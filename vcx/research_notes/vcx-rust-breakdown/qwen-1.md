Here is the plan to migrate Vibe Code X from Swift to Rust using tao + wry, prioritizing a windowless verification path and preserving the existing socket protocol while replacing the heavy session model.

### Executive Summary (5 Lines)
First, port the `RuntimeTransport` and agent adapters as native Rust crates that speak the existing JSON-Lin socket protocol, allowing immediate swapping of workers behind the Swift frontend. Second, build a windowless `tao+wry` shell to run offscreen rendering and DOM verification scripts without user interaction or dock visibility. Third, migrate the monolithic `Session.swift` state machine into a typed Rust struct with virtual scrolling and patch-based updates, keeping the socket protocol but tightening JSON serialization. Fourth, replace the attributed-string composer with a native web-view composer handling IME and chips via object bridge only if necessary. Fifth, use hot-swap binaries to transition workers from Swift to Rust while preserving file descriptors and session state for zero-downtime migration.

### Rust Workspace & File Mapping

| Crate | Responsibility | Swift Files Replaced / Covered |
| :--- | :--- | :--- |
| **vcx-runtime** | Core process logic: socket I/O, back-pressure framing, lifecycle (attach/detach), and swap state handling. | `RuntimeTransport`, `RuntimeServer`, `RuntimeClient`, `RuntimeSession` (logic only, not UI). |
| **vcx-protocol** | Typed JSON-Lin schema validation, message routing (hello/perform/list), and agent connection abstraction (`Connection` trait). | `Messages`, `ProviderJSONReader`, `ClaudeCompatibility`, parts of `Commands`. |
| **vcx-agents** | Specific CLI wrappers for Claude, Qwen/Ollama, Codex RPC, and Agy. | `Agents` (1023 lines), `Agy`. |
| **vcx-ui-shell** | Tao event loop + Wry web view wrapper, window state (position/size), and offscreen rendering context. | `main`, parts of `Views` (shell wrappers). |
| **vcx-render** | HTML/CSS loader, Markdown parser/sanitizer, iframe sandboxing for "chart" blocks, and virtual scrolling engine. | `Transcript` (render logic), `Chart` (webview embedding), `Composer` (render part). |
| **vcx-state** | Typed state model (`Row`, `Item`, `Session`), change detection patches, and local disk state persistence. | `Session` (2305 lines), `StateHome`, `Directory`, `ErrorsRank`. |
| **vcx-verify** | Headless verification suite: DOM evaluation scripts, synthetic mouse/keyboard injection, offscreen snapshots. | `*Check.swift` (19 files). |

### Port Order & Slices

**Slice 1: The Rust Runtime Core (`vcx-runtime`) + Swift Workers**
Build the socket handling and lifecycle management in pure Rust to replace `RuntimeTransport`, `RuntimeServer`, and `RuntimeClient`. Keep all existing Swift worker binaries running.
*   **Proof Command:** Run `cargo run --bin vcx-runtime-test -- --listen` on a fresh socket, then point a live Swift worker at the new port using `--runtime-url <new_ip>`. Verify the Swift worker sees the Rust server via `hello` and sends a `perform` action that returns a valid receipt.
*   **Coexistence:** Use a configuration flag in `settings.json` to specify the runtime endpoint; switch workers to connect to the new Rust binary while keeping the same process IDs.

**Slice 2: Windowless Verification Harness (`vcx-verify`) + Tao Shell**
Implement a `tao` application with a hidden `wry::WebView` (no top-level window) that loads a minimal HTML template, executes JS to read DOM text/structure, and sends results back to the Rust core via IPC.
*   **Proof Command:** Compile a simple "ping" page; run the shell binary with `--headless --url data:text/html,<simple>`. Assert that the JS result matches expected DOM nodes without any window appearing in Activity Monitor's window list or on the desktop.
*   **Coexistence:** This runs parallel to Slice 1, validating that the new display engine can communicate with the socket logic before connecting to any agent.

**Slice 3: Typed State & Protocol (`vcx-protocol` + `vcx-state`) + Swift Frontend**
Migrate the `Session` state machine and agent adapters to Rust structs with strict typing, but keep the Swift frontend binary running by having it consume the new typed messages (or a JSON adapter) from the socket.
*   **Proof Command:** Inject a complex agent response into the socket; assert that the Rust side parses it without panic (proving the typed parser works) and sends a `session/update` patch back to the existing Swift UI, which should render the data correctly.
*   **Coexistence:** The Swift UI continues drawing while feeding its state requests to the new Rust brain via the stable socket protocol.

**Slice 4: Render Engine (`vcx-render`) + Full Migration**
Replace `Transcript`, `Chart`, and `Composer` with the Rust implementation handling virtual lists, markdown parsing, and iframe sandboxing. Finally, migrate the UI drawing logic from Swift to Rust using Tao/Wry.
*   **Proof Command:** Run a full agent session end-to-end in the new Rust binary; verify that thousands of rows scroll correctly, code blocks render instantly, and "chart" iframes are isolated.
*   **Coexistence:** Perform a live update: build the new `VCX.app`, kill the old process, and have the new one attach to the same workers (using `freezeForSwap` logic ported) or reconnect agents if they were long-running CLI children.

### Deep Dive on Specific Questions

#### 3. What to rebuild better?
*   **Protocol:** Keep the v1 JSON-Line socket for simplicity but add a compact header (version + type byte) in Slice 3 to allow future typed binary framing without breaking existing parsers. The "untyped `[String: Any]`" becomes a strongly typed Rust enum (`ItemKind`) decoded from JSON, reducing runtime branching.
*   **State Model:** Replace the 2,305-line state machine with a functional `Session` struct holding immutable snapshots and a `diff` builder. Patches become explicit Rust structs (`PatchMeta`, `PatchRow`) instead of ad-hoc JSON objects.
*   **Concurrency:** Use `tokio` for async agent I/O but bind it to `tao`'s single-threaded event loop via `tokio::task::LocalSet` or a dedicated thread pool, ensuring the main thread remains responsive to mouse/touch events.
*   **Template Data Contract:** Load HTML/CSS from a versioned directory (`/Resources/{version}/`). The Rust core parses a `manifest.json` describing schema versions; if an edit fails validation, revert to the "last-good" version automatically.
*   **Composer:** Keep it native within the Wry view using a custom JS bridge for IME and marked text. Chips (attachments) are rendered as HTML elements injected by Rust via `webview.evaluate_script` or an ObjC2 bridge only if native Cocoa text attachments are strictly required, preferring JS objects for flexibility.
*   **Live Update:** Implement a binary hot-swap where the new Rust process connects to the same Unix socket, takes over the session lease, and requests the current state snapshot from the worker. The worker swaps its own process ID under the hood, hiding the reboot from the agent child.

#### 4. What not to port?
*   **Dropped:** The Python installer/auto-update logic (keep in Swift/Python or switch to `pkgbuild` + Rust wrapper). The complex "Fleet" menu bar sync if it can be simplified to file-watching; otherwise, keep the ObjC2 bridge.
*   **Left in Swift:** If the ObjC2 bridge for native text composition is too brittle, leave the `Composer` drawing in Swift but feed data from Rust. The 50+ lines of Objective-C glue for `NSTextView` might remain if Wry's JS-to-ObjC loop proves slower than a direct native call.
*   **Merged:** Merge `Session.swift` and `StateHome` into one `vcx-state` crate; merge `Commands` and `Messages` into `vcx-protocol`.

#### 5. Windowless Verification with Tao + Wry
*   **Mechanism:** Create a `tao::WindowBuilder` with `title = ""`, `visible = false`, and set the `ContentRect` off-screen (e.g., x=10000). Wrap this in `wry::Webview` using `wry::WebViewBuilder`. Load a script that returns document HTML or innerText.
*   **Traps:** On macOS, hidden windows still consume activation policy resources; ensure `NSWindowActivationBehavior = .delegatesWantToActivate` is handled if needed (mostly irrelevant if strictly hidden). Watch for timer throttling: hidden WKWebViews on some iOS/macOS versions throttle animations; disable `requestAnimationFrame` or run JS timers via the Rust core's polling loop (`vcx.live`) instead of relying on JS `setInterval` inside the view.
*   **Checks Migration:** Convert 7,668 lines of Swift checks to Rust unit tests (for logic) and integration tests that spawn the offscreen window, feed it data, assert DOM output, and verify mouse injection coordinates match expected paths. Page tests become Rust functions calling `evaluate_script` on a snapshot of the rendered view.

#### 6. Risks and Stop Rules
*   **Top Risk:** The "windowless" behavior on macOS 26 (or the current 14/15 base) may throttle `requestAnimationFrame` or hide DOM updates if the window isn't strictly in the `NSApplication` hierarchy correctly. **Stop Rule:** If DOM reads from the offscreen view lag by >100ms or miss frames, fall back to a tiny hidden "status" window until fixed.
*   **Second Risk:** Socket handover during swap. If the Rust worker fails to steal file descriptors from the Swift process cleanly, the agent CLI (e.g., `claude`) might lose its pipe connection. **Stop Rule:** Implement a "cold start" fallback where agents are restarted briefly on the new worker if hot-swap timing fails; measure this at <1% session loss.
*   **Effort Estimate:** 
    *   Slice 1 (Runtime): 2 weeks (high confidence, logic is I/O bound).
    *   Slice 2 (Shell/Verify): 3 weeks (macOS quirks, JS integration).
    *   Slice 3 (State/Proto): 4 weeks (complex typing of untyped JSON).
    *   Slice 4 (Render/UI): 6 weeks (SwiftUI to Wry mapping is non-trivial for rich composer).
    *   **Total:** ~15 developer weeks.
