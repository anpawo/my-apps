# copilot

Ask about what is on the screen, on ⌥Space. With nothing typed, ↵ works out what you need from the screen: the
fix for the error, the reply to the message, the answer to the exercise.

![⌥Space over a terminal where a Python script failed: the panel opens at the top, ↵ with nothing typed, and Claude explains that the CSV is semicolon-separated and gives the fixed line; a follow-up typed in French, "et si le fichier est vide ?", gets its answer in French; ⌘C copies its code and ⎋ closes the panel](docs/demo.gif)

⌥Space takes a screenshot of the display under the mouse (the panel left out) and starts `claude`; ↵ sends the
screenshot and the question to Claude Opus through Claude Code, on the subscription it is logged in with: no API
key. The first words come 1.5 to 3 s after ↵. Follow-ups go to the same process, which remembers the screen;
⎋ ends it. The screenshot stays in memory and no transcript is kept; the `claude` process takes about 150 MB while
the panel is up, nothing otherwise.

The panel stays up while you click in the app behind; ⌥Space there takes a new screenshot for the next question,
⌥Space in the panel closes it. Screen shares and recordings leave it out (`sharingType = .none`), as far as
macOS still honours that: since 15.4 not every capture tool does.

| Key | Does |
|---|---|
| ⌥Space | open on the screen as it is; from the app behind, a new screenshot; in the panel, close |
| letters | the question, in French or English: the answer comes in the same |
| ↵ | ask; with nothing typed, help with the screen |
| ⌘C | the selection; with nothing selected, the last answer's code block, or the whole answer |
| ⌘V | paste text into the question |
| ⌫, ⌥⌫, ⌘⌫ | take a letter, a word, all of it |
| ⎋ | close, and end the conversation |

The first ⌥Space asks for Screen Recording (System Settings → Privacy & Security → Screen & System Audio
Recording); without it, questions still work, without the screen.

Made after [cue](https://github.com/Blueturboguy07/cue), a free Cluely clone, without its code: cue is Electron
and GPL, and its downloads send prompts and screenshots through publik's servers by default. No audio and no
meeting transcript here.

```sh
./install.sh   # builds, runs the self-test, copies to ~/Applications, starts at login
```

`copilot --selftest` checks what goes to `claude` and back, the keys and the Markdown;
`copilot --ask <image> [question] [follow-up…]` runs a conversation on a picture in the terminal, with timings;
`copilot --render out.png [--dark]` draws the panel offscreen. `docs/make-demo.sh` draws the GIF again;
`--ask-again` asks Claude about its screen once more.
