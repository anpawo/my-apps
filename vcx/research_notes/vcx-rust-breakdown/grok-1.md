Recommendation (5 lines)
Keep the existing frontend/worker Unix-socket protocol and the Connection abstraction that normalises every provider to Codex-shaped events; they are the cleanest cut points and let the two implementations interoperate during the move. Redraw the 2 305-line Session into a typed, display-free core, replace untyped [String:Any] with a versioned schema, and move the draft out of NSAttributedString. Start with a shared Rust core library (protocol, state, agents, Markdown), then a Rust worker that the Swift frontend can attach to, then the tao+wry frontend against either worker. Build the template folder and hot-reload early so display work can proceed in parallel. Windowless verification is feasible with a hidden tao window + wry + evaluate_script + raw WKWebView snapshot, but expect RAF and timer throttling that must be polyfilled or forced visible for tests.

Workspace table

Crate	Responsibility	Swift files / areas replaced
vcx-protocol	Versioned line-JSON (or later typed) frames, lease/sequence, request/reply/notification types, back-pressure helpers	RuntimeTransport, parts of RuntimeClient/Server
vcx-state	Typed Session, Row, Item (discriminated enums), draft as structured chips + plain text, revision/patch generation, checkpoint serialisation	Session.swift (core), Commands, Trace, ErrorsRank, Directory, StateHome
vcx-agents	Connection trait + adapters for Claude stream-json, Codex app-server JSON-RPC, Ollama HTTP, Agy; capability discovery, usage/quota	Agents, RPC, Agy, Capabilities, Messages, ProviderJSONReader, ClaudeCompatibility, ModelControl
vcx-markdown	Parse + sanitise Markdown to HTML (or AST) in Rust; cache rendered fragments; allow-list for chart iframe polling	Transcript parsing that currently lives in views or Session
vcx-runtime	Worker process: own Session + agent child, socket server, freezeForSwap / adopt, recovery from disk	RuntimeServer, RuntimeSession, RuntimeSwap, RuntimeUpdate, RuntimeRecovery, NativeThreadLease
vcx-frontend	tao event loop, one Window + one wry WebView per session, load template from disk, hot-reload, IPC to page, status/sidebar/task-bar chrome	main, Views, Composer (partial), Chart, Find, Run, TaskBoard, QuotaOverview, Demo
vcx-shell	Binary that can run as frontend or --runtime-worker; settings, Fleet file presence, live-update orchestration	RuntimeClient, top-level app entry, Settings
vcx-check	Windowless harness + protocol conformance tests runnable against both Swift and Rust workers	The 19 *Check.swift files (logic extracted)
(optional later) vcx-fleet	Menu-bar companion if rewritten	Fleet communication files

Keep the process model (one frontend process, one worker process per session, private 0700 socket folder, getpeereid). Keep the Connection trait shape. Drop compiling the self-checks into the production binary; they become a separate crate or test binary. Drop the draft-as-NSAttributedString; the page (or a thin native overlay) owns composition.

Port order (slices, each usable alone)

Shared core library (vcx-protocol + vcx-state + vcx-agents + vcx-markdown).
Proof: unit tests that round-trip the existing v1 line-JSON, parse a real Claude stream-json transcript into typed rows, render Markdown, and serialise a checkpoint that the current Swift recovery path can still read.
Coexistence: pure library; Swift continues unchanged. Effort estimate: 1–1.5 weeks with AI agents.

Rust worker binary that speaks the existing socket protocol.
Proof: Swift frontend attaches to a Rust worker for a new session (attach returns full state, perform send streams updates, lease hand-off works). Measure memory (target ≤ current 0.11 GB for 7 workers).
Coexistence: two apps side-by-side (Swift.app and a Rust CLI or .app that only starts workers); a setting or environment variable tells the Swift frontend which worker binary to launch. Existing sessions stay on Swift workers. Effort estimate: 1.5–2 weeks.

Freeze/adopt path for agent children (optional, only if the measurement shows it is reliable).
Proof: start an agent under Swift worker, call freezeForSwap, hand pid + FDs + unread bytes to a Rust worker, continue the same CLI stream without the provider seeing a reconnect.
Worth doing only after slice 2 is solid; the existing recovery-from-disk already covers crash cases, so live FD hand-off is an optimisation, not a requirement. Effort estimate: 3–5 days if it works, abandon after two failed attempts.

Minimal tao + wry frontend that can attach to either Swift or Rust workers, loads a static HTML template, displays a virtualised transcript from the state snapshot + patches, and sends perform actions.
Proof: open 5–13 windows against live workers, stream Markdown, fold tool calls, answer a question card; memory of the frontend process comparable to or better than the current 0.31 GB.
Coexistence: separate .app (or the same binary with a flag); user opens new sessions in the Rust shell while old sessions stay in the Swift shell. No risk to in-progress work. Effort estimate: 2–3 weeks.

Template folder + hot-reload + versioned data contract (Markdown HTML cache, chart iframes with allow-listed vcx.live, last-good fallback).
Proof: edit a CSS/JS file on disk, every open window reloads without restart; broken edit falls back; chart block polls through the core.
Effort estimate: 1 week overlapping with 4.

Composer, find bar, task board, status bar, sidebar, Fleet presence files.
Proof: full daily workflow (image chips, long paste, / palette, quotas, hooks/skills/MCP) works in the Rust shell.
Effort estimate: 2–3 weeks.

Live update for the Rust binary (replace frontend process, workers swap when idle).
Proof: push to main, new frontend attaches to existing workers, idle worker swaps itself while keeping the agent child.
Effort estimate: 1 week.

Windowless check harness and migration of the 7 668 lines of checks.
Proof: the same headless suite that today runs against Swift now runs against the Rust implementation (or both).
Effort estimate: 1–2 weeks, parallelisable.

During the whole move the owner keeps using the Swift app for production sessions; Rust is exercised only on new sessions or in a parallel .app until parity is declared.

3. What to rebuild better, concretely

Protocol: keep v1 line-JSON (sorted keys, 32 MB frame limit, 80 ms batching of patches) for the entire migration. It already works and is the interoperability bridge. Design a typed v2 (protobuf or serde-json with a schema version field, stronger error codes, explicit patch algebra) only after both ends are Rust; the change is then a clean cut-over, not a dual-stack forever.

State model: make rows and items strongly typed in Rust (enums for kind and item type). Keep a “passthrough” JSON bag for provider-specific fields whose schemas move, but the core shape (id, kind, items, revision) is owned by vcx-state. The four providers continue to be adapted behind the Connection trait so their schema churn never leaks into the page or the protocol.

State to the page: on attach, send the full snapshot once. Thereafter send the same batched patches the Swift workers already emit (meta, rowOrder, rowUpdates, items, draft). The page keeps a virtual list (only the visible rows + a small buffer are in the DOM). Markdown is rendered to HTML (or a compact AST) in the Rust core, cached by content hash, and the HTML string is what travels in the patch; the page never re-parses Markdown.

Concurrency: tokio for the worker (agent I/O, socket, timers). The frontend runs tao’s main-thread event loop; use EventLoopProxy / channels to move work off the main thread and post results back. Never block the main thread on agent or disk I/O.

Template data contract: a small JSON schema (or TypeScript types generated from Rust) versioned in the template folder. The core embeds the version it understands; on load the page declares its version; mismatch falls back to the last-good template that matches. Hot-reload watches the folder and re-injects only when the version is still compatible.

Composer: keep it native for IME, marked text, and attachment chips. A thin NSTextView (via objc2) layered over the bottom of the wry view, or a child view that the page sizes via IPC, is the lowest-risk path for a macOS-only app that already has a working NSTextView subclass. Pure web composer is possible later but will fight IME and long-paste performance; do not start there.

Live update: the same two-phase dance works. Frontend process is replaced and re-attaches with the existing leases. A worker that is idle calls freezeForSwap (pid, FDs, unread bytes) and the new binary adopts them; a worker that cannot move simply stays on the old binary until its sessions are closed. The Rust side must re-implement the FD-passing and the “keep agent child alive” logic exactly.

4. What not to port

The 19 *Check.swift files as compiled-in production code; extract the assertions into the vcx-check crate.
NSAttributedString draft and the ObservableObject row/item wrappers; they are display coupling.
Any SwiftUI view code; the template folder replaces it.
Python installer / auto-update job can stay for the first few months (or be rewritten once the Rust binary is the only one).
Fleet menu-bar app can stay in Swift (or even AppleScript) until the core is stable; only the small presence files need a stable format.
Must stay native via objc2 even inside the Rust shell: the composer NSTextView (if chosen), any status-item / Dock badge helpers, and the getpeereid / Unix-socket peer check. WKWebView itself is already behind wry.

5. Windowless verification with tao + wry

Create a tao Window with visible: false (or off-screen position) and set the activation policy to Accessory or Prohibited before the event loop starts so no Dock icon appears for the test process (tao’s EventLoopExtMacOS::set_activation_policy and set_dock_visibility; see docs.rs/tao and the macOS platform module). Attach a wry WebView to that window. Load the template (or a test page) via custom protocol or file URL. Drive it with evaluate_script (and the callback form) to read the DOM or invoke page functions. For screenshots, obtain the raw WKWebView handle through wry’s macOS extension (webview() or equivalent) and call takeSnapshotWithConfiguration:completionHandler: via objc2. Synthetic key and mouse events can be injected through the tao event loop or by posting NSEvents to the window.

Known traps (sources read 25 Nov 2026):

Hidden or occluded WKWebViews throttle requestAnimationFrame and timers (document.hidden becomes true; observed in screensaver and background WebKit contexts). Polyfill RAF with a Worker or force the window visible for the duration of animation-sensitive tests.
Activation policy and Dock visibility must be set before the run loop; later changes are unreliable when the process is launched from a .app bundle.
Creating a hidden webview must not steal focus (wry fixed related focus-stealing in recent releases).
Transparent windows + high refresh rates can pin the GPU; keep test windows opaque.

How the 7 668 lines of checks map:

Pure protocol and state-machine assertions → Rust unit tests in vcx-state / vcx-protocol.
Round-trip and concurrency tests that previously talked to a live worker → protocol conformance tests that run the same script against both the Swift worker binary and the Rust worker binary.
DOM, rendering, input, and visual regression tests → page tests driven by the windowless harness (evaluate_script + snapshot).
Anything that needed real mouse/keyboard routing into an unshown window becomes the same harness with synthetic events.

6. Risks and stop rules

Most likely failures:

Subtle differences in the socket protocol (ordering of patches, lease edge cases, back-pressure) that only appear under 10+ concurrent windows.
Markdown sanitisation or chart-iframe sandbox differences that let unsafe content through.
Composer IME / chip behaviour that feels “almost” right but breaks daily muscle memory.
Live-update FD hand-off that corrupts the agent child’s stdio.
Hidden-webview throttling that makes the check suite flaky.

Notice early by: keeping the dual-implementation conformance suite green at every slice; measuring frontend and worker RSS after each slice against the known Swift baselines (0.31 GB / 0.11 GB); running the daily 5–13-window workload on the Rust side for a full day before declaring a slice done; never migrating an in-progress session until the owner explicitly opens a new one in the new shell.

Effort (one developer + AI agents, calendar time): core 1–1.5 w, worker 1.5–2 w, minimal frontend 2–3 w, template/hot-reload 1 w, full chrome 2–3 w, live-update 1 w, checks 1–2 w. Total realistic window 10–14 weeks if slices stay sequential and each is proven before the next begins; parallelising template work and checks can shave 2–3 weeks. Stop and reassess if any single slice exceeds its estimate by >50 % or if the dual-protocol tests start diverging.