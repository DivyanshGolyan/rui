# Cancellation in durable systems

> **Research record, published 6 September 2026.** Findings and proposals below reflect the dated investigation. Subsequent decisions are owned by [ARCHITECTURE.md](../../ARCHITECTURE.md) and [PRODUCT.md](../../PRODUCT.md); historical recommendations and implementation-ticket references do not override them.

Status: design research, 2026-09-05. This note does not change OnePage's accepted contract. Evidence consists of official documentation and inspected source/tests; no upstream tests or crash experiments were executed.

## Subsequent OnePage decision

After reviewing this research, the user selected simpler recovery: an unfinished Run cancellation may repeat its whole Session stop pass after a crash; callers coordinate Session reuse. The existing terminal Run outcome prevents further propagation once cancellation completes. No per-Session propagation receipts or idle-check records are selected. This supersedes the no-retarget recommendation under the implications below; upstream findings remain historical research evidence. The [accepted trace](../design/workflow-cancellation-stop-mapping.md#accepted-simplification) and owning architecture/verification documents govern implementation.

## Questions and distinctions

The question is whether cancellation uses the same durability mechanisms as ordinary workflow effects, and what information those mechanisms retain. Four different events matter: accepting a cancellation request, propagating it to another execution, recording an execution's terminal outcome, and actually stopping external work. A durable record of one does not necessarily establish the others.

## Temporal

**Cancellation is durable, cooperative workflow input, distinct from a cancelled outcome.** Temporal defines `WorkflowExecutionCancelRequested` and `WorkflowExecutionCanceled` separately. The former can identify the initiating external workflow and its history event; the latter is reported through a completed Workflow Task. Thus a request can survive worker reconstruction without claiming the workflow already finished. [Event schemas](https://github.com/temporalio/api/blob/68c7e8c7b361e77e9cb5d8f9b9c9bcc631382f01/temporal/api/history/v1/message.proto#L589-L604).

**Propagation is represented explicitly within existing history and task infrastructure.** Cancelling another workflow produces `RequestCancelExternalWorkflowExecutionInitiated`; its eventual acceptance or failure is linked back by the initiated event ID. The server constructs pending `RequestCancelInfo` and a `CancelExecutionTask` from this event. These are cancellation-specific record/task types inside the existing execution machinery, not facts inferred solely from the parent's final status. [External cancellation event schemas](https://github.com/temporalio/api/blob/68c7e8c7b361e77e9cb5d8f9b9c9bcc631382f01/temporal/api/history/v1/message.proto#L645-L689), [mutable-state transition](https://github.com/temporalio/temporal/blob/891d1b648b7252925142cc36f13e40a0e2ed4244/service/history/workflow/mutable_state_impl.go#L5169-L5215), [task generation](https://github.com/temporalio/temporal/blob/891d1b648b7252925142cc36f13e40a0e2ed4244/service/history/workflow/task_generator.go#L634-L666).

The transfer executor reads the pending request and original target, retries transient delivery failures, and records acceptance or a nontransient failure in the originating execution. Retries carry the same stored cancellation request ID. Acceptance means the other execution received a cancellation request, not that all its work stopped. The inspected path also skips work if the source execution is no longer running; do not interpret this one path as an unconditional cascade after every parent close. [Transfer processing](https://github.com/temporalio/temporal/blob/891d1b648b7252925142cc36f13e40a0e2ed4244/service/history/transfer_queue_active_task_executor.go#L513-L638), [request reuse](https://github.com/temporalio/temporal/blob/891d1b648b7252925142cc36f13e40a0e2ed4244/service/history/transfer_queue_active_task_executor.go#L1806-L1834).

Within workflow code, the TypeScript SDK uses cancellation scopes. Cancellation flows to enclosed cancellable operations; a noncancellable scope permits cleanup to proceed. Parent closure is separately governed by Parent Close Policy: terminate, request cancellation, or abandon the child. These are explicit behavioral choices built on the runtime, not implications of persistence alone. [Cancellation scopes](https://docs.temporal.io/develop/typescript/workflows/cancellation-scopes), [Parent Close Policy](https://docs.temporal.io/parent-close-policy).

**Execution identity makes repeated cancellation safe.** A reusable Workflow ID and a particular Run ID are distinct. The cancellation API also accepts `first_execution_run_id` to constrain an execution chain, alongside a deduplication request ID. Server handling returns success without another event for an already-cancel-requested execution or an already-finished target, and checks the chain guard before cancelling running work. Omitting execution constraints can intentionally address the current execution; the API does not universally prevent a caller from doing that. [Identity model](https://docs.temporal.io/workflow-execution/workflowid-runid), [request schema](https://github.com/temporalio/api/blob/68c7e8c7b361e77e9cb5d8f9b9c9bcc631382f01/temporal/api/workflowservice/v1/request_response.proto#L830-L848), [server handling](https://github.com/temporalio/temporal/blob/891d1b648b7252925142cc36f13e40a0e2ed4244/service/history/api/requestcancelworkflow/api.go#L39-L94).

**Persistence is not physical preemption.** Ordinary remote Activities learn of cancellation through heartbeats and must cooperate; Local Activities have different delivery mechanics. Termination immediately closes the Workflow Execution without letting workflow code clean up. Neither description establishes that an arbitrary remote HTTP request, subprocess or paid provider call has physically ceased. [Activity cancellation](https://docs.temporal.io/develop/typescript/workflows/cancellation), [cancellation versus termination](https://github.com/temporalio/documentation/blob/main/docs/develop/dotnet/workflows/cancellation.mdx).

## Restate

**Restate durably represents cancellation in the ordinary invocation journal.** In the inspected server, an administrative cancellation becomes a `TerminateInvocation` log command with cancellation flavor; the RPC replies on application. Running, suspended and paused invocations receive `CANCEL_SIGNAL` through ordinary journal-entry processing. Queued or scheduled invocations take a terminal path; completed and missing targets produce distinct responses. [Cancellation RPC](https://github.com/restatedev/restate/blob/64d12f01368b66cf88a3f78ba4397f129b623fc9/crates/worker/src/partition/rpc/cancel_invocation.rs#L19-L45), [cancellation transition](https://github.com/restatedev/restate/blob/64d12f01368b66cf88a3f78ba4397f129b623fc9/crates/worker/src/partition/state_machine/lifecycle/cancel.rs#L67-L125).

The architecture puts events, journal entries and inter-service messages through its durable log before applying them. Processor state can be rebuilt from that log. This is the durability foundation used by the cancellation transition, not a separate cancellation database. [Restate architecture](https://docs.restate.dev/references/architecture).

**Propagation becomes ordinary durable signal commands.** On observing cancellation, the shared SDK core resolves tracked child invocation IDs and invokes `sys_cancel_invocation` for each. That operation emits a `SendSignalCommandMessage` with the built-in cancellation signal ID through the ordinary journal transition. On the server, the generic send-signal handler enqueues `NotifySignal` in the existing outbox. This is a concrete example of composition through common journal and message-delivery mechanisms, while still having code that specifies which invocations to cancel. [SDK cancellation handling](https://github.com/restatedev/sdk-shared-core/blob/bcdf52777955b36bed611483abd227db03b9a09c/src/vm/mod.rs#L472-L523), [cancellation command](https://github.com/restatedev/sdk-shared-core/blob/bcdf52777955b36bed611483abd227db03b9a09c/src/vm/mod.rs#L1229-L1244), [generic signal outbox effect](https://github.com/restatedev/restate/blob/64d12f01368b66cf88a3f78ba4397f129b623fc9/crates/worker/src/partition/state_machine/entries/send_signal_command.rs#L21-L37).

The strongest directly relevant evidence is the SDK test `replay_while_cancelling`. Its existing journal contains two child calls, their invocation IDs, the incoming cancellation, and an outgoing cancellation already recorded for child 1. Replaying emits only child 2's cancellation:

```text
Persisted journal: call child 1; call child 2; cancel arrives; cancel child 1
Replay:            reuse those entries; emit cancel child 2; finish
```

This demonstrates the intended partial-propagation recovery construction: previous effects are journaled and replayed; unfinished propagation proceeds through the same API. It does not demonstrate that physical child execution has stopped, or supply independent passing crash-test evidence. [Replay test](https://github.com/restatedev/sdk-shared-core/blob/bcdf52777955b36bed611483abd227db03b9a09c/src/tests/implicit_cancellation.rs#L331-L427).

**The public guarantee has limits.** Documentation describes cooperative cancellation at an await point, recursive call-graph propagation, and compensation. One-way/delayed calls are detached. The API is nonblocking, requires a reachable deployment for cooperative handling, and explicitly cautions that cancellation may rarely fail to take effect. Kill bypasses compensation. Therefore the source evidence supports durable representation and replay, not an unqualified guarantee that every cancel response means all descendants are stopped. Invocations have unique IDs; restart-as-new creates a different invocation rather than reusing the old one. [Managing invocations](https://docs.restate.dev/services/invocation/managing-invocations).

## DBOS TypeScript: status rows and ordinary step checkpoints

DBOS documents cancellation as setting workflow status to `CANCELLED`, removing queued work, and interrupting running workflow execution at the next step boundary. Recursive child cancellation is an option, disabled by default. Cancelled workflows can explicitly resume from their last completed step. These are TypeScript contracts; other SDKs have different cooperative-cancellation details. [TypeScript management API](https://docs.dbos.dev/typescript/reference/methods#dboscancelworkflow), [workflow management](https://docs.dbos.dev/typescript/tutorials/workflow-management#cancelling-workflows)

Source inspected at `dbos-inc/dbos-transact-ts` commit `d8c4974cca6cc84b296f3b8edfbbb41627ddd47e` (4 September 2026):

- `DBOS.cancelWorkflow` delegates to `cancelWorkflows`, which wraps the cancellation in the same `runInternalStep` helper used by other workflow management calls. The helper checkpoints the call when invoked directly inside a workflow, and calls it directly outside a workflow or from inside an existing step. [API and wrapper](https://github.com/dbos-inc/dbos-transact-ts/blob/d8c4974cca6cc84b296f3b8edfbbb41627ddd47e/src/dbos.ts#L376-L400), [cancel operation](https://github.com/dbos-inc/dbos-transact-ts/blob/d8c4974cca6cc84b296f3b8edfbbb41627ddd47e/src/dbos.ts#L1140-L1160)
- Cancellation updates the existing `workflow_status` table. Optional propagation walks descendants level by level using an in-memory `visited` set and frontier, querying `parent_workflow_id`. Each level is updated separately. This function has no durable traversal cursor or transaction covering the entire cascade. [Status update and traversal](https://github.com/dbos-inc/dbos-transact-ts/blob/d8c4974cca6cc84b296f3b8edfbbb41627ddd47e/src/system_database.ts#L1858-L1887), [child query](https://github.com/dbos-inc/dbos-transact-ts/blob/d8c4974cca6cc84b296f3b8edfbbb41627ddd47e/src/system_database.ts#L2036-L2047)
- The ordinary internal-step executor looks up a recorded result before running the callback. It records the result after the callback returns. These are separate operations; this is not the transactional internal-step helper. [Executor](https://github.com/dbos-inc/dbos-transact-ts/blob/d8c4974cca6cc84b296f3b8edfbbb41627ddd47e/src/dbos-executor.ts#L1266-L1296), [transactional helper distinction](https://github.com/dbos-inc/dbos-transact-ts/blob/d8c4974cca6cc84b296f3b8edfbbb41627ddd47e/src/dbos.ts#L402-L427)

Inference: DBOS is a strong example of reusing normal status and operation-result machinery. It is not evidence that a standalone recursive cancellation automatically finishes after a caller crash between levels. A call made by another recovering workflow can replay, but interruption before its result checkpoint can repeat the callback. In particular, the source allows explicit resumption to make a workflow cancellable again; do not extrapolate a guarantee that a repeated cancellation cannot affect resumed work. No DBOS fault-injection test was run.

## Azure Durable Functions / Durable Task: persisted termination messages

Azure explicitly lists orchestration termination messages among persisted task-hub data. Instance status and history also persist. With the Azure Storage backend, termination uses the existing control queues that carry starts, activity completions, timers, and external events, with at-least-once delivery. This is shared orchestration infrastructure, not a separate volatile cancellation channel. [Persistence contract](https://learn.microsoft.com/en-us/azure/durable-task/durable-functions/durable-functions-serialization-and-persistence#task-hub-contents), [Azure Storage control queues](https://learn.microsoft.com/en-us/azure/azure-functions/durable/durable-functions-azure-storage-provider#queues)

The documented .NET `DurableTaskClient.TerminateInstanceAsync(string, object, CancellationToken)` API completes when the termination message is enqueued. A worker processes it and updates the target instance to `Terminated`. Cancelling the API's token only cancels enqueueing; it does not retract an already-enqueued termination. The documented operation does not terminate in-flight activities or sub-orchestrations: their execution continues and separate termination requests are needed for child instances. This API is forced orchestration termination, not a cooperative cancellation handler. Scope this finding to the cited API/backend documentation rather than every Durable Task provider or future overload. [Termination API and remarks](https://learn.microsoft.com/en-us/dotnet/api/microsoft.durabletask.client.durabletaskclient.terminateinstanceasync?view=durabletask-dotnet-1.x)

Lesson: durable stop intent does not imply a universal propagation policy. When propagation is wanted, it needs to be represented, but the termination command itself already belongs to the normal durable transport and state model.

## AWS Step Functions Standard: durable abort, best-effort downstream stop

`StopExecution` targets an execution ARN and returns its stop time; Express workflows do not support this API. The public history schema includes `ExecutionAborted` and state/task-aborted events, while `DescribeExecution` exposes `ABORTED` status. These document a persisted orchestration outcome, not just cancellation of the requesting client's connection. AWS's private storage and recovery algorithm were not inspected. [StopExecution](https://docs.aws.amazon.com/step-functions/latest/apireference/API_StopExecution.html), [history schema](https://docs.aws.amazon.com/step-functions/latest/apireference/API_HistoryEvent.html), [execution status](https://docs.aws.amazon.com/step-functions/latest/apireference/API_DescribeExecution.html)

For `.sync` integrations, stopping the state machine triggers a best-effort attempt to cancel its task. For a nested `states:startExecution.sync`, that means calling `StopExecution` on the child execution. AWS explicitly names missing permissions and temporary outages as reasons it may fail, and warns that downstream charges can continue. The documented guarantee therefore does not establish eventual successful propagation to every external task. [Service integration cancellation](https://docs.aws.amazon.com/step-functions/latest/dg/connect-to-resource.html#connect-sync)

Lesson: cancellation of orchestration, delivery of a downstream stop, and physical/billing cessation are different facts. A cloud service's weaker external-stop guarantee is not a reason OnePage's local database operations must also be best effort.

## Kubernetes: a durable control-plane analogue

Kubernetes deletion with finalizers records a `deletionTimestamp`, returns acceptance, and retains the object until its cleanup conditions are satisfied. Controllers observe that stored state, perform cleanup, and remove finalizer keys. Cascading deletion uses owner references; those references include object UIDs. This is deletion/finalization rather than workflow cancellation, but it shows a second representation: durable desired state plus reconciliation instead of a replayed imperative program. [Finalizers](https://kubernetes.io/docs/concepts/overview/working-with-objects/finalizers/), [owner identities](https://kubernetes.io/docs/concepts/overview/working-with-objects/owners-dependents/)

This analogy has limits. Foreground deletion only blocks on the dependents covered by the garbage collector's documented cache and owner-reference rules; it is not an unconditional promise to discover every concurrently created dependent. It also deletes an object incarnation permanently, unlike stopping current work in a reusable OnePage Session. [Garbage-collection limits](https://kubernetes.io/docs/concepts/architecture/garbage-collection/#foreground-deletion)

## Implications to evaluate for OnePage

The workflow systems surveyed persist cancellation or termination requests/outcomes. Propagation differs: Temporal and Restate explicitly represent it through their normal durable execution infrastructure; DBOS combines status updates with ordinary step checkpoints when called from a workflow; Azure's cited termination API does not propagate; AWS documents best-effort downstream stopping. Durable cancellation is common, but the word durable does not establish every propagation or physical-stop guarantee.

Restate's replay test is the closest construction to the question: cancellation propagation reuses normal journal commands, while retaining each command's identity and target. This supports composition, not cancellation with no additional durable facts.

Temporal and Restate do not give a direct precedent for OnePage's `stop(Session)` selecting whatever work happens to be current in a reusable, shared Session. Restate targets invocation IDs; Temporal exposes execution and chain constraints. The OnePage-specific question remains where a Session stop's target selection becomes a durable fact, including an idle result. It may fit an existing operation/result record; the research does not establish a need for a separate queue or tracking subsystem.

Another relevant distinction: OnePage's proposed per-Session stop selection can include another workflow's current work. The call-tree cancellation semantics above should not be copied as if they already implement that shared-Session contract.

The minimal OnePage direction to investigate is therefore:

1. Commit the Run cancellation fence using the Store's normal transaction boundary.
2. Represent each required Session stop through the same durable admission/result discipline as other Host operations. The target selection, semantic stop, and recorded result should commit together in the local Store, or an equivalent atomic representation must prove the same behavior. A generic step wrapper that records only after its effect is insufficient to prove this boundary.
3. Recover outstanding stops from those facts. Do not reselect current Session work after an already-committed result; an idle result is a completed stop with no selected work.
4. Let existing Operation/Attempt cleanup handle physical effects. Recorded stopping is not proof of provider billing cessation.

This is a research recommendation, not acceptance of a schema, general command framework, new queue, or propagation policy. The Session-facing API can remain simple; concrete work identity can stay internal. OnePage fences ordinary evaluator execution on Run cancellation, so propagation must remain permitted on the Host control path. Reusing durable primitives does not mean rerunning ordinary cancelled workflow code or adopting another product's cancellation scopes and cleanup language.

The one-transaction alternative in the [local cancellation investigation](../design/workflow-cancellation-stop-mapping.md#alternative-select-all-targets-atomically) is still unselected. This research does not establish that per-Session receipts are the only possible representation; changing when all targets are selected changes the tradeoff.

## Source versions and evidence limits

- Temporal server: `891d1b648b7252925142cc36f13e40a0e2ed4244`.
- Temporal API schemas: `68c7e8c7b361e77e9cb5d8f9b9c9bcc631382f01`.
- Restate server: `64d12f01368b66cf88a3f78ba4397f129b623fc9`.
- Restate SDK shared core: `bcdf52777955b36bed611483abd227db03b9a09c`.
- DBOS TypeScript: `d8c4974cca6cc84b296f3b8edfbbb41627ddd47e`.
- Azure, AWS and Kubernetes: the official documentation/API contracts linked above; no deployed service was probed.

These were upstream default-branch snapshots inspected on 2026-09-05, not a verified combination of deployed releases. Documentation was read live on the same date. Source inspection and upstream test definitions establish representation and intended behavior; they do not substitute for testing OnePage's implementation or proving upstream end-to-end guarantees under every failure.
