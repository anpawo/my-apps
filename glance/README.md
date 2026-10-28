# glance

Ask about what is on the screen, on ⌘⌥J, what happens on it, on ⌘2, and what the computer plays, on ⌘3. With nothing typed, ↵ works
out what you need from the screen: the fix for the error, the reply to the message, the answer to the exercise;
after listening, from what was said: the answer to the question asked in the call, the gist of the video, the song.

![⌘⌥J over a terminal where a Python script failed: the panel opens at the top right, ↵ with nothing typed, and Claude explains that the CSV is semicolon-separated and gives the fixed line; a follow-up typed in French, "et si le fichier est vide ?", gets its answer in French; ⌘C copies its code and ⎋ closes the panel](docs/demo.gif)

⌘⌥J takes a screenshot of the display under the mouse (the panel left out) and starts `claude`; ↵ sends the
screenshot and the question to Claude Opus through Claude Code, on the subscription it is logged in with: no API
key. The first words come 1.5 to 3 s after ↵. Follow-ups go to the same process, which remembers the screen;
⎋ ends it. The buttons on top pick what goes with the next question, each with its key: Photo (⌘1) a new
screenshot, or none when it is already blue; Video (⌘2) films the screen until Video again or ↵, a frame a
second, and sends the frames in place of the screenshot (past 16, every other one goes and the pace halves, so a
long film sends at most 16, spread over all of it; 9 frames of 20 s came to 780 KB and an answer 5 s later). The
question is typed at the bottom. The screenshot stays in memory and no transcript is kept; the `claude` process takes about 150 MB while
the panel is up, nothing otherwise.

⌘3, or the Listen button, listens to the computer's sound (every app but glance; not the microphone) until ⌘3
again or ↵, and writes what is said in the panel as it is said, about a second behind. Apple's speech recognizer
puts it in words on the Mac, once per language (the Mac's first two, as System Settings → General → Language &
Region lists them), and each sentence is shown in the language it is surer of; a sentence run from one language
into the other with no pause shows garbled until the pause, then comes right. Only those words go to Claude with
the question. The sound stays in memory and never leaves the Mac. Speech only: Claude hears no tone and no music,
only the lyrics. The first ⌘3 in a language downloads its model, about a second.

The panel is Watcher's watch list glass, clearer (blurred 5 pt, tinted at 0.1), under white at 0.2, the screen behind it blurred and seen through: a box of the screen's
shape, 512 pt wide, that scrolls, in a corner of the screen (top right at first; ⌃ and an arrow move it to another,
where it opens from then on). With ⌃ held over it, it follows the mouse until ⌃ is let go. ⌘⌥J gives it the focus,
and ⎋ gives it back to the app you were in. It stays up while you click in the app behind; ⌘⌥J closes it from
anywhere, ⎋ from the panel. Screenshots, screen shares and recordings show it as any window; the eye button
(Seen, Hidden) leaves it out of them, and stays as it was set. glance's own screenshot always leaves it out.

| Key | Does |
|---|---|
| ⌘⌥J | open on the screen as it is, with the focus; again, close |
| letters | the question, in French or English: the answer comes in the same |
| ⌘1 | Photo: a new screenshot for the next question; again, none |
| ⌘2 | Video: film the screen for the next question; again, stop (↵ stops it too) |
| ⌘3 | Listen: the computer's sound, its words written as they are said; again, stop (↵ stops it too) |
| ⌘4 | the eye: Seen or Hidden by screenshots and screen shares |
| ↵ | ask; with nothing typed, help with the screen, or with what it showed or what was heard |
| ⌘C | the selection; with nothing selected, the last answer's code block, or the whole answer |
| ⌘V | paste text into the question |
| ⌫, ⌥⌫, ⌘⌫ | take a letter, a word, all of it |
| ⌃←, ⌃→, ⌃↑, ⌃↓ | move it to that side of the screen: to a corner, where it opens from then on; two together, as ⌃↑ and →, to the corner between |
| ⌃, over it | it follows the mouse until ⌃ is let go |
| ⎋ | close, end the conversation, drop what was heard, give the focus back |

The first ⌘⌥J asks for Screen Recording (System Settings → Privacy & Security → Screen & System Audio
Recording), which also covers the sound; without it, questions still work, without the screen or the sound.

Made after [cue](https://github.com/Blueturboguy07/cue), a free Cluely clone, without its code: cue is Electron
and GPL, and its downloads send prompts and screenshots through publik's servers by default. Here the sound never
leaves the Mac, only its words.

Needs macOS 26, for its speech recognizer.

```sh
./install.sh   # builds, runs the self-test, copies to ~/Applications, starts at login
```

`glance --selftest` checks what goes to `claude` and back, the keys, the Markdown and how the two languages' words
are put together;
`glance --ask <image> [question] [follow-up…]` runs a conversation on a picture in the terminal, with timings;
`glance --listen <seconds>` prints the words of what the computer plays as they come, then as ↵ would send them;
`glance --film <seconds> [question]` films the screen as Video does and prints Claude's answer about it;
`glance --render out.png` draws the panel offscreen, over the demo's screen. `docs/make-demo.sh` draws the GIF again;
`--ask-again` asks Claude about its screen once more.
