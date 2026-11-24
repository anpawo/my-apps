### Production Architecture and Offline Optimization

The recommended production architecture is a two-tier, provenance-first router. Deterministic rules take precedence: resolve git ancestry and nested repositories via longest-prefix matching on process working directory or edited file paths, while strictly ignoring read-only dependency access. When a session starts at `/` without file edits, fallback to local hybrid retrieval: SQLite FTS5 BM25 (https://www.sqlite.org/fts5.html) combined via Reciprocal Rank Fusion (https://learn.microsoft.com/en-us/azure/search/hybrid-search-ranking) with exact nearest-neighbor search over precomputed catalogue embeddings (https://www.sbert.net/examples/sentence_transformer/applications/semantic-search/). If the top match score is below a strict confidence threshold, route to runtime LLM classification (Haiku) or abstain into an "Unassigned" group. Abstention is strictly superior to misclassification.

Evolutionary frameworks (OpenEvolve, ShinkaEvolve, GEPA) have no place in runtime inference due to latency and non-deterministic overhead. Offline, GEPA (https://arxiv.org/abs/2507.19457) or OpenEvolve (https://github.com/algorithmicsuperintelligence/openevolve) should be used solely to evolve prompt templates, BM25 field weights, and confidence thresholds against a static benchmark.

### Component Comparison

Deterministic provenance provides sub-millisecond latency, zero memory overhead, and perfect stability, but fails before actions occur. Lexical BM25 handles explicit project names instantly at negligible memory, yet stumbles on vocabulary mismatch. Small sentence embeddings resolve conceptual intent with minimal RAM (under 150 MB) and 20 ms latency, avoiding external network calls. Small supervised classifiers like fastText (https://fasttext.cc/docs/en/supervised-tutorial.html) are brittle given dynamic catalogues and sparse per-project training data. Runtime LLM classification handles nuanced ambiguity and image-only multimodal context, but introduces seconds of latency, API dependencies, and drift.

### Edge Cases and Authoritative State

Authoritative session assignment must reside in VCX session metadata, completely decoupled from shell execution `cwd`. A tool inspecting system paths or running in `/tmp` must not alter grouping. Nested projects resolve to the deepest enclosing project boundary. Incidental dependency reads are discarded; only file writes, edits, and explicit user commands update provenance. Corrections (such as an explicit directory change) or mid-session topic shifts immediately re-bind the metadata assignment, which remains sticky across subsequent passive reads.

### Evaluation Contract and Falsifier

Before declaring an improvement, evaluation requires:
1. Ground truth: At least 200 real user sessions manually labeled with true project associations.
2. Time-of-decision splitting: Features must strictly include data available at turn zero (prior to downstream file edits) to eliminate temporal leakage.
3. Metrics: Measure routing accuracy, coverage (percentage classified versus abstained), median latency, and user reassignment rate.

Current evidence cannot determine whether local hybrid retrieval can achieve sufficient confidence to bypass LLM calls entirely for cold-start sessions.

Concrete falsifier: If a hybrid provenance-plus-lexical router yields higher misclassification rates or requires more frequent manual corrections on held-out sessions than an unconstrained Haiku prompt baseline, the recommendation is falsified.
