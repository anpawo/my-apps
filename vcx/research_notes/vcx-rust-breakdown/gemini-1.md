Recommendation
Build the tao + wry frontend first against the existing Swift --runtime-worker processes over the v1 Unix socket protocol, then port the workers behind that contract. Keep the process split, socket transport, and Connection provider abstraction; dissolve the monolithic Session into typed state, structured draft chips, and pure reducers. Coexist safely via a separate VCX-Rust.app bundle that attaches via lease handover on demand without risking active sessions. Do not attempt cross-language freezeForSwap file-descriptor handover between Swift and Rust workers—drain and restart cleanly instead.

Rust Workspace Architecture
Crate	Responsibility	Swift Files Replaced
vcx-proto	Wire protocol v1/v2 frames, serde RPC envelopes, leases, sequence receipts, and schema-versioned template view-models.	RuntimeTransport.swift, RuntimeSession.swift, NativeThreadLease.swift, untyped JSON wire helpers.
vcx-markdown	CommonMark/GFM parsing (pulldown-cmark), HTML sanitization (ammonia), syntax highlighting (syntect), and content-hash HTML caching.	Transcript Markdown rendering, sanitizer/highlighter helpers.
vcx-core	Pure deterministic state machine: typed rows/items with #[serde(flatten)] passthroughs, structured draft chips, slash commands, quota/Fleet state, and patch diffing.	Session.swift, Commands.swift, Settings.swift, StateHome.swift, Trace.swift, ErrorsRank.swift, Directory.swift.
vcx-agents	Async child-process management, Connection trait normalizing claude -p, codex app-server, Ollama HTTP, and agy into uniform typed events.	Agents.swift, RPC.swift, Agy.swift, Capabilities.swift, Messages.swift, ProviderJSONReader.swift, ClaudeCompatibility.swift, ModelControl.swift.
vcx-worker	Headless --runtime-worker daemon: Unix socket server (getpeereid auth), 80 ms patch batching, disk checkpointing, and same-language binary swap.	RuntimeServer.swift, RuntimeRecovery.swift, RuntimeSwap.swift, RuntimeUpdate.swift.
vcx-ui	tao window lifecycle, wry WKWebView management, custom URI scheme (vcx://), template hot-reloader with last-good fallback, and objc2 native hooks.	Views, Transcript, Composer, Chart, Find, Run, TaskBoard, QuotaOverview, Demo, RuntimeClient.swift.
vcx-app	Thin binary entrypoint dispatching --runtime-worker vs. GUI frontend, CLI flags, and single-instance coordination.	main.swift.
vcx-verify (dev/test crate)	Offscreen tao + wry harness, WKWebView.takeSnapshot bridge, protocol conformance suite, and fixture replay.	All 19 *Check.swift files (7,668 lines).

Boundaries to Keep vs. Redraw:

Keep: The frontend/worker process boundary (isolates WebContent memory bloat from long-lived CLI child processes), the Unix domain socket with getpeereid peer verification, lease-based single-writer ownership, and the Connection adapter pattern that normalizes heterogeneous CLIs into Codex-shaped domain events.

Redraw: Split the 2,305-line Session into a pure synchronous state reducer (vcx-core) separate from async I/O (vcx-worker). Replace NSAttributedString drafts with an explicit Vec<DraftSegment> (Text(String) | Chip(ChipKind)). Move the 7,668 lines of *Check.swift out of the production binary into cargo test integration suites (vcx-verify).

Port Order & Coexistence Slices

Building the frontend first delivers daily-driver value immediately while leaving battle-tested Swift workers holding live agent sessions. During migration, install the Rust build as ~/Applications/VCX-Next.app sharing ~/.local/state/vcx and ~/Library/Application Support/VCX/settings.json. Because attach uses lease handover (session/leaseLost), opening a session UUID in VCX-Next.app cleanly steals the lease from Swift VCX.app without killing the underlying worker or CLI child; closing VCX-Next.app lets Swift re-attach seamlessly.

Slice 1: vcx-proto + Wire Spy & Conformance Harness

Scope: Implement v1 newline-delimited JSON framing, getpeereid client, hello/list/attach/perform RPCs, and patch application in Rust.

Proof: cargo test -p vcx-verify --test proto_v1 attaches to a live Swift --runtime-worker, replays a recorded session fixture, and asserts byte-identical reconstructed state against Swift's RuntimeClient.

Slice 2: vcx-markdown + Hot-Reloadable HTML/CSS/JS Shell (vcx-ui)

Scope: tao window + wry WKWebView serving the disk template folder via custom vcx:// protocol, notify file watcher with last-good fallback, and pulldown-cmark + ammonia pipeline.

Proof: cargo run -p vcx-app -- --demo-fixture renders a 5,000-row transcript fixture with sandboxed chart iframes; corrupting a template .js file triggers fallback within 100 ms without blanking the view.

Slice 3: Live VCX-Next.app Frontend Against Swift Workers

Scope: Connect vcx-ui to live Swift worker sockets (v<swap>-<hash>.sock), implement the in-page composer, / palette, vcx.live allowlisted proxy, and multi-window tao management.

Proof: Run 8 active coding sessions in VCX-Next.app for a full workday against existing Swift workers; verify RSS stays below 350 MB (ps -o rss=) and zero dropped session/update patches.

Slice 4: vcx-core + vcx-agents + vcx-worker (Rust Worker Parity)

Scope: Port the Session reducer, checkpointing, and the four CLI adapters (claude -p, codex app-server, Ollama, agy) into vcx-app --runtime-worker.

Proof: Run the vcx-verify protocol conformance suite identically against both Swift --runtime-worker and Rust --runtime-worker binaries; attach the existing Swift VCX.app frontend to a Rust worker to confirm backward compatibility.

Slice 5: Cutover, Rust-to-Rust freezeForSwap, and Swift Retirement

Scope: Implement SCM_RIGHTS / inherited-FD swap between Rust workers, switch VCX-Next.app to ~/Applications/VCX.app, and archive the Swift source tree.

Proof: Trigger the auto-update job while an idle worker holds an open codex app-server child; verify the new Rust worker adopts the PID and pipes with zero session interruption.

Cross-Language freezeForSwap: Do not build Swift-to-Rust freezeForSwap handoff. Swift's DispatchIO / FileHandle internal buffer state and memory layout differ from Tokio/Rust OwnedFd framing; translating unread byte offsets across languages for a one-time migration risks corrupting mid-frame JSON-RPC streams. Instead, let existing Swift workers finish their active turn (idle), checkpoint to disk, and cold-reopen them on Rust workers.

Question 3: What to Rebuild Better, Concretely

Protocol (v1 Compatibility with Typed v2 Evolution): Keep v1 newline-delimited JSON (\n framed, getpeereid checked) intact for Slices 1–4 so Swift and Rust processes interoperate without flag days. In vcx-proto, negotiate protocol: 2 in hello while falling back to 1: v2 adds pre-rendered html fragments inside items patches (eliminating redundant Markdown parsing in the frontend) and MessagePack or length-prefixed framing as an optional capability for large multi-megabyte tool outputs.

State Model (Typed Core + Passthrough): Model Row and Item as strongly typed Rust enums (#[serde(tag = "type")]) covering known variants (commandExecution, fileChange, mcpToolCall, dynamicToolCall, webSearch, peerMessage, reasoning, userMessage, assistantMessage), plus an #[serde(other)] Unknown variant and #[serde(flatten)] extra: serde_json::Map<String, Value> on every struct. Upstream CLI schema additions survive round-trips and checkpointing without deserialization failures.

How State Reaches the Page: Maintain canonical session state in vcx-ui (updated by worker session/update 80 ms batches). Cache rendered Markdown HTML in an LRU map keyed by (item_id, blake3(raw_markdown)) in vcx-markdown. Push incremental JSON patches over window.__vcx.applyPatch(...) via evaluate_script (or custom protocol fetch for payloads >256 KB) coalesced to requestAnimationFrame (~16 ms). Render the transcript via a DOM windowed/virtual list measuring dynamic row heights with ResizeObserver so 10,000+ rows keep DOM node count under ~150.

Concurrency (tokio + tao): Run a multi-threaded tokio runtime on background threads handling Unix sockets, file watchers (notify), and vcx.live HTTP polling. Bridge to tao's main-thread event loop exclusively via tao::event_loop::EventLoopProxy<UiEvent> (which wakes the macOS CFRunLoop safely) plus a lock-free crossbeam_channel for patch queues. Never block the tao main thread on socket I/O or Markdown rendering.

Template Data Contract & Versioning: The template folder declares "contractVersion": 1 in a manifest.json alongside index.html. On boot or reload, vcx-ui loads the new template into a hidden staging check or validates window.__vcxContractVersion === 1 after DOM load; if loading throws an uncaught error or mismatches the contract version, vcx-ui reverts immediately to the last-known-good in-memory bundle snapshot and surfaces a non-blocking status chip.

Composer (In-Page DOM + contenteditable / Rich Input): Build the composer inside the HTML/JS template rather than floating an NSTextView over WKWebView (overlaying native AppKit views over WKWebView causes z-order clipping with popovers, scroll-sync jitter, and focus-ring bugs). Use a structured contenteditable editor (or lightweight ProseMirror/CodeMirror core) where attachment chips (image, long-paste, /command) are contenteditable="false" atomic inline nodes serialized cleanly to Vec<DraftSegment>. Handle compositionstart/compositionend explicitly so macOS CJK/accent IME marked text never triggers slash-command popups or Enter-to-send mid-composition.

Live Update: Keep the Python build-and-sign watcher on main, producing a signed bundle in a staging path. The running Rust frontend watches a release.json marker; on update, it spawns the new VCX.app binary with --takeover, which calls attach on all active session sockets (triggering session/leaseLost in the old frontend, which exits once zero leases remain). Idle workers exec-swap onto the new binary using libc::fcntl (FD_CLOEXEC cleared on agent pipes and listener socket) + serialized JSON swap state passed via memfd/temp 0600 file.

Question 4: What Not to Port

Drop completely: The 19 *Check.swift files compiled into the release binary (move to cargo test in vcx-verify); SwiftUI ObservableObject wrapper boilerplate; NSAttributedString draft encoding.

Keep in Python: The 3,069 lines of build/install/auto-update/cleanup scripts (codesign, cargo build --release, .app bundle assembly, archive rotation). Porting deployment glue to Rust adds compile time with zero runtime gain.

Keep native via objc2 (objc2-app-kit / objc2-foundation / objc2-web-kit):

NSApplication activation policy (NSApplicationActivationPolicy::Regular vs. Accessory for headless tests) and macOS application menu (Cmd+Q, Cmd+W, Cmd+F, Cmd+C/V/X responder chain—without a native NSMenu edit menu, WKWebView clipboard shortcuts break on macOS).

NSSavePanel / NSOpenPanel and drag-and-drop NSFilenamesPboardType / NSPasteboard file URL resolution for image/file chips.

WKWebViewConfiguration tweaks not exposed by wry (e.g., mediaTypesRequiringUserActionForPlayback, developer extras toggle, and takeSnapshotWithConfiguration:completionHandler:).

Fleet integration: Keep writing the existing small atomic status JSON files to the shared Fleet state directory from vcx-core—no changes needed in the separate Fleet menu-bar app.

Question 5: Windowless Verification with tao + wry

Hidden Window Setup (No Dock Icon, No Focus Steal):

Call NSApp.setActivationPolicy(NSApplicationActivationPolicyAccessory) via objc2-app-kit before starting the tao event loop so no Dock icon appears and the active app never loses focus (Apple Developer Documentation: NSApplication.ActivationPolicy.accessory, https://developer.apple.com/documentation/appkit/nsapplication/activationpolicy-swift.enum/accessory, read 2026-11-25).

Create the tao window with .with_visible(false) and an explicit logical size (e.g., 1280x800) so layout viewport metrics match desktop rendering.

DOM Reads & Synthetic Input:

Use WebView::evaluate_script with a callback (evaluate_script_with_return in wry, https://docs.rs/wry/latest/wry/struct.WebView.html, read 2026-11-25) to query DOM state, bounding boxes, and virtual-list scroll heights as JSON.

For synthetic keyboard/mouse tests, either dispatch NSEvent instances (keyEventWithType:..., mouseEventWithType:...) directly to the underlying WKWebView responder via objc2-app-kit ([wkWebView keyDown:event], [wkWebView mouseDown:event]) to exercise native keybindings/IME, or inject trusted-equivalent test harness events into the page input controller for pure DOM flows.

Offscreen Screenshots:

Obtain the underlying WKWebView pointer from wry::WebViewExtMacOS::webview (wry::WebViewExtMacOS, https://docs.rs/wry/latest/wry/trait.WebViewExtMacOS.html, read 2026-11-25) and invoke -[WKWebView takeSnapshotWithConfiguration:completionHandler:] via objc2-web-kit (WKWebView::takeSnapshotWithConfiguration_completionHandler, https://developer.apple.com/documentation/webkit/wkwebview/takesnapshot(with:completionhandler, read 2026-11-25), converting the returned NSImage to PNG bytes for visual regression assertions.

Known Traps on macOS / WebKit:

Timer & requestAnimationFrame Throttling: macOS App Nap and WebKit's background page throttling clamp timers and pause requestAnimationFrame when a window is hidden (visible(false)) or occluded (WebKit Blog / NSProcessInfo App Nap docs, https://developer.apple.com/documentation/foundation/nsprocessinfo/beginactivity(options:reason, read 2026-11-25). Mitigation: Call NSProcessInfo.processInfo.beginActivityWithOptions_reason(NSActivityUserInitiatedAllowingIdleSystemSleep, "VCX headless verification") to disable App Nap, and in verification mode route window.__vcxFlushFrame() synchronously from Rust instead of waiting on requestAnimationFrame.

Zero-Size Backing Store: Creating an unshown window without explicit inner dimensions yields a 0x0 WKWebView frame, causing takeSnapshot to fail or produce empty bitmaps. Always set .with_inner_size(LogicalSize::new(1280.0, 800.0)) and force layoutSubtreeIfNeeded before snapshotting.

Missing Edit Menu Breaks Shortcuts: Under ActivationPolicy::Accessory, omitting a native NSMenu with copy:/paste:/selectAll: selectors causes Cmd+C/Cmd+V sent via synthetic NSEvents to beep instead of reaching WKWebView. Construct a minimal NSMenu in vcx-ui even in headless mode.

Carrying Over the 7,668 Lines of Swift Checks:

Rust unit/property tests (vcx-core, vcx-markdown): Session state transitions, prompt queueing, slash commands, draft chip serialization, archive safety, and Markdown sanitization (~40% of existing checks).

Dual-target protocol conformance tests (vcx-verify): Wire framing, getpeereid rejection, lease handover, idempotent sequence receipts, and 80 ms patch batching—executed against both Swift and Rust --runtime-worker binaries (~30%).

Headless wry page tests (vcx-verify): Virtual scroll performance at 5,000 rows, find-bar highlighting, chart iframe sandbox isolation + vcx.live allowlist blocking, template hot-reload fallback, and takeSnapshot PNG diffs (~30%).

Question 6: Risks, Stop Rules & Effort Estimates
Slice	Effort (Estimate, 1 dev + AI)	Primary Risk	Early Detection & Stop Rule
1. vcx-proto + Conformance	2–3 days (estimate)	Subtle edge cases in Swift's sorted-key JSON framing, 32 MB frame limits, or lease-handover race conditions.	Run conformance tests against live Swift worker logs on Day 2. Stop rule: If wire compatibility requires >300 lines of Swift workarounds, freeze v1 as-is and isolate quirks inside vcx-proto's compat codec.
2. vcx-markdown + vcx-ui Shell	4–5 days (estimate)	wry custom protocol (vcx://) CSP interactions with sandboxed chart iframes and vcx.live XHR/fetch interception.	Test a real chart block with vcx.live polling on Day 3 of this slice. Stop rule: If WKWebView custom scheme origin rules block iframe sandboxing cleanly, serve templates over [http://127.0.0.1](http://127.0.0.1):<ephemeral_port> bound to loopback with a per-launch bearer token instead.
3. Full Frontend Daily Driver	5–7 days (estimate)	Composer contenteditable IME composition bugs or focus loss across 10+ tao windows; WebContent RSS creep if virtual list DOM nodes leak.	Measure RSS with 13 windows open and test Japanese/accented dead-key IME on Day 4. Stop rule: If contenteditable chip cursor behavior proves fragile after 2 days, drop in CodeMirror 6 (bundled single-file JS) as the composer engine rather than hand-rolling selection ranges.
4. vcx-core + vcx-agents + vcx-worker	6–8 days (estimate)	Provider CLI edge cases (claude -p stream-json quirks, codex app-server JSON-RPC back-pressure, agy stderr interleaving) missing from the brief.	Diff live CLI session transcripts from Swift vs. Rust workers on identical recorded stdout/stderr streams before live testing. Stop rule: Keep Swift workers as a fallback runtime option in settings until Rust workers pass 5 consecutive days of zero-crash usage.
5. Rust freezeForSwap & Cutover	2–3 days (estimate)	Inherited FD CLOEXEC leaks or partial pipe buffer loss during execve swap on macOS 26.	Stress-test swap under continuous token streaming in vcx-verify. Stop rule: If execve FD inheritance proves brittle on macOS 26, restrict worker live-update to idle workers only (matching today's safe path) and skip mid-stream FD adoption.

Total Estimated Effort: ~19–26 working days (estimate) for one developer working with AI coding agents, with usable daily-driver cutover of the Rust UI at Day ~12–15 (end of Slice 3).