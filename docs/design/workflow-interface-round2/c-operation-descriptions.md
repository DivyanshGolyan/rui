# Candidate C: operation descriptions and one executor

> **Historical design exploration, published 6 September 2026.** The [normative architecture](../../../ARCHITECTURE.md) and [product contract](../../../PRODUCT.md) own the current design. Earlier signatures, issue ownership, status statements, and unselected alternatives below retain their original context; they are not a second current specification.

Status: interface alternative, 5 September 2026. This is an exploration, not an accepted API or implemented guarantee. It preserves the user's newly accepted separation of Session creation from messaging, including empty Sessions. It uses the accepted behavior in the [Session workflow proposal](../session-workflow-interface.md); that document and the [creation comparison](../session-creation-options.md) still contain historical wording about creation being undecided.

## Interface

Workflow code constructs ordinary immutable data describing an operation. Only `perform` expresses execution and returns a normal Promise. Session identity is a plain Store-relative ID; there is no Session object or attachment operation.

```ts
// Existing bounded canonical data, baseline-context, and schema concepts.
// Their complete field definitions belong to their owning contracts.
type CreateSession = Readonly<{
  kind: "create-session";
  key: string;
  baseline: SessionBaseline;
}>;

type SendMessage<T = string> = Readonly<{
  kind: "send-message";
  key: string;
  session: SessionId;
  message: string;
  input?: CanonicalData;
  schema?: Schema<T>;
}>;

declare function perform(operation: CreateSession): Promise<SessionId>;
declare function perform(operation: SendMessage<string> & {
  schema?: undefined;
}): Promise<string>;
declare function perform<T>(operation: SendMessage<T> & {
  schema: Schema<T>;
}): Promise<T>;
```

These are overloads of one function, not several executor methods. `Schema<T>` means a schema whose locally validated value is `T`; a caller's unsupported TypeScript assertion cannot establish output validity. The signatures illustrate the shape and do not choose a schema library or extend model-setting applicability to active work.

Descriptors are inert, acyclic canonical data, with no getters, callbacks, custom prototypes, execution methods, or promises inside them. TypeScript `Readonly` documents caller intent; it does not provide deep runtime immutability. At `perform`, bounded validation captures the canonical operation value before subsequent caller mutation could change its meaning. A public deep-freezing helper is not required. The executor must not retain caller-owned mutable input as future admission authority.

This is exclusively a JavaScript-facing representation. The adapter can dispatch these two kinds to explicit typed native operations. It does not require a generic command union, interpreter, plugin registry, or persisted command-bus layer in the native Host.

## Draft, review, revise

```js
const [writer, reviewer] = await Promise.all([
  perform({
    kind: "create-session", key: "writer", baseline: writerBaseline,
  }),
  perform({
    kind: "create-session", key: "reviewer", baseline: reviewerBaseline,
  }),
]);

// Both IDs now exist. Neither creation started a model request.
const draftRequest = {
  kind: "send-message",
  key: "draft",
  session: writer,
  message: "Draft a migration plan.",
};

// Constructing draftRequest did nothing. This call expresses submission.
const draft = await perform(draftRequest);
const review = await perform({
  kind: "send-message",
  key: "review",
  session: reviewer,
  message: "Review this migration plan.",
  input: draft,
});

return await perform({
  kind: "send-message",
  key: "revise",
  session: writer,
  message: "Revise the plan using this review.",
  input: review,
});
```

`await perform(create)` returns after durable creation, exposing the ID independently of the first answer. `await perform(send)` returns the completed answer, exactly as selected for workflow messages. The operation kind makes those different completion points explicit. Creating a Session and stopping before sending leaves an empty durable Session, with no active worker or invented first message.

## Existing Sessions, fan-out, and a dynamic loop

Another workflow receives a Session ID in its stable arguments and uses it directly:

```js
const review = await perform({
  kind: "send-message",
  key: "review",
  session: args.writerSessionId,
  message: "Review the latest implementation against our plan.",
});
```

There is no implicit open, Session creation, metadata read, access lease, or historical revision check. The server validates the ID when used. The same spelling of `key` in another Run denotes a different operation. Fresh submissions use current Session state; a replay uses its original admission and recorded result. The ID does not need to be included in the model's answer.

Operation data can be assembled before execution. For bounded, stable input items, this example creates independent Sessions, fans out checks, and performs a result-dependent revision loop:

```js
const workers = await Promise.all(args.checks.map(check => perform({
  kind: "create-session",
  key: `check-session:${check.id}`,
  baseline: checkBaseline,
})));

const requests = args.checks.map((check, index) => ({
  kind: "send-message",
  key: `check:${check.id}`,
  session: workers[index],
  message: check.question,
  input: args.plan,
}));

const reviews = await Promise.all(requests.map(request => perform(request)));

let candidate = args.plan;
for (let round = 0; round < args.maxRevisionRounds; round++) {
  const result = await perform({
    kind: "send-message",
    key: `revision:${round}`,
    session: args.writerSessionId,
    message: "Revise the plan. Report whether further revision is needed.",
    input: { candidate, reviews },
    schema: revisionSchema,
  });
  candidate = result.plan;
  if (!result.needsRevision) break;
}
return candidate;
```

Here `revisionSchema` validates exactly `{ plan: string, needsRevision: boolean }`; there is no Session/result envelope. `args.checks` has bounded size and unique stable `id` values. The explicit loop round is deterministic workflow meaning, not an automatically assigned global call ordinal. Recorded results determine the same branch decisions on replay. Arrays and a dynamic loop are ordinary JavaScript, not an added DAG description language.

Separate Sessions permit independent work. Several descriptors targeting the same active Session can contribute to the same work and receive its same outcome. Constructing two descriptions does not reserve independent executions, and `Promise.all` does not confer conversational isolation.

## What the executor hides

`perform` hides Run-key lookup, bounded canonical validation, durable admission, scheduling, and recovery of the original result. It does not hide a retained evaluator or a general execution-plan subsystem.

- Creation atomically binds its Run-local key, kind, and complete baseline to the created Session ID. Lost acknowledgement recovers that ID instead of allocating another Session.
- A message key binds its complete canonical submission and original admitted work. Reuse with another Session, message, schema, input, or operation kind conflicts. Replay of equal bindings retrieves the original answer or frozen failure. It cannot look up the Session's current answer as a substitute.
- Distinct keyed submissions may refer to the same internal work. The answer remains exact text or exact schema value where the accepted output contract permits that submission. Descriptors do not solve output-contract incompatibilities between concurrent submissions.
- An immutable evaluation visibility snapshot and the whole blocked set preserve the existing deterministic Promise composition contract. All expressed operations must be accounted for even if their Promises are not immediately awaited. Constructed but unperformed descriptions are not blocked work.
- At a durable barrier the evaluator, descriptors, arrays, Promise graph, and local answers disappear. Replay reconstructs the temporary values from source and durable facts. No heap or Session driver survives the barrier.

Normal Promises also allow later awaiting:

```js
const pending = perform(draftRequest);
// Other deterministic computation, or independent keyed operations.
const draft = await pending;
```

Submission happens at `perform`, not at `await`. If its recorded work fails while another dependency is unresolved, later awaiting must observe that original frozen rejection. The runtime must not turn delayed observation into a fresh submission, newer Session outcome, or swallowed failure. Ordinary rejection handling remains necessary; this design does not promise that attaching a handler arbitrarily late suppresses all unhandled-rejection behavior. `Promise.all` or `Promise.allSettled` attaches the relevant joins immediately. A final output cannot erase already expressed unresolved work. The evaluator's exact rejection-accounting behavior needs verification; the descriptor shape itself is not that evidence.

Run cancellation fences further operations and propagates one-time stops to the Sessions to which the Run has actually submitted messages. Descriptions merely constructed, or Sessions only created, do not join that set. Stopping may affect newer work submitted by another Run. Once a stop was applied, recovery must recover that stop's original application rather than stop subsequent continuation again. This is derived from durable admission and cancellation facts, not from scanning a surviving descriptor list.

## Resource behavior

One descriptor adds a discriminator, key, Session ID or baseline, and references to prompt/input/schema values in the current evaluator. This is additional temporary object storage compared with passing arguments directly. There is no credible numeric RSS saving to claim.

Keeping an entire request array retains its objects and referenced payloads. The mapped `Promise.all` example is appropriate only within evaluator and pending-work bounds; a descriptor language does not make arbitrarily large fan-out cheap. Authors can construct and perform each operation inline when staging offers no benefit. Canonical capture and the bridge must obey the existing per-value and aggregate limits without creating a second authoritative transcript or resident history copy.

An unperformed descriptor costs temporary evaluator bytes but creates no durable work, provider spend, cancellation association, or resumable pending intention. An expressed operation becomes work through the existing Host admission path; neither `perform` returning a Promise nor allocating a description proves a provider request has launched.

## Assessment

This candidate exposes only one execution method, but method count understates its conceptual surface. Authors learn two operation variants, a data-versus-action distinction, a dispatch function, and separate completion semantics by variant. The fluent Session alternative communicates the receiver and verb more directly.

Its distinct benefit is ordinary data composition. A workflow can select, map, or examine a bounded set of requests before executing them, and helpers can return request data without accidentally starting work. The point where work is expressed is visually uniform: `perform(...)`. This is useful when there is a concrete need to separate choosing an operation from doing it.

The same distinction introduces easy mistakes. Forgetting `perform` silently leaves an inert object. Performing the same description twice recovers the same keyed work, which may surprise someone expecting two messages. Copying it with a changed prompt but the old key conflicts. Generating fresh random keys defeats replay. JSON serialization of a description is not a new durable scheduling or export/import capability.

The executor is a deep boundary because a small call hides durable identity, admissions, outcomes, and bounded replay. Those are also hidden by a good Session method or direct function; the descriptor layer adds no new recovery power. If most workflows immediately construct a description only to perform it, this candidate adds syntax and temporary objects without earning its extra concept.

Recommendation: retain it as a real alternative for workflows that need to construct operation data before execution, but do not select it merely to minimize the number of methods. For the draft/review/revise case it is less direct than separate Session creation plus a result-returning message method. No agreed semantics must change to support this candidate; no added reads, waits, patches, controls, task language, or native command bus are justified by it.

## Evidence boundary

This is a read-only design analysis of the owning contracts and recent accepted amendments, with a new comparison document only. It is not executable validation of schema typings, Promise rejection handling, multi-message replay, or crash-safe cancellation propagation. Older exact-revision, exclusive Run–Turn membership, and combined first-message creation wording in normative documents remains superseded where the accepted decisions conflict; this candidate does not restore those rules.
