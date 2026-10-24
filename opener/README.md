# opener

Spotlight for apps only, on ⌥Space. Type a few letters of an app, ↵ opens it.

![opener](docs/opener.png)

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

⌥Space and not ⌘Space: Raycast holds ⌘Space while it runs. The chord is in `Sources/opener/main.swift`.

```sh
./install.sh   # builds, runs the self-test, copies to ~/Applications, starts at login
```

`opener --selftest` checks the ranking and the keys; `opener --render out.png [query] [--dark]` draws the panel
offscreen.
