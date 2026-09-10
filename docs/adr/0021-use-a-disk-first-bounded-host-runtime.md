---
status: accepted
---

# Use one disk-first bounded Host Runtime

## Accepted amendment — Direct operations, bounded tracking and independent workflows (10 September 2026)

Use [direct transactional operations](../design/transactional-operations.md): validate content before the transaction, check current saved state and mutate within it, dispatch effects after commit. No mandatory pure classifier/interpreter remains. Complete response validation stays sequential with bounded windows; a worker requires measured justification. [Fixed tracking](../design/fixed-execution-tracking.md) preallocates exactly active_capacity content-free neutral/occupied records, selects oldest eligible durable work, retains custody until safe cleanup and waits on OS events/deadlines when idle. [Shared keyed requests](../design/shared-request-identity.md) separate core transactions from Workflow Runtime bookkeeping; progress observations need no globally atomic cross-Session view. [Unified recovery](../design/unified-tool-recovery.md) and [exact Edit](../design/fixed-location-edit-approval.md) supersede post-crash target reconciliation and pre-approval whole-file preparation. Preserve Operation-owned current execution/results from ADR-0026 and the selected resource bounds; [platform evidence](../design/platform-contract-review.md) distinguishes tested Mac behavior from unexecuted compatibility assumptions.

For implementation, read the consolidated [execution](../architecture/execution.md), [resources](../architecture/resources.md) and their linked verification contracts. The record below preserves the original decision and later amendments; superseded wording is historical.

## Accepted resource and visibility closeout — 8 September 2026

[#68](https://github.com/DivyanshGolyan/onepage/issues/68#issuecomment-5578368447), [#95](https://github.com/DivyanshGolyan/onepage/issues/95#issuecomment-5568965123), [#115](https://github.com/DivyanshGolyan/onepage/issues/115#issuecomment-5578221972) and [#89](https://github.com/DivyanshGolyan/onepage/issues/89#issuecomment-5578432698) complete the resource-policy and inspection-ownership decisions. Earlier open-policy wording below is historical. The [V1 limit matrix](../architecture/resources.md#v1-limit-matrix) owns current controls and implementation derivations; exact internal sizes and integrated qualification remain outstanding. [ADR-0014](0014-use-ephemeral-quickjs-for-workflow-evaluation.md#accepted-amendment-on-demand-original-result-decoding) also permits narrowly scoped private snapshot-metadata scratch writes during workflow visibility capture; bodies are materialized after that read transaction ends. Together with inspection capture, these are the explicit scratch-write exceptions to the original no-I/O statement; neither allows network delivery or external effects inside a transaction.

## Accepted native Edit amendment — 6 September 2026

[ADR-0027](0027-use-an-in-process-exact-edit-module.md) replaces Git-backed unified Patch with the in-process exact Edit module behind the Action adapter. The closed executable inventory is `bash` and `edit`. Preserve permissions, exact preimage/postimage intent, uncertainty and recovery; Host authority stays separate from edit mechanics. Git-specific helper/scratch requirements and old Patch names below are historical where superseded. The current [Edit contract](../architecture/execution.md#native-edit-module) and [verification](../verification/execution.md#native-edit-verification) govern implementation; this is not production certification.


Amended by [ADR-0024](0024-capture-run-inspection-before-delivery.md): an inspection read transaction may span private report-scratch writes. Network delivery and external effects remain outside transactions.

Amended by [ADR-0025](0025-enforce-execution-contracts-without-historical-replay.md): the historical Completion replay/conflict promise below no longer applies. At-most-once terminal delivery belongs to the adapter/effect owner; complete failed-try diagnostics are not a V1 guarantee. Recovery facts and accepted results remain durable, and execution representation remains under comparison.

## Accepted execution-control amendment — 5 September 2026

Physical Custody is one startup-sized in-memory table of content-free records. Use plain bounded table scans in V1, without a separate free list, active-record index, resident Session collection, or durable SQLite slot table. Reserve a record before Attempt admission; rollback returns the unused reservation, while successful admission permits dispatch only after its commit is observed. SQLite owns Session occupancy, Attempt/Resolution facts, cancellation and retry eligibility; it does not duplicate live handle ownership. Logical settlement does not free a record whose physical cleanup is still outstanding. Reuse requires safe resource release and rejection of stale or duplicate events by exact admitted identity. The accounting invariant is free records plus occupied records equals startup Active Capacity; it does not introduce a second credit pool.

When no runnable work or required deadline/poll is due, sleep until an existing I/O/control notification or required wake. Do not add periodic scans merely to revisit an empty custody table. The existing single bounded SQLite retry-eligibility poll remains; its cadence is a separate budget decision. This is not a whole-process prohibition on allocation after startup: library, evaluator, transport, and scratch resources retain their existing bounded ownership and accounting.

See the [accepted simplification and evidence](../design/execution-control-simplicity.md). Numeric resource decisions remain open; prototype results are not production certification.

## Accepted server-lifetime amendment — 5 September 2026

The foreground Host/control context is the explicitly started local server, holding exclusive Store ownership through startup recovery and live execution. Clients never acquire execution custody, open SQLite, or schedule progress. Server driving continues without clients. Infrastructure stop fences dispatch promptly and performs bounded effect-aware cleanup without waiting deliberately for LLM completion; it is not Run cancellation or user-command Model Interruption. Explicit restart recovers unfinished facts under existing effect rules and remaining budgets. See [server ownership](../../ARCHITECTURE.md#server-ownership-and-local-clients) and [lifecycle verification](../../VERIFICATION.md#server-lifecycle-and-local-command-boundary).

## Accepted parser and SQLite resource refinement — 6 September 2026

The post-seal parser uses byte ranges into sealed scratch, bounded resident validation state, and scratch-backed metadata when item count grows. Complete provider validation precedes incremental import through the existing atomic settlement boundary. These private ranges do not become durable replay authority. Store initialization explicitly configures and verifies effective SQLite spill behavior alongside cache and enforced heap settings; a suggested cache size alone does not bound resident memory during large imports. See [execution and settlement](../architecture/execution.md#host-runtime-execution-and-settlement), [capacity and memory](../architecture/resources.md#capacity-and-memory), and [memory verification](../verification/resources.md#memory-and-density) for the owning requirements. Numeric settings remain open in [the SQLite resource decision](https://github.com/DivyanshGolyan/onepage/issues/95).

This preserves the single Storage Owner, serial validation/import workspace, explicit replay references, and effect-specific recovery. It requires no shared validation/inspection region or new recovery framework. Prototype measurements establish feasibility, not complete provider validation or production certification.

## Accepted control-service and cleanup refinement — 6 September 2026

Ready stop/cancel requests and due cancellation cleanup receive bounded service turns between individual ordinary result settlements. Durable acknowledgement alone does not justify leaving already-sealed cancellation evidence and safely releasable custody behind the ordinary-result backlog. Individual imports and settlement transactions retain their atomicity; effect owners retain physical custody until safe release, and other work must continue to make progress. This uses existing owners and the custody table. Numeric control latency and service budgets remain undecided.

Keep explicit resource cleanup and the existing bounded reusable workspaces. The allocator-retention evidence does not require a custom allocator or pressure-relief mechanism; any later reclamation policy depends on the selected idle-footprint requirement and supported-build measurements. Retained process memory remains accounted for. The [accepted decision](https://github.com/DivyanshGolyan/onepage/issues/68#issuecomment-5557664310) follows the [prototype evidence](https://github.com/DivyanshGolyan/onepage/issues/68#issuecomment-5557643391), which is not a production guarantee. The current [Host driving contract](../architecture/workflows.md#run-interface) and [memory verification](../verification/resources.md#memory-and-density) own the detailed requirements.

## Accepted reactor-service refinement — 6 September 2026

The [accepted decision](https://github.com/DivyanshGolyan/onepage/issues/68#issuecomment-5557772741) keeps the single I/O Reactor and provides cancellation service opportunities between individual socket events and completed-transfer notifications. Preserve library callback, handle/message lifetime and stale-readiness rules. This extends the accepted control-service direction through physical transport cleanup without adding another worker or queue. The [reactor prototype evidence](https://github.com/DivyanshGolyan/onepage/issues/68#issuecomment-5557764087) supports this mechanism; its experimental curl build and measured timings do not select a supported dependency, numerical capacity or latency guarantee. Individual socket/timeout actions and callbacks remain non-preemptible. The [Host driving contract](../architecture/workflows.md#run-interface) and [memory verification](../verification/resources.md#memory-and-density) own the requirements.

## Accepted saturation policy — 6 September 2026

The [accepted capacity-wait decision](https://github.com/DivyanshGolyan/onepage/issues/68#issuecomment-5557977555) distinguishes durable-work admission from physical-execution admission.

When the custody table is full, already-accepted work waits in its existing SQLite facts rather than failing solely for lack of Active Capacity. Waiting creates no new Attempt, consumes no Attempt allowance, and owns no physical execution resources or per-waiter resident queue. Safe release prompts bounded reconsideration through the existing driving path; cancellation and restart use existing authority and recovery. Waiting alone does not keep the driver spinning. Independent ingress, storage and effect limits still apply.

This retains the fixed table and its free-plus-occupied invariant. It adds no separate pool, scheduler, wait-state schema, FIFO promise, numeric default or whole-process static-allocation rule. The [capacity contract](../architecture/resources.md#capacity-and-memory) and [verification requirements](../verification/resources.md#memory-and-density) own the details. The motivating distinction is between admission of durable work and admission of its physical execution; the latter waits when there is no free record.

## Accepted storage-exhaustion policy — 6 September 2026

See the [accepted storage policy](https://github.com/DivyanshGolyan/onepage/issues/68#issuecomment-5558017651).

Wait before a new Attempt when required temporary storage is known to be exhausted. If storage runs out after admission, stop the affected execution safely and report an explicit failure through its existing owner; do not switch to RAM, silently truncate, indefinitely pause while retaining scratch, or automatically redispatch it. Preserve the real admission, external-effect uncertainty, required evidence and ordinary cleanup boundaries. A failed Bash command is not proof its external changes were undone.

If a canonical SQLite storage fault prevents saving semantic state, stop dispatch and shut down the Host with bounded effect-aware cleanup. Do not claim an outcome whose transaction did not commit. After storage is restored, explicit restart follows existing recovery; diagnostics retain their separate non-authoritative failure behavior. This selects the overload policy, not numeric quotas, a guaranteed emergency reserve, custom reclamation or a new scheduler. The [capacity and storage contract](../architecture/resources.md#capacity-and-memory) and [verification requirements](../verification/resources.md#memory-and-density) own the details.

## Accepted Host policy package — 6 September 2026

The user accepted the [Host policy package](../design/host-final-recommendations.md).
The current [client and diagnostic contracts](../../ARCHITECTURE.md), capacity/scratch
contract and [qualification targets](../verification/resources.md#accepted-host-qualification-targets)
own the defaults, rotation/export behavior, startup configuration and one-second
retry poll. Earlier statements in this historical record that those numbers or
mechanics remain undecided are superseded by those owning sections. Acceptance
is not production qualification. The [owner audit](../design/host-resource-owner-audit.md)
records the Patch helper-write and named-scratch cleanup gap, subsequently
resolved by [Patch helper scratch ownership](../design/archive/git-patch-scratch-before-native-edit-2026-09-06.md).
The Host ticket remains open until its remaining finite ownership accounting is complete.

## Original decision

OnePage uses one foreground Host/control context as the sole Storage Owner and one multiplexed I/O Reactor that observes provider streams, subprocess pipes, and temporary Action executors. Only the Storage Owner accesses SQLite or selects semantic meaning. One bounded table of content-free Physical Custody records implements Active Capacity: occupying one record is one Active Credit, not a second object or pool. There is no per-Turn driver, permanent Patch lane, retained worker, payload buffer, parser workspace, or resident Session object. Bash and Patch share one closed typed Action lifecycle and may execute concurrently without a Workspace fence or isolation guarantee.

Attempt admission reserves capacity before `BEGIN IMMEDIATE` and issues a one-shot post-commit Dispatch Permit only to the invocation that observed the commit. Exact outbound requests and inbound provider or tool bytes move through fixed borrowed windows and dynamically charged, immediately unlinked scratch. No SQLite transaction spans external I/O. Scratch is non-authoritative and nonrecoverable: loss leaves the Attempt unresolved for effect-specific recovery.

After effect-specific terminalization, the Storage Owner parses sealed evidence in one shared serial validation/import workspace. Normal content, Attempt Completion, Operation Resolution, Conversation, User Message, or permission facts, and the next semantic consequence commit in one transaction. The sole Completion-only exception is a retryable model Completion committed atomically with immutable future eligibility while its Operation remains unresolved. Each Attempt has at most one Completion; exact replay is idempotent and contradictory evidence is rejected. SQLite eligibility rows plus one bounded periodic query replace per-Turn timers, wake objects, and a second scheduler.

This decision removes ADR-0003's Workspace-quiescence assumption while retaining its external-truth and Patch-reconciliation rules. It supersedes ADR-0011's Activation Slot pool and ADR-0016's generic two-transaction Completion/Resolution protocol, and amends ADR-0010, ADR-0013, and ADR-0015. Historical buffer, scratch-replay, online-detector, driver-lease, and execution-cell designs remain research evidence only.

## Accepted amendment — Operation-owned execution and results

[ADR-0026](0026-let-operations-own-current-execution-and-final-results.md) supersedes this record’s per-try authority and final-content ownership. Use the current [execution contract](../architecture/execution.md) and [verification](../verification/execution.md); retain the original wording as history.

## Accepted amendment — shared FIFO temporary-file retention, 7 September 2026

The accepted spillover decision adds optional later reading of complete temporary tool output while only a small Tool Result is canonical. The shared temporary-file owner protects content still required by current work, promptly releases files with no later consumer, and reclaims optional retained files oldest-first when space is needed. No separate per-Turn expiry, per-tool storage pool or background cleanup service is selected. Required evidence and outstanding I/O remain protected; actual safe release precedes quota reuse. When reclamation cannot provide space, existing wait/failure rules apply.

This amends earlier statements excluding temporary-file reclamation or assuming all tool output is removed at settlement. Spillover loss on crash, Host exit or reclamation is accepted; saved results remain unchanged, and recovery never automatically reruns an old Bash call. Retained-file metadata and access still require bounded ownership. The [current retention contract](../architecture/resources.md#shared-temporary-file-retention) and [memory verification](../verification/resources.md#memory-and-density) own the requirements. Historical measurements do not certify the added retained population; no production implementation is claimed.

## Accepted amendment — published-spillover accounting scope, 7 September 2026

The user accepted the limitation of ordinary filesystem paths after the open-reader example: FIFO may remove a published spillover name while another program still holds its data. Its shared retention charge is returned after successful name removal and closure of Host handles, without discovering external readers. The shared budget covers OnePage-written/retained temporary data, not a strict bound on all physical storage held or changed by arbitrary tools. External mutation, links and retained handles are outside the published-spillover guarantee. No sandbox or global reader-tracking machinery is selected.

This scopes the earlier FIFO amendment's outstanding-reader and actual-release claims to private scratch and Host-owned I/O. Strict growth reservation and safe release remain for private scratch and active capture. Required canonical evidence and the saved small Tool Result are unchanged; real disk-full failures remain explicit. The [shared retention contract](../architecture/resources.md#shared-temporary-file-retention) and [verification](../verification/resources.md#memory-and-density) own the current requirements.

## Accepted amendment — workflow idle discovery

The 7 September 2026 [ADR-0014 pull-discovery amendment](0014-use-ephemeral-quickjs-for-workflow-evaluation.md#accepted-amendment--asynchronous-pull-discovery) adds one shared asynchronous one-second idle timer for workflow eligibility discovery. It is distinct from the existing model-retry poll and does not revisit an empty custody table or retain per-waiting-Run resources. Workflow Runs in ARCHITECTURE.md owns its service and memory contract.
