# Larger uploads after local workload inspection

The user suggested local Claude Code and Codex transcripts to guide the traffic
shape. Their usage records establish large model contexts, so the small-upload
result warranted larger synthetic request-body checks. Token counts do not give
exact HTTP body lengths; the selected 256 KiB, 1 MiB and 4 MiB requests are broad
sensitivity cases, not reconstructed payload percentiles.

## Upload-buffer result

Using the same curl 8.22.0/OpenSSL 3.6.3 build, six cases compare 64 KiB and 16 KiB
upload buffers at 1,000 concurrent streams. Each body size has one run per
setting, with reversed setting order for the middle size. Only the upload-buffer
setting differs within a pair. The fixture consumes uploaded data through 64 KiB
server read windows instead of retaining the entire request body; its emitted
response and held-open cancellation target follow the prior probe.

| Request body | Peak physical, 64 KiB buffer | Peak physical, 16 KiB buffer | Work interval, 64 / 16 KiB buffers |
| --- | ---: | ---: | ---: |
| 256 KiB | 266.20 MiB | 182.70 MiB | 6.535 / 6.332 s |
| 1 MiB | 249.80 MiB | 166.02 MiB | 8.062 / 8.241 s |
| 4 MiB | 236.16 MiB | 160.75 MiB | 16.663 / 16.741 s |

See [comparison.md](comparison.md) for exact rounded metrics including CPU and
cancellation. All six cases pass: 6,000 operations, 5,994 ordinary successes and
six expected cancellations. Checks include exact advertised upload length read
by the server, concurrent cohorts, response byte counts, cancellation/server EOF,
SQLite integrity, scratch release and descriptor return. Neither upload nor
response payload bytes are compared with an expected buffer. Phase partitions
exactly cover commit-to-removal-plus-cleanup.

The smaller buffer reduces observed peak footprint by 75–84 MiB in all three
pairs. CPU fractions remain close, and observed whole-work times differ by at
most about 3.1%. One run per cell is not a statistical performance-equivalence
claim. The lower peak at larger body sizes does not mean larger requests
intrinsically cost less memory: different upload/handshake timing changes the
population of simultaneous transient allocations. Compare settings within each
pair; do not infer an allocation formula across body sizes.

Together with the three repetitions per setting in the
[small-upload study](../host-transport-simple-memory/README.md), this supports the
documented `CURLOPT_UPLOAD_BUFFERSIZE=16384L` as a simple candidate setting. It
requires no TLS callback, custom allocator or transport redesign. Stop the
optimization search here under the user's stated simplicity preference.
Slow receivers, real WAN conditions and full production integration remain
verification work. These synthetic bodies have no provider semantics, so this
is not a live provider or complete Host certification.

## Local transcript usage distribution

This section and the aggregate JSON remain local; no transcript content or
private usage statistics were published to the issue tracker.

Window: 2026-08-07 08:00 UTC through 2026-09-06 08:00 UTC. The read-only analyzer
scanned recently modified JSONL files in the two local transcript roots, then
filtered records by timestamp. It included subagent files. No message content,
request IDs, session IDs or project paths are written into the aggregate JSON.

| Source | Usage observations | Input p10 | Input median | Input p95 | Input p99 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Claude Code | 174,389 | 74,197 | 168,051 | 337,686 | 360,657 |
| Codex canonical response records | 7,244 | 45,754 | 112,858 | 214,860 | 231,751 |
| Codex legacy cumulative-counter proxy | 9,912 | 34,384 | 92,874 | 202,339 | 224,024 |

These are model-accounted input tokens. Claude sums uncached input, cache writes
and cache reads, without adding the nested cache breakdown again. Codex's input
count already includes cached input. Cache accounting does not prove that bytes
were uploaded, omitted, compressed or reused through continuation references.
The distributions do not measure request framing, exact network bytes, peak
concurrency, transfer timing or chunk sizes.

Claude's median/p95 output is 335/2,243 tokens; canonical Codex's is 198/1,745.
Output tokens also are not streamed SSE or final encoded payload byte counts.
The data shows workload scale, not that a 4 KiB HTTP body is impossible for a
client using server-side continuation.

### Method and limits

`analyze_transcripts.py` uses cclog's raw streaming parser, avoiding model-schema
filtering and writing aggregate statistics only. The source hash is recorded in
`transcript-usage.json`. It scanned 3,031 Claude files and 509 Codex files; 1,974
and 484 respectively contributed retained observations. Those file counts are
not unique session counts. No parse errors were recorded.

Claude records are deduplicated by message ID, falling back to request ID when
needed. Canonical Codex records are deduplicated by response ID, with a compound
fallback. Duplicates retain one actual observed usage tuple, choosing the largest
input then output/cache tuple; fields are never independently combined into an
invented observation. There were 134,860 duplicate records and 25,116 differing
updates across the combined sources. Streaming updates are expected, but every
conflict was not manually audited. This is usage analysis, not billing
reconciliation or proof of a complete network-request census.

For Codex, any file with canonical response records excludes its legacy token
snapshots to avoid double counting; that can omit genuinely older records in a
mixed-format file. Legacy-only files deduplicate populated cumulative counters
within a session/turn and are reported separately as a proxy. Empty cumulative
counters are excluded. Missing/unlogged requests and files outside the two roots
are not captured. The file-mtime prefilter, local availability and a user's own
workload limit representativeness. Percentiles use nearest rank.

Provider field definitions: [Claude prompt caching](https://platform.claude.com/docs/en/build-with-claude/prompt-caching),
[OpenAI token categories](https://help.openai.com/en/articles/4936856-what-are-tokens-and-how-to-count-them).

## Reproduction

```sh
python3 research/host-transport-realistic-uploads/run_tls.py --curl-build /tmp/onepage-stock-curl-qualification/curl-8.22.0
python3 research/host-transport-realistic-uploads/summarize.py
```

The fixed matrix writes `tls-results.json`, recording source and curl archive
hashes/configuration. The inherited `--capacity` flag does not select this
matrix. `--smoke` runs one 10-stream, 256 KiB-request, 16 KiB-buffer case and was
not executed in this pass. Build provenance is the earlier
[candidate metadata](../host-transport-qualification/build-metadata.json).
To rerun transcript analysis, use the local cclog environment's Python with
`analyze_transcripts.py`; it reads the current user's two transcript roots and
writes only `/tmp/onepage-transcript-usage.json`. A new run has a moving 30-day
window and may include newer records. No production code or dependencies changed.
