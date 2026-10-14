#!/usr/bin/env bash
# Builds ClaudeJump.app. Do NOT rerun casually: every rebuild revokes its Accessibility grant.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p ClaudeJump.app/Contents/MacOS
cp Jump-Info.plist ClaudeJump.app/Contents/Info.plist
swiftc -O jump.swift -o ClaudeJump.app/Contents/MacOS/ClaudeJump
codesign --force --sign - ClaudeJump.app >/dev/null 2>&1 || true
echo built
