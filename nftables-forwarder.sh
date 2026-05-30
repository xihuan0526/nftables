#!/usr/bin/env bash
set -euo pipefail

TABLE="portfw"
CHAIN_PREROUTING="prerouting"
CHAIN_FORWARD="forward"
CHAIN_POSTROUTING="postrouting"
STATE_FILE="/var/lib/nftables-forwarder/rules.tsv"

usage() {
  cat <<'EOF'
nftables-forwarder.sh - nftables 端口转发管理脚本

直接运行会进入菜单：
  sudo ./nftables-forwarder.sh

功能选项：
  1) 添加端口转发
  2) 显示当前端口转发
  3) 删除端口转发
  4) 清空全部规则
  5) 退出

命令行用法：
  sudo ./nftables-forwarder.sh add <协议> <监听端口> <目标IP> <目标端口> [网卡]
  sudo ./nftables-forwarder.sh list
  sudo ./nftables-forwarder.sh delete <编号>
  sudo ./nftables-forwarder.sh delete <协议> <监听端口> [目标IP] [目标端口]
  sudo ./nftables-forwarder.sh flush

协议：
  both    同时添加 TCP 和 UDP，默认值
  tcp     只添加 TCP
  udp     只添加 UDP

示例：
  sudo ./nftables-forwarder.sh add both 8080 10.0.0.2 80 eth0
  sudo ./nftables-forwarder.sh add tcp 8080 10.0.0.2 80 eth0
  sudo ./nftables-forwarder.sh add udp 5353 10.0.0.3 53
  sudo ./nftables-forwarder.sh list
  sudo ./nftables-forwarder.sh delete 2
  sudo ./nftables-forwarder.sh delete tcp 8080
  sudo ./nftables-forwarder.sh flush

说明：
  - 添加规则时会同时创建 DNAT 和 MASQUERADE。
  - 这样目标是内网 IP 或外网 IP 时，一般都能正常回包。
  - 目标服务器看到的来源 IP 会是本机/转发机 IP，而不是原始客户端 IP。

注意：
  - 需要 Linux + nftables；如果系统未安装 nftables，脚本会尝试用 apt 自动安装。
  - add/delete/flush 通常需要 root 权限。
  - 本脚本管理 table: inet portfw，请不要把其它手写规则放进同名 table。
EOF
}

show_menu() {
  cat <<'EOF'
========================================
 nftables 端口转发管理工具
========================================
1) 添加端口转发
2) 显示当前端口转发
3) 删除端口转发
4) 清空全部规则
5) 退出
========================================
EOF
}

interactive_menu() {
  while true; do
    show_menu
    echo -n "请选择功能 [1-5]: "
    read -r choice
    case "$choice" in
      1) prompt_add_rule ;;
      2) list_rules ;;
      3) prompt_delete_rule ;;
      4) prompt_flush_rules ;;
      5|q|Q) echo "已退出。"; return 0 ;;
      *) echo "无效选择，请输入 1-5。" ;;
    esac
    echo
    read -r -p "按 Enter 返回菜单..." _
  done
}

prompt_add_rule() {
  echo
  echo "添加端口转发（默认同时添加 TCP 和 UDP）"
  local proto="both"
  read -r -p "监听端口，例如 8080: " listen_port
  read -r -p "目标 IP，例如 10.0.0.2 或 1.1.1.1: " target_ip
  read -r -p "目标端口，例如 80: " target_port
  read -r -p "入站网卡，可留空，例如 eth0: " iface
  add_rule "$proto" "$listen_port" "$target_ip" "$target_port" "$iface"
}

prompt_delete_rule() {
  echo
  echo "删除端口转发"
  list_rules
  echo
  read -r -p "请输入要删除的编号，或留空后按协议/端口删除: " rule_id
  if [[ -n "$rule_id" ]]; then
    delete_rule "$rule_id"
    return 0
  fi
  read -r -p "协议 tcp/udp: " proto
  read -r -p "监听端口，例如 8080: " listen_port
  read -r -p "目标 IP，可留空: " target_ip
  read -r -p "目标端口，可留空: " target_port
  delete_rule "$proto" "$listen_port" "$target_ip" "$target_port"
}

prompt_flush_rules() {
  echo
  read -r -p "确认清空所有由本脚本创建的规则？输入 yes 继续: " answer
  if [[ "$answer" == "yes" ]]; then
    flush_rules
  else
    echo "已取消。"
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "错误：找不到命令 $1，请先安装。" >&2
    exit 127
  }
}

ensure_nftables() {
  if command -v nft >/dev/null 2>&1; then
    return 0
  fi

  need_root_for_write

  if command -v apt-get >/dev/null 2>&1; then
    echo "检测到未安装 nftables，正在自动安装..."
    apt-get update -y
    apt-get install -y nftables
  elif command -v apt >/dev/null 2>&1; then
    echo "检测到未安装 nftables，正在自动安装..."
    apt update -y
    apt install -y nftables
  else
    echo "错误：未安装 nftables，且当前系统没有 apt/apt-get，无法自动安装。" >&2
    echo "请手动安装 nftables 后再运行本脚本。" >&2
    exit 127
  fi

  command -v nft >/dev/null 2>&1 || {
    echo "错误：nftables 安装后仍找不到 nft 命令。" >&2
    exit 127
  }
}

need_root_for_write() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "错误：该操作需要 root 权限，请使用 sudo。" >&2
    exit 1
  fi
}

validate_proto() {
  case "$1" in
    tcp|udp|both) ;;
    *) echo "错误：协议只能是 both、tcp 或 udp。" >&2; exit 1 ;;
  esac
}

validate_single_proto() {
  case "$1" in
    tcp|udp) ;;
    *) echo "错误：删除单条规则时协议只能是 tcp 或 udp。" >&2; exit 1 ;;
  esac
}

expand_proto() {
  case "$1" in
    both) printf 'tcp\nudp\n' ;;
    tcp|udp) printf '%s\n' "$1" ;;
    *) echo "错误：协议只能是 both、tcp 或 udp。" >&2; exit 1 ;;
  esac
}

validate_port() {
  local port="$1"
  local name="$2"
  if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
    echo "错误：$name 必须是 1-65535 的端口号。" >&2
    exit 1
  fi
}

ensure_table() {
  nft list table inet "$TABLE" >/dev/null 2>&1 || nft add table inet "$TABLE"
  nft list chain inet "$TABLE" "$CHAIN_PREROUTING" >/dev/null 2>&1 || \
    nft "add chain inet $TABLE $CHAIN_PREROUTING { type nat hook prerouting priority dstnat; policy accept; }"
  nft list chain inet "$TABLE" "$CHAIN_FORWARD" >/dev/null 2>&1 || \
    nft "add chain inet $TABLE $CHAIN_FORWARD { type filter hook forward priority filter; policy accept; }"
  nft list chain inet "$TABLE" "$CHAIN_POSTROUTING" >/dev/null 2>&1 || \
    nft "add chain inet $TABLE $CHAIN_POSTROUTING { type nat hook postrouting priority srcnat; policy accept; }"
}

enable_forwarding() {
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
}

state_dir() {
  dirname "$STATE_FILE"
}

ensure_state_file() {
  mkdir -p "$(state_dir)"
  touch "$STATE_FILE"
  migrate_state_file
}

migrate_state_file() {
  [[ -s "$STATE_FILE" ]] || return 0
  local tmp
  tmp="$(mktemp)"
  while IFS=$'\t' read -r saved_proto saved_listen saved_target_ip saved_target_port field5 field6 field7 field8 rest; do
    [[ -n "${saved_proto:-}" ]] || continue

    local iface nat_rule filter_rule post_rule
    if [[ "${field8:-}" == *"masquerade"* ]]; then
      # Current format: proto, listen, target_ip, target_port, iface, nat, filter, post
      iface="${field5:-}"
      nat_rule="${field6:-}"
      filter_rule="${field7:-}"
      post_rule="${field8:-}"
    else
      # Old 7-column format: proto, listen, target_ip, target_port, iface, nat, filter
      # Very old broken rows may miss iface; reconstruct rules defensively.
      iface="${field5:-}"
      nat_rule="${field6:-}"
      filter_rule="${field7:-}"
      post_rule="ip daddr ${saved_target_ip} masquerade"
    fi

    if [[ -z "$filter_rule" || "$filter_rule" == *"masquerade"* ]]; then
      iface=""
      nat_rule="${saved_proto} dport ${saved_listen} dnat ip to ${saved_target_ip}:${saved_target_port}"
      filter_rule="ip daddr ${saved_target_ip} ${saved_proto} dport ${saved_target_port} accept"
      post_rule="ip daddr ${saved_target_ip} masquerade"
    elif [[ "$nat_rule" != *" dport "* || "$nat_rule" != *" dnat "* ]]; then
      iface=""
      nat_rule="${saved_proto} dport ${saved_listen} dnat ip to ${saved_target_ip}:${saved_target_port}"
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$saved_proto" "$saved_listen" "$saved_target_ip" "$saved_target_port" "$iface" "$nat_rule" "$filter_rule" "$post_rule" >> "$tmp"
  done < "$STATE_FILE"
  mv "$tmp" "$STATE_FILE"
}

rule_key_matches() {
  local line="$1" proto="$2" listen_port="$3" target_ip="${4:-}" target_port="${5:-}"
  IFS=$'\t' read -r saved_proto saved_listen saved_target_ip saved_target_port saved_iface saved_nat saved_filter saved_post <<<"$line"
  [[ "$saved_proto" == "$proto" && "$saved_listen" == "$listen_port" ]] || return 1
  [[ -z "$target_ip" || "$saved_target_ip" == "$target_ip" ]] || return 1
  [[ -z "$target_port" || "$saved_target_port" == "$target_port" ]] || return 1
  return 0
}

line_by_number() {
  local number="$1"
  awk -v n="$number" 'NF && ++idx == n {print; found=1; exit} END{exit !found}' "$STATE_FILE"
}

add_nft_rule_if_missing() {
  local chain="$1" rule="$2"
  if nft list chain inet "$TABLE" "$chain" 2>/dev/null | grep -Fq -- "$rule"; then
    return 0
  fi
  nft add rule inet "$TABLE" "$chain" $rule
}

add_one_rule() {
  local proto="$1" listen_port="$2" target_ip="$3" target_port="$4" iface="$5" iface_expr=""

  if [[ -n "$iface" ]]; then
    iface_expr="iifname \"$iface\" "
  fi

  local nat_rule="${iface_expr}${proto} dport ${listen_port} dnat ip to ${target_ip}:${target_port}"
  local filter_rule="ip daddr ${target_ip} ${proto} dport ${target_port} accept"
  local post_rule="ip daddr ${target_ip} masquerade"

  if awk -F '\t' -v p="$proto" -v lp="$listen_port" -v ip="$target_ip" -v tp="$target_port" \
    '$1==p && $2==lp && $3==ip && $4==tp {found=1} END{exit !found}' "$STATE_FILE"; then
    echo "已存在：${proto} ${listen_port} -> ${target_ip}:${target_port}"
    add_nft_rule_if_missing "$CHAIN_POSTROUTING" "$post_rule"
    return 0
  fi

  add_nft_rule_if_missing "$CHAIN_PREROUTING" "$nat_rule"
  add_nft_rule_if_missing "$CHAIN_FORWARD" "$filter_rule"
  add_nft_rule_if_missing "$CHAIN_POSTROUTING" "$post_rule"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$proto" "$listen_port" "$target_ip" "$target_port" "$iface" "$nat_rule" "$filter_rule" "$post_rule" >> "$STATE_FILE"
  echo "已添加：${proto} ${listen_port} -> ${target_ip}:${target_port}${iface:+ via $iface}，已启用 masquerade"
}

add_rule() {
  need_root_for_write
  ensure_nftables
  need_cmd sysctl
  need_cmd grep

  local proto="${1:-both}" listen_port="${2:-}" target_ip="${3:-}" target_port="${4:-}" iface="${5:-}"
  [[ -n "$proto" && -n "$listen_port" && -n "$target_ip" && -n "$target_port" ]] || { usage; exit 1; }
  validate_proto "$proto"
  validate_port "$listen_port" "监听端口"
  validate_port "$target_port" "目标端口"

  ensure_table
  enable_forwarding
  ensure_state_file

  local p
  while IFS= read -r p; do
    add_one_rule "$p" "$listen_port" "$target_ip" "$target_port" "$iface"
  done < <(expand_proto "$proto")
}

list_rules() {
  ensure_nftables
  [[ -f "$STATE_FILE" ]] && migrate_state_file

  if [[ -f "$STATE_FILE" && -s "$STATE_FILE" ]]; then
    echo "当前端口转发："
    printf '%-4s %-6s %-12s %-22s %-10s %-12s\n' "编号" "协议" "监听端口" "目标" "网卡" "SNAT"
    awk -F '\t' '
      NF {
        iface = ($5 == "" ? "-" : $5)
        snat = ($8 == "" ? "-" : "masquerade")
        printf "%-4d %-6s %-12s %-22s %-10s %-12s\n", ++idx, $1, $2, $3 ":" $4, iface, snat
      }
    ' "$STATE_FILE"
  else
    echo "本脚本暂无端口转发记录。"
  fi
}

delete_matching_nft_rule() {
  local chain="$1" rule="$2"
  local output handles handle
  output="$(nft --handle list chain inet "$TABLE" "$chain" 2>/dev/null || true)"
  handles="$(printf '%s\n' "$output" | grep -F -- "$rule" | sed -n 's/.* handle \([0-9][0-9]*\).*/\1/p' || true)"
  while IFS= read -r handle; do
    [[ -n "$handle" ]] && nft delete rule inet "$TABLE" "$chain" handle "$handle" || true
  done <<< "$handles"
}

post_rule_still_used() {
  local post_rule="$1" tmp_file="$2"
  [[ -s "$tmp_file" ]] || return 1
  awk -F '\t' -v rule="$post_rule" '{candidate=($8 != "" ? $8 : $7)} candidate==rule {found=1} END{exit !found}' "$tmp_file"
}

delete_saved_rule() {
  local saved_proto="$1" saved_listen="$2" saved_target_ip="$3" saved_target_port="$4" saved_nat="$5" saved_filter="$6" saved_post="${7:-}"
  [[ -n "$saved_post" ]] || saved_post="ip daddr ${saved_target_ip} masquerade"

  delete_matching_nft_rule "$CHAIN_PREROUTING" "$saved_nat"
  delete_matching_nft_rule "$CHAIN_FORWARD" "$saved_filter"
  echo "已删除：${saved_proto} ${saved_listen} -> ${saved_target_ip}:${saved_target_port}"
}

delete_unused_post_rule() {
  local saved_post="$1" tmp_file="$2"
  [[ -n "$saved_post" ]] || return 0
  if ! post_rule_still_used "$saved_post" "$tmp_file"; then
    delete_matching_nft_rule "$CHAIN_POSTROUTING" "$saved_post"
  fi
}

delete_rule_by_number() {
  local number="$1"
  validate_port "$number" "编号"

  if [[ ! -f "$STATE_FILE" || ! -s "$STATE_FILE" ]]; then
    echo "没有可删除的记录。"
    return 0
  fi

  migrate_state_file

  local line tmp deleted=0 idx=0 deleted_post=""
  line="$(line_by_number "$number" || true)"
  if [[ -z "$line" ]]; then
    echo "未找到编号：$number"
    return 0
  fi

  tmp="$(mktemp)"
  while IFS=$'\t' read -r saved_proto saved_listen saved_target_ip saved_target_port saved_iface saved_nat saved_filter saved_post; do
    idx=$((idx + 1))
    if [[ "$idx" -eq "$number" ]]; then
      delete_saved_rule "$saved_proto" "$saved_listen" "$saved_target_ip" "$saved_target_port" "$saved_nat" "$saved_filter" "$saved_post"
      deleted_post="${saved_post:-ip daddr ${saved_target_ip} masquerade}"
      deleted=1
    else
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$saved_proto" "$saved_listen" "$saved_target_ip" "$saved_target_port" "$saved_iface" "$saved_nat" "$saved_filter" "${saved_post:-ip daddr ${saved_target_ip} masquerade}" >> "$tmp"
    fi
  done < "$STATE_FILE"

  delete_unused_post_rule "$deleted_post" "$tmp"
  mv "$tmp" "$STATE_FILE"
  [[ "$deleted" -eq 1 ]] || echo "未找到编号：$number"
}

delete_rule_by_fields() {
  local proto="$1" listen_port="$2" target_ip="${3:-}" target_port="${4:-}"
  [[ -n "$proto" && -n "$listen_port" ]] || { usage; exit 1; }
  validate_single_proto "$proto"
  validate_port "$listen_port" "监听端口"
  [[ -z "$target_port" ]] || validate_port "$target_port" "目标端口"

  if [[ ! -f "$STATE_FILE" || ! -s "$STATE_FILE" ]]; then
    echo "没有可删除的记录。"
    return 0
  fi

  migrate_state_file

  local tmp
  tmp="$(mktemp)"
  local deleted=0 deleted_posts=""

  while IFS=$'\t' read -r saved_proto saved_listen saved_target_ip saved_target_port saved_iface saved_nat saved_filter saved_post; do
    local line
    saved_post="${saved_post:-ip daddr ${saved_target_ip} masquerade}"
    line=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$saved_proto" "$saved_listen" "$saved_target_ip" "$saved_target_port" "$saved_iface" "$saved_nat" "$saved_filter" "$saved_post")
    if rule_key_matches "$line" "$proto" "$listen_port" "$target_ip" "$target_port"; then
      delete_saved_rule "$saved_proto" "$saved_listen" "$saved_target_ip" "$saved_target_port" "$saved_nat" "$saved_filter" "$saved_post"
      deleted_posts+="$saved_post"$'\n'
      deleted=1
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$STATE_FILE"

  while IFS= read -r post_rule; do
    [[ -n "$post_rule" ]] && delete_unused_post_rule "$post_rule" "$tmp"
  done <<< "$deleted_posts"

  mv "$tmp" "$STATE_FILE"
  if [[ "$deleted" -eq 0 ]]; then
    echo "未找到匹配规则。"
  fi
}

delete_rule() {
  need_root_for_write
  ensure_nftables
  need_cmd grep

  if [[ "${1:-}" =~ ^[0-9]+$ && $# -eq 1 ]]; then
    delete_rule_by_number "$1"
  else
    delete_rule_by_fields "$@"
  fi
}

flush_rules() {
  need_root_for_write
  ensure_nftables
  nft delete table inet "$TABLE" 2>/dev/null || true
  rm -f "$STATE_FILE"
  echo "已清空 inet $TABLE 和本地记录。"
}

main() {
  local cmd="${1:-}"
  if [[ -z "$cmd" ]]; then
    interactive_menu
    return 0
  fi
  shift || true
  case "$cmd" in
    add) add_rule "$@" ;;
    list|show) list_rules "$@" ;;
    delete|del|remove|rm) delete_rule "$@" ;;
    flush|clear) flush_rules "$@" ;;
    menu) interactive_menu ;;
    -h|--help|help) usage ;;
    *) echo "未知命令：$cmd" >&2; usage; exit 1 ;;
  esac
}

main "$@"
