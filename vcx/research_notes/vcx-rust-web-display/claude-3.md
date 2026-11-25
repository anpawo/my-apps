# Claude leg sign-off (round 3)

The figures in the preamble match my round-2 measurement as written.

1. AGREE.
2. AGREE.
3. DISAGREE on the word "only": among public APIs, yes. In the WebKit-7624.5.1.11.3 source, the private `usesSingleWebProcess` mode (`_WKProcessPoolConfiguration.h:38`, used at `WebProcessPool.cpp:1307`) also shares one process, and `processForSite` can reuse an idle cached or prewarmed process. Suggested wording: "the only public way to share is related views". Codex-2 also asked for "only" to be dropped.
4. AGREE.
5. AGREE. Two notes: in the Swift-host steps, today's frontend comes on top of these figures until its SwiftUI transcript code leaves. The 253 MB baseline excludes the WebContent process each chart block spawns today, so the matched baseline must count those processes.
6. AGREE.
7. AGREE.
8. AGREE.
9. AGREE.
10. AGREE.
11. AGREE. The matched baseline is today's VCX on the same 8 threads, with its chart-block WebKit processes counted.
12. AGREE. One test is still missing: `takeSnapshot` on a view with no window (VCX snapshots views in unshown windows today).
13. AGREE. My own estimate stays 11 to 16 weeks, inside the stated range. The transcript wins come in 3 to 5 weeks; moving the whole window (composer, palette, cards, task bar) is about 5 to 7 weeks.
