# Retry and failure taxonomy: non-agent-harness prior art

Research date: 2026-09-03

This note looks for the smallest established taxonomy that can decide whether OnePage should:

1. create a replacement Attempt for the same Model Operation and replay its immutable Model Request
   Manifest;
2. continue only after independently admitted input or state changes; or
3. stop automatic retry and either await an explicit change or settle at the correct enclosing level.

It uses only specifications, official documentation, and first-party source. It is design research,
not a normative decision.

## Recommendation

Adopt a **retry-scope taxonomy**, not a universal list of retryable errors:

| Disposition | OnePage meaning | Durable consequence |
|---|---|---|
| **Replacement Attempt** | Retry the same semantic Operation with a new Attempt and the exact immutable request manifest. Only timing, transport connection, and attempt identity may differ. | Commit the failed Attempt Completion and future eligibility together; leave the Operation unresolved. |
| **Higher-Level Continuation** | The same request is not eligible for automatic replay. Something relevant must change: request content, surrounding state, credentials/configuration, or model-visible corrective context. | Resolve the current Operation as rejected or failed. Any continuation is an ordinary new Operation with a new immutable manifest, not a special Operation kind. |
| **No Automatic Retry** | Time and repetition alone cannot fix the condition, or the retry/correction budget is exhausted. | Resolve the Operation. Ordinary composition may use already-pending input, await an explicit external change if the product exposes such a state, or settle the Turn only when no legal recovery remains. |

Before choosing among them, apply a separate **effect-certainty gate**. If the previous external effect
might have happened and replay is not semantically idempotent or protected by the same idempotency key,
reconcile observable state or preserve uncertainty; do not blindly replay it.

This is almost exactly the scope distinction in gRPC's official status guidance, while Temporal's
durable schema is the clearest precedent for storing cause, retry disposition, and outcome separately:

- `UNAVAILABLE`: retry just the failing call;
- `ABORTED`: retry at a higher level, such as restarting a read-modify-write sequence; and
- `FAILED_PRECONDITION`: do not retry until system state has been explicitly fixed.

([gRPC status codes](https://grpc.io/docs/guides/status-codes/#full-list-of-status-codes))

OnePage should adopt that distinction in its own domain vocabulary, not copy the gRPC codes. The same
cause can have different dispositions depending on effect certainty, operation semantics, provider
advice, and remaining budget.

## Keep three dimensions separate

### 1. Failure cause is observed evidence

A cause says what was observed, not what to do. A compact provider-neutral cause vocabulary is enough:

- **availability**: connection loss, unavailable service, timeout, or lost execution custody;
- **capacity**: rate limit, temporary overload, quota, or local resource pressure;
- **request**: invalid, too large, unauthenticated, unauthorized, or unsupported request;
- **response rejection**: a complete response is malformed, structurally invalid, or too large for
  OnePage to admit;
- **state conflict**: failed precondition, optimistic-concurrency conflict, or stale snapshot;
- **integrity**: corruption, data loss, or a broken internal invariant;
- **cancellation**: an authoritative user or system cancellation; and
- **indeterminate effect**: execution may have occurred but no authoritative result was obtained.

Preserve the provider's raw code and bounded diagnostics beside this classification. Do not put
`retryable` in the cause name: `RESOURCE_EXHAUSTED`, `DEADLINE_EXCEEDED`, HTTP `500`, process exit 1,
and SQLite `BUSY` do not carry enough context to determine a safe retry scope by themselves.

### 2. Retry disposition is a policy decision

The policy evaluates at least:

- whether the request/effect is safe to repeat, or the original is known not to have applied;
- whether replay would use the same immutable manifest or requires changed input/state;
- any explicit provider retry hint, such as a delay;
- attempt count, elapsed deadline, and fleet-level throttling; and
- whether cancellation or another SQLite resolution already won the race.

The policy produces one of the three dispositions above plus, for Replacement Attempt, an immutable
`eligible_at`. That field is scheduling data, not a fourth lifecycle state.

### 3. Semantic outcome belongs to the correct level

An Attempt can complete unsuccessfully without making its Operation fail. A retryable Completion is
evidence that one Attempt ended; the Operation remains unresolved. Conversely, a complete model response
can be an unsuccessful semantic result even though transport succeeded.

Keep at least these levels distinct:

- **Attempt Completion**: bounded observed evidence for one physical try;
- **Operation Resolution**: the single selected meaning, such as accepted, rejected, failed, cancelled,
  or uncertain; and
- **Turn Outcome**: completed, failed, or cancelled after no unresolved work can still change it.

This prevents "the HTTP call failed", "the model output was rejected", and "the Turn failed" from
becoming the same fact.

## Prior art

### gRPC: the closest reusable taxonomy

gRPC explicitly separates a call from its attempts. A retry creates a **new retry stream** and replays
the saved call history. Once response headers arrive, the RPC is **committed** and gRPC performs no more
automatic retries. Transparent retry is narrower still: it is allowed without policy only when the RPC
never left the client, or once when it reached the server library but not application logic
([gRPC retry guide](https://grpc.io/docs/guides/retry/#how-grpc-client-retry-works),
[transparent retry](https://grpc.io/docs/guides/retry/#transparent-retry)).

The status vocabulary then distinguishes retry scope rather than declaring all errors globally
retryable. `UNAVAILABLE` is usually transient but still warns that non-idempotent operations might not
be safe to retry. `ABORTED` asks the caller to restart a higher-level sequence. `FAILED_PRECONDITION`
requires explicit state repair. `INVALID_ARGUMENT` is independent of current state, while
`OUT_OF_RANGE` might become valid after state changes. `DATA_LOSS` is unrecoverable
([gRPC status codes](https://grpc.io/docs/guides/status-codes/#full-list-of-status-codes)).

**Lesson for OnePage:** call-level retry maps to Replacement Attempt; higher-level restart or repaired
precondition maps to Higher-Level Continuation; unrecoverable or exhausted cases map to No Automatic Retry.
The "committed" boundary is also a useful warning: retry policy must consider what the recipient could
already have observed, not only the local exception.

### HTTP: idempotency and uncertainty dominate status classes

HTTP defines an idempotent request by intended server effect, not by receiving an identical response.
An idempotent request may be repeated after a communication failure even if the first request succeeded.
A client should not automatically retry a non-idempotent request unless it knows the request semantics
are idempotent or knows the original was never applied
([RFC 9110 section 9.2.2](https://www.rfc-editor.org/rfc/rfc9110.html#section-9.2.2)).

Status codes supply evidence and hints, not a complete retry table:

- `408 Request Timeout` says the server did not receive a complete request and permits repeating an
  outstanding request.
- `409 Conflict` says current resource state prevented completion and anticipates that the caller may
  resolve the conflict and resubmit.
- `413 Content Too Large` says the request exceeds what the server will process; unchanged replay does
  not address the cause.
- `503 Service Unavailable` describes temporary overload or maintenance and can include `Retry-After`.

([RFC 9110 status definitions](https://www.rfc-editor.org/rfc/rfc9110.html#section-15),
[`Retry-After`](https://www.rfc-editor.org/rfc/rfc9110.html#section-10.2.3))

**Lesson for OnePage:** transport failure is not proof of non-execution. An identical replay requires
effect safety, not merely a 4xx/5xx category. Provider delay hints should influence `eligible_at`; they
should not determine semantic outcome. Request-too-large and conflict responses belong to Corrective
Operation, not Replacement Attempt.

### Temporal: retry an Activity Attempt, not the whole durable computation

Temporal's Retry Policy is declarative policy for trying an Activity or Workflow again after failure.
Activities receive a default exponential-backoff policy; Workflow Executions do not retry by default.
Temporal recommends placing failure-prone or non-deterministic external work, including API calls and
LLM invocations, in Activities and retrying those specific failure points rather than redundantly
restarting the Workflow
([Temporal Retry Policies](https://docs.temporal.io/encyclopedia/retry-policies)).

Temporal also separates the failure object from retry disposition. An Activity Failure carries the last
Activity Task's Application Failure as its `cause`. Application Failure separately carries `type`,
details, `non_retryable`, and an optional next retry delay
([Temporal Failure API](https://github.com/temporalio/api/blob/10a041c3eb639786707e2a7f5881fee26e7a5ef5/temporal/api/failure/v1/message.proto#L19-L29),
[Application Failure API](https://github.com/temporalio/api/blob/10a041c3eb639786707e2a7f5881fee26e7a5ef5/temporal/api/failure/v1/message.proto#L106-L135)).
Application Failure `type` is matched against policy `non-retryable errors`, or the failure can
explicitly set `non_retryable`
([Temporal failure reference](https://docs.temporal.io/references/failures#application-failure),
[non-retryable errors](https://docs.temporal.io/encyclopedia/retry-policies#non-retryable-errors)).

The durable `RetryState` is a different enum: retry can still be in progress or can have stopped because
of a non-retryable failure, timeout, maximum attempts, missing policy, server error, or requested
cancellation. Temporal's failed-event schema stores the `failure`, `retry_state`, and a linked new Run ID
as independent fields
([Temporal `RetryState`](https://github.com/temporalio/api/blob/10a041c3eb639786707e2a7f5881fee26e7a5ef5/temporal/api/enums/v1/workflow.proto#L108-L117),
[failed-event schema](https://github.com/temporalio/api/blob/10a041c3eb639786707e2a7f5881fee26e7a5ef5/temporal/api/history/v1/message.proto#L233-L247)).

Temporal warns that Activities can execute more than once and therefore recommends idempotency; if an
Activity completes but its Worker cannot report completion, the Activity is executed again
([Temporal Activities](https://docs.temporal.io/activities#activity-idempotency)).

When state or arguments must change, Temporal has a different operation: Continue-As-New checkpoints
state into arguments and starts a fresh Run with a new Event History. It is explicitly not an attempt
retry. Workflow Execution status is also separate from retry state: it records Running, Completed,
Failed, Canceled, Terminated, Continued-As-New, Timed-Out, or Paused
([Temporal Continue-As-New](https://docs.temporal.io/workflow-execution/continue-as-new#what-is-continue-as-new),
[Workflow status API](https://github.com/temporalio/api/blob/10a041c3eb639786707e2a7f5881fee26e7a5ef5/temporal/api/enums/v1/workflow.proto#L72-L83)).

**Lesson for OnePage:** make the Attempt the retry unit; keep the enclosing Operation/Turn durable and
unresolved. Store cause, non-retry policy, delay, and exhaustion separately. Do not restart a whole Turn
to recover one provider invocation, and do not claim exactly-once execution around a lost completion.

### PostgreSQL and SQLite: the safe restart boundary is operation-specific

PostgreSQL requires applications to retry a transaction after `serialization_failure` and recommends
considering retries for deadlocks. Crucially, it says to retry the **complete transaction, including the
logic that chose SQL and values**, not merely the failed statement. PostgreSQL does not automate this
because it cannot guarantee application-level correctness. Unique and exclusion violations require more
care because they can be either concurrency artifacts or persistent conditions
([PostgreSQL serialization failure handling](https://www.postgresql.org/docs/current/mvcc-serialization-failure-handling.html)).

SQLite is even more explicit about scope. `SQLITE_BUSY` means another connection prevented progress,
whereas `SQLITE_LOCKED` usually identifies a conflict within the same connection or shared cache
([SQLite result codes](https://www.sqlite.org/rescode.html#busy)). For `sqlite3_step`, a `BUSY` result
from `COMMIT` or outside an explicit transaction can be retried; a `BUSY` result from a statement inside
an explicit transaction requires rollback before continuing
([SQLite `sqlite3_step`](https://www.sqlite.org/c3ref/step.html)). A `COMMIT` blocked by a reader leaves
the transaction active and can be retried later
([SQLite transactions](https://www.sqlite.org/lang_transaction.html#implicit_versus_explicit_transactions)).

**Lesson for OnePage:** "database contention" does not mean "repeat the last statement". SQLite should
arbitrate races, but the host must restart the transaction closure at the documented boundary and reread
authoritative rows. A uniqueness loss that means another writer already resolved the Operation is not a
transient failure; it is the winning semantic result.

### Kubernetes Jobs: map observed failure to action, then apply a budget

A Kubernetes Job replaces a failed Pod, and the application must tolerate temporary files, locks, and
incomplete output from earlier runs. The same program can sometimes be started twice even with one
completion and parallelism one. By default, failures count toward `backoffLimit`, after which the Job is
failed
([Kubernetes Jobs: handling failures](https://kubernetes.io/docs/concepts/workloads/controllers/job/#handling-pod-and-container-failures),
[Pod backoff policy](https://kubernetes.io/docs/concepts/workloads/controllers/job/#pod-backoff-failure-policy)).

`podFailurePolicy` makes the cause-to-action mapping explicit. Rules match exit codes or Pod conditions
and choose `Ignore` (replacement without consuming budget), `Count` (replacement consuming budget),
`FailIndex`, or `FailJob`. The official example ignores infrastructure disruption but immediately fails
the Job for an exit code representing a software bug
([Kubernetes Pod failure policy](https://kubernetes.io/docs/concepts/workloads/controllers/job/#pod-failure-policy)).

Kubernetes also separates the decision to end a Job from cleanup completion: it first records
`FailureTarget` or `SuccessCriteriaMet`, and records terminal `Failed` or `Complete` only after the Pods
terminate
([termination of Job Pods](https://kubernetes.io/docs/concepts/workloads/controllers/job/#termination-of-job-pods)).

**Lesson for OnePage:** cause, budget accounting, replacement, and final Job outcome are independent.
Do not encode all of them in a single enum such as `retryable_transport_failure`. Infrastructure loss
can justify a replacement Attempt without consuming the same budget as a malformed complete result, if
OnePage intentionally chooses that policy.

### systemd: restart classification is configurable policy

systemd classifies process termination by clean exit, non-zero exit, signal, timeout, watchdog, or OOM,
then maps those causes through `Restart=`. `RestartPreventExitStatus=` and `RestartForceExitStatus=` can
override the general mapping, and start-rate limits bound repeated restarts. The documentation recommends
`Restart=on-failure` for long-running services but explicitly does not restart a service stopped by the
service manager
([systemd `systemd.service` source](https://github.com/systemd/systemd/blob/2451b1a9c47153d019e433d490b296521035375b/man/systemd.service.xml#L879-L1013),
[restart overrides](https://github.com/systemd/systemd/blob/2451b1a9c47153d019e433d490b296521035375b/man/systemd.service.xml#L1105-L1143)).

**Lesson for OnePage:** process exit cause is evidence; restart is supervisor policy; intentional stop is
a different semantic event; rate limiting is another independent guard. Avoid treating a provider or
process exit code as a durable Operation Resolution.

## Proposed OnePage decision table

| Observation | Default disposition | Why |
|---|---|---|
| Connection failed before dispatch was observable | Replacement Attempt | Comparable to gRPC transparent retry; exact manifest is unchanged. |
| Lost provider transport or Host custody after dispatch | Replacement Attempt only because model generation is policy-approved for replay; record possible duplicate work/billing | HTTP and Temporal show that lost acknowledgement is not proof of non-execution. |
| Explicit transient unavailable, overload, or rate-limit response | Replacement Attempt at bounded `eligible_at` | Same Operation can still succeed without semantic input change. Honor a bounded provider delay hint. |
| Timeout/deadline | Depends on effect certainty and operation semantics | gRPC says a deadline can be returned even when a state-changing operation completed. Do not make timeout globally retryable. |
| Complete response exceeds an admission limit or has malformed Tool Call/structure | Higher-Level Continuation or No Automatic Retry, as #91 decides | Replaying the identical manifest does not incorporate the known rejection. This research does not invent a validation-diagnostic input or implicitly admit another Model Operation. |
| Immutable request itself is too large or invalid | Higher-Level Continuation if OnePage has an authorized deterministic transformation; otherwise No Automatic Retry | A new manifest is required. This is not another Attempt of the same Operation. |
| Stale precondition or concurrency conflict | Higher-Level Continuation | Reread authoritative state and form a new request or transaction, as gRPC `ABORTED`, HTTP 409, and PostgreSQL require. |
| Invalid credentials or fixable configuration | No Automatic Retry; later work uses a new Operation or Attempt only after explicit repair | Time alone does not change the condition. |
| Unsupported capability, permission denial, integrity failure, or data loss | No Automatic Retry | Blind repetition is unsafe or futile. Whether the Turn can recover is a separate enclosing-level decision. |
| Direct Model Interruption wins the SQLite resolution race | Interrupted Resolution; no replacement Attempt for that Operation | The committed Resolution is semantic authority, not a retryable failure. Late provider evidence cannot become Completion, Conversation, or continuation input. Ordinary advancement separately derives whether pending User Messages require another model Operation or the Turn becomes cancelled. |
| Retry or corrective budget exhausted | No Automatic Retry | Every cited supervisor has a policy or time boundary; none makes retry success inevitable. |

## Adopt

1. **Replacement Attempt / Higher-Level Continuation / No Automatic Retry** as the stable three-way
   disposition vocabulary.
2. A separate provider-neutral **cause** plus raw upstream code, stage, bounded diagnostics, and optional
   retry delay.
3. An explicit **effect-certainty/idempotency gate** before identical replay.
4. SQLite-enforced one Completion per Attempt and one Resolution per Operation; first durable resolution
   wins every cancellation/completion race.
5. Retry budgets and `eligible_at` as policy metadata, never as semantic outcomes.
6. A rejected complete model response as an Operation Resolution. Any correction requires an independently
   specified canonical input and a new Model Operation; #91 must not manufacture an implicit diagnostic or
   call a changed request another try of the old immutable request.

## Avoid

1. A single `retryable` boolean on a failure code. It hides retry scope, effect uncertainty, and budget.
2. Deriving policy from HTTP class, gRPC code, provider wording, or process exit code alone.
3. Calling a changed request an Attempt retry. Immutability makes it a new Operation.
4. Treating an unsuccessful Attempt as an unsuccessful Operation or Turn.
5. Automatic replay after ambiguous state-changing effects without idempotency or reconciliation.
6. Endless retry. Backoff reduces pressure; it does not make a persistent failure transient.

## Bottom line

The strongest prior art is not a detailed failure-code hierarchy. It is gRPC's small distinction between
retrying the failing call, restarting at a higher semantic level, and waiting for explicit repair;
Temporal's durable separation of Failure, RetryState, and Workflow status; HTTP's idempotency rule; and
supervisors' separate retry budgets. In OnePage terms, that becomes **Replacement Attempt,
Higher-Level Continuation, or No Automatic Retry**. Failure cause and final semantic outcome remain
separate axes.
