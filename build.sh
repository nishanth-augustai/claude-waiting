#!/usr/bin/env bash
# Builds ClaudeWaiting.app and (re)starts it under launchd so it is always running.
set -euo pipefail
cd "$(dirname "$0")"
APP=ClaudeWaiting.app
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources" && cp art/* "$APP/Contents/Resources/"
swiftc -O main.swift -o "$APP/Contents/MacOS/ClaudeWaiting"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

PLIST="$HOME/Library/LaunchAgents/com.nishanth.claude-waiting.plist"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>Label</key><string>com.nishanth.claude-waiting</string>
    <key>ProgramArguments</key><array><string>$PWD/$APP/Contents/MacOS/ClaudeWaiting</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ProcessType</key><string>Interactive</string>
</dict></plist>
PL
launchctl bootout "gui/$(id -u)/com.nishanth.claude-waiting" 2>/dev/null || true
# bootout returns before the old job is gone; bootstrap fails if it is still there
until ! launchctl print "gui/$(id -u)/com.nishanth.claude-waiting" >/dev/null 2>&1; do sleep 0.2; done
launchctl bootstrap "gui/$(id -u)" "$PLIST"
sleep 1
echo "ClaudeWaiting running (pid $(pgrep -f ClaudeWaiting.app/Contents/MacOS/ClaudeWaiting | head -1))"
