# Breaking VCX's Swift app apart and rebuilding it in Rust (tao + wry)

25/11/2026. Six models answered the brief blind, then cross-examined each other against measurements taken from a
first Rust slice built the same day (`vcx/rust`, commits `878c4ee` to `28ef65a`). Research folder:
`research_notes/vcx-rust-breakdown/`. The moderator (this Claude session) judged and built; it is not a seventh
opinion.

## Answer

1. **Port the frontend first, against today's Swift workers, over protocol v1 unchanged.** All six legs end there
   (Grok and Qwen changed in round 2). It already works: the Rust shell drives an unmodified Swift worker from prompt
   to answer (M1, M9).
2. **Cut along the socket, not along the Swift files.** Keep the frontend/worker split, the per-session Unix socket,
   leases and sequences, and the Codex-shaped `Connection` idea. Redraw the 2,305-line `Session` (a display-free
   state crate), the untyped JSON (typed accessors over passthrough maps), the draft as an attributed string (text
   plus chips), and the checks compiled into the app (tests outside the binary).
3. **The page owns the transcript and, for now, the composer.** Markdown becomes HTML in the frontend's Rust core,
   with raw HTML shown as text, a scheme allowlist and a CSP without inline script: no sanitizer library, no cache
   yet. A textarea plus a chip strip takes real keys, a real click and input-method text in a window that is never
   shown (M9, M11). Paste, ⌘ shortcuts and undo are not measured; Codex leaned to a native editor in round 2 and
   agreed in the sign-off to try the page composer first.
4. **No async runtime in the frontend, no virtual list yet.** Plain threads, channels and `EventLoopProxy` carry one
   window (M5). A 5,000-row thread draws in 0.37 s and a streamed patch costs 30 ms at p95 (M10), under the 100 ms
   budget the Claude leg set for building a virtual list. Grok wanted the virtual list from the start until M10 and
   agreed in the sign-off.
5. **Rust workers come second, behind a conformance suite run against both implementations, Codex adapter first**
   (the interop fixture is a stand-in for `codex app-server`). Swift sessions are never adopted live by a Rust
   worker: idle sessions close and reopen cold. Qwen alone kept the hot swap in round 2, without evidence, and
   agreed to the cold reopen in the sign-off (yielded: it cited nothing new).
6. **Coexistence is a second app, never installed at the Swift app's path**, attaching only to sessions it is
   pointed at. Taking a session closes its Swift window and nothing gives it back by itself (M4). Before it touches
   a session he works in, one Swift change is needed: a window closed on lease loss must leave the recovery list,
   or the next cold launch of the Swift app takes the session back (C4, read in the code, not run).

## The workspace

Built today:

| Crate | Responsibility | Swift it stands in for |
|---|---|---|
| `vcx-proto` | v1 frames, client, leases, sequences and receipts | `RuntimeTransport`, the client half of `RuntimeClient`, `NativeThreadLease` |
| `vcx-model` | Session replica (snapshot + patches), the page contract (`view`), Markdown to HTML | the read side of `Session`, `Transcript`'s Markdown, `Messages` |
| `vcx-shell` | tao window, wry web view, template store with hot reload and last-good, page bridge, windowless checks | `main`, `Views`, `Transcript`, the `*Check.swift` harness |
| `vcx-testkit` | Starts an isolated Swift worker with the fixture agent | test peers |
| `template/` | The page: HTML, CSS, script, contract 1 | SwiftUI rows and styles |

Still to build, in this order:

| Crate | Responsibility | Swift it replaces |
|---|---|---|
| `vcx-app` (grows out of `vcx-shell`) | Many windows in one process, starting and finding workers, session list, Fleet presence, Edit menu, `.app` bundle | `main`, `RuntimeClient`, `RuntimeRecovery`, `Settings`, `StateHome` |
| `vcx-conformance` | One protocol suite run against the Swift worker and the Rust worker | `RuntimeCheck`, `RuntimeBoundsCheck`, parts of `RecoveryCheck` |
| `vcx-agents` | Provider adapters emitting typed events with the raw payload kept | `Agents`, `RPC`, `Agy`, `Capabilities`, `ProviderJSONReader`, `ClaudeCompatibility`, `ModelControl` |
| `vcx-worker` | The session's write side, socket server, checkpoints, Rust-to-Rust swap | `Session`, `Commands`, `RuntimeServer`, `RuntimeSession`, `RuntimeSwap`, `RuntimeUpdate` |

Stays in Python: installer, auto-update job, archive helpers. Stays native through objc2: snapshots, synthetic
input for checks, the application menu, open and save panels, drag and drop.

## Slices, each with its proof

| # | Slice | Proof | State |
|---|---|---|---|
| 1 | Protocol client, replica, one window drawing a live session, template hot reload with last-good, windowless checks with picture, keys, click, input-method text | `cargo test --workspace` in `vcx/rust` | done, 78 tests pass |
| 2 | Transcript parity: images, question cards, thought bubbles, debate rows, find, charts as `vcx://chart/<id>` sandboxed frames with their own CSP | one windowless test per feature; a chart frame that posts to its parent and is refused the network | next |
| 3 | Composer: chips, long-paste, `/` palette, Edit menu, undo | the M9 and M11 harness extended; paste tested page-side with a synthetic `ClipboardEvent` (a real paste would read his clipboard) | open |
| 4 | The app: many windows in one process, starts workers itself, own bundle id, own Fleet namespace; the Swift recovery-list fix | a 13-window run measuring threads, memory and patch delay; a cold Swift launch while Rust holds a session | open |
| 5 | Conformance suite, then the Rust worker with the Codex adapter, then Claude, Qwen, agy | the same suite green against both workers; the Swift frontend attached to a Rust worker | open |
| 6 | Rust-to-Rust live update, cutover, Swift retired | a swap under a streaming agent: same agent pid, no byte lost, failed adoption rolls back | open |

## Evidence: measured on this Mac

| # | What | Result |
|---|---|---|
| M1 | Rust shell (tao 0.38, wry 0.58.1) against an unmodified Swift worker, fixture agent | `hello`, `attach`, `perform send`, `session/update`, `detach` work; the turn is drawn |
| M2 | Window built with `with_visible(false)`, `ActivationPolicy::Accessory`, no activation, `BackgroundThrottlingPolicy::Disabled` | page loads over `vcx://template/`, lays out, answers IPC and script calls; `takeSnapshot` gives a 1960×1440 picture |
| M3 | Same window | `visibilityState` is `hidden`; CSS animations and transitions never advance, so a check finishes them itself; the page applies messages at once and never waits on a frame |
| M4 | Attach from Rust to a session the Swift app shows | the Swift window closes (`session/leaseLost`) and does not come back when the Rust window closes |
| M5 | Frontend concurrency | std threads, channels, `EventLoopProxy`; no tokio in the dependency tree |
| M6 | Markdown | pulldown-cmark 0.13 events, raw HTML as text, scheme allowlist; CSP `default-src 'none'`, scripts and styles only from the template |
| M7 | A template whose page never reports ready, or reports another contract | replaced after 3 s by the last template whose page was ready |
| M8 | Template edited while the page is open | a CSS edit restyles with no page load; a script edit reloads and redraws the session; a script that throws gives way to the page before it, with a notice |
| M9 | Real `NSEvent` keys through `-[NSWindow sendEvent:]`, real `mouseDown:`/`mouseUp:` on the web view, window never shown or key | 23 characters reach the textarea in order, the click sends, the Swift worker runs the turn |
| M10 | 5,000 rows (75,012 DOM nodes, 3.2 MB of HTML), optimized build, unshown window | whole thread drawn and laid out in 370 ms; streamed patch p50 27 ms, p95 30 ms; with `content-visibility: auto` 239 ms and p95 7 ms, but rows then keep placeholder heights in an unshown window |
| M11 | `setMarkedText:` then `insertText:` on the web view for `かな変換é` | five compositions seen by the page, the text arrives intact, nothing is sent before the click |

Not measured: paste and ⌘ shortcuts (C1), undo, a real input method's candidate window, chart frames (C3), several
windows in one process, memory, paint and scroll latency in a shown window, long answers, any Rust worker.

M10 and M11 were taken after round 2; the legs saw them only in the sign-off.

## Disputed points after round 2

| # | Point | Claude | Codex | Gemini | Grok | Muse | Qwen | Outcome | Decided by |
|---|---|---|---|---|---|---|---|---|---|
| D1 | Which end first | frontend; conformance suite moved to before the Rust worker | frontend | frontend | frontend (was worker first) | frontend | frontend (withdrew core first) | settled: frontend first | M1, M9 |
| D2 | Composer | page textarea + chips, if the IME check passes | textarea in the canary, leans native, same test on both | page textarea + chips (was contenteditable) | textarea next, native prototyped beside | page textarea, native as fallback (was native) | page textarea | page composer first; Codex undecided in round 2, leaning native, agreed in the sign-off | M9, M11; paste and shortcuts open |
| D3 | Rust adopting a running Swift agent | never | drain and cold resume | never | cold only for now | cold first, live later as opt-in | keeps hot swap | cold reopen; Qwen kept the hot swap in round 2 and yielded in the sign-off | `RuntimeSwap.swift:92,138,142`: the swap execs the installed Swift path, a failed adoption kills the agent |
| D4 | Where Markdown becomes HTML | frontend, no cache until measured | frontend, cache if profiling asks | frontend, with a cache | frontend | frontend (was worker) | not asked | settled: frontend | M6 |
| D5 | Protocol v2 | undecided; v1 enough for interop | v1 through coexistence, measure frames first | not needed during the move | only when both ends are Rust | undecided | kept a binary header | v1 through coexistence, v2 shape open | `RuntimeServer.swift:125-131`: Swift requires `protocol: 1` and one JSON line |
| D6 | Frontend concurrency | threads (was tokio) | threads (was tokio) | threads (was tokio) | threads | threads | not asked | settled for one window; 13 windows open | M5 |
| D7 | Sanitizer | none needed unless raw HTML is rendered (was ammonia) | none now, WebKit URL corpus first (was ammonia) | none (was ammonia) | none | none, fuzz the pipeline | not asked | settled: no ammonia | M6; pulldown-cmark 0.13.6 `html.rs` escapes everything but raw HTML events |
| D8 | Long threads | `content-visibility` + paging, virtual list on a missed budget | simple list, the 5,000-row run decides | `content-visibility` first (was virtual list) | virtual list from the first slice | `content-visibility` first (was virtual list) | virtual list only if slow | no virtual list now; Grok agreed in the sign-off | M10 |
| D9 | The unshown check window | `with_visible(false)` + Accessory | same | same | same | same (was off-screen with private settings) | not asked | settled | M2, M3, M8 |
| D10 | Synthetic input | keys and clicks verified, IME open | undecided (answered before M9) | verified, IME open | verified, IME open | verified, IME open | not asked | settled for keys, clicks, marked text | M9, M11 |
| D11 | Worker binary | separate `vcx-worker` | separate executables in one bundle | separate | one binary with a flag | one binary with a flag | separate | open, leaning separate; decided with slice 5 | none yet |
| D12 | First provider of the Rust worker | Codex (was Claude) | undecided, parity spike on both | undecided | undecided | undecided | not asked | Codex first, weakly | `fixtures/fake_agent.py:1`: the fixture both workers can run stands in for `codex app-server` |
| D13 | Coexistence | second app, shared runtime folder, explicit socket, Swift fix | separate app state, explicit handback | second app, no Swift markers (seamless return withdrawn) | second app, handback logic missing | two apps by lease, no automatic return | not asked | second app; no automatic return | M4 |
| D14 | Effort, one developer with agents | 25 to 45 days (was 42 to 66) | 36 to 58 days, undecided; to re-estimate after one parity-complete frontend slice and one provider migration | nearer 36 to 66 days (was 19 to 26) | between the short and long figures | withdrew 18 to 25 weeks (yielded) | about 15 weeks, undecided | no agreed figure; all are estimates | nothing measured |

Single-leg claims:

| # | Claim | Outcome | Decided by |
|---|---|---|---|
| C1 | Without an Edit menu, ⌘C/⌘V/⌘A do not reach the web view | likely true, not run; the app slice adds the menu | tao 0.38 installs no main menu; wry's parent view forwards keys to `app.mainMenu()` (`wry_web_view_parent.rs:30-35`), read by Claude; Codex undecided |
| C2 | An unshown window with no size gives a 0×0 view | refuted | tao 0.38 `window_delegate.rs:174-176` defaults to 800×600 |
| C3 | Sandboxed chart frames fail under a custom scheme | undecided | no source found; a `srcdoc` chart would inherit the page CSP, so charts need their own `vcx://chart/<id>` document |
| C4 | The Swift app can take a session back from the Rust app | supported by code, not run | `main.swift:213-217` closes the window on lease loss through `closing`, so `windowShouldClose` (`main.swift:419`) skips `beginClose`, and `RuntimeRecovery.requestClose`/`remove` run only from the close paths (`main.swift:433,443,495`, `RuntimeClient.swift:227-238`); `main.swift:170-174` reattaches pending entries on a cold launch; update race: `main.swift:215,312,344`, Codex undecided |
| C5 | Only a private occlusion setter keeps a page visible | true for a shown, covered window only | WebKit `PageClientImplMac.mm`: a window that is not visible is hidden before occlusion is consulted; M3 |
| C6 | Swift workers can connect to a Rust server through `--runtime-url` | refuted, withdrawn by Qwen | no such flag in the Swift sources; the worker is the server |
| C7 | Muse's three sources for private occlusion settings | weak, said so by Muse | agent-written notes; not needed after M2 |

## Risks and stop rules

- **Sessions taken back or lost during coexistence (C4).** Until the Swift fix and its test exist, the Rust app
  attaches only to throwaway sessions.
- **The composer feels almost right.** Slice 3 ends with the same marked-text, paste, undo and focus test run on the
  page composer; if it fails, a native sibling `NSTextView` (Codex's design) replaces it.
- **Background windows fall behind.** A page in a hidden or covered window gets no frames (M3). The page must keep
  applying messages without them, and slice 4 measures the delay between a worker revision and the page's.
- **Long threads.** M10 has no paint or scroll figure. If a shown 5,000-row window scrolls badly, paging older rows
  comes first, a virtual list second.
- **The Swift worker test can skip silently** when the Swift binary is missing (found by Codex). The migration gate
  must require a run that did not skip.

## Sign-off

| Leg | K1 to K10 | Remarks |
|---|---|---|
| Claude (Opus) | AGREE on all ten | read the report; its C4 citation was imprecise, corrected above |
| Codex (gpt-6.2-sol) | AGREE on all ten | read the report; D2 overstated its position as a dissent and D14 left out the frontend slice of its re-estimation plan, both corrected above |
| Gemini | AGREE on all ten | none |
| Grok | AGREE on all ten | none; K5 reverses its round-2 virtual list after M10 |
| Muse | AGREE on all ten | none; K10 leaves its one-binary preference open |
| Qwen (qwen3.5-9b-abl) | AGREE on nine, DISAGREE on K2 | its K2 reason restates K2 (native editor only if the composer test fails), so nothing was changed; K6 reverses its round-2 hot swap with no evidence (yielded) |

No dissent on a key claim is left standing. Still open by agreement: the worker binary split (K10), the first
provider beyond a weak lean to Codex (D12), the shape of a v2 (D5), every effort figure (D14).

## Roster and failures

| Leg | Route | Round 1 | Round 2 | Sign-off |
|---|---|---|---|---|
| Claude (Opus) | native agent | answered | answered | answered |
| Codex (gpt-6.2-sol) | Codex CLI | answered | answered on the second try (the first stalled on a network outage) | answered |
| Gemini | web | answered | answered | answered |
| Grok | web | answered, no sources | answered | answered |
| Muse | web | answered | answered | answered |
| Qwen (qwen3.5-9b-abl) | local Ollama endpoint | answered, no sources | answered a shortened list; confused labels, low weight | answered; low weight |
| agy (gemini-3.8-flash-high) | Antigravity CLI | failed: quota reached, resets in 126 h | not asked | not asked |
| Meta AI | web | not asked: same provider as Muse | not asked | not asked |

Web legs and Qwen received the disagreement list with each position, not the five full answers.

## Outcomes

- 25/11/2026, observed: slice 1 built and pushed; `cargo test --workspace` passes (see the last section of the
  research folder's `disagreements.md` for M1 to M11).
- 25/11/2026, observed: sign-off round, 59 AGREE and 1 DISAGREE out of 60 lines (six legs, ten key claims).
- 25/11/2026, proposed, not done: slices 2 to 6, the worker binary split.
- 26/11/2026, observed: the Swift recovery-list fix is pushed (`fb40939`). A window closed on lease loss deletes its
  own entry of the recovery list (`RuntimeRecovery.release`, only when the entry's owner is the closing process and
  no other window of that process holds the session); `--runtime-recovery-check` prints 48 checks passed, two of
  them new (another owner's entry survives a release, this process's entry is removed). Not run: a real takeover by
  the Rust app followed by a cold launch of the Swift app, so C4's stop rule holds until that test exists.
- 26/11/2026, observed: every push under `vcx/rust` made the update job rebuild and swap the Swift app (6 Rust
  commits installed on 25/11, one run failed and was retried); `7181bf0` takes `vcx/rust` and `vcx/build-rust.sh`
  out of `auto-update.sh`'s paths.
- 26/11/2026, observed: the update job installed `fb40939` at 00:18:48 on its second attempt (the first failed on
  the network-retry check that also failed on `7b0f1cf` and `adcbcf2`, before this change). The live handover to
  the new frontend did not complete (its log: "the previous frontend kept its lock for 25 s", cause not established);
  the old frontend was quit at 00:19:55 and a cold launch at 00:20:10 runs the new build, each listed session with
  its entry in the recovery list.
