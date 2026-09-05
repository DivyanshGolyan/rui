# Alternative: stateless Session functions with causal references

> **Historical design exploration, published 6 September 2026.** The [normative architecture](../../../ARCHITECTURE.md) and [product contract](../../../PRODUCT.md) own the current design. Earlier signatures, issue ownership, status statements, and unselected alternatives below retain their original context; they are not a second current specification.

Status: design alternative, not an adopted contract. Public operations concern Sessions, messages, and answers. Turns remain internal.

## Interface

```ts
type SessionRef = { id: string; message: string };

sessionStart({ key, message, schema?, model?, ... }): Promise<SessionRef>
sessionMessage(previous: SessionRef, { key, message, schema?, ... }): Promise<SessionRef>
sessionWait(ref: SessionRef): Promise<Answer>
sessionRead(ref: SessionRef, { after?, last?, type? }): Promise<EntryPage>
```

A reference is a small ordinary data value, not a live object. `id` identifies the conversation; `message` identifies the admitted User entry whose work the caller is observing. Reference field names are illustrative. Message identity is not a public Turn ID, execution handle, or revision counter.

Start and message return after durable admission. Wait returns the exact Final Answer text or validated schema value, with no metadata envelope. Failure throws the recorded bounded error. Reading history returns a bounded page of public Conversation entries and content references; it never exposes private provider continuation material.

## Draft → review → revise

```js
const drafting = await sessionStart({
  key: "draft",
  message: "Draft a migration plan.",
});
const draft = await sessionWait(drafting);

const reviewing = await sessionStart({
  key: "review",
  message: `Review this migration plan:\n${draft}`,
  schema: {
    type: "object",
    properties: { changes: { type: "string" } },
    required: ["changes"],
    additionalProperties: false,
  },
});
const review = await sessionWait(reviewing);
// review is exactly { changes: string }, not { answer, session, ... }.

const revising = await sessionMessage(drafting, {
  key: "revise",
  message: `Revise your plan using this review:\n${review.changes}`,
});
const revised = await sessionWait(revising);
```

`drafting.id === revising.id`. Their message cursors differ. No evaluator, function closure, or Session object must survive an await.

## Replay

1. Admission of `draft` commits Session, initial message, internal execution membership, and the existing Run-scoped key binding together.
2. A crash before its reply reaches JavaScript causes replay to recover exactly the same reference. It cannot create another Session.
3. A blocked wait destroys the evaluator. Re-evaluation repeats start, retrieves the same reference, and waits on the message's recorded processing episode.
4. A completed wait reads that episode's immutable answer. Later Session activity cannot replace it.
5. `review` has a different key and Session. Replay uses the same draft bytes and therefore the same review binding.
6. `revise` binds the original drafting reference and review bytes. If already admitted, replay returns the same continuation even after the Session advances.

Mutation keys remain explicit because this alternative preserves the existing deterministic workflow mechanism. They are not direct CLI request keys. Wait needs no additional key: its reference already fixes the answer source.

## Frozen history and concurrency

For a workflow, `sessionRead(ref)` is a read of the conversation prefix frozen when that reference's processing settles. It waits if necessary. Pagination cursors stay within that prefix. A live “latest” read is not silently substituted. Direct clients can independently offer current-history reads.

On first admission, `sessionMessage(previous, ...)` continues from the previous message's recorded settled conversation/context state. If another writer advanced the Session, it conflicts. Exact revisions stay internal. Equal-key replay is checked before this freshness condition.

This deliberately makes workflow continuation stronger than the direct CLI's “send to this Session now.” Supporting workflow steering of active work would need an explicit contract; it is not assumed here. Independent Sessions can execute concurrently, but JavaScript-visible values cannot depend on which physically completes first.

## Tradeoffs and unresolved edges

This adds four functions instead of one `agent()`, but keeps admission, settlement, and history conceptually separate. The cost is carrying a Session reference with a message cursor rather than a bare Session ID. That causal cursor is necessary to distinguish the draft answer from the later revised answer without exposing Turns.

The simple example needs only the first three functions. History reads could be deferred until a workflow use case requires them. Whether full answers fit evaluator limits remains governed by existing output limits; history pages must additionally bound bytes, not just entry counts.

Failure with admitted but unconsumed User messages remains an open lifecycle decision. Wait must report failure, not falsely claim the message was handled. Cancellation also freezes an explicit outcome; a Session's continued existence is not evidence of success.
