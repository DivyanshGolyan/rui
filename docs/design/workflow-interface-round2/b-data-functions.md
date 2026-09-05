# Accepted shape B: Session IDs and ordinary functions

> **Historical design exploration, published 6 September 2026.** The [normative architecture](../../../ARCHITECTURE.md) and [product contract](../../../PRODUCT.md) own the current design. Earlier signatures, issue ownership, status statements, and unselected alternatives below retain their original context; they are not a second current specification.

**Selection:** accepted after comparison and local-use-case review. Settings/schema typing details below remain illustrative where explicitly marked; the runtime is not implemented.

**Later amendment:** configuration is a third, independent operation that changes persistent Session settings (`configureSession` is the illustrative name). The two-function comparison below is historical evidence for the ID-based shape, not a prohibition on the accepted configuration capability. Active-work applicability and output-schema scope remain open.

Status: selected public shape, 5 September 2026; not implemented. It preserves the user's accepted separation of Session creation from messages, including empty Sessions and early identity. The main product, architecture, and decision records now reflect the selected shape.

## Interface

Give the evaluator two functions. A Session reference is its ordinary serializable ID; there is no handle to acquire, construct, attach, or keep alive.

```ts
type SessionId = string; // Store-relative ID, not a cross-server address.
type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
type JsonSchema = Readonly<Record<string, Json>>;

// Existing closed baseline-context contract, not an arbitrary options bag.
// The fields and schema vocabulary are supplied by the owning contracts.
type SessionBaseline = ExistingSessionBaseline;

interface CreateSessionOptions {
  key: string;
  context?: SessionBaseline; // Omission selects the Run's bound defaults.
}

interface MessageOptions {
  key: string;
  input?: Json;
}

interface WorkflowApi {
  createSession(options: CreateSessionOptions): Promise<SessionId>;

  sendMessage(
    session: SessionId,
    message: string,
    options: MessageOptions,
  ): Promise<string>;

  sendMessage<T extends Json>(
    session: SessionId,
    message: string,
    options: MessageOptions & { schema: JsonSchema },
  ): Promise<T>;
}
```

`ExistingSessionBaseline` is an explicit reference to the current baseline contract, not a proposed implementation symbol or selected new context-patch API. Schema typing is illustrative: `T` documents the schema's validated shape; TypeScript cannot prove that a separately supplied JSON Schema describes `T`. A production declaration should use the selected schema-to-type mechanism without treating a generic annotation as runtime validation.

Creation commits the Session, its complete baseline, and the Run-local creation binding before returning its ID. It starts no model work. `sendMessage` returns the final text or exact schema value from the work accepting its message; there is no metadata envelope. Its Promise rejects with the frozen failure or cancellation associated with that admission.

All operation keys share one Run-local namespace and bind operation kind and complete inputs. Reuse with changed inputs, another Session, or another operation kind conflicts. The ID and keys remain different concepts: an ID selects shared server state; a key identifies one workflow operation and its saved result.

This candidate deliberately does not supply standalone reads, waits, context mutation, Session stop, or workflow cancellation methods. They are not needed for the common draft/review flow; existing external Run cancellation still propagates server Session stops. Their absence here does not remove the direct consumer's capabilities or settle context-patch semantics.

## Create, draft, review, revise

```js
export default async function workflow({ createSession, sendMessage }, args) {
  const [writer, reviewer] = await Promise.all([
    createSession({ key: "writer" }),
    createSession({ key: "reviewer" }),
  ]);

  const draft = await sendMessage(writer, "Draft the migration plan", {
    key: "draft",
    input: args.requirements,
  });

  const review = await sendMessage(reviewer, "Review this migration plan", {
    key: "review",
    input: draft,
  });

  const revision = await sendMessage(writer, "Revise the plan using this review", {
    key: "revise",
    input: review,
  });

  return { writer, reviewer, revision };
}
```

The first message has exactly the same call shape as subsequent messages. Session IDs are available before the model answer and remain available after a failed message. Returning them in the workflow's own output is ordinary application data, not mandatory response wrapping.

## Existing Session and ordinary composition

```js
export default async function workflow({ sendMessage }, args) {
  return await sendMessage(args.writerSessionId, "Review the latest changes", {
    key: "review",
    input: args.changedFiles,
  });
}
```

The server validates the ID when the command arrives. No preliminary `get()` or `open()` asserts existence, freshness, or exclusive access. An ID comes from bound workflow arguments or a recorded operation result, rather than live environment reads during replay. Another workflow may use the same ID and the same key spelling: keys are scoped to different Runs.

Small functions can compose IDs without depending on Session-object identity or serializing executable members:

```js
async function reviewFile(sendMessage, session, file) {
  return await sendMessage(session, "Review this file", {
    key: `review:${file.id}`,
    input: file.content,
  });
}
```

Key construction is caller responsibility. `file.id` must be stable and unique in this invocation's logical collection. If the helper is used twice, include a stable phase or call-site prefix. Stable array indices are possible for immutable bound arrays; completion-order indices, global invocation counters, timestamps, and randomness are not replay identities.

## Parallel work and later awaiting

```js
const pending = sendMessage(writer, "Draft the summary", { key: "summary" });

const reviews = await Promise.all(args.files.map(async (file) => {
  const reviewer = await createSession({ key: `reviewer:${file.id}` });
  return await reviewFile(sendMessage, reviewer, file);
}));

const summary = await pending;
```

Calling `sendMessage` expresses a submission; `await` expresses a dependency. Neither call return nor a stored Promise is a durable admission receipt. The Host owns admission and bounded scheduling. Delaying the await cannot change the message's bound result to a later Session answer. Reawaiting the same Promise has the same result.

Independent Sessions can progress under the configured limits. `Promise.all` does not reserve one worker per item or grant unlimited concurrency. Arrays, values, and Promises in the current evaluation still count toward evaluator limits; callers must bound fan-out and returned data. The evaluator exits at its blocked boundary and replay reconstructs temporary values. No Promise graph survives on behalf of waiting work. `Promise.race` and `Promise.any` remain outside the deterministic workflow contract.

## Shared Sessions and aliases

```js
const alias = writer;
const first = sendMessage(writer, "Draft the plan", { key: "draft" });
const second = sendMessage(alias, "Also address rollback", { key: "rollback" });
const [a, b] = await Promise.all([first, second]);
```

These are two messages to one Session, not two agent instances. If both admissions join the same active work, both Promises receive that work's outcome. They need not receive separate answers. If settlement precedes the second admission, it may instead start later work. Another workflow or direct client can contribute under the same rule; a fresh submission uses current committed state without caller-position checks.

The same constraint applies to typed output: aliases cannot impose incompatible schemas on one active work outcome. Schema applicability to joining messages needs an explicit admission rule in the owning contract. Neither a function signature nor a handle solves that unresolved policy. Do not silently promise an independent typed model response for each send.

If deterministic dependent work is intended, await the first answer before submitting the dependent message. This establishes the workflow's dependency but does not prevent trusted external clients from contributing to the shared Session.

## Failure and recovery

```js
const writer = await createSession({ key: "writer" });
const [attempt] = await Promise.allSettled([
  sendMessage(writer, "Draft the plan", { key: "draft" }),
]);

if (attempt.status === "rejected") {
  // A separate, explicit submission; recovery alone does not request a retry.
  return await sendMessage(writer, "Produce a smaller draft", {
    key: "smaller-draft",
  });
}
return attempt.value;
```

The failure branch receives the recorded typed failure. Its exact error discriminants remain the owning failure contract's concern. A Run that itself has been cancelled cannot use a catch branch to bypass its admission fence; this example concerns a failed message in a Run still allowed to advance. Empty or previously used Sessions persist without implicit retry or model work.

Recovery scenarios:

1. **Creation committed, response lost.** Replay of `writer` recovers the same ID. It does not create another empty Session.
2. **Creation completed, crash before draft admission.** The ID is recovered; the new draft uses the Session's state when admitted, including any intervening client's contribution.
3. **Draft admitted, answer not yet settled.** Replay recovers the admission and its pending outcome. It does not send another message merely to reconstruct the JavaScript variable. Effect-specific external recovery remains separate and can incur expected resume cost.
4. **Draft and review completed, crash before revision.** Draft and review replay to their recorded answers. Revision is a new submission against current Session state. If revision had committed before the crash, its key instead recovers that admission and result.
5. **Same keys reached in another physical order.** Keys and bindings recover the original operations. No global call ordinal is used; changing a binding conflicts instead of retrieving another call's result.
6. **Cancellation stops one Session, crash before the next.** Run cancellation fences new submissions and derives used Sessions from durable admissions. Recovery must distinguish the applied stop from remaining propagation. The applied stop cannot reselect and cancel later work. Exact relational mapping remains unresolved; these functions do not claim to prove it.

## What the interface hides

The caller sees two operation kinds and ordinary data. The Host retains durable Session baseline/identity, creation bindings, message bindings to the accepted work, and references to frozen outcomes. Shared admissions can point to one work outcome rather than storing independent answer copies. Internal Turns, request manifests, effect reconciliation, capacity, and replay visibility do not become script parameters.

The ID is a tiny temporary value; it does not bring a loaded Conversation, open socket, cursor, exclusive owner, or resident Session worker. The disk cost of Sessions and operations remains. Function syntax does not eliminate the need to store replay bindings or cancellation progress. Conversely, small Session-object wrappers could have the same asymptotic memory behavior; this candidate makes no measured memory win over them.

## Tradeoffs and critique

The strongest advantage is that workflow variables contain exactly what must cross workflow boundaries: Session IDs and answer values. A trusted client can immediately use an ID with the same command as its creator. There is no `get()` whose name suggests a read but actually creates an inert wrapper, and no question about whether two wrappers carry independent state. The two-function boundary hides substantial execution and recovery semantics without creating a public command interpreter.

The cost is repeated Session arguments and weaker local intent. Passing `reviewer` where `writer` was intended is syntactically valid. A Session object improves method discoverability but still permits the wrong object, so neither shape prevents this semantic error. Distinct variable names and stable input contracts matter more than receiver syntax.

The plain string alias also cannot distinguish Session IDs from other strings in TypeScript. An optional branded declaration can reject accidental Run-ID substitution at compile time, but JSON arguments need runtime decoding and a cast proves nothing. Avoid adding a branded-ID factory solely to disguise that reality; server validation and Store binding remain necessary either way. Runtime validation can reject invalid IDs, not a valid but unintended Session.

This shape is general enough for helper functions, fan-out, multiple workflows, and reuse without introducing a generalized command bus or builder. Its weakness is scale of discoverability if many unrelated Session capabilities are added later. That is not a reason to add reads, observation keys, or mutation APIs now. Grouping these same functions in a namespace is possible later without introducing per-Session objects, but should follow a demonstrated need.

For resource efficiency, the decisive boundaries are bounded evaluator values, disk-backed recorded results, and absence of resident workers. Both this candidate and lightweight handles can preserve those boundaries. Prefer this candidate if the product wants IDs to be visibly ordinary workflow data and considers a wrapper plus `get()` more conceptual surface than repeating the ID at each send.

## Evidence boundaries

This is design analysis, not a new runtime test or schema selection. It follows the accepted decisions summarized in [the workflow proposal](../session-workflow-interface.md) and the newly accepted separate-creation choice explored in [the creation comparison](../session-creation-options.md). Existing [call-order evidence](../../../research/workflow-call-order/README.md) motivates explicit keys; it does not prove this complete interface. Context-patch semantics, schema admission for shared work, and crash-safe cancellation propagation remain questions for their owners.
