
- 04/11/2026: Native instances merge shared settings under a process lock and keep account/thread ownership transactional; failed connections must preserve saved conversations, and each editable record has one window owner. Temporary command drafts belong to their source record and must clear before restoring another conversation; asynchronous restores and rollbacks must retain intervening text and image edits through shared user-edit tracking, and connection startup must stay serialized.
- 04/11/2026: Freeze source edits during Swift builds, including delegated edits; the compiler rejects files modified while it runs.
- 04/11/2026: Check saved configuration formats before tightening validation; Jarvis proxy URLs include the socks5h scheme.
