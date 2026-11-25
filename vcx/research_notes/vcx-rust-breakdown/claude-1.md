# VCX in Rust (tao + wry): where to cut and in what order (reviewer claude-1)

Sources read 2026-11-25. Swift citations are `file:line` under `/Users/mr/self/my-apps/vcx/Sources/VCX`. Library facts cite docs.rs or the crate sources in `~/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/` (wry 0.57.2 and tao 0.37.2 are cached there, not 0.58/0.38; I checked the 0.58/0.38 pages on docs.rs where it mattered). Anything not sourced is marked "estimate".

## Recommendation in 5 lines

1. Build a thin shared core first: typed v1 wire types plus a conformance suite that passes against today's Swift worker. That suite becomes the specification. Do not start with a full core library.
2. Next, ship the tao + wry frontend (as a second app, "VCX Next.app") against the unchanged Swift workers, one window at a time. Lease takeover already closes the Swift window cleanly (`main.swift:213-217`), so each session is moved by hand and can be moved back.
3. Rust workers come last, one provider at a time, chosen per new session by the Rust frontend. A worker failure loses agent work, while a frontend failure loses only a window (the agents are children of the workers), so the riskier half waits until the protocol is proven.
4. Do not try to hand a running agent from a Swift worker to a Rust one through the swap manifest. It is feasible only by installing Rust over the Swift app's path and parsing Swift's private session serialization. Instead, idle Swift sessions close and reopen cold from provider history.
5. Redraw three things: replace the 2,305-line `Session` with a pure typed reducer plus a worker controller, store the draft as typed pieces (the wire already does), and move the checks out of the shipped binary. Keep two other boundaries: the process split with its lease/sequence/receipt protocol, and the single provider trait (but emitting VCX's own typed events, not Codex-shaped JSON).

## Workspace

| Crate | Responsibility | Swift files it replaces |
|---|---|---|
| `vcx-protocol` (lib, no IO) | Typed v1 frames with serde: `hello`, `attach`, `perform` + the 15 actions, `detach`, `list`, the `session/update` patch, `leaseLost`, `runtime/swapping`, error codes. Line codec with the 32 MB frame and 64 MB buffer limits. Unknown fields are kept in a flattened map so a frame survives a round trip unchanged. | The frame and dictionary shapes inside `RuntimeTransport` (framing part), `RuntimeServer`, `RuntimeClient`, `RuntimeSession` |
| `vcx-model` (lib, pure) | Typed `Row { id, kind, items }` and `Item` (an enum of the known types plus `Other(raw)`), `Draft = Vec<DraftPiece>` (text, localImage, paste, command), turn state machine, prompt queue, question flow, permission state. A reducer `apply(AgentEvent) -> Patch`. No processes, no sockets, no AppKit. | The state half of `Session.swift`, `Messages`, the reducing parts of `Commands` |
| `vcx-agents` (lib) | A `Provider` trait (spawn, send turn, interrupt, answer approval, close; stream of typed `AgentEvent` that keeps the raw JSON) with adapters for `claude -p` stream-json, `codex app-server` JSON-RPC, Ollama HTTP chat, `agy`. Also capability and model catalogs. | `Agents`, `RPC`, `Agy`, `Capabilities`, `ProviderJSONReader`, `ClaudeCompatibility`, `ModelControl` |
| `vcx-worker` (bin) | Socket server (0700 folder, `getpeereid`), leases, sequence receipts, 80 ms patch batching, checkpoint and recovery, execv self-swap, settings and state home, trace log. Owns one session and its agent child. | `RuntimeServer`, `RuntimeSession`, `RuntimeSwap`, `RuntimeRecovery`, `NativeThreadLease`, `StateHome`, `Settings` (worker side), `Trace`, `Directory`, `ConversationArchive`, `ArchivePath`, `ErrorsRecall`/`ErrorsRank` |
| `vcx-client` (lib) | Frontend end of the socket: launch-or-connect under the `.launch.lock`, `hello`/`attach`, reconnect, `perform` with sequences, applying patches onto a client-side `vcx-model` copy, lease loss. | `RuntimeClient`, the frontend part of `RuntimeUpdate` (handover) |
| `vcx-render` (lib) | Markdown to sanitized HTML in the core (pulldown-cmark + ammonia are the obvious candidates: https://crates.io/crates/pulldown-cmark, https://crates.io/crates/ammonia, read 2026-11-25; choosing them is an estimate). HTML cache keyed by (item id, content hash), incremental rendering of the streaming tail, file-link rewriting, and turning a model diff into page operations. | Markdown and row-building in `Views` and `Transcript`, `FindRanges` (search index) |
| `vcx-app` (bin, the `.app`) | tao event loop, one wry web view per window, `vcx://` custom protocol serving the template folder, state pages and chart iframes, IPC handler, template hot reload with last-good fallback, `vcx.live` proxy with an allowlist, Fleet presence files, close control, desktops, menu, Dock. The objc2 glue lives here. | `main`, `Views` (shell), `Composer`, `Chart`, `Find`, `Run`, `TaskBoard`, `QuotaOverview`, `CloseControl`, `Desktops`, `FleetPresence`, `TaskProgress`, `UpdateBuild` |
| `template/` (folder, not a crate) | HTML/CSS/JS, `manifest.json` with the contract version, and a JSON Schema of the contract generated from the Rust types | The SwiftUI views |
| `vcx-conformance` (test bin) | Runs one suite against any worker executable (`--worker <path>`) in a temp `VCX_RUNTIME_HOME` with scripted fake agent CLIs: protocol, bounds, idempotency, lease, recovery, swap, provider replay. | `RuntimeCheck`, `RuntimeBoundsCheck`, `RuntimeLoadCheck`, `RuntimeSwapCheck`, `RecoveryCheck`, `ArchiveSafetyCheck`, `ArchiveLifecycleCheck`, `ArchiveResumeCheck`, `ProviderCheck`, `ClaudeParityCheck`, `RetryCheck`, `AgyCheck`, `ModelControlCheck`, `TraceSafetyCheck` |
| `vcx-pagetest` (dev bin, never shipped) | Windowless harness: loads the template in an unshown tao window, feeds fixture state, reads the DOM, sends input, writes PNGs. | `FrontendCheck`, `BugCheck` (UI parts), `ChartInteractionCheck`, `InteractionCheck`, `SelectionCheck`, `InstantCloseCheck`, `--render`, `--render-demo`, `--scroll-bench` |

Ship two executables in one bundle, `vcx-app` and `vcx-worker`. Today the build identity is the SHA-256 of the one executable (`RuntimeClient.swift:12-13`), so a frontend-only change still marks every worker as outdated and triggers a swap. With a separate worker binary and its own hash, a template or frontend push never moves a worker. The worker binary also does not link WebKit. How much memory that saves is an estimate; it is small, because today's workers already total only 0.11 GB for 7.

### Which boundaries to keep, which to redraw

- **Keep the frontend/worker split and the v1 socket semantics.** Lease, strictly increasing sequence with per-sequence receipts, revision, snapshot on attach, batched patches: all of these are right. They are also what makes per-window coexistence possible (see the slices).
- **Keep one provider abstraction, but change what it emits.** Today the `Connection` protocol (`RPC.swift:21-33`) passes untyped `JSON` events shaped like Codex app-server, and it also carries archive and Fleet fields (`archiveProcess`, `fleetFile`, `logFile`) that do not belong in it. In Rust, every adapter, Codex included, should map into a VCX-owned `AgentEvent` enum that keeps a `raw` value. Then a Codex schema change touches the Codex adapter only, not the shape every provider has to imitate.
- **Redraw `Session`.** It imports AppKit and SwiftUI (`Session.swift:1-5`) and has 56 `ObservableObject`/`@Published` uses (grep count). That means the worker process runs a SwiftUI object graph. Split it into: the pure reducer (`vcx-model`); the turn and queue controller plus command handling (`vcx-worker`); usage and quota (its own module); thread switching and archive (`vcx-worker`); presentation (the page).
- **Redraw the draft.** The worker and the wire already treat it as a list of typed pieces: `draftContent` emits `text`, `localImage`, `paste` and `command` (`Composer.swift:593-603`). `NSAttributedString` is only the local editing form. Make `Vec<DraftPiece>` the one form everywhere.
- **Redraw the checks.** 7,668 lines of checks ship inside the app binary behind 40-odd flags (`main.swift`). Move them into `cargo test`, `vcx-conformance` and `vcx-pagetest`. The installed app keeps only what the update job needs to preflight a build: `--runtime-protocol` printing `1` (`RuntimeClient.swift:273-291`) and `--adopt-check`.

## Slices in order, each with its proof

Effort assumes one developer with AI agents; every figure is an estimate.

**S0. Protocol types and a probe (1 to 2 days).** Build `vcx-protocol`, plus `vcx-probe`, a CLI that connects to a socket and runs `hello`, and with `--attach` also attach. The rule: the probe only runs `hello` against the live runtime folder, because attaching takes the lease and closes his Swift window (`main.swift:213-217`, `RuntimeServer.swift:192`). Attach is used only on workers started under a temp `VCX_RUNTIME_HOME`. That variable also disables swaps (`RuntimeSwap.swift:89-93`) and relocates state (`StateHome.swift:36`).
- Proof: `cargo test -p vcx-protocol`. It round-trips frames captured from a Swift test worker byte-equal after canonical key sorting. Then `vcx-probe hello <live socket>` prints `protocol 1` and the worker's build hash, and that hash matches `shasum -a 256 "~/Applications/Vibe Code X.app/Contents/MacOS/VCX"`.

**S1. Conformance suite, green against Swift (3 to 4 days).** `vcx-conformance --worker "<Swift VCX path>"` launches the worker like the frontend does: `--runtime-worker <socket>` with the cwd set (`RuntimeClient.swift:205-215`). It uses the existing fixture agent command (`--runtime-fixture-command`) or a Rust fake CLI that replays recorded stream-json. It covers hello, attach snapshot, every action, the patch sequence, duplicate-sequence idempotency, lease loss, the frame limits, recovery after `kill -9`, and closing.
- Proof: the whole suite passes against the installed Swift binary, and against a deliberately broken worker (one receipt dropped) it fails. Without the failing run, a green result proves nothing.

**S2. Read-only Rust viewer for one session (4 to 6 days).** Build `vcx-app` with one tao window and one wry web view. It loads `template/` through the `vcx://` custom protocol and hot-reloads it. It attaches to an existing Swift worker for one session (`vcx-next --attach <session id>`) and renders the snapshot and the patches, with Markdown and HTML coming from `vcx-render`. There is no composer yet. `vcx-pagetest` is born in this slice too.
- Proof, windowless: `vcx-pagetest --fixture 5000-rows` reports the DOM row count, the time to first paint, the p95 time to apply a patch, and a PNG.
- Proof, live: attach to a real idle session. The Swift window closes, the Rust window shows the same last 20 rows (DOM text compared with the worker snapshot via `evaluate_script`). Then `VCX --resume <id>` takes the session back, and the Rust window closes on `session/leaseLost`.

**S3. Composer and actions (4 to 6 days).** The composer lives in the page. It handles `send`, `sendNow`, `unsend`, `stop`, `answer` (the question card replaces the input), the `/` palette, image and paste chips, and `perform` with sequences. The draft is synced as pieces plus a generation, like today (`RuntimeSession.swift:198`).
- Proof: an end-to-end conformance test. The Rust frontend drives a Swift worker with the fixture agent, sends, and the assistant row appears. A pagetest feeds `setMarkedText`/`insertText` through objc2 on the `WKWebView` (dead-key `é`, a Japanese IME composition) and checks the textarea value. A draft survives killing and restarting the frontend.

**S4. Daily-drivable frontend (6 to 10 days).** Many windows. New sessions are spawned by launching the Swift worker by path, which works because the client launches workers by executable path plus socket (`RuntimeClient.swift:205-207`). Also: Fleet presence files, status bar, task bar, find, sidebar, charts in sandboxed iframes with `vcx.live` routed through the core allowlist (today it goes through a `WKScriptMessageHandler`, `Chart.swift:161-176, 440`), restoring windows across restarts of the Rust frontend, and desktops.
- Proof: 13 windows open for a working day. Total resident memory of the frontend plus all its WebContent processes, from `ps -o rss` over the frontend pid and its `com.apple.WebKit.WebContent` children, against the Swift frontend's 0.31 GB. The Fleet card shows each Rust window with the right state. Zero lost drafts in the trace log.

**S5. Rust frontend live update (2 to 3 days).** A template edit needs no binary at all: hot reload. A frontend binary update is a new process that takes the leases over, the same handover as today.
- Proof: a pagetest edits a CSS file and sees every window reload within 1 s. A syntax error in the template makes the windows fall back to the last-good copy. A binary handover with 5 attached windows loses no patch: the revision is continuous in the trace.

**S6. Rust worker, Claude first (8 to 12 days), then Codex, Qwen, agy (3 to 5 days each).** Build `vcx-model`, `vcx-agents` and `vcx-worker`. The Rust frontend gets a per-provider setting `worker = swift | rust` that applies to new sessions only.
- Proof: `vcx-conformance --worker target/release/vcx-worker` is green on the same suite as Swift. A replay parity test feeds the same recorded provider stream to both workers and diffs the normalized snapshots (ids and timestamps masked): no diff. Then a week of real use per provider.

**S7. Rust worker self-swap and recovery (4 to 6 days).** execv onto the new worker binary, keeping the listener, the lock and the agent pipes, the same design as `RuntimeSwap.swift:118-147`.
- Proof: the swap test from `RuntimeSwapCheck` ported into the conformance suite. Mid-idle swap, the agent pid is unchanged, no bytes are lost (the leftover is carried), and a forced failed adopt check rolls back.

**S8. Retire Swift (1 to 2 days).** Stop the Swift auto-update build. Swift workers still running stay on their build until their sessions close (a worker that cannot move keeps its sessions, as the brief says). Then delete the Swift app.
- Proof: `ls ~/.local/state/vcx/runtime` shows no `v1-*.sock` whose `hello` returns the Swift build hash. The Rust conformance suite runs in CI.

### How Swift and Rust coexist on one Mac

- **Two apps.** `~/Applications/Vibe Code X.app` (Swift) stays unchanged, keeps its bundle id and auto-update. Rust ships as `~/Applications/VCX Next.app` with its own bundle id.
- **Never install the Rust build at the Swift path.** Swift workers execv `~/Applications/Vibe Code X.app/Contents/MacOS/VCX` during a live update (`RuntimeUpdate.swift:27`, `RuntimeSwap.swift:92`). A Rust binary at that path would receive Swift adopt manifests.
- **Share the runtime folder, nothing else.** Socket names (`v1-<16 hex of sha256(session)>.sock`, `RuntimeClient.swift:19-23`) are what let the Rust frontend find and attach to Swift workers. Settings, window registry and restore files, update markers (`installed-build`, `update-request`, `manual-build`, `RuntimeUpdate.swift:59-73`) and the Fleet file names stay per app. The Rust app must never write the Swift update markers.
- **Per window, by lease.** Opening a session in the Rust app closes its Swift window. Reopening it in Swift closes the Rust one. Nothing is in two places at once, and his working sessions keep running in their workers whichever frontend holds them. One risk to test in S2: when the Swift frontend hands over to a new frontend on a Swift update, it may restore windows whose lease Rust now holds, and take them back. The test is a forced Swift update (`--update-now`) while one session sits in Rust.
- **The reverse direction (Swift frontend on a Rust worker) needs no slice.** The Swift frontend only launches its own executable as worker, but it can attach to a Rust worker socket that already exists. That makes it a free cross-check of S6.

### Can a Rust worker take over a running agent through the Swift swap state? Not worth it.

The mechanism is execv of the same pid onto the installed path with `--adopt <manifest>` (`RuntimeSwap.swift:136-142`), after a blocking `--adopt-check` run of the new binary (`RuntimeSwap.swift:157-177`). The manifest carries:
- the listener and lock fds;
- per session, the private `SessionBackend` serialization: rows, plus a `connection` with `kind`, agent `pid`, `input`/`output` fds and base64 `leftover`, plus `nativeLeases` and `recordLock` descriptors (`RuntimeSwap.swift:126-133`);
- only the `claude` and `codex` kinds can be adopted (`RuntimeSwap.swift:22-27`);
- `freezeForSwap` returns nil while work is in flight (`RuntimeSwap.swift:16-17`).

A Rust worker could implement all of that, since pipes and child pids survive execv regardless of language. But it would have to:
- be installed at the Swift app's path;
- check a `build` field against its own hash (`RuntimeSwap.swift:181`);
- parse an internal format no protocol covers, for two providers only.

A failed adopt closes the agent's pipes and SIGTERMs it (`RuntimeSwap.swift:193-203`), so a bug there kills live work. The alternative costs nothing: an idle Swift session is closed and reopened in a Rust worker cold from the provider's own history, the path `RuntimeRecovery` already uses. Estimate: 1 to 2 weeks saved, and no new way to kill an agent.

## 3. What to rebuild better, concretely

**Protocol.** Keep v1 line-JSON byte-compatible for as long as any Swift end exists, but typed in Rust (serde structs, with unknown fields preserved). Sorted keys can stay on output, because no reader depends on them. Add v2 by negotiation once Swift is gone (`hello` offering `protocols: [1, 2]`), with these changes:
- **Item deltas.** Today every changed item is resent whole in each 80 ms patch (`RuntimeSession.swift:176`). Streaming a long answer therefore costs bytes that grow roughly with the square of its length (estimate, derived from that code). v2 adds `appendText {itemId, offset, text}`.
- **Explicit resync.** A revision gap triggers a fresh `attach` snapshot.
- **A schema version per item kind.**
- **A capability list in `hello`.**

Keep line framing and JSON. At these sizes, debuggability with `nc -U` and `jq` beats a binary format.

**State model.** Use typed rows and items with a passthrough. The `Item` enum covers `commandExecution`, `fileChange`, `mcpToolCall`, `dynamicToolCall`, `webSearch`, `peerMessage`, `reasoning`, agent and user messages. Each variant holds the fields VCX displays or reasons about (status, text, exit code, paths), and every item keeps `raw: serde_json::Value`. An unknown `type` becomes `Item::Other`, which renders as a generic folded tool card. The provider schemas that move are absorbed in the adapters. Each adapter has golden fixtures: recorded streams per CLI version, replayed in `cargo test`. When a CLI updates, re-record and read the diff. Untyped JSON stays only at the edge (`raw`), never in the reducer.

**How state reaches the page.**
- **Initial load.** Attach gives the full snapshot to `vcx-client`. The page then fetches its first screen of rows as pre-rendered HTML from `vcx://state/<window>/rows?before=…`. Large payloads travel through the custom protocol, not through `evaluate_script` string literals. `with_asynchronous_custom_protocol` exists in wry 0.58: https://docs.rs/wry/0.58.0/wry/struct.WebViewBuilder.html, read 2026-11-25.
- **Updates.** The worker's 80 ms batching stays. The frontend coalesces incoming patches per window and pushes at most one `vcx.apply(ops)` per frame, where ops are `upsertRow`, `appendText` and `removeRow`, carrying the HTML of changed blocks only.
- **Caching.** Markdown HTML is cached in the frontend core keyed by (item id, content hash). For a streaming message, only the last open block is re-rendered; the closed blocks are cached (estimate of the gain: proportional to the message length).
- **Long threads.** Thousands of rows: first rely on `content-visibility: auto` on rows plus paged loading of older rows. Add a real virtual list only if `vcx-pagetest --fixture 5000-rows` misses its frame budget. That decision comes from a measurement, not up front.
- **Find.** Find runs over the core's text index, so it covers rows that are not in the DOM.

**Concurrency.**
- **Frontend.** The tao event loop owns the main thread, every window and every web view, because WKWebView is main-thread-only. A tokio runtime on a background thread owns the sockets, the file watcher and Markdown rendering. It reaches the main thread with `EventLoopProxy::send_event`, which delivers `Event::UserEvent` (https://docs.rs/tao/0.38.0/tao/event_loop/struct.EventLoopProxy.html, read 2026-11-25). Page IPC arrives on the main thread through `with_ipc_handler` and goes to tokio by channel.
- **Worker.** A tokio current-thread runtime is enough for one session per process: `tokio::process`, `UnixListener`, timers, HTTP to Ollama. Two traps carry over from Swift:
  - Tokio opens fds with close-on-exec, so before the swap's execv the kept fds get `FD_CLOEXEC` cleared, exactly as `RuntimeSwap.swift:134-135` does.
  - An adopted agent pid is not a `tokio::process::Child`, so it needs its own waitpid/kqueue reaper. Swift needed the same (`AdoptedProcess`, `RuntimeSwap.swift:39-73`).

**Template data contract.**
- `template/manifest.json` declares `contract: {major, minor}`.
- The JSON Schema is generated from the Rust view types (schemars, estimate of the crate choice) and checked in. Pagetests validate fixtures against it.
- Adding a field bumps minor; renaming or removing bumps major.
- The core refuses to load a template whose major differs and serves the last-good copy instead. The last-good copy is the folder snapshot, by hash, that last booted, that is, called `vcx.ready(contractVersion)` within 3 s with no `window.onerror` before it.
- On a broken edit, every window reloads last-good and the status bar shows the error with its file and line. The draft and scroll position live in the core, so a reload loses nothing.

**Composer.** Put it in the page, not in a native `NSTextView` over the web view.
- WKWebView already handles marked text and IME for editable elements as a native text input client. That claim is not re-read today and is marked estimate; S3's IME pagetest is what proves it.
- An `NSTextView` overlay brings back what one web view removes: z-order, focus handoff, two layout systems, and question cards that must replace the input. This is the kind of AppKit/SwiftUI seam that produced the freezes `FreezeTrace.swift` was written for.
- Use a `textarea` for the text and a chip strip for the image, paste and command pieces, rather than `contenteditable` with inline atoms. Caret and undo behaviour around non-editable inline spans is a known source of bugs (estimate).
- A long paste becomes a chip. Pasted or dropped images go to the core through a `vcx://upload` POST, and the core writes the file and returns its path.

**Live update in Rust.**
- Three layers: the template (hot reload, no restart); `vcx-app` (process handover by lease, as today); `vcx-worker` (execv self-swap when idle, as today), each with its own binary hash.
- Most UI work becomes template-only pushes, so most updates never restart anything.
- The auto-update job (Python) runs `cargo build --release`, signs, installs into `VCX Next.app`, and writes the Rust app's own markers.

## 4. What not to port

**Drop:**
- `FreezeTrace` and `GraphDump`: they read SwiftUI's AttributeGraph during main-thread freezes (`FreezeTrace.swift:4-6`, `GraphDump.swift:5-6`). Replace them with a generic main-thread watchdog that logs the last IPC and proxy events.
- The `NSScrollView`-of-SwiftUI-cells transcript, `TranscriptWheel` routing between the scroll view and chart web views, and one `WKWebView` per chart (charts become iframes in the window's single web view).
- `NSAttributedString` and the chip attachments.
- `FindRanges`, replaced by core search.
- `Demo` and `--render-demo`, unless the README icon or picture needs them. The icon can stay a Swift script beside the repo, as `make-icons.swift` already is for my-apps.

**Merge:**
- `Settings`, `StateHome` and `Directory` into one worker config module.
- The 19 check files into the three test homes.
- `ErrorsRecall`/`ErrorsRank` port as plain Rust (BM25, `ErrorsRank.swift:3-6`). Keep its 614-prompt identical-output test as a golden test.

**Leave in Python:** the installer, the auto-update job, the archive and cleanup helpers, and the test peers (3,069 lines). They talk to VCX through files and flags, not through Swift types.

**Must stay native through objc2 even in the Rust shell:**
- Desktops: private `CGSCopyManagedDisplaySpaces` and the Dock-bridged move (`Desktops.swift:4-11`).
- Activation policy and Dock visibility (tao exposes both, see section 5).
- `takeSnapshot`, and synthetic `NSEvent`/`NSTextInputClient` calls on the `WKWebView` in tests.
- Raw `WKWebView` access is there: `WebViewExtMacOS::webview() -> Retained<WryWebView>` and `ns_window()` exist in wry 0.58 (https://docs.rs/wry/0.58.0/x86_64-apple-darwin/wry/trait.WebViewExtMacOS.html, read 2026-11-25). Use it to set `WKPreferences.inactiveSchedulingPolicy` if wry's option does not fit, and for occlusion handling.
- `getpeereid`, `execv`, fd flags: libc, not objc2.
- Pasteboard file URLs and drag-and-drop of Finder files, only if the page's paste and drop events turn out not to carry paths (estimate).

## 5. Windowless verification with tao + wry

**Use a hidden tao window, not "no window".** wry's `build` takes a window handle, and `build_as_child` takes a parent (https://docs.rs/wry/0.58.0/wry/struct.WebViewBuilder.html, read 2026-11-25). A web view that is not in a window at all falls under `WKPreferences.inactiveSchedulingPolicy`. Apple: "A policy you set to specify how a web view that's not in a window handles tasks", with cases none, suspend and throttle; macOS 14.0+ (https://developer.apple.com/tutorials/data/documentation/webkit/wkpreferences/inactiveschedulingpolicy-swift.property.json and `...-swift.enum.json`, read 2026-11-25). wry maps `with_background_throttling(BackgroundThrottlingPolicy::Disabled)` to `inactiveSchedulingPolicy = none` on macOS 14+ (`wry-0.57.2/src/wkwebview/mod.rs:515-538`; the 0.58 docs list the same method with "Supported since version 14.0+").

The precedent in this codebase is the Swift checks:
- They already mount a `WKWebView` in a borderless `NSWindow` that is never ordered front (`ChartInteractionCheck.swift:76-89`).
- They read the DOM with `evaluateJavaScript` (`:152-158`), click with `NSEvent.mouseEvent` sent straight to the view (`:160-176`), type with `window.sendEvent` of key events (`:223-227, 252-258`), and write PNGs with `takeSnapshot` (`:211-221`).

The Rust harness reproduces exactly that. The tao window is built with `with_visible(false)`. The `WryWebView` is reached through `webview()` for snapshots and events (objc2-web-kit 0.3.2 has `takeSnapshotWithConfiguration_completionHandler`, `objc2-web-kit-0.3.2/src/generated/WKWebView.rs:532`), and `evaluate_script_with_callback` for DOM reads (`wry-0.57.2/src/lib.rs:2114`). Whether the Swift chart check passes on macOS 26 today I did not run, so its success is not claimed here.

**Traps, with sources:**
- **Hidden or occluded page means throttled timers and rAF.** WebKit marks a page hidden when its native window is occluded. A WebKit report dated 2026-11-11 measured "page hidden" over a 28 s occlusion, and showed the page stayed visible only with the private `_setWindowOcclusionDetectionEnabled:false` (https://bugs.webkit.org/show_bug.cgi?id=331092, read 2026-11-25). The page also stops rendering updates, and the WebContent process can be napped for many seconds (Apple forums report, https://developer.apple.com/forums/thread/671830, read 2026-11-25 via search summary only, so treat it as a candidate).
  - Consequences for tests: never wait on `requestAnimationFrame` or timers in the page. The harness drives the page by `evaluate_script` and awaits explicit `vcx.ready`/`vcx.applied(rev)` IPC acknowledgements. A test that needs layout reads `getBoundingClientRect`, which forces layout synchronously. A test that needs a painted frame calls `takeSnapshot`, whose `afterScreenUpdates` defaults to incorporating pending updates (https://developer.apple.com/tutorials/data/documentation/webkit/wksnapshotconfiguration/afterscreenupdates.json, read 2026-11-25).
  - Consequence for the real app: the page must not assume rAF runs in background windows. Apply patches without rAF when `document.visibilityState` is hidden.
- **Activation policy and the Dock icon.** tao's `EventLoopExtMacOS` has `set_activation_policy`, `set_dock_visibility` and `set_activate_ignoring_other_apps`, all effective only before `run` (https://docs.rs/tao/0.38.0/x86_64-apple-darwin/tao/platform/macos/trait.EventLoopExtMacOS.html, read 2026-11-25). The policies are Regular, Accessory and Prohibited (`tao-0.37.2/src/platform/macos.rs:174-182`). The harness uses `Accessory` or `Prohibited` plus `set_activate_ignoring_other_apps(false)` (the default is to activate), so a test run never shows a Dock icon or steals focus.
- **Focus.** Unshown windows do not acquire focus from the desktop. The Swift check makes the web view first responder by hand (`ChartInteractionCheck.swift:234-237`), and the Rust harness must do the same through `ns_window()`.
- **Key events through `sendEvent` cover ordinary keys only.** IME needs direct `setMarkedText:selectedRange:replacementRange:` and `insertText:replacementRange:` calls on the web view (estimate: this is the standard NSTextInputClient path; S3 proves it).

**How the 7,668 lines carry over:**
- **Rust unit tests** (`cargo test`): reducer behaviour (queueing, turn states, question flows, permission states), the provider adapters on recorded fixtures, Markdown sanitizing (script, iframe and `javascript:` URLs stripped), BM25 equivalence, archive path safety. Sources: the pure-logic parts of `Check.swift`, `ProviderCheck`, `ClaudeParityCheck`, `ModelControlCheck`, `RetryCheck`, `AgyCheck`, `ArchiveSafetyCheck`, `TraceSafetyCheck`.
- **Protocol conformance, run against both the Swift and the Rust worker:** `RuntimeCheck`, `RuntimeBoundsCheck`, `RuntimeLoadCheck`, `RuntimeSwapCheck`, `RecoveryCheck`, `ArchiveLifecycleCheck`, `ArchiveResumeCheck`, and the worker half of `InstantCloseCheck`. This is the most valuable group, because it is the specification during coexistence.
- **Page tests** (`vcx-pagetest`): `FrontendCheck`, the UI parts of `BugCheck` (1,168 lines of offscreen renders and wheel routing), `ChartInteractionCheck`, `InteractionCheck`, `SelectionCheck`, the frontend half of `InstantCloseCheck`, and scroll and render benches. Pixel assertions become DOM assertions where possible, with PNGs kept as artifacts.
- **Dropped:** wheel-routing and SwiftUI-freeze assertions that test seams the single web view removes.

## 6. Risks and stop rules

| Risk | How to notice early | Stop rule |
|---|---|---|
| The Rust frontend steals or loses leases against the Swift frontend's update handover | S2 test: force a Swift update (`--update-now`) while one session is held by Rust | If Swift takes the session back, fix the Swift restore list to skip sessions it no longer holds (small Swift change) before S4 |
| Throttled hidden or occluded windows make the page lag or miss patches (5 to 13 windows, most in the background) | Trace each window's applied revision against the worker's revision; alert on a gap over 2 s | If background windows lag, apply patches without rAF and use `inactiveSchedulingPolicy`/occlusion settings; if still lagging, stop S4 |
| Memory: 13 WebContent processes | S4 measurement (frontend + WebContent RSS) | If the total exceeds roughly 2x the Swift 0.31 GB frontend figure with 13 windows (estimate of an acceptable bound), profile DOM size and row paging before adding features |
| Long threads are slow in the DOM | `vcx-pagetest --fixture 5000-rows`: first paint and p95 patch apply | Over 100 ms p95 per patch (estimate budget) means build the virtual list before S4 |
| Composer IME or paste regressions (he types French: dead keys) | S3 IME pagetest plus a day of real typing | Any lost or doubled character blocks S4 |
| Provider schema drift during the port | Golden fixtures re-recorded weekly; diffs reviewed | A drift that the `Item::Other` fallback cannot display blocks that provider's Rust worker, and Swift keeps it |
| Template hot reload breaks every window at once | Last-good fallback test in S5 | No hot reload into real windows before the fallback test passes |
| Two codebases maintained too long, so Swift fixes are needed during the port | Count Swift commits per week after S4 | Freeze Swift features at S2; only fixes land in Swift |
| Scope creep: rebuilding "better" before parity | Every slice has its proof command | A slice whose proof does not pass is not followed by the next one |

**Effort total (estimate):** S0 to S5, the usable Rust frontend, take about 20 to 31 working days. S6 to S8, the Rust workers for all four providers plus swap and retirement, take about 22 to 35 more. That is roughly 2 to 3.5 months for one developer with agents. The first slice he can use every day (S4) lands after about 4 to 6 weeks.
