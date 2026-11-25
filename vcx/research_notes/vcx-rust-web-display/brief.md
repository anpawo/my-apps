# Brief: should Vibe Code X move to Rust with a web display, and how

You are one of several independent AI reviewers answering the same brief blind. Read it whole, then answer the
questions at the end. Each factual claim about a library, engine or measurement carries its source URL and the
date you read it; an estimate is marked "estimate". Answer in English.

## What Vibe Code X (VCX) is today

VCX is a personal, single-user native macOS app (Apple silicon, macOS 26 "Tahoe"; macOS only, no Windows or
Linux target planned) that gives coding agents a chat window: one window per agent session. It drives the agents'
own command-line tools rather than their APIs: `claude -p` in stream-json mode (Claude Code), `codex app-server`
(OpenAI Codex, JSON-RPC over stdio), a local Qwen model through Ollama's HTTP chat API, and a few web chat sites
through a headless browser for research debates. So the agents' hooks, skills, MCP servers and instruction
files apply as they would in a terminal. Its owner uses it all day as his main interface to agents, with
typically 5 to 10 windows open at once.

Features the display must keep:
- A streaming chat transcript: user prompts, agent text in Markdown (headings, tables, code blocks with
  monospaced text, images, links that open local files), tool calls folded into one collapsible block per answer
  that counts actions as they run, "thought" bubbles, debate rows between several models, question cards that
  replace the input box (a number key picks an option), a find bar with highlighted matches, and long
  transcripts (thousands of rows) that must scroll smoothly.
- A composer (input box) with image and long-paste chips, a command palette (`/model` switches provider, model
  and effort), keyboard-first use.
- "chart" blocks: the agent writes a fenced block holding one self-contained HTML page; VCX renders it live
  inline. A helper `vcx.chart({...})` draws price or time series with TradingView lightweight-charts (loaded
  from a CDN), tables and headline cards; other charts are free-form HTML/SVG/JS written by the agent in each
  reply. Blocks can be pinned above the chat and expanded. A `vcx.live(url, seconds, cb)` bridge lets a page poll
  a URL through the app (no CORS).
- A right-hand task bar listing every session's task on the same project, a status bar (provider usage quotas,
  update progress, a progress line any agent can drive by writing a file), a sidebar of hooks/skills/MCP servers.
- Each window reports its state to a separate menu-bar dashboard app (Fleet).

Architecture today:
- About 22,100 lines of Swift in one target (64 files; about 7,500 of them are headless self-checks) plus about
  3,000 lines of Python (installer, update and helper scripts). SwiftUI with AppKit pieces: the transcript is a
  SwiftUI `LazyVStack`, text runs in custom `NSTextView` subclasses and CoreText measuring; chart blocks and
  Markdown tables/images are `WKWebView`s (the system WebKit), created per block.
- Process model: one "frontend" process owns all windows; each agent session lives in its own "runtime worker"
  process that owns the agent CLI child process, so the frontend can be replaced by a new build without killing
  agents ("live update": an auto-update job builds each push to main and every open window moves to the new
  build once its turn ends; workers swap later). Frontend and workers talk over a local socket RPC.
- Built without Xcode (Command Line Tools and SwiftPM only), installed as a signed `.app` in ~/Applications.
- It is verified without ever opening a window on the owner's desktop: offscreen renders (`--render`,
  `--render-demo` for the README GIF), headless interaction checks that route real mouse/key events into
  unshown windows, and about 7,500 lines of self-checks. Any new stack must keep a windowless way to render and
  test the UI.

Measured on this Mac (25/11/2026, `footprint` / `top`): the frontend process with 7 windows open uses 253 MB
physical footprint (peak 305 MB); each runtime worker uses 11 to 22 MB. On 19/11/2026: VCX frontend 227 MB;
the owner's other app "One Text" (Tauri 2: Rust + system WKWebView) used about 480 MB in total: 76 MB app
process, 315 MB WebKit WebContent process, 83 MB WebKit GPU process, 7 MB WebKit networking process. CPU at
rest is near 0 %; the hard part is streaming and scrolling long transcripts without dropped frames.

Known pain points that motivate a change: every display tweak (spacing of a bubble, a color, a new block
kind) needs a Swift rebuild and reinstall, minutes through a shared build queue (estimate); SwiftUI layout bugs
in long transcripts and with WKWebView blocks inside a SwiftUI scroll view (focus theft from the composer,
wheel events scrolling the chat behind an expanded block, pinned blocks not fitting their content); SwiftUI
rendering of very long chats needed many hand optimizations.

## What the owner wants

1. Move VCX to Rust with a web display ("some Rust with the web display"), as discussed earlier, while
   keeping its optimized rendering and keeping resource use and cost low (RAM, CPU, battery; no paid
   services; no Electron-sized footprint).
2. His new idea (25/11): the chat display is an HTML/CSS/JS template loaded from disk and hot-reloaded, so a
   change to how the chat looks shows at once in every open window, with no VCX binary rebuild or reinstall.
   Agents (or he) could then restyle or extend the display live.
3. Every visible change animates (spring or ease-out of 200 to 350 ms, never a jump; growing content is
   revealed with its container), and Reduce Motion turns it into a short fade.

What was concluded before (19/11/2026, an earlier discussion plus a five-model council):
- A webview does not save RAM by itself: the system WebKit brings 3 helper processes (One Text: ~400 MB of its
  480 MB). Lighter HTML/CSS engines exist (Blitz / Dioxus Native: pure Rust, no JS engine; Sciter: small, closed
  source; Ultralight: WebKit-based, proprietary) and native Rust UI kits (GPUI from Zed, Slint, iced, egui), all
  unmeasured on this Mac.
- Free-form agent charts need a JS engine; a JS-free display would require a data-only chart spec
  (`{v, kind, data, x, y, title}`) drawn by the app, with a static SVG fallback, and a one-time conversion of
  old threads' HTML chart blocks to frozen images. The council said: ship that spec first in today's Swift VCX,
  and start a Rust rewrite only after a spike proves a real RAM saving on the same thread.
- The owner has since decided he wants the Rust + web display direction; this review is about how to do it
  well, not whether to stay on Swift forever. Saying "do not do it" is allowed only with measured evidence.

## Questions to answer

1. Stack. Compare at least: Tauri 2 (Rust + system WKWebView), wry/tao directly without Tauri, a Swift or Rust
   shell around one shared WKWebView, Dioxus (desktop on WebKit, or Native/Blitz), GPUI, and any other
   Electron-free option you consider serious. For each: resident RAM for one and for 8 windows (one WebKit
   content process per window, or one shared?), streaming and scrolling performance on a 5,000-row transcript,
   maturity on macOS in late 2026, how it renders and tests headlessly (no visible window), and how it handles
   keyboard focus, IME, text selection and accessibility. Recommend one.
2. Windows and processes. Many windows: one webview per window, or one process hosting all, or a single window
   with tabs? How do WebKit processes get shared between webviews in one app (process pool, related views), and
   what does that do to RAM? Keep or change the frontend/worker split and live update?
3. Rendering and streaming design: how tokens flow from the Rust core into the page (IPC channel, batching per
   animation frame, virtualized list, DOM recycling), how Markdown is rendered (Rust side or JS side), how to
   keep long transcripts fast and memory flat, how charts fit in (iframes? sandboxing? the data-only spec?).
4. The hot-reload template: how to structure it (one HTML/CSS/JS bundle in a watched folder; versioned; a
   stable data contract between the Rust core and the template), how to reload without losing scroll position,
   selection or composer text, how to fall back when an edited template is broken, and how to keep agents from
   breaking his main tool with a bad edit (validation, last-good copy, a test render before applying). Security:
   the template and chart pages must not be able to run arbitrary local commands through the IPC bridge.
5. Migration path in shippable steps, each usable on its own (for example: first only the transcript view
   becomes a web view inside the current Swift app, then the core moves to Rust, or the reverse), with what to
   measure at each step and what would make you stop. What to keep in Swift, if anything (menu-bar, global
   hotkeys, TCC permissions, signing without Xcode).
6. Risks and costs: RAM, energy, input latency, IME/accessibility regressions, the rewrite's size (estimate
   weeks of one developer working with AI agents), and how to keep the 7,500 lines of checks' value.

Answer with: your recommendation first in 5 lines, then each question in order, then a table of the options
with your numbers (each with source and date, or marked estimate).
