#!/usr/bin/env bash
# Builds ClaudeWaiting.app and (re)starts it under launchd so it is always running. Under CI it only builds.
set -euo pipefail
cd "$(dirname "$0")"
APP=ClaudeWaiting.app
R="$APP/Contents/Resources"
mkdir -p "$APP/Contents/MacOS" "$R" "$APP/Contents/Helpers"
cp Info.plist "$APP/Contents/Info.plist"
./vscode-ext/build-vsix.sh >/dev/null
# Everything a downloaded copy needs to set itself up lives inside the bundle.
cp art/* hook jump-iterm.applescript jump-terminal.applescript claude-waiting-focus.vsix "$R/"
if [ -d ClaudeJump.app ]; then rm -rf "$APP/Contents/Helpers/ClaudeJump.app"; cp -R ClaudeJump.app "$APP/Contents/Helpers/"; fi
swiftc -O main.swift -o "$APP/Contents/MacOS/ClaudeWaiting"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
if [ -n "${CI:-}" ]; then echo "built $APP"; exit 0; fi

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
