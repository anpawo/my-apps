# Viewer

One window for images, videos, GIFs and PDFs: load many, switch with the arrows, change the playback speed.

![Viewer: a sidebar of loaded files beside the GIF being played](docs/screenshot.png)

Files opened from Finder, with `open` or dropped on the window join the list of the one window. A folder adds the media files inside it.

| In the app | Anywhere | Does |
|---|---|---|
| ↑ / ↓ | ⌃⌥↑ / ⌃⌥↓ | Previous / next item |
| ← / → | ⌃⌥← / ⌃⌥→ | Slower / faster video or GIF (0.25× to 4×); previous / next PDF page |
| Space | ⌃⌥Space | Play / pause |
| ⌥↑ / ⌥↓ | ⌃⌥⇧↑ / ⌃⌥⇧↓ | Volume |
| ⌥← / ⌥→ | ⌃⌥⇧← / ⌃⌥⇧→ | Jump to start / end |
| ⇧← / ⇧→ | | Back / forward 5 s |
| ⌘+ / ⌘- | | Zoom an image or PDF (pinch works too) |
| ⌫ | | Remove the item from the list |
| F | | Full screen |

Videos play through AVFoundation, so formats macOS cannot decode (WebM, MKV) show a crossed-out play button.

## Install

```sh
./install.sh
```
