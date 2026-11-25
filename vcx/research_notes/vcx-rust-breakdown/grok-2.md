Own round-1 claims I now retract or revise

I claimed Rust workers under the Swift frontend should come first. M1 already shows a working tao+wry frontend attached to an unmodified Swift worker and drawing a full turn; the measured path is therefore frontend-first against live Swift workers. That claim is REFUTED by M1.

I treated live FD takeover of a running agent as “optional if a measurement shows it reliable.” No such measurement has been made; every other leg that measured recovery prefers cold reopen from provider history. I still mark it optional, but lower priority than I implied.

I said “channels in the frontend.” M5 confirms exactly that (plain threads + channels + EventLoopProxy, no tokio in the frontend dependency tree). That part stands.

Everything else I said is either aligned with the build or still open.

D1 – Which end is ported first
VERIFIED (frontend first against Swift workers). M1: Rust tao 0.38 + wry 0.58.1 shell already attaches to an unmodified Swift worker, runs hello/attach/perform/session/update/detach, and draws a turn. The measured path is the one four other legs preferred.

D2 – Composer
UNDECIDED. Native NSTextView still looks safest for IME and chips on macOS-only, but M9 only proved plain key events into a page textarea; IME, marked text, paste and ⌘ shortcuts are unmeasured. Gemini’s claim that a native overlay clips popovers remains untested. A temporary page textarea (as Muse suggested) is the pragmatic next step while the native path is prototyped.

D3 – Rust worker adopting a running agent (pid/fds/unread)
UNDECIDED / lean REFUTED for the first cut. No measurement exists. Cold reopen from provider history is already the recovery path in the brief and is what three legs chose. Keep the freezeForSwap surface for later; do not block on it.

D4 – Where Markdown becomes HTML
VERIFIED (frontend Rust core, cached there). M6: pulldown-cmark 0.13 events, raw HTML escaped at the event level, scheme-limited links/images, no ammonia. Matches Codex/Claude and the build.

D5 – Protocol v2
VERIFIED (only once both ends are Rust). M1 still speaks pure v1. No need to negotiate or dual-stack during the move.

D6 – Frontend concurrency
VERIFIED (plain threads + channels + EventLoopProxy; tokio only in the worker). M5: “The frontend uses no async runtime \ldots 26 unit tests, no tokio in the dependency tree.” Matches Muse and the build; my earlier “channels” statement was correct.

D7 – HTML sanitizer
VERIFIED (escape at event level is sufficient for now). M6: raw HTML events emitted as escaped text; CSP is strict (default-src 'none'; \ldots). ammonia is not present and not required by the current threat model. Adding it later is cheap; the build already chose the lighter path.

D8 – Long threads
UNDECIDED (no 5 000-row measurement yet). Virtual list from the first slice remains the conservative choice; Claude’s “content-visibility first, virtualise only if budget missed” is still viable once the page test exists.

D9 – Unshown check window
VERIFIED (with_visible(false) + Accessory + BackgroundThrottlingPolicy::Disabled). M2 and M3: page loads, lays out non-zero boxes, answers IPC and evaluate_script_with_callback, takeSnapshot returns a real 1960×1440 picture; visibilityState is hidden and CSS animations do not advance until finish() is forced. Matches the measured path.

D10 – Synthetic input
VERIFIED for basic keys and clicks. M9: NSEvent keyDown/Up and mouseDown/Up sent to the never-shown web view put 23 characters into the textarea and clicked the send button; the Swift worker ran the turn. IME/marked text/paste still open.

D11 – Worker binary
UNDECIDED. One binary with --runtime-worker (my prior position, Gemini, Muse) is simplest and matches the existing Swift design. A separate vcx-worker binary (Claude) gives independent update hashes. No measurement yet decides it; either works with the current socket protocol.

D12 – First provider of the Rust worker
UNDECIDED. Codex shape is the common event surface; Claude is the most-used. The build has not yet implemented a Rust worker, so the question is not yet live.

D13 – Coexistence
Partially VERIFIED / REFUTED. A second app is the safe default (all frontend-first legs). M4 shows that taking a lease closes the Swift window and the Swift frontend does not reopen it automatically when the Rust window closes; Gemini’s “closing it lets Swift re-attach seamlessly” is therefore REFUTED by M4. Shared state directories are still possible but require explicit lease hand-back logic that does not yet exist.

D14 – Effort
UNDECIDED. My 10–14 weeks was an upper-bound estimate before M1–M9. The measured first slice already exists, so the remaining work is smaller than a pure green-field estimate; Gemini’s 19–26 days looks optimistic once IME, charts, multi-window memory and live-update are counted. Real calendar time will land between the short and long estimates once the remaining unmeasured items are sized.

Claims

C1 (Edit menu required for ⌘C/⌘V/⌘A): UNDECIDED / lean VERIFIED. wry historically removed its own keypress handlers so that copy/paste go through the menu (wry commit 5a9df15, 2021). No measurement in the current build yet; an Edit menu is cheap insurance.

C2 (unshown window without explicit size → 0×0): UNDECIDED. M2 used a 980×720 viewport and got non-zero layout; the zero-size case was not tested.

C3 (sandboxed iframes under custom scheme may fail): UNDECIDED. Custom-scheme origins are known to be tricky for sandboxed iframes (various WebKit reports); a loopback HTTP fallback is a reasonable contingency but not yet measured.

C4 (Swift frontend update can reclaim sessions from Rust): UNDECIDED. Plausible from the existing lease protocol, but not demonstrated.

C5 (occlusion detection / private _setWindowOcclusionDetectionEnabled:): PARTIALLY VERIFIED. WebKit has long had the private API and TestWebKitAPI disables it precisely because occluded host windows mark the page hidden (bugs.webkit.org 328223, read 25 Nov 2026). M3 already shows visibilityState=hidden under with_visible(false); the private call is not required for the current check suite because the page never waits on RAF.

C6 (--runtime-url flag): REFUTED. The brief and the v1 protocol make the worker the server; no such flag exists.

C7 (Muse’s three weak sources for private occlusion settings): REFUTED as authoritative evidence. The real WebKit source (bugs.webkit.org and the private API history) is stronger; the three sites named are not needed.

Final recommendations (one line each)

D1: Frontend first against Swift workers (settled by M1).
D2: Page textarea for the next slice; prototype native NSTextView in parallel; settle with an IME + paste measurement.
D3: Cold reopen only for now; settle with a freezeForSwap reliability measurement if ever attempted.
D4: Frontend core with pulldown-cmark + event-level escape (settled by M6).
D6: Plain threads + channels + EventLoopProxy in the frontend (settled by M5).
D7: Keep the current escape-only path; add ammonia only if a concrete XSS vector appears.
D8: Virtual list from the first transcript slice; settle with a 5 000-row windowless timing test.
D11: One binary with --runtime-worker until an independent worker update story is required; settle by measuring whether frontend pushes force unwanted worker restarts.