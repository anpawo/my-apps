# evolve

An AlphaEvolve-style loop ([OpenEvolve](https://github.com/algorithmicsuperintelligence/openevolve)) pointed at two hot paths of my own apps, with Codex as the model and nothing else to pay for: a small proxy turns `codex exec` into an OpenAI-compatible endpoint, so the run spends the ChatGPT plan's quota instead of API credits.

The loop: the model proposes a change to one function, a judge compiles it with `swiftc -O`, checks that it returns exactly what the original returns, times it, and the fastest correct versions become the parents of the next ones.

## Results (23 Nov 2026, one hour, gpt-6.2-sol at medium effort)

| | [vcx-recall](vcx-recall) | [fleet-delegation](fleet-delegation) |
|---|---|---|
| Function | `ErrorsRecall.recall` in [VCX](../vcx): BM25 ranking of ~300 rules against each prompt sent | The head scan in [Fleet](../fleet)'s `TranscriptStore.parse`: lines of a transcript that start or end a background job |
| Before | 9.6 ms per prompt | 94 ms per 20 MB transcript head |
| After | 0.41 ms per prompt (**23×**) | 0.47 ms (**~200×**) |
| Iterations / Codex calls | 77 / 78, none failed | 84 / 88, none failed |
| Checked against the original | 614 new prompts, every project's rule files, Unicode traps (combining accents, Kelvin sign, dotted İ, CRLF, full-width letters) | 60 real Claude and Codex transcripts, 40 generated files with marks cut at line ends |
| What it found | Packs each word into a `UInt64` and scans UTF-8 bytes directly, scores only the rules sharing a word with the prompt, keeps the top 4 by insertion; rare Unicode falls back to the original tokenizer so the output stays identical | Samples one 4-byte window every 10 bytes against a hash table of the marks' windows (a sublinear skip search), confirms with `memcmp`, finds the line with `memchr` |

"After" figures are from a separate run on inputs the loop never saw; the in-run scores were 22.8× and 241×. Each `progress.csv` lists every new best with its time and iteration. Both runs together took 2% of the plan's weekly Codex quota (14% to 16%).

Not merged yet: the evolved code is several times longer than the original (25 to ~200 lines for VCX, 5 to ~150 for Fleet), so each one goes into its app only after a review.

## Run it

```sh
python3.12 -m venv venv && venv/bin/pip install openevolve
venv/bin/python codex_proxy.py gpt-6.2-sol medium 8765 &   # needs a logged-in `codex`
cd vcx-recall && python3 make_fixtures.py
../venv/bin/openevolve-run initial_program.swift evaluator.py --config config.yaml --output out
```

The fixtures are built from local files (my agents' rule files, my session transcripts) and stay out of git.

## Files

- `codex_proxy.py`: `/v1/chat/completions` answered by `codex exec --ephemeral`, at most 4 at a time.
- `<target>/initial_program.swift`: the function as it is in the app, between `EVOLVE-BLOCK` markers.
- `<target>/main.swift`: the benchmark, which also writes every output so the judge can compare it byte for byte.
- `<target>/evaluator.py`: compiles, rejects shared state and threads, checks the output on a main and a held-out input, scores the speedup.
- `<target>/best_program.swift`: the fastest correct version found.
