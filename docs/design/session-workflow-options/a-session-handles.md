# Option: ephemeral Session handles

> **Historical design exploration, published 6 September 2026.** The [normative architecture](../../../ARCHITECTURE.md) and [product contract](../../../PRODUCT.md) own the current design. Earlier signatures, issue ownership, status statements, and unselected alternatives below retain their original context; they are not a second current specification.

Status: proposal, not an adopted contract. This replaces the public Turn-shaped `agent()` surface; it preserves internal Turn execution and immutable replay results.

## Small surface

```js
const writer = await sessions.start({ message: "Draft the implementation plan." });
const draft = await writer.wait();

const reviewer = await sessions.start({
  message: "Review this plan.",
  input: draft,
  schema: reviewSchema,
});
const review = await reviewer.wait(); // exactly reviewSchema's value

await writer.send({ message: "Revise using this review.", input: review });
const revised = await writer.wait();
return revised;
```

`start` admits the initial message and creates the Session atomically. It resolves on admission, returning a small handle. `send` admits another message, also resolving on admission. `wait` resolves to the answer of the work associated with this handle's last admitted message, or throws its frozen failure. No result envelope, Turn ID, revision argument, or caller-managed continuation token appears.

A handle exposes its Session ID for outside observation but is not a service, worker, retained conversation, or independently durable JS object. It holds only identifiers and an internal reference to its last admitted work within one evaluator generation.

This is slightly narrower than “wait until this Session happens to be idle”: each invocation fixes its observation target, so later unrelated activity cannot replace the answer. The target is an implementation detail. Repeated waits without another send return the same result.

Independent Sessions run concurrently: create several, then use `Promise.all` on their waits. Waiting on permissions suspends normal workflow progress; inspection exposes the actionable request independently.

## Handle reconstruction and replay

At a durable barrier the evaluator and all handles disappear. Reevaluation executes the same source; `start` reconstructs the original handle from its recorded admission. A completed `wait` resolves to its original immutable answer, never the Session's newest answer. `send` recognizes its original admission rather than adding another message.

Example: crash after the review finishes but before the revision begins. Reevaluation reconstructs the writer and reviewer, reuses both answers, then admits the revision once. Crash after revision admission but before its answer: reevaluation recovers that admission and waits for the same work. No successful model call reruns merely to rebuild a handle.

Errors must preserve enough admission metadata internally to reconstruct the Session after failure. The handle remains reusable once internal occupancy is released; whether unresolved accepted input can survive failure remains the separate pending-message decision.

## Identity is not free

The ergonomic example omits keys, but doing so changes the present `(Run, key, specification digest)` replay contract. A possible implementation identifies durable API invocations by deterministic call order within the pinned workflow definition and validates each canonical binding. The existing prohibition on observing physical completion order helps, but it does not prove a complete invocation-order scheme.

Before adopting automatic identity, verify fan-out, nested loops, errors, repeated waits, and branches against immutable visibility snapshots. Do not derive identities from source locations alone. A safer transitional variant retains workflow-only operation keys:

```js
const writer = await sessions.start({ key: "draft", message: "Draft a plan." });
await writer.send({ key: "revision", message: "Revise.", input: review });
```

These keys are not direct-CLI options. Whether to remove them is a distinct replay machinery decision, not a prerequisite for hiding Turns.

## Concurrency and outside writers

The smallest handle contract permits one in-flight mutating method on a handle. Reject concurrent `send` calls rather than implicitly queueing them. Independent handles addressing the same Session still need storage admission serialization and an explicit sharing policy; JS object locking is insufficient.

Two viable policies need selection:

- **Current Session:** first admission uses the conversation as it then exists, just like the direct CLI; its actual binding and result become immutable for replay. External messages can affect the workflow answer.
- **Exact continuation:** the handle privately carries the prior observed boundary; a later send conflicts if external activity has advanced it. No revision fields leak into caller code.

Prefer exact continuation for a workflow-owned handle, while allowing explicit steering of active work only under a separately defined policy. This preference must not be silently treated as accepted.

A bounded `read({after, last, type})` can be added later. Workflow reads must freeze their selected entry boundary and returned content for replay; exposing an ordinary live-history query would reintroduce nondeterministic branching. The draft/review/revise example needs only `start`, `send`, and `wait`.
