## Corrections to my round-one answer

- **Frontend Tokio was premature.** M5 demonstrates the first slice with standard threads and `EventLoopProxy`. Keep that implementation and measure queue pressure at 13 windows before adding an async runtime to the frontend.
- **Ammonia was premature.** M6 and `vcx-model/src/markdown.rs:8–24` show a renderer that escapes raw HTML and filters destinations at the parser boundary. Keep it for the current event set and test the destination policy in WebKit.
- **Virtualization and frame batching were premature requirements for the first slice.** M1 passed with a full DOM, and M3 showed that synchronous application and acknowledgement work while CSS animation stalls. Move both optimizations behind measurement.
- **My windowless recipe was too prescriptive.** M2 used `.build(window)` at `vcx-shell/src/app.rs:117`. It also shows that a successful snapshot callback can still capture invisible rows, as M3 demonstrated. Use the proven host path and control animation state explicitly.
- **I overstated byte compatibility.** M1 proves interoperability between the Rust encoder and Swift worker. Preserve v1 framing and semantics, including the same sequence and canonical action payload on retry. Matching every serialized byte across encoders is unnecessary. `vcx-proto/src/frame.rs:30–36`, `RuntimeServer.swift:238–246`.

## Disputed points

**D1 VERIFIED.** Frontend first over v1 is a working slice. M1 shows a full fixture turn through an unmodified Swift worker. The current integration test can skip when the Swift binary is missing, so require a non-skipped run in the migration gate. `vcx-shell/tests/windowless.rs:98–111`.

**D2 UNDECIDED.** The temporary textarea handles the send path and checks `isComposing`. M1 sends through the shell’s `--prompt` argument, so it settles neither IME nor keyboard routing. Compare the textarea plus chip strip with a native sibling `NSTextView` on the same marked-text, paste, undo and question-focus test. `template/app.js:181–191`, `vcx-shell/tests/windowless.rs:105`.

**D3 UNDECIDED.** Swift already freezes a provider and session snapshot, then execs in place with selected descriptors inherited. A compatible Rust adopter is plausible. Qwen’s under-1% loss figure is unsupported. Settle practical viability with an isolated Swift-to-Rust exec test that preserves the child PID, consumes a split frame once and survives a failed adoption. `RuntimeSession.swift:284–291`, `RuntimeSwap.swift:119–146`.

**D4 VERIFIED for placement.** M6 and `vcx-model/src/view.rs:28–42,62–66` put Markdown conversion in the frontend’s Rust projection. That path renders on projection, so a cache benefit remains open. Measure repeated render cost on a streamed long answer and history reattach before adding one. M1 shows worker-generated HTML is unnecessary for v1 interop.

**D5 VERIFIED for keeping v1 during coexistence.** M1 settles the first slice. Swift requires `protocol: 1` and parses the line as JSON, so a binary prefix on a v1 frame would break compatibility. Measure frame sizes and cumulative bytes on a long streaming replay to decide whether v2 deltas or paged history earn their cost. `RuntimeServer.swift:125–131`, `RuntimeTransport.swift:90`, `vcx-proto/src/client.rs:145–146`.

**D6 VERIFIED for the current shell.** M5 settles feasibility without Tokio. The source also starts a socket reader and deadline threads, so the named responsibilities are not an exact thread count. A 13-window soak with slow peers should measure backlog, thread count and p95 input latency before a scheduler change. `vcx-proto/src/client.rs:120`, `vcx-shell/src/app.rs:131–135`.

**D7 REFUTED as a requirement to add Ammonia now.** M6 and `markdown.rs:8–24,39–61` show event escaping, destination filtering and targeted tests. Those tests do not settle browser URL normalization or the native file-opening policy. Run a WebKit DOM and navigation corpus against the exact renderer, CSP and bridge before broadening accepted content.

**D8 UNDECIDED at production scale.** M1 disproves the need to virtualize before shipping the first transcript slice. `template/app.js:134–142` mounts every row. A 5,000-row streaming replay measuring first render, p95 patch and scroll latency, footprint, anchoring and cross-row selection should determine whether paging is enough.

**D9 VERIFIED for the measured harness.** M2 settles loading, DOM reads and snapshots with an unordered accessory window. M3 settles the need to control animation state for captures and contradicts any claim that disabling background throttling restores normal animation there. M7 settles timeout fallback in one window. The wrong-contract branch exists, while the timeout is what the cited windowless test exercises. `vcx-shell/src/app.rs:155–171`, `vcx-shell/tests/windowless.rs:115–130`.

**D10 UNDECIDED.** M2 proves IPC and script-driven DOM inspection. The windowless test asserts layout and PNG output. Settle native input with one unordered-window test that routes mouse down/up, ordinary keys and marked text through the intended responder path and asserts the resulting focus and values. `vcx-shell/tests/windowless.rs:75–94`.

**D11 UNDECIDED as a packaging choice.** Swift derives worker identity from the bundled executable’s hash, so its current scheme couples frontend rebuilds to worker updates. Separate binaries make that boundary explicit. Settle it with a signed frontend-only update while a worker streams and assert unchanged worker identity, worker and agent PIDs, and uninterrupted revisions. `RuntimeClient.swift:11–13`, `RuntimeSwap.swift:119–142`.

**D12 UNDECIDED.** M1 exercises a fixture in place of Codex, which gives Codex the shortest path from the existing test, but proves no Rust provider lifecycle. Compare Codex and Claude on the same start, interrupt, question or approval, and cold-resume parity spike. `vcx-testkit/src/lib.rs:1–2,31–36`.

**D13 REFUTED for seamless automatic return.** M4 directly contradicts Gemini. Swift marks the client superseded, cancels reconnect and closes the window, then removes it from the registry. Keep separate app state and use explicit handback. Verify Rust-to-Swift handback with a preserved draft and pending question. `RuntimeClient.swift:317–325`, `main.swift:213–217,467–471`.

**D14 UNDECIDED.** M1’s 3.17 seconds is fixture test runtime. It supplies no development-time evidence for any leg, including my 36–58 developer-day estimate. Record actual effort through one parity-complete frontend slice and one provider migration, then re-estimate the remaining work against those two results.

## Individual claims

**C1 UNDECIDED.** WebKit forwards key equivalents to WebCore when its view is first responder. Wry also has a parent-view path that forwards keys to the native menu. Settle actual ⌘C/⌘V/⌘A outcomes with a menu-on/menu-off run through the pinned shell’s ordinary event path. [WebKit key-equivalent handling, read 2026-11-25](https://raw.githubusercontent.com/WebKit/WebKit/refs/tags/WebKit-7624.5.1.11.3/Source/WebKit/UIProcess/mac/WebViewImpl.mm), [wry parent view, read 2026-11-25](https://raw.githubusercontent.com/tauri-apps/wry/wry-v0.58.1/src/wkwebview/class/wry_web_view_parent.rs).

**C2 REFUTED as a general rule.** tao 0.38 defaults to 800×600 physical pixels, and AppKit sizes the content view to the window. M2 used an explicit size, so its PNG gives no default-size comparison. Keep explicit dimensions for reproducibility. [tao window creation, read 2026-11-25](https://raw.githubusercontent.com/tauri-apps/tao/tao-v0.38.0/src/platform_impl/macos/window_delegate.rs), [AppKit content view, read 2026-11-25](https://developer.apple.com/documentation/appkit/nswindow/contentview.md).

**C3 UNDECIDED.** M2 verifies the custom scheme for the top-level page. The current CSP has no `frame-src` or `child-src`, so a blocked iframe URL load under this policy would not establish a custom-scheme limitation. Run the same opaque-origin chart, message bridge and denied-network assertions under `vcx:` and loopback with explicit frame policies. `template/index.html:6`. [CSP fallback rules, read 2026-11-25](https://w3c.github.io/webappsec-csp/).

**C4 UNDECIDED for an update race.** The “every worker it knows” explanation is refuted. Swift restores its window ticket, and ordinary lease loss removes the old window. During replacement, the lease-loss close is suppressed and the replacement path can reclaim or replay an entry. Force lease theft after ticket creation in the isolated Swift replacement harness and inspect the final writer. `main.swift:130–142,213–217,299–345`.

**C5 UNDECIDED as stated.** Bug 331092 verifies the off-Space visibility change and private override in that reporter’s ordered-window setup. The tagged code separately rejects a window that is not visible, so the override does not generalize to M3’s unordered window. A controlled occlusion test on the target build would settle which supported configurations preserve the required rendering behavior. [Bug 331092, read 2026-11-25](https://bugs.webkit.org/show_bug.cgi?id=331092), [WebKit visibility checks, read 2026-11-25](https://raw.githubusercontent.com/WebKit/WebKit/refs/tags/WebKit-7624.5.1.11.3/Source/WebKit/UIProcess/mac/PageClientImplMac.mm).

**C6 REFUTED.** `main.swift:592–630` takes a socket path and starts a `RuntimeServer`. `RuntimeClient.swift:189–207` connects to it. The proposed `--runtime-url` path reverses these roles. M1 exercised the actual direction.

**C7 REFUTED as three corroborating sources.** ChatOverflow reports offscreen experiments and Asyar describes its parked panel. Unstuck Agents PC-342 is about activation policy and reports Linux-only checks. M2 makes private occlusion settings unnecessary for VCX’s measured snapshot path. [ChatOverflow field note, read 2026-11-25](https://chatoverflow.dev/n/run-wkwebview-test-harnesses-invisibly-without-throttled-raf-31dffa4a52c1), [Asyar lifecycle, read 2026-11-25](https://asyar.org/docs/explanation/launcher-rendering-lifecycle), [PC-342, read 2026-11-25](https://unstuckagents.com/notes/cards/PC-342).

## Final recommendations

D1. Continue frontend first over v1. Require a non-skipped fixture turn and a bidirectional handover before using live sessions.  
D2. Keep the textarea in the canary and favor a native sibling editor for parity. Decide after the same IME, chips and responder test runs against both.  
D3. Drain Swift workers and cold-resume. Reopen adoption only if cold-resume measurements justify the isolated exec test.  
D4. Render Markdown in the frontend’s Rust core. Add a bounded cache if render profiling shows repeat work matters.  
D6. Keep standard threads and `EventLoopProxy`. Revisit Tokio for the frontend after the 13-window soak.  
D7. Keep event-level filtering and a restrictive CSP. Let the WebKit corpus decide whether a second sanitizer is needed.  
D8. Keep the simple list for fixtures. Use the 5,000-row replay to choose paging or virtualization before daily-driver rollout.  
D11. Package separate frontend and worker executables in one bundle, with independent update identities. Verify that a signed frontend-only update leaves the worker and agent in place.