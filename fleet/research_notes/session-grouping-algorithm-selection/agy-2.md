### Point Assessments

- **Points 1, 3 (Embeddings and Performance Numbers): REVISE.** I retract my round-1 estimates of sub-millisecond execution, zero memory, 150 MB embedding footprint, 20 ms latency, and a 200-sample label requirement; none were empirically measured. Furthermore, without evidence that fixed embeddings improve the error-coverage frontier over lexical search on 139 entries, I yield to Codex: start with lexical ranking as the primary search engine, treating embeddings as an offline challenger.
- **Point 2 (Assignment Ownership): REVISE.** Newly cited code facts from `SessionRegistry.swift:27,111` and `ProcessScanner.swift:56` show Fleet tracks terminal sessions alongside VCX. Authoritative session state cannot reside in VCX; it must live in Fleet's own session store, receiving normalized events from VCX and terminal adapters. Grouping and execution `cwd` must remain decoupled.
- **Points 4, 5 (Evolution and Numerical Baselines): RETAIN offline role, REVISE baseline.** Evolutionary search belongs strictly offline for scoring heuristics. However, for tuning numeric field weights and thresholds, random search (https://www.jmlr.org/papers/v13/bergstra12a.html) must be the primary baseline. Program evolution via GEPA (https://github.com/gepa-ai/gepa) or OpenEvolve (https://github.com/algorithmicsuperintelligence/openevolve) is justified only if tuning complex symbolic rules or prompt templates against an independently labeled evaluator.
- **Points 6, 9 (Abstention, Provenance, and Images): RETAIN abstention, REVISE image handling.** Yielding to the prompt fact that the router only receives text and that Claude is offline, I retract my round-1 multimodal LLM fallback. Image-only turns without text anchors must abstain to an explicit "Unassigned" category rather than guessing the home directory or `/`. Provenance is conditional: dependency writes outweigh reads, but deliberate edits inside vendor directories must not be universally discarded.
- **Point 7 (Evaluation Time and Leakage): REVISE.** Restricting evaluation to turn zero was an error. The evaluator must score decision-time prefixes across multiple session turns (turn 0, turn t) to capture mid-session reassignments without leaking future edits.
- **Points 8, 10 (Falsifiers and Hierarchy): RETAIN.** Preserve Fleet's two-level display (`dirName` and `groupKey` for `.fleet` splits). Evaluation must assess false assignments at matched coverage rather than rewarding all-abstain policies.

### Final Recommended Initial Architecture

1. **Deterministic Provenance Tier:** On meaningful shell or file events, Fleet matches canonical paths against registered Git roots and `.fleet` boundaries using longest-prefix matching. Grouping assignment is stored in Fleet's session registry, separate from execution `cwd`.
2. **Lexical Candidate Retrieval:** For sessions at `/` or home lacking strong provenance, query project metadata using SQLite FTS5 BM25 (https://www.sqlite.org/fts5.html).
3. **Calibrated Abstention:** If the top BM25 candidate lacks sufficient margin, classify the session as "Unassigned" rather than invoking unverified or unavailable LLM routes.

### Offline Optimization Plan

1. **Data Curation:** Collect historical sessions, split by project and time without future leakage, and obtain human-adjudicated ground truth across multiple turn prefixes.
2. **Baseline Search:** Optimize BM25 column weights and abstention margins using random parameter search (https://www.jmlr.org/papers/v13/bergstra12a.html).
3. **Challenger Evaluation:** Benchmark fixed embeddings and GEPA-driven symbolic heuristics against the optimized lexical baseline.

**Falsifier:** If an optimized lexical-plus-provenance cascade yields higher false-assignment rates at equal coverage than a deterministic-only baseline, or if embeddings fail to improve coverage at matched error rates on held-out sessions, the recommendation is falsified.
