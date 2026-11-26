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
- `origin/main` builds after every push: a commit that needs another session's uncommitted file waits until its
  owner has committed it (ask it), and the owner commits what others wait for first.
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

- Rust transcript. Done: vcx-model, bridge, template and the page pushed (5b941e9, ae6d48c): sections, work blocks, actions, debates, notices, peers, pictures, question cards, find, links, code copy, the pinned question and Back to latest, 15 windowless cases in `tests/transcript.rs` passing, a streamed patch on 5,000 rows in 7 ms (was 40), one `restyled` per template edit (309ad05, windowless 6 of 6). From his templates: picture preview WT-118, buttons WT-033, find field WT-030, question card WT-080. New for him, in their style with no favourite or accepted template: the question and answer bubbles, the debate turns, the work block fold, action rows, recalled lines, the long-message unfold, numbered question options, notice and peer lines, the picture strip.
  Next: nothing pending in slice 2; the new elements above wait on his word or a template of his.
- Rust composer. Done: the page composer (chips, folded pastes, `/` palette, `@` files, history, drafts, stop, Edit menu, undo, the send flight), redrawn from his web templates (530232e: the text area that grows WT-035, the button variants WT-033, the address pills WT-061, the command palette WT-089; new, in their style: a chip's remove button and the palette's key hints); the core answers files, pasted pictures and drops (8ce9910, `composer::answer`); the run panel (9cfce8a): `run.rs` runs a shell block's or an inline sudo command on its own pty as Swift `CommandRun`, a line typed with the echo off goes to the tty only, `run.js` draws it in the bar dialog (WT-072; new: the output box and a code block's Run button); 28 windowless cases in `tests/composer.rs`, 6 in `run::tests`.
- Rust composer. Next: all its wiring is on main (`pane.rs` e5fd4ee, `bridge.rs`, `template.rs` and `index.html` ae6d48c); left: the run panel tried in an installed `VCX Rust.app` on a harmless command.
- Rust app. Done: `vcx-app`, bin `vcx-rust` (775ace9, 6ec6420, d88ae3d, 7050d16, 7683fb1, 7c09d37, 59a32b5): many windows in one process on plain threads, a worker per session started by the app, reattach after a crash (with or without `windows.json`), a cold reopen on a new worker from the saved record, frames saved and restored, Fleet presence in `~/.local/state/vcx-rust/fleet`, the control socket (`open`, `send`, `setDir`, `setModel`, `close`, `frame`, `report`, `quit`), the command line through `vcx_cli`, the Edit menu, the task bar (`tasks` from each `$VCX_TASK_FILE`, `focus`), the page's `title`, the folder chip's panel, the Settings sheet's answer, the quota popover (Swift `QuotaOverview`, a minute's cache), the frontend verbs the worker refuses (`/login claude|codex|cancel|dismiss` with the sign-in panel in every window, `/window`, `/quit`, `/exit`, `/settings` and `/preview` handed to the page); sessions run on the Swift worker (default) or the Rust one (`"worker"` in settings.json, shipped as `Contents/MacOS/vcx-worker`); `../build-rust.sh --install` puts `~/Applications/VCX Rust.app` (`com.mr.vcx.rust`); 13 windows: 95 threads, 42 MB app and 684 MB in 13 WebContent processes, patch to page p95 11 ms (Outcomes); `tests/app.rs` 15 windowless tests.
- Rust app. Next: the Rust worker as the default waits on his word (it drives Claude, Qwen and agy since 5524b29); the takeover test Rust report owes before the app attaches to a session he works in.
- Rust worker. Done: `vcx-worker` (`3b3d841`), protocol v1 over the Codex app-server: leases, sequences and receipts, patches, Swift-format checkpoints, cold reopen of a killed worker with its history and unsent draft; conformance 21 of 21, the Swift `runtime_probe.py` 68 of 68 (as on the Swift worker), a Rust shell `--check` fixture turn; held fixture turns (`fixture:hold`, `fixture:approve`) and a worker exit marker for the suite (`b6f64ed`); Claude, agy and Qwen sessions through `vcx-agents`' `Connection`, the account picked from his settings as the Swift `Session` picks it, each provider's turn run end to end in `tests/providers.rs` (`5524b29`). K10: its own binary (3.6 ms to hello, 2.1 MiB idle, against 46.8 ms and 38.2 MiB for the Swift worker), sent to Rust report.
- Rust worker. Next: the Swift `Session`'s fallbacks (another account at a usage limit, rate-limit retries, a provider switch mid-conversation), `approvalPolicy` from his `mode`, and the agent log.
- Rust charts. Done: chart frames (`7abeb34`): sandboxed `vcx://chart/<id>` documents with their own CSP, the Swift page API (`vcx.chart` series, table, cards; `vcx.live` fetched by the core; pin above the chat, enlarge on double click, pinch, wheel and drag), lightweight-charts 5.3.0 vendored; `tests/charts.rs` 10 windowless tests pass, C3 refuted. From his templates: cards WT-084, table WT-085, the enlarged chart WT-118 (zoom popup), its buttons WT-033 (ghost icon size, light colours); `pane.rs` hands `vcx.live` to `chart::Feeds` (left for Rust app to commit).
- Rust charts. Next: new elements for him, drawn in the templates' style with no template of their own: the pinned chart strip at the top of the chat, and the series' hover legend kept from the Swift kit (WT-012, the pointer tooltip, is not used); not run: `vcx.live` in the real window and the Nasdaq `symbol` chart against the live API.
- Rust chrome. Done: `chrome.js`/`chrome.css` drawn from his web templates (02554e6): status word and bar chips as status pills (WT-037), progress and update chips with the progress bar (WT-104), the permission prompt as the bar dialog answering through `answer` (WT-072), the model, mode, models and quota popovers as the single pick (WT-046) with toggle chips (WT-034) and the table (WT-085), the task bar as the card bar (WT-050) with its empty state (WT-102); notices, the title; the session panel (fa2a057): Settings, the Hooks/Skills/Commands/MCP/MD Files/RAG count cards (WT-050) and their search lists (WT-030), Session ID copied through the core (WT-033 buttons, WT-020 copy check); the Settings sheet (0459d54): the bar dialog (WT-072) with the tabs (WT-105) Session, Accounts, Qwen, Background, Keys, each setting a name and value block (WT-055) that fills the composer's palette with its command, opened by Settings or ⌘, and asking the core with `{type: "settings"}`; the sign-in panel from a `{type: "login"}` message (Cancel, Dismiss); `tests/chrome.rs` 32 windowless tests pass. New elements for him, no template covers them: the status line's layout (pill, what runs, elapsed, "Your answer is needed"), the background job blocks and the keycaps. `src/progress.rs` reads the progress file (d0ec388), Pane's 2 s ticker sits in Rust app's uncommitted `pane.rs`. Next: nothing left to draw; waits on Rust app answering `settings`, `quota` and `chooseDirectory` and sending `login` (asked 26/11), and on the core naming a RAG line's ERRORS section (Swift `ErrorsRecall.section`). The view's meta keys (5e4a217), the task bar, focus and title (6ec6420), and answer, command and refresh (775ace9) are in.
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
- Rust agents. Done: `vcx-agents` holds Codex (the worker's client), Claude, agy and Qwen behind one `Connection`, each tested on a recorded (Codex, Claude) or hand-written (agy, Qwen) turn read into the same typed events, plus capabilities and models per provider; the Rust worker confirmed it runs its turns through this Codex client (3b3d841). Next: the worker switching from `Agent` to `Connection` for the other three providers.
- Rust report. Done: slice 1, the report, `vcx-conformance` (27 cases, green against the Swift worker and the Rust worker: handshake, sessions, actions, turns, held turns, worker exit, receipt expiry), the Swift recovery-list fix (`fb40939`), Rust pushes no longer reinstall the Swift app (`7181bf0`). The workspace run is green on a fresh checkout of `main` (`53509d4`: 452 tests, exit 0). The takeover test C4 asked for passes on the installed Swift app and fails on the one built before the fix (`crates/vcx-conformance/tests/takeover.rs`; `SwiftWorker::app()` in `vcx-testkit` runs the Swift app's headless entry points in the worker's folders). Not in the suite: `snapshotTooLarge` and the `busy` admissions, which the fixture agent cannot reach. Next: nothing owed; the same takeover made by the `vcx-rust` binary belongs in `crates/vcx-app/tests/app.rs` (Rust app).
