Recommendation (first 5 lines)
Proceed with a thin Rust + system-WKWebView path (prefer wry/tao directly or a minimal Tauri 2 shell) rather than pure-native GPUI/Blitz or a full Dioxus rewrite. Keep one frontend process owning multiple windows, share a single WKWebsiteDataStore across the main chat webviews to minimize WebKit processes, and load a hot-reloadable HTML/CSS/JS template from disk. Measure RAM and scroll FPS on a 5 000-row transcript at every step; stop or pivot only if total footprint for 8 windows exceeds ~1.2–1.5 GB or input latency regresses. Ship incremental, usable milestones so the current Swift app stays the daily driver until the new stack is proven.

Stack

Tauri 2 (Rust + system WKWebView via wry) is mature on macOS in late 2026 (v2.12.x), ships small binaries (single-digit MB), and re-uses the OS WebKit. Idle RAM for a simple app is typically 30–80 MB for the Rust process plus WebKit helpers; real multi-window chat-like apps land higher because of WebContent processes. One public 2025/2026 benchmark measured ~172 MB total for six windows versus ~409 MB for the equivalent Electron app. Streaming and scrolling of long lists is limited by WebKit’s DOM + JS performance; virtualization (windowing only visible rows) is required for 5 000-row transcripts and is feasible but not automatic. Headless testing is possible via off-screen windows or the existing --render style harnesses; keyboard focus, IME, text selection and accessibility inherit from system WKWebView and are generally good.

wry/tao directly (without the full Tauri command/permission layer) is lighter and gives the same WebKit surface. It is the lowest-overhead way to host multiple WKWebViews from Rust. Maturity is high because Tauri itself is built on it. Same RAM and performance profile as Tauri, slightly less abstraction.

A pure Swift or thin Rust shell around one (or several) shared WKWebViews is the smallest change from today’s architecture. It keeps AppKit/SwiftUI interop for menus, global hotkeys and TCC, and can reuse the existing process-model and live-update machinery. RAM is essentially identical to today’s One Text measurement (~480 MB total for a Tauri-like app). Headless off-screen rendering already works.

Dioxus desktop still defaults to a WebKit backend; Dioxus Native / Blitz (pure-Rust HTML/CSS, WGPU) is in beta/early production in late 2026. Blitz can render many static sites and simple apps and reports lower RAM in CPU-backed experiments (tens of MB), but GPU backends still show higher footprints (reports of ~140 MB on macOS) and incomplete features (rich text editing, full form controls, accessibility). Free-form agent charts that rely on arbitrary JS/TradingView would require either a data-only chart DSL + static SVG fallback or a hybrid webview for chart blocks—exactly the path the earlier council warned against. Maturity is still too low for a daily-driver tool that must stay rock-solid.

GPUI (Zed’s GPU-accelerated framework) delivers excellent scrolling and low RAM (Zed itself ~150–350 MB for heavy editor workloads; Cap’s migration reported ~440 MB vs multi-GB Tauri for a comparable workload; Discord’s Phoenix internal builds ~290 MB). It is pure Rust, no JS engine, and therefore cannot host free-form HTML/JS charts without a secondary webview or a full rewrite of the chart system. Accessibility, IME and text selection must be re-implemented; the API surface is still evolving. Excellent for an editor-like UI, high rewrite cost and loss of agent-authored HTML charts for VCX.

Other serious Electron-free options (Sciter closed-source, Ultralight proprietary WebKit fork, iced/egui immediate-mode) either lack a full JS engine, have licensing friction, or do not match the required Markdown + chart + accessibility surface.

Recommendation: start with wry/tao (or a minimal Tauri 2 shell) so the display is a hot-reloadable web page while the core stays Rust. This preserves free-form charts, system IME/accessibility, and the ability to keep the existing worker process model. Pure GPUI or Blitz only become attractive after a data-only chart DSL is proven and the owner is willing to lose arbitrary agent HTML.

Windows and processes

Prefer one OS window per agent session (current mental model) rather than a single window with tabs; the owner already runs 5–10 concurrent sessions. Inside the frontend process host one webview per window.

On modern macOS (12+) WKProcessPool is deprecated and no longer controls process sharing. Process and network sharing is now driven by WKWebsiteDataStore: webviews that share the same data store tend to share WebContent / Networking processes; different stores force isolation and extra RAM. For the main chat UI use one shared non-persistent or named data store across all session windows; isolate only the free-form chart iframes if sandboxing demands it. Expect roughly one shared WebContent process plus a Networking process for the whole set of chat windows, plus per-window GPU overhead—far better than one full process tree per window.

Keep the frontend/worker split and live-update design. The frontend (Rust + webviews) can be replaced while workers continue; workers still own the agent CLI processes. The socket RPC stays essentially the same.

Rendering and streaming design

Tokens flow over a local IPC channel (Unix socket or Tauri’s channel) from each runtime worker into the frontend. Batch updates per animation frame (requestAnimationFrame or a 16 ms timer) and apply them as a single DOM patch or virtual-list update.

Markdown rendering can stay on the JS side (existing libraries or a lightweight custom renderer) for simplicity and hot-reload; heavy or security-sensitive parsing can move to Rust and ship pre-rendered HTML fragments.

Long transcripts must be virtualized: only the visible rows (plus a small overscan) exist in the DOM; older rows are recycled. Memory stays roughly constant after the first few hundred rows. Smooth scrolling is achieved by keeping the virtual list on the GPU-friendly path and avoiding layout thrashing.

Charts: keep free-form HTML/JS blocks inside sandboxed iframes (or a separate webview with a restricted data store). The existing vcx.chart / TradingView path continues to work. Optionally introduce a data-only chart DSL later for the common price/time-series case so those blocks can be rendered without a full JS engine, but do not block the migration on it.

Hot-reload template

Structure: a single versioned folder on disk containing index.html, CSS, JS modules and a small contract.json that documents the stable IPC messages and data shapes the template expects. The Rust core loads the template at startup and watches the folder (or a specific entry point) with a file-system watcher.

On change, the core validates the new template (basic HTML parse + a smoke-test render into an off-screen webview), then swaps the content of every open window while preserving scroll position, selection and composer state via a short-lived snapshot/restore handshake. If validation fails, the last-good copy remains in place and an error is shown in the status bar.

Agents (or the owner) can edit the template live, but the IPC bridge exposes only a narrow, capability-checked API; arbitrary shell execution or unrestricted file access is never available from the page. Chart pages receive an even tighter sandbox. A “safe mode” that forces the last-known-good template is available from the menu-bar app.

Migration path

Shipable steps, each usable daily:

Step 0 (1–2 weeks): extract the transcript + composer into a single WKWebView inside the existing Swift frontend, driven by the same data the SwiftUI stack already produces. Measure RAM, scroll FPS and input latency on a 5 000-row thread. Keep all other UI in Swift. Stop if the hybrid is already slower or larger than today’s optimized SwiftUI.

Step 1 (2–4 weeks): move the frontend process to Rust + wry/tao (or thin Tauri), keep the same worker processes and socket RPC. Port the menu-bar / Fleet reporting and the live-update swap. Measure total footprint for 1 and for 8 windows.

Step 2: make the HTML/CSS/JS template hot-reloadable and move the remaining chrome (task bar, status bar, sidebar) into the same page or into lightweight native companions.

Step 3: optionally rewrite the workers in Rust later; they can stay Python/Swift for a long time.

Keep in Swift (or AppKit) for as long as convenient: global hotkeys, TCC permission prompts, menu-bar extra, code-signing / notarization without Xcode if the current pipeline already works. The Rust binary can still be signed and installed as a .app.

Stop criteria: measured RAM for 8 windows > ~1.5 GB, sustained < 50 fps while streaming a long transcript, or IME/accessibility regressions that cannot be fixed in a week.

Risks and costs

RAM: expect the WebKit helper processes to dominate; a realistic target is 400–800 MB total for 7–8 windows (versus today’s 253 MB frontend + workers). Energy and battery follow the same curve. Input latency and IME should stay comparable to Safari if the webview is configured carefully; accessibility is system-provided but must be verified for custom widgets.

Rewrite size: estimate 6–12 weeks of one developer + AI agents for a production-quality first cut (transcript + composer + hot-reload + process model), plus ongoing polish. The 7 500 lines of self-checks keep most of their value by being re-targeted at the new rendering path (off-screen webview snapshots, headless event injection, golden-image diffs).

Biggest non-technical risk is losing the “change a color and see it instantly” loop if the hot-reload path is not rock-solid from day one.

Table of options (late 2026 figures; sources dated where known, otherwise estimate)

Option	1-window RAM (est.)	8-window RAM (est.)	Streaming / 5 k-row scroll	macOS maturity	Headless test	Focus / IME / a11y	Notes
Tauri 2	80–150 MB	400–900 MB	Good with virtualization	High (2.12)	Yes (off-screen)	System WK	Measured ~172 MB / 6 windows in one public bench
wry/tao direct	70–130 MB	350–800 MB	Same	High	Yes	System WK	Lowest overhead
Swift/Rust + shared WK	~100–200 MB	~400–700 MB	Same as today	Highest	Already works	Native	Minimal change
Dioxus (WebKit)	similar to Tauri	similar	Good	Medium-high	Possible	System	Extra framework cost
Dioxus Native / Blitz	40–140 MB	200–600 MB	Promising but incomplete	Beta	Limited	Re-implement	No free-form JS charts
GPUI	50–150 MB	300–700 MB	Excellent	High (Zed/Discord)	Custom	Re-implement	Loses agent HTML charts

Sources consulted 25 Nov 2026: Tauri release notes & benchmarks, wry issues, Apple WKWebsiteDataStore / WKProcessPool docs, Blitz/Dioxus Native status pages, Zed/GPUI and Cap/Discord migration reports, and the owner’s own 19/25 Nov footprint numbers. All multi-window RAM numbers for complex UIs remain estimates until measured on the target Mac with the real transcript workload.