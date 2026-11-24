# Connected roster checked on 2026-11-24

No provider was installed, connected or switched to API billing for this research. Each route received a short connectivity prompt and its assistant answer was checked; HTTP success alone was not accepted.

| Requested provider/model | Route | Connection result | Responding identity and limitation |
| --- | --- | --- | --- |
| Claude configured default | Authenticated Claude CLI | Unavailable: usage-limit error, no assistant answer | No responding model; excluded |
| OpenAI gpt-6.1-sol | Authenticated Codex CLI, explicit configured-model flag | READY assistant answer, successful exit | Codex route; the JSON probe did not expose a separately resolved server-model identifier, so gpt-6.1-sol is the requested configured model |
| Google gemini-3.8-flash-high | Authenticated Antigravity CLI, explicit configured-model flag | READY assistant answer, SUCCESS status | Antigravity route; configured Gemini 3.8 Flash High, no separate resolved-model field in its response |
| Google Gemini web default | Existing authenticated web adapter | READY assistant answer | Gemini product route; exact backend model version undisclosed |
| Alibaba qwen3.5-9b-abl | Current configured local Ollama endpoint through its configured proxy | AVAILABLE assistant answer, no provider error | Response metadata explicitly reports qwen3.5-9b-abl |
| xAI Grok web default | Existing authenticated web adapter | Unavailable: provider usage-limit response, no answer | Excluded |
| Meta Muse web default | Existing authenticated web adapter | READY assistant answer | Muse product route; exact backend model version undisclosed |
| Meta AI web default | Existing authenticated web adapter | READY assistant answer | Meta AI product route; exact backend model version undisclosed |

Gemini CLI and Gemini web share Google; Muse and Meta AI share Meta. These pairs are not independent-provider confirmations. The moderator is not an additional reviewer. Unknown resolved model versions remain unknown rather than being inferred from an assistant's self-description.

The first Qwen request reached its endpoint but a bytes-to-text mistake prevented the probe harness from saving the reply; a separate corrected connectivity probe verified the response metadata and assistant answer. No research response was retried blind.

## Research-round outcomes

All six available routes completed blind assessment and cross-examination. Codex, Antigravity Gemini, local Qwen, Gemini web and Muse completed final sign-off on K1 through K6. Meta AI's final-sign-off adapter exited with status 1: `ask-web: Meta AI did not finish answering within 10 minutes`. No final answer was saved and no retry was made; its two completed rounds remain archived. Claude and Grok remain failed connectivity legs, not silent agreements.
