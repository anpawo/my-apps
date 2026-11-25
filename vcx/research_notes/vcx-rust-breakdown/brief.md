# Brief: how to break Vibe Code X's Swift app apart and rebuild it better in Rust (tao + wry)

You are one of several independent AI reviewers answering the same brief blind. Read it whole, then answer the
questions at the end. Each factual claim about a library, an API or a measurement carries its source URL and the
date you read it; an estimate is marked "estimate". Answer in English.

## Decided, not to be argued again

The owner decided on 25/11/2026, after a five-model review the same day:

- VCX is rebuilt in Rust. The shell is tao (windows, events) + wry (system `WKWebView`), not Tauri, Dioxus,
  Blitz or GPUI. One web view per session window, one WebContent process per window.
- The display is an HTML/CSS/JS template folder loaded from disk and hot-reloaded in every open window, behind a
  versioned data contract, with a last-good fallback when an edit is broken.
- Markdown is parsed and sanitized in the Rust core, not in the page. Agent "chart" blocks (free-form HTML/JS
  pages) run in sandboxed iframes; their `vcx.live(url, seconds, cb)` polling goes through the core with an
  allowlist.
- macOS only (Apple silicon, macOS 26), single user, built without Xcode (Command Line Tools), installed as a
  signed `.app` in ~/Applications. No paid services.
- Building starts today. The earlier review advised a web transcript inside the Swift app first; the owner has
  chosen to start the Rust + tao + wry build now instead. This brief is about how to cut the Swift app apart
  and in which order to rebuild the pieces, not about whether to.

## What VCX is

A personal native macOS app that gives coding agents a chat window, one window per agent session, used all day
with 5 to 13 windows open. It drives the agents' own command-line tools: `claude -p` in stream-json mode,
`codex app-server` (JSON-RPC over stdio), a local Qwen model through Ollama's HTTP chat API, `agy` (Antigravity
CLI). Display features: streaming Markdown transcript (tables, code, images, file links), tool calls folded into
one collapsible block per answer, thought bubbles, debate rows between models, question cards that replace the
input box, find bar, thousands of rows per thread; a composer with image and long-paste chips and a `/` command
palette; "chart" blocks (HTML pages rendered inline, pinnable); a right-hand task bar; a status bar with
provider quotas, update and progress chips; a sidebar of hooks, skills and MCP servers; every window reports
its state to a separate menu-bar app (Fleet) through small files.

## The Swift code today (read 25/11/2026, `wc -l`, one SwiftPM target, 22,397 lines in 65 files)

| Part | Lines | Files | What it does |
|---|---|---|---|
| Self-checks | 7,668 | 19 `*Check.swift` | Headless checks run by flags of the same binary: offscreen renders, real mouse and key events routed into unshown windows, runtime protocol, live update, archive safety |
| Display | 5,996 | `Views` 2,188, `Transcript` 674, `Composer` 640, `Chart` 475, `main` 798, `Find`, `Run`, `TaskBoard`, `QuotaOverview`, `Demo`, others | SwiftUI + AppKit: transcript is an `NSScrollView` of cells hosting SwiftUI rows, composer is an `NSTextView` subclass with attachment chips, charts are one `WKWebView` per block |
| Session model | 4,285 | `Session` 2,305, `Commands` 548, `Settings`, `StateHome`, `Trace`, `ErrorsRank`, `Directory`, others | One `Session` class per conversation: rows and items, turn state machine, queueing of prompts, question flows, permissions, commands, usage and quota, thread switching, archive, Fleet presence |
| Agent connections | 2,389 | `Agents` 1,023 (Claude and Qwen), `RPC` 250 (Codex), `Agy` 288, `Capabilities` 320, `Messages`, `ProviderJSONReader`, `ClaudeCompatibility`, `ModelControl` | A `Connection` protocol (`start`, `request(method, params)`, `respond`, `reject`, `close`, an `event` callback of untyped JSON); each provider adapts its CLI to Codex-app-server-shaped events |
| Runtime (processes) | 2,059 | `RuntimeTransport` 282, `RuntimeServer` 385, `RuntimeClient` 404, `RuntimeSession` 320, `RuntimeSwap` 209, `RuntimeUpdate` 172, `RuntimeRecovery` 199, `NativeThreadLease` 88 | The frontend/worker split described below |

Plus 3,069 lines of Python (installer, auto-update job, archive and cleanup helpers, test peers).

The session model is not display-free: `Session.swift` imports AppKit and SwiftUI and holds the draft as an
`NSAttributedString` (28 uses) whose attachments are the image, paste and command chips; rows and items are
`ObservableObject`s. All state is untyped `[String: Any]` JSON; an item is a dictionary whose `type` is one of
`commandExecution`, `fileChange`, `mcpToolCall`, `dynamicToolCall`, `webSearch`, `peerMessage`, `reasoning`,
agent or user message; a row has `id`, `kind` (`user`, `peer`, `assistant`, `notice`, `activity`, `debate`) and
items.

### Process model and wire protocol

- One frontend process owns every window. Each session lives in its own runtime worker process (the same
  binary with `--runtime-worker`), which owns the `Session` and the agent CLI child. Measured today: frontend
  0.31 GB with 13 windows, 7 workers 0.11 GB together.
- They talk over a Unix stream socket per session in a private `0700` folder
  (`~/.local/state/vcx/runtime/v<swap version>-<hash of session id>.sock`); peers are checked with
  `getpeereid`. Frames are one JSON object per line (sorted keys), at most 32 MB a frame, 64 MB buffered, with
  back-pressure.
- Requests `{id, method, params}`, replies `{id, result}` or an error with a `code`. Methods: `hello`
  (`protocol: 1`, returns build hash, instance id, pid, limits), `attach` (session UUID + cwd; returns a
  `lease`, a `revision`, `lastSequence` and the full `state` snapshot: metadata, rows with items, draft pieces,
  window state), `perform` (lease, strictly increasing `sequence`, `action`, `params`; idempotent through
  per-sequence receipts and a fingerprint), `detach`, `list`. Actions: `send`, `sendNow`, `unsend`, `stop`,
  `answer`, `command`, `setModel`, `moveDirectory`, `switchThread`, `checkpoint`, `refreshCatalog`,
  `refreshUsage`, `refreshRepository`, `refreshCapabilities`, `close`.
- Notifications from the worker: `session/update` (`revision`, a `patch` batched every 80 ms: `meta`,
  `rowOrder`, `rowUpdates` with item ids, changed `items`, `draft`), `session/leaseLost` (another frontend
  attached), `runtime/swapping`.
- Live update: an auto-update job builds each push to main. The frontend is replaced by a new process that
  attaches to the same workers (the old windows hand over their leases); a worker later swaps itself onto the
  new binary while idle, keeping the agent child and its pipes (`freezeForSwap` returns pid, file descriptors
  and unread bytes; the new image adopts them). A worker that cannot move keeps its sessions on the old build.
- Recovery: each worker checkpoints its session state to disk so a crashed worker's session can be reopened
  cold from the provider's own history.
- Settings live in `~/Library/Application Support/VCX/settings.json`, state in `~/.local/state/vcx`.

### Verification constraint

Nothing may open a visible window on the owner's desktop to check something. Today every UI check renders
offscreen or routes events into unshown windows. The Rust app needs the same: a windowless way to render the
page, read the DOM, take a picture and send key and mouse input.

## Questions

1. **Where to cut.** Propose the Rust workspace: crates, the responsibility of each, and which Swift files each
   replaces. Which of today's boundaries are right and should be kept (the frontend/worker socket protocol? the
   `Connection` abstraction that makes every provider look like Codex app-server?), and which are wrong and
   should be redrawn (the 2,305-line `Session`, untyped JSON everywhere, the draft as an attributed string,
   checks compiled into the app binary)?
2. **Port order.** The existing socket protocol lets a new frontend attach to today's Swift workers, and lets
   today's Swift frontend attach to a new worker. Which end goes first: the tao + wry frontend against Swift
   workers, Rust workers under the Swift frontend, or a shared Rust core library first? Give the slices in
   order, each usable on its own, each with the command or measurement that proves it works, and say how the
   Swift and Rust builds coexist on one Mac during the move (two apps, a setting, per window?) without risking
   the sessions he is working in. Can a Rust worker take over a running agent from a Swift worker through the
   existing swap state (pid, file descriptors, unread bytes), and is that worth doing?
3. **What to rebuild better, concretely.** Protocol (keep v1 line-JSON as is, or a typed v2: what changes and
   why), the state model (typed rows and items against passthrough JSON from four providers whose schemas
   move), how state reaches the page (full snapshot, patches, per-frame batching, virtual list, where Markdown
   HTML is cached), concurrency (tokio or plain threads, and how it meets tao's main-thread event loop), the
   template data contract and its versioning, the composer (in the page or a native `NSTextView` over the web
   view through objc2: IME, marked text, chips, paste), and live update in a Rust world.
4. **What not to port.** Name what should be dropped, merged or left in Swift or Python, and what must stay
   native through objc2 even in the Rust shell.
5. **Windowless verification with tao + wry.** How to load, drive and capture a wry web view without showing a
   window on macOS 26: hidden tao window or no window at all, `evaluate_script` for DOM reads,
   `WKWebView.takeSnapshot` through wry's raw handle, synthetic input. Name the known traps (timer and
   `requestAnimationFrame` throttling in hidden or occluded views, activation policy, the Dock icon) with
   sources. How do the 7,668 lines of Swift checks carry over: which become Rust unit tests, which become
   protocol conformance tests run against both the Swift and the Rust implementation, which become page tests?
6. **Risks and stop rules.** What is most likely to go wrong in this order of work, how to notice early, and
   the effort per slice (estimate, one developer working with AI agents).

Answer with: your recommendation in 5 lines first; then the workspace table (crate, responsibility, Swift files
replaced); then the slices in order, each with its proof; then questions 3 to 6.
