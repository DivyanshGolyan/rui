# Should evaluator and coordinator be separate public modules?

Researched 2026-09-10. Recommendation for discussion; no accepted contract or production implementation changed.

## Recommendation

Expose one **Workflow Runtime**, with a private evaluator that computes from fixed inputs. Keep the evaluator's narrow input/output interface and existing containment. The runtime owns the complete Run lifecycle and consumes the Session core API.

This recommendation follows OnePage's present requirements, not a claim that integrated runtimes are universally better. The comparison found concrete reasons for reusable public boundaries in other systems: multiple language SDKs or independently deployed applications. We have not identified an independently supported caller that needs OnePage's evaluator alone.

“One module” means one public owner, not one source file or unrestricted access to shared mutable state. It can contain separate files, tests and a private child executable. The [accepted computation boundary](../design/evaluator-coordinator-boundary.md) remains useful inside it.

## Prior art

### Temporal: shared machinery for real language SDKs

Temporal's first-party rationale identifies repeated event/state-machine logic across language SDKs. Core shares that machinery, while language SDKs execute user code and provide idiomatic APIs. The same rationale favors linking Core into the SDK process so the user deploys one worker. Thus library separation and operational integration are compatible. [Design rationale](https://temporal.io/blog/why-rust-powers-core-sdk).

Its activation interface supplies jobs to the language SDK, which executes workflow code and returns commands. This resembles OnePage's computation interface, but Temporal also supports cached workflow instances and substantial history-processing machinery. The comparison supports keeping a narrow internal interface; its multiple SDK consumers explain why Temporal additionally exposes a reusable Core library. [Pinned architecture](https://github.com/temporalio/sdk-rust/blob/acac9e3f98c64eda54805f65779ddf2b313c8cb2/ARCHITECTURE.md#L15).

### Obelisk: one runtime with an explicit worker interface

Obelisk ships a single runtime binary that executes workflows and activities and persists their execution logs. Internally, its repository separates the executor, execution workers and storage implementations. This is evidence that one product/runtime boundary can contain meaningful module boundaries. It is a pre-release project, so this is source-visible design evidence, not an endorsement of maturity. [Runtime description](https://github.com/obeli-sk/obelisk), [pinned repository structure](https://github.com/obeli-sk/obelisk/blob/8321e26161cbcd8ac4ea7c98d2ddbb5c24ebc3e1/DEVELOPMENT.md#L3).

The executor calls `Worker.run(WorkerContext) -> WorkerResult`. Context contains parameters, event history and responses. However, a result can report that the worker updated the database, and workflow workers receive database access. This is a useful example of an internal execution interface, **not** an example of OnePage's stricter compute-only evaluator. Its Rust crates also expose interfaces; “one runtime” does not mean no reusable code. [Worker interface](https://github.com/obeli-sk/obelisk/blob/8321e26161cbcd8ac4ea7c98d2ddbb5c24ebc3e1/crates/executor/src/worker.rs#L20), [database supplied to worker](https://github.com/obeli-sk/obelisk/blob/8321e26161cbcd8ac4ea7c98d2ddbb5c24ebc3e1/crates/wasm-workers/src/workflow/workflow_worker.rs#L440).

### DBOS: public workflow library, internal executor

DBOS embeds orchestration in the application library, using Postgres for checkpoints rather than requiring a separate orchestration server. Its optional Conductor coordinates distributed recovery and operations. [Official architecture](https://docs.dbos.dev/architecture).

The TypeScript package entry exports `DBOS`; `DBOS.launch()` constructs the executor internally. The executor invokes the workflow function and records its outcome. Users do not assemble a separate evaluator and coordinator. However, workflow execution awaits ordinary live operations; this does not demonstrate disposable fixed-input evaluation or OnePage's memory guarantees. [Public exports](https://github.com/dbos-inc/dbos-transact-ts/blob/be82b1f4ace6210ab02473e92c0add1464495b84/src/index.ts), [launch](https://github.com/dbos-inc/dbos-transact-ts/blob/be82b1f4ace6210ab02473e92c0add1464495b84/src/dbos.ts#L470), [execution](https://github.com/dbos-inc/dbos-transact-ts/blob/be82b1f4ace6210ab02473e92c0add1464495b84/src/dbos-executor.ts#L867).

### Restate: independent deployment and shared protocol implementation

Restate separates its durable server from independently deployed application endpoints. Inside its SDKs, a shared Rust core implements protocol/replay state across languages. These are two distinct reasons for separation. Its protocol VM is not a JavaScript evaluator; the application can receive live progress and execute effects during an invocation. [Application architecture](https://docs.restate.dev/foundations/key-concepts), [shared-core consumers](https://github.com/restatedev/sdk-shared-core/blob/bcdf52777955b36bed611483abd227db03b9a09c/README.md), [detailed comparison and pinned interfaces](workflow-split-runtime-prior-art.md).

## What changes for OnePage

The proposed public shape is:

```text
Caller -> Workflow Runtime -> Session core
             |
             +-- private evaluate(source, arguments, fixed results)
                   -> encountered calls + waiting/value/failure
```

The runtime prepares fixed input, runs the evaluator, validates its output, saves/submits requested work under the accepted admission rules, and publishes dependencies/outcome. JavaScript still decides branches and joins. Evaluation receives no live Session replies and performs no Session effects. Waiting Runs retain no evaluator heap. Native on-demand reads from prepared immutable input remain permitted.

For a workflow requesting two messages and awaiting both, evaluation describes those calls and returns waiting. The runtime handles submission and later supplies available original results to a fresh evaluation. JavaScript determines whether the join can complete. This sequence is identical under either public-module choice; no second graph interpreter is introduced by putting both responsibilities inside one owner.

| Question | Separate public evaluator + coordinator | One public Workflow Runtime |
| --- | --- | --- |
| Who exposes the complete Run lifecycle? | Coordinator; evaluator also needs a documented standalone purpose | Runtime |
| Fixed-input computation and isolated tests? | Yes | Yes, through private evaluator interface |
| Disposable process and limits? | Possible | Equally possible; retain accepted containment |
| Independently supported evaluator consumers? | Natural when required | Would justify later extraction |
| Immediate implementation savings? | Depends on existing coupling | Mostly simpler ownership/API; essential mechanics remain |

The module choice itself provides no CPU or memory improvement. Those come from bounded evaluation, fixed inputs and reclaiming temporary resources. Likewise, a private evaluator still needs protocol validation, crash handling and limits if it runs in a child process. Removing that process would be a separate containment decision.

Keep the evaluator public only if a concrete consumer needs to run it independently and own its inputs, limits and compatibility. A test harness alone does not require a supported public API. Multiple future languages or deployment modes are possible reasons to revisit this, not current commitments.

## Evidence limits

Inspected official documentation and pinned source interfaces; did not build or benchmark these projects. Source snapshots were downloaded under `/tmp/onepage-workflow-module-priors/`. The Temporal/Restate companion note records its own pinned sources. Existing OnePage implementation is not evidence that this proposed ownership arrangement is implemented. Exact Session-reference encoding, creation-failure behavior and any wakeup-policy changes remain separate decisions.
