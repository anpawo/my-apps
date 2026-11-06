# vcx

Vibe Code X: a native macOS window for Claude Code, Codex and Qwen sessions, one window per session.

![A prompt typed into an empty Vibe Code X window and sent with ↵: it flies into the chat, Claude's actions fold into one block that counts them as they run, a question card asks which button style to use and 1 picks the first option, then the answer comes back with its green summary, the orange Done line and the blue Next line; / opens the command palette, /model lists Claude, Codex and Qwen, and esc closes it](docs/demo.gif)

`vcx` in a terminal opens a window on the current folder; `vcx --resume` picks a past conversation back up. Each
window drives the agent's own CLI (`claude -p` in stream-json, `codex app-server`), so its hooks, skills, MCP servers
and instruction files apply as they do in the terminal; the sidebar lists them.

- **Work stays folded.** An answer's actions and notes fold into one block above its last message; a click opens it.
- **Questions in the composer.** A question card replaces the input; a number key picks an option, or type your own.
- **Every provider, one palette.** `/model` switches between Claude, Codex and Qwen, then the model and effort.
  When an account hits its usage limit, the turn carries on with the next enabled account, context included.
- **Images and pastes as chips.** A pasted picture stays a compact card that previews on click; a long paste folds
  into a `[Paste #N]` chip.
- **Sessions outlive updates.** `vcx --update-now` moves every running window to the installed build once its turn
  ends, without restarting its agent.
- **Fleet sees it.** Each window reports its state to [Fleet](../fleet), which shows when it needs you.

`vcx -p "<prompt>"` runs a background job with no window and the same fallback (`--provider auto|claude|codex|qwen`,
`--output-format text|json|stream-json`).

## Install

`./install-native.py` builds the app into `~/Applications/Vibe Code X.app` and writes the `vcx` and `cx`
commands into `~/.local/bin`.

To keep it current, copy `mac.vcx-update.plist` into `~/Library/LaunchAgents`: on every push from this checkout
and every 10 minutes, `auto-update.sh` installs the latest `vcx/` from `main`, from a worktree of its own.
Open windows move to the new build on their own. Log: `~/.local/state/mac.vcx-update.log`.

## Checking it without a window

`vcx --render <dir>` draws the conversation, palettes, questions and popups offscreen. `docs/make-demo.sh` draws
the GIF above again: the app renders each frame offscreen (`--render-demo`) on a made-up session, and ffmpeg puts
them together.
