# Workflow interface comparison brief

> **Historical design exploration, published 6 September 2026.** The [normative architecture](../../../ARCHITECTURE.md) and [product contract](../../../PRODUCT.md) own the current design. Earlier signatures, issue ownership, status statements, and unselected alternatives below retain their original context; they are not a second current specification.

**Subsequent cancellation amendment:** the comparison below predates the [accepted simplification](../workflow-cancellation-stop-mapping.md#accepted-simplification). Unfinished Run cancellation may repeat all Session stops after a crash; callers coordinate reuse. Only completed Run cancellation suppresses further propagation. Earlier no-retarget/idle-receipt requirements in this comparison and its candidates are superseded.

This is a second design-an-interface exploration, requested 5 September 2026. It compares public workflow shapes, not production implementations. It does not select a winner or close [Choose replay-stable Session continuation from agent results](https://github.com/DivyanshGolyan/onepage/issues/101).

## Callers and purpose

Coding agents author bounded JavaScript/TypeScript programs that compose reusable server-side Sessions. The workflow capability handles durable admission and recorded results; scripts use ordinary functions, arrays, loops, async/await, Promise.all, and Promise.allSettled. The server owns execution and SQLite. The direct shell CLI is another consumer with its own admission-acknowledgement contract.

## Accepted constraints

- The user explicitly agreed immediately before this exploration to separate Session creation and identity from messages. Creation can leave a valid empty Session, returns an ID before any message/model work, and has its own replay identity. The interrupted publication turn made no changes; older local and live issue text still calls this unresolved or forbids empty Sessions. That text is stale relative to the conversation and is not a constraint on these designs.
- Each message operation returns a normal Promise of its recorded final text or exact schema-validated result; recorded failure/cancellation rejects it. Await now or later without a separate wait key or model-answer metadata envelope.
- Explicit Run-local keys identify creation and message operations/results. Equal replay recovers original committed facts; changed binding conflicts. Operation kinds cannot silently reuse one another's identities. Simple global automatic ordinals are disproven for the supported async composition by the existing call-order probe.
- Sessions are shared by one trusted local owner. Another workflow can use the same Session ID; new messages use current state without caller-specific views, leases, ACLs, or historical revision preconditions. Several messages can join one internal Turn and share an outcome.
- Turns remain internal; request manifests and effect-specific safety remain exact. Session identity is not a Turn, result identity, or proof of exclusive ownership.
- Run cancellation fences further evaluation/submission, then stops current work in every Session the Run submitted to, including another Run's newer work. Merely creating/referencing a Session does not count as a message submission. Applied stops must not retarget later continuation on recovery. The storage mapping is still unresolved.
- Empty/dormant Sessions retain disk facts, not live workers, evaluators, histories, or ownership registries. Evaluators and Promise graphs disappear at barriers; handles, IDs, or descriptors are bounded temporary workflow values.
- Session baseline context commits with creation. First-message Turn, message, and initial Conversation admission remain atomic. Explicit later context-patch behavior remains separate design work.
- Direct CLI submissions remain keyless and do not retry mutations automatically. No new wire/API behavior is implied by changing the workflow-facing shape.

## Independent design assignments

1. Bound Session capabilities: optimize discoverability and the common draft/review/revise flow.
2. Plain Session IDs and stateless functions: optimize explicit data flow and sharing; eliminate attach/get handles.
3. Typed operation descriptions plus execution: optimize composition of operation data; distinguish constructing data from submitting work without imposing a generic native command union.

Each design must show types, actual usage, what it hides, tradeoffs, error behavior, recovery, and resource lifetimes. Do not judge by estimated implementation effort. Judge caller simplicity, depth, correctness, flexibility, and whether the shape permits bounded disk-first internals.

## Common review scenarios

Create without sending; lose creation acknowledgement; replay after first or second answer; use an ID from workflow arguments; create two Sessions and fan out; loop over input-derived keys; retain a Promise and await later; catch failure and continue the same Session; two Runs contribute to shared work; cancel one Run and later continue; reject changed binding and invalid Session ID.

No wrapper, function, or command description itself promises Session existence or admission. Every design must say when those validations occur. None should claim that storing a Promise keeps it alive across evaluator destruction, or that JavaScript invocation order proves physical dispatch/admission order. The current evaluator lacks the separate creation-result capability, regardless of public spelling.
