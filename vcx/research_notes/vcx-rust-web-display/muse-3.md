AGREE - system WebKit is the only option that runs free-form agent HTML and JS charts, and Blitz, Dioxus Native and GPUI do not.
AGREE - wry and tao last, only if the AppKit host's maintenance justifies it, after the Rust core and workers are ported, not Tauri.
AGREE - verified in round 2 from the WebKit source and confirmed by A's measurement: sharing a data store gave 8 processes at 299 MB, same as separate configurations at 300 MB.
AGREE - one process per window by default, related views only to recover the measured roughly 125 MB saving, with a hang watchdog because a looping iframe in one related view froze the other seven.
AGREE - on real virtualized threads 350 to 650 MB separate and 230 to 450 MB related are plausible estimates against 253 MB today, so no RAM saving is expected.
AGREE - A's measurement already answers the spike question, so step 0 as a Swift web transcript on a real long thread in 3 to 5 days replaces a separate wry spike.
AGREE - the native composer stays until a web composer passes IME marked text, paste, attachments, shortcuts and VoiceOver checks.
AGREE - Markdown is parsed and sanitized in the core with pulldown-cmark or comrak, raw HTML escaped and link targets validated.
AGREE - template edits go live automatically after an offscreen test render in a separate unrelated view with a hang timeout, with last-good and built-in fallbacks and no per-edit owner approval.
AGREE - charts in sandboxed iframes with an opaque origin and no bridge, vcx.live polling brokered by the core with an allowlist, and Lightweight Charts vendored offline with attribution.
AGREE - stop above 600 MB total for 8 windows or on a more than 10 percent energy regression, with the 10 percent RAM limit as a target, since WebKit alone took 277 MB for 8 separate synthetic windows.
AGREE - Tauri has a macOS automation route through WebdriverIO's embedded WebDriver, unproven windowless, and VCX does not need it because unwindowed WKWebViews load and answer evaluateJavaScript.
AGREE - 10 to 16 developer-weeks with agents is a reasonable consolidated estimate, with step 0 and the web transcript giving the visible wins in about 3 to 5 weeks.