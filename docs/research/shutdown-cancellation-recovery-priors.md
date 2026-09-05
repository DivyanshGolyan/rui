# Shutdown, cancellation, and recovery priors

> **Historical evidence published 6 September 2026.** The observations and recommendations below retain their investigation context. Subsequent accepted decisions and retired implementation tickets do not change the measured results; this publication makes no production-certification claim.

Research date: 2026-09-05.

Decision status: evidence only. This note informs [Choose live Host ownership and cross-process command semantics](https://github.com/DivyanshGolyan/onepage/issues/100); it does not approve a OnePage shutdown policy. Research is tracked in [Research shutdown, cancellation, and recovery contracts across execution systems](https://github.com/DivyanshGolyan/onepage/issues/107).

## Finding

There is no uniform industry rule that server shutdown should either finish or immediately abort all in-flight work. Agent harnesses themselves disagree. The useful shared distinction is between an executor's lifetime, the continuing intent of its work, and what is safe to repeat after an uncertain result.

The earlier proposal that graceful stop should wait for each operation's normal deadline is not established as an industry requirement. A shutdown-specific grace period, which may be zero, and forced escalation are common alternatives. A clean stop can interrupt work and still preserve recoverability; it need not mean successful completion of that work.

## Comparison at a glance

Read the linked evidence sections for transport, SDK, and version scope. “Resume” does not mean reconnecting to the same remote request unless the source explicitly supplies that guarantee.

| System | Owner shutdown | Work after restart | Important qualification |
| --- | --- | --- | --- |
| OpenCode V2, pinned implementation | Shutdown interrupts execution while preserving its durable claim | Managed startup resumes claimed work, with a persistent retry bound | Explicit user interruption releases intent; repeated external effects remain possible |
| Codex multi-client app-server, pinned implementation | First signal drains assistant Turns; repeated forceable signal forces exit | These sources do not establish automatic crash redispatch | Whole-Turn drain; requests remain accepted while draining; excludes stdio mode |
| Claude Agent SDK Python, pinned implementation | Small EOF grace for persistence, then terminate/kill escalation | Explicit Session continuation is available | Process cleanup grace is not a promise to finish an LLM call |
| Temporal | Stop polling; optional Activity grace; cooperative cancellation follows | Durable workflow history and Activity retry rules govern recovery | Inspected Python default grace is zero; cancellation can still fail to end shutdown promptly |
| Celery 5.5.3 | Normal TERM drains; other modes interrupt or bound the wait | Broker acknowledgement and redelivery rules govern recovery | Task cancellation and worker shutdown are separate; duplicates or loss depend on policy |
| PostgreSQL 18 | Default pg_ctl stop aborts transactions, then shuts down cleanly | Immediate mode additionally requires WAL recovery | Fast clean shutdown is distinct from both full drain and crash |
| NGINX | Separate fast stop and graceful quit; optional graceful timeout | No durable workflow recovery contract | Explicit modes, not a single universal meaning of stop |
| Kubernetes | Application termination grace, then forced kill | Application/controller policy owns recovery | Infrastructure grace does not imply remote-effect cancellation or business completion |

## Agent harness precedents

Implementation claims use immutable revisions; these are not claims about all released versions or every transport.

### OpenCode V2: interrupt on shutdown, preserve intent, resume automatically

At the previously researched V2 pin `8ba434b5973856b2f32b8cd3543e154b25c413e6`, execution records a durable claim before running. User interruption releases it; shutdown interruption preserves it. Thus an intentional server restart and a crash both leave work eligible for restart, while explicit cancellation does not resurrect. This directly contradicts treating server shutdown as Run cancellation. [Execution lifecycle, lines 71–139](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/core/src/session/execution.ts#L71-L139)

Managed-server startup invokes the restart sweep; the source explicitly covers graceful and unclean deaths without relying on a shutdown hook. Shutdown removes the application and closes incoming connections. [Server lifecycle, lines 84–90 and 230–237](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/server/src/process.ts#L84-L90), [restart installation](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/server/src/process.ts#L230-L237)

The restart sweep has a durable per-turn attempt count, default maximum 10, and terminalizes repeated interruptions rather than crash-looping forever. It adds a continuation instruction to the Session. Its contract explicitly states at-least-once recovery does not prevent repeated external effects. It assumes the prior owner is dead; only the managed server performs this sweep automatically. [Restart policy, lines 15–96](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/core/src/session/execution/restart.ts#L15-L96)

**Interpretation:** strong precedent for prompt shutdown interruption plus durable continuation. No evidence here guarantees provider billing stops immediately, exactly-once tools, or no duplicate model spending. OpenCode's continuation prompt is also weaker than OnePage's proposed effect-specific replay contract.

### Codex app-server: graceful turn drain, then force on repeated signal

At `459a79eb85400af759e9220c7bafb4429ae07516`, multi-client app-server installs a shutdown handler: first SIGINT/SIGTERM requests graceful drain; another forceable signal forces shutdown. SIGHUP requests graceful-only behavior. The drain waits for zero running assistant turns, **continues accepting requests while waiting**, then stops acceptance and disconnects clients. This is a turn drain, not merely collecting one already-issued LLM request. The handler is disabled for stdio/single-client mode. Forced shutdown skips the normal background/task/thread cleanup path. [Signals and drain, lines 205–300](https://github.com/openai/codex/blob/459a79eb85400af759e9220c7bafb4429ae07516/codex-rs/app-server/src/lib.rs#L205-L300), [transport condition, lines 742–744](https://github.com/openai/codex/blob/459a79eb85400af759e9220c7bafb4429ae07516/codex-rs/app-server/src/lib.rs#L742-L744), [cleanup branch, lines 1203–1216](https://github.com/openai/codex/blob/459a79eb85400af759e9220c7bafb4429ae07516/codex-rs/app-server/src/lib.rs#L1203-L1216)

The API separately exposes `turn/interrupt`, acknowledged by subsequent `turn/completed` with interrupted status. It does not stop background terminals. `thread/resume` reopens history so later `turn/start` calls append; this does not itself establish automatic post-crash completion of interrupted model calls. [Interrupt contract](https://github.com/openai/codex/blob/459a79eb85400af759e9220c7bafb4429ae07516/codex-rs/app-server/README.md#L1375-L1387), [resume contract](https://github.com/openai/codex/blob/459a79eb85400af759e9220c7bafb4429ae07516/codex-rs/app-server/README.md#L183-L184)

**Interpretation:** direct precedent for drain-first server shutdown, but not for OnePage's exact proposed stop-admission/drain-one-Operation boundary. No general automatic crash-recovery or provider-charge guarantee was established from these sources.

### Claude Agent SDK Python: bounded teardown grace for persistence

At `b1b838b1c5730a7a0b270915a79b15861a8ca716`, subprocess transport close ends stdin, allows **5 seconds** for exit, sends terminate and allows **5 seconds**, then kills and waits at most **5 seconds**. The source explains that the first grace period lets CLI flush its Session transcript: immediate SIGTERM could lose the last assistant message. This is evidence for bounded cleanup before escalation, not a promise to finish an expensive in-flight model response. [Subprocess close, lines 942–1035](https://github.com/anthropics/claude-agent-sdk-python/blob/b1b838b1c5730a7a0b270915a79b15861a8ca716/src/claude_agent_sdk/_internal/transport/subprocess_cli.py#L942-L1035)

The SDK documents explicit Session reuse via `resume`/`continue_conversation`; persistent Session history is not an independently supervised workflow. Interrupting an active response and disconnecting the SDK are distinct controls. [Python SDK interface](https://code.claude.com/docs/en/agent-sdk/python), [Session continuation](https://code.claude.com/docs/en/agent-sdk/sessions)

**Interpretation:** useful prior for a small shutdown grace period to persist already-earned results and reap processes. It does not settle server-owned Run restart policy; this SDK hosts a CLI subprocess rather than the independent local server OnePage is designing.


## Durable workflow and job systems

### Temporal

#### Worker shutdown is an infrastructure operation

A shutting-down worker stops polling. A configurable grace period lets current Activities finish; afterward their contexts are cancelled. SDK behavior varies: the documentation says Core waits for Activities, whereas Go shutdown can complete while an Activity remains running. This is a cooperative cancellation boundary, not proof of remote cancellation or a universal process-exit deadline. Local Activities have additional workflow-task coupling, so they are not a clean analogue for OnePage model calls. [Worker shutdown behavior](https://docs.temporal.io/encyclopedia/workers/worker-shutdown)

The Python SDK notifies Activities when shutdown begins. Once its grace interval expires, it cancels outstanding Activities, but `shutdown()` still waits for their completion; an Activity ignoring cancellation can prevent completion indefinitely. [Python SDK worker shutdown](https://github.com/temporalio/sdk-python#worker-shutdown)

Crucial counterexample to “industry always drains”: the inspected Python SDK constructor defaults `graceful_shutdown_timeout` to `timedelta()`, i.e. zero. This is a configurable grace-before-cancel policy, not an unconditional finish-everything policy. Source verified at commit `22a9e41fd857261ee0a9bb5ce57f439d93e7f88d`, line 134. [Pinned Python Worker constructor](https://github.com/temporalio/sdk-python/blob/22a9e41fd857261ee0a9bb5ce57f439d93e7f88d/temporalio/worker/_worker.py#L134)

#### Workflow cancellation is a separate durable request

Cancelling a Workflow records `WorkflowExecutionCancelRequested` and schedules a Workflow Task, allowing workflow cleanup. Termination instead records a terminal event without allowing workflow code to handle it. These are explicit execution-level actions, distinct from stopping a worker. Cancellation is not proof that external Activity work stopped: regular Activities receive it through heartbeats. [Python Workflow cancellation and termination](https://docs.temporal.io/develop/python/workflows/cancellation)

#### Crash recovery and repeat work

Temporal detects lost Activity attempts through timeout rather than direct worker-death detection. A timed-out Activity is retried according to its Retry Policy; setting maximum attempts to one prevents that retry. Activities may accept or ignore cancellation. Thus a crash is neither automatic terminal Workflow cancellation nor an unconditional retry instruction. [Activity execution](https://docs.temporal.io/activity-execution)

Completed Activities are reused during replay. But if external work succeeds and the worker dies before reporting completion, the Activity can execute again. Temporal explicitly recommends externally enforced idempotency keys and warns about duplicate charges. Retry backoff survives worker crashes. Its durability guarantee does not make an arbitrary outbound request execute exactly once. [Activity definition, idempotency, and retry policy](https://docs.temporal.io/activity-definition)

Inference for OnePage: retain Run intent independently of server lifetime; reconstruct committed results, then apply effect-specific retry rules to unresolved attempts. A server shutdown API must separately define stopping new dispatch, waiting, cancellation, and the limit on waiting. These priors do not determine whether OnePage should have zero or positive grace.

### Celery

#### Multiple explicit shutdown modes, with draining as the normal stop

In the versioned 5.5.3 documentation, `TERM` requests warm shutdown: running tasks finish. `QUIT` requests cold shutdown. An optional soft phase gives current tasks a bounded chance to finish before cold cancellation; it is disabled by default. Hard shutdown cannot guarantee restoration even when the log reports restoring unacknowledged messages. Task revocation is separate: it skips a task but does not interrupt an already running task unless termination is requested. Revokes are normally held in memory and require `--statedb` to persist across a full worker restart. [Celery 5.5.3 worker guide](https://docs.celeryq.dev/en/v5.5.3/userguide/workers.html)

#### Crash delivery is an acknowledgement policy, not a promise inherent in shutdown

Late acknowledgement is disabled by default. Even when enabled, an abruptly lost worker child may have its task acknowledged unless `task_reject_on_worker_lost` is enabled. Enabling that option requeues the task and can cause loops. Broker connection loss is another case: an unacknowledged task can be redelivered while the old execution still runs, producing duplicate concurrent execution. Celery therefore requires idempotence for such tasks. [Celery configuration: acknowledgements and connection loss](https://docs.celeryq.dev/en/stable/userguide/configuration.html#task-reject-on-worker-lost)

Inference for OnePage: never describe an interrupted Attempt simply as “it resumes.” Say whether the existing external execution is reattached, the operation is dispatched again, or a typed uncertainty/failure is recorded. Celery's worker stop modes are useful precedents; its defaults and best-effort revoked-task memory would not provide OnePage's intended durable Run cancellation contract.


## Service and database precedents

### PostgreSQL 18: fast clean shutdown is distinct from a crash

PostgreSQL exposes three modes: smart refuses new connections and waits for sessions; fast aborts current transactions and disconnects clients before clean shutdown; immediate skips normal shutdown and requires WAL recovery next time. `pg_ctl stop` defaults to fast. This is a concrete counterexample to treating graceful shutdown as necessarily waiting for successful work completion. Database rollback cannot be assumed for external model or shell effects. [Shutdown modes](https://www.postgresql.org/docs/18/server-shutdown.html), [pg_ctl default and behavior](https://www.postgresql.org/docs/18/app-pg-ctl.html).

The client's `pg_ctl` wait timeout is not a server termination deadline: the control command can time out while shutdown continues. OnePage should likewise distinguish a client acknowledgement/wait limit from an executor cleanup limit if both exist. [pg_ctl waiting](https://www.postgresql.org/docs/18/app-pg-ctl.html).

### NGINX: explicitly selectable fast and graceful stop

NGINX assigns fast shutdown to TERM/INT and graceful shutdown to QUIT; `nginx -s stop` and `nginx -s quit` expose that distinction. During graceful worker replacement, old workers stop listening and finish servicing existing clients. The optional `worker_shutdown_timeout` makes workers try to close remaining connections once the grace expires; no value is configured by default. This supplies a prior for explicit operational modes, not a durable-workflow recovery contract. [Signals](https://nginx.org/en/docs/control.html), [commands](https://nginx.org/en/docs/switches.html), [shutdown timeout](https://nginx.org/en/docs/ngx_core_module.html#worker_shutdown_timeout).

### Kubernetes: grace bounds termination, not business completion

Pod termination normally delivers TERM with a 30-second default grace period, stops routing ordinary traffic to terminating endpoints, and escalates to KILL after the grace expires. Applications are expected to stop regular work and finish open connections. A forced API deletion does not itself prove the old process has stopped. Kubernetes establishes a process-termination envelope; application recovery and external-effect safety remain outside that guarantee. [Pod termination flow](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#pod-termination-flow), [forced termination](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#forced-pod-termination).

## Provider cancellation and the cost question

OpenAI's current Responses documentation explicitly says that terminating the connection cancels a synchronous response. Background responses have a separate cancel operation and permit reconnecting to the stream. The ordinary synchronous case therefore must not be described using the background case's disconnect behavior. The same page does not specify a billing cutoff, cancellation latency, or refund guarantee, and does not prove the Codex subscription route's behavior. [Background mode, cancellation, streaming, and limits](https://developers.openai.com/api/docs/guides/background).

Anthropic's official TypeScript SDK documents cancelling a stream by breaking iteration or calling `stream.abort()`; the helper aborts in-flight network requests. This establishes the SDK action, not an exact provider-side billing or computational-stop boundary. [Anthropic SDK stream helpers](https://github.com/anthropics/anthropic-sdk-typescript/blob/main/helpers.md#streaming-responses).

**Cost inference, not a measured provider guarantee:** promptly interrupting unwanted generation can avoid some remaining work when cancellation is honored. If the workflow will later retry from the same immutable input, discarding the current attempt can instead increase total work. Draining preserves a potentially reusable result but spends the remaining generation cost and delays shutdown. None of the reviewed cancellation contracts establishes that either policy minimizes cost for every interruption point. OnePage's pinned subscription route still requires its own evidence.

## Implications for OnePage

These are deductions from the comparison, not settled product decisions.

1. **Keep execution intent independent of the server's lifetime.** OpenCode supplies the closest direct prior for interrupting at shutdown while retaining eligibility for restart. This does not require treating server stop as Run cancellation or adding a Run pause state.
2. **Name the drain boundary before choosing a policy.** Waiting for a provider response, settling an Operation, finishing a Turn, and completing a Workflow Run admit different amounts of additional work. Codex's whole-Turn drain must not be mistaken for “no new provider calls.” OnePage can prohibit new external dispatch as soon as shutdown starts regardless of whether it grants current Attempts a grace period.
3. **Separate persistence cleanup from waiting for useful work.** Even a prompt stop should preserve already-complete evidence and finish or roll back its current SQLite transaction. Claude SDK and PostgreSQL demonstrate that clean shutdown does not require letting business work run to normal completion.
4. **Keep the grace period and the process-exit guarantee distinct.** Temporal shows that cancellation after a grace interval is not necessarily a hard exit deadline. A Host must specify how non-cooperative tool work and executor cleanup are ultimately bounded. A remote model can also outlive local handles.
5. **Do not equate shutdown with the existing direct Model Interruption command.** Under current OnePage semantics, direct interruption durably abandons an Operation and may lead to a cancelled Turn. Infrastructure shutdown has different intent if unfinished Runs remain eligible after restart. The owning decision must state what is recorded when the server intentionally drops physical custody; the existing crash/uncertainty model may be sufficient without a new authoritative lifecycle entity.
6. **Keep cost policy with existing dispatch/retry bounds.** No reviewed prior justifies a new per-retry approval system for this decision. Budgets must survive restarts, and uncertain model replacement must not be described as free replay. Reuse accepted results; recover unresolved Attempts by effect type.
7. **Keep operation-specific safety.** Closing a model connection, interrupting Bash, and interrupting Patch during filesystem mutation have different consequences. A prompt server stop need not mean indiscriminate process killing or a claim that every external effect has ceased.

## Decision options the evidence leaves open

| OnePage policy | Benefit | Cost or risk |
| --- | --- | --- |
| Prompt interruption plus bounded persistence/cleanup | Stop promptly; no intentional wait for generation to finish | Discarded progress may require another paid request on restart; provider cancellation semantics matter |
| Bounded drain of currently dispatched Attempts, then interruption | Can preserve nearly finished work while limiting shutdown delay | Continues some generation during the grace period; needs one explicit grace policy |
| Drain through normal effect deadlines | Maximizes opportunity to retain current results | Server stop can take as long as the longest remaining deadline; not a universal industry default |

A small grace policy is operational machinery, not a new Run state. Either of the first two options fits the agreed simple client-server model. The choice should follow the desired meaning and latency of an explicit server stop, rather than an unsupported claim that it is always cheaper.

## Remaining evidence and handoff

- The exact Codex subscription route's disconnect/cancellation behavior, observable terminal evidence, and any billing guarantees are not established by generic Responses or SDK documentation. Route-specific evidence remains with [Establish provider reasoning and server-side compaction wire contracts](https://github.com/DivyanshGolyan/onepage/issues/73) and [Integrate Codex with durable Workflow Runs](https://github.com/DivyanshGolyan/onepage/issues/43).
- The default shutdown policy and meaning of cleanly interrupted custody remain a human decision in [Choose live Host ownership and cross-process command semantics](https://github.com/DivyanshGolyan/onepage/issues/100). This research does not select a new public flag, signal mapping, transport, or durable pause mechanism.
- Any numeric grace and existing provider/effect deadline relationship belongs with [Choose provider retry and external-effect budgets](https://github.com/DivyanshGolyan/onepage/issues/91) and [Set Host Runtime admission controls and budgets](https://github.com/DivyanshGolyan/onepage/issues/68).
- Required later tests include no new dispatch after stop begins, a result completing during cleanup, signal escalation, a lost shutdown acknowledgement, fresh-process reopen after each handoff, and no automatic Bash replay. A full turn must not accidentally advance during an intended current-Attempt drain.

## Evidence limits

Official documentation was read on the research date; implementation-specific claims use the pinned source revisions above. No provider billing experiments, live cancellation experiments, or shutdown fault tests were run. This is a comparative source review, not production certification. Differences among service shutdown, worker shutdown, SDK transport teardown, and durable execution cancellation are kept explicit; their guarantees are not interchangeable.
