# opener

Spotlight for apps only, on ⌘Space. Type a few letters of an app, ↵ opens it.

![⌘Space over a desktop: the panel opens empty, typing "saf" narrows the list to Safari and ↵ opens it; ⌘Space again over Safari, "te" lists Terminal then TextEdit, ↓ moves to TextEdit and ↵ opens it](docs/demo.gif)

It reads the app folders (`/Applications`, `/System/Applications`, their `Utilities`, `~/Applications`) each
time it opens, not Spotlight's index: it works with indexing turned off, and an app installed a minute ago is
already there. No file, contact or web result, no settings.

| Key | Does |
|---|---|
| letters | match the start of a name, then the start of a word, the initials (`vsc`), anywhere, the letters in order; the apps opened most often from here come first |
| ↑ ↓ | move through the matches |
| ↵ | open the app |
| ⌫, ⌘⌫ | take a letter, take them all |
| ⎋ | close (a click elsewhere too) |

![opener](docs/opener.png)

⌘E, from any app, opens a Finder window on the home folder (a Windows habit, Win+E). It was Spotlight's
"Show Finder search window", gone with the Spotlight agent. ⌥⌘F brings up Firefox, starting it if needed, and
⌥⌘T always opens a new Ghostty window: Raycast's app hotkeys, until it was uninstalled.

⌘Space works only while Spotlight's own shortcut is off (System Settings → Keyboard → Keyboard Shortcuts →
Spotlight). The chords are in `Sources/opener/main.swift`.

```sh
./install.sh   # builds, runs the self-test, copies to ~/Applications, starts at login
```

`opener --selftest` checks the ranking and the keys; `opener --render out.png [query] [--dark]` draws the panel
offscreen. `docs/make-demo.sh` draws the GIF again: the app renders each frame offscreen (`--render-demo`), on the
apps every Mac has, and ffmpeg puts them together.
