# Sign-off

This is the last round. Two measurements were taken after round 2:

- M10. A 5,000-row thread (75,012 DOM nodes, 3.2 MB of HTML) in the unshown window, optimized build: the whole thread is drawn and laid out in 370 ms; a streamed patch redrawing the last answer, layout included, costs p50 27 ms and p95 30 ms. With `content-visibility: auto` on rows: 239 ms and p95 7 ms, but in a window that is never shown every row then keeps its placeholder height. No paint, scroll or memory figure.
- M11. Input-method text in the unshown window: `setMarkedText:selectedRange:replacementRange:` then `insertText:replacementRange:` sent to the web view for each character of `かな変換é`, with the page's textarea focused. The page saw five compositions, the text reached the Swift worker intact, and nothing was sent before the click on the send button. Paste, ⌘ shortcuts, undo and a real input method's candidate window are not measured.

The report's key claims are K1 to K10 below. Answer AGREE or DISAGREE for each, one line each, with the reason in the same line when you disagree. Nothing else.

K1. The frontend is ported first, against today's Swift workers, over protocol v1 unchanged.
K2. The composer stays in the page (textarea plus a chip strip), given M9 and M11; a native sibling NSTextView replaces it only if the marked-text, paste, undo and focus test of the composer slice fails.
K3. Markdown becomes HTML in the frontend's Rust core: raw HTML shown as text, a scheme allowlist, a CSP without inline script, no sanitizer library, no HTML cache until a measurement asks for one.
K4. The frontend uses plain threads, channels and EventLoopProxy, no async runtime; this is measured again with 13 windows in one process.
K5. No virtual list now, given M10; if a shown 5,000-row window scrolls badly, paging older rows comes first and a virtual list second.
K6. Rust workers come second, behind one conformance suite run against the Swift worker and the Rust worker, with the Codex adapter first. A Rust worker never adopts a running agent from a Swift worker: idle sessions close and reopen cold.
K7. Coexistence is a second app with its own bundle id, never installed at the Swift app's path. Taking a session closes its Swift window and nothing returns it automatically; before the Rust app touches real sessions, the Swift app must stop keeping a recovery entry for a window closed on lease loss.
K8. Protocol v1 stays unchanged while Swift and Rust coexist; a v2 is designed only once both ends are Rust.
K9. Checks run in a window built with `with_visible(false)` and the Accessory activation policy; the check finishes animations itself and sends input as real NSEvent keys, mouse events and NSTextInputClient calls.
K10. Whether the worker is a separate binary or the same binary run with a flag stays open, leaning to a separate binary, and is decided with the Rust worker slice.
