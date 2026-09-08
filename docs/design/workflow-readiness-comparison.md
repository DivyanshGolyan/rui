# Derived readiness versus a durable ready set

Design comparison, 7 September 2026, with the accepted follow-up below. Earlier proposed alternatives for [Choose workflow reevaluation eligibility and wake-ups](https://github.com/DivyanshGolyan/onepage/issues/114), not an accepted contract change. The user accepts independent branch progress and extra evaluations, and prefers simplicity without a batching subsystem.

## Accepted choice — asynchronous pull loop

Accepted 7 September 2026. Use the pull loop described in the follow-up below: select eligible work when evaluator capacity is free; after its complete lifecycle, select again; only an empty selection arms a one-second asynchronous idle timer. The Host keeps servicing other work. Readiness derives from saved facts, without completion hooks, deferred completion IDs or a maintained ready set. [ARCHITECTURE.md](../../ARCHITECTURE.md#workflow-runs), [ADR-0014](../adr/0014-use-ephemeral-quickjs-for-workflow-evaluation.md#accepted-amendment--asynchronous-pull-discovery) and [VERIFICATION.md](../../VERIFICATION.md#workflow-replay) own the contract and remaining proof. Earlier alternatives and recommendations below remain the comparison history. No production qualification is claimed.

## The alternatives

**Derived readiness:** saved unresolved dependencies and outcomes determine whether a Run needs another evaluation. Finding work requires checking those relationships. Completion, dependency publication, startup and capacity availability must reliably lead to discovery.

**Durable ready set:** additionally keep at most one pending Run ID per workflow. It means that the Run needs a fresh evaluation; it contains no answer, callback, event history or evaluation payload. Selecting work reads this relation. A pending entry and an in-progress evaluation may coexist: the entry then requests later consideration. This is distinct from replaying an interrupted admitted generation's immutable snapshot.

A ready set does not require a general job-queue framework, multiple consumers, leases, dead-letter handling or configurable retry policies. Existing Run cancellation, evaluator resource/failure handling and generation ownership still apply. Selection fairness is required whichever candidate is chosen; choosing the lowest Run ID repeatedly is not a fairness proof.

## Smallest ready-set protocol to compare

| Transition | Required durable action |
| --- | --- |
| Create a Run | Record initial readiness with its admission. |
| Commit a result | In the same transaction, insert affected nonterminal, uncancelled Run IDs found through current dependency bindings. Duplicate Run IDs retain one entry. |
| Start a fresh evaluation | Consume its pending entry and admit its immutable Evaluation Generation atomically. Actual capacity is still required. |
| Result arrives during evaluation | Insert readiness for later consideration. The running generation keeps its original view. |
| Publish evaluation dependencies | Replace the current eligibility basis under generation validation; check newly published dependencies against present results and insert readiness where needed. Do not blindly delete an entry here. |
| Resume after crash | Recover an admitted generation under its existing snapshot rules; do not consume its later pending entry merely to resume it. Otherwise choose pending ready work. |
| Cancel or terminate | Prevent new admission and remove or disregard stale readiness atomically with applicable terminal/fencing facts. |

Publication's recheck remains necessary: a result can commit before its new dependency is recorded. A ready set does not remove that race. Clearing readiness when an evaluation finishes is also incorrect if a result arrived during that evaluation; consuming the entry at fresh admission avoids clearing that newer request.

Exact transaction grouping for workflow-result publication and newly discovered Session requests remains a shared prerequisite, not solved by a ready relation.

## The durability distinction

A durable destination does not make a deferred producer durable:

```text
commit A's result
crash before deferred lookup inserts W into ready
restart: ready is empty, although W can progress
```

Two complete alternatives to that gap are:

- Populate affected readiness in A's result transaction. Either both commit or neither does.
- Keep the deferred population, but reconstruct missing readiness from dependencies/results or durably record unfinished population work.

The second reintroduces derived recovery or another durable obligation. It weakens the claim that the ready set alone simplifies startup. The first is the smallest self-contained ready-set candidate, but result completion now includes lookup and fan-out writes. Reevaluation remains asynchronous; these database changes are not deferred.

Dependencies must refer to original request/result bindings, not Session-current answers. A shared Turn may have many dependents, so atomically marking every one can make an owner transaction long. Constant-size ready entries do not imply constant transaction work. Processing only the first portion and forgetting the rest is invalid.

## Comparison under the same scenarios

| Scenario | Derived readiness | Durable ready set |
| --- | --- | --- |
| A finishes during evaluation | Later current-fact check discovers it | A pending entry survives evaluation publication |
| A finishes before its dependency is published | Publication checks present results | Same check, then insert entry |
| Crash after result commit | Reconstruct eligibility | Ready entry exists only if population committed atomically or was separately recoverable |
| Repeated discovery | Revalidate eligibility/generation | Unique Run entry; revalidate generation at admission |
| Evaluator busy | Readiness must remain discoverable | Pending entry waits on disk |
| Many idle workflows | Query path must avoid repeated irrelevant scans | Direct ready selection; maintained rows add write-side responsibility |
| Very large result fan-out | Bound discovery while preserving eventual progress | Atomic writes scale with fan-out, or require additional recovery for deferred population |
| Memory | Bound query workspace and any deferred work records | Bound query workspace; pending population is on disk, not a heap queue |

Neither candidate needs to retain a JavaScript heap while waiting. Neither justifies dropping live work because startup might recover it someday. Both need the existing Host to wake reliably and give ready work eventual capacity.

## Small measured comparison

The [SQLite experiment](../../research/workflow-readiness/README.md) uses a small schema to examine the lookup/write trade-off. With 100,000 unrelated waiters and 100,000 historical results, the targeted zero-dependent lookup took about 0.006 ms; the result-plus-readiness commit took 0.44 ms. Marking 1,000 dependents took a 0.76 ms commit; 100,000 took 18.20 ms. The simple derived-selection query scanned waiting dependencies and took roughly 4–7 ms, while selecting from ready took about 0.006 ms.

These are warm medians on a different SQLite build, not production command latency, crash evidence, a selected query/index set or proof of arbitrary fan-out. The fixture intentionally places unrelated waiters before the target dependencies and does not exhaust alternative derived queries. It shows why both empty lookup and high fan-out must be considered; it does not establish that one scheme is universally faster or simpler.

## Recommendation for discussion

A single durable ready entry per Run is a credible, small candidate for simpler admission and restart selection. Its strongest form marks readiness in the same transaction as the result. The probe supports investigating that form; it does not justify adding a general queue system.

The choice is whether this extra maintained fact and synchronous completion work are preferable to derived selection/recovery. If keeping the dependency lookup deferred is essential, do not pretend a ready set removes the recovery work; the derived scheme may then be simpler overall.

Before accepting the ready-set candidate, confirm that trade-off with the user and qualify the required transaction/publication boundaries and representative fan-out. The earlier recommendation favoring derived readiness in the branch-progress note is a historical starting proposal; this comparison supersedes that recommendation without selecting a replacement.

## Follow-up candidate — pull loop with one-second idle polling

Proposed in response to the user's follow-up; not an accepted contract change. Keep derived eligibility and make discovery the evaluator driver's ordinary loop:

1. With evaluator capacity free, ask for one eligible Run through the Storage Owner.
2. If one exists, admit/evaluate/publish/clean up through existing generation rules, then ask for the next.
3. If none exists, wait one second before checking again. Startup begins with a check.

The one-second interval applies to idle discovery, not a one-evaluation-per-second rate limit. The loop must yield to controls and other owner work; SQL remains synchronous on the existing connection while each statement executes. Selecting one Run avoids materializing all eligible Runs, but does not itself bound rows examined. Existing cancellation and explicit Host shutdown still wake/service their existing owners.

This removes the need for Turn-completion notifications, reverse fan-out scheduling and a durable ready relation specifically for workflow discovery. A result committed during evaluation or before dependency publication is seen by a subsequent eligibility query. Once an evaluation has considered a result, its new unresolved-dependency basis prevents that old result alone from retriggering work. Crash recovery still distinguishes interrupted admitted generations from new evaluations.

The trade-off is up to roughly one second of idle discovery delay, plus contention/evaluation waiting, and recurring database CPU/I/O when nothing changes. This is not a hard one-second latency guarantee. No per-workflow timer or batching accumulator is introduced.

The initial naive derived query was measured for no-ready-work cases: about 4.16 ms process CPU with 100,000 waiting dependencies and 42.87 ms with 1,000,000. At exactly one query per second, arithmetic attribution is approximately 0.42% and 4.29% of one core for this query alone. The measurements ran seven warm queries consecutively, not a timed idle Host or production load test. Unrelated waiters all reference the same pending work row, historical completed rows have no current dependents, and a better access shape may avoid redundant work. These observations demonstrate the cost of this particular dependency scan, not an inherent lower bound for polling. See [poll measurements](../../research/workflow-readiness/README.md#idle-poll-cost-follow-up).

Polling is the smallest control-flow candidate considered so far. Whether it is acceptable depends on the user's discovery-delay preference and measured query work against the accepted idle-CPU/owner-responsiveness targets. Existing targets must not be silently relaxed. Compare this loop before committing to maintained ready state.
