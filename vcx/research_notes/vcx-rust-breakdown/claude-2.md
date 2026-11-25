# Round 2, Claude leg: cross-examination

Read whole on 2026-11-25: brief.md, claude-1.md, codex-1.md, muse-1.md, grok-1.md, qwen-1.md, gemini-1.md, disagreements.md, every source file under `vcx/rust` (crates, template, fixtures) and the Swift files cited below. Web sources were read with curl on 2026-11-25. Nothing was built or run.

## My own round-1 claims I now think wrong

1. **S1 (a full conformance suite) as a gate before the frontend.** M1 got a working frontend against the Swift worker with one 52-line interop test (`vcx-proto/tests/swift_worker.rs`). The suite belongs before the Rust worker (my S6), not before the frontend.
2. **A tokio runtime in the frontend.** M5: plain std threads (`vcx-runtime-reader` `client.rs:120`, `vcx-link` `link.rs:27`, `vcx-session` `session.rs:90`, `vcx-template-watch` `template.rs:189`) plus `EventLoopProxy` are enough. Changed.
3. **"Use `inactiveSchedulingPolicy`/occlusion settings" as the cure for hidden windows** (my risk table and section 5). WebKit decides visibility from the window, not from that policy. `PageClientImplMac.mm:211-233` (WebKit main, https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/UIProcess/mac/PageClientImplMac.mm): `if (!viewWindow.isVisible) return false;` comes before the occlusion test. M3 is that line at work: a `with_visible(false)` window with `BackgroundThrottlingPolicy::Disabled` is still `hidden`. Changed.
4. **The mechanism behind C4.** The update ticket lists only the windows the Swift frontend still holds, so "the replacement restores windows Rust holds" is mostly wrong. The real paths are below under C4. Refined.
5. **The S2 proof "time to first paint" in the windowless pagetest.** M3: an unshown window gets no frames, so first paint and frame budgets cannot be measured there. Only DOM-apply time and forced-layout time can. Changed.
6. **Claude as the first Rust worker provider (D12), ammonia as required (D7), `Prohibited` as a harness policy (D9), and a Markdown HTML cache from day one (D4).** All four changed, each with its evidence below.

## Disputed points

**D1, port order: VERIFIED (frontend first).**
- M1 and M9: an unmodified Swift worker is driven by the Rust shell from prompt to answer, by real keys and a click.
- Grok's worker-first order and Qwen's core-first order are not refuted by a measurement, but nothing measured supports them either.
- Qwen's order rests on C6, which is refuted.

**D2, composer: UNDECIDED.**
- M9 covers only letters, digits and the space typed into the page's textarea.
- `app.js` already refuses Enter while `event.isComposing`, but no IME path has run.
- WKWebView does implement `NSTextInputClient` and `NSTextInputClient_Async`, with `setMarkedText:selectedRange:replacementRange:` (`WKWebViewMac.mm:108-109, 667`, https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/UIProcess/API/mac/WKWebViewMac.mm). So the IME test I proposed is possible on the shipped view.
- A trap for both options: a real paste test reads `NSPasteboard.general`, which is the owner's clipboard. Paste checks must stay page-side, using a synthetic `ClipboardEvent` with a `DataTransfer`.

**D3, live adoption from Swift into Rust: VERIFIED (never).**
- `RuntimeSwap.swift:92, 138, 142`: the swap execs the installed Swift path with `--adopt <file>`.
- No `SCM_RIGHTS` or `sendmsg` exists anywhere in the Swift sources (grep), so Muse's fd-passing variant would need new Swift code as well.
- A separately launched Rust worker cannot pick up the pipes (Codex's point). No measurement argues for it.

**D4, where Markdown becomes HTML: VERIFIED (frontend core). The cache part is UNDECIDED.**
- M6 and `view.rs:66`: `markdown::to_html` runs in the frontend each time a row is redrawn, with no cache (grep finds none), and it works.
- Muse's in-worker HTML cannot exist while Swift workers do, and a worker cannot key on the frontend's template.
- I drop "cache from day one". It comes back only if a measured per-patch render of a long streaming answer misses its budget.

**D5, protocol v2: UNDECIDED (no new evidence).**
- The build speaks v1 with `serde_json::Value` maps and typed accessors, not the serde structs with flattened unknown fields I proposed. That was enough for interop, so typed wire structs are not a prerequisite.
- The cost of resending whole items stays unmeasured. Each patch carries whole items, and `view::patch` re-renders the whole row's Markdown.

**D6, frontend concurrency: REFUTED for tokio, VERIFIED for plain threads (M5). I changed position.**
- Caveat: the shell is one process per window today ("One VCX session window", `main.rs:1`). That is four long-lived threads per window, plus one short-lived thread per timer (`app.rs:141`).
- Thirteen windows in one frontend process has not been measured. That move, and not tokio, is the open question.

**D7, sanitizer: REFUTED as "ammonia required". I changed position.**
- In pulldown-cmark 0.13.6, `html.rs:122` writes only `Html`/`InlineHtml` events raw. Text, code, link and image targets, titles and the code language all go through `escape_html`/`escape_href` (`html.rs:103-201, 266, 336-379`).
- `markdown.rs` turns both raw events into `Text` and blocks non-allowlisted schemes. The page CSP has no `'unsafe-inline'` (M6), so even an escaping slip would not run inline script or handlers.
- Ammonia is needed only if VCX decides to render a raw-HTML subset such as `<br>` or `<details>`, which today show as text.

**D8, long threads: UNDECIDED.**
- `app.js` has neither a virtual list nor `content-visibility`, and no 5,000-row run exists.
- M3 narrows what can decide it windowless: DOM-apply time, forced-layout time (`getBoundingClientRect` after a patch), DOM node count and WebContent RSS. Not scroll smoothness.
- My rule stands, restated: start with `content-visibility: auto` plus paged older rows, and switch to a virtual list if those figures miss budget.

**D9, the unshown check window: VERIFIED (`with_visible(false)` + Accessory), settled by M2, M3, M8, M9.**
- Muse's `orderBack` + private occlusion approach puts a real window in the window list. It buys only running animations and timers, which the checks no longer need (`check.rs` finishes animations; `app.js` applies messages without rAF).
- I drop `Prohibited`. Apple: "The application doesn't appear in the Dock and may not create windows or be activated" (https://developer.apple.com/tutorials/data/documentation/appkit/nsapplication/activationpolicy-swift.enum/prohibited.json).
- Gemini's `beginActivity` and `layoutSubtreeIfNeeded` were not needed: M2's snapshot worked without them.

**D10, synthetic input: VERIFIED for keys and clicks (M9). UNDECIDED for IME, modifiers and ⌘ shortcuts.**
- M9 used `makeFirstResponder` + `sendEvent` for keys and `mouseDown:`/`mouseUp:` on the view (`input.rs`), in a window that was never key.
- See C1 for why ⌘ shortcuts need a menu before such a test can pass.

**D11, worker binary: UNDECIDED (no new evidence).**
- The build already ships the frontend as its own binary (`vcx-shell`), so a template or frontend push cannot invalidate Swift workers.
- The question reopens only for Rust workers. Today the build hash is the executable's SHA-256 (`RuntimeClient.swift:12-13`, reread today).

**D12, first Rust worker provider: Codex. I changed position.**
- The interop fixture is "A stand-in for `codex app-server`" (`fixtures/fake_agent.py:1`), and the Swift worker loads it through `--runtime-fixture-command`.
- A Codex-first Rust worker therefore runs the very fixture the Swift worker passes, which gives side-by-side conformance for free. Claude second.

**D13, coexistence: VERIFIED (a second app, shared runtime folder, explicit socket).**
- Gemini's "closing it lets Swift re-attach seamlessly" is REFUTED by M4.
- But Swift does re-attach later, uninvited (see C4). So coexistence needs one small Swift change: a window closed by `leaseLost` must leave the recovery list.

**D14, effort: UNDECIDED. I yield part of my figure.**
- disagreements.md says M1 to M7 were built while round 1 ran (brief.md 18:07, this round's message 18:50 by file times). That covers most of my S0 and S2 and parts of S3 and S5, which I priced at 10 to 17 days.
- The hard remainder is unmeasured: IME, 13 windows in one process, charts, Rust workers, self-swap.
- New estimate: 25 to 45 working days in total.

## Single-leg claims

**C1 (Edit menu): VERIFIED from source, not yet measured.**
- tao 0.38.0 installs no main menu (no `mainMenu` in `platform_impl/macos`).
- An unhandled ⌘ key is resent through `[NSApp sendEvent:]` (`WebViewImpl.mm` `doneWithKeyEvent`, WebKit main), and wry's parent view forwards keys only to `app.mainMenu()` (`wry-0.58.1 wry_web_view_parent.rs:30-35`).
- The Swift app builds exactly that menu (`main.swift:125-126`).

**C2 (0×0 web view without a size): REFUTED.**
- tao 0.38.0 `window_delegate.rs:174-176`: with no inner size, the window gets `PhysicalSize::new(800, 600)`.
- M2 sets 980×720 explicitly, so the measurement does not test the default.

**C3 (sandboxed chart iframes under the custom scheme): UNDECIDED.**
- I found no source saying a custom scheme blocks sandboxed frames.
- A nearer trap: a `srcdoc` chart inherits the page CSP (`script-src 'self' vcx:`, M6), which blocks its inline scripts. Charts must be served as `vcx://chart/<id>` documents with their own CSP header.
- Also, `bridge.rs` `is_template` already keeps frames from posting to the core.

**C4 (Swift takes sessions back from Rust): VERIFIED, by two paths other than the one I named.**
- Cold launch: a window closed on lease loss (`main.swift:212-217`) never reaches `requestClose`/`remove`. Those run only in `beginClose` (`main.swift:433`) and the `close` action (`RuntimeClient.swift:227-238`). Its `.window.json` stays, and once its owner pid is dead (`RuntimeRecovery.swift:147`) a cold launch reattaches it (`main.swift:170-174`). Swift also quits when Rust takes its last window (`main.swift:473`), so the next launch of Swift steals the session.
- During an update: `guard !self.updating` keeps a superseded window open, and the update's `reclaim()` (`main.swift:312, 344`, `RuntimeClient.swift:106-108`) or the replacement's `connect` attaches again.

**C5 (only the private occlusion setter keeps a page visible): partly VERIFIED.**
- Bug 331092 (filed 2026-11-11, NEW, rdar 193106428) measured a WKWebView on another Space "page hidden for 28.037 seconds", and with `_setWindowOcclusionDetectionEnabled:false` "page remained visible" (https://bugs.webkit.org/show_bug.cgi?id=331092).
- That holds for an ordered-in, occluded window only. `isViewVisible` returns false for a window that is not visible before occlusion is consulted, so no setter helps a `with_visible(false)` window (M3).
- WebKit main also gates both tests on a `backgroundTextExtractionEnabled` configuration. I have not checked whether macOS 26's shipped WebKit has it.

**C6 (`--runtime-url`): REFUTED.**
- Grep of the Swift sources finds no `runtime-url`. The runtime flags are `--runtime-worker`, `--runtime-test`, `--runtime-fixture-command`, `--runtime-protocol` and the check flags.
- The worker is the socket server.

**C7 (Muse's weak sources): VERIFIED weak.**
- The chatoverflow page Muse cites describes itself as "The network where AI agents learn from each other", with notes and comments by agent handles.
- Its claims agree with primary sources: KVC key `windowOcclusionDetectionEnabled` resolves to `_setWindowOcclusionDetectionEnabled:` (`WKWebViewMac.mm:1990`), and the public policy does not unhide a page (M3).
- They remain unreviewed agent notes. Its "never ordered in, so iframe init stalls on a 10 s reply" claim is unchecked and matters for chart tests.

## Where measurements settle points

- M1 and M9 settle D1 and the key/click half of D10.
- M2, M3, M8 and M9 settle D9 and refute my throttling cure.
- M3 also limits what D8 can measure windowless.
- M4 refutes Gemini's D13 claim, and with the Swift code it confirms C4.
- M5 settles D6. M6 settles D4's location and, with the pulldown-cmark source, D7.
- M7 and M8 confirm my template contract: a 3 s ready, a contract number, last-good.
- A side note: the comment at `app.rs:122` ("keeps following its session at full speed") holds only for messages delivered by `evaluate_script`, not for timers or rAF (M3).

## Final recommendation

- **D1:** Frontend first against unchanged Swift workers, with the conformance suite built before the first Rust worker.
- **D2:** Composer in the page (textarea + chip strip), kept only if the IME check passes.
- **D3:** No Swift-to-Rust live adoption. Idle Swift sessions close and reopen cold.
- **D4:** Markdown rendered in the frontend core on each row redraw, cache added only after a measurement.
- **D6:** Plain threads + channels + `EventLoopProxy` in the frontend. Tokio only in the Rust worker.
- **D7:** Event-level escaping + scheme allowlist + strict CSP. Ammonia only if a raw-HTML subset is wanted.
- **D8:** `content-visibility: auto` + paged older rows. A virtual list only if the 5,000-row figures miss budget.
- **D11:** A separate `vcx-worker` binary with its own hash.

## What would settle each open point

- **D2 and D10 (IME):** in the M9 harness, call `setMarkedText:` then `insertText:` on the WKWebView with the textarea focused (dead-key `´`+`e`, and a kana composition), then read `input.value` and the composition events.
- **D5:** a byte counter on the socket during a 50 KB fixture answer.
- **D6 at scale:** one shell process holding 13 windows, measured for threads and RSS.
- **D8:** a 5,000-row demo state in the windowless check, timing apply plus forced layout per patch, with node count and WebContent RSS.
- **D11:** `git log` over the last month, counting pushes to main that touched only frontend or template files.
- **D14:** the commit times of `vcx/rust`.
- **C1:** a ⌘A key event sent with and without an Edit menu, then read `getSelection()`.
- **C3:** a `vcx://chart/1` sandboxed iframe in the unshown window that posts a message to its parent.
- **C4:** the Swift fix (drop the recovery entry on `leaseLost`), then a cold Swift launch while Rust holds the session.
