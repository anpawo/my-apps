# watcher

What the answers you are waiting for brought back, one line at a time, on ⌘⌥K.

It reads the state of the hourly checker (`~/.local/state/checker`): a headless follow-up that finished
something, or stopped on something that needs you. The menu bar shows how many lines wait; ⌘⌥K opens
them Spotlight-style.

| Key | Does |
|---|---|
| ← → | move through the lines, none is dropped |
| ↵ | resume the line's session in a terminal, and set the line aside |
| ↓ then ↵ | set the line aside as done, without opening it |
| S | the watch list: the checks still watched, and under them those done in the last 7 days (newest first: the pointer on one shows Add back, which brings back the line its follow-up left, set aside or not, shown and ↵ away from its session; a check that left none is watched again from now, and stays listed here); S again goes back to the lines, or closes Watcher when none waits |
| ⎋ | close |

With no line waiting, ⌘⌥K opens on the watch list.

## Checking it without a window

`watcher --render out.png` draws the panel offscreen (also `out-asking.png`, `-empty`, `-checks`).
