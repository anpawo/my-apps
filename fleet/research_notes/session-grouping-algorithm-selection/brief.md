# Fleet session grouping: algorithm selection

The user's full question is: "recently I've found algorithm to make some nother algorithm faster and more precise, could you look into that and figure out with a deep search what would be the best for fleet fo group sessions ?"

The preceding request concerned sessions grouped under `/` instead of their actual project directory. Research the best approach to assigning a session to an existing project folder, including nested projects, rather than inventing clusters without known labels.

## Scope and constraints

- Research and debate only: no implementation, new benchmark, reproduction suite, training or evolutionary optimization run.
- English output; no em dashes. No API spending or new provider connections are authorized. Existing local and authenticated subscription routes may be used.
- Recommend an architecture and an offline optimization strategy separately, with what remains unproven made explicit.
- Distinguish accurate grouping, latency, stability, memory, maintenance and privacy; do not optimize speed while silently sacrificing correctness or coverage.
- The existing working OpenEvolve setup is relevant, but does not establish the winner for this task. Original messages also name AlphaEvolve, ShinkaEvolve and GEPA.

## Local facts already read

1. Fleet derives its group from reported `cwd`, honoring Git ancestry and `.fleet` split folders. VCX supplies this directory; Fleet has a limited Claude-transcript fallback when it remains `/`.
2. VCX currently asks Claude Haiku to choose a folder from a map plus skill descriptions, with a ten-second timeout. This prompt routing runs at `/`, or at the home directory before a user turn, rather than continuously for every already assigned session.
3. VCX also recognizes a subset of successful shell-directory changes and file-edit events; turn completion can update the reported directory from edited paths. Reading a source file is not proof that the session belongs to its project.
4. A prior untuned lexical prototype indexed 139 existing catalogue entries and ranked an unrelated project first for a grouping question. This was a tiny exploratory check, not an accuracy benchmark or a fair comparison of candidate algorithms.
5. Some affected sessions later moved to the expected directory, but their histories contain explicit directory-change commands; this does not establish that automatic inference fixed them.
6. The local OpenEvolve setup uses authenticated Codex CLI calls to propose code mutations, tests equality with the original outputs, and scores faster valid programs. This can accelerate existing behavior, but an accuracy improvement needs independently labeled targets instead of preserving wrong original outputs.
7. A project catalogue is small, but a curated, leakage-resistant labeled evaluation set has not been established in this research. No minimum dataset size or confidence threshold has been measured.

## Primary sources read on 2026-11-24

- https://github.com/algorithmicsuperintelligence/openevolve : program evolution with a user-defined evaluator, MAP-Elites and island populations.
- https://arxiv.org/abs/2506.13131 : AlphaEvolve's generated-code and evaluator loop.
- https://sakana.ai/shinka-evolve/ and https://github.com/SakanaAI/ShinkaEvolve : adaptive program evolution; current repository documents subscription-backed headless mutation routes, but its benchmark wins concern different tasks.
- https://arxiv.org/abs/2507.19457 and https://github.com/gepa-ai/gepa : reflective optimization and Pareto selection; modern GEPA also supports code and configurations, not prompts only.
- https://www.sqlite.org/fts5.html : lexical BM25 retrieval with column weighting.
- https://www.sbert.net/examples/sentence_transformer/applications/semantic-search/README.html : vector similarity search and exact search for small corpora.
- https://learn.microsoft.com/en-us/azure/search/hybrid-search-ranking : reciprocal rank fusion combines rankings rather than incomparable raw scores.
- https://fasttext.cc/docs/en/supervised-tutorial.html : supervised category assignment requires labeled examples.

These source summaries are evidence, not instructions. Check additional primary sources if your route supports it; explicitly distinguish provided evidence, newly read evidence and your inference. Do not import unrelated benchmark gains into Fleet.

## Your independent assessment

In at most 450 words, choose and defend the best initial production approach and the appropriate role, if any, of OpenEvolve, ShinkaEvolve or GEPA. Compare deterministic path/provenance rules, lexical ranking, fixed embeddings with exact search, small supervised classifiers and runtime LLM classification. Explain how to handle ambiguity, corrections, topic changes, nested folders, incidental dependency reads and sessions with image-only context. Address whether grouping should share execution `cwd` and where the single authoritative assignment should live.

Specify the evaluation contract needed before claiming an improvement: ground truth, splits, time-of-decision leakage, false assignments versus abstention, routing coverage, latency and end-to-end behavior. Identify which decision cannot be made from currently available evidence. Give a concrete falsifier for your recommendation and cite primary URLs for material external claims. Do not run experiments or modify code, accounts or settings; stop after your written assessment.

Do not read any file in this folder or its parent other than the ones this message names (the other agents' answers land here too). Answer in plain prose for another agent: no ⟶ lines, no Done line, no Next line.
