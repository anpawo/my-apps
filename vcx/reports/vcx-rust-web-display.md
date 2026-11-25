# VCX to Rust with a web display: deep review, 25/11/2026

Research only: nothing was built or changed in VCX. Brief, answers and round-2 cross-checks:
[research_notes/vcx-rust-web-display](../research_notes/vcx-rust-web-display/).

## Answer

All five legs that answered agree on the direction (Rust core, system WebKit display, hot-reloaded template) and,
after round 2, on most of the design. Recommended:

- **Stack.** System WebKit (`WKWebView`), one per session window, owned by a thin native host. The final Rust shell
  is wry + tao (Claude, Muse, Grok), not Tauri (only Qwen kept Tauri) and not Blitz, Dioxus Native or GPUI, which
  cannot run the agents' free-form HTML/JS charts. Codex dissents only on timing: keep the thin AppKit host and
  move it to Rust only if that cuts maintenance once core and workers are ported.
- **Migration path, each step shippable.**
  1. Step 0, 3 to 5 days (estimate): one window's transcript drawn by a `WKWebView` from a template folder in
     today's Swift app, behind a setting, virtualized, on a real long thread; measure 1 and 8 windows (host +
     every attributed WebKit helper, read during normal use), scroll frames and key-to-paint. No separate wry
     spike: the process question is already answered on the system WebKit (see Evidence).
  2. Web transcript in Swift (2 to 4 weeks): template folder, versioned data contract, hot reload gated by an
     offscreen test render with last-good and built-in fallbacks, Markdown parsed and sanitized in the core,
     charts in sandboxed iframes, `vcx.live` brokered by the core. The native composer stays.
  3. Rest of the window web (composer, palette, cards, find, task bar) only after IME, marked text, shortcuts,
     paste and attachments are measured equal to the native composer.
  4. Rust workers behind the existing socket protocol, then the Rust core, then the wry + tao shell.
     Codex: the Rust port need not wait for step 3; the rest of the window can stay native meanwhile.
- **Main risks.**
  - RAM: no saving expected. One WebContent process per window by default; 8 windows estimated at 350 to 650 MB
    separate, 230 to 450 MB related (Claude, from its system-WebKit measurement). Today's 253 MB counts 7 windows
    and the frontend PID only; the matched baseline (today's VCX on the same 8 threads, its chart-block WebKit
    processes and helpers counted) is still unread. Related views save about 125 MB (synthetic) but one looping
    chart then freezes every window.
  - Input and accessibility parity (IME, focus, VoiceOver, wheel routing over charts) is the long, expensive tail.
  - Effort: 10 to 16 developer-weeks with agents for most legs (Muse 14 to 20; all estimates); step 0 and the
    web transcript alone give the visible wins (hot reload, no SwiftUI layout bugs) in about 3 to 5 weeks.
- **Stop rule.** Stop the default switch above 600 MB total for 8 windows on real threads (Claude, Muse) or on a
  more than 10 % energy regression (all but Qwen). Codex also wants a 10 % RAM limit; Claude measured that the
  WebKit side alone already takes 277 MB for 8 separate windows, so that rule would end the project by
  construction and stays a target (Codex still dissents: keep the 10 % RAM gate against a matched baseline, 600 MB
  only as an outer ceiling). Qwen alone would accept up to 1 GB.

## Evidence

- **Process sharing (the point that moved most).** Apple: "each web view is given its own Web Content process
  until an implementation-defined process limit is reached"; `WKProcessPool` has had no effect since macOS 12.
  WebKit source for the macOS 26 build (WebKit-7624.5.1.11.3, `WebProcessPool.cpp` L1270 to L1367) creates
  ordinary views with `IsSharedProcess::No`; the data store is only a compatibility check; related pages (a
  page's `window.open` answered with the configuration WebKit supplies) have their own reuse path, the only
  public way to share; a private `usesSingleWebProcess` mode and idle or prewarmed process reuse also exist. Muse and Grok
  had claimed that a shared `WKWebsiteDataStore` shares one process (from a dev.to post); both read the source and
  withdrew it. Claude then measured it on this Mac's system WebKit (21624.5.1.11.3, the same version as that tag),
  windowless, synthetic 5,000-row pages, `footprint` of the host and every attributed WebKit process:
  - 8 views, separate configurations: 8 WebContent processes, 300 MB total (two runs).
  - 8 views sharing one configuration and one data store: still 8 processes, 299 MB.
  - 1 opener + 7 `window.open` related views: 1 process, 175 MB total; still 1 after `reload()` on all 8.
  - 8 related views as a full DOM (no virtualization): 1.63 GB.
  - A sandboxed `srcdoc` chart iframe looping forever in view 1: with related views, view 8 did not answer within
    5 s; with separate views it answered at once. Chart iframes run in their page's process.
  - A bare AppKit + WebKit host costs 17 to 23 MB, so a Rust shell buys no RAM, only one language.
- **Claude's round-1 Playwright figures** (49 MB virtualized, 316 MB full DOM, 194 MB for 8 related) ran about
  1.5 times the system WebKit's (32, 223, 133 MB); the ratios hold. None of the figures include on-screen
  windows, images, highlighted code or live charts.
- **One Text (Tauri 2, 19/11):** 480 MB total, of which 315 MB WebContent, 83 MB GPU, 7 MB networking.
- **Tauri on macOS:** standalone `tauri-driver` is Windows and Linux only; WebdriverIO's `@wdio/tauri-service`
  drives a Tauri app on macOS through an embedded WebDriver plugin (https://v2.tauri.app/develop/tests/webdriver/),
  its Apple Silicon CI passed on 10/11/2026, but always with a visible window. No leg showed a windowless route.
- **Charts:** a sandboxed iframe without `allow-same-origin` has an opaque origin, so it can read only
  CORS-enabled responses (Fetch spec); polling any URL needs the core as a broker with an allowlist. TradingView
  Lightweight Charts is a library to vendor offline with its attribution; there is no official iframe widget for
  one's own series.
- **Markdown:** parse in the core (pulldown-cmark or comrak) and drop raw HTML; `pulldown-cmark` emits raw
  `Html` events and `marked` leaves sanitizing to the caller, so either way the filter is explicit work.
- **GPUI:** latest published crate 0.2.2 (Oct 2025), no AccessKit in its manifest; good marked-text example and
  a macOS AccessKit adapter upstream; still no JS for agent charts.
- **Qwen's `headless-ui-test` crate does not exist** (crates.io 404, checked by Codex, Muse and Grok).

## Disputed points

| Point | Claude | Codex | Muse | Grok | Qwen | Outcome | Decided by |
|---|---|---|---|---|---|---|---|
| Shared data store shares a WebContent process | no, only related views | no | yes, then changed with source | yes, then yielded | yes, then yielded | No: 8 views on one store got 8 processes; related views are the only public way to share | Claude's measurement; WebKit-7624.5.1.11.3 `WebProcessPool.cpp` |
| Default process layout | one per window, related after a watchdog | one per window | one shared, then changed | shared, then yielded | pooled, then yielded | One per window; related views only if RAM misses by less than their saving measured on real threads, with a watchdog | hang test: one looping chart froze all 8 related windows |
| RAM, 8 windows | 300 to 400 related, 490 to 940 separate; round 2: 230 to 450 related, 350 to 650 separate | 460 to 1,080, then yielded to Claude's figures | 400 to 550, then raised | 350 to 800 | 350 to 400, then 400 to 900 | Synthetic windowless: 175 related, 300 separate; on-screen real threads unmeasured | Claude's system-WebKit probe |
| Stop threshold | 600 MB, + 10 % energy | +10 % footprint and energy | 700 MB, then +10 % or 600 MB | 1.2 to 1.5 GB, then +10 % or 700 MB | 600 MB, then 1 GB | 600 MB total or +10 % energy; +10 % RAM as a target (Codex dissents, Qwen dissents) | 277 MB WebKit-only for 8 separate views |
| Final shell | wry + tao | thin AppKit host, Rust later if cheaper | wry + tao | wry + tao or thin Tauri | Tauri 2 | wry + tao at the end, AppKit host until then | wry 0.58 exposes the raw `WKWebViewConfiguration` |
| Tauri WebDriver on macOS | embedded route exists | exists, CI passed | none, then yielded | yielded | not addressed | Exists, not windowless | Tauri docs, WebdriverIO CI job 10/11 |
| Composer | into the page in step 2 | native until parity | native in step 1 | into the page at step 0, then yielded | not addressed | Native until IME and input parity is measured | no source settles parity; caution kept |
| Markdown | core | core | core (comrak + ammonia) | JS fine, then yielded | JS (`marked`), then agreed at sign-off | Core, raw HTML escaped | `marked` docs; pulldown-cmark `Event` docs |
| Order | Swift web transcript first | Swift web transcript first | wry spike first, kept in round 2 | Swift web transcript first | hybrid, core, Tauri | Step 0 inside today's Swift app; no wry spike (Muse agreed at sign-off) | Claude's probe answered the process question in Swift; the layout is a `createWebViewWith` answer in Swift and wry alike |
| Who applies a template edit | auto after test render | auto after test render | owner approves drafts, then yielded | auto + safe mode | auto, yielded | Auto after offscreen test render, last-good rollback | `takeSnapshot` works offscreen |
| `vcx.live` from chart frames | broker | broker | broker | broker | plain fetch, then yielded | Broker with allowlist | Fetch spec, HTML sandbox spec |
| Chart library | vendor | vendor | vendor | vendor | TradingView widget, then yielded | Vendor pinned Lightweight Charts | TradingView product comparison |
| GPUI maturity | not for this | credible renderer | 0.2.2, no AccessKit | high, then yielded | not compared | Credible for Zed, wrong fit for VCX | crates.io manifest |
| Effort (weeks) | 11 to 16 | 9 to 16 (+2 to 4) | 14 to 20, kept | 6 to 12, then 10 to 16 | 8 to 12, then 10 to 14 | 10 to 16 for most legs; Muse 14 to 20; all estimates | none |
| One web view with tabs | no | optional mode | no, then fallback | later option | not addressed | Not the default; fallback if related sharing fails | AppKit one superview per view |

"Yielded" means a position changed without a new source of the leg's own; Muse's and Codex's changes on process
sharing and RAM came with sources; Claude's round 2 ran its own measurement.

## Sign-off

| Claim | Claude | Codex | Muse | Grok | Qwen |
|---|---|---|---|---|---|
| 1 WebKit, one view per window | AGREE | AGREE | AGREE | AGREE | AGREE |
| 2 wry + tao last, not Tauri | AGREE | AGREE | AGREE | AGREE | no answer |
| 3 shared store does not share; related views do | DISAGREE on "only" (fixed) | DISAGREE on "only" (fixed) | AGREE | AGREE | DISAGREE, no source |
| 4 one process per window by default | AGREE | DISAGREE: cutoff from real threads (fixed) | AGREE | AGREE | AGREE |
| 5 RAM 350 to 650 separate, 230 to 450 related | AGREE, baseline note (fixed) | DISAGREE: needs a matched 8-window baseline (fixed) | AGREE | AGREE | DISAGREE, no source |
| 6 step 0 in Swift, no wry spike | AGREE | DISAGREE: Rust port need not wait for the rest of the window (recorded) | AGREE | AGREE | AGREE |
| 7 native composer until parity | AGREE | AGREE | AGREE | AGREE | AGREE |
| 8 Markdown in the core | AGREE | AGREE | AGREE | AGREE | AGREE |
| 9 automatic edits after a test render | AGREE | AGREE | AGREE | AGREE | AGREE |
| 10 sandboxed charts, brokered `vcx.live` | AGREE | AGREE | AGREE | AGREE | AGREE |
| 11 stop at 600 MB or +10 % energy | AGREE | DISAGREE: keep the 10 % RAM gate (dissent stands) | AGREE | AGREE | no answer |
| 12 no WebDriver needed | AGREE, `takeSnapshot` without a window untested | AGREE | AGREE | AGREE | AGREE |
| 13 10 to 16 weeks | AGREE (own 11 to 16) | AGREE | AGREE | AGREE | AGREE |

Qwen answered 11 lines for 13 claims without numbers; the mapping above follows their content.

## Roster and failures

| Leg | Route | Round 1 | Round 2 |
|---|---|---|---|
| Claude Opus 5.5 | native agent | answered, measured Playwright WebKit | answered, measured the system WebKit windowless |
| Codex gpt-6.2-sol | `ask-codex.sh` | answered, read VCX sources read-only | answered |
| Muse | web, `ask-muse.sh` | answered | answered |
| Grok | web, `ask-grok.sh` | answered | answered |
| Qwen qwen3.5-9b-abl | local Ollama | answered after a PC wake, no browsing | answered |
| agy | `ask-agy.sh` | failed: quota reached, resets in about 129 h | not run |
| Gemini | web | skipped: out of quota | not run |
| Meta AI | web | not run: same provider as Muse | not run |

Five providers answered, so this is a complete multi-provider result.
