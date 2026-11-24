# Fleet session grouping: recommended design and optimizer

Research date: 2026-11-24. Blind assessments and cross-examination complete; five final sign-offs received, Meta AI final sign-off timed out.

## Recommendation

Use a **Fleet-owned deterministic project resolver**: explicit project intent and corroborated task paths first, lightweight lexical candidate retrieval when evidence is missing, and an explicit unresolved result when evidence is insufficient. Store the inferred project separately from execution `cwd`, and preserve Fleet's existing parent/child grouping policy.

For offline improvement, establish independently adjudicated examples first. Use simple parameter search for a few weights and thresholds. Reuse the working **OpenEvolve** setup for structural changes to the scoring or extraction algorithm when that simpler baseline is insufficient. Keep fixed local embeddings, GEPA and ShinkaEvolve as challengers to evaluate, rather than declaring them winners from unrelated benchmarks.

This is the best-supported initial engineering choice from the code and sources reviewed. **No Fleet accuracy winner, speedup, confidence threshold or required dataset size has been measured in this research.**

## The method behind the recent optimization work

The existing [local optimization setup](../../../optimization/llm-evolve/README.md) uses OpenEvolve with authenticated Codex CLI calls. Its documented loop mutates a function, checks output equality against the original and scores valid programs on runtime; the inspected recall evaluator also contains that equality check.

That contract is appropriate for accelerating behavior that must remain unchanged. Improving session classification needs a different objective: independently verified target projects and acceptable unresolved cases. Copying an equality-only contract into grouping could make existing misclassifications faster.

| Offline method | Appropriate role here | Decision |
| --- | --- | --- |
| Simple parameter search | Tune a small set of lexical weights and abstention parameters against development data | First tuning baseline, with fixed seeds and a locked final test |
| OpenEvolve | Search for better feature extraction, scoring logic or faster equivalent implementations under explicit correctness constraints | Reuse the existing integration if structural search is justified |
| ShinkaEvolve | Alternative program-evolution search with adaptive sampling, novelty filtering and model selection | No Fleet evidence justifies switching frameworks now |
| GEPA | Reflectively optimize textual parameters, including code, configuration and prompts | Valid challenger; current GEPA is not limited to prompts |

[OpenEvolve](https://github.com/algorithmicsuperintelligence/openevolve), [AlphaEvolve](https://arxiv.org/abs/2506.13131) and [ShinkaEvolve](https://arxiv.org/abs/2509.19349) use evaluator-driven program search. [Current GEPA](https://github.com/gepa-ai/gepa) supports code and configuration as well as prompts. These are optimization mechanisms, with no demonstrated superiority on this particular grouping task. [Random-search research](https://www.jmlr.org/papers/v13/bergstra12a.html) supplies a useful numerical baseline, not proof of a Fleet-specific advantage.

## What the current code establishes

Fleet derives a specific project name and an outermost grouping key from session `cwd`, Git ancestry and `.fleet` split rules in [Models.swift](../Sources/Fleet/Models.swift), particularly lines 409, 437 and 465. Its [registry](../Sources/Fleet/SessionRegistry.swift), lines 27 and 111, combines terminal sessions with VCX sessions. Fleet therefore needs an assignment policy covering both sources.

VCX's [prompt router](../../vcx/Sources/VCX/Directory.swift), beginning at line 103, calls Haiku with folder and skill metadata and applies a ten-second timeout. This is a timeout ceiling, not a measured average response latency. [Session.swift](../../vcx/Sources/VCX/Session.swift), line 1495, restricts prompt routing to root sessions or an initially empty home-directory session; line 739 can update the directory after a completed turn using recognized edited paths.

An earlier untuned lexical experiment indexed 139 existing catalogue entries and ranked an unrelated project first for a grouping question. It was not a representative accuracy comparison. Two affected sessions later acquired the expected directory, but their histories also contained explicit directory-setting commands, so their movement does not prove that automatic inference recovered them.

## Production design

**One owner, separate fields.** Fleet should own the accepted grouping assignment for its stable session identity. VCX and terminal adapters supply normalized evidence. Keep the canonical project directory, reason, revision and catalogue version separate from the real execution directory. An inferred display category must not redirect commands or change an agent's permissions. If a broader shared assignment service is introduced later, it must cover every input adapter; VCX alone currently does not.

**Resolve intent before similarity.** A deliberate user override outranks inferred evidence. A successful directory change or edit inside a registered project is useful when it agrees with task intent, but an inherited launch folder or a temporary command directory is not conclusive. Read-only access to shared setup, examples or dependencies is weak evidence. Deliberate work on a dependency remains eligible; blanket exclusions of every vendor folder would also be wrong. Agent-issued directory changes are not automatically human-adjudicated labels.

**Use canonical project identities and the existing hierarchy.** Discover actual registered roots and `.fleet` boundaries, including nested repositories and worktrees; supplement them with reviewed names, aliases and descriptions. A static prose map can omit a target. Resolve specific ownership without replacing Fleet's intentional distinction between `dirName` and outermost `groupKey`. Preserve its existing display hierarchy and labels.

**Keep the fallback small.** For unresolved textual intent, rank catalogue candidates with weighted lexical retrieval over project names, aliases and concise descriptions. Use actual task text and meaningful action evidence, excluding injected agent instructions and incidental source dumps. [SQLite FTS5](https://www.sqlite.org/fts5.html) provides weighted BM25. A rank or score margin is not a calibrated probability: automatic acceptance must be justified on development data, with unresolved results retained otherwise.

**Update on meaningful evidence.** Normalize successful structured tool events across providers before adding a more sophisticated ranker. Preserve explicit corrections and resist weak contradictory reads; reconsider on clear task changes or stronger evidence. Cache catalogue data and invalidate it when roots or descriptions change. Reclassify on relevant events rather than running inference on every UI refresh. Missing tool evidence cannot be recovered by changing a ranking formula.

**Handle missing information honestly.** An image-only or vague request can remain unresolved until other evidence appears. The current text router does not send image bytes; a vision or OCR path would be a separate integration. A default assignment to the home directory would create a false project label. No runtime paid-provider substitution is part of this recommendation.

| Runtime candidate | Why consider it | Limitation and current role |
| --- | --- | --- |
| Intent-sensitive provenance | Explainable project evidence, compatible with existing boundaries | Can be inherited, temporary or incomplete; initial foundation, not proven perfect |
| Weighted lexical retrieval | Small local index, exact names and aliases, inspectable reasons | Vocabulary mismatch and ambiguity; initial fallback baseline |
| Fixed local embeddings with exact similarity search | Semantic matches across different wording | Model assets and encoding cost; add only if held-out results justify them |
| Small supervised classifier | Learns task-specific distinctions from examples | Representative labels and new-project handling needed; later challenger |
| Runtime LLM classifier | Can interpret richer supplied context | Availability, variability and context transfer; not required by the initial design |

For a small catalogue, [Sentence Transformers documentation](https://www.sbert.net/examples/sentence_transformer/applications/semantic-search/README.html) describes exact vector similarity search; an approximate vector index is not an established need here. If lexical and vector ranking are compared together, [reciprocal rank fusion](https://learn.microsoft.com/en-us/azure/search/hybrid-search-ranking) supplies a baseline for combining ranks without treating different raw scores as comparable. Neither technique establishes project ownership or a Fleet accuracy gain. [Supervised classification](https://fasttext.cc/docs/en/supervised-tutorial.html) requires labeled examples.

## Evaluation contract before optimization

- Adjudicate target projects, acceptable alternatives and legitimate unresolved cases using task intent. Current labels, eventual edit locations and agent-issued `--set-dir` calls can help identify candidates, but are not unquestionable ground truth.
- Evaluate session prefixes at multiple decision points, including the initial request, meaningful later actions and topic changes. Later human adjudication may supply a label; future actions, corrections and catalogue knowledge must not appear in earlier features.
- Keep resumed sessions, near-duplicates and related tasks together across splits. Separate development/tuning from a locked chronological final test; report novel projects separately rather than conflating a closed-label classifier with open-catalogue routing.
- Report false assignments alongside useful routing coverage and abstention, including genuinely unknown cases. Report per-project and difficult slices, not just a majority-project average. An all-abstain policy must not win the objective.
- Measure cold and warm end-to-end tail latency, memory, time to a correct group, assignment churn, correction persistence, restore behavior and the group actually displayed in Fleet. Scoring-loop timing alone is insufficient.
- Freeze the quality, coverage and resource constraints before adaptive search; inspect the error/coverage frontier rather than choosing a convenient single threshold. Do not feed the final test back into mutation or parameter selection.

**Falsifier:** a challenger that reliably reduces false assignments at matched useful coverage, within the same agreed latency, stability and privacy constraints, would displace the recommended baseline. Conversely, embeddings that add no useful coverage at matched error risk should not become a default dependency. The required sample size and confidence thresholds remain open until the data and uncertainty are examined.

## Debate record

Six blind assessments were followed by cross-examination: Codex, Antigravity Gemini, Gemini web, local Qwen, Muse and Meta AI. These represent four provider families, not six independent providers: the two Gemini routes share Google, and Muse and Meta AI share Meta. The moderator's judgment is not an extra vote. Claude and Grok returned usage-limit failures in connectivity probes and supplied no research answers.

The initial prompt was shared, but no blind reviewer received the other answers until cross-examination. The moderator read every answer in full. Changes based only on another reviewer's preference are marked as yielded; they do not establish an empirical result. New code observations support the ownership correction, while the newly supplied source on numerical tuning motivates a baseline rather than proving a Fleet win. Web-product model versions and separately resolved CLI server-model identifiers were not exposed; the roster preserves those identity limitations.

| Disputed claim | Codex | Antigravity | Qwen | Gemini web | Muse | Meta AI | Outcome and deciding evidence |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Ship embeddings initially | Challenger | Yielded to lexical-first | Retains hybrid in cross-examination, yields at sign-off | Yielded to lexical-first | Revises to lexical-first | Withdraws immediate hybrid | No Fleet comparison exists; the final lexical-first agreement is not experimental confirmation |
| Authoritative store | Fleet | Revises VCX to Fleet | Clarifies Fleet | Fleet | Revises VCX to Fleet | Fleet | New SessionRegistry/ProcessScanner observations show terminal and VCX inputs need coverage |
| Numerical speed, memory or sample-size claims | Unmeasured | Retracts figures | Initial 5% cutoff not supported | Withdraws precision assertion | Expectations, not measurements | Unmeasured | No quantitative claim or threshold accepted without applicable measurement |
| Evolution can optimize grouping code | Yes | Offline structural work | Retains a narrower tuning/prompt role | Yes | Yes | Yes | Current GEPA documentation and custom-evaluator design support code/configuration optimization; no task winner established |
| Few numeric parameters need evolution first | Revises to random baseline | Revises to random baseline | Simple grid baseline | Revises to numerical baseline | Revises to random baseline | Numerical baseline | Random-search paper motivates comparison; no Fleet superiority inferred |
| Later human labels versus future features | Keeps distinction | Withdraws turn-zero-only rule | Time-ordered features; limited detail | Clarifies multiple prefixes | Clarifies multiple prefixes | Accepts adjudication distinction | Later adjudication is compatible with decision-time features; automatic final directories remain weak labels |
| Image-only fallback | Revises to unresolved | Withdraws assumed vision path | Unassigned, with a home-directory caveat | Withdraws assumed vision path | Unresolved | Unresolved | Existing router sends text, not image bytes; no forced home assignment or assumed vision integration |

Qwen retained immediate embeddings through cross-examination, then endorsed lexical-first at final sign-off without supplying new empirical evidence. That change is recorded as yielded, not as experimental confirmation. Its narrower cross-examination description of evolutionary optimization does not override current GEPA documentation; its final response accepts the report's broader structural-search role. The earlier disagreements remain visible in the archived rounds.

The [brief](../research_notes/session-grouping-algorithm-selection/brief.md), [source notes](../research_notes/session-grouping-algorithm-selection/sources.md), [roster](../research_notes/session-grouping-algorithm-selection/availability.md), [disagreement list](../research_notes/session-grouping-algorithm-selection/disagreements.md) and per-route round files preserve the evidence and revisions. Archived review text normalizes typography; raw adapter outputs remain outside the repository. Some routes could assess the supplied evidence but could not independently browse sources, so agreement is not described as six independent source verifications.

## Claims for final sign-off

- K1: Fleet should initially own a canonical grouping assignment covering every adapter, separate from execution `cwd`, while preserving existing hierarchy.
- K2: Intent-sensitive provenance plus a lexical fallback and unresolved state is the recommended initial engineering baseline; embeddings remain a challenger, with Qwen's dissent recorded.
- K3: Independently adjudicated labels and multiple decision-time prefixes are required to assess accuracy; the existing equality-only tasks do not supply a grouping-accuracy judge.
- K4: Simple numerical tuning should precede structural evolution; the existing OpenEvolve integration is a reasonable reusable tool, while GEPA and ShinkaEvolve have no demonstrated Fleet advantage.
- K5: No numerical performance, accuracy, threshold or dataset-size claim is established by this research; all comparisons must account for coverage, resource costs and assignment stability.
- K6: Source research and debate are complete in scope; no production implementation, new benchmark, training or evolutionary run is claimed.

No production code, app installation, new benchmark, training run or evolutionary search was performed for this request.

## Final sign-off outcome

| Route | K1 | K2 | K3 | K4 | K5 | K6 |
| --- | --- | --- | --- | --- | --- | --- |
| Codex | AGREE | AGREE | AGREE | AGREE | AGREE | AGREE |
| Antigravity Gemini | AGREE | AGREE | AGREE | AGREE | AGREE | AGREE |
| Local Qwen | AGREE | AGREE, yielded from immediate hybrid | AGREE | AGREE | AGREE | AGREE |
| Gemini web | AGREE | AGREE | AGREE | AGREE | AGREE | AGREE |
| Muse | AGREE | AGREE | AGREE | AGREE | AGREE | AGREE |
| Meta AI | No answer | No answer | No answer | No answer | No answer | No answer |

Meta AI's final adapter call exited unsuccessfully after reporting that it did not finish answering within ten minutes. No final answer was saved, and it was not retried. Its blind assessment and cross-examination remain part of the record; the failed sign-off is not counted as agreement. Claude and Grok supplied no research answers because their connectivity probes hit usage limits. The five received sign-offs endorse the claims as reviewed, not a measured performance advantage. The final report adds these outcomes and Qwen's yielded change without changing the recommended design.
