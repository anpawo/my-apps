# Errors

One line per mistake of mine: date, what I did wrong, what to do instead.

- 2026-11-03: `resumeID` is used by both normal binding and cross-project rescue; update both callers when changing its signature.
- 2026-11-04: Check the displayed card title when naming fails; parsing a full prompt does not make it a dashboard label.

- 2026-10-12 — Ran `--bench-panel` eight times and a `--render` of the live fleet to compare two binaries, without reading what a run fetches; each one read the hub's Firestore collections whole, the day's 50k reads ran out on the last, and a Fleet restarted before 09:00 had no mail or todos to show — before a mode is run in rounds, read what it fetches: `--render` and `--bench-panel` now draw the kept copy (`Firestore.reads`), every other mode that builds a hub still reads, against the 35k a day Fleet allows itself.
- 2026-10-12 — Ran `./install.sh` while `/tmp/fleet.log` already said `daily read quota exhausted`, minutes after reading the line above; the restart emptied MAIL and TODO until 09:00, just after he had chosen to wait rather than lose them — before an install, read the log's last `hub fetch` line: when the quota is spent and the build about to start has no kept copy to show, the restart is his call, "install after every change" does not cover what it costs that day.
- 2026-10-20 — Shipped Echo's glass copied as is, checked only through `--render`, which draws a gradient in its place; in Fleet's light appearance the backdrop layer is `Backdrop`, Echo's exact match on `backdrop` hid it and the panel had no blur at all — code that reaches into private layers is checked in Fleet's own hierarchy before install: dump the layer tree from the `--render --live` window, never shown.
- 2026-11-17: Asked why a session sat on its own card, I changed Fleet's project rule to follow a worktree in /tmp back to its repo; the cause was the worktree's place (outside s14), another session was already moving it, and my rule then put it on a separate "scientcapital" card. A wrong card is first traced to where the session's folder is, and fixed there.
- 2026-11-24: SwiftUI's accessibilityReduceMotion environment value is read-only; a windowless test uses a local preview override instead of trying to set it with .environment.
- 2026-11-24: Real roadmap loading took 0.627 seconds but the renderer waited 0.5; await source completion and inspect a real-source frame, since synchronous fixtures hid the race.
- 2026-11-24: Tinted every roadmap column with the same color and left labels faint; use distinct project colors and check text contrast and step boundaries together.
