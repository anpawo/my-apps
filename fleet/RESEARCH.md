# Local coding-usage reference

Reviewed on 2026-11-24.

Source: https://github.com/goodnight000/tally

Tally is an MIT-licensed Tauri application that normalizes local coding-tool usage into SQLite and shows dashboards by tool, model, project and session. It includes Claude Code JSONL and Codex SQLite/JSONL parsers.

Possible reuse: compare its token normalization and usage views when extending Fleet's usage reporting. Its costs are estimates from configurable model rates, not subscription invoices. Compatibility with current transcript schemas and this project's sessions has not been tested.

Recommendation: a lower-priority reference for usage reporting, rather than another session-management app. No code was imported and no application behavior changed.
