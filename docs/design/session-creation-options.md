# Session creation and existing references

## Accepted amendments — 10 September 2026

The accepted [Session initialization and reuse decision](session-initialization-proposal.md) supersedes separate creation, generated-ID discovery and implicit first-message initialization: callers construct references locally; first complete configuration establishes the Session; exact full keys from Run-state inspection can be used unchanged in later workflows. The [shared request contract](shared-request-identity.md) gives direct and workflow configuration/message submissions the same stable acceptance/rejection replay, with independent workflow bookkeeping. The original discussion below is historical where it differs.

> **Historical design exploration, published 6 September 2026.** The [normative architecture](../../ARCHITECTURE.md) and [product contract](../../PRODUCT.md) own the current design. Earlier signatures, issue ownership, status statements, and unselected alternatives below retain their original context; they are not a second current specification.

Status: historical comparison, 5 September 2026. Separate creation was accepted; the later accepted surface is `createSession({ key })` returning a plain ID and `sendMessage(id, message, { key })`. The handle/get syntax below was not selected. No implementation is claimed. Completes the next question in [Choose replay-stable Session continuation from agent results](https://github.com/DivyanshGolyan/onepage/issues/101), after selection of `send(): Promise<Answer>`.

## Historical proposed shape

```js
const writer = await sessions.create({ key: "writer" });
const draft = await writer.send("Draft the plan", { key: "draft" });

// In another workflow, with the Session ID supplied as an argument:
const sameWriter = sessions.get(sessionId);
const revision = await sameWriter.send("Revise the plan", { key: "revise" });
```

`create` records the Session and its complete baseline context and returns a small handle with `id`. It makes no model request. `send` uses the already-selected message-result contract for both the first message and subsequent messages. The two keys identify different operations: Session creation and a particular submitted message.

`get(id)` is proposed as a pure local wrapper around a Store-relative Session ID, not a read of Session metadata or a server resource acquisition. It creates no Session, durable attachment, ownership lease, or model work. A nonexistent ID fails when an operation reaches the server. A handle obtained this way is not proof that the Session exists. The ID must come from stable workflow arguments or a recorded result for deterministic replay.

## The actual tradeoff

| Shape | Benefits | Costs |
| --- | --- | --- |
| Create first, then send | Immediate Session ID after creation; one message/result method for every message; ordinary Promise return types | One additional keyed durable creation operation and admission boundary; a Session can remain empty |
| Create with the first message, returning `{ session, result }` after admission | Session and first message commit together; one key covers the initial exchange | Different first-message shape, an admission-visible container plus a separately reconstructed result Promise |

The second option would preserve the earlier no-empty-Session rule without requiring a special thenable. Its answer can still be exact user-schema data at `await result`. Neither option is free: both need Session identity visible before the first work outcome, beyond the current evaluator's answer-only capability. Lazy first-send creation would conceal this timing and need additional rules for when an ID exists, so it is not the recommended shortcut.

The recommendation accepts the additional creation operation in exchange for a simpler caller model. An empty Session is inactive by absence of work; it needs no fake Turn, empty User Message, outcome, special lifecycle flag, active worker, or permanent resident object. It remains valid if the caller stops before sending anything. This is a storage cost, not a measured RSS result.

## Recovery and composition traces

1. Creation atomically commits Session, complete baseline context, and the Run-local creation key/binding. The key and operation kind cannot be reused with conflicting creation inputs or as a different message operation.
2. If creation commits but acknowledgement is lost, replay recovers the same Session ID. If no creation committed, replay may perform it once. No provider request is involved in either path.
3. If the workflow stops or crashes after creation but before its first message, the Session remains empty. Explicit workflow recovery reuses it; the runtime does not manufacture a first message or automatic model work.
4. The first message atomically admits its internal Turn, initiating User Message, and Conversation entry against the existing baseline. This preserves first-Turn atomicity while removing the requirement that Session creation share that transaction.
5. Another trusted client may send to the Session before the creator does. The creator's later send uses current state and can join active work, with no creator priority or historical revision guard.
6. The Session handle survives a model failure conceptually because it was obtained independently; replay reconstructs it before recovering a failed message result. No metadata needs to be inserted into schema output or a model error just to expose the Session ID.
7. Creating or referencing a Session without sending a message does not add it to that Run's selected cancellation set. Once the Run submits a message, the existing used-Session cancellation rule applies.

The creation result must be visible to a later disposable evaluation as a small recorded Session reference. This requires bridge/admission support, and may add an evaluator boundary before first work. It does not justify preserving an evaluator heap between calls. No exact storage bytes or latency are claimed.

## Existing contract and source evidence

- [Version model-visible Session context and bind exact model requests](https://github.com/DivyanshGolyan/onepage/issues/59) currently explicitly forbids empty Sessions. [Direct CLI exploration](direct-session-cli.md) also assumes creation with a first message. Separate creation needs an explicit amendment, not an inference that the rule has already changed.
- [Architecture](../architecture/workflows.md#workflow-runs) and [product contract](../../PRODUCT.md) describe an older combined first-message admission. The context requirement that Session and its complete baseline commit together can be preserved with separate creation.
- [Session glossary](../../CONTEXT.md) requires reusable linear Conversation, not a minimum message count.
- [Current Session implementation](../../src/session.zig) uses the earlier ledger runtime: `create` requires root task content, and `openExisting` reads storage, binds scratch, validates Workspace, and claims ownership. It is not the proposed lightweight `get(id)` wrapper.
- [Evaluator source](../../src/workflow_evaluator.zig) currently supplies only `agent()` and one pending/recorded-result Promise. Neither creation alternative is an implemented workflow API.

This is a source-checked design trace, not an executable recovery proof. No production files or GitHub contracts were changed for this comparison. The later accepted choice permits empty Sessions. Precise settings and bridge implementation remain outstanding; the historical no-empty criterion is superseded.
