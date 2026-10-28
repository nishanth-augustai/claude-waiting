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
# Registering the agent again would make macOS announce a new "background item" every build, so only
# register when it is missing; otherwise just restart the running job.
if launchctl print "gui/$(id -u)/com.nishanth.claude-waiting" >/dev/null 2>&1; then
    launchctl kickstart -k "gui/$(id -u)/com.nishanth.claude-waiting"
else
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
fi
sleep 1
echo "ClaudeWaiting running (pid $(pgrep -f ClaudeWaiting.app/Contents/MacOS/ClaudeWaiting | head -1))"
