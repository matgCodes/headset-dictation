#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PLIST_NAME="com.user.headsetdictation.plist"
TARGET_DIR="${HOME}/Library/LaunchAgents"
TARGET_PLIST="${TARGET_DIR}/${PLIST_NAME}"

"${SCRIPT_DIR}/build.sh"

mkdir -p "${TARGET_DIR}"

# Update binary path in plist to absolute root path if needed
sed "s|/Users/mag_station/Dev_Tools/headset-dictation/HeadsetDictation.app/Contents/MacOS/headset_dictation|${ROOT_DIR}/HeadsetDictation.app/Contents/MacOS/headset_dictation|g" \
    "${ROOT_DIR}/launchd/${PLIST_NAME}" > "${TARGET_PLIST}"

echo "==> Unloading any existing daemon..."
launchctl unload "${TARGET_PLIST}" 2>/dev/null || true

echo "==> Loading LaunchAgent: ${TARGET_PLIST}"
launchctl load -w "${TARGET_PLIST}"

echo "==> Daemon successfully installed and started!"
echo "==> Log file: /tmp/headset_dictation.log"
