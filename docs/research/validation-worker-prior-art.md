# Validation work outside the decision loop

## Subsequent decision — 10 September 2026

The subsequent [transactional-operation decision](../design/transactional-operations.md) selects sequential complete validation with bounded memory as the baseline. This worker comparison remains research; it does not select a thread, pool or manually yielding parser.

Research date: 2026-09-08. Prior-art evidence and architectural inferences only; no selected architecture, dependency, or runtime verification.

## What the prior art establishes

Node.js explicitly distinguishes two ways to keep its event loop responsive: partition a calculation so it yields between pieces, or move the calculation to another worker. Partitioning retains intermediate state and reschedules continuation. Offloading introduces communication and resource costs. Its guide also notes that partitioning itself adds overhead and opportunities for mistakes. Long jobs can occupy all available workers, so offloading alone does not guarantee fair progress. This is evidence for a tradeoff, not a requirement to build a general worker pool. [Node.js guide, complex calculations and avoiding task partitioning](https://nodejs.org/learn/asynchronous-work/dont-block-the-event-loop)

libuv provides a concrete interface: `uv_queue_work` runs a work callback on a worker and reports completion through an after-work callback on the originating event-loop thread. Its built-in pool is global, shared with filesystem and DNS work, and has a configurable size. Those defaults carry contention and memory implications; adopting the interface idea does not imply adopting libuv's pool. [libuv work scheduling](https://docs.libuv.org/en/v1.x/threadpool.html)

For `uv_work_t`, `uv_cancel` cancels pending work but fails once work has started or finished. Even successful cancellation still produces a later callback, and request memory must remain valid until that callback. It cannot forcibly interrupt arbitrary running parser code. [libuv request cancellation](https://docs.libuv.org/en/v1.x/request.html)

## Candidate division for OnePage

The following is an inference to evaluate, not a claim about current OnePage implementation:

| Decision owner | Validation owner |
| --- | --- |
| Orders commands, cancellation, and result publication | Reads a sealed input and validates its contents |
| Owns authoritative Session state | Owns its file descriptors, parsing buffers, and private output |
| Receives a small completion record | Returns an output reference or error |
| Decides whether completion may be published | Does not write the Session outcome itself |

One bounded validation worker is a useful minimal candidate. Its parser can run an ordinary streaming loop with bounded buffers. It need not return to the decision loop after each buffer. Pending work must also be bounded; waiting jobs should remain discoverable from storage instead of accumulating an unrestricted in-memory queue. This adds a handoff and a lifetime boundary while potentially removing scheduler-specific parser continuation machinery.

It does not remove all incremental state: a streaming parser still tracks its location and nesting between reads. The simplification is keeping that state inside one ordinary execution, rather than exposing a resumable parsing job to the scheduler.

## Cancellation and limits

The decision owner can stop accepting a validation result immediately. It cannot then free buffers or scratch still used by a running worker. Release those resources, and the occupied worker capacity, only after execution actually ends. An ordinary cancellation flag checked between reads can shorten cleanup; hard interruption requires a different mechanism and justification.

A single worker keeps controls responsive but a large validation delays smaller validations. A resumable parser can interleave those jobs, at the cost of scheduling state. Neither choice solves a slow SQLite commit or unbounded final import automatically. Measure those paths separately before claiming bounded control latency.

The useful next comparison is one representative large response validated by an ordinary worker loop versus a resumable parser: compare code needed to explain ownership, retained memory, cancellation cleanup, and control response time. No need to prescribe per-request threads or a generic task framework first.
