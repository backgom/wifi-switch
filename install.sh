#!/bin/bash
set -euo pipefail

INT_COUNT=0
_handle_int() {
  if (( INT_COUNT >= 1 )); then
    printf '\033[?25h\n취소.\n' >/dev/tty 2>/dev/null || true
    exit 130
  fi
  INT_COUNT=$((INT_COUNT + 1))
  printf '\033[?25h\n  메인 메뉴로 돌아갑니다 (Ctrl+C 한 번 더 누르면 종료)\n' \
    >/dev/tty 2>/dev/null || true
}
trap _handle_int INT

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WIFI_DIR="${HOME}/.wifi"
CONFIG_FILE="${WIFI_DIR}/config.json"
SWITCH_SRC="${SCRIPT_DIR}/wifi-switch.sh"
SWITCH_DEST="${WIFI_DIR}/wifi-switch.sh"
PLIST_TEMPLATE="${SCRIPT_DIR}/com.user.wifi-switch.plist.template"
PLIST_DEST="${HOME}/Library/LaunchAgents/com.user.wifi-switch.plist"

mkdir -p "${WIFI_DIR}/logs" "${HOME}/Library/LaunchAgents"

normalize_mac() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | awk -F: '
    NF==6 {
      out=""
      for (i=1;i<=NF;i++) { v=$i; if (length(v)==1) v="0"v; out = out (i>1?":":"") v }
      print out
    }'
}

# Arrow-key TUI picker with optional combo input row (last virtual row).
# Args: prompt, input_label (empty = no input row), input_default, options...
# Globals on return:
#   TUI_INDEX     = 0..n-1 if regular item picked, -1 otherwise
#   TUI_INPUT     = typed text if input row was used, "" otherwise
#   TUI_BACK      = 1 if user pressed ESC (go back one step)
#   TUI_CANCELLED = 1 if user pressed q (no-input mode) or Ctrl+C (cancel all)
# Keys: ↑↓ move, PgUp/PgDn page, Home/End jump, Enter confirm,
#       ESC = back, Ctrl+C = cancel-all, q (no input mode) = cancel-all.
# When input row is enabled: typing goes to input row (auto-jumps cursor),
# Backspace deletes a byte. Pre-populated typed buffer = input_default.
# Enter on empty input row is allowed only when input_default was non-empty
# (so the user explicitly cleared a pre-populated value).
TUI_INDEX=-1
TUI_INPUT=""
TUI_BACK=0
TUI_CANCELLED=0
tui_select_into() {
  TUI_INDEX=-1
  TUI_INPUT=""
  TUI_BACK=0
  TUI_CANCELLED=0
  local prompt="$1"
  local input_label="$2"
  local input_default="${3:-}"
  shift 3
  local opts=("$@")
  # Always prepend live network status header so user can verify changes.
  # Preserve body so Ctrl+R refresh can re-prepend with a fresh header.
  local _prompt_body="${prompt}"
  if declare -F _status_header >/dev/null 2>&1; then
    local _status
    _status="$(_status_header)"
    prompt="${_status}

${_prompt_body}"
  fi
  local n=${#opts[@]}
  local has_input=0
  [[ -n "${input_label}" ]] && has_input=1
  local n_total=$(( n + has_input ))
  (( n_total == 0 )) && return 0
  local cur=0 k1 k2 k3 view_top=0 rows view_h
  local winch=0
  local typed="${input_default}"
  local had_default=0
  [[ -n "${input_default}" ]] && had_default=1
  local pre_int=${INT_COUNT}

  _term_rows() { rows="$(tput lines 2>/dev/null || echo 24)"; }
  _term_rows

  _draw() {
    # Count prompt lines (supports multi-line headers).
    local _pline p_lines=0
    while IFS= read -r _pline; do p_lines=$((p_lines + 1)); done <<< "${prompt%$'\n'}"
    (( p_lines < 1 )) && p_lines=1
    view_h=$(( rows - p_lines - 2 ))
    (( view_h < 1 )) && view_h=1
    if (( n_total < view_h )); then view_h=$n_total; fi
    if (( cur < view_top )); then view_top=$cur; fi
    if (( cur >= view_top + view_h )); then view_top=$(( cur - view_h + 1 )); fi
    printf '\033[H' >/dev/tty
    while IFS= read -r _pline; do
      printf '%s\033[K\n' "${_pline}" >/dev/tty
    done <<< "${prompt%$'\n'}"
    local i end=$(( view_top + view_h ))
    for (( i = view_top; i < end; i++ )); do
      local row_text
      if (( has_input && i == n )); then
        row_text="${input_label}${typed}"
      else
        row_text="${opts[$i]}"
      fi
      if (( i == cur )); then
        printf ' \033[7m▶ %s\033[0m\033[K\n' "${row_text}" >/dev/tty
      else
        printf '   %s\033[K\n' "${row_text}" >/dev/tty
      fi
    done
    if (( n_total > view_h )); then
      printf '  (%d / %d)\033[K\n' $(( cur + 1 )) "$n_total" >/dev/tty
    fi
    printf '\033[J' >/dev/tty
  }

  # Save tty state and switch to non-canonical mode so control bytes
  # (Ctrl+R/Ctrl+L for refresh, ^R reverse-search, etc.) reach our read
  # instead of being intercepted by the tty line discipline.
  local _saved_stty
  _saved_stty="$(stty -g </dev/tty 2>/dev/null || true)"
  stty -icanon -echo </dev/tty 2>/dev/null || true

  printf '\033[?1049h\033[?25l' >/dev/tty
  trap '_term_rows; winch=1' WINCH
  _draw

  while :; do
    if ! IFS= read -rsn1 k1 </dev/tty; then
      if (( winch )); then winch=0; _draw; continue; fi
      break
    fi
    # ESC sequences (arrow keys, function keys)
    if [[ "$k1" == $'\033' ]]; then
      if ! IFS= read -rsn2 -t 1 k2 </dev/tty; then k2=""; fi
      case "$k2" in
        '[A') (( cur = (cur - 1 + n_total) % n_total )) ;;
        '[B') (( cur = (cur + 1) % n_total )) ;;
        '[5') IFS= read -rsn1 -t 1 k3 </dev/tty || true
              (( cur -= view_h - 1 )); (( cur < 0 )) && cur=0 ;;
        '[6') IFS= read -rsn1 -t 1 k3 </dev/tty || true
              (( cur += view_h - 1 )); (( cur >= n_total )) && cur=$(( n_total - 1 )) ;;
        '[H'|'OH') cur=0 ;;
        '[F'|'OF') cur=$(( n_total - 1 )) ;;
        '') TUI_BACK=1; break ;;   # bare ESC: go back
      esac
      _draw
      continue
    fi
    # Enter
    if [[ -z "$k1" || "$k1" == $'\r' || "$k1" == $'\n' ]]; then
      if (( has_input && cur == n )); then
        if [[ -n "${typed}" ]] || (( had_default )); then
          TUI_INPUT="${typed}"
          break
        fi
        # empty input row Enter without default: ignore, keep waiting
      else
        TUI_INDEX=$cur
        break
      fi
      _draw
      continue
    fi
    # Backspace (DEL or BS)
    if [[ "$k1" == $'\x7f' || "$k1" == $'\b' ]]; then
      if (( has_input )); then
        cur=$n
        typed="${typed%?}"
      fi
      _draw
      continue
    fi
    # Ctrl+R or Ctrl+L: refresh status header and redraw
    if [[ "$k1" == $'\x12' || "$k1" == $'\x0c' ]]; then
      if declare -F _status_header >/dev/null 2>&1; then
        local _new_status
        _new_status="$(_status_header)"
        prompt="${_new_status}

${_prompt_body}"
      fi
      _draw
      continue
    fi
    # Other input
    if (( has_input )); then
      # Any other byte appends to typed text and jumps to input row.
      cur=$n
      typed+="${k1}"
    elif [[ "$k1" == "q" ]]; then
      TUI_CANCELLED=1; break   # only cancel-on-q when there's no input row
    fi
    _draw
  done

  trap - WINCH
  printf '\033[?25h\033[?1049l' >/dev/tty
  # Restore tty mode.
  [[ -n "${_saved_stty}" ]] && stty "${_saved_stty}" </dev/tty 2>/dev/null || true
  if (( INT_COUNT > pre_int )); then
    TUI_CANCELLED=1
    TUI_BACK=0
    printf '\n' >&2
  fi
}

# Pick a router MAC. Sets globals PICKED_MAC and PICKED_GW (both "" on cancel).
# Args: $1 = current router MAC (optional), $2 = current gateway IP (optional).
PICKED_MAC=""
PICKED_GW=""
pick_router_mac_into() {
  PICKED_MAC=""
  PICKED_GW=""
  local cur_mac="${1:-}"
  local cur_gw="${2:-}"
  local options=() option_macs=() option_gws=()
  local found_current=0

  while IFS=$'\t' read -r m g ls c; do
    [[ -z "${m}" ]] && continue
    local label="${m}  ${g}  ${ls}  ${c}x"
    [[ "${m}" == "${cur_mac}" ]] && { label="${m}  ${g}  ${ls}  ${c}x  ◀ 현재"; found_current=1; }
    options+=("${label}")
    option_macs+=("${m}")
    option_gws+=("${g}")
  done < <(python3 -c '
import json, os, sys
cfg, seen = sys.argv[1], sys.argv[2]
if not os.path.exists(seen): sys.exit(0)
try:
    with open(cfg) as f: registered = set(json.load(f).get("networks_by_router_mac", {}))
    with open(seen) as f: data = json.load(f).get("seen", {})
except Exception: sys.exit(0)
items = sorted([(m, i) for m, i in data.items() if m not in registered],
               key=lambda x: x[1].get("last_seen", ""), reverse=True)
for m, i in items:
    gw = i.get("gateway", "?")
    ls = i.get("last_seen", "?")
    ct = i.get("count", 1)
    print(f"{m}\t{gw}\t{ls}\t{ct}")
' "${CONFIG_FILE}" "${WIFI_DIR}/seen.json")

  if (( found_current == 0 )) && [[ -n "${cur_mac}" ]]; then
    if (( ${#options[@]} > 0 )); then
      options=("${cur_mac}  ${cur_gw}  ◀ 현재" "${options[@]}")
      option_macs=("${cur_mac}" "${option_macs[@]}")
      option_gws=("${cur_gw}" "${option_gws[@]}")
    else
      options+=("${cur_mac}  ${cur_gw}  ◀ 현재")
      option_macs+=("${cur_mac}")
      option_gws+=("${cur_gw}")
    fi
  fi

  tui_select_into \
    "라우터 MAC 선택 (↑↓ 이동, 타이핑 = 직접 입력, Enter 확정, ESC/Ctrl+C 취소):" \
    "직접 입력 > " \
    "" \
    "${options[@]+"${options[@]}"}"
  if [[ -n "${TUI_INPUT}" ]]; then
    local m
    m="$(normalize_mac "${TUI_INPUT}")"
    if [[ -z "${m}" ]]; then
      echo "  invalid MAC, cancelled"
      TUI_CANCELLED=1
      TUI_BACK=0
      return 0
    fi
    PICKED_MAC="${m}"
    PICKED_GW=""    # typed MAC: no associated gw → caller falls back to 192.168.1.1
  elif (( TUI_INDEX >= 0 )); then
    PICKED_MAC="${option_macs[$TUI_INDEX]}"
    PICKED_GW="${option_gws[$TUI_INDEX]}"
  fi
}

current_gateway() {
  route -n get default 2>/dev/null | awk '/gateway/{print $2; exit}'
}

current_router_mac() {
  local gw="$1"
  [[ -z "${gw}" ]] && return
  ping -c 1 -W 500 "${gw}" >/dev/null 2>&1 || true
  local raw
  raw="$(arp -n "${gw}" 2>/dev/null | sed -nE 's/.* at ([0-9a-fA-F:]+) on .*/\1/p' | head -1)"
  normalize_mac "${raw}"
}

if [[ ! -f "${CONFIG_FILE}" ]]; then
  cat > "${CONFIG_FILE}" <<'JSON'
{
  "version": 2,
  "wifi_service": "Wi-Fi",
  "networks_by_router_mac": {}
}
JSON
fi

# Migrate v1 (key=SSID) -> v2 (key=router MAC). Best-effort: fill MAC from
# current gateway if its router IP matches a v1 entry.
GW_NOW="$(current_gateway || true)"
MAC_NOW="$(current_router_mac "${GW_NOW}" || true)"
python3 - "${CONFIG_FILE}" "${GW_NOW:-}" "${MAC_NOW:-}" <<'PY'
import json, sys
path, gw, mac = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    c = json.load(f)
if c.get("version", 1) >= 2 and "networks_by_router_mac" in c:
    sys.exit(0)
old = c.get("networks", {})
new = {}
migrated, dropped = [], []
for ssid, n in old.items():
    if mac and n.get("router") == gw:
        new[mac] = {"label": ssid, "ip": n["ip"], "subnet": n["subnet"],
                    "router": n["router"], "dns": n.get("dns", [])}
        migrated.append(ssid)
    else:
        dropped.append(ssid)
c = {"version": 2, "wifi_service": c.get("wifi_service", "Wi-Fi"),
     "networks_by_router_mac": new}
with open(path, "w") as f:
    json.dump(c, f, indent=2, ensure_ascii=False)
if migrated:
    print(f"  migrated v1 entries: {', '.join(migrated)}")
if dropped:
    print(f"  dropped v1 entries (router MAC unknown): {', '.join(dropped)}")
PY

cp "${SWITCH_SRC}" "${SWITCH_DEST}"
chmod +x "${SWITCH_DEST}"
sed "s|__HOME__|${HOME}|g" "${PLIST_TEMPLATE}" > "${PLIST_DEST}"

add_network() {
  local label mac_in ip subnet router dns
  local gw mac gw_default ip_default
  gw="$(current_gateway || true)"
  mac="$(current_router_mac "${gw}" || true)"

  local last_label="" last_ip="" last_subnet="" last_router="" last_dns=""
  local step=1
  while :; do
    case "${step}" in
      1)
        tui_select_into \
          "[1/6] Label 입력 (표시용 이름 — Enter 확정, ESC 취소, Ctrl+C 종료):" \
          "Label > " "${last_label}"
        if (( TUI_CANCELLED )); then return 0; fi
        if (( TUI_BACK )); then return 0; fi
        if [[ -z "${TUI_INPUT}" ]]; then return 0; fi
        last_label="${TUI_INPUT}"
        label="${TUI_INPUT}"
        step=2
        ;;
      2)
        pick_router_mac_into "${mac}" "${gw}"
        if (( TUI_CANCELLED )); then return 0; fi
        if (( TUI_BACK )); then step=1; continue; fi
        if [[ -z "${PICKED_MAC}" ]]; then return 0; fi
        mac_in="${PICKED_MAC}"
        gw_default="${PICKED_GW:-192.168.1.1}"
        ip_default="$(printf '%s' "${gw_default}" | awk -F. 'NF==4 {print $1"."$2"."$3".100"}')"
        [[ -z "${ip_default}" ]] && ip_default="192.168.1.100"
        step=3
        ;;
      3)
        local def_ip="${last_ip:-$ip_default}"
        tui_select_into \
          "[3/6] IP 입력 (${label} @ ${mac_in} — Enter 확정, ESC 뒤로):" \
          "IP > " "${def_ip}"
        if (( TUI_CANCELLED )); then return 0; fi
        if (( TUI_BACK )); then step=2; continue; fi
        ip="${TUI_INPUT:-$def_ip}"
        last_ip="${ip}"
        step=4
        ;;
      4)
        local def_sub="${last_subnet:-255.255.255.0}"
        tui_select_into \
          "[4/6] Subnet mask 입력 (Enter 확정, ESC 뒤로):" \
          "Subnet > " "${def_sub}"
        if (( TUI_CANCELLED )); then return 0; fi
        if (( TUI_BACK )); then step=3; continue; fi
        subnet="${TUI_INPUT:-$def_sub}"
        last_subnet="${subnet}"
        step=5
        ;;
      5)
        local def_rt="${last_router:-$gw_default}"
        tui_select_into \
          "[5/6] Router/Gateway 입력 (Enter 확정, ESC 뒤로):" \
          "Router > " "${def_rt}"
        if (( TUI_CANCELLED )); then return 0; fi
        if (( TUI_BACK )); then step=4; continue; fi
        router="${TUI_INPUT:-$def_rt}"
        last_router="${router}"
        step=6
        ;;
      6)
        local def_dns="${last_dns:-8.8.8.8}"
        tui_select_into \
          "[6/6] DNS 입력 (콤마/스페이스 구분, 비우려면 backspace 후 Enter, ESC 뒤로):" \
          "DNS > " "${def_dns}"
        if (( TUI_CANCELLED )); then return 0; fi
        if (( TUI_BACK )); then step=5; continue; fi
        dns="${TUI_INPUT}"
        last_dns="${dns}"
        step=7
        ;;
      7)
        python3 - "${CONFIG_FILE}" "${label}" "${mac_in}" "${ip}" "${subnet}" "${router}" "${dns}" <<'PY'
import json, re, sys
path, label, mac, ip, mask, router, dns_in = sys.argv[1:8]
dns = [s for s in re.split(r'[,\s]+', dns_in.strip()) if s]
with open(path) as f:
    c = json.load(f)
c.setdefault("networks_by_router_mac", {})[mac] = {
    "label":  label,
    "ip":     ip,
    "subnet": mask,
    "router": router,
    "dns":    dns,
}
with open(path, "w") as f:
    json.dump(c, f, indent=2, ensure_ascii=False)
PY
        echo "  added '${label}' @ ${mac_in}"
        return 0
        ;;
    esac
  done
}

edit_network() {
  local mac="$1" label="$2"
  local cur_ip cur_sub cur_rt cur_dns
  {
    IFS= read -r cur_ip
    IFS= read -r cur_sub
    IFS= read -r cur_rt
    IFS= read -r cur_dns
  } < <(python3 -c '
import json, sys
c = json.load(open(sys.argv[1]))
n = c["networks_by_router_mac"][sys.argv[2]]
print(n.get("ip", ""))
print(n.get("subnet", ""))
print(n.get("router", ""))
print(",".join(n.get("dns", [])))
' "${CONFIG_FILE}" "${mac}")

  local ip="${cur_ip}" subnet="${cur_sub}" router="${cur_rt}" dns="${cur_dns}"
  local header="${label} @ ${mac} — 수정"
  local step=1
  while :; do
    case "${step}" in
      1)
        tui_select_into \
          "[1/4] ${header} / IP (Enter 확정, ESC 취소, Ctrl+C 종료):" \
          "IP > " "${ip}"
        if (( TUI_CANCELLED )); then return 0; fi
        if (( TUI_BACK )); then return 0; fi
        ip="${TUI_INPUT}"
        step=2
        ;;
      2)
        tui_select_into \
          "[2/4] ${header} / Subnet mask (Enter 확정, ESC 뒤로):" \
          "Subnet > " "${subnet}"
        if (( TUI_CANCELLED )); then return 0; fi
        if (( TUI_BACK )); then step=1; continue; fi
        subnet="${TUI_INPUT}"
        step=3
        ;;
      3)
        tui_select_into \
          "[3/4] ${header} / Router/Gateway (Enter 확정, ESC 뒤로):" \
          "Router > " "${router}"
        if (( TUI_CANCELLED )); then return 0; fi
        if (( TUI_BACK )); then step=2; continue; fi
        router="${TUI_INPUT}"
        step=4
        ;;
      4)
        tui_select_into \
          "[4/4] ${header} / DNS (콤마/스페이스 구분, 비우려면 backspace+Enter, ESC 뒤로):" \
          "DNS > " "${dns}"
        if (( TUI_CANCELLED )); then return 0; fi
        if (( TUI_BACK )); then step=3; continue; fi
        dns="${TUI_INPUT}"
        step=5
        ;;
      5) break ;;
    esac
  done

  python3 - "${CONFIG_FILE}" "${mac}" "${label}" "${ip}" "${subnet}" "${router}" "${dns}" <<'PY'
import json, re, sys
path, mac, label, ip, sub, rt, dns_in = sys.argv[1:8]
dns = [s for s in re.split(r'[,\s]+', dns_in.strip()) if s]
with open(path) as f:
    c = json.load(f)
nets = c.setdefault("networks_by_router_mac", {})
if mac not in nets:
    print(f"  '{mac}' not found", file=sys.stderr); sys.exit(1)
# Re-write with canonical key order: label, ip, subnet, router, dns.
nets[mac] = {
    "label":  label,
    "ip":     ip,
    "subnet": sub,
    "router": rt,
    "dns":    dns,
}
with open(path, "w") as f:
    json.dump(c, f, indent=2, ensure_ascii=False)
PY
  echo "  updated '${label}' @ ${mac}"
}

remove_network() {
  local mac="$1" label="$2"
  tui_select_into \
    "정말로 '${label}' (${mac}) 을 삭제할까요? (↑↓, Enter 확정, ESC 뒤로):" \
    "" \
    "" \
    "아니오 (취소)" \
    "예 (삭제)"
  if (( TUI_CANCELLED )) || (( TUI_BACK )) || (( TUI_INDEX != 1 )); then
    echo "  취소됨"
    return 0
  fi
  python3 - "${CONFIG_FILE}" "${mac}" <<'PY'
import json, sys
path, mac = sys.argv[1:3]
with open(path) as f: c = json.load(f)
nets = c.get("networks_by_router_mac", {})
if mac in nets:
    label = nets[mac].get("label", "?")
    del nets[mac]
    with open(path, "w") as f:
        json.dump(c, f, indent=2, ensure_ascii=False)
    print(f"  removed '{label}' @ {mac}")
PY
}

apply_config() {
  local mac="$1" label="$2"
  local ip subnet router dns_csv svc
  IFS=$'\t' read -r ip subnet router dns_csv svc < <(python3 -c '
import json, sys
c = json.load(open(sys.argv[1]))
n = c["networks_by_router_mac"][sys.argv[2]]
print("\t".join([n["ip"], n["subnet"], n["router"],
                 ",".join(n.get("dns", [])),
                 c.get("wifi_service", "Wi-Fi")]))
' "${CONFIG_FILE}" "${mac}")

  echo "  적용: ${label} → ${ip}/${subnet} gw=${router} (service: ${svc})"
  if ! networksetup -setmanual "${svc}" "${ip}" "${subnet}" "${router}"; then
    echo "  ERROR: setmanual 실패 — admin 권한이 필요할 수 있습니다"
    return 1
  fi
  if [[ -n "${dns_csv}" ]]; then
    # shellcheck disable=SC2086
    networksetup -setdnsservers "${svc}" ${dns_csv//,/ }
    echo "  ✓ DNS=${dns_csv}"
  else
    networksetup -setdnsservers "${svc}" empty
    echo "  ✓ DNS 비움"
  fi
  echo "  ✓ 적용 완료"
}

reset_dhcp() {
  local svc
  svc="$(python3 -c '
import json, sys
print(json.load(open(sys.argv[1])).get("wifi_service", "Wi-Fi"))
' "${CONFIG_FILE}")"
  echo "  Wi-Fi (${svc}) 를 DHCP 로 초기화"
  if ! networksetup -setdhcp "${svc}"; then
    echo "  ERROR: setdhcp 실패 — admin 권한이 필요할 수 있습니다"
    return 1
  fi
  networksetup -setdnsservers "${svc}" empty
  echo "  ✓ DHCP 적용, DNS 비움"
}

action_menu() {
  local mac="$1" label="$2"
  tui_select_into \
    "${label} @ ${mac} — 동작 선택 (↑↓, Enter 확정, ESC/Ctrl+C 취소):" \
    "" \
    "" \
    "이 설정 적용 (Wi-Fi 에 IP 반영)" \
    "수정 (IP 설정 변경)" \
    "삭제" \
    "취소"
  if (( TUI_INDEX < 0 )); then return 0; fi
  case "${TUI_INDEX}" in
    0) apply_config "${mac}" "${label}" || true ;;
    1) edit_network "${mac}" "${label}" || true ;;
    2) remove_network "${mac}" "${label}" || true ;;
    3) ;;
  esac
}

_status_header() {
  local svc="${1:-Wi-Fi}"
  local dev="${2:-en0}"
  local hw_mac ip gw gw_mac dns_servers cfg_mode arp_line
  cfg_mode="$(networksetup -getinfo "$svc" 2>/dev/null | head -1)"
  hw_mac="$(networksetup -getmacaddress "$svc" 2>/dev/null \
            | awk '/Ethernet Address:/ {print $3}')"
  ip="$(ifconfig "$dev" 2>/dev/null | awk '/inet / {print $2; exit}')"
  gw="$(route -n get default 2>/dev/null | awk '/gateway/ {print $2; exit}')"
  if [[ -n "${gw}" ]]; then
    arp_line="$(arp -n "${gw}" 2>/dev/null)"
    if [[ "${arp_line}" != *' at '* ]]; then
      ping -c 1 -W 200 "${gw}" >/dev/null 2>&1 || true
      arp_line="$(arp -n "${gw}" 2>/dev/null)"
    fi
    gw_mac="$(printf '%s' "${arp_line}" \
              | sed -nE 's/.* at ([0-9a-fA-F:]+) on .*/\1/p' | head -1)"
    gw_mac="$(normalize_mac "${gw_mac}")"
  fi
  dns_servers="$(networksetup -getdnsservers "$svc" 2>/dev/null \
                  | grep -v "^There aren" | tr '\n' ' ' | sed 's/ *$//')"
  printf '── 현재 노트북 네트워크 상태 ──\n'
  printf '  Mode: %s\n' "${cfg_mode:-?}"
  printf '  MAC : %s\n' "${hw_mac:-?}"
  printf '  IP  : %s\n' "${ip:-?}"
  printf '  GW  : %s  (router MAC: %s)\n' "${gw:-?}" "${gw_mac:-?}"
  printf '  DNS : %s\n' "${dns_servers:-(none)}"
  printf '────────────────────────────────'
}

main_tui_loop() {
  while :; do
    local entries=() entry_macs=() entry_labels=()
    while IFS=$'\t' read -r m label disp; do
      [[ -z "${m}" ]] && continue
      entries+=("${disp}")
      entry_macs+=("${m}")
      entry_labels+=("${label}")
    done < <(python3 -c '
import json, sys
c = json.load(open(sys.argv[1]))
for m, n in c.get("networks_by_router_mac", {}).items():
    label = n.get("label", "?")
    ip = n.get("ip", "")
    sub = n.get("subnet", "")
    rt = n.get("router", "")
    dns = ",".join(n.get("dns", [])) or "-"
    print(f"{m}\t{label}\t{label}  @ {m}  {ip}/{sub}  gw={rt}  dns={dns}")
' "${CONFIG_FILE}")

    local options=()
    if (( ${#entries[@]} > 0 )); then
      options=("${entries[@]}")
    fi
    local add_idx=${#options[@]}
    options+=("+ 새 네트워크 추가")
    local reset_idx=${#options[@]}
    options+=("↺ DHCP 로 초기화 (DNS 비움)")
    local quit_idx=${#options[@]}
    options+=("종료")

    tui_select_into \
      "Wi-Fi switch — 등록된 네트워크 (↑↓ 이동, Enter 선택, Ctrl+R 새로고침, ESC/Ctrl+C 종료):" \
      "" \
      "" \
      "${options[@]}"

    if (( TUI_INDEX < 0 )); then
      break
    fi
    INT_COUNT=0
    if (( TUI_INDEX == quit_idx )); then
      break
    elif (( TUI_INDEX == add_idx )); then
      add_network || true
    elif (( TUI_INDEX == reset_idx )); then
      reset_dhcp || true
    else
      action_menu "${entry_macs[$TUI_INDEX]}" "${entry_labels[$TUI_INDEX]}"
    fi
  done
}

reload_agent() {
  launchctl unload "${PLIST_DEST}" 2>/dev/null || true
  launchctl load -w "${PLIST_DEST}"
  echo "LaunchAgent loaded: $(basename "${PLIST_DEST}")"
}

echo "Wi-Fi switch installer (router-MAC matching)"
echo "  config:        ${CONFIG_FILE}"
echo "  switch script: ${SWITCH_DEST}"
echo "  LaunchAgent:   ${PLIST_DEST}"
echo

main_tui_loop

reload_agent

cat <<EOF

Done. Try it now:
  bash "${SWITCH_DEST}"
  tail -n 20 "${WIFI_DIR}/logs/wifi-switch.log"
  networksetup -getinfo "Wi-Fi"
EOF
