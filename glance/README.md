# glance

Ask about what is on the screen, on ⌘⌥G, and about what the computer plays, on ⌘R. With nothing typed, ↵ works
out what you need from the screen: the fix for the error, the reply to the message, the answer to the exercise;
after listening, from what was said: the answer to the question asked in the call, the gist of the video, the song.

![⌘⌥G over a terminal where a Python script failed: the panel opens at the top, ↵ with nothing typed, and Claude explains that the CSV is semicolon-separated and gives the fixed line; a follow-up typed in French, "et si le fichier est vide ?", gets its answer in French; ⌘C copies its code and ⎋ closes the panel](docs/demo.gif)

⌘⌥G takes a screenshot of the display under the mouse (the panel left out) and starts `claude`; ↵ sends the
screenshot and the question to Claude Opus through Claude Code, on the subscription it is logged in with: no API
key. The first words come 1.5 to 3 s after ↵. Follow-ups go to the same process, which remembers the screen;
⎋ ends it. The screenshot stays in memory and no transcript is kept; the `claude` process takes about 150 MB while
the panel is up, nothing otherwise.

⌘R listens to the computer's sound (every app but glance; not the microphone) until ⌘R again or ↵. whisper.cpp
puts it in words on the Mac (large-v3-turbo, French and English in the same clip), and only those words go to
Claude with the question: two minutes of speech take about 8 s, started as soon as listening stops. The sound
stays in memory, and on disk only for the seconds Whisper reads it. Speech only: Claude hears no tone and no music,
only the lyrics. Needs `brew install whisper-cpp` and, in `~/.local/share/whisper`, `ggml-large-v3-turbo-q5_0.bin`
(huggingface.co/ggerganov/whisper.cpp) and `ggml-silero-v5.1.2.bin` (huggingface.co/ggml-org/whisper-vad).

The panel stays up while you click in the app behind; ⌘⌥G closes it from anywhere, ⎋ from the panel. Screen
shares and recordings leave it out (`sharingType = .none`), as far as macOS still honours that: since 15.4 not
every capture tool does.

| Key | Does |
|---|---|
| ⌘⌥G | open on the screen as it is; again, close |
| letters | the question, in French or English: the answer comes in the same |
| ⌘R | listen to the computer's sound; again, stop (↵ stops it too) |
| ↵ | ask; with nothing typed, help with the screen, or with what was heard |
| ⌘C | the selection; with nothing selected, the last answer's code block, or the whole answer |
| ⌘V | paste text into the question |
| ⌫, ⌥⌫, ⌘⌫ | take a letter, a word, all of it |
| ⎋ | close, end the conversation, drop what was heard |

The first ⌘⌥G asks for Screen Recording (System Settings → Privacy & Security → Screen & System Audio
Recording), which also covers the sound; without it, questions still work, without the screen or the sound.

Made after [cue](https://github.com/Blueturboguy07/cue), a free Cluely clone, without its code: cue is Electron
and GPL, and its downloads send prompts and screenshots through publik's servers by default. Here the sound never
leaves the Mac, only its words.

```sh
./install.sh   # builds, runs the self-test, copies to ~/Applications, starts at login
```

`glance --selftest` checks what goes to `claude` and back, the keys, the Markdown and the WAV given to Whisper;
`glance --ask <image> [question] [follow-up…]` runs a conversation on a picture in the terminal, with timings;
`glance --listen <seconds>` prints what the computer played for that long, as ↵ would send it;
`glance --render out.png [--dark]` draws the panel offscreen. `docs/make-demo.sh` draws the GIF again;
`--ask-again` asks Claude about its screen once more.
