//! The command line of the Rust app. `vcx-rust` is its only binary (built by `vcx-app`): it parses here, opens
//! windows itself (`Command::App`) and hands every other command to [`run`]. Nothing here replaces
//! `~/.local/bin/vcx`, which keeps starting the Swift app.
//!
//! Every flag of the Swift `vcx` today (the launcher `~/.local/bin/vcx`, `main.swift`, `background.py`), and where
//! it went:
//!
//! - Here, against the running Rust app: `--cwd`/`-C <folder>`, `--resume`/`-r [id]`, `--focus`, `--` and bare
//!   words (the first prompt), `--sessions`, `--send <window> [--from <window>] <text…|->`, `--set-dir <window|self>
//!   <folder>`, `--set-model <window|self> [provider] [model] [effort]`, `--close <window>`, `--version`, `--help`,
//!   `--runtime-protocol`; and `--windowless` (new: the app with no window shown, for checks).
//! - Handed to `background.py`, as the Swift app does: `-p`/`--print`/`--headless`, `--ensure-qwen`, and with them
//!   `--provider`, `--codex`, `--output-format`, `--input-format`, `--model`, `--resume`, `--fork-session`,
//!   `--session-id`, `--session-id-format`, `--system-prompt`, `--append-system-prompt`,
//!   `--append-system-prompt-file`, `--json-schema`, `--tools`, `--allowedTools`, `--disallowedTools`,
//!   `--setting-sources`, `--settings`, `--mcp-config`, `--permission-mode`, `--effort`, `--max-turns`, `--add-dir`,
//!   `--strict-mcp-config`, `--disable-slash-commands`, `--no-session-persistence`, `--dangerously-skip-permissions`,
//!   `--restricted`, `--verbose`, `--include-partial-messages`, `--cwd`.
//! - Refused with the reason ([`ELSEWHERE`]): the live update (`--update-now`, `--publish-update`, `--manual`,
//!   `--restore-windows`, `--adopt-check`), the old terminal interface (`--terminal`), the Swift app's debugging
//!   entries (`--recall`, `--route-project`), its checks built into the binary, now `cargo test`, and its worker
//!   and fixture flags, which belong to `vcx-worker`.

pub mod commands;
pub mod control;
pub mod fleet;
pub mod parse;

pub use commands::{Context, run};
pub use parse::{Command, ELSEWHERE, Open, USAGE, parse};
