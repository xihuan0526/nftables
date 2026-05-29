from __future__ import annotations

from dataclasses import dataclass
import ipaddress
import re
from typing import Iterable


_PORT_RE = re.compile(r"^(?P<listen>\d{1,5}):(?P<host>[^:]+):(?P<target>\d{1,5})(?:/(?P<proto>tcp|udp))?$")


@dataclass(frozen=True)
class ForwardRule:
    listen_port: int
    target_host: str
    target_port: int
    protocol: str = "tcp"

    def __post_init__(self) -> None:
        _validate_port(self.listen_port, "listen_port")
        _validate_port(self.target_port, "target_port")
        if self.protocol not in {"tcp", "udp"}:
            raise ValueError("protocol must be tcp or udp")
        try:
            ipaddress.ip_address(self.target_host)
        except ValueError as exc:
            raise ValueError(f"target_host must be an IP address: {self.target_host}") from exc

    @property
    def nft_family(self) -> str:
        return "ip6" if ipaddress.ip_address(self.target_host).version == 6 else "ip"


def _validate_port(port: int, field_name: str) -> None:
    if not 1 <= int(port) <= 65535:
        raise ValueError(f"{field_name} must be between 1 and 65535")


def parse_port_mapping(value: str) -> ForwardRule:
    """Parse LISTEN_IP:TARGET_IP:TARGET_PORT[/tcp|/udp] style mappings.

    Format: listen_port:target_ip:target_port[/protocol]
    Example: 8080:10.0.0.2:80 or 5353:10.0.0.3:53/udp
    """
    match = _PORT_RE.match(value.strip())
    if not match:
        if "/" in value and not value.endswith(("/tcp", "/udp")):
            raise ValueError("protocol must be tcp or udp")
        raise ValueError("mapping must be listen_port:target_ip:target_port[/tcp|/udp]")
    protocol = match.group("proto") or "tcp"
    return ForwardRule(
        listen_port=int(match.group("listen")),
        target_host=match.group("host"),
        target_port=int(match.group("target")),
        protocol=protocol,
    )


class NftScriptBuilder:
    def __init__(self, table: str = "portfw", interface: str | None = None) -> None:
        if not re.match(r"^[A-Za-z_][A-Za-z0-9_-]*$", table):
            raise ValueError("table must be a valid nftables identifier")
        self.table = table
        self.interface = interface

    def build_apply_script(self, rules: Iterable[ForwardRule]) -> str:
        rules = list(rules)
        lines = [
            "#!/usr/sbin/nft -f",
            f"delete table inet {self.table}",
            "",
            f"table inet {self.table} {{",
            "  chain prerouting {",
            "    type nat hook prerouting priority dstnat; policy accept;",
        ]
        for rule in rules:
            lines.append(f"    {self._match_prefix(rule)}dnat {rule.nft_family} to {self._format_addr(rule)}:{rule.target_port}")
        lines.extend([
            "  }",
            "",
            "  chain forward {",
            "    type filter hook forward priority filter; policy accept;",
        ])
        for rule in rules:
            lines.append(f"    {rule.nft_family} daddr {self._format_addr(rule)} {rule.protocol} dport {rule.target_port} accept")
        lines.extend([
            "  }",
            "}",
            "",
        ])
        return "\n".join(lines)

    def build_delete_script(self) -> str:
        return f"delete table inet {self.table}\n"

    def _match_prefix(self, rule: ForwardRule) -> str:
        iface = f'iifname "{self.interface}" ' if self.interface else ""
        return f"{iface}{rule.protocol} dport {rule.listen_port} "

    @staticmethod
    def _format_addr(rule: ForwardRule) -> str:
        if rule.nft_family == "ip6":
            return f"[{rule.target_host}]"
        return rule.target_host
