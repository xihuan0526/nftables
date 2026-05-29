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

menu_output="$(printf '5\n' | $script)"
[[ "$menu_output" == *"请选择功能"* ]] || fail "no-arg run should show interactive menu"
[[ "$menu_output" == *"1) 添加端口转发"* ]] || fail "interactive menu should show add option"
[[ "$menu_output" == *"已退出"* ]] || fail "choice 5 should exit cleanly"

echo "shell menu tests OK"
