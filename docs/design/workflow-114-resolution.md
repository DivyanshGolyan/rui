# Workflow eligibility decision closeout

8 September 2026. This checks the accepted decisions in [#114](https://github.com/DivyanshGolyan/onepage/issues/114) against the owning [Workflow Runs contract](../../ARCHITECTURE.md#workflow-runs), [product behavior](../../PRODUCT.md) and [required verification](../../VERIFICATION.md). It is a design consistency review, not executed production evidence. The configuration acknowledgement shape and local-client choices remain with [#101](https://github.com/DivyanshGolyan/onepage/issues/101).

## End-to-end traces

| Trace | Accepted behavior and durable boundary |
| --- | --- |
| New Run creates a Session, then sends | A new Run is eligible without any result. The evaluator emits keyed creation; the Host commits Session and original acknowledgement atomically. A suspended generation publishes that unresolved key. The next immediate pull can see the acknowledgement, and fresh source execution obtains the same Session ID before emitting the message. No live evaluator-to-Host RPC or mandatory one-second gap is needed. |
| Configure, then send | Configuration and its original acknowledgement commit together. A later evaluation reuses that acknowledgement without reapplying the mutation. The subsequent message is an independent admission; other clients may interleave. The exact acknowledgement value remains #101's decision. |
| Scanner A finishes before B | A newly available unresolved result makes the Run eligible. Fresh fixed visibility lets A create its verifier work while B remains pending. Stable scanner/finding keys preserve identity. A final explicit join still waits for its own required results. |
| Result commits during evaluation or before publication | The live snapshot stays fixed. A key unresolved in that view remains in the atomically published suspended dependency set even if its original result has since committed. A later pull finds it from current facts. |
| Result already considered | Once the next suspended publication no longer records that result as unresolved, it alone cannot retrigger evaluation. Conservative extra evaluation for partial joins is accepted. |
| Several Runs or message keys share work | Each keyed admission retains its original work-result binding. A later Session Turn cannot retarget it. Each Run discovers eligibility independently without per-waiter resident payloads or a completion fan-out queue. |
| Crash before generation admission commits | No new generation authority is exposed; ordinary discovery can retry. |
| Crash after admission or a prefix of keyed calls, before publication | Interruption itself makes the Run recoverable. Replace the generation and capture current results. Equal keys reuse committed operations; changed bindings conflict. The old generation cannot admit or publish. No partial dependency set or successful output is exposed. |
| Crash after generation publication | The committed suspended dependency set or terminal outcome is authoritative. Discovery uses it; a terminal Run is not reevaluated. |
| Cancellation during capture or admission | Admission and final publication recheck cancellation and generation identity. A committed prefix retains its existing recovery/stop behavior; completion is never fabricated and the batch is not claimed to roll back as a unit. |
| Returned Promise fulfills with unrelated calls pending | Encountered calls still pass validation and ordinary admission before successful terminal publication. Their Session work continues. Later results do not restart the Run, and no unawaited JavaScript continuation survives evaluator exit. |
| Returned Promise rejects or evaluation fails | Existing failure handling applies; required validation and resource failures still prevent false success. Already committed operations retain their existing lifecycle. Root completion is not permission to bypass evaluator/protocol failures. |
| Bursts and ordinary operation | Oldest eligible by creation time plus stable tie-breaker; one complete evaluator lifecycle, Host service, immediate recheck. Only an empty query starts the shared asynchronous one-second wait. Millisecond evaluation assumptions are compared with seconds-to-minutes Turns; aggregate overload and linear discovery work remain qualification limits. |

JavaScript constructs its own dynamic dependencies. The Host records complete encountered unresolved calls for a pending root without discovering Promise reachability or building a second DAG. Existing evaluator deadlock/failure handling is not replaced by a promise that arbitrary unresolved JavaScript can make progress.

## What is decided

The durable fact families, original-result ownership, fresh recovery, atomic publication boundaries, conservative eligibility, oldest-first asynchronous pull selection, bounded resident discovery, on-demand decoding, stable authoring and returned-root completion are specified. No exact SQL column list, snapshot file format, new queue, delivery history, mutation checker or additional numeric quota is needed to close this decision.

## What remains implementation and qualification

- Integrate the accepted Session operations and original result bindings into the evaluator and protocol. The inspected source still exposes the older `agent` bridge. Its fulfilled-root path in `src/workflow_evaluator.zig` calls `writeBlocked` when requests are pending; its completed outcome does not carry the required successful-generation request collection. Those are known implementation differences, not passing conformance or newly reopened choices.
- Preserve existing failure/deadlock handling while adding the accepted returned-root behavior; verify successful unawaited descriptors are admitted and unavailable continuations are discarded. Required cases are in VERIFICATION.md.
- Choose concrete records, indexes and bounded conversion/capture workspaces; enforce actual allocation, scratch, CPU and lifetime budgets and result retention through existing owners. Prototype whole-record conversion does not qualify arbitrary records.
- Execute real crash, cancellation, Session mutation, partial admission, terminal-output and original-result tests. The relational model and native probes are narrower evidence.
- Measure actual discovery, publication, control service and whole-Host resource use on the pinned build. Oldest-first has no unconditional starvation guarantee under sustained overload; LIMIT 1 does not bound examined dependencies. Existing resource targets and their remaining aggregate decisions stay with #68/#89.
- Publish the locally prepared normative documentation through the ordinary repository workflow. Closing the issue records accepted design pending that publication; it does not commit or push these files or certify production.

The prototype reports remain on local branches `codex/workflow-input-capture-probe` (`bb7a6ea`), `codex/workflow-lazy-input-probe` (`c57dd39`) and `codex/workflow-oldest-loop-probe` (`37fa9e6`). The [generation note](workflow-generation-publication.md) records their outcomes and limits. No speculative implementation tickets are created; [V1 readiness #2](https://github.com/DivyanshGolyan/onepage/issues/2) owns later slicing against the aligned contract.

## Publication follow-up — 8 September 2026

The [accepted-baseline publication](accepted-baseline-2026-09-08.md) includes these owning amendments and referenced decision evidence. Earlier local/uncommitted statements record the closeout state; publication does not satisfy the production obligations above.
