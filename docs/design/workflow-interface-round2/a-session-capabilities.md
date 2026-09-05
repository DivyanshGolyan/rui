# Design A: ephemeral Session objects

> **Historical design exploration, published 6 September 2026.** The [normative architecture](../../../ARCHITECTURE.md) and [product contract](../../../PRODUCT.md) own the current design. Earlier signatures, issue ownership, status statements, and unselected alternatives below retain their original context; they are not a second current specification.

Status: interface comparison, 5 September 2026. Separate Session creation and messaging is accepted in the conversation; this particular naming and entry signature is a proposal. No implementation or integrated recovery proof is claimed.

## Shape

Expose two factory operations and one operation on a Session:

```ts
type SessionId = string;
type Key = string;

interface Sessions {
  create(options: { key: Key }): Promise<Session>;
  ref(id: SessionId): Session;
}

interface Session {
  readonly id: SessionId;
  send(message: string, options: { key: Key }): Promise<string>;
  send<T>(
    message: string,
    options: { key: Key; schema: Schema<T> },
  ): Promise<T>;
}

export default async function workflow(
  { sessions }: { sessions: Sessions },
  args: WorkflowArguments,
) {
  // Ordinary JavaScript orchestration.
}
```

`Schema<T>` stands for the project's supported strict output-schema representation, not a proposed new schema library or a claim that every TypeScript type is expressible. The baseline context for `create` comes from the resolved Run configuration. Any already-required explicit baseline configuration belongs in creation options; this comparison does not choose a new configuration system. Message-local options can retain their existing closed contract. Persistent context patching remains unresolved.

`create` durably creates an empty Session before returning its reference. It starts no model work. `ref` constructs a local reference to an existing Store-relative ID; it performs no read or existence validation. A nonexistent or wrong-Store target is rejected when submitted to the server. The name `ref` makes that distinction clearer than a `get` which appears to fetch data.

`send` submits when invoked and returns an ordinary Promise for the outcome of the work accepting that message. It fulfills with final text or the exact validated schema value, and rejects with the recorded typed failure or cancellation. Awaiting is not the trigger for submission. The server, rather than each handle, holds the conversation.

All durable operation keys share the existing Run-local namespace. Creation and messages need distinct keys. Reusing a key with another operation kind, Session, message, or other bound input is a binding conflict, not a new invocation.

## Complete draft, review, and revision

```js
export default async function workflow({ sessions }, args) {
  const [writer, reviewer] = await Promise.all([
    sessions.create({ key: "writer" }),
    sessions.create({ key: "reviewer" }),
  ]);

  const draft = await writer.send(`Draft a plan for: ${args.task}`, {
    key: "draft",
  });

  const review = await reviewer.send(`Review this plan:\n${draft}`, {
    key: "review",
  });

  const revision = await writer.send(`Revise using this review:\n${review}`, {
    key: "revision",
  });

  return { writerId: writer.id, reviewerId: reviewer.id, revision };
}
```

The final object is an explicit workflow result assembled by its author. Model answers themselves have no framework envelope. Returning the IDs makes future reuse possible, while IDs are already available inside the workflow immediately after creation.

## Existing Session and shared clients

```js
export default async function workflow({ sessions }, args) {
  const writer = sessions.ref(args.writerId);
  return await writer.send(args.instructions, { key: "continue" });
}
```

The supplied ID must come from stable Run arguments or recorded workflow results. Constructing another reference grants no additional authority and creates no durable attachment. All admitted clients already act for the local owner. New submissions use current Session state, including other clients' input. Two references to the same ID have no separate positions or private message queues.

Concurrent messages in one Session can join the same active work and receive its shared outcome. Separate calls do not imply separate answers. If callers demand incompatible output contracts while joining shared work, the admission contract needs an explicit compatible-or-reject rule; this object shape neither resolves nor conceals that obligation. It must not silently return an outcome in a different requested schema.

## Fan-out and dynamic loops

```js
export default async function workflow({ sessions }, args) {
  // args.files contains unique stable IDs supplied as Run arguments.
  const reviews = await Promise.all(args.files.map(async (file) => {
    const reviewer = await sessions.create({
      key: `reviewer:${file.id}`,
    });
    const review = await reviewer.send(`Review ${file.path}`, {
      key: `review:${file.id}`,
    });
    return { fileId: file.id, review };
  }));

  const editor = await sessions.create({ key: "editor" });
  const draft = await editor.send(JSON.stringify(reviews), { key: "draft" });

  // The author deliberately bounds the loop and names each semantic step.
  let answer = draft;
  for (let round = 0; round < args.revisionRounds; round++) {
    answer = await editor.send(`Improve this draft:\n${answer}`, {
      key: `revision:${round}`,
    });
  }
  return answer;
}
```

Explicit local loop indices are suitable when they identify stable sequential rounds. A runtime-wide ordinal assigned by invocation order is different and remains unsafe across replayed Promise continuations. Fan-out keys follow stable item identity. Duplicate input IDs produce a conflict or intentional reattachment rather than independent work; examples must not imply arbitrary arrays are automatically safe key sources.

This API provides concurrency expression, not unlimited execution capacity. Host admission, evaluator allocation, value size, and active-work limits still apply. Large arrays of promises and answers can exhaust an evaluator budget even though dormant Sessions have no resident workers.

## Deferred await and failures

```js
const drafting = writer.send("Draft the plan", { key: "draft" });
const reviewing = reviewer.send("List likely risks", { key: "risks" });

// Ordinary joins attach observation to both promises before suspension.
const [draft, risks] = await Promise.all([drafting, reviewing]);
```

The later `await` does not look up whichever answer is newest in the Session. Each Promise retains its original submission/result binding. Native JavaScript unhandled-rejection rules still matter if authors defer attaching error handlers while awaiting unrelated work. `Promise.all` or `Promise.allSettled` expresses the usual safe join.

```js
try {
  return await writer.send("Produce the final answer", { key: "final" });
} catch (error) {
  // Example code name is illustrative; use the frozen public error union.
  if (error.code !== "cancelled") throw error;
  return { writerId: writer.id, status: "stopped" };
}
```

A Session stop can reject this message while its Workflow Run remains active, allowing ordinary catch logic. Cancellation of this very Workflow Run prevents further evaluator execution; catch is not a facility to override Run cancellation. Reissuing the same failed message key on replay recovers its failure. A deliberate new attempt needs a new key and may incur new model cost.

## What the objects hide

The Session object carries only its ID and a binding to this evaluator's host capability. It does not contain conversation history, an active worker, a current Turn pointer, or a caller view. Internal Turns and shared-work membership remain server facts. A method invocation contributes the Run identity implicitly from the evaluator context, not from a caller-supplied Run argument.

Creation uses its Run-local key to recover a recorded ID. A message uses its key to recover its admitted message and outcome binding. A public Session ID alone cannot substitute for a message key because one Session can receive many messages from this Run and other Runs.

No JavaScript object is itself durable. At a blocked boundary the evaluator, references, closures, and Promise graph are discarded. Re-evaluation recreates these objects from stable inputs and recorded operations. Only the ID should cross workflow boundaries; authors should not serialize a handle or retain its methods in output.

Cancellation needs no public workflow-side method here. The external Run cancellation command fences further submissions, derives the distinct Sessions the Run submitted to, and applies ordinary current-work stops. Creation or reference construction alone does not add a Session to that set. An applied stop must not select newer work again on recovery. The exact multi-Session durable cancellation mapping is still unverified.

## Failure boundaries and retained resources

1. Creation commits Session, baseline, and creation binding atomically. If acknowledgement is lost, the same key returns the same ID. Before commit, there is no created Session to recover.
2. A crash between creation and first send leaves a valid empty Session. Explicit Run recovery reconstructs it. No first message or provider call is fabricated.
3. Message admission commits the message and Run/key result binding together. Lost acknowledgement recovers that admission, not a duplicate message against newer Session state.
4. A completed answer followed by evaluator death is recovered through the original key. Neither delayed awaiting nor another client's continuation changes that recorded answer.
5. Provider uncertainty still follows the existing effect-specific recovery rules. This interface promises no external exactly-once invocation or immunity from provider charges on retry.

Dormant Sessions occupy disk records. Active evaluator references require space proportional to the handles created during that evaluation, and materialized outputs count toward its existing limits. Recorded answers can use the existing immutable content representation rather than a second per-handle transcript. No persistent object registry, per-caller position, or resident Promise table is justified by this design. These are allocation boundaries to implement and measure, not benchmark results.

## Comparison and self-critique

This design fits how an author speaks about a conversation: obtain a Session, then send messages to it. Discoverability is strong because `writer.` exposes the operation relevant to that conversation. The interface is small while hiding substantial admission and replay behavior. The first and subsequent messages share one shape, and Session identity is available even if the first message fails.

The object metaphor is also its chief danger. A normal SDK object often represents mutable local state or a connection. Here it represents neither. Readers may assume two objects mean independent conversations, that retaining a handle prevents cancellation, or that methods are safe to serialize. Calling these objects security capabilities would be misleading because all clients share the same owner authority; they are only evaluator API capabilities.

`ref` is honest about the absence of a read, but less familiar than `get`, and errors for nonexistent IDs arrive later. Adding eager validation just to make `get` unsurprising would introduce another replayable observation without a demonstrated workflow need. Flat ID-based functions avoid this entire object expectation at the cost of repeating the ID.

The largest correctness obligations remain behind the appealing syntax: stable keyed creation, shared-work admission and schema compatibility, immutable replayed results, and one-time cancellation propagation. An object API does not make these disappear. If authors primarily pass IDs among helper functions, the wrapper contributes modest ergonomic value and the flat-function design may be clearer. Prefer this design only if the common workflow genuinely benefits from naming and repeatedly addressing a small set of conversation objects.
