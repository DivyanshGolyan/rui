# Host resource accounting — design input

6 September 2026. For [Set Host Runtime admission controls and budgets](https://github.com/DivyanshGolyan/onepage/issues/68), feeding [Approve the minimal V1 limit matrix and removal sequence](https://github.com/DivyanshGolyan/onepage/issues/89). Accepted values come from the [policy package](host-final-recommendations.md) and ARCHITECTURE.md. Updated 8 September 2026: the Host policy and owner coverage are settled; the combined [V1 limit matrix](../../ARCHITECTURE.md#v1-limit-matrix) now consolidates these accepted policies. This is not a complete numeric implementation total or production qualification.

## Accepted controls and targets

| Owner / protected resource | Population and value | Release / overload | Evidence required |
| --- | --- | --- | --- |
| Host / physical execution | Shared startup C=1,000 default; model+Bash+Edit preparation/execution+cleanup custody <= C | Safe cleanup returns the record. Full capacity waits in SQLite without Attempt/resource admission. | Exact occupancy, cancellation cleanup, mixed load and startup OS requirements. |
| Scratch owners / temporary disk | Shared B=8 GiB of Host-owned logical bytes and retained-name spillover charges; pending Host growth reservations included; external spillover mutation/retention excluded | Refund unused growth; safe release returns charges. Reclaim oldest eligible optional retained files first; protected files remain. Remaining pre-admission exhaustion waits; later exhaustion fails safely. | Growth/partial/error/truncation/overflow tests, external-reader exception, retained/empty-file populations, restart cleanup, no RAM fallback or all-process disk-cap claim. |
| Local adapter / connections | L=128 total; O<=120 ordinary, 8 classification/control headroom | One exchange then close. Full ordinary population cannot occupy control headroom. | Concurrent controls, slow peers, connection churn, no detached response backlog. |
| Local adapter / wire materialization | Headers including request line <=16 KiB; short control request and ack/error <=8 KiB | Reject oversized requests before mutation. Stream ordinary content under scratch rules. | Compiled fixtures with maximal supported identities, escaping and errors. |
| Local adapter / stalled peers | 10 s total headers; 60 s client transfer inactivity | Close stalled exchange; preserve committed work and submission uncertainty. Host work/backpressure excluded. | Trickle/timeout attribution, stalled controls, healthy long transfer. |
| Diagnostic writer / recent history | 128 MiB default; <=16 files including active; floor(cap/16) each; <=4 KiB encoded record | Delete oldest closed segments before growth. Drop/stop diagnostics on failure. | Boundary rotation, incomplete tails, failure and restart with smaller cap. |
| Diagnostic detail/export | Detail shares history cap; export belongs to ordinary exchange, copies charged to scratch | Missing chunks/gaps explicit; close source handles between copy turns; scratch-full export fails. | No pinned archives under slow delivery, bounded memory and no semantic dependence. |
| Host / retry discovery | One indexed bounded poll every 1 s; no per-operation timer | Revalidate on admission; no missed-tick backlog or busy full-capacity loop. | <=2 s discovery when light/free; no immediate dispatch promise at saturation. |
| Whole OnePage / memory | Accepted <=256 MiB target in defined 1,000-operation model/Bash/Edit/mixed fixtures; same idle ceiling plus churn stability | Qualification miss requires explicit review, not an RSS admission controller. | Include evaluator and any retained OnePage helpers; separate model-selected workload, RSS, physical footprint and kernel/cache. |
| Host / CPU and control latency | Idle <1% one core; model reference <=2 cores average; p95 durable controls <=1 s under defined saturation | Targets, not new scheduling counters or hard real-time guarantees. | Include capture contention; report maximum delay/cleanup and separate useful tool CPU. |

All configuration changes apply at startup. Canonical SQLite is a separate storage lifetime and failure authority; its internal limits belong to the SQLite decision. Evaluator containment and effect-size/retry policy belong to their existing decision owners, with their real costs included here.

## Owner layouts and derived file accounting

Allocate on demand; release files with no later consumer at the end of actual use. Optional retained spillover follows the shared FIFO policy, remains charged, and releases its execution slot after safe ownership transfer. Waiting Operations retain durable facts, not per-waiter buffers or scratch. A content reference already in SQLite is not another materialized file.

| Owner | Scratch containers derived from accepted layout | Lifetime |
| --- | ---: | --- |
| Model execution | 2 — derived from accepted layout | Outbound request and captured response, including settlement overlap. |
| Bash execution | 3 — derived from accepted layout | Optional materialized input, stdout and stderr; release after safe capture/import cleanup or transfer retained output to shared FIFO ownership. |
| Edit preparation/execution | 3 — derived from accepted layout | At most one materialized argument container, one sealed source snapshot and one prepared output. Represent decoded fields as ranges in the argument container; do not create a file per field. Stream replacement content. |
| Shared serial validation/import | 1 — derived from accepted layout | Metadata for the current import; release with its sources. |
| Ordinary client exchange | 2 — derived from accepted layout | Ingress and response, including transition overlap. Reports and diagnostic exports share the response role. |
| Protected short control | 0 | Existing bounded request/reply state. |
| Diagnostics | 16 persistent segments | Separate from scratch; bounded writer/export handles. |

For M model, H Bash and E Edit custodians, M+H+E<=C, these accepted execution/client/import layouts give `2M + 3H + 3E + 1 + 2O <= 3C + 1 + 2O`: **3,241 scratch containers** at the accepted defaults. This is the derived subtotal for these scratch content roles, not an FD count, preallocation or separately enforced file quota. Fixed Store files and retained diagnostics are separate. Retained spillover is also outside this active-execution subtotal; include its metadata/files/handles under the shared temporary budget before claiming a complete Host population bound. The single evaluator lifecycle adds its input/snapshot preparation, output capture and publication/cleanup overlap outside this subtotal. Complete provider integration must account for any additional required materialization. Neither evaluator files nor retained spillover may be omitted from a final total.

**Accepted preparation ownership:** pre-authorization Edit preparation occupies the same shared capacity as execution; E includes these preparation custodians. Persist exact intent and required immutable inputs, then release scratch, buffers and custody before waiting for permission. Approved work reacquires capacity to reconstruct and revalidate that intent before application. No additional preparation population is added to the formula and no second preparation pool is introduced. The three-role Edit layout above is separately accepted. Preparation has no Attempt or Dispatch Permit and cannot mutate the target.

Any additional materialization or overlapping phase must appear in this derivation. File counts describe the implementation shape for sizing and leak verification; do not add per-tool file counters, admission checks, configurable quotas or fourth-file rejection. Enforce aggregate bytes in the shared scratch owner. Ordinary unlinked scratch replaces the old Git trees and helper captures; no independent file quota or buffer pool is proposed.

## Descriptor derivation and startup validation

Descriptors are not the same thing as content files. Compute requirements from the chosen implementation before enabling a configuration:

- Host baseline: standard I/O, Store/SQLite handles including selected journal/spill behavior, Store and scratch locks, listener, reactor/wake handles, and bounded credential/config access.
- Client contribution: at most L sockets plus descriptors for the <=2O content containers. No keep-alive/pipelining population outside L.
- Model contribution: request/response handles plus the selected transport's connection, resolver and wake requirements. Bound retained connection resources to the configured execution population; qualify the selected curl build, not a guessed socket-per-operation multiplier.
- Bash contribution: captured-content handles, stdout/stderr pipe ends, optional input delivery, process supervision and any transient spawn overlap.
- Edit contribution: up to three scratch handles for the accepted Edit layout, live target and bounded directory traversal handles, including pre-authorization preparation under the same E population. Matching/application needs no helper pipes, process supervision or inherited Git scratch lock. The accepted file-access amendment removes the Git eligibility helper; production source still needs that replacement.
- Shared contribution: one metadata handle, active diagnostic writer and transient export source. The one evaluator lifecycle contributes its three stdio pipes, narrowly inherited read-only input descriptors, parent scratch/output handles, process supervision and transient spawn overlap. Count shared underlying files once as containers and each simultaneously open descriptor separately.

Use checked arithmetic, include both ends briefly held during spawn, close-on-exec discipline and the actual per-process OS descriptor limit. Failure rejects startup/configuration explicitly; do not infer supported C merely from RAM or allocate a separate descriptor credit pool. Exact library/ABI constants require the selected implementation and supported build. This is a derivation obligation, not a claim that a complete numeric FD total is already known.

## Native Edit memory accounting

The accepted scan/copy window is W=16,384 bytes. For the tested reused-buffer implementation and N bytes of nonempty search text, the named peak heap allocation is:

`N + max(W, N) + N - 1` bytes.

This includes the resident search text and the scan window with overlap. Copying reuses the scan allocation and releases the search text first; do not add another copy buffer. Two hash contexts add 208 bytes on the tested build. Continuation state, target/path state, allocator overhead, decoding, Host custody and shared runtime costs remain additional. Whole source and replacement lengths do not multiply this workspace; their materialized copies count against scratch instead.

**Accepted limit:** cap decoded search text at 16 KiB (16,384 bytes after decoding). Reject larger input before Authorization or mutation, using bounded decoding. With the tested representation, named buffers then peak at 49,151 bytes (just under 48 KiB) per simultaneous scan, or **46.874 MiB for 1,000 scans**. This is allocation arithmetic, not measured whole-Host footprint. It bounds the matching input only, not file or replacement size. Its product tradeoff is that larger literal old-text selections are rejected; it is a policy choice, not a measured typical-workload requirement.

Use actual simultaneous populations when adding costs: all-model and all-Edit maxima do not occur together under the shared execution ceiling. Edit preparation shares that ceiling; clients, evaluator, SQLite and shared state add independently. Do not multiply a standalone editor process baseline by Edit count or resurrect the synthetic per-worker stack budget.

## Implementation derivation and qualification

The accepted Host policies need no additional numerical allocation or per-kind pool. Before enabling a supported configuration, derive complete compiled custody/continuation/decoder/path state and descriptor requirements from the actual implementation, including transient overlap. The 49,151-byte Edit buffer figure and 3,241-container subtotal remain partial arithmetic, not complete resource bounds.

- Native Edit has three scratch roles under shared preparation/execution custody. Git eligibility helpers are removed by the accepted file-access amendment. Target identity/revalidation, directory handles and phase continuation still count. Scan/hash/copy and reconciliation must yield through the existing driving path; a synchronous whole-file prototype does not prove control responsiveness.
- One serial evaluator lifecycle adds parent preparation/capture/import and child resources independently of execution capacity and ordinary clients. Use the accepted fixed-visibility, on-demand input and fresh-generation recovery contract; do not restore historical whole-input buffer caps as budgets.
- Retained spillover outlives execution custody. Its metadata, names and any Host handles need bounded resident traversal/reclamation and explicit cleanup; a resident record or open descriptor per retained file cannot be assumed to fit. The byte cap alone does not bound empty files. Derive the representation without adding a new retention quota or treating the active-container subtotal as a total.
- Qualify all-model, all-Bash, all-Edit and mixed loads with clients, evaluation, inspection, import, diagnostics and retained-file churn. Include filesystem pressure, actual supported-library costs and control/cleanup service. Whole-process observations and named allocations must not be double-counted.

These are implementation and qualification obligations, not unresolved product-policy choices. The final limit-matrix review consumes the accepted owner/value/release/failure contracts with these explicit missing implementation quantities. If a supported implementation cannot meet the existing targets or derive adequate OS resources, reject unsupported startup configuration or review the failed target/design explicitly; do not silently invent a new pool, lower default or passing resource claim.

## Evidence and status

The [accepted Host package](https://github.com/DivyanshGolyan/onepage/issues/68#issuecomment-5559200690), [accepted native Edit decision](https://github.com/DivyanshGolyan/onepage/issues/68#issuecomment-5559712638), [ADR-0027](../adr/0027-use-an-in-process-exact-edit-module.md) and [buffer experiment](https://github.com/DivyanshGolyan/onepage/issues/68#issuecomment-5559639242) establish the current inputs. Local prototype commit `63581a1` preserves code, measurements and limitations.

The [previous matrix](archive/host-resource-matrix-before-native-edit-2026-09-06.md) preserves the retired Git layout and arithmetic as history. The accepted policy is consolidated here with incomplete implementation quantities identified. No production source changed or new benchmark ran for this accounting pass.

## Sequential metadata decision

The user accepted retaining the shared sequential range file after the [two-pass comparison](https://github.com/DivyanshGolyan/onepage/issues/68#issuecomment-5560090827). The alternative passed the narrow correctness checks but showed no meaningful memory saving and added parsing inside the Store transaction. Local prototype `codex/parser-two-pass-probe`, commit `aa880d1`, preserves results and limits. Its 16 bytes per item describe a start/length pair, not the full metadata needs of a complete provider validator. No additional quota or production qualification follows.

## Whole-memory synthesis

[Host memory accounting](host-memory-accounting.md) combines current measured costs and named allocations without adding whole-process baselines twice or inventing component allowances. The 256 MiB target remains unqualified: Bash supervision, final shared state, the selected evaluator lifecycle and full mixed-owner overlap still need concrete implementation derivation and integrated evidence.
