# echo

What the answers you are waiting for brought back, one line at a time, on ⌘⌥K.

It reads the state of the hourly checker (`~/.local/state/checker`): a headless follow-up that finished
something, or stopped on something that needs you. The menu bar shows how many lines wait; ⌘⌥K opens
them Spotlight-style.

| Key | Does |
|---|---|
| ← → | move through the lines, none is dropped |
| ↵ | resume the line's session in a terminal, and set the line aside |
| ↓ then ↵ | set the line aside as done, without opening it |
| S | the checks still waiting, and under them those done in the last 7 days; S again goes back to the lines |
| ⎋ | close |

At 0 it shows the last lines set aside, each with what came of it (one `claude -p` with no tool, kept).

## MCP

`echo mcp` is a stdio MCP server over the same files. It needs neither the app nor anything else to be running.

```sh
claude mcp add --scope user echo -- ~/Applications/echo.app/Contents/MacOS/echo mcp
```

| Tool | Does |
|---|---|
| `echo_lines` | the lines waiting (`past: true`: the ones set aside) |
| `echo_checks` | every awaited answer and when the checker last ran |
| `echo_set_aside` | set one waiting line aside as done |

## Checking it without a window

`echo --render out.png` draws the panel offscreen (also `out-asking.png`, `-empty`, `-checks`, `-past`).
