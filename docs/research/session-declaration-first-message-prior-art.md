# Session declaration and first-message admission

**Decision update — 2026-09-10.** The accepted [initialization contract](../design/session-initialization-proposal.md) keeps caller-owned references but establishes durable Session state through first configuration, before messages. The start-with-message recommendation below was not selected; retain it as research history.

Research and recommendation, 2026-09-10. This reconsiders empty core Session creation and the [logical-reference proposal](../design/workflow-session-reference-proposal.md). It does not amend the accepted API or claim production evidence.

## Start with the caller's purpose

A workflow author may want to name a reviewer, choose its configuration, start a review, and later ask a follow-up. These are distinct events:

- A JavaScript declaration describes intended use. Unused declarations need not leave durable Sessions.
- Core admission accepts responsibility for a Session and its first message. Those facts must survive a crash before model execution.
- Execution temporarily acquires resources to advance admitted work. A durable Session need not have a resident object or worker.

The question is whether anyone needs the durable Session before there is a first message. Naming something in JavaScript does not by itself establish that requirement.

## Relevant primary-source examples

### Codex SDK: a local declaration before the first turn

At revision `bf5ebd98c567931d82e873a4afdac7548bd85979`, `startThread(options)` synchronously constructs a `Thread`; it makes no creation request. The object stores options and initially has a null ID. Running a turn invokes the executable, and a `thread.started` event supplies the ID. [Factory source](https://github.com/openai/codex/blob/bf5ebd98c567931d82e873a4afdac7548bd85979/sdk/typescript/src/codex.ts#L21-L38), [Thread source](https://github.com/openai/codex/blob/bf5ebd98c567931d82e873a4afdac7548bd85979/sdk/typescript/src/thread.ts#L40-L110).

This supports separating the author-facing declaration from execution. It does not establish atomic durable first-message admission or recoverable workflow identity. The SDK uses mutable object state, and its class documentation describes consecutive turns. That is insufficient evidence for concurrent first calls or replay from a discarded JavaScript heap.

Codex's app-server offers a different surface: `thread/start` returns a thread ID, followed by `turn/start` with user input. The same product family therefore provides both a convenient local declaration and a separate server creation operation. Its API shape cannot decide which core operation OnePage needs. [Official app-server lifecycle](https://learn.chatgpt.com/docs/app-server#typical-flow).

### Pi: an identity can precede its session file

At revision `400d6905ce46ec46e79da8a7701b1b48850192df`, Pi's `newSession` creates an ID, in-memory header and intended file path. On the ordinary fresh-session append path, `_persist` defers file creation until an assistant message exists, then writes accumulated entries. Explicit file opening, rewriting and branching have other paths; this is not a claim that Pi never writes empty sessions. [Initialization](https://github.com/earendil-works/pi/blob/400d6905ce46ec46e79da8a7701b1b48850192df/packages/coding-agent/src/core/session-manager.ts#L926-L951), [Persistence](https://github.com/earendil-works/pi/blob/400d6905ce46ec46e79da8a7701b1b48850192df/packages/coding-agent/src/core/session-manager.ts#L1029-L1063).

The useful lesson is that having an ID does not imply durable creation. OnePage should not copy this persistence timing: its accepted message must survive a crash before any assistant response. This is an inference from the inspected path and OnePage's stronger admission contract, not an end-to-end crash test of Pi.

### Cloudflare and Orleans: identity before activation

Cloudflare explicitly says constructing a Durable Object stub sends no request and does not instantiate the object. Orleans similarly supplies references identified by type and key, while runtime activation and application persistence are separate. These are precedents for naming a future target. [Cloudflare lifecycle](https://developers.cloudflare.com/durable-objects/concepts/durable-object-lifecycle/), [Orleans references](https://learn.microsoft.com/en-us/dotnet/orleans/grains/grain-references), [Orleans persistence](https://learn.microsoft.com/en-us/dotnet/orleans/grains/grain-persistence/).

They also expose the cost of that choice: identity rules, initialization concurrency and failure semantics remain real machinery. Cloudflare's stub ordering and failure propagation exceed ordinary Promise composition; Orleans does not durably suppress duplicate deliveries caused by retries. Neither proves OnePage's atomic creation/message transaction. The [companion actor comparison](session-activation-prior-art.md) traces these limits and their primary sources.

## Recommendation for OnePage

First examine one explicit **start-with-message** core operation. Given complete initial configuration, first-message inputs and a request identity, its transaction would save the Session, baseline revision, first-message admission and original request answer together. A definite rejection would save the original rejection without creating an empty Session. A commit followed by a lost reply would be recovered using the same request identity; changed inputs would conflict. Provider execution would begin only after admission commits.

Core's accepted answer would expose the real Session ID and the bound message work. Workflow code could obtain that answer through an ordinary Promise, then use the real ID for subsequent messages. Admission and final work completion remain distinct: an API that resolves only with the final answer unnecessarily delays callers that need the ID to submit more input during active work. The exact workflow result shape still needs selection.

A declaration helper can hold configuration locally, but it must not quietly become a second recoverable identity protocol. A reusable configuration value is also not inherently one reusable conversation: invoking a start operation twice with different keys would create two Sessions. Code wanting the same Session must reuse the first admission's ID, or explicitly choose a preassigned-address design.

| Scenario | Consequence of the proposed starting point |
| --- | --- |
| Declare configuration and never send | No core Session or request |
| First message rejected | Original keyed rejection; no empty Session |
| First admission committed, reply lost | Same-key retry recovers the original Session ID and message binding |
| First model execution fails after admission | Session and admitted message remain inspectable; creation is not rolled back |
| Follow-up after first admission | Ordinary send using the returned ID; active work retains existing join/admission rules |
| Two branches must address one Session before first admission returns | Introduce an explicit Promise dependency, or justify preassigned identity as a separate core capability |
| Configure before starting | Supply the intended initial configuration; there is no durable update history for a nonexistent Session |
| Save/share a configured Session without sending | Concrete reason to retain empty creation, if selected as a product capability |

Configuration history for an existing Session remains unchanged: every admitted explicit instruction update is preserved. Removing empty creation must not accidentally reintroduce instruction coalescing for already-created Sessions.

This approach removes a standalone creation effect and its dependent-failure cascade. It accepts another fixed-input evaluation when JavaScript needs the admitted ID. If immediate independent addressing is necessary, make that an explicit core identity contract available to all callers, with separate Session identity and per-message request identity. Do not invent a Workflow Runtime graph solely to avoid the evaluation.

## What remains to decide and verify

The current accepted [core API](../design/session-core-api-contract.md) still has separate creation. The proposal above would amend that contract, initialization atomicity and corresponding verification; it is not a description of current behavior.

Before adopting an API, trace sequential follow-ups, early additional input, first-admission rejection, same-key replay, configuration conflicts, cancellation during uncertain first admission, and crash after commit before reply. Reuse the [shared request identity](../design/shared-request-identity.md) rules rather than adding another recovery ledger. Cancellation must still resolve a saved unanswered start request before applying the accepted stop policy; it may admit work before stopping it.

Sources were inspected; no provider execution, production change or crash experiment was performed. Documentation checks cover local references and whitespace only.
