#!/bin/bash
set -u

WIFI_DIR="${HOME}/.wifi"
CONFIG_FILE="${WIFI_DIR}/config.json"
LOG_FILE="${WIFI_DIR}/logs/wifi-switch.log"

mkdir -p "${WIFI_DIR}/logs"

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "${LOG_FILE}"
}

normalize_mac() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | awk -F: '
    NF==6 {
      out=""
      for (i=1;i<=NF;i++) { v=$i; if (length(v)==1) v="0"v; out = out (i>1?":":"") v }
      print out
    }'
}

if [[ ! -f "${CONFIG_FILE}" ]]; then
  log "config.json not found at ${CONFIG_FILE}"
  exit 0
fi

WIFI_SERVICE="$(python3 -c '
import json, sys
print(json.load(open(sys.argv[1])).get("wifi_service", "Wi-Fi"))
' "${CONFIG_FILE}")"

probe_router() {
  local gw raw mac
  gw="$(route -n get default 2>/dev/null | awk '/gateway/{print $2; exit}')"
  [[ -z "${gw}" ]] && return 1
  ping -c 1 -W 500 "${gw}" >/dev/null 2>&1 || true
  raw="$(arp -n "${gw}" 2>/dev/null | sed -nE 's/.* at ([0-9a-fA-F:]+) on .*/\1/p' | head -1)"
  mac="$(normalize_mac "${raw}")"
  [[ -z "${mac}" ]] && return 1
  GATEWAY="${gw}"
  ROUTER_MAC="${mac}"
  return 0
}

GATEWAY=""
ROUTER_MAC=""
# First pass: see if current config can reach a gateway.
for delay in 0 2 3; do
  [[ "${delay}" -gt 0 ]] && sleep "${delay}"
  if probe_router; then break; fi
done

# If still nothing, current Manual config may be stale (old gateway unreachable
# on the new SSID). Bounce to DHCP so the new network's gateway can be found,
# then probe again — the lookup below decides whether to re-apply Manual.
if [[ -z "${ROUTER_MAC}" ]]; then
  log "no router MAC visible — bouncing DHCP to refresh, then re-probing"
  networksetup -setdhcp "${WIFI_SERVICE}" >> "${LOG_FILE}" 2>&1 || true
  for delay in 2 3 5; do
    sleep "${delay}"
    if probe_router; then break; fi
  done
fi

if [[ -z "${ROUTER_MAC}" ]]; then
  log "no router MAC after DHCP bounce; skipping"
  exit 0
fi

python3 - "${WIFI_DIR}/seen.json" "${ROUTER_MAC}" "${GATEWAY}" <<'PY' 2>/dev/null || true
import json, os, sys
from datetime import datetime
path, mac, gw = sys.argv[1], sys.argv[2], sys.argv[3]
data = {"version": 1, "seen": {}}
if os.path.exists(path):
    try:
        with open(path) as f:
            data = json.load(f)
    except Exception:
        pass
seen = data.setdefault("seen", {})
now = datetime.now().isoformat(timespec="seconds")
e = seen.get(mac, {"first_seen": now, "count": 0})
e["gateway"] = gw
e["last_seen"] = now
e["count"] = e.get("count", 0) + 1
seen[mac] = e
with open(path, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
PY

ENTRY="$(python3 -c '
import json, sys
c = json.load(open(sys.argv[1]))
mac = sys.argv[2]
n = c.get("networks_by_router_mac", {}).get(mac)
if n is None:
    sys.exit(0)
print("|".join([
    n.get("label", ""),
    n["ip"], n["subnet"], n["router"],
    ",".join(n.get("dns", [])),
]))
' "${CONFIG_FILE}" "${ROUTER_MAC}")"

if [[ -n "${ENTRY}" ]]; then
  IFS='|' read -r LABEL IP MASK ROUTER DNS_CSV <<< "${ENTRY}"
  log "match label='${LABEL}' router_mac=${ROUTER_MAC} -> static ${IP}/${MASK} gw=${ROUTER}"
  if ! networksetup -setmanual "${WIFI_SERVICE}" "${IP}" "${MASK}" "${ROUTER}" >> "${LOG_FILE}" 2>&1; then
    log "ERROR: setmanual failed (admin privileges may be required)"
    exit 1
  fi
  if [[ -n "${DNS_CSV}" ]]; then
    # shellcheck disable=SC2086
    networksetup -setdnsservers "${WIFI_SERVICE}" ${DNS_CSV//,/ } >> "${LOG_FILE}" 2>&1
    log "DNS=${DNS_CSV}"
  else
    networksetup -setdnsservers "${WIFI_SERVICE}" empty >> "${LOG_FILE}" 2>&1
  fi
else
  log "no match router_mac=${ROUTER_MAC} gw=${GATEWAY} -> DHCP"
  networksetup -setdhcp "${WIFI_SERVICE}" >> "${LOG_FILE}" 2>&1
  networksetup -setdnsservers "${WIFI_SERVICE}" empty >> "${LOG_FILE}" 2>&1
fi
