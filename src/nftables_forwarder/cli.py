from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

from .core import NftScriptBuilder, parse_port_mapping


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="nftables-forwarder",
        description="Generate and apply nftables port forwarding rules.",
    )
    parser.add_argument(
        "mapping",
        nargs="*",
        help="Port mapping: listen_port:target_ip:target_port[/tcp|/udp]. Example: 8080:10.0.0.2:80",
    )
    parser.add_argument("--table", default="portfw", help="nftables table name (default: portfw)")
    parser.add_argument("--interface", "-i", help="Only match packets arriving on this interface")
    parser.add_argument("--apply", action="store_true", help="Apply generated rules with nft -f -")
    parser.add_argument("--delete", action="store_true", help="Delete the generated table")
    parser.add_argument("--output", "-o", type=Path, help="Write generated nft script to a file")
    parser.add_argument("--sysctl", action="store_true", help="Enable net.ipv4.ip_forward=1 before applying")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    try:
        builder = NftScriptBuilder(table=args.table, interface=args.interface)
        if args.delete:
            script = builder.build_delete_script()
        else:
            if not args.mapping:
                parser.error("at least one mapping is required unless --delete is used")
            rules = [parse_port_mapping(item) for item in args.mapping]
            script = builder.build_apply_script(rules)
    except ValueError as exc:
        parser.error(str(exc))

    if args.output:
        args.output.write_text(script, encoding="utf-8")

    if args.apply:
        return apply_script(script, enable_sysctl=args.sysctl)

    if not args.output:
        print(script, end="")
    return 0


def apply_script(script: str, enable_sysctl: bool = False) -> int:
    if shutil.which("nft") is None:
        print("error: nft command not found", file=sys.stderr)
        return 127
    if enable_sysctl:
        subprocess.run(["sysctl", "-w", "net.ipv4.ip_forward=1"], check=True)
    subprocess.run(["nft", "-f", "-"], input=script, text=True, check=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
