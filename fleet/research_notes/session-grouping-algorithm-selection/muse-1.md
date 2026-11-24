Recommendation, from provided evidence and inference: a deterministic-first hybrid, not evolutionary search or runtime LLM classification as primary selector.

Provenance first. Use explicit cd commands, directory changes, file edits, git operations, and .fleet folders, with Git ancestry choosing the deepest containing project. Exclude reads and dependency paths such as vendor and node_modules. This is fast, local, stable, and private, and fixes sessions that started at / then worked in a project. Inference: a read does not prove belonging.

Without strong provenance, use a local hybrid over the small catalogue: BM25 plus fixed embeddings with exact search, combined by reciprocal rank fusion. Provided sources describe BM25 weighting, exact search for small corpora, and fusion of rankings rather than incomparable scores. Inference: this fits 139 entries, avoids model latency and cost, and is low-memory and inspectable. Supervised classification is premature without a leakage-resistant labeled set and would need retraining for new projects. Use runtime LLM classification only as a bounded fallback for unresolved sessions, with short prompt, small context, and strict timeout.

Require a clear margin between the top two candidates; otherwise abstain and keep the existing assignment. A user correction becomes a locked label. Re-evaluate topic changes only on new strong evidence. Image-only context should abstain unless paths or transcript text provide evidence.

Keep execution cwd and grouping separate. The authoritative assignment should live in VCX session state as a persisted project directory, consumed by Fleet for grouping. It should not silently move a running shell, because relative paths and git state depend on the real cwd. Only a new session or explicit user action should change execution cwd.

Evolutionary methods have a narrow offline role. OpenEvolve can later tune fusion weights and thresholds against a labeled evaluator, and GEPA can tune the fallback prompt, but neither can create ground truth or correct a wrong original label. ShinkaEvolve has no provided evidence for this task.

The evaluation contract needs user-confirmed ground truth, time-based and project-based splits, and only evidence available at decision time. Report false assignments separately from abstention, plus coverage, latency, and end-to-end Fleet grouping. A top-1 score on a tiny exploratory check is not a benchmark.

The decision that cannot be made now is the best fusion weights, threshold, or LLM fallback prompt, because no labeled set or confidence measurement exists.

Falsifier: if this hybrid, on a held-out time split, does not beat current Haiku routing on false assignments at equal or better coverage, or is worse on latency or stability end to end, reject it.

No new sources were read. Sources: OpenEvolve https://github.com/algorithmicsuperintelligence/openevolve ; GEPA https://arxiv.org/abs/2507.19457 ; ShinkaEvolve https://sakana.ai/shinka-evolve/ ; BM25 https://www.sqlite.org/fts5.html ; embeddings https://www.sbert.net/examples/sentence_transformer/applications/semantic-search/README.html ; fusion https://learn.microsoft.com/en-us/azure/search/hybrid-search-ranking