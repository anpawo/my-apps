# Round 2, cross-examination

Five other models answered the same brief blind (you were one of the six). Below is the list of points where the six answers differ, with each position, and what was measured on the Mac since round 1.

For each disputed point D1 to D14 and each claim C1 to C7: say VERIFIED, REFUTED or UNDECIDED, with newly read evidence (a source URL and the date read, a line of code, or one of the measurements M1 to M7), in at most four lines per point. Attack your own round-1 claims first: name each one you now think wrong. A change of position counts only with new evidence; if you give in without any, say "yielded". Where a measurement M1 to M7 contradicts or settles a point, say so. End with your final recommendation for D1, D2, D3, D4, D6, D7, D8 and D11 in one line each, and the one read or measurement that would settle each point still open.

Do not read any file in this folder or its parent other than the ones this message names (the other agents' answers land here too). Answer in plain prose for another agent: no ⟶ lines, no Done line, no Next line.

---

# Round 2: where the six round-1 answers differ

Legs: Claude (Opus), Codex (gpt-6.2-sol), Muse (web), Grok (web), Qwen (qwen3.5-9b-abl), Gemini (web).

## Measured on this Mac since round 1 (25/11/2026, commit `9ffebd9`, `vcx/rust`)

A first slice was built while round 1 ran. These are observations, not opinions:

- M1. A Rust tao 0.38 + wry 0.58.1 shell attaches to an unmodified Swift worker over v1 (`hello`, `attach`,
  `perform send`, `session/update` patches, `detach`), follows a turn of a fixture agent from prompt to answer and
  draws it. `cargo test -p vcx-shell --test windowless`: 3 passed in 3.17 s.
- M2. The check window is built with `WindowBuilder::with_visible(false)`, `ActivationPolicy::Accessory`,
  `set_activate_ignoring_other_apps(false)` and wry `BackgroundThrottlingPolicy::Disabled`. In it the page loads from
  a custom protocol (`vcx://template/…`), runs its script, lays out (non-zero row boxes inside a 980×720 viewport),
  answers `window.ipc.postMessage`, answers `evaluate_script_with_callback`, and
  `takeSnapshotWithConfiguration:completionHandler:` (objc2-web-kit) returns a 1960×1440 picture of the real page.
- M3. In that window `document.visibilityState` is `hidden`, and CSS animations and transitions do not advance: rows
  with a 240 ms entrance animation stayed at opacity 0 in the picture until the check called `finish()` on every
  finite animation. The page applies each message synchronously and acknowledges it by serial; nothing waits on
  `requestAnimationFrame`.
- M4. Attaching to a session takes its lease, and the Swift frontend closes its window of that session
  (`session/leaseLost`). It does not reopen it by itself when the Rust window closes.
- M5. The frontend uses no async runtime: tao owns the main thread, three std threads (session replica, worker link,
  template watcher) talk through channels and `EventLoopProxy`. 26 unit tests, no tokio in the dependency tree.
- M6. Markdown is rendered with pulldown-cmark 0.13 events; raw HTML events are emitted as escaped text, link and
  image addresses are limited by scheme. No ammonia. The page CSP is `default-src 'none'; script-src 'self' vcx:;
  style-src 'self' vcx:; img-src 'self' vcx: data:`.
- M7. A template whose page does not post `ready` within 3 s, or posts another contract number, is replaced by the
  last template whose page was ready (the built-in one is compiled in); proven by a windowless test.

- M8 (commit `7b0f1cf`, after the list was first sent). Live template edits in the unshown window: an edit of
  `style.css` changes the page's computed background with no page load; an edit of `app.js` loads the page again and
  the session is drawn again; an `app.js` that throws gives way, after the 3 s wait, to the page before it with a
  notice. One windowless test, 3.9 s.
- M9 (commit `95cbc88`). Real input in the unshown window: `NSEvent` key down and up events sent with
  `-[NSWindow sendEvent:]` after `makeFirstResponder(webView)` and a page-side `input.focus()` put 23 characters in
  the page's textarea in order; `mouseDown:` and `mouseUp:` sent to the web view at the send button's centre clicked
  it; the Swift worker ran the turn and the page drew the typed text as the user row. The window was never key,
  never shown. Letters, digits and the space only; no modifier, no IME, no paste.

Not measured yet: IME and marked text, ⌘ shortcuts and paste, a 5,000-row thread, chart iframes, several windows,
memory.

## Disputed points

| # | Point | Positions in round 1 |
|---|---|---|
| D1 | Which end is ported first | Frontend first against Swift workers: Codex, Claude (after typed v1 wire + conformance suite), Muse, Gemini. Rust worker first under the Swift frontend, frontend third: Grok. Rust runtime core first, a Rust server that Swift workers connect to through a `--runtime-url` setting: Qwen. |
| D2 | Composer | Native `NSTextView` over the web view through objc2: Codex, Muse (slice 3, temporary textarea before), Grok. In the page: Claude (textarea + chip strip, IME proven by a page test), Gemini (contenteditable with atomic chips, CodeMirror 6 as fallback; says a native view over `WKWebView` clips popovers and jitters), Qwen (in page, native only if required). |
| D3 | A Rust worker adopting a running agent from a Swift worker (pid, fds, unread bytes) | Never, reopen cold from the provider's history: Codex, Claude, Gemini. Cold first, live takeover optional later: Muse. Optional if a measurement shows it reliable: Grok. Yes, hot swap with a cold fallback, under 1 % session loss: Qwen. |
| D4 | Where Markdown becomes HTML | In the frontend's Rust core, cached there: Codex, Claude, and the build (M6). In the worker, sent once per item in a v2 patch: Muse. Gemini says both (a frontend LRU cache and v2 patches carrying pre-rendered HTML). |
| D5 | Protocol v2 | Only once both ends are Rust: Codex, Claude (item deltas such as `appendText`), Grok. Negotiated in `hello` during the move, Swift staying on v1: Muse (slice 5), Gemini (optional MessagePack or length-prefixed frames). A header with a version and a type byte added in slice 3: Qwen. |
| D6 | Frontend concurrency | A tokio runtime on a background thread: Codex, Claude, Gemini, Qwen. Plain threads + channels + `EventLoopProxy`, tokio only in the worker: Muse, and the build (M5). Grok: tokio in the worker, "channels" in the frontend. |
| D7 | HTML sanitizer | pulldown-cmark + ammonia: Codex, Claude, Gemini. The build escapes raw HTML at the event level and has no sanitizer (M6). |
| D8 | Long threads | Virtual list from the first transcript slice: Muse, Grok, Gemini, Qwen, Codex (anchoring tests). `content-visibility: auto` + paged older rows first, a virtual list only if a 5,000-row page test misses its budget: Claude. |
| D9 | The unshown check window | `with_visible(false)` + activation policy: Claude, Gemini, Grok, Qwen (plus an off-screen position), Codex (and wry built as a child view). Off-screen `orderBack` with private occlusion settings: Muse. Gemini adds `NSProcessInfo.beginActivity` against App Nap, an Edit menu so that ⌘C/⌘V reach the view, and `layoutSubtreeIfNeeded` before a snapshot. M2 and M3 are what `with_visible(false)` gave. |
| D10 | Synthetic input in that window | `NSEvent` mouse and key events sent to the web view, plus `NSTextInputClient` calls for IME: Codex, Claude, Gemini. M9 is the first run of it on a wry view that was never shown. |
| D11 | Worker binary | Its own `vcx-worker` binary with its own build hash, so frontend pushes never restart workers: Claude. One binary run with `--runtime-worker`: Gemini, Grok, Muse. |
| D12 | First provider of the Rust worker | Codex (the others are already adapted to its event shape): Codex. Claude (most used): Claude. All four in one slice: Muse, Gemini, Qwen. |
| D13 | Coexistence | A second app with its own bundle id (all frontend-first legs). Its own config, cache, Fleet namespace and runtime home: Codex. Shared `~/.local/state/vcx` and `settings.json`, "closing it lets Swift re-attach seamlessly": Gemini (M4 contradicts the last part). Never installed at the Swift app's path, never writing Swift's update markers: Claude. |
| D14 | Effort for the whole move, one developer with AI agents | Gemini 19 to 26 days. Codex 36 to 58 days. Claude 42 to 66 days. Grok 10 to 14 weeks. Qwen about 15 weeks. Muse 18 to 25 weeks. |

## Claims made by one leg only, to verify or refute

- C1 (Gemini): without a native Edit menu, ⌘C/⌘V/⌘A do not reach a `WKWebView` in a tao app.
- C2 (Gemini): an unshown window without an explicit inner size gives a 0×0 web view and an empty snapshot.
- C3 (Gemini): sandboxed chart iframes may not work under a custom scheme origin; fallback is a loopback HTTP server
  with a per-launch token.
- C4 (Claude): a Swift frontend update can take sessions back from the Rust app (its replacement attaches to every
  worker it knows).
- C5 (Claude): WebKit marks a page hidden when its window is occluded, and only the private
  `_setWindowOcclusionDetectionEnabled:` keeps it visible (WebKit bug 331092).
- C6 (Qwen): Swift workers can be pointed at a Rust server with a `--runtime-url` flag. The brief describes no such
  flag: in v1 the worker is the server and the frontend the client.
- C7 (Muse): three weak sources (chatoverflow.dev, unstuckagents.com, asyar.org) back its private occlusion settings.
