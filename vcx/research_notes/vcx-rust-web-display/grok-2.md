Point 1 – Process sharing.
Leg B’s WebKit-source claim is the stronger one. The public Apple docs still say “each web view is given its own Web Content process until an implementation-defined process limit” (developer.apple.com/documentation/webkit/wkprocesspool, read 25 Nov 2026). The widely-cited dev.to post that “a shared WKWebsiteDataStore forces process sharing” is an over-statement; the data store is mainly a compatibility/cookie check. Site-isolation code paths (processForSite, IsSharedProcess) exist, but ordinary independent WKWebViews created by an app do not automatically collapse into one WebContent process merely by sharing a store. Related views (window.open answered with the configuration WebKit supplies) do share. Yielded: my earlier “share one data store → one WebContent process” claim is too strong; treat sharing as a measured bonus, not a guarantee.

Point 2 – Default process layout.
Budget one process per view (A/B position). Aiming for a single shared process for all chat windows is optimistic given the source above. Unchanged preference for isolation of runaway charts, but accept any sharing WebKit actually grants.

Point 3 – RAM for 8 windows.
All numbers remain estimates. A’s synthetic 194 MB (related) / ~400 MB (separate) is the only measured pair. My 350–800 / 400–900 MB band is still plausible for a real chat UI; tighten the lower bound only after measurement on the owner’s Mac. Unchanged range, with the caveat that the lower end requires actual process sharing that is not guaranteed.

Point 4 – Stop threshold.
My original 1.2–1.5 GB was too permissive relative to today’s 253 MB frontend. Yielded toward B/C: stop if the new stack is more than ~10 % worse on footprint/energy than the current frontend, or if 8 windows exceed ~700 MB without evidence of process sharing. Absolute hard stop still useful around 1 GB.

Point 5 – Final shell.
Prefer wry + tao (A/C). A minimal Tauri 2 shell remains acceptable if the extra surface area is useful; the claimed headless-ui-test crate does not exist on crates.io (404 confirmed 25 Nov 2026). Unchanged: wry/tao first, thin Tauri only if it reduces maintenance.

Point 6 – Tauri headless testing on macOS.
C is correct for the standalone tauri-driver binary (Windows/Linux only). A/B are correct that the WebdriverIO @wdio/tauri-service + tauri-plugin-wdio-webdriver embedded provider works on macOS (docs at v2.tauri.app/develop/tests/webdriver and webdriver.io, read 25 Nov 2026; the plugin exists on crates.io). Windowless/off-screen still needs explicit verification; the embedded path is not proven zero-window. Yielded on the existence of a macOS route; still unproven for fully headless CI without a visible window.

Point 7 – Composer.
B’s caution is right. Keep the native AppKit composer until web IME, marked text, shortcuts, paste and attachments are measured equal. My “move transcript + composer in step 0” was too aggressive. Yielded: transcript first, composer later.

Point 8 – Markdown.
A/B/C are safer: parse and sanitize in Rust (pulldown-cmark or comrak). Raw agent HTML in the DOM is an unnecessary attack surface. Yielded from “JS side is fine”.

Point 9 – Migration order.
My order (web transcript inside Swift → Rust frontend shell → workers optional/late) is still the lowest-risk path and matches the consensus of A/B/D. A short wry spike before the Swift hybrid is reasonable but not mandatory. Unchanged core sequence.

Point 10 – Who applies a template edit.
Automatic live after staged off-screen validation + last-good rollback (A/B) is acceptable provided the validation is strict. Owner approval for every edit (C) is safer but slower; a “safe mode” that forces the last-good copy covers the risk. Unchanged: live after validation + safe-mode escape hatch.

Point 11 – vcx.live and chart frames.
Opaque-origin sandboxed frames cannot freely fetch arbitrary URLs; CORS and the opaque origin block it. The core must broker polling with an allow-list. E’s “plain fetch from the iframe” is incorrect for a properly sandboxed chart. Unchanged: brokered allow-list.

Point 12 – Chart library.
Vendor a pinned lightweight-charts build (offline, attribution). CDN loading is a network and availability risk for a daily-driver tool. Unchanged preference for vendoring.

Point 13 – GPUI.
B’s assessment is more precise: GPUI is production in Zed, has marked-text APIs and AccessKit work in progress, but is still a moving target for a third-party app. My “high maturity” overstated readiness for a non-Zed product that also needs free-form HTML charts. Yielded: credible but high-cost, still loses agent HTML charts.

Point 14 – Effort.
My 6–12 weeks was optimistic. Consensus of A/B/C is 9–16+ weeks; raise the estimate to 10–16 developer-weeks for a production-quality first cut. Yielded upward.

Point 15 – Shared WKWebView with tabs.
Keep one window per session. An optional low-memory tab mode (B) is a later optimisation, not the default. Unchanged.

Final 5-line recommendation
Proceed with a thin wry/tao (or minimal Tauri) shell, but budget one WebContent process per window and treat any sharing as a measured bonus. Move only the transcript into a web view first while keeping the native composer; sanitize Markdown in Rust; vendor charts; broker vcx.live. Stop if 8-window footprint exceeds ~700 MB without sharing or is >10 % worse than today’s frontend on energy. Raise the effort estimate to 10–16 weeks and keep the existing self-check harness by retargeting it at off-screen webview snapshots.