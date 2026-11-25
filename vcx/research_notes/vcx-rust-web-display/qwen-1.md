**Recommendation Summary (5 lines)**
The optimal path is **Tauri 2 with the system WebKit engine** because it offers the smallest resident footprint among WebView-based solutions on macOS while providing a native IPC bridge for live updates. To address RAM, we must implement a **single shared WebKit context** across all windows rather than one process per window, leveraging Tauri's lifecycle management to minimize helper process overhead. The hot-reload template should be an HTML/CSS bundle watched by the Rust core, streamed via JSONL tokens with a "last-good" fallback mechanism to prevent UI breaks from user edits. We will ship in three phases: isolate the chat area, migrate the core to Rust, then swap the entire display, using headless rendering (`headless-ui-test`) to maintain the 7,500-line verification suite throughout the rewrite.

---

### 1. Stack Comparison and Recommendation

**Tauri 2 (Rust + system WebKit)**
*   **Architecture:** Rust backend (`tauri.rs`) wrapping the platform's native WebView (WebKit on macOS).
*   **RAM (1 window):** Estimate ~85–100 MB (Rust app process ~60 MB + single WebContent context ~40 MB, plus negligible GPU/Net processes if managed strictly per Tauri v2 optimizations).
*   **RAM (8 windows):** ~750–850 MB (shared or pooled contexts allow reusing the WebContent and GPU processes; worst-case separate contexts would hit ~6 GB, but Tauri encourages process sharing for similar URLs/origins).
*   **Performance:** Excellent scrolling with virtualized lists in JS; handles long transcripts well if DOM nodes are recycled.
*   **Maturity (Late 2026):** High. Mature ecosystem on macOS.
*   **Headless Testing:** Uses `headless-ui-test` (Rust) which drives the webview offscreen or via WebDriver protocol without a visible frame, compatible with existing off-screen render workflows.
*   **Input/IME:** Excellent. Tauri maps native IME events directly; keyboard focus is managed by the OS within the WebContent process but controlled via Rust commands.

**wry/tao (Rust + raw WKWebView)**
*   **Architecture:** Pure Rust bridge to `WKWebView`. More boilerplate than Tauri.
*   **RAM:** Similar to Tauri, but harder to manage process pooling efficiently without writing custom IPC logic for window sharing.
*   **Verdict:** Tauri is preferred for the "hot-reload" requirement as it has built-in file watching (`tauri-plugin-fs`) and a robust state management layer that speeds up JS injection for UI tweaks.

**Dioxus (Native/Blitz Mode)**
*   **Architecture:** Compiles to native code without a JS engine in some modes, or uses a small embedded webview in others. Blitz mode claims zero JS runtime.
*   **RAM:** Potentially lowest (~20–40 MB), but "Blitz" is still maturing and may require heavy Rust UI rendering logic for complex Markdown tables/images without falling back to a canvas engine.
*   **Chart Handling:** Difficult. Requires a strict data-only spec conversion *and* a high-quality native charting library (like `plotly-rs` or embedding TradingView via an iframe, which defeats the "no JS engine" benefit if the iframe loads its own engine).
*   **Headless:** Good support for `wry`/`headless-browser`, but the learning curve for rendering complex Markdown *and* custom HTML charts without a JS engine is high.

**SwiftUI (Current State)**
*   **RAM:** 253 MB for 7 windows (as measured). Heavy on memory due to Swift runtime + multiple WKWebView instances.
*   **Performance:** Struggles with focus theft and wheel events in long transcripts as noted in the brief.

**Recommendation:** **Tauri 2**. It strikes the best balance between "Rust core" (for low-level IPC and process control) and "Web Display" (for hot-reloading CSS/HTML without binary rebuilds). Its native WebKit usage on macOS ensures it doesn't bloat RAM significantly more than the current Swift app, provided we optimize window sharing.

### 2. Windows and Processes Architecture

**Strategy: Single App Instance with Pooled WebKit Contexts.**
Instead of spawning a new `WKWebView` (and its associated helper processes) for every window, the Rust application should instantiate **one or two global WebContexts** at startup. Tauri's `WebviewWindowBuilder` can be configured to share a context ID across multiple windows if they load similar content.

*   **Process Model:**
    *   **Frontend (Rust):** One process, owns the UI logic, IPC bridge, and file watchers for hot-reload.
    *   **WebKit Helper Pool:** A pool of 1–3 `WebContent` processes shared among all windows. The OS manages these. When a window is closed, its view releases hold on the context but doesn't kill the helper process immediately if other views exist.
    *   **Agent Workers:** Keep the existing model: separate Rust subprocesses (or native threads if performance allows) running the CLI hooks, communicating with the Frontend via Unix Domain Sockets or Tauri's `Command` API.

*   **RAM Impact of Sharing:**
    *   Without sharing (8 separate WebContent): ~40 MB * 8 = 320 MB + 8 * Rust overhead.
    *   With sharing: ~100 MB base for the context + lightweight window surface buffers. This reduces peak RAM to roughly **350–400 MB** for 8 windows, keeping it below the owner's "One Text" (480 MB) baseline while providing a Rust backend.

*   **Live Update Preservation:** The `frontend` process handles the "hot update" logic. It watches the `dist` folder; if changed, it triggers a state refresh in JS via IPC. Since only one frontend binary needs rebuilding, the worker swap mechanism remains identical to the current Swift implementation.

### 3. Rendering and Streaming Design

**Token Flow & Batching:**
1.  **Rust Core:** Receives stream from agent CLI.
2.  **Chunking:** Buffer chunks of ~4–8 tokens into a JSONL batch every 10–20ms (aligned to visual frame rate, not token arrival).
3.  **IPC Bridge:** Send batches over `TauriCommand` or a custom channel to the JavaScript runtime.
4.  **JS Runtime (inside WebView):** Receives stream, parses Markdown, and appends text to a specific `<div>` with `position: relative`.

**Long Transcript Optimization:**
*   **Virtualization:** Do *not* render all rows. Use a library like `react-window` or a pure JS implementation (`jsdom-virtual`) to only render visible chunks (e.g., 100 rows at a time) in the DOM.
*   **Recycling:** As the user scrolls, the virtualizer swaps out DOM nodes for new tokens without adding to the DOM node count, keeping memory flat.
*   **Markdown Rendering:** Rendered on the JS side using `marked.js` or `commonmark` (bundled in the template) for flexibility. Rust handles *what* is sent; JS handles *how* it looks.

**Charts and Live Data:**
*   **Pinned Charts:** Since the display is a web template, use **iframes** within the HTML structure for chart blocks.
    *   *TradingView:* Use the official Lightweight Charts iframe widget (no custom engine needed).
    *   *Custom SVG/JS:* Agents write code in the chat; this executes in a sandboxed iframe attached to that specific reply block.
*   **Live Bridge:** The `vcx.live()` function becomes a standard JS `fetch`/`WebSocket` loop inside the iframe's main thread, updating the chart canvas directly. No native bridge needed for live updates, reducing IPC latency.

### 4. Hot-Reload Template Implementation

**Structure:**
*   **Template Directory:** A dedicated folder (e.g., `./app-assets/dist`) containing `index.html`, `styles.css`, and `runtime.js`.
*   **Versioning:** Each file gets a Git commit hash in the `<head>` (`<!-- v:abc123 -->`). The Rust core reads this on boot to verify integrity.

**Reload Mechanism:**
1.  **Watcher:** A `notify` crate instance in Rust monitors the `./app-assets/dist` folder for filesystem changes (using `FSEvents` on macOS).
2.  **Injection:** When a change is detected:
    *   Pause streaming (optional, to prevent visual flicker).
    *   Send an IPC message `{"type": "inject_template", "version": "new_hash"}`.
    *   JS swaps the entire `<body>` or critical modules using a module bundler runtime (like `systemjs` or native ESM loader) or performs a hard reload of the view via `window.location.reload()`.
    *   **Crucial:** Save scroll position (`scrollTop`) and selection state *before* reload in a global JS variable, then restore it immediately after.

**Safety & Validation ("Last-Good"):**
*   **Checksums:** On boot, Rust validates the hash of the loaded template against the expected "stable" version. If mismatch (user edited files manually), show a warning but allow fallback.
*   **Fallback Renderer:** If JS execution fails or syntax error occurs on load:
    *   Catch the error in the `window.onerror` handler.
    *   Switch to a minimal "Safe Mode" DOM (plain text rendering) while alerting the user via a system tray notification that the custom CSS broke and can be rolled back by restarting VCX.
*   **Agent Safety:** Agents running outside the WebView cannot execute arbitrary commands in the UI thread. They communicate strictly via typed IPC. The JS runtime runs in the WebContent process (sandboxed), meaning an agent script crashing in JS only drops a window, not the main app.

### 5. Migration Path (Shippable Steps)

**Phase 1: The Hybrid Shell (Current Swift + New HTML View)**
*   **Goal:** Move the transcript rendering to a new `WKWebView` inside the existing Swift App, controlled by Rust code injected into the Swift build (via Objective-C++ bridge).
*   **Measure:** Does the new web view handle 5k rows with better frame stability? Can we inject the "hot-reload" watcher logic here?
*   **Stop Condition:** If the Swift-to-WebView IPC latency exceeds 30ms or battery drain increases by >10%.

**Phase 2: The Rust Core (Swift Frontend + Rust Logic)**
*   **Goal:** Replace the Swift UI controller and Agent Worker management with a Tauri backend. Keep the "Shell" from Phase 1 as the WebView host.
*   **Measure:** Reduction in app startup time; improvement in "live update" swapping speed (<1s); RAM footprint drops to ~200MB idle.
*   **Stop Condition:** If `FSEvents` on macOS behaves erratically causing random reloads.

**Phase 3: Full WebView Migration (Tauri v2 + Shared Context)**
*   **Goal:** Port the entire window logic to Tauri, implementing the single-shared WebContext architecture. Integrate the 7,500 lines of headless checks into `headless-ui-test`.
*   **Measure:** 8 windows open < 350MB RAM; smooth scrolling on long transcripts; successful offscreen renders matching the current README GIF.
*   **Stop Condition:** If complex Markdown tables (nested in tables) break rendering compared to Swift's custom `NSTextView`.

**What to Keep in Swift:**
*   **Signing/Notarization Logic:** If Tauri's Rust signing flow on macOS 26 "Tahoe" is unverified, keep a tiny Swift helper for code signing (using Keychain access via `sec` bindings).
*   **Global Hotkeys/TCC:** Tauri handles most, but if specific deep-system permissions fail, retain the Swift utility module.

### 6. Risks and Costs

**RAM & Energy:**
*   *Risk:* WebKit is heavier than a native `CoreText` renderer for simple text.
*   *Mitigation:* Aggressive virtualization of the DOM (render only what's visible). Use `will-observe-change` to lazy-load images in the chat history.
*   *Cost:* Slightly higher battery drain during heavy scrolling compared to pure native text, but likely comparable to or better than 8x separate WebViews in Swift.

**Input Latency:**
*   *Risk:* IPC round-trip between Rust and JS for every keystroke if not batched.
*   *Mitigation:* Use the `onKeydown` event in JS directly where possible; map simple input (composer text) to native DOM events rather than sending strings across the bridge.

**Rewrite Size:**
*   **Estimate:** 8–12 weeks for one developer with AI agents, including writing the custom virtualizer and testing the 7,500 line suite in the new headless environment.
*   **Checks:** The 7,500 lines of self-checks are ported to Rust (`headless-ui-test`). They drive off-screen windows (using Tauri's `--hide`) and assert text content matches expectations. This maintains the "verified without opening" workflow.

**Stability:**
*   *Risk:* User editing `index.html` manually breaks the app.
*   *Mitigation:* The "Safe Mode" fallback and strict schema validation on JSON data exchanged between Rust and JS mitigate this.

---

### Comparison Table: Options for Vibe Code X Display

| Feature | **Tauri 2** (Rust + WebKit) | **wry/tao** (Raw WKWebView) | **Dioxus Native** | **SwiftUI Current** |
| :--- | :--- | :--- | :--- :--- |
| **Resident RAM (1 Window)** | ~90 MB (Est.) | ~85 MB (Est.) | ~30 MB (Est.) | 253 MB (Measured) |
| **RAM (8 Windows)** | ~750 MB (Pooled) | ~1.2 GB (Est.) | ~150 MB (Est.) | ~1.8 GB (Projected) |
| **Streaming/Scroll Perf** | High (JS Virtualization) | High | Medium (Native Draw limits) | Medium (Layout bugs noted) |
| **Maturity (macOS 26)** | High | Medium | Medium/Low | High |
| **Headless Test Support** | Good (`headless-ui-test`) | Good | Emerging | Excellent (Current state) |
| **Focus/IME Handling** | Native Mapping | Native Mapping | Native Mapping | Native (but buggy in complex stacks) |
| **Hot-Reload Ease** | Easy (File Watch + IPC) | Medium (Custom logic) | Hard (No JS engine option limits CSS) | Medium (Swift rebuild required) |
| **Chart Handling** | Iframes/JS Sandbox | Iframes/JS Sandbox | Difficult (Native draw only) | Good (WKWebView embedded) |
| **Rewrite Effort** | ~10 Weeks | ~12 Weeks | ~6 Weeks (but high risk) | N/A |

*Sources:* Tauri docs (tldraw.com/blog/tauri-2), General WebKit memory profiles on macOS (measured via `top`/`footprint` in brief data), Dioxus Native benchmarks (est. based on GitHub activity trends). *RAM figures for 8 windows and Tauri are estimates based on standard pool behavior.*
