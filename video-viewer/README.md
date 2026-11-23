# Video Viewer

One window for images, videos, GIFs, music and PDFs: load many, switch with the arrows, change the playback speed.

![Video Viewer: the sidebar of opened files beside a video and its playback bar](docs/screenshot.png)

Files opened from Finder, with `open` or dropped on the window join the list of the one window. A folder adds the media files inside it.

Laid out like Notes: the sidebar lists the files open in the window, in the order they were opened, with a thumbnail, the duration, pixel size or page count, and the search field filters them by name. A video, GIF or song gets a bar over its bottom with slower, play, faster, its speed and a seek slider; the toolbar holds the volume and Reveal in Finder buttons. A file open alone folds the sidebar away (the toolbar's sidebar button brings it back) and the window takes the file's shape, a portrait video a portrait window; a list keeps the viewer 16:9.

| In the app | Anywhere | Does |
|---|---|---|
| ↑ / ↓ | ⌃⌥↑ / ⌃⌥↓ | Previous / next item, in the list's order |
| ← / → | ⌃⌥← / ⌃⌥→ | Slower / faster video or GIF (0.25× to 4×); previous / next PDF page |
| Space | ⌃⌥Space | Play / pause |
| ⌥↑ / ⌥↓ | ⌃⌥⇧↑ / ⌃⌥⇧↓ | Volume |
| ⌥← / ⌥→ | ⌃⌥⇧← / ⌃⌥⇧→ | Jump to start / end |
| ⇧← / ⇧→ | | Back / forward 5 s |
| ⌘+ / ⌘- | | Zoom an image or PDF (pinch works too) |
| ⌫ | | Remove the item from the list |
| F | | Full screen |
| Esc | | Hide / show the playback bar |
| ⌘, | | Settings: the file kinds it opens, and which app opens each by default |

Videos play through AVFoundation, so formats macOS cannot decode (WebM, MKV) show a crossed-out play button.

## Install

```sh
./install.sh
```
