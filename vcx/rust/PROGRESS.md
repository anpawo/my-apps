# VCX in Rust: who builds what

The plan and its evidence: `../reports/vcx-rust-breakdown.md` (slices 1 to 6, measurements M1 to M11). Slice 1 is
built: `cargo test --workspace` passes. Since 25/11/2026 the rest is split over nine sessions working in this one
tree at the same time.

## Owners

A session edits and commits only the paths it owns. To write to one, read its id beside its Fleet label in
`vcx --sessions` in the same turn and send to that id (`vcx --send <id> "<text>"`), never to the name alone.

| Session (Fleet label) | Slice | Owns |
|---|---|---|
| Rust transcript | 2: transcript parity | `crates/vcx-model/`, `template/` except `composer.*`, `chart*` and `chrome.*`, `fixtures/demo_state.json`, `crates/vcx-shell/src/{bridge,template,snapshot}.rs`, `crates/vcx-shell/tests/transcript.rs` |
| Rust charts | 2: charts | `template/chart.js`, `template/chart.css`, `template/chart/`, `crates/vcx-shell/src/chart.rs`, `crates/vcx-shell/tests/charts.rs` |
| Rust chrome | 2: everything in the window around the transcript and the composer | `template/chrome.js`, `template/chrome.css`, `crates/vcx-shell/tests/chrome.rs` |
| Rust composer | 3: composer | `template/composer.js`, `template/composer.css`, `crates/vcx-shell/src/{input,menu}.rs`, `crates/vcx-shell/tests/composer.rs` |
| Rust app | 4: the app | `crates/vcx-app/` (new), `crates/vcx-shell/src/{main,lib,app,check,link,session,pane,summary}.rs`, `crates/vcx-shell/tests/windowless.rs`, `../build-rust.sh` (new) |
| Rust config | 4: settings, state folders, the command line | `crates/vcx-config/` (new), `crates/vcx-cli/` (new) |
| Rust worker | 5: the worker | `crates/vcx-worker/` (new), `crates/vcx-proto/`, `crates/vcx-testkit/`, `fixtures/fake_agent.py` |
| Rust agents | 5: provider adapters | `crates/vcx-agents/` (new), `fixtures/streams/` (new) |
| Rust report (the launching session) | conformance suite, integration | `crates/vcx-conformance/` (new), `Cargo.toml`, this file |

## Rules of the shared tree

- A change needed in a path another session owns: ask its owner (`vcx --send <its id> "<what and why>"`).
  A one-line additive edit (a `mod` line, a `<script>` tag, an enum variant) may be made directly and told to the
  owner in the same way.
- A new crate lists its own dependencies in its own `Cargo.toml`; the workspace table changes only through its
  owner. `Cargo.lock` is committed with whatever change moved it.
- Build and test only what you own: `~/.local/bin/build-stack cargo test -j 2 -p <crate>`. One build at a time,
  edits finished before it starts. `cargo test --workspace` is the integration run of the launching session.
- Commit small and often, own paths only, through a private index (never `git add -A`, never `git commit -a`),
  then push. A crate is committed only while its own tests pass.
- The page is built from his web templates. Marius, 25/11/2026: "make sure to use my templates for the display of
  the app, ok ? since its web". They are in `~/self/templates/web` (read its `CLAUDE.md` first): search
  `templates.json` before drawing any element (a favourite first, then an accepted one), copy the effect between
  its `Effect: … Copy from here` and `End of effect` markers, and say in the commit which template (`WT-…`) an
  element comes from. An element no template covers is built in their style and told to him as a new one.
- Nothing opens a window to check: every check runs in the unshown window (`--check`) or in a plain test.
- Nothing is installed at `~/Applications/Vibe Code X.app`, and the Swift app, its workers and its state under
  `~/.local/state/vcx` are never stopped, killed, attached to or written. Tests start their own Swift worker
  through `vcx-testkit`.
- Real provider turns: Marius allowed, on 25/11/2026, one short real turn each on Codex and Claude to record their
  streams. They belong to the session `Rust agents`; every other test runs on fixtures and those recordings.

## State (each session keeps its own two lines)

- Rust transcript. Done: vcx-model pushed (debates, pictures, notices, requests, code and chart blocks); the page draws sections, work blocks, actions, debates, notices, peers, pictures and preview, question cards, find, links, code copy, the pinned question and Back to latest, 13 windowless cases in `tests/transcript.rs` passing.
  Next: push `bridge.rs`, `template.rs` and the page files once Rust app commits `lib.rs` and `pane.rs`; measure `arrange()` on 5,000 rows.
- Rust composer. Done: the page composer (chips, folded pastes, `/` palette, `@` files, history, drafts, stop, Edit menu, undo), 22 windowless cases in `tests/composer.rs`; the stop rule passed, no native `NSTextView`. Next: the send flight and the run panel; core wiring asked of Rust app and Rust transcript.
- Rust app. Done: nothing yet. Next: `vcx-app` with several windows in one process.
- Rust worker. Done: `vcx-worker` (`3b3d841`), protocol v1 over the Codex app-server: leases, sequences and receipts, patches, Swift-format checkpoints, cold reopen of a killed worker with its history and unsent draft; conformance 21 of 21, the Swift `runtime_probe.py` 68 of 68 (as on the Swift worker), a Rust shell `--check` fixture turn. K10: its own binary (3.6 ms to hello, 2.1 MiB idle, against 46.8 ms and 38.2 MiB for the Swift worker), sent to Rust report.
- Rust worker. Next: the worker drives Claude, Qwen and agy through the `vcx-agents` connections; the Swift-worker conformance flake (an archive notice under load, on HEAD before the worker) is with Rust report.
- Rust charts. Done: chart frames (`7abeb34`): sandboxed `vcx://chart/<id>` documents with their own CSP, the Swift page API (`vcx.chart` series, table, cards; `vcx.live` fetched by the core; pin above the chat, enlarge on double click, pinch, wheel and drag), lightweight-charts 5.3.0 vendored; `tests/charts.rs` 10 windowless tests pass, C3 refuted. From his templates: cards WT-084, table WT-085, the enlarged chart WT-118 (zoom popup), its buttons WT-033 (ghost icon size, light colours); `pane.rs` hands `vcx.live` to `chart::Feeds` (left for Rust app to commit).
- Rust charts. Next: new elements for him, drawn in the templates' style with no template of their own: the pinned chart strip at the top of the chat, and the series' hover legend kept from the Swift kit (WT-012, the pointer tooltip, is not used); not run: `vcx.live` in the real window and the Nasdaq `symbol` chart against the live API.
- Rust chrome. Done: `chrome.js`/`chrome.css` drawn from his web templates (02554e6): status word and bar chips as status pills (WT-037), progress and update chips with the progress bar (WT-104), the permission prompt as the bar dialog answering through `answer` (WT-072), the model, mode, models and quota popovers as the single pick (WT-046) with toggle chips (WT-034) and the table (WT-085), the task bar as the card bar (WT-050) with its empty state (WT-102); notices, the title; `tests/chrome.rs` 18 windowless tests pass. New element for him, no template covers it: the status line's layout (pill, what runs, elapsed, "Your answer is needed"). Next: `src/progress.rs` and the Pane ticker, then the session panel, Settings sheet and sign-in panel; waits on the view sending usage, repo state, models and efforts, and on Rust app forwarding answer/command/title/focus/quota and sending tasks.
  What `Views.swift` draws outside the rows and the composer, and who builds it. Rust chrome: the session panel
  (Settings button, Hooks/Skills/Commands/MCP/MD Files/RAG counts and their search panels, Session ID copy), the
  Settings sheet (Session, Accounts, Qwen, Background, Keys), the status line (dot, Thinking/Ready/Not connected/
  Pending action, what runs, elapsed, "Your answer is needed"), the status bar (update chip, progress chip, Directory,
  Model and effort, Mode, the debate models badge, Tokens, Usage with the quota overview, Repo, Pull request), the
  permission prompt (Cancel, Decline, Allow), the sign-in panel, the task bar, notices, the window title. Rust
  transcript: the pinned question, Back to latest, the find bar (top right of the transcript), the image preview,
  question cards (`QuestionPanel`). Rust composer: the `/` palette, the draft's pictures, the send flight, the run
  panel. Rust charts: the pinned chart and the chart preview.
- Rust config. Done: `vcx-config` (homes with the `VCX_RUST_*` and worker overrides, his `settings.json` read and written back byte for byte in Swift or Python style under `settings.lock`, accounts, limits, Qwen; `1a744b8`) and `vcx-cli`, a library `vcx-rust` calls (`parse`, `run`, `control::request`, `fleet::list`). Flags today, and where they go: taken against the Rust app `--cwd`/`-C`, `--resume`/`-r`, `--focus`, `--`, bare words, `--sessions`, `--send [--from]` (`-` reads stdin), `--set-dir`, `--set-model`, `--close`, `--version`, `--help`, `--runtime-protocol`, `--windowless` (new); handed to `background.py` `-p`/`--print`/`--headless`/`--ensure-qwen` with its 34 flags (`--provider`, `--output-format json`, ...), in the Rust worker folders; refused with the reason (`parse::ELSEWHERE`, 44 flags) the live update, `--terminal`, `--recall`, `--route-project`, the built-in checks (now `cargo test`) and the worker and fixture flags.
- Rust config. Next: `vcx-app` drops its `cli.rs` and calls `vcx_cli::parse`/`run`, and serves `setModel` and `close` (asked of Rust app); `--sessions` then prints the Swift columns (id8, provider, state, folder, name).
- Rust agents. Done: `vcx-agents` holds Codex (the worker's client), Claude, agy and Qwen behind one `Connection`, each tested on a recorded (Codex, Claude) or hand-written (agy, Qwen) turn read into the same typed events, plus capabilities and models per provider. Next: the worker switching from `Agent` to `Connection` for the other three providers.
- Rust report. Done: slice 1, the report, `vcx-conformance` (21 cases green against the Swift worker), the Swift recovery-list fix (`fb40939`), Rust pushes no longer reinstall the Swift app (`7181bf0`). Next: cases for stop, answer, a frontend leaving mid-turn and worker retirement once the fixture can hold a turn open; the workspace run once every crate is committed.
