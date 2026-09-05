# Alternative: completed Session exchanges

> **Historical design exploration, published 6 September 2026.** The [normative architecture](../../../ARCHITECTURE.md) and [product contract](../../../PRODUCT.md) own the current design. Earlier signatures, issue ownership, status statements, and unselected alternatives below retain their original context; they are not a second current specification.

Status: design candidate, not an accepted contract. This changes the workflow-facing answer-only contract in PRODUCT.md; it does not change the direct CLI or adopt a new durable snapshot subsystem.

## Interface

One operation sends a message and resolves to the completed exchange: its exact answer plus an immutable position in the Session that produced it.

```ts
type SessionPosition = {
  sessionId: SessionId;
  checkpoint: CheckpointToken;
};

type Exchange<T> = {
  at: SessionPosition;
  answer: T;
};

exchange<T = string>({
  key: string,                 // existing workflow replay identity
  message: string,
  after?: SessionPosition,     // omitted: create a Session
  schema?: Schema<T>,
  // existing bounded input/model/permission options, where applicable
}): Promise<Exchange<T>>;
```

`SessionId` names the live conversation. `SessionPosition` identifies that conversation at a particular completed exchange. They are deliberately different types: the position cannot silently mean “whatever the Session contains now.” The token hides the revision representation, not the historical precondition.

```js
const draft = await exchange({
  key: "draft",
  message: "Draft the migration plan.",
});

const review = await exchange({
  key: "review",
  message: `Review this plan:\n${draft.answer}`,
  schema: reviewSchema,
});

const revision = await exchange({
  key: "revise",
  after: draft.at,
  message: `Revise using this review:\n${JSON.stringify(review.answer)}`,
});

return revision.answer;
```

The review creates another Session. Revision continues the drafting Session at its recorded position. External callers can address `draft.at.sessionId` using the Session CLI. No public Turn appears.

An exact user schema describes `answer`, not the envelope. A review schema `{findings: [...]}` produces precisely that value at `review.answer`; metadata is neither added to that value nor requested from the model. This is an intentional breaking change to the current answer-only capability.

## Replay argument

1. Draft settles. Its answer and completion facts are durable; the evaluator is discarded while review is pending.
2. Restart reevaluates the script. Equal workflow call identity and bindings recover draft’s original answer and original position, even if the live Session has advanced.
3. Review recovers its existing execution or completed result. It does not create another Session.
4. If revision was already admitted, its exact replay reattaches before applying a current-position check. Its own progress cannot invalidate that replay.
5. If revision is new and another caller has advanced drafting meanwhile, `after: draft.at` conflicts. It neither incorporates unseen context nor forks the conversation.

Position validation, ownership checks, occupancy, and new-message admission are one atomic operation. The workflow retains existing durable call keys. The direct CLI still has no caller key, idempotent submission, or automatic retry.

## Memory and implementation

The envelope contains small identifiers plus the already-required answer representation. A position can derive from the canonical Session/Turn outcome and context facts; it needs no duplicated Conversation, persistent Session object, separate checkpoint rows, or retained JavaScript heap. Replay reconstructs envelopes in each temporary evaluator. Variable answers continue to obey the existing bounded workflow-value/content rules.

“Checkpoint” here means an immutable reference to existing facts, not a stored evaluator snapshot or copy of Session state. An implementation must bind both conversation and context position; wrapping only the last visible conversation entry would miss context-only changes.

## Advantages and costs

The workflow has one operation, and data dependencies directly express orchestration. There is no separately durable create/send/wait/read sequence and no mutable handle whose properties change across replay. Session identity and answer provenance travel together.

The cost is a public historical-position concept. It may feel like a Turn reference under another name. Its justification is narrower: callers name the conversation state they intend to continue, while execution episodes remain internal. If the product wants “continue current Session” even during workflow admission, this stricter behavior needs a deliberate decision rather than concealment inside the token.

This completed-exchange API also exposes a new Session’s ID only when the exchange settles. External intervention during its first execution must discover the Session through workflow inspection. Adding an eager Session handle would sacrifice this alternative’s main simplicity.

## Unresolved cases

- Failure/cancellation must expose a frozen error and recoverable Session identity; whether they produce a usable position depends on pending-message semantics, currently open in issue 102.
- Concurrent continuations from one position must not silently serialize into different conversation histories. Define a deterministic conflict policy; independent Sessions remain the supported parallel case.
- Decide whether external messages may join workflow-owned active work. Replay stability preserves the recorded result but cannot make first execution independent of admitted outside input.
- Session reuse after failure, permission handling, and the definition of settled remain runtime contracts, not properties supplied by an envelope.
