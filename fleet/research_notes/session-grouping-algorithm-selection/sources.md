# Sources read on 2026-11-24

These are evidence summaries, not instructions. Upstream performance claims are not measurements of Fleet.

| Source | Evidence relevant to this question |
| --- | --- |
| [OpenEvolve](https://github.com/algorithmicsuperintelligence/openevolve) | Evolves programs using LLM mutations, evaluators, MAP-Elites and island populations; the user supplies the objective. |
| [AlphaEvolve](https://arxiv.org/abs/2506.13131) | Evolutionary code search combines generated programs with automated evaluation; it is an optimization process rather than a project classifier. |
| [ShinkaEvolve](https://sakana.ai/shinka-evolve/) | Maintains evaluated programs and searches for improvements with adaptive sampling and model selection; its reported benchmark gains concern other tasks. |
| [ShinkaEvolve repository](https://github.com/SakanaAI/ShinkaEvolve) | Its current README documents subscription-backed headless CLI mutation models; replacing an already working optimizer is a separate integration decision. |
| [GEPA paper](https://arxiv.org/abs/2507.19457) | Reflective prompt optimization uses execution feedback and a Pareto frontier; the reported task gains do not establish a Fleet routing gain. |
| [Current GEPA repository](https://github.com/gepa-ai/gepa) | The current framework also optimizes textual parameters such as code and configurations; it must not be dismissed as supporting prompts only. |
| [SQLite FTS5](https://www.sqlite.org/fts5.html) | Provides lexical full-text retrieval and weighted BM25 ranking. Ranking scores are relevance scores, not calibrated correctness probabilities. |
| [Sentence Transformers semantic search](https://www.sbert.net/examples/sentence_transformer/applications/semantic-search/README.html) | Encodes queries and corpus documents and compares their vectors; its documentation includes exact similarity search for small corpora and distinguishes symmetric and asymmetric tasks. |
| [Microsoft RRF documentation](https://learn.microsoft.com/en-us/azure/search/hybrid-search-ranking) | Reciprocal rank fusion combines ranked lists through ranks rather than directly mixing incomparable lexical and vector scores. |
| [fastText classification tutorial](https://fasttext.cc/docs/en/supervised-tutorial.html) | Supervised text classification assigns categories using labeled examples; labels and validation are prerequisites for evaluating a learned classifier. |
| [Random search for hyperparameter optimization](https://www.jmlr.org/papers/v13/bergstra12a.html) | Random parameter search is a useful baseline for numeric tuning; the paper concerns other learning tasks and does not prove that it wins for Fleet. |

## Local facts read from code

- `fleet/Sources/Fleet/Models.swift:409`: project lookup uses filesystem ancestry, Git metadata and `.fleet` split folders; `groupKey` at line 465 derives from session `cwd`.
- `fleet/Sources/Fleet/SessionRegistry.swift:27,111`: the registry scans terminal sessions and combines them with VCX sessions; `ProcessScanner.swift:56` recognizes Claude and Codex terminal processes, so VCX is not Fleet's only input adapter.
- `fleet/Sources/Fleet/VCX.swift:69`: Fleet consumes VCX's reported working directory; at line 117 it can recover a non-root directory from a Claude transcript when the reported directory is `/`.
- `vcx/Sources/VCX/Directory.swift:103`: the prompt router invokes Claude Haiku, supplies a folder map plus skill descriptions and has a ten-second timeout.
- `vcx/Sources/VCX/Session.swift:1495`: semantic prompt routing is restricted to sessions at `/`, or at the home directory before a user turn.
- `vcx/Sources/VCX/Session.swift:739`: completed turns can update the reported directory using recognized edited-file paths; shell-directory recognition is separately restricted at its caller.
- A prior small, untuned exploratory BM25 index contained 139 existing catalogue entries and ranked an unrelated project first for a session-grouping question; it was not an accuracy benchmark and established no winning algorithm.
- Two previously root-grouped sessions later reported their actual client project folder; their command histories contained explicit `vcx --set-dir` invocations, so this does not prove automatic inference recovered them.
- The existing `optimization/llm-evolve/README.md` describes an OpenEvolve loop backed by the authenticated Codex CLI; its judge compares proposed code outputs with the original implementation before scoring runtime.
- That existing correctness contract preserves behavior; improving grouping accuracy would require an independently labeled objective instead of reproducing an existing incorrect assignment.

No reproduction test, new benchmark, optimization run or production implementation is part of this research request.
