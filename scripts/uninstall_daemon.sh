#!/usr/bin/env bash
set -euo pipefail

PLIST_NAME="com.user.headsetdictation.plist"
TARGET_PLIST="${HOME}/Library/LaunchAgents/${PLIST_NAME}"

if [ -f "${TARGET_PLIST}" ]; then
    echo "==> Unloading LaunchAgent..."
    launchctl unload "${TARGET_PLIST}" 2>/dev/null || true
    rm -f "${TARGET_PLIST}"
    echo "==> Removed ${TARGET_PLIST}"
    echo "==> Daemon successfully uninstalled."
else
    echo "==> LaunchAgent not found at ${TARGET_PLIST}"
fi
