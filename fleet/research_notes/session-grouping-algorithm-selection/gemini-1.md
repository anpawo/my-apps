For production, deploy a deterministic-first, confidence-gated hybrid cascade owned centrally by Fleet, separating authoritative project assignment from mutable execution cwd.

Evidence from local facts shows deterministic signals (cwd, Git ancestry, .fleet split markers, explicit cd commands, and file-edit events) already carry the highest precision, whereas incidental file reads cause false positives and runtime LLM routing incurs up to a 10-second timeout. Newly verified primary sources confirm SQLite FTS5 provides fast, zero-dependency BM25 ranking with column weighting (https://sqlite.org/fts5.html), while exact vector search handles small corpora without approximate-index overhead (https://www.sbert.net/examples/sentence_transformer/applications/semantic-search/README.html). My inference for combining them is a four-stage cascade:

Deterministic provenance rules: Resolve Git/marker ancestry from cwd, explicit directory changes, and edited file paths, locking assignments once verified. Ignore read-only file accesses to prevent dependency-read pollution.

Hybrid lexical plus fixed-embedding retrieval: When provenance is absent (sessions starting at / or home), fuse FTS5 BM25 (weighting folder names and .fleet metadata over prose) with exact cosine similarity over a small, fixed local embedding model via Reciprocal Rank Fusion (https://learn.microsoft.com/en-us/azure/search/hybrid-search-ranking). Small supervised classifiers (https://fasttext.cc/docs/en/supervised-tutorial.html) are premature until labeled histories exist.

Abstention and runtime LLM fallback: If hybrid margin falls below a calibrated threshold (including image-only turns lacking text tokens or ambiguous sibling projects), abstain or invoke the existing bounded Haiku prompt route over the top-K candidates rather than forcing a bad label.

State separation and mutability: Decouple project_id from shell cwd so subshell directory traversal does not corrupt grouping. Fleet must hold the single authoritative assignment, ingesting VCX signals as advisory events. Nested folders resolve to the deepest matching .fleet or Git root; explicit user overrides lock the session until a confirmed topic shift or cd into another registered root triggers re-evaluation.

Evolutionary frameworks like OpenEvolve (https://github.com/algorithmicsuperintelligence/openevolve), ShinkaEvolve (https://github.com/SakanaAI/shinkaevolve), and GEPA (https://arxiv.org/abs/2507.19457) belong strictly offline. Current local OpenEvolve usage tests output equivalence, which optimizes latency but preserves wrong labels. Once ground truth exists, GEPA's reflective Pareto optimization is best suited to tune prompt templates, FTS5 column weights, and abstention thresholds; OpenEvolve or ShinkaEvolve can optimize heuristic parsing rules.

Before claiming improvement, establish an evaluation contract:

Ground truth and splits: Time-ordered train/validation/test splits of historical sessions labeled via post-hoc user confirmations or unambiguous edit targets, stratified across nested and flat projects.

Leakage prevention: Evaluate strictly on prefixes available at decision time, stripping future cd commands or later edits.

Metrics: Measure precision at target coverage (false-assignment rate versus abstention rate), routing coverage, p50/p99 latency, memory footprint, and end-to-end session stability.

What cannot be decided from current evidence is the minimum confidence threshold, exact RRF/BM25 weights, and whether fixed embeddings add measurable recall over tuned FTS5 on this specific catalogue.

Falsifier: If a leakage-free evaluation shows that tuned FTS5 plus deterministic rules matches or exceeds hybrid retrieval and LLM fallback on precision at equal coverage, drop embeddings and runtime LLM routing entirely.