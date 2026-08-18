#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "==> Compiling headset_dictation (Swift with optimizations)..."
swiftc -O -o "${ROOT_DIR}/headset_dictation" "${ROOT_DIR}/dictation_listener.swift"
echo "==> Build successful: ${ROOT_DIR}/headset_dictation"
