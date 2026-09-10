# Workflow runtime boundaries: Temporal and Restate

Reviewed 2026-09-10. Research recommendation, not an accepted architecture change or implementation claim. Source revisions are pinned below; documentation was inspected live. Existing OnePage changes were preserved.

## Finding

These systems justify a narrow interface between computation and durable execution. They do **not** establish that OnePage should expose evaluator and coordinator as peer components. Temporal extracts reusable machinery for multiple language SDKs; Restate separates deployable applications from its durable server and shares protocol machinery across SDKs. Those are concrete consumers and deployment requirements.

For OnePage's present scope, the smaller public explanation is **Workflow Runtime → Session core**, with a private disposable evaluator inside Workflow Runtime. This is an inference from the comparison, conditional on there being no independently supported evaluator consumer. It preserves the [accepted compute boundary](../design/evaluator-coordinator-boundary.md): JavaScript determines branches and joins; native code saves keyed calls/results and submits through Session core. “Private” concerns who must understand the interface, not whether the evaluator has a dedicated process or tests.

## Temporal: reuse inside a worker

Temporal's first-party rationale explicitly identifies duplicated event/state-machine logic across language SDKs as the problem. Rust Core shares that logic while language SDKs supply idiomatic interfaces. The same rationale favors linking Core into the language SDK's process, avoiding an additional deployment and IPC requirement. This is a reusable library boundary with deliberate operational integration. [Design rationale](https://temporal.io/blog/why-rust-powers-core-sdk).

The public Core interface is concrete: the C bridge exports `temporal_core_worker_poll_workflow_activation` and `temporal_core_worker_complete_workflow_activation`, alongside activity polling, completion, shutdown and cache eviction operations. This is a supported SDK construction surface, broader than a pure workflow evaluator. [Pinned C bridge](https://github.com/temporalio/sdk-rust/blob/acac9e3f98c64eda54805f65779ddf2b313c8cb2/crates/sdk-core-c-bridge/src/worker.rs#L680).

Core polls the Temporal service, processes history through state machines and produces activation jobs. The language SDK runs workflow code and returns commands in an activation completion; it also executes activity/Nexus functions and chooses language-appropriate concurrency. An activation can start fresh code or resume a cached workflow. Core is the worker-side history adapter; the remote Temporal service supplies durable history. [Pinned ownership description](https://github.com/temporalio/sdk-rust/blob/acac9e3f98c64eda54805f65779ddf2b313c8cb2/ARCHITECTURE.md#L15).

In TypeScript, callers create and run one `Worker`; its implementation polls the native worker, activates workflow instances, and sends completions. End users need not assemble Core and evaluator as two peer services. [Pinned Worker implementation](https://github.com/temporalio/sdk-typescript/blob/72615f23ef735ab27ef0cc18cbf3de68f823fdc1/packages/worker/src/worker.ts#L512).

**Fit:** supplying recorded outcomes to code and collecting requested commands resembles OnePage. **Mismatch:** Temporal's Core/language boundary serves multiple languages, activity execution, cached workflows and rich history state machines. OnePage's evaluator consumes one fixed result view, exits after computation, and cannot execute Session effects. Copying Temporal's package split or state-machine machinery would need a separate justification.

## Restate: deployment boundary plus reusable protocol library

Restate applications embed an SDK and run independently as containers, functions or other deployments. The server owns durable execution and stored state/history; applications can remain stateless and scale separately. This is an actual server/application failure and deployment boundary. [Official application structure](https://docs.restate.dev/foundations/key-concepts).

The application surface includes `restate.serve({ services: [...] })`, a configurable HTTP handler, and adapters for Lambda and other JavaScript runtimes. The server invokes an SDK endpoint through `POST /invoke/{serviceName}/{handlerName}` with a versioned invocation content type. Its wire protocol supports both bidirectional HTTP/2 and request/response exchange. Replay supplies the recorded journal; later commands, notifications and acknowledgments drive progress, ending in completion, suspension or failure. [Serving API](https://docs.restate.dev/develop/ts/serving), [pinned protocol](https://github.com/restatedev/sdk-shared-core/blob/bcdf52777955b36bed611483abd227db03b9a09c/docs/service-invocation-protocol.md#L10).

A second boundary sits **inside the SDK**. Restate's Rust `sdk-shared-core` is reused by multiple language SDKs. Its “VM” is a synchronous protocol state machine, not a JavaScript interpreter. It handles framing, replay position, notification correlation and suspension; the language SDK owns transport, context APIs, application scheduling, `ctx.run` closures and serialization. [Shared consumers](https://github.com/restatedev/sdk-shared-core/blob/bcdf52777955b36bed611483abd227db03b9a09c/README.md), [integration responsibilities](https://github.com/restatedev/sdk-shared-core/blob/bcdf52777955b36bed611483abd227db03b9a09c/docs/sdk-integration.md#L12).

The pinned `VM` trait exposes `notify_input`, `take_output`, `do_await`, `take_notification`, `sys_call`, `sys_run` and `propose_run_completion`. TypeScript context calls reach a WASM binding around `CoreVM`; application JavaScript runs outside that VM. The integration guide still uses `do_progress` where pinned source uses `do_await`, so source is authoritative for these signatures. [VM trait](https://github.com/restatedev/sdk-shared-core/blob/bcdf52777955b36bed611483abd227db03b9a09c/src/lib.rs#L430), [TypeScript binding](https://github.com/restatedev/sdk-typescript/blob/6879b36b6774c580c8dad9812cc6088150909dae/sdk-shared-core-wasm-bindings/src/lib.rs#L539).

**Fit:** an internal computation interface can own replay mechanics without owning I/O. **Mismatch:** Restate's SDK can process arriving results and execute effectful closures during an invocation. Its protocol VM also owns suspension machinery. OnePage instead freezes inputs, forbids live replies and keeps JavaScript's Promise decisions inside QuickJS. Restate's request/response mode is closer, but still implements a remotely deployed effectful application protocol, not OnePage's compute-only evaluator.

## What the comparison supports

| Boundary | Concrete reason | Implication for OnePage |
| --- | --- | --- |
| Temporal Core/language SDK | Share difficult logic across actual language SDKs | Extract reusable packages when there are actual consumers |
| Restate server/application | Independent deployment, failures and scaling | Separate public components when deployment is part of the product contract |
| Restate SDK/shared VM | Share protocol implementation across languages | A private implementation seam can later become a library |
| OnePage Runtime/evaluator | Fixed computation, resource limits and disposable memory | Keep a narrow private interface and existing containment |

Calling the owner Workflow Runtime would not remove replay, validation, cancellation or recovery responsibilities. It would give one module authority over the complete workflow lifecycle while keeping evaluation mechanically isolated. Promote the evaluator to a public peer only if a concrete caller must invoke it independently and can meaningfully own its inputs, limits and compatibility. A source file, child executable, fuzz target or useful unit-test seam alone does not establish that product requirement.

No performance comparison or production verification was performed. This note assesses documented and source-visible boundaries; it does not select wakeup mechanics, Session-reference encoding or new deployment topology.
