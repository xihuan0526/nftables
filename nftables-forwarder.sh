#!/usr/bin/env bash
set -euo pipefail

TABLE="portfw"
CHAIN_PREROUTING="prerouting"
CHAIN_FORWARD="forward"
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
  sudo ./nftables-forwarder.sh delete <协议> <监听端口> [目标IP] [目标端口]
  sudo ./nftables-forwarder.sh flush

示例：
  sudo ./nftables-forwarder.sh add tcp 8080 10.0.0.2 80 eth0
  sudo ./nftables-forwarder.sh add udp 5353 10.0.0.3 53
  sudo ./nftables-forwarder.sh list
  sudo ./nftables-forwarder.sh delete tcp 8080
  sudo ./nftables-forwarder.sh flush

注意：
  - 需要 Linux + nftables。
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
  echo "添加端口转发"
  read -r -p "协议 tcp/udp [tcp]: " proto
  proto="${proto:-tcp}"
  read -r -p "监听端口，例如 8080: " listen_port
  read -r -p "目标 IP，例如 10.0.0.2: " target_ip
  read -r -p "目标端口，例如 80: " target_port
  read -r -p "入站网卡，可留空，例如 eth0: " iface
  add_rule "$proto" "$listen_port" "$target_ip" "$target_port" "$iface"
}

prompt_delete_rule() {
  echo
  echo "删除端口转发"
  read -r -p "协议 tcp/udp [tcp]: " proto
  proto="${proto:-tcp}"
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

need_root_for_write() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "错误：该操作需要 root 权限，请使用 sudo。" >&2
    exit 1
  fi
}

validate_proto() {
  case "$1" in
    tcp|udp) ;;
    *) echo "错误：协议只能是 tcp 或 udp。" >&2; exit 1 ;;
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
  nft list table inet "$TABLE" >/dev/null 2>&1 && return 0
  nft add table inet "$TABLE"
  nft "add chain inet $TABLE $CHAIN_PREROUTING { type nat hook prerouting priority dstnat; policy accept; }"
  nft "add chain inet $TABLE $CHAIN_FORWARD { type filter hook forward priority filter; policy accept; }"
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
}

rule_key_matches() {
  local line="$1" proto="$2" listen_port="$3" target_ip="${4:-}" target_port="${5:-}"
  IFS=$'\t' read -r saved_proto saved_listen saved_target_ip saved_target_port saved_iface saved_nat saved_filter <<<"$line"
  [[ "$saved_proto" == "$proto" && "$saved_listen" == "$listen_port" ]] || return 1
  [[ -z "$target_ip" || "$saved_target_ip" == "$target_ip" ]] || return 1
  [[ -z "$target_port" || "$saved_target_port" == "$target_port" ]] || return 1
  return 0
}

add_rule() {
  need_root_for_write
  need_cmd nft
  need_cmd sysctl

  local proto="${1:-}" listen_port="${2:-}" target_ip="${3:-}" target_port="${4:-}" iface="${5:-}"
  [[ -n "$proto" && -n "$listen_port" && -n "$target_ip" && -n "$target_port" ]] || { usage; exit 1; }
  validate_proto "$proto"
  validate_port "$listen_port" "监听端口"
  validate_port "$target_port" "目标端口"

  ensure_table
  enable_forwarding
  ensure_state_file

  local iface_expr=""
  if [[ -n "$iface" ]]; then
    iface_expr="iifname \"$iface\" "
  fi

  local nat_rule="${iface_expr}${proto} dport ${listen_port} dnat ip to ${target_ip}:${target_port}"
  local filter_rule="ip daddr ${target_ip} ${proto} dport ${target_port} accept"

  if awk -F '\t' -v p="$proto" -v lp="$listen_port" -v ip="$target_ip" -v tp="$target_port" \
    '$1==p && $2==lp && $3==ip && $4==tp {found=1} END{exit !found}' "$STATE_FILE"; then
    echo "已存在：${proto} ${listen_port} -> ${target_ip}:${target_port}"
    return 0
  fi

  nft add rule inet "$TABLE" "$CHAIN_PREROUTING" $nat_rule
  nft add rule inet "$TABLE" "$CHAIN_FORWARD" $filter_rule

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$proto" "$listen_port" "$target_ip" "$target_port" "$iface" "$nat_rule" "$filter_rule" >> "$STATE_FILE"
  echo "已添加：${proto} ${listen_port} -> ${target_ip}:${target_port}${iface:+ via $iface}"
}

list_rules() {
  need_cmd nft
  echo "nftables table: inet $TABLE"
  echo

  if [[ -f "$STATE_FILE" && -s "$STATE_FILE" ]]; then
    echo "本脚本记录的端口转发："
    printf '%-6s %-12s %-22s %-10s\n' "协议" "监听端口" "目标" "网卡"
    while IFS=$'\t' read -r proto listen_port target_ip target_port iface nat_rule filter_rule; do
      printf '%-6s %-12s %-22s %-10s\n' "$proto" "$listen_port" "${target_ip}:${target_port}" "${iface:--}"
    done < "$STATE_FILE"
  else
    echo "本脚本暂无记录。"
  fi

  echo
  echo "当前 nftables 规则："
  nft list table inet "$TABLE" 2>/dev/null || echo "inet $TABLE 不存在。"
}

delete_rule() {
  need_root_for_write
  need_cmd nft

  local proto="${1:-}" listen_port="${2:-}" target_ip="${3:-}" target_port="${4:-}"
  [[ -n "$proto" && -n "$listen_port" ]] || { usage; exit 1; }
  validate_proto "$proto"
  validate_port "$listen_port" "监听端口"
  [[ -z "$target_port" ]] || validate_port "$target_port" "目标端口"

  if [[ ! -f "$STATE_FILE" || ! -s "$STATE_FILE" ]]; then
    echo "没有可删除的记录。"
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  local deleted=0

  while IFS=$'\t' read -r saved_proto saved_listen saved_target_ip saved_target_port saved_iface saved_nat saved_filter; do
    local line
    line=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' "$saved_proto" "$saved_listen" "$saved_target_ip" "$saved_target_port" "$saved_iface" "$saved_nat" "$saved_filter")
    if rule_key_matches "$line" "$proto" "$listen_port" "$target_ip" "$target_port"; then
      nft --handle list chain inet "$TABLE" "$CHAIN_PREROUTING" | awk -v pat="$saved_nat" '$0 ~ pat {print $NF}' | while read -r handle; do
        [[ -n "$handle" ]] && nft delete rule inet "$TABLE" "$CHAIN_PREROUTING" handle "$handle" || true
      done
      nft --handle list chain inet "$TABLE" "$CHAIN_FORWARD" | awk -v pat="$saved_filter" '$0 ~ pat {print $NF}' | while read -r handle; do
        [[ -n "$handle" ]] && nft delete rule inet "$TABLE" "$CHAIN_FORWARD" handle "$handle" || true
      done
      echo "已删除：${saved_proto} ${saved_listen} -> ${saved_target_ip}:${saved_target_port}"
      deleted=1
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$STATE_FILE"

  mv "$tmp" "$STATE_FILE"
  if [[ "$deleted" -eq 0 ]]; then
    echo "未找到匹配规则。"
  fi
}

flush_rules() {
  need_root_for_write
  need_cmd nft
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
