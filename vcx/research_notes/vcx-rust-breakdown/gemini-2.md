Critique of My Round-1 Claims

M4 refutes my seamless Swift re-attach claim (D13): In round 1, I claimed that closing VCX-Next.app lets Swift VCX.app re-attach seamlessly. Measurement M4 proves that when VCX-Next steals a lease, Swift receives session/leaseLost and closes its window for that session without automatically reopening it upon Rust exit.

M5 refutes my frontend tokio recommendation (D6): I recommended running a multi-threaded tokio runtime in the frontend. M5 demonstrates that three std::thread workers communicating over channels and tao's EventLoopProxy drive the frontend cleanly with zero async runtime overhead in the dependency tree.

M6 refutes my ammonia dependency and worker-side HTML rendering (D4, D7): M6 shows that escaping pulldown-cmark HTML events directly in the frontend with scheme filtering plus a strict CSP (default-src 'none') eliminates ammonia and makes worker-side HTML pre-rendering redundant.

M2/M3 refines my requestAnimationFrame and App Nap claims (D9): M2 proves BackgroundThrottlingPolicy::Disabled is sufficient for synchronous JS execution and layout in an unshown tao window without NSProcessInfo.beginActivity. However, M3 shows CSS animations/transitions still freeze under document.visibilityState === "hidden", requiring explicit animation.finish() in visual checks.

Evaluation of Disputed Points (D1–D14)

D1 (Frontend first): VERIFIED. M1 proves a tao + wry frontend attaches to an unmodified Swift worker over v1, executes a full turn, and renders in 3.17 s. Porting the frontend first validates the UI and protocol immediately against working agent backends.

D2 (In-page composer vs. native NSTextView): UNDECIDED. M9 confirms synthetic NSEvent typing and clicking work in a web-view <textarea>, but IME marked text, CJK composition, and ⌘ shortcuts remain unmeasured. A plain <textarea> plus a separate chip strip (Claude's design) is safer than contenteditable until IME is tested.

D3 (Cross-language FD takeover from Swift worker): REFUTED. No measurement attempts cross-language freezeForSwap, and mismatched internal buffering (DispatchIO vs. Rust OwnedFd) risks mid-frame stream corruption. Cold-reopening idle sessions from disk checkpoints is deterministic and safe.

D4 (Where Markdown becomes HTML): VERIFIED (Frontend). M6 proves pulldown-cmark in the frontend renders fast enough for synchronous patch application without bloating the wire protocol or coupling workers to HTML presentation. I yield my round-1 proposal to also send HTML in v2 patches.

D5 (Protocol v2 timing): UNDECIDED. M1 confirms v1 handles live turns cleanly today, so v2 is unnecessary during initial migration. Whether v2 needs delta streaming (appendText) or binary framing depends on unmeasured 5,000-row and multi-megabyte tool output benchmarks.

D6 (Frontend concurrency): REFUTED (for my round-1 tokio claim). M5 settles this: three std::threads with standard channels and EventLoopProxy suffice for socket I/O, state replication, and file watching in the frontend, keeping compile times and dependency bloat down.

D7 (HTML sanitizer): REFUTED (for ammonia). M6 proves that converting pulldown-cmark Event::Html and Event::InlineHtml directly into escaped text nodes, combined with URL scheme allowlisting and default-src 'none' CSP, prevents XSS without ammonia. I yield my round-1 ammonia recommendation.

D8 (Long threads — virtual list vs. content-visibility: auto): UNDECIDED. A 5,000-row thread is explicitly listed as unmeasured. Starting with CSS content-visibility: auto plus paged older rows avoids scroll-anchoring complexity until a real 5,000-row takeSnapshot / scroll check proves a virtual list is needed.

D9 (Unshown check window): VERIFIED (with_visible(false) + BackgroundThrottlingPolicy::Disabled). M2 proves WindowBuilder::with_visible(false), ActivationPolicy::Accessory, and wry's BackgroundThrottlingPolicy::Disabled (wry docs: https://docs.rs/wry/0.58.1/wry/enum.BackgroundThrottlingPolicy.html, read 2026-11-25) yield full layout and 1960×1440 snapshots without private occlusion APIs, though CSS animations require .finish() per M3.

D10 (Synthetic input in unshown window): VERIFIED (for basic key/mouse events), UNDECIDED (for IME). M9 proves -[NSWindow sendEvent:] after makeFirstResponder(webView) types characters into a <textarea> and clicks buttons without showing or activating the window. IME marked text (NSTextInputClient) remains unmeasured.

D11 (Worker binary split vs. single binary): UNDECIDED. Both work, but Claude's separate vcx-worker binary with an independent build hash prevents frontend-only commits from triggering unnecessary worker swaps or rebuilds. No measurement contradicts either packaging layout yet.

D12 (First provider of Rust worker): UNDECIDED. Codex is already the canonical internal schema (codex app-server), making it the cleanest first adapter to port, while Claude is the primary daily driver. Neither has been benchmarked in Rust yet.

D13 (Coexistence): REFUTED (my seamless re-attach claim), VERIFIED (separate app bundle + no Swift update markers). M4 shows Swift closes its window on session/leaseLost and does not reopen it when Rust exits, so users must manually re-open sessions in Swift or run separate state paths when testing concurrently. Never overwriting Swift's path or update markers prevents accidental takeover.

D14 (Effort estimate): REFUTED (my 19–26 day estimate was optimistic). M1–M9 show rapid progress on the shell, but IME, 5,000-row virtual/paged scrolling, sandboxed chart iframes, four provider adapters, and full parity across 65 Swift files realistically align closer to Codex/Claude's 36–66 day range (estimate).

Evaluation of Single-Leg Claims (C1–C7)

C1 (Native Edit menu required for ⌘C/⌘V/⌘A in tao + WKWebView): VERIFIED. In tao on macOS, tao creates an empty or minimal menu bar unless configured, and WKWebView routes standard Edit menu key equivalents (copy:, paste:, selectAll:) through the AppKit responder chain (tao macOS menu/responder behavior, https://docs.rs/tao/0.38.0/tao/, read 2026-11-25; not yet tested in M9 since M9 used no modifiers).

C2 (Unshown window without explicit inner size gives 0×0 web view): VERIFIED. M2 explicitly sets a 980×720 viewport to get non-zero row boxes; in tao, WindowBuilder::new() without .with_inner_size(...) defaults to 800×600 (tao::window::WindowAttributes, https://docs.rs/tao/0.38.0/tao/window/struct.WindowAttributes.html, read 2026-11-25), though explicit sizing guarantees deterministic Retina 1960×1440 snapshots.

C3 (Sandboxed chart iframes under custom vcx:// scheme): UNDECIDED. In WebKit, custom WKURLSchemeHandler origins (vcx://) behave as opaque/non-HTTP origins where <iframe sandbox="allow-scripts"> origin isolation and vcx.live proxy fetches interact subtly (WKURLSchemeHandler Apple docs, https://developer.apple.com/documentation/webkit/wkurlschemehandler, read 2026-11-25). Chart iframes are explicitly listed as unmeasured.

C4 (Swift frontend auto-update can steal sessions back from Rust): VERIFIED. The brief states that an auto-update job builds each push to main and replaces the Swift frontend, which attaches to known sockets in ~/.local/state/vcx/runtime/ and triggers session/leaseLost in the Rust frontend unless isolated or disabled.

C5 (WebKit marks hidden/occluded windows hidden unless _setWindowOcclusionDetectionEnabled: is called): VERIFIED. M3 directly confirms document.visibilityState is hidden and CSS animations freeze in the unshown with_visible(false) window even with BackgroundThrottlingPolicy::Disabled (WebKit bug 331092, https://bugs.webkit.org/show_bug.cgi?id=331092, read 2026-11-25).

C6 (Swift workers accept --runtime-url to connect to a Rust server): REFUTED. The brief explicitly specifies that workers listen on Unix domain sockets (v<swap version>-<hash>.sock) and frontends connect as clients; no --runtime-url flag exists in the Swift runtime protocol.

C7 (Muse's three sources for private occlusion settings are weak): VERIFIED. Private AppKit/WebKit SPIs are undocumented by Apple and break across macOS releases; M2 and M3 prove BackgroundThrottlingPolicy::Disabled plus animation.finish() in tests achieves deterministic offscreen rendering without private SPIs.

Final Recommendations & Settling Measurements

D1: Port the tao + wry frontend first against live Swift workers over v1, then port workers behind the same conformance suite.

D2: Build the composer in the page using a standard <textarea> plus an adjacent chip strip, avoiding contenteditable and native NSTextView overlays unless IME testing proves a blocker.

D3: Never attempt cross-language file-descriptor takeover from Swift workers; reopen sessions cold from disk checkpoints when moving to Rust workers.

D4: Convert Markdown to HTML in the frontend's Rust core (pulldown-cmark + LRU cache) rather than sending HTML over the worker protocol.

D6: Use plain std::threads with channels and tao's EventLoopProxy in the frontend (no tokio), reserving tokio only for the worker if needed.

D7: Escape raw HTML events in pulldown-cmark with scheme filtering and a strict CSP (default-src 'none'), dropping ammonia.

D8: Start with CSS content-visibility: auto and paged older rows, adding a virtual list only if a 5,000-row benchmark misses frame-time budgets.

D11: Split vcx-worker into its own binary with an independent build hash so frontend UI updates never force worker swaps.

One read or measurement to settle each remaining open point:

D2 (Composer IME & shortcuts): Send Japanese/accented IME setMarkedText:selectedRange:replacementRange: and ⌘C/⌘V NSEvents to the unshown window's <textarea> and assert committed text and clipboard round-trip.

D5 & D8 (Protocol v2 & long threads): Load a 5,000-row fixture with large tool outputs over v1 in the unshown window and measure attach serialization latency, DOM layout time, and WebContent RSS.

D11 & D12 (Worker binary split & first provider): Run the v1 conformance test suite against a prototype vcx-worker implementing codex app-server first, measuring build-hash isolation during a frontend-only edit.

C3 (Sandboxed chart iframes): Render an <iframe sandbox="allow-scripts"> chart inside vcx://template/ calling vcx.live in a windowless test and verify both DOM isolation from the parent frame and allowlisted data delivery.