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

- Rust transcript. Done: nothing yet. Next: images, question cards, thought bubbles, debate rows.
- Rust composer. Done: nothing yet. Next: chips, long paste, `/` palette, Edit menu, undo.
- Rust app. Done: nothing yet. Next: `vcx-app` with several windows in one process.
- Rust worker. Done: nothing yet. Next: `vcx-worker` serving v1 with the fixture agent.
- Rust charts. Done: chart frames (`7abeb34`): sandboxed `vcx://chart/<id>` documents with their own CSP, the Swift page API (`vcx.chart` series, table, cards; `vcx.live` fetched by the core; pin above the chat, enlarge on double click, pinch, wheel and drag), lightweight-charts 5.3.0 vendored; `tests/charts.rs` 10 windowless tests pass, C3 refuted.
- Rust charts. Next: Rust app wires `chart::Feeds` into `pane.rs` (asked) so `vcx.live` runs in the real window; the Nasdaq `symbol` chart is not run against the live API.
- Rust chrome. Done: `chrome.js`/`chrome.css` (45aedec): status line (dot, Thinking/Ready/Not connected/Pending action, what runs, elapsed, "Your answer is needed"), status bar (progress and update chips, Directory, Model and effort, Mode, debate models badge, Tokens, Usage, Repo, PR) with the model, mode, models and quota popovers, the permission prompt answering through `answer`, the task bar, notices, the title; `tests/chrome.rs` 18 windowless tests pass. Next: the session panel and Settings sheet, the sign-in panel; waits on the view sending usage, repo state, models and efforts, and on Rust app forwarding answer/command/title/focus/quota and sending progress and tasks.
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
- Rust agents. Done: nothing yet. Next: the Codex adapter on a recorded stream.
- Rust report. Done: slice 1, the report, `vcx-conformance` (21 cases green against the Swift worker), the Swift recovery-list fix (`fb40939`), Rust pushes no longer reinstall the Swift app (`7181bf0`). Next: cases for stop, answer, a frontend leaving mid-turn and worker retirement once the fixture can hold a turn open; the workspace run once every crate is committed.
