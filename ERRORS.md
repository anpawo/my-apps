
- 04/11/2026: Native instances merge shared settings under a process lock and keep account/thread ownership transactional; failed connections must preserve saved conversations, and each editable record has one window owner. Temporary command drafts belong to their source record and must clear before restoring another conversation; asynchronous restores and rollbacks must retain intervening text and image edits through shared user-edit tracking, and connection startup must stay serialized.
- 04/11/2026: Freeze source edits during Swift builds, including delegated edits; the compiler rejects files modified while it runs.
- 04/11/2026: Check saved configuration formats before tightening validation; Jarvis proxy URLs include the socks5h scheme.
- 04/11/2026: Swift search filters explicitly allow empty queries: String.contains("") and localizedCaseInsensitiveContains("") return false. Standalone probes of Foundation string methods import Foundation.
- 04/11/2026: Swift usage fixtures need explicit JSON types and isolated display sessions; inferred dictionaries promote integer fields to Double, and exhausted Codex windows persist fallback settings that affect later checks.
- 04/11/2026: Composer input checks recreate its retained NSTextStorage, NSLayoutManager and NSTextContainer; a standalone ComposerText with a nil container has no storage and cannot test typed text.
- 04/11/2026: Keep prompt timestamps in saved message data; restoring a UI row creates a new UUID, not a newly sent prompt.
- 04/11/2026: Asynchronous selection checks wait for command completion, not a selected value that may already equal the target.
- 04/11/2026: Scope new fixture variables in Check.run in a do block; shared local names can collide with later checks and fail compilation.
