#!/bin/bash
set -u

PLIST="${HOME}/Library/LaunchAgents/com.user.wifi-switch.plist"
WIFI_DIR="${HOME}/.wifi"
WIFI_DEVICE="$(networksetup -listallhardwareports \
  | awk '/Hardware Port: Wi-Fi/{getline; print $2; exit}')"

if [[ -f "${PLIST}" ]]; then
  launchctl unload "${PLIST}" 2>/dev/null || true
  rm -f "${PLIST}"
  echo "removed LaunchAgent: ${PLIST}"
else
  echo "no LaunchAgent at ${PLIST}"
fi

if [[ -n "${WIFI_DEVICE}" ]]; then
  WIFI_SERVICE="Wi-Fi"
  if [[ -f "${WIFI_DIR}/config.json" ]]; then
    WIFI_SERVICE="$(python3 -c '
import json, sys
print(json.load(open(sys.argv[1])).get("wifi_service", "Wi-Fi"))
' "${WIFI_DIR}/config.json")"
  fi
  networksetup -setdhcp "${WIFI_SERVICE}" || true
  networksetup -setdnsservers "${WIFI_SERVICE}" empty || true
  echo "restored ${WIFI_SERVICE} to DHCP"
fi

echo "config preserved at ${WIFI_DIR}"
echo "to fully remove, run: rm -rf '${WIFI_DIR}'"
