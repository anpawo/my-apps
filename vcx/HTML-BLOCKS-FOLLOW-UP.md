# HTML blocks follow-up

Pinned and expanded HTML blocks need a dedicated interaction and layout repair in Vibe Code X.
Deferred at Marius's request on 24 November 2026; the latest passing checks do not mean the experience is accepted.

## Reported problems

- Clicking editable fields previously opened the dashboard or dropped focus immediately.
- Scrolling an expanded block previously moved the chat behind it.
- Expanding a pinned graph did not fit its content, especially its width.
- After the latest fixes, Marius still reported many problems with pinned HTML blocks; the remaining failures have not been specified or reproduced.

## Requested behavior

- Right-click pins or unpins a block.
- Double-click opens its expanded version.
- Editable controls retain focus and accept changes.
- Scrolling targets the expanded content instead of the underlying chat.
- Expanded content uses the available width, with scrolling for taller content.
- Visible transitions remain smooth and respect Reduce Motion.

## Resume later

Start with `Sources/VCX/Chart.swift`, its hosting and event-routing callers, and `Sources/VCX/ChartInteractionCheck.swift`.
Latest interaction commit: `514ab6c` (`feat: Add chart pin gestures and fit expanded dashboards`).
Automated checks and a native mouse check passed, but Marius's subsequent report means the overall experience remains unresolved.
Reproduce the remaining failures with the actual HTML dashboard and native event routing before attempting further fixes.
No further application change was made after the request to defer this work.

Existing windowless check, from `/Users/mr/self/my-apps/vcx` after building:

```sh
.build/debug/VCX --chart-check /tmp/vcx-html-block-check
```

Append an existing dashboard HTML file as the final argument to exercise that document too.
