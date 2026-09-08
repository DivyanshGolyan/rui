# Initial timing observations — 7 September 2026

Three synthetic requests to Codex using `gpt-6-astra` with `high` reasoning effort reached `response.completed`. No automatic retries were used. The reasoning and longer-answer requests ran concurrently.

| Case | First body chunk | Longest gap between body chunks | Total duration | Body reads |
| --- | ---: | ---: | ---: | ---: |
| [short](results/2026-09-07-short-observe.jsonl) | 0.97 s | 1.32 s | 2.55 s | 10 |
| [reasoning](results/2026-09-07-reasoning.jsonl) | 1.23 s | 5.90 s | 13.65 s | 104 |
| [longer](results/2026-09-07-longer.jsonl) | 1.28 s | 21.16 s | 77.23 s | 889 |

A 60-second response-body inactivity timer would not have interrupted any of these three observed traces. The longest observed gap was 21.16 seconds. This is preliminary evidence only: three synthetic requests cannot establish the tail of the distribution or qualify extended reasoning, long context, compaction, load, outages, or Claude. The longest request lasted 77 seconds, so this did not exercise a response lasting more than five minutes.

The first two short-request attempts were closed after headers because the endpoint omitted Content-Type. Their files are retained as probe setup observations, excluded from successful-stream statistics. The corrected probe accepts an omitted header but requires a terminal SSE event; all three successful observations also had no Content-Type header. No claim is made about whether the provider continued processing the early-closed requests.

Five local HTTP scenarios checked timing with deliberate delays, heartbeat traffic, a fragmented completion event and CRLF, an explicit failed event, missing completion, wrong response type, and HTTP rejection. The emitted records were checked to exclude sentinel response text. This validates the measurement harness, not production timeout enforcement.

No response text or credentials were saved in the measurement files. See [probe scope and limitations](README.md). No OnePage production source, accepted timeout policy, or Claude setup was changed. The 60-second proposal remains unverified for production.
