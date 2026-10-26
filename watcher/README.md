# watcher

What the answers you are waiting for brought back, one line at a time, on ⌘⌥K.

![⌘⌥K over a desktop with 3 in the menu bar: the panel fades in on the first of three lines; → shows the next and ← comes back; ↓ asks to set the line aside and ↵ does it, the count dropping to 2; S shows the watch list, the checks still watched and those done this week, each with the logo of what it reads; S again goes back, esc closes, and a new line brings the count back to 3](docs/demo.gif)

It reads the state of the hourly checker (`~/.local/state/checker`): a headless follow-up that finished
something, or stopped on something that needs you. The menu bar shows how many lines wait; ⌘⌥K opens
them Spotlight-style.

![The panel: one line waiting, its subject, what the follow-up left, its age, and the buttons to move, open, set aside](docs/panel.png)

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
`docs/make-demo.sh` draws the GIF above again: the app renders each frame offscreen (`--render-demo`), on
made-up lines and checks over a stock wallpaper, and ffmpeg puts them together.
