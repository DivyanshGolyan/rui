# Host ticket — accepted policy package

Prepared 6 September 2026 for [Set Host Runtime admission controls and budgets](https://github.com/DivyanshGolyan/onepage/issues/68).
**Accepted by the user on 6 September 2026.** ARCHITECTURE.md and VERIFICATION.md
own the requirements; this file preserves the package and its rationale. Previously accepted defaults remain: 1,000 shared active operations,
8 GiB logical-byte scratch, and 128 MiB oldest-first diagnostic history.

These are explicit starting policies and verification targets. They are not
numbers inferred from typical traffic, fitted from a speculative component
memory table, or already-certified production behavior.

## Later amendment

[ADR-0027](../adr/0027-use-an-in-process-exact-edit-module.md) replaces Git-based Patch with native in-process exact Edit. The original package below records its accepted resource policies; references to Patch/Git helper costs are historical where superseded. No four-Edit concurrency cap is selected.

## Accepted choices

| Area | Recommendation | Reason and boundary |
| --- | --- | --- |
| Client population | 128 connections total: at most 120 ordinary, with 8 places left for classification/short controls; startup configurable | Supports many simultaneous CLI/script transfers and a small control burst without matching clients to the 1,000 execution population. Accepted work outlives clients. This revisits the earlier unselected 128/8 proposal as a product policy, not a deduction from the withdrawn 4 MiB allocation. |
| Request envelope | 16 KiB total request line/headers; 8 KiB short-control body and 8 KiB acknowledgement/error response | Controls carry bounded identifiers/decisions, not payloads. Exceeding the request bounds rejects explicitly before semantic mutation. Message/configuration/content bodies use their existing streamed/scratch rules; these are not Conversation or model-context quotas. Compiled wire fixtures must prove every supported control fits; revise openly if they do not. |
| Client deadlines | Select the existing 10-second total header deadline and 60-second client-inactivity deadline as initial defaults | No minimum speed, whole-transfer deadline or idle keep-alive. Host processing/backpressure is not client inactivity. Configuration takes effect at startup; no hot-resize protocol. |
| Diagnostic storage | One Host-owned append writer; newline-delimited structured records in at most 16 size-rotated files | Derive each file's maximum from configured total / 16, rounded down; at 128 MiB this gives 8 MiB each, including the active file. Count logical encoded bytes, including framing. Rotate/delete oldest closed files before new bytes would exceed the cap; whole-file deletion is intentionally coarser than individual-record eviction. No compression or diagnostic SQLite database in V1. |
| Diagnostic record size | At most 4 KiB encoded per record, through a fixed window | Preserve mandatory identity/classification fields. Shorten optional text with an explicit omission marker before encoding would exceed the bound. If a valid bounded record cannot be produced, omit it; do not allocate an oversized record then test its length. File size must fit one record; reject incompatible configuration. |
| Detailed capture | Opt-in bounded chunks in the same diagnostic cap, with capture identity/order/completeness markers | No extra payload store or quota. Detail can evict older summaries; make that consequence explicit when enabling it. A rotated/missing chunk makes the capture incomplete, never a falsely complete provider payload. Capture must never bypass the credential exclusion or affect semantic results. |
| Diagnostic failure/restart | Allow a missing crash tail; discard incomplete final records before reusing a segment; no per-record fsync | On write/delete failure, stop or drop diagnostic writes with a bounded notice, not a RAM queue or semantic failure. Do not exceed the cap to preserve new logs. After reducing the configured cap on restart, prune before further writes; failure to prune disables growth rather than pretending the old bytes are gone. |
| Export | Best-effort recent complete records copied in bounded turns into charged scratch, then delivered like a report | Record a cutoff and gaps if rotation removes data before copying. No atomic historical snapshot promise. Close source handles between copy turns so slow consumers never pin deleted diagnostic files; temporary copies count in scratch while retained originals count in diagnostics. If the scratch cap is unavailable, export fails explicitly. |
| Retry poll | One existing eligibility poll every 1 second | An indexed due-time query, bounded processing turns, eligibility revalidation at admission, and no timer per Operation. No queue of missed ticks after sleep. Discovery may take one interval under otherwise idle service; dispatch still waits for capacity/other work. Backoff policy remains with its existing ticket. |
| Scratch/configuration | Load limits at Host startup; preserve accepted logical accounting and failure rules | No hot quota changes, free-space-percentage tuner or emergency scratch pool. Full scratch can reject incomplete ingress/report/export and fail already-admitted work under its existing rules; ready small controls do not require execution credit or content scratch. Metadata-growth failure must fail/settle affected work rather than wait indefinitely while retaining the full quota. Canonical SQLite may still fail independently on the same volume. |

## Accepted verification targets, not runtime admission counters

- **256 MiB total OnePage-owned process physical footprint** at the planned
  1,000-operation qualification population, including OnePage-owned helpers and
  evaluator, across defined model/Bash/Patch/mixed fixtures. This is an engineering
  goal, not a demonstrated result or a guarantee for arbitrary workloads. The
  optimized model fixture's largest recent peak was about 183 MiB; that motivates
  testing the total but does not price real tool helpers. No per-component or
  invented per-worker allocation is imposed. If actual necessary work misses,
  review measured costs and the target/default explicitly before release.
- Apply the same total bound to cold and retained idle for now; record both
  separately and require stable retained memory across repeated churn and no
  resident growth merely from dormant/history counts. Do not invent separate
  cold/idle partitions without a reason. Freed allocations need not return pages
  immediately. No custom allocator or RSS-triggered cancellation follows.
- **Idle CPU below 1% of one core**, including the one-second retry poll, on the
  reference laptop. **At most two core-seconds per wall second on average** for
  the existing model-stream reference load at 1,000 streams (100 small SSE events
  per second per stream, short request and bounded terminal burst), excluding
  fixture-server CPU. Record tool/mixed CPU separately because it depends on
  useful filesystem work; do not impose a universal active CPU admission limit.
- **p95 durable control acknowledgement within 1 second** in the defined saturated
  qualification workloads, including inspection/capture contention. Report max
  observed delay and physical cleanup separately. This is not a hard real-time
  promise, a provider billing-cutoff guarantee, or a tool-termination deadline.
  The existing non-preemptible capture/import rules remain. A workload that misses
  triggers review with the query-work owner; do not hide capture time from latency.
- **Retry discovery within 2 seconds of due time** when capacity is free and the
  Host is otherwise lightly loaded. Separate query lateness from admission/effect
  launch and measure the full-capacity case without promising immediate dispatch.

Measure RSS, per-process physical footprint, kernel/socket resources and filesystem
cache separately. Summing process footprints may count shared mappings more than
once; label the reported aggregate. Workload processes chosen by model Bash
remain separate; helpers OnePage invokes to implement Patch do not disappear
from its accounting. The artificial worker benchmark is not cost evidence.

## Engineering completion obligations, not more user preference questions

For every existing owner, list its concurrently held files/descriptors/handles,
release points and fixed workspace. Cover outbound request plus output overlap,
Bash stdout/stderr, Patch temporary files and helpers, parser metadata, one report
per client, export capture and diagnostic segments. Prove that empty scratch files
cannot accumulate independently of those populations; byte caps alone are not
sufficient. Any newly found unbounded owner must be resolved before closing this
ticket. Exact ABI struct sizes and library/process descriptor counts are derived
from the selected implementation, not guessed numeric pools.

Keep one existing owner per file, shared logical accounting, bounded service turns
and deterministic overload results. Complete startup resource validation and
representative execution traces against these owners before claiming the finite
matrix is ready. Full implementation certification happens later. Accepting this
package does not automatically close the ticket before that bookkeeping is done,
or silently waive the matrix gate. SQLite/evaluator internal settings and provider
retry/effect policy stay with their existing decision owners.

## Research

The [primary-source note](../research/host-policy-final-priors.md) supports ordinary
size rotation and indexed polling, and identifies hard-cap/descriptor pitfalls.
Its sources do not dictate OnePage's numeric defaults. No new benchmark was run
for this recommendation round. Historical probes retain their original limits.
