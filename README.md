# Claude Waiting

A small macOS widget in the top-left corner that lists every Claude Code session waiting on you,
with a button that jumps to the exact chat. Works for sessions in VS Code terminals, iTerm2,
Terminal.app and the Claude desktop app.

A card appears when a session asks a question, needs a permission, or has been idle for a minute
after finishing. It plays a sound on arrival. ✕ dismisses it. The arrow button opens the chat.

## Install

Needs Xcode command line tools, `jq`, and the `code` CLI.

```sh
git clone https://github.com/nishanth-augustai/claude-waiting.git ~/claude-waiting-widget
~/claude-waiting-widget/install.sh
```

Then do the three steps the script prints: grant Accessibility to `ClaudeJump.app`, reload your
VS Code windows, and restart your Claude sessions.

## How it works

```
Claude Code hook (hook) ──writes──> ~/.claude-waiting/<session>.json
                                          │
ClaudeWaiting.app (main.swift) ──polls──┘   shows a card per file, oldest first
         │
         │ "Open"
         ├── VS Code:     asks every VS Code window (vscode-ext, local http) "who owns tty X?"
         ├── iTerm2 /     launches ClaudeJump.app, which runs jump-*.applescript
         │   Terminal:    to select the tab on that tty
         └── Claude app:  opens claude://code/continue?session=<app id>
```

- `hook` runs on SessionStart, UserPromptSubmit, Stop, Notification, SessionEnd and around
  AskUserQuestion. It records the session's tty, folder, name and why it is waiting, and sets the
  terminal title to `✅ name #sNNN` so you can spot the tab by eye too.
- `main.swift` is the widget. Built by `build.sh`, which also registers it with launchd so it is
  always running. Rebuild as often as you like.
- `jump.swift` is `ClaudeJump.app`: a tiny app that runs an AppleScript with Accessibility rights.
  macOS ties that grant to the app's signature, so **never rerun `build-jump.sh`** on a machine
  where it already works. The scripts it runs are passed as arguments, so it never needs changing.
- `vscode-ext/` is a VS Code extension. Each window listens on a random local port and writes it
  to `~/.claude-waiting/vscode/`. The widget asks each port to focus the terminal with a given tty.
  Quick Open and tab titles were too fragile; this is exact.
- `art/` holds the card header images and the open icon.

## Tuning

Top of `main.swift`: `SHOW_AFTER_SECONDS` (delay before a finished turn shows), `WIDTH`, `SOUND`
(any name from /System/Library/Sounds). Rerun `build.sh` after changing.

## Debugging

- `~/.claude-waiting/hook.log`: one line per hook call.
- `~/.claude-waiting/open.log`: what ClaudeJump ran and what the script returned.
- `CLAUDE_WAITING_DEBUG=1 ClaudeWaiting.app/Contents/MacOS/ClaudeWaiting` prints the rows it sees.
- Open goes to a new VS Code terminal: the window has not loaded the extension yet. Reload it.
- "osascript is not allowed to send keystrokes": ClaudeJump lost its Accessibility grant. Remove
  and re-add it in System Settings.
