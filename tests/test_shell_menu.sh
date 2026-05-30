#!/usr/bin/env bash
set -euo pipefail

script="${1:-./nftables-forwarder.sh}"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

output="$($script --help)"
[[ "$output" == *"1) 添加端口转发"* ]] || fail "help should show add menu option"
[[ "$output" == *"2) 显示当前端口转发"* ]] || fail "help should show list menu option"
[[ "$output" == *"3) 删除端口转发"* ]] || fail "help should show delete menu option"
[[ "$output" == *"4) 清空全部规则"* ]] || fail "help should show flush menu option"
[[ "$output" == *"both    同时添加 TCP 和 UDP"* ]] || fail "help should document both protocol"
[[ "$output" == *"delete <编号>"* ]] || fail "help should document delete by number"
[[ "$output" == *"MASQUERADE"* || "$output" == *"masquerade"* ]] || fail "help should document masquerade"

menu_output="$(printf '5\n' | $script)"
[[ "$menu_output" == *"请选择功能"* ]] || fail "no-arg run should show interactive menu"
[[ "$menu_output" == *"1) 添加端口转发"* ]] || fail "interactive menu should show add option"
[[ "$menu_output" == *"已退出"* ]] || fail "choice 5 should exit cleanly"

# Static source checks for the UX requirements. These avoid needing root/nft in CI.
grep -q 'local proto="both"' "$script" || fail "interactive add should default to both without asking protocol"
! grep -q '协议 both/tcp/udp \[both\]' "$script" || fail "interactive add should not ask protocol"
grep -q 'printf .*"编号" "协议" "监听端口"' "$script" || fail "list should print rule numbers"
! grep -q '当前 nftables 规则' "$script" || fail "list should not print raw nftables rules"
grep -q 'delete_rule_by_number' "$script" || fail "script should support delete by number"
grep -q 'CHAIN_POSTROUTING="postrouting"' "$script" || fail "script should define postrouting chain"
grep -q 'masquerade' "$script" || fail "script should add masquerade rules"

# Regression test: adding two ports in one menu session should not corrupt proto variables.
tmp="$(mktemp -d)"
mkdir -p "$tmp/bin"
cat > "$tmp/bin/sysctl" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$tmp/bin/nft" <<'SH'
#!/usr/bin/env bash
log=${NFT_LOG:-/tmp/nftables-forwarder-test-nft.log}
printf '%s\n' "$*" >> "$log"
case "$*" in
  list\ table*) exit 1 ;;
  list\ chain*) exit 1 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$tmp/bin/nft" "$tmp/bin/sysctl"
rm -rf /var/lib/nftables-forwarder
add_twice_output="$(PATH="$tmp/bin:$PATH" timeout 5 bash "$script" <<'EOF'
1
59306
203.0.113.7
59306


1
54695
203.0.113.7
54695


5
EOF
)"
[[ "$add_twice_output" != *"错误：协议只能是 both、tcp 或 udp"* ]] || fail "adding a second port should not trigger protocol error"
[[ -f /var/lib/nftables-forwarder/rules.tsv ]] || fail "state file should be created"
[[ "$(wc -l < /var/lib/nftables-forwarder/rules.tsv)" -eq 4 ]] || fail "two both-rules should create four state rows"

# Regression test: delete by number should update state even when no nft handle matches.
rm -rf /var/lib/nftables-forwarder
mkdir -p /var/lib/nftables-forwarder
cat > /var/lib/nftables-forwarder/rules.tsv <<'EOF'
tcp	5000	1.1.1.1	5000		tcp dport 5000 dnat ip to 1.1.1.1:5000	ip daddr 1.1.1.1 tcp dport 5000 accept	ip daddr 1.1.1.1 masquerade
udp	5000	1.1.1.1	5000		udp dport 5000 dnat ip to 1.1.1.1:5000	ip daddr 1.1.1.1 udp dport 5000 accept	ip daddr 1.1.1.1 masquerade
EOF
PATH="$tmp/bin:$PATH" timeout 5 bash "$script" delete 1 >/tmp/nftables-forwarder-delete-test.out
[[ "$(wc -l < /var/lib/nftables-forwarder/rules.tsv)" -eq 1 ]] || fail "delete by number should remove one state row"
PATH="$tmp/bin:$PATH" timeout 5 bash "$script" delete 1 >/tmp/nftables-forwarder-delete-test.out
[[ ! -s /var/lib/nftables-forwarder/rules.tsv ]] || fail "delete by number should remove final state row"

echo "shell menu tests OK"
