# VCX in Rust: who builds what

The plan and its evidence: `../reports/vcx-rust-breakdown.md` (slices 1 to 6, measurements M1 to M11). Slice 1 is
built: `cargo test --workspace` passes. Since 25/11/2026 the rest is split over five sessions working in this one
tree at the same time.

## Owners

A session edits and commits only the paths it owns. The session is found by its Fleet label (`vcx --sessions`).

| Session (Fleet label) | Slice | Owns |
|---|---|---|
| Rust transcript | 2: transcript parity | `crates/vcx-model/`, `template/` except `composer.*`, `fixtures/demo_state.json`, `crates/vcx-shell/src/{bridge,template,snapshot}.rs`, `crates/vcx-shell/tests/transcript.rs` |
| Rust composer | 3: composer | `template/composer.js`, `template/composer.css`, `crates/vcx-shell/src/{input,menu}.rs`, `crates/vcx-shell/tests/composer.rs` |
| Rust app | 4: the app | `crates/vcx-app/` (new), `crates/vcx-shell/src/{main,app,check,link,session}.rs`, `crates/vcx-shell/tests/windowless.rs`, `build-rust.sh` (new) |
| Rust worker | 5: the worker | `crates/vcx-worker/` (new), `crates/vcx-agents/` (new), `crates/vcx-proto/`, `crates/vcx-testkit/`, `fixtures/fake_agent.py` |
| Rust report (the launching session) | conformance suite, integration | `crates/vcx-conformance/` (new), `Cargo.toml`, this file |

## Rules of the shared tree

- A change needed in a path another session owns: ask its owner (`vcx --send "<Fleet label>" "<what and why>"`).
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
- No real provider turn (Codex, Claude, agy) without Marius's word: fixtures and recorded streams stand in.

## State (each session keeps its own two lines)

- Rust transcript. Done: nothing yet. Next: images, question cards, thought bubbles, debate rows.
- Rust composer. Done: nothing yet. Next: chips, long paste, `/` palette, Edit menu, undo.
- Rust app. Done: nothing yet. Next: `vcx-app` with several windows in one process.
- Rust worker. Done: nothing yet. Next: `vcx-worker` serving v1 with the fixture agent.
- Rust report. Done: slice 1, the report, `vcx-conformance` (21 cases green against the Swift worker). Next: cases for stop, answer, a frontend leaving mid-turn and worker retirement once the fixture can hold a turn open; the suite against the Rust worker.
