#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "==> Compiling headset_dictation (Swift with optimizations)..."
mkdir -p "${ROOT_DIR}/HeadsetDictation.app/Contents/MacOS"

cat << 'EOF' > "${ROOT_DIR}/HeadsetDictation.app/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.user.headsetdictation</string>
    <key>CFBundleName</key>
    <string>Headset Dictation</string>
    <key>CFBundleExecutable</key>
    <string>headset_dictation</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF

swiftc -O -o "${ROOT_DIR}/HeadsetDictation.app/Contents/MacOS/headset_dictation" "${ROOT_DIR}/dictation_listener.swift"
cp "${ROOT_DIR}/HeadsetDictation.app/Contents/MacOS/headset_dictation" "${ROOT_DIR}/headset_dictation"
codesign --force --deep -s - "${ROOT_DIR}/HeadsetDictation.app"
echo "==> Build successful: ${ROOT_DIR}/HeadsetDictation.app"
