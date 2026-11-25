# Round 2: points where the five answers differ

Legs: A = Claude, B = Codex, C = Muse, D = Grok, E = Qwen (local 9B model, could not browse).

1. Process sharing between windows. C and D: web views that share one `WKWebsiteDataStore` share one WebContent
   process (C cites a dev.to post, and a research note that marks the claim unverified). A and B: Apple's rule is
   "each web view is given its own Web Content process until an implementation-defined process limit"; a shared
   store or origin gives no public guarantee of sharing; only related views (a page's `window.open` answered with
   the configuration WebKit supplies) share. A measured 1 page + 7 `window.open` popups at 194 MB total against
   about 400 MB for 8 separate views (Playwright WebKit, synthetic). Which is true on macOS 26 system WebKit?
2. Default process layout. A: one process per window by default (a runaway chart freezes one window), related
   views only after a watchdog exists. B: budget one process per view, treat any sharing as a measured bonus.
   C and D: aim for one shared process for all chat windows. E: "one or two global contexts" through Tauri.
3. RAM for 8 windows. A: 300 to 400 MB related, 490 to 940 MB separate. B: 460 to 1,080 MB. C: 400 to 550 MB.
   D: 350 to 800 MB (wry), 400 to 900 MB (Tauri). E: 350 to 400 MB, elsewhere 750 MB, and "SwiftUI today 1.8 GB
   projected" against the measured 253 MB for 7 windows. All estimates; only A's 194 MB / 49 MB are measured,
   on a synthetic transcript.
4. Stop threshold. A: stop above 600 MB for 8 windows. C: stop if no shared process and above 700 MB. B: stop if
   more than 10 % worse than today's frontend footprint and energy. D: stop above 1.2 to 1.5 GB.
5. Final shell. A and C: wry + tao, no Tauri. D: wry/tao or a minimal Tauri. E: Tauri 2 (claims Tauri has a
   built-in file watcher via `tauri-plugin-fs` and a `headless-ui-test` crate). B: keep a thin AppKit host; move
   it to Rust only if that cuts maintenance after the core and workers are ported.
6. Tauri headless testing on macOS. C: `tauri-driver` is Windows/Linux only, no WebDriver for WKWebView. A and B:
   current Tauri docs describe a macOS route through an embedded WebDriver (WebdriverIO service), still unproven
   windowless. Which is right on 25/11/2026?
7. Composer. B: keep the native AppKit composer until web input (IME, marked text, shortcuts, paste, attachments)
   is proven equal. A: move composer, palette, question cards, find, task bar into the page in step 2. C: keep the
   Swift composer in step 1, a page textarea later. D: move transcript and composer into one web view at step 0.
8. Markdown. A, B, C: parse and sanitize in Rust (pulldown-cmark or comrak), no raw agent HTML in the DOM.
   D: JS side is fine, Rust optional. E: JS side (`marked.js`).
9. Order of migration. A: web transcript in Swift, whole window web, Rust workers, Rust core + wry shell.
   B: web transcript in Swift, template + charts, Rust model and workers, host maybe. C: a 3 to 5 day wry spike
   first, then web transcript in Swift, Rust core, Rust shell. D: web transcript in Swift, then a Rust frontend
   shell, workers in Rust optional and late. E: hybrid, Rust core, full Tauri.
10. Who applies a template edit. C: agents write only drafts; the owner approves each before it goes live.
    A and B: any edit goes live automatically after a staged offscreen test render, with last-good rollback.
    D: live edits after validation, plus a safe mode.
11. `vcx.live` and chart frames. A, B, C: frames have an opaque origin and no bridge; polling is brokered by the
    core with an allowlist (A notes today's bridge accepts localhost). E: plain `fetch` from inside the chart
    iframe, no bridge. Is that possible with a sandboxed opaque-origin frame and without CORS?
12. Chart library. B and C: vendor a pinned lightweight-charts build (offline, attribution). E: "official
    Lightweight Charts iframe widget". Today it loads from a CDN.
13. GPUI. B: credible native renderer in production in Zed, with marked-text input APIs and AccessKit work.
    C: 0.2.2 (Oct 2025) still latest in July 2026, no first-party text input, AccessKit unreleased/disabled.
    D: maturity "high". All agree it loses agent HTML charts.
14. Effort. A: 11 to 16 developer-weeks. B: 9 to 16 (+2 to 4 for a Rust host). C: 14 to 20. D: 6 to 12. E: 8 to 12.
15. One shared WKWebView with tabs. B: an optional low-memory mode. A, C, D: no, keep one window per session.
