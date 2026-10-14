#!/usr/bin/env bash
# One-shot setup. Safe to rerun. Never rebuilds ClaudeJump.app once it exists (see README).
set -euo pipefail
cd "$(dirname "$0")"
for cmd in swiftc jq code zip; do
    command -v "$cmd" >/dev/null || { echo "need $cmd on PATH"; exit 1; }
done

./build.sh
[ -d ClaudeJump.app ] || ./build-jump.sh
./vscode-ext/build-vsix.sh
code --install-extension claude-waiting-focus.vsix --force >/dev/null 2>&1 || true

# Claude Code hooks: drop older entries for this hook, then add the current ones.
S="$HOME/.claude/settings.json"
[ -f "$S" ] || echo '{}' > "$S"
cp "$S" "$S.bak-waiting"
jq --arg h "$PWD/hook" '
  def entry($event; $matcher):
    {hooks: [{type: "command", command: ($h + " " + $event)}]}
    + (if $matcher then {matcher: $matcher} else {} end);
  .hooks //= {}
  | .hooks |= with_entries(.value |= map(select((.hooks[0].command // "") | test("claude-waiting") | not)))
  | .hooks.SessionStart     += [entry("start"; null)]
  | .hooks.UserPromptSubmit += [entry("prompt"; null)]
  | .hooks.Stop             += [entry("stop"; null)]
  | .hooks.Notification     += [entry("notify"; null)]
  | .hooks.SessionEnd       += [entry("end"; null)]
  | .hooks.PreToolUse       += [entry("question"; "AskUserQuestion")]
  | .hooks.PostToolUse      += [entry("answered"; "AskUserQuestion")]
  | .env.CLAUDE_CODE_DISABLE_TERMINAL_TITLE = "1"
' "$S" > "$S.tmp" && mv "$S.tmp" "$S"

# VS Code: show the tab's own title as the description so the hook's "#sNNN" id stays visible.
V="$HOME/Library/Application Support/Code/User/settings.json"
if [ -f "$V" ] && jq -e . "$V" >/dev/null 2>&1; then
    cp "$V" "$V.bak-waiting"
    jq '."terminal.integrated.tabs.title" = "${process}" | ."terminal.integrated.tabs.description" = "${sequence}"' \
        "$V" > "$V.tmp" && mv "$V.tmp" "$V"
else
    echo 'VS Code settings.json has comments or is missing; add by hand:'
    echo '  "terminal.integrated.tabs.title": "${process}",'
    echo '  "terminal.integrated.tabs.description": "${sequence}"'
fi

cat <<MSG

Installed. Three things to do by hand:
  1. System Settings > Privacy & Security > Accessibility: add $PWD/ClaudeJump.app
     (only needed for iTerm2 / Terminal.app jumps)
  2. Reload every open VS Code window (Cmd+Shift+P > "Reload Window")
  3. Restart your Claude Code sessions so they pick up the hooks
MSG
