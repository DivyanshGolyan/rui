# Inspection and stop responsiveness

Throwaway native measurement, 5 September 2026. This exercises a synthetic single SQLite owner and independent I/O reactor; it is not OnePage's unimplemented Run API, canonical query set, or cancellation-set traversal.

## Question

Does small, bounded working memory also keep control commands responsive while complete inspection reports are captured? Does choosing a waiting control command before another queued inspection materially help?

## Method

One main thread owns the pinned SQLite connection, using DELETE journaling, EXTRA synchronous mode, a 64 KiB suggested cache, disabled mmap, and the repository's SQLite compile flags. It joins an indexed membership-like relation to precomputed status rows in private batches of 100 and formats each record into bounded buffers. Each report holds one read transaction until its complete data has been written to unlinked scratch; response delivery is omitted.

A producer sends 1 KiB every 10 ms to each of 99 local socket pairs at capacity 100. A real owned shell process emits lines through a pipe and runs a short sleep between writes. A separate poll-based reactor drains all streams to separate unlinked spools through a fixed 4 KiB window. Capacity 10 uses nine fake model streams plus one shell. The shell must produce output before measurement begins.

Four inspection commands are treated as already queued. An independent client thread requests cancellation about 1 ms after the first capture begins; its actual request time is recorded. Two synthetic owner policies are compared:

- **FIFO:** finish all four queued reports before handling the later control command.
- **Control first between captures:** finish the current report, then handle the waiting control command before starting another report.

The latter leaves remaining reports pending during the measured interval; this experiment does not establish fairness for sustained control traffic. It does not interrupt a capture or weaken its snapshot. There is no proposed new queue subsystem here.

The owner writes a small cancellation-intent fixture transaction and commits it before signalling the reactor. The reactor closes the fake-stream read ends and requests process-group interruption of its shell. Request-to-commit measures acknowledgement; request-to-last-close/signal measures dispatch of interruption, not Session settlement. EOF/drain timing excludes final spool closure and does not prove application effects ceased.

Five observations per policy and size; policy order alternates. The machine is a shared Apple M1 Pro MacBookPro18,1, macOS 15.7.7, with 16 GiB RAM and clang 17. No other experiment compilation/timing overlapped the final timing matrix. Other user/OS work remained active; raw system load is recorded. No CPU pinning, thermal control, or filesystem-cache purge. These are observed medians/maxima, not p99 or worst-case guarantees.

## Results

Stop acknowledgement, milliseconds; each cell is **median / observed maximum**. Capacity is 100. Row counts and widths are synthetic sensitivity inputs, not product quotas or proposed wire fields.

| Records per report | Binding bytes per record | FIFO, four reports | Control first between reports |
| ---: | ---: | ---: | ---: |
| 1,000 | 128 | 2.66 / 2.95 | 1.04 / 1.88 |
| 10,000 | 128 | 26.11 / 32.04 | 5.29 / 7.65 |
| 100,000 | 128 | 227.24 / 293.17 | 52.22 / 72.82 |
| 100,000 | 1024 | 1316.65 / 1658.52 | 346.52 / 361.41 |

With no inspection, median acknowledgement was 0.75 ms. One million ordinary-width records in a single report produced 589.85 ms median acknowledgement delay (observed maximum 824.99 ms). That case has no backlog for scheduling to bypass.

Each final non-baseline sample recorded the request arriving inside a capture. The reactor continued draining concurrently in the larger cases. The largest observed interval from committed intent to dispatching all interruption requests was 1.941 ms. This supports attributing most measured delay to waiting for the owner/capture, not delayed model-stream teardown. Reactor gap values include warmup and scheduling, and are labeled accordingly in raw output.

Ordinary reports were about 1.92 MB at 10,000 records and 19.43 MB at 100,000; the wide 100,000-record report was about 109.03 MB. The million-record report was about 196.28 MB. The shape differs from the earlier capture probe, so absolute times should not be directly substituted into that report.

## Interpretation

A small memory footprint does not establish short command latency. Letting a ready control command proceed before another queued capture helps substantially, but cannot eliminate the pause from one complete capture already in progress. Constant-time slot scanning cannot fix this serialization cost.

Keep the simple single-connection starting point for ordinary report sizes. Carry the scheduling result and per-capture delay into the existing query/capture budget decision. Do not infer a record cap, silently truncate reports, choose WAL, add a reader connection, or create a snapshot service from these measurements alone. The acceptable maximum interruption delay remains a product/resource decision; the real query and encoder must be measured before release.

## Verification and boundaries

The final normal matrix contains 60 successful runs. Checks enforce exact row ordering/counts, zero SQLite full-scan steps/sorts for this query shape, completed transactions before control admission, monotonic request/commit/interruption timestamps, real shell startup and reaping, and equality between bytes drained and scratch length. Every non-baseline request overlapped a capture. No shell needed escalation in the final normal matrix.

Two additional sanitized measurements exercised both scheduling choices, plus SIGABRT/SIGTERM emergency-cleanup controls. The controls verify removal of the exact owned shell process group. An earlier sanitizer run exposed an emergency-cleanup race in the probe: shell EOF could reach the reactor while its parent was deliberately terminating, before normal cancellation was published. The probe now distinguishes emergency shutdown, and the rerun passed. This was a harness defect, not a OnePage runtime finding. Leak detection is disabled; no leak certification is claimed.

Heap and physical-footprint endpoints are recorded, but this is not a peak-RSS or whole-system memory study. Kernel buffers, filesystem cache, allocator retention, imported model output, provider/TLS behavior, concurrent Patch execution, actual derived status queries, JSON escaping, HTTP clients, slow report delivery, durable cancellation traversal, and sustained fairness are not represented. No paid LLM calls or application Stores are used. A watchdog terminates the probe through its child-cleanup handler on timeout.

## Reproduce

```sh
python3 research/execution-control-experiments/run_inspection.py
ASAN_OPTIONS=detect_leaks=0 python3 research/execution-control-experiments/run_inspection.py --sanitize --smoke --repeats 1 --output research/execution-control-experiments/inspection-sanitizer-results.json
```

Raw results: [normal matrix](inspection-results.json), [sanitizer checks](inspection-sanitizer-results.json). Source: [inspection.c](inspection.c), [runner](run_inspection.py), [pinned SQLite builder](build_native.py). All scratch databases, spools, executables, and owned child processes are temporary.
