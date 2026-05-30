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

echo "shell menu tests OK"
