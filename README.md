# Claude Waiting

A small macOS widget in the top-left corner that lists every Claude Code session waiting on you,
with a button that jumps to the exact chat. Works for sessions in VS Code terminals, iTerm2,
Terminal.app and the Claude desktop app.

A card appears when a session asks a question, needs a permission, or has been idle for a minute
after finishing. It plays a sound on arrival. ✕ dismisses it. The arrow button opens the chat.

## Install (download)

1. Grab `ClaudeWaiting.zip` from the [latest release](https://github.com/nishanth-augustai/claude-waiting/releases/latest), unzip, drop the app in Applications.
2. First open: right-click the app › Open (it is not notarized, so macOS asks once).
3. The app offers to set itself up. Say Install. That adds the Claude Code hooks to `~/.claude/settings.json` and installs the VS Code extension. Then restart your Claude sessions and reload VS Code windows.
4. Optional, for iTerm2 / Terminal.app jumps: System Settings › Privacy & Security › Accessibility › add `ClaudeWaiting.app/Contents/Helpers/ClaudeJump.app`.

Needs macOS 13+ and `jq` (built into macOS 15; otherwise `brew install jq`).

A bell icon appears in the menu bar. From there: card style (Default, Compact, Art), thin or bold
outline, outline colour, start at login, re-run setup, quit.

## Install (from source)

Needs Xcode command line tools, `jq`, and the `code` CLI.

```sh
git clone https://github.com/nishanth-augustai/claude-waiting.git ~/claude-waiting-widget
~/claude-waiting-widget/install.sh
```

Then do the three steps the script prints: grant Accessibility to `ClaudeJump.app`, reload your
VS Code windows, and restart your Claude sessions.

## Card styles

- **Default**: minutes first, status beside it, chat name · folder, one line of the last output. Hover unfolds the output and shows ✕ and Open.
- **Compact**: one line per session (dot · name · folder · time) plus the output. Hover unfolds it and adds the buttons. Half the height.
- **Art**: a picture header per source (blue VS Code, orange Claude app, red terminal) with a folder tab. Buttons always visible.

Hover never pushes the cards below; the unfolded card draws over them.

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
- `main.swift` is the widget. Built by `build.sh`, which bundles the hook, scripts, extension and
  ClaudeJump inside the app and registers it with launchd. Rebuild as often as you like.
- `.github/workflows/release.yml` builds the app on a tag push (`v*`) and attaches `ClaudeWaiting.zip`
  to a GitHub release.
- `jump.swift` is `ClaudeJump.app`: a tiny app that runs an AppleScript with Accessibility rights.
  macOS ties that grant to the app's signature, so **never rerun `build-jump.sh`** on a machine
  where it already works. The scripts it runs are passed as arguments, so it never needs changing.
- `vscode-ext/` is a VS Code extension. Each window listens on a random local port and writes it
  to `~/.claude-waiting/vscode/`. The widget asks each port to focus the terminal with a given tty.
  Quick Open and tab titles were too fragile; this is exact.
- `art/` holds the card header images and the open icon.

## Tuning

Menu bar icon for style and outline. Top of `main.swift` for `SHOW_AFTER_SECONDS` (delay before a
finished turn shows), `WIDTH`, `SOUND` (any name from /System/Library/Sounds). Rerun `build.sh` after changing.

## Debugging

- `~/.claude-waiting/hook.log`: one line per hook call.
- `~/.claude-waiting/open.log`: what ClaudeJump ran and what the script returned.
- `CLAUDE_WAITING_DEBUG=1 ClaudeWaiting.app/Contents/MacOS/ClaudeWaiting` prints the rows it sees.
- Open goes to a new VS Code terminal: the window has not loaded the extension yet. Reload it.
- "osascript is not allowed to send keystrokes": ClaudeJump lost its Accessibility grant. Remove
  and re-add it in System Settings.
