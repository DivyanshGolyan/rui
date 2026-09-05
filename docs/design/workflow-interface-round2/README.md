# Workflow interface: three alternatives

> **Historical design exploration, published 6 September 2026.** The [normative architecture](../../../ARCHITECTURE.md) and [product contract](../../../PRODUCT.md) own the current design. Earlier signatures, issue ownership, status statements, and unselected alternatives below retain their original context; they are not a second current specification.

**Subsequent cancellation amendment:** the comparison below predates the [accepted simplification](../workflow-cancellation-stop-mapping.md#accepted-simplification). Unfinished Run cancellation may repeat all Session stops after a crash; callers coordinate reuse. Only completed Run cancellation suppresses further propagation. Earlier no-retarget/idle-receipt requirements in this comparison and its candidates are superseded.

**Selection:** the user accepted B, plain Session IDs and `createSession`/`sendMessage`, after the local-use-case audit. The comparison below records the alternatives at the time of evaluation; no implementation is claimed.

**Later amendment:** configuration is a third, independent operation that changes persistent Session settings (`configureSession` is the illustrative name). The two-function comparison below is historical evidence for the ID-based shape, not a prohibition on the accepted configuration capability. Active-work applicability and output-schema scope remain open.

Status: comparison and recommendation, 5 September 2026. B is now selected; none is implemented. Separate Session creation is already accepted; the question here is how workflow code addresses Sessions and expresses operations. See the [requirements](requirements.md) for the accepted constraints and [current decision](https://github.com/DivyanshGolyan/onepage/issues/101) for the broader work.

## A. Session objects

```ts
sessions.create({ key }): Promise<Session>
sessions.ref(id): Session
session.send(message, { key }): Promise<string>
```

```js
const writer = await sessions.create({ key: "writer" });
const draft = await writer.send("Draft a plan", { key: "draft" });
const revision = await writer.send(`Improve this plan:\n${draft}`, {
  key: "revision",
});
return { sessionId: writer.id, revision };
```

The object hides the Session ID argument and the evaluator's connection to the Host capability. It contains no conversation history, private view, or resident worker. Existing IDs require `sessions.ref(id)`, which constructs a wrapper without fetching or validating the Session; validation happens when used.

This reads naturally when repeatedly talking to a few named Sessions. Method discovery is convenient. Its cost is explaining that the object is temporary and that only its ID should cross workflow boundaries. A wrapper adds no isolation or recovery guarantee. [Full design and scenarios](a-session-capabilities.md).

## B. Session IDs and ordinary functions

```ts
createSession({ key }): Promise<SessionId>
sendMessage(sessionId, message, { key }): Promise<string>
```

```js
const writer = await createSession({ key: "writer" });
const draft = await sendMessage(writer, "Draft a plan", { key: "draft" });
const revision = await sendMessage(writer, `Improve this plan:\n${draft}`, {
  key: "revision",
});
return { sessionId: writer, revision };
```

The functions hide durable creation, admission, and recovery behind IDs and ordinary values. They are supplied to the workflow with its Run context; this is not a proposal for globally mutable runtime state. Existing IDs work directly: `sendMessage(args.writerId, message, { key })`. There is no reference-construction step.

This makes sharing explicit: the variable is the same ID another workflow or shell client can use. The cost is repeating the target argument and less method discovery. Neither an object receiver nor an ID prevents selecting a valid but unintended Session. [Full design and scenarios](b-data-functions.md).

## C. Operation descriptions and one executor

```ts
perform({ kind: "create-session", key, baseline }): Promise<SessionId>
perform({ kind: "send-message", key, session, message }): Promise<string>
```

```js
const writer = await perform({
  kind: "create-session", key: "writer", baseline: writerBaseline,
});
const request = {
  kind: "send-message", key: "draft", session: writer,
  message: "Draft a plan",
};
const draft = await perform(request);
```

Constructing a description does nothing; `perform` expresses the operation. It captures validated inputs and hides dispatch to the appropriate typed Host operation, together with the same admission and recovery work as the other candidates. This is a JavaScript surface, not a new generic native command protocol.

This is useful when scripts need to assemble or inspect requests before executing them. It adds a distinction between operation data and action, and forgetting `perform` leaves no work to run. One method is not necessarily fewer concepts. [Full design and scenarios](c-operation-descriptions.md).

## Comparison and recommendation

Recommend **B: Session IDs and ordinary functions** for the current agent-authored workflow consumer. It exposes two meaningful operations and keeps the Session reference as ordinary cross-client data. Separate creation already makes identity explicit; B carries that decision through without adding an object acquisition step. A remains a reasonable ergonomic choice if repeated receiver-style calls matter more to the user. C earns its extra concept only with a concrete request-staging use case.

All three can hide substantial execution and recovery machinery behind a small interface. All support ordinary helpers, loops, parallel composition, and result-dependent messages. C exposes more of the operation representation; it does not gain stronger replay behavior. This comparison does not rely on estimated implementation effort.

There is no measured material RAM advantage between tiny IDs and tiny Session wrappers. Disk-first storage, bounded active evaluations, and discarding JavaScript heaps at barriers dominate the resource contract. C can retain additional temporary request objects if authors stage whole arrays, but all candidates still require limits on pending work and materialized values.

The examples above omit schema and baseline detail to compare the shapes fairly. Creation must commit the complete baseline using the owning configuration contract. Messages may return exact schema-validated values instead of text; the schema vocabulary and inference mechanism are not selected here.

## What remains the same, and what remains unresolved

Creation returns identity without starting model work. Creation and each message have distinct stable Run-local keys. These keys recover operations and their recorded results; they are not Session names and do not become direct CLI idempotency parameters. Message invocation expresses submission; awaiting observes its result. No public Turn ID or separate workflow wait is needed to receive that result.

An acknowledgement lost after creation recovers the same ID. A crash before first submission can leave a valid empty Session. A replayed message recovers its original admission and result; a fresh message uses current shared Session state. JavaScript objects and Promises are reconstructed, not retained across evaluator destruction. These are required behaviors, not proof that the existing implementation supports them.

Run cancellation retains the agreed shared-Session behavior: stop current work in Sessions the Run submitted to, even if another Run started that work. Creating or referencing alone does not count. Recovery must not apply an already-applied stop to later continuation. The durable propagation mapping still needs its separate design and crash checks.

The comparison also exposes one shared question: messages joining the same active work can share one outcome, so incompatible requested output schemas need a defined admission rule. None of these syntaxes can promise independent typed answers to each contributor. Context-patch applicability remains unresolved as well. This exercise selects neither policy and adds no speculative read, wait, or control API.

## Verification and decision boundary

Three independent designs were reviewed against the same creation, sharing, replay, parallelism, failure, and cancellation scenarios. Local Markdown references and whitespace were checked. No runtime tests, memory benchmarks, production changes, or GitHub edits were made for this comparison. Older documents that still forbid empty Sessions or call separate creation undecided await integration of the user's accepted decision; candidate naming remains a proposal.

The user selected B's plain IDs. The next decision is settings allocation; storage and context contracts remain outstanding.
