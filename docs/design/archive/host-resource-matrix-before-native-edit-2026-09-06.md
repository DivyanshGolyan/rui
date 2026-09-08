> Historical accounting: superseded by the native Edit decision. Values and proposals below are not a current complete matrix.

> Updated decision: [ADR-0027](../../adr/0027-use-an-in-process-exact-edit-module.md) selects native in-process exact Edit. The Git-based layout and memory conflict below are historical, not the current executor topology. The matrix remains incomplete pending the search-text bound and aligned Edit owner accounting; do not add the proposed four-Patch cap.

# Host resource accounting — design input

6 September 2026. For [Set Host Runtime admission controls and budgets](https://github.com/DivyanshGolyan/onepage/issues/68), feeding [Approve the minimal V1 limit matrix and removal sequence](https://github.com/DivyanshGolyan/onepage/issues/89). Accepted values come from the [policy package](../host-final-recommendations.md) and ARCHITECTURE.md. This is not an approved complete matrix or production qualification.

## Accepted controls and targets

| Owner / protected resource | Population and value | Release / overload | Evidence required |
| --- | --- | --- | --- |
| Host / physical execution | Shared startup C=1,000 default; model+Bash+Patch+cleanup custody <= C | Safe cleanup returns the record. Full capacity waits in SQLite without Attempt/resource admission. | Exact occupancy, cancellation cleanup, mixed load and startup OS requirements. |
| Scratch owners / temporary disk | Shared B=8 GiB logical bytes; pending growth reservations included | Refund unused growth; final safe close releases unlinked files. Named Patch trees retain full reservation until removal. Known pre-admission exhaustion waits; later exhaustion fails safely. | Growth/partial/error/truncation/overflow tests, empty-file populations, restart cleanup, no RAM fallback. |
| Local adapter / connections | L=128 total; O<=120 ordinary, 8 classification/control headroom | One exchange then close. Full ordinary population cannot occupy control headroom. | Concurrent controls, slow peers, connection churn, no detached response backlog. |
| Local adapter / wire materialization | Headers including request line <=16 KiB; short control request and ack/error <=8 KiB | Reject oversized requests before mutation. Stream ordinary content under scratch rules. | Compiled fixtures with maximal supported identities, escaping and errors. |
| Local adapter / stalled peers | 10 s total headers; 60 s client transfer inactivity | Close stalled exchange; preserve committed work and submission uncertainty. Host work/backpressure excluded. | Trickle/timeout attribution, stalled controls, healthy long transfer. |
| Diagnostic writer / recent history | 128 MiB default; <=16 files including active; floor(cap/16) each; <=4 KiB encoded record | Delete oldest closed segments before growth. Drop/stop diagnostics on failure. | Boundary rotation, incomplete tails, failure and restart with smaller cap. |
| Diagnostic detail/export | Detail shares history cap; export belongs to ordinary exchange, copies charged to scratch | Missing chunks/gaps explicit; close source handles between copy turns; scratch-full export fails. | No pinned archives under slow delivery, bounded memory and no semantic dependence. |
| Host / retry discovery | One indexed bounded poll every 1 s; no per-operation timer | Revalidate on admission; no missed-tick backlog or busy full-capacity loop. | <=2 s discovery when light/free; no immediate dispatch promise at saturation. |
| Whole OnePage / memory | Accepted <=256 MiB target in defined 1,000-operation model/Bash/Patch/mixed fixtures; same idle ceiling plus churn stability | Qualification miss requires explicit review, not an RSS admission controller. | Include Git/evaluator/other OnePage helpers; separate model-selected workload, RSS, physical footprint and kernel/cache. **Feasibility conflict below.** |
| Host / CPU and control latency | Idle <1% one core; model reference <=2 cores average; p95 durable controls <=1 s under defined saturation | Targets, not new scheduling counters or hard real-time guarantees. | Include capture contention; report maximum delay/cleanup and separate useful tool CPU. |

All configuration changes apply at startup. Canonical SQLite is a separate storage lifetime and failure authority; its internal limits belong to the SQLite decision. Evaluator containment and effect-size/retry policy belong to their existing decision owners, with their real costs included here.

## Concrete file-container layout recommended for implementation

These are finite owner shapes to complete the matrix, not source behavior already implemented. Files are opened on demand; a maximum does not preallocate file handles or data.

| Owner | Maximum temporary content containers | Overlap / lifetime |
| --- | ---: | --- |
| Model execution | 2 | One outbound request and one captured response; both may coexist through settlement. |
| Bash execution | 3 | One materialized input/descriptor if needed, plus separate stdout and stderr capture files. Two stream files avoid inventing an indexed capture format. |
| Patch execution | 4 | One materialized input/descriptor, up to two helper-output captures, and one named snapshot/replacement. Sequential Git phases reuse/release these containers; no one-container-per-helper-call accumulation. |
| Shared serial validation/import | 1 | One scratch metadata container, borrowed by the current import; output remains charged to execution owner. Append metadata records, not one file per parsed item. |
| Ordinary client exchange | 2 | At most one ingress and one response container, allowing transition overlap. Report and diagnostic export use the same response role, not separate retained responses. |
| Protected short control | 0 | Fixed bounded request/reply state; no content scratch required. |
| Diagnostics | 16 persistent segments | Separate from scratch; one writer and at most one source handle during a serial export-copy turn. |

For M model, H Bash and P Patch custodians with M+H+P<=C, the content-file ceiling for this shape is:

`2M + 3H + 4P + 1 + 2O <= 4C + 1 + 2O`.

At accepted defaults this is **4,241 temporary content files**, plus at most 16 retained diagnostic segments. This is a conservative file-count ceiling, not expected occupancy, FD count, disk preallocation or resident memory. Empty files obey the same population bound. Fixed Store files, sockets and lock files are separate. Patch has at most P private trees; parent directories are bounded by the admitted target-path length/depth from the syntax owner. Streaming cleanup must not retain a directory listing proportional to history. No new independent file quota or pool is needed.

This shape deliberately permits fewer actual files and earlier release. Any implementation needing additional simultaneously live files must update the owner derivation rather than bypass it.

## Descriptor derivation and startup validation

Descriptors are not the same thing as content files. Compute requirements from the chosen implementation before enabling a configuration:

- Host baseline: standard I/O, Store/SQLite handles including selected journal/spill behavior, Store and scratch locks, listener, reactor/wake handles, and bounded credential/config access.
- Client contribution: at most L sockets plus descriptors for the <=2O content containers. No keep-alive/pipelining population outside L.
- Model contribution: request/response handles plus the selected transport's connection, resolver and wake requirements. Bound retained connection resources to the configured execution population; qualify the selected curl build, not a guessed socket-per-operation multiplier.
- Bash contribution: captured-content handles, stdout/stderr pipe ends, optional input delivery, process supervision and any transient spawn overlap.
- Patch contribution: input/capture/snapshot handles, live target and bounded directory traversal handles, helper pipe ends and temporary executor supervision. Each active helper inherits one reference to the same scratch lock; this adds a descriptor in that helper, not another Host lock file or independent lock.
- Shared contribution: one metadata handle, active diagnostic writer and transient export source. Evaluator contributes its selected pipes/process handles under its own bound.

Use checked arithmetic, include both ends briefly held during spawn, close-on-exec discipline and the actual per-process OS descriptor limit. Failure rejects startup/configuration explicitly; do not infer supported C merely from RAM or allocate a separate descriptor credit pool. Exact library/ABI constants require the selected implementation and supported build. This is a derivation obligation, not a claim that a complete numeric FD total is already known.

## Honest executor-memory feasibility

Intended topology: Bash uses reactor-driven process supervision and disk capture; Patch uses temporary execution machinery and sequential Git phases per active Patch, with no permanent worker or shared serial Patch lane. Git's heap and line metadata are OnePage-owned cost, not model-selected Bash workload.

The measured one-file fixture (1,000,004-byte source, 75-byte patch, 500,000 short lines) used 12,026,752 and 13,222,784 bytes peak Git physical footprint on the two tested builds. For orientation, multiplying those single-process observations by 1,000 yields about **11.2–12.3 GiB**. That is an arithmetic estimate, not a concurrent benchmark: peak overlap, shared pages and process aggregation matter. It nevertheless makes 1,000 overlapping helpers at a 256 MiB aggregate target implausible. Even many fewer helpers consume a material part of that target before transport, SQLite and evaluator costs.

The previous claim that only mechanical bookkeeping remained was too optimistic. An explicit policy/implementation decision is still needed to reconcile:

1. the accepted shared 1,000 active-operation default;
2. the accepted 256 MiB whole-OnePage qualification target across tool-heavy fixtures;
3. temporary per-Patch Git execution with no extra concurrency bound.

Do not certify the combination by selecting tiny patches, staggering helpers invisibly, treating OnePage's Git as excluded workload, or calling the synthetic worker-stack probe a real cost. No new helper pool, lower shared default or higher memory target is selected by this accounting document.

The smallest alternatives for the user to evaluate are a separate bound on simultaneous expensive helper phases while retaining the 1,000 overall ceiling, a lower shared default, or a revised workload-specific memory target. Each changes a previously accepted policy and must be explicit. This is the remaining Host decision; exact production performance follows later.

## Evidence and status

[Patch probe](https://github.com/DivyanshGolyan/onepage/issues/68#issuecomment-5559278325), [accepted scratch mechanism](https://github.com/DivyanshGolyan/onepage/issues/68#issuecomment-5559463730), and [accepted Host package](https://github.com/DivyanshGolyan/onepage/issues/68#issuecomment-5559200690). Local prototype commits `7867015` and `71d89a7` retain code, raw results and limitations.

The owner/file table is complete as a proposed finite implementation shape, but the Host ticket and combined matrix must remain open until the executor-memory conflict is resolved. No production source changed and no new benchmark was run for this accounting pass.

## Native Edit accounting amendment

Edit adds no per-edit process, dedicated stack, Git pipe set or named snapshot tree for matching/application. Preparation holds an owned source snapshot and a separate prepared output; decoded search/replacement input containers also count if scratch-backed. Each remains charged through its actual owner lifetime. The 16 KiB reusable I/O window is not a complete per-edit bound: search text and overlap storage, continuation state, hashing and target access are additional. Their selected maxima and actual concurrency still need a finite derivation. Any retained Git-based target-eligibility check counts until explicitly removed or replaced by its owning decision. Do not use a standalone executable's baseline as the incremental cost of an in-process Edit.
