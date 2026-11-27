# VCX Rust switch: multi-model review (27/11)

Subject: `vcx/rust/cutover/cutover.sh --to rust --rust-worker` and `--to swift`, read at 9a3b2f0 (main moved to abfa54a during round 2: the `native:` resume fix with its tests).

Verdict: **NO-GO**, unanimous (Claude, Codex, Qwen). Nothing was run against his live sessions; all reads were read-only.

Roster: Claude (native agent) answered both rounds; Codex `gpt-6.2-sol` answered both rounds; Qwen `qwen3.5-9b-abl` (local, PC) answered both rounds on pasted code only (cutover.sh, switch.sh, takeover.rs); agy failed (quota reached, resets in about 158 h); the web legs (Gemini, Grok, Muse, Meta) were not asked, as they cannot read a repo.

Confidence: 5 found blind by two or more; 4 accepted in round 2; 3 accepted after narrowing.

| # | Conf. | Severity | Where | Finding | Failure | Found by |
|---|---|---|---|---|---|---|
| A | 5 | critical | `cutover.sh:96-98`, `requests.rs:80-88`, `app.rs:447-451, 485-510` | An empty or partial takeover counts as success | `{"taken":[]}`, or an id returned after window build failed, still switches the launcher and trashes Swift | Claude, Codex, Qwen |
| B | 5 | high | `cutover.sh:86-116`, `app.rs:242, 472-477`, `settings.rs:9-25` | VCX Rust reads its worker setting once; with no settings.json the default is the Swift binary that cutover then trashes | after the switch every new window (vcx, Fleet, spawn, ⌥⌘J, ⌘N) has no worker until VCX Rust restarts; permanent without `--rust-worker` | Claude, Codex |
| C | 5 | high | `cutover.sh:79-98`, `switch.sh:43-58`, `main.swift:167-173` | switch.sh's preconditions and the updater pause run only after the SIGKILL; a Swift frontend launched during the up to 60 s cold start reclaims the entries | the script stops halfway ("Nothing changed") with windows split between the apps, or takeover skips windows a new Swift frontend owns | Claude, Codex |
| D | 5 | high | `takeover.rs` (read only), `main.swift:212-219`, `RuntimeServer.swift:185-196` | takeover never retires the Swift recovery entries | after `--to swift` the first Swift launch takes every live adopted session back out of VCX Rust, against the script header | Claude, Codex |
| E | 5 | medium (Claude), critical (Codex) | `RuntimeClient.swift:247-257`, `RuntimeRecovery.swift:157-161`, `takeover.rs:21-29, 68-76` | the window file's newer draft is ignored | keystrokes whose checkpoint was in flight at the SIGKILL are lost | Claude, Codex |
| F1 | 4 | critical | `worker.rs:65-71`, `homes.rs:107-110`, `switching.rs:244-265` | the cold path starts its worker in `~/.local/state/vcx-rust/worker`, never the record's Swift `stateDirectory` | a cold adopt or restore of a Swift window whose record lives only in Swift's state (all of the Mac's today) opens "Connection failed" (GONE) instead of its conversation; the record stays on disk, unreachable | Codex; Claude confirmed with live paths |
| F2 | 4 | critical | `app.rs:154-170, 365-376` | after a reboot (or any Swift worker exit) every taken-over window goes down that cold path | taken-over windows come back failed after the first reboot; those without a record ID are skipped outright (`app.rs:154-164`) | Claude; Codex confirmed. The "native: is dropped" part was refuted (`backend.rs:266-268` tries `named_resume` first; abfa54a pins it) |
| F3 | 4 | high | `app.rs:183-185, 457-458`, `vcx-proto/client.rs:16, 144-146` | a hello timeout (10 s) is treated as a dead worker | a slow mid-turn Swift worker runs on with no window, VCX Rust shows a failed window, nothing re-adopts it; the second-writer claim was refuted by F1 | Claude; Codex confirmed |
| G | 4 | medium | `cutover.sh:76-77, 121-131` | forward preflight checks only that the release exists, not its asset | rollback from the release is untested; the layout (`ditto --keepParent` at 92a827e) looks right | Codex; Claude confirmed |
| H | 4 | low | `takeover.rs:59-77` vs `RuntimeRecovery.swift:191-201` | stale entries are adopted without Swift's `hasSavedRecord` check | an extra failed window (one such entry on the Mac, owner 62200) | Claude; Codex confirmed |
| I | 4 | low | `app.rs:449`, `RuntimeUpdate.swift:131`, `app.rs:339-346` | frames dropped at adopt; a cold start opens a stray focused $HOME window first | windows come back centred and stacked, plus one extra window | Claude; Codex confirmed |
| J | 3 | low | `takeover.rs:59-61`, `RuntimeServer.swift:253-266` | `closeRequested` entries skipped; an unadmitted or failed close is never finished | that worker keeps its session alive (one on the Mac, owner 78952, live socket) | Claude, narrowed by Codex |

Refuted: Qwen's double-loop race (one SIGKILL per pid, then a wait), the `launchctl` "state = running" match (the Mac prints `state = not running` / `state = running`), and a settings.json race with the Swift updater (different files). PID reuse between the start-time check and the kill: milliseconds, low.

Unverified by all (L): whether running Swift workers still find `background.py` and `cleanup.py` once `Vibe Code X.app` is in the Trash (both skip silently when missing); whether the workers of a LaunchServices-started frontend survive its SIGKILL on the real Mac (the rehearsal starts them apart from the frontend; live, the 6 workers are children of frontend 15011, though they call `setsid`).

## What must change before the switch (all three legs)

1. Run every precondition before the SIGKILL: switch.sh's checks, the updater pause, and Swift launches blocked; the permanent launcher switch only once every attach succeeded (C).
2. Require every killed entry to be taken and confirmed attached (a snapshot, not the id `adopt` returns); otherwise fail before the launcher switch and give the windows back to a Swift frontend (A).
3. Write the worker setting before VCX Rust starts, and have an already-running VCX Rust re-read it or restart before the Swift bundle moves (B).
4. Cold paths reach the Swift record: pass its `stateDirectory` or migrate the record; prove it with a cold restore after a killed worker (F1, F2).
5. Only ENOENT or ECONNREFUSED on a worker not being launched means a dead worker; retry a hello timeout (F3).
6. Carry the newer window-file draft, and retire the Swift recovery entries only once VCX Rust has durably saved ownership and that draft (`app.rs:447-451, 967-971`) (D, E).

## Sign-off

- Claude: AGREE on every row, the verdict and the six items.
- Codex: AGREE on A, B, D, G, H, I, the verdict, items 3 and 4; its DISAGREE lines refined C (the 60 s counts sleeps only, socket waits add to it), E (critical when the draft never reaches the worker), F1, F2, F3 (a second writer stays possible: native locks can sit in separate folders, `archive.rs:48-51`, `NativeThreadLease.swift:61-76`), J (a later Swift launch can finish closes), the refuted list (the bare-PID wait has no bound, `cutover.sh:67-85`) and items 1, 2, 5, 6, all folded in above.
- Qwen: AGREE on A and the NO-GO; its other points were refuted.

Answers: the folder `$TMPDIR/deep/vcx-switch-5Eyi/` (`claude-1.md`, `codex-1.md`, `qwen-1.md`, round 2 `-2.md`).
