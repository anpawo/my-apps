# autocorrect

Fixes the word you just typed when you press space, in French and in English, in every app. Mostly the
accents and apostrophes a U.S. keyboard makes you leave out: `ca va tres bien` becomes `ça va très bien`,
`cest` `c'est`, `peutetre` `peut-être`, `dont` `don't`, `teh` `the`. No underline, no popup: the word is
replaced as you go.

| Key | Does |
|---|---|
| space, ↵ | fix the word before it, with its punctuation (`tres.` → `très.`) |
| ⌫ right after | put back what you typed; that word is never changed that way again |

## How it picks

Each spelling the word could be gets a score: how often it is said (French and English counts, weighed by
how French the sentence is so far, plus how often you use it) times how likely you typed it that way when you
meant it (as is, without its accents or apostrophe, one letter off, two pairs swapped). The best one replaces the word only when
it scores five times higher, and three times higher than the next best: `verifie` could be `vérifie` or
`vérifié`, so it is left as typed. Mixed sentences work: `dont` is `don't` after `i`, and stays `dont` after
`la maison`.

It never changes a word it knows into another one (`chat`, `scan` stay), a word typed with its accents
(`côte` stays), nor a word the macOS spell checker knows (`plugin`, `hotkey`, `tutoriels`). It leaves alone
words with a digit or a capital inside (`GitHub`), links and addresses (`etudiant.gouv.fr`), a word begun
after an arrow key (it sees keys, not the text), password fields, and terminals (but
Ghostty, where Claude Code runs), code editors and password managers (the list is in
`Sources/autocorrect/Tap.swift`). Another app:

```sh
defaults write com.mr.autocorrect skip -array-add <bundle id> && launchctl kickstart -k gui/$UID/app.autocorrect
```

## What it learns

`~/Library/Application Support/autocorrect/learned.json`, readable by you alone: how often you kept each
word, and the fixes you took back with ⌫. A word you kept is never fixed again, and among close spellings the
one you use wins.

## Install

```sh
./install.sh   # builds, runs the self-test, copies to ~/Applications, starts at login
```

Then give it Accessibility (System Settings → Privacy & Security → Accessibility): it waits for it and starts
fixing as soon as it is on. `autocorrect --selftest` checks the choices and the keys; `autocorrect --fix`
prints its input as it would read once typed.

## The words

`./make-words.py` rebuilds `Resources/words.tsv` (268,000 words, how often each is said per million):
French from [Lexique 3.83](https://www.lexique.org), English from the 2018 OpenSubtitles counts of
[FrequencyWords](https://github.com/hermitdave/FrequencyWords), both CC BY-SA 4.0, as is `words.tsv`.
