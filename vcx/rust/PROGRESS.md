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
| Rust app | 4: the app | `crates/vcx-app/` (new), `crates/vcx-shell/src/{main,app,check,link,session}.rs`, `crates/vcx-shell/tests/windowless.rs`, `build-rust.sh` (new) |
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
- Rust charts. Done: nothing yet. Next: a chart block drawn in a sandboxed frame.
- Rust chrome. Done: nothing yet. Next: status bar, task bar, model controls.
  What `Views.swift` draws outside the rows and the composer, and who builds it. Rust chrome: the session panel
  (Settings button, Hooks/Skills/Commands/MCP/MD Files/RAG counts and their search panels, Session ID copy), the
  Settings sheet (Session, Accounts, Qwen, Background, Keys), the status line (dot, Thinking/Ready/Not connected/
  Pending action, what runs, elapsed, "Your answer is needed"), the status bar (update chip, progress chip, Directory,
  Model and effort, Mode, the debate models badge, Tokens, Usage with the quota overview, Repo, Pull request), the
  permission prompt (Cancel, Decline, Allow), the sign-in panel, the task bar, notices, the window title. Rust
  transcript: the pinned question, Back to latest, the find bar (top right of the transcript), the image preview,
  question cards (`QuestionPanel`). Rust composer: the `/` palette, the draft's pictures, the send flight, the run
  panel. Rust charts: the pinned chart and the chart preview.
- Rust config. Done: nothing yet. Next: `vcx-config` reading today's settings and state folders.
- Rust agents. Done: nothing yet. Next: the Codex adapter on a recorded stream.
- Rust report. Done: slice 1, the report, `vcx-conformance` (21 cases green against the Swift worker). Next: cases for stop, answer, a frontend leaving mid-turn and worker retirement once the fixture can hold a turn open; the suite against the Rust worker.
