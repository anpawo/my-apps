#!/usr/bin/env python3
"""Rebuilds Resources/words.tsv: how often each French and English word is said, per million
words, plus the elisions and contractions the sources split apart.

French: Lexique 3.83 (lexique.org, CC BY-SA 4.0), every form of every word with its accents,
counted in film subtitles. Only real words, so "etat" or "deja" are not in it and get fixed,
while "termine" is and stays. Words it lacks (vas-y, avez-vous) come from the subtitle counts
below, unless they are an accent-less spelling of one it has (weekend stays, etat does not).
English: hermitdave/FrequencyWords, 2018 OpenSubtitles counts (CC BY-SA 4.0). Spoken language,
closer to chat than books are. Its tokenizer cuts at the apostrophe ("c'est" counts as "est",
"don't" as "don"), so those forms are added back below.

Also rebuilds Resources/pairs.tsv: how likely each word is right after another (je vais à, il a),
counted on the first lines of the OpenSubtitles 2018 text (OPUS). For a word that shares its
unaccented spelling with another (a/à, ou/où, vérifie/vérifié), and for every word said at least
once per million, which a typo may stand for (wnat: want or what, after "i").

    ./make-words.py            downloads the sources (the subtitle text is streamed, not saved)
    ./make-words.py <dir>      reads Lexique383.tsv, fr_full.txt, en_full.txt, fr.txt.gz and
                               en.txt.gz from <dir>, and keeps the counts there (fr.pairs,
                               fr.single, en.pairs, en.single) to start from next time
"""
import gzip
import re
import subprocess
import sys
import tempfile
import unicodedata
import urllib.request
import zipfile
from pathlib import Path

TEXT = "https://object.pouta.csc.fi/OPUS-OpenSubtitles/v2018/mono/{0}.txt.gz"
# About 130 million words per language: enough for the frequent pairs, a few minutes to count.
LINES = 20_000_000
# A pair seen fewer times is noise; a word seen fewer times before others has no reliable context.
# Each pair kept costs the app about 100 bytes of memory.
PAIR_FLOOR = 10
PREV_FLOOR = 500
# A word, with its apostrophes and hyphens (j'ai, peut-être), or one punctuation mark.
TOKEN = re.compile(r"[^\W\d_]+(?:['-][^\W\d_]+)*|\S")
URL = "https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/{0}/{0}_full.txt"
LEXIQUE = "https://www.lexique.org/databases/Lexique383/Lexique383.zip"
# Below these counts the subtitle lists are mostly typos and names.
FLOOR = {"fr": 50, "en": 20}
# Every Lexique word, however rare, is a word: never mistaken for a typo (Words.swift: rare).
LEXIQUE_FLOOR = 0.25
# Subtitle words outside it are encoding junk or another language (prã, até).
LETTERS = set("abcdefghijklmnopqrstuvwxyzàâäçéèêëîïôöùûüÿœæ'-")

# (elided prefix, word, share of that word's occurrences that follow the prefix). Guessed, not
# measured: they only need to beat the apostrophe-less spelling, which is rare or not a word.
ELISIONS = {
    "c": {"est": .5, "était": .5, "étaient": .3},
    "j": {"ai": .5, "étais": .4, "avais": .4, "aime": .3, "adore": .5, "arrive": .2, "en": .1, "y": .1,
          "habite": .3, "espère": .5, "attends": .3, "irai": .5, "aurais": .4, "avoue": .5, "imagine": .3,
          "oublie": .2, "entends": .3, "ose": .3, "allais": .3, "ai-je": .5},
    "n": {"est": .1, "a": .05, "ai": .2, "y": .1, "as": .1, "importe": .4, "était": .1, "avait": .1,
          "en": .05, "ont": .1, "es": .2, "aime": .1},
    "l": {"ai": .15, "a": .03, "as": .1, "on": .1, "autre": .3, "un": .05, "une": .02},
    "d": {"accord": .9, "abord": .9, "ailleurs": .9, "habitude": .9, "un": .1, "une": .1, "autres": .1,
          "être": .05, "avoir": .05, "où": .1},
    "qu": {"il": .1, "elle": .1, "on": .1, "ils": .1, "elles": .1, "est-ce": .9, "un": .05, "une": .05,
           "au": .05, "en": .1},
    "s": {"il": .05, "ils": .05, "est": .03, "en": .05},
    "m": {"a": .03, "ont": .03, "en": .05, "appelle": .5, "aime": .1},
    "t": {"as": .2, "es": .05, "en": .05, "inquiète": .5, "aime": .1, "a": .02},
    "jusqu": {"à": 1, "ici": .3, "au": .5, "aux": .5},
    "quelqu": {"un": .2, "une": .2},
    "presqu": {"île": .3},
}
# English contractions whose spelling without the apostrophe is not a word of its own. Every
# other English word with an apostrophe (possessives: screenshot's) is dropped. Left out
# on purpose: it's, I'll, I'd, let's, we're, we'll, he'll, she'll, we'd, he'd, she'd (its, ill,
# id, lets, were, well, hell, shell, wed, shed are words). Count = the stem the source kept.
STEMMED = {"don't": "don", "didn't": "didn", "isn't": "isn", "doesn't": "doesn", "wasn't": "wasn",
           "aren't": "aren", "weren't": "weren", "haven't": "haven", "hasn't": "hasn", "hadn't": "hadn",
           "wouldn't": "wouldn", "shouldn't": "shouldn", "couldn't": "couldn", "ain't": "ain"}
# Share of all English words, guessed from the stems above.
SHARE = {"can't": 1e-3, "won't": 5e-4, "I'm": 4e-3, "I've": 5e-4, "you're": 1.5e-3, "they're": 5e-4,
         "that's": 2e-3, "there's": 7e-4, "what's": 8e-4, "who's": 2e-4, "here's": 1.5e-4,
         "you've": 3e-4, "you'll": 4e-4, "we've": 2e-4, "they've": 1e-4, "would've": 3e-5,
         "could've": 2e-5, "should've": 2e-5, "he's": 1e-3, "she's": 5e-4, "you'd": 1.5e-4,
         "they'll": 1e-4, "that'll": 5e-5, "y'all": 5e-5}


def plain(word):
    return 0 < len(word) <= 30 and word.replace("'", "").replace("-", "").isalpha() \
        and word[0].isalpha() and word[-1].isalpha()


def fold(word):
    word = unicodedata.normalize("NFD", word.lower().replace("œ", "oe").replace("æ", "ae"))
    return "".join(c for c in word if unicodedata.category(c) != "Mn")


def read(folder, lang):
    counts = {}
    with open(folder / f"{lang}_full.txt", encoding="utf-8") as f:
        for line in f:
            word, _, n = line.rstrip("\n").rpartition(" ")
            if n.isdigit() and int(n) >= FLOOR[lang] and plain(word) and set(word.lower()) <= LETTERS:
                counts[word] = counts.get(word, 0) + int(n)
    total = sum(counts.values())
    return {w: n / total * 1e6 for w, n in counts.items()}


def pairs(folder, lang, lexicon, wanted):
    """P(word | the word before it), for the words in `wanted`; only words of `lexicon` (that
    language's) next to each other, with no punctuation between them: French subtitles often
    write coeur, an English word, which must not outweigh cœur. The pairs are counted on disk
    (tens of millions of them, too many for a dict) and kept in `folder`."""
    counted, singles = folder / f"{lang}.pairs", folder / f"{lang}.single"
    if not counted.exists():
        path = folder / f"{lang}.txt.gz"
        source = open(path, "rb") if path.exists() else urllib.request.urlopen(TEXT.format(lang))
        single = {}
        raw = folder / f"{lang}.pairs.raw"
        with source, gzip.open(source, "rt", encoding="utf-8", errors="replace") as f, open(raw, "w", encoding="utf-8") as out:
            for i, line in enumerate(f):
                if i >= LINES:
                    break
                prev = None
                for token in TOKEN.findall(line.lower().replace("’", "'")):
                    if not token[0].isalpha() or token not in lexicon:
                        prev = None
                        continue
                    single[token] = single.get(token, 0) + 1
                    if prev:
                        out.write(f"{prev}\t{token}\n")
                    prev = token
        with open(singles, "w", encoding="utf-8") as out:
            out.writelines(f"{word}\t{n}\n" for word, n in single.items())
        # Written beside, then renamed: a run cut short is not taken for a finished count.
        part = folder / f"{lang}.pairs.part"
        with open(part, "w", encoding="utf-8") as out:
            sort = subprocess.Popen(["sort", "-S", "1G", "-T", str(folder), str(raw)], stdout=subprocess.PIPE, env={"LC_ALL": "C"})
            subprocess.run(["uniq", "-c"], stdin=sort.stdout, stdout=out, check=True)
            if sort.wait():
                raise SystemExit(f"sort failed on {raw}")
        part.rename(counted)
        raw.unlink()
    single, double = {}, {}
    with open(singles, encoding="utf-8") as f:
        for line in f:
            word, n = line.rstrip("\n").split("\t")
            single[word] = int(n)
    with open(counted, encoding="utf-8") as f:
        for line in f:
            n, pair = line.strip().split(" ", 1)
            a, b = pair.split("\t")
            if int(n) >= PAIR_FLOOR and b in wanted:
                double[a, b] = int(n)
    return {(a, b): n / single[a] for (a, b), n in double.items() if single.get(a, 0) >= PREV_FLOOR}


def lexique(folder):
    freq = {}
    with open(folder / "Lexique383.tsv", encoding="utf-8") as f:
        next(f)
        for line in f:
            cols = line.split("\t")
            if plain(cols[0]):
                freq[cols[0]] = freq.get(cols[0], 0) + float(cols[8])
    return freq


def main():
    if len(sys.argv) > 1:
        folder = Path(sys.argv[1])
    else:
        folder = Path(tempfile.mkdtemp())
        for lang in ("fr", "en"):
            urllib.request.urlretrieve(URL.format(lang), folder / f"{lang}_full.txt")
        urllib.request.urlretrieve(LEXIQUE, folder / "Lexique383.zip")
        zipfile.ZipFile(folder / "Lexique383.zip").extract("Lexique383.tsv", folder)
    lex, subtitles, en = lexique(folder), read(folder, "fr"), read(folder, "en")
    # Lexique writes "coeur"; the subtitles have "cœur" too, which is the spelling.
    for word in [w for w in lex if "oe" in w or "ae" in w]:
        ligature = word.replace("oe", "œ").replace("ae", "æ")
        if subtitles.get(ligature, 0) >= 0.1 * subtitles.get(word, 1):
            lex[ligature] = lex.pop(word)
    fr = {w: max(f, LEXIQUE_FLOOR) for w, f in lex.items()}
    spelled = {}
    for w in lex:
        spelled.setdefault(fold(w), set()).add(w)
    for word, f in subtitles.items():
        if word in lex or not spelled.get(fold(word), set()) - {word}:
            fr[word] = max(fr.get(word, 0), f)
    for prefix, words in ELISIONS.items():
        for word, share in words.items():
            fr[f"{prefix}'{word}"] = fr.get(word, 0) * share
    en = {w: f for w, f in en.items() if "'" not in w}
    # The stems are not words: isin is not a typo of isn.
    for word, stem in STEMMED.items():
        en[word] = en.pop(stem, 0)
    for word, share in SHARE.items():
        en[word] = share * 1e6
    # "I" is the only English word always written in capitals; the lists have it lower-case.
    en["I"] = en.pop("i", 0)
    fr.pop("i", None)

    out = Path(__file__).parent / "Resources" / "words.tsv"
    with open(out, "w", encoding="utf-8") as f:
        for word in sorted(fr.keys() | en.keys()):
            f.write(f"{word}\t{fr.get(word, 0):.4g}\t{en.get(word, 0):.4g}\n")
    print(f"{out}: {len(fr | en)} words ({len(fr)} French, {len(en)} English)")

    # Words.swift folds apostrophes and hyphens away too: dont and don't are one spelling.
    spellings = {}
    for word in fr.keys() | en.keys():
        spellings.setdefault(fold(word).replace("'", "").replace("-", ""), set()).add(word.lower())
    ambiguous = {w for group in spellings.values() if len(group) > 1 for w in group}
    wanted = ambiguous | {w.lower() for w in fr.keys() | en.keys() if max(fr.get(w, 0), en.get(w, 0)) >= 1}
    both = {lang: pairs(folder, lang, {w.lower() for w in words}, wanted) for lang, words in (("fr", fr), ("en", en))}
    out = out.with_name("pairs.tsv")
    with open(out, "w", encoding="utf-8") as f:
        for a, b in sorted(both["fr"].keys() | both["en"].keys()):
            f.write(f"{a}\t{b}\t{both['fr'].get((a, b), 0):.3g}\t{both['en'].get((a, b), 0):.3g}\n")
    print(f"{out}: {len(both['fr'])} French pairs, {len(both['en'])} English")


main()
