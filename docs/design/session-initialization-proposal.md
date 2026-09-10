# Caller references and ordered Session configuration

## Discovering and reusing Sessions across workflows

When an agent asks for a Workflow Run’s state, inspection exposes the full keys of its associated durable Sessions with enough context to distinguish them. The agent can then write a selected exact key directly into another workflow’s source. That key is used unchanged; only the new requests receive the new Run’s request-key scope. This does not require the first workflow to return Session metadata, a `previousRun` argument, lookup code, an attachment operation or an existence-check round trip. An unused local reference declaration does not create a durable Session.

Reuse continues the same Session’s current conversation and configuration. It does not clone it, restore its position at the end of the earlier Run or grant access merely through possession of the key. Run-local naming prevents accidental short-name collisions; this flow selects no separate “must be new” creation operation.

Accepted 2026-09-10 following the caller-owned identity discussion. This amends the [core API](session-core-api-contract.md); it is a documented contract, not production implementation evidence. The filename records the document's proposal origin.

## Caller-owned naming and durable configuration

The caller constructs and scopes a Session reference locally. Core treats its key as opaque within the Store. A workflow caller scopes a short name by Run identity: the same name in another Run identifies a different Session, while replay of the same Run retains the same key. Session operations also accept a full key unchanged for deliberate reuse across Runs. Naming does not confer access and requires no core operation.

Durable configuration is different work. It can establish a useful Session before any message and requires core acknowledgement. That reopens the earlier recommendation to create durable Session state only with the first message. Caller-owned naming remains valid regardless of when durable initialization happens.

## Accepted behavior

Use one configuration operation. Against an unknown Session key, it requires enough validated input to establish the complete baseline, Workspace and access scope. Against an existing Session, it applies supplied mutable configuration fields as an ordinary update. Workspace and access-scope constraints remain enforced; this does not make every initialization field mutable.

Illustrative workflow surface:

```javascript
const reviewer = session("reviewer");

await configureSession(reviewer, completeConfig, { key: "setup" });

const answer = await sendMessage(reviewer, "Review the implementation", {
  key: "review",
});

await configureSession(reviewer, { instructions: revisedInstructions }, {
  key: "revise-instructions",
});

return await sendMessage(reviewer, "Review the tests too", {
  key: "tests",
});
```

`session` is pure reference construction. It neither submits configuration nor claims the Session exists. `configureSession` describes a durable request; its Promise resolves on committed configuration acceptance, or rejects with the recorded rejection. `sendMessage` retains the existing workflow Promise of the bound work's final result. Core's message admission acknowledgement is independently available before that final result and before any provider request.

Awaiting configuration before describing a message makes the message depend on successful configuration. Under the fixed-input evaluator this may require a fresh evaluation. The dependency is on successful durable work, not on discovering an ID. No special native dependent-failure record is required: ordinary JavaScript decides whether to call `sendMessage` after the configuration result.

## Ordered behavior

Core admission order determines which valid configuration changes apply first. Distinct requests supplying instructions A, then B, then A preserve those explicit updates. New model requests select the current committed configuration; an already admitted model request retains its frozen inputs. Existing continuation-compatibility validation and Action-time permission selection remain applicable.

There is no special original-baseline equality rule. Two fresh full-configuration requests for the same Session key become successive configuration admissions, subject to ordinary field validation and immutable Workspace/access constraints. A partial configuration request against an unknown key rejects if it cannot establish a complete baseline. A message to an unknown key rejects; message submission does not implicitly initialize or configure a Session.

The first accepted configuration transaction saves the Session, complete baseline and original request answer together. A rejected first configuration saves its definite rejection without leaving a partial Session. Storage failure that prevents a commit cannot promise a durable answer.

## Replay and identity

The Session key identifies a conversation. The request key identifies one configuration or message submission. Internal Turn identity identifies the work a message starts or joins; multiple message request keys can bind to one Turn. Configuration does not itself start a Turn.

Retain the [shared request contract](shared-request-identity.md): check an existing canonical binding and recover its original answer before reevaluating current admission conditions. A matching retry applies nothing again. Changed inputs under the same request key conflict. A fresh intended change uses a new request key even when its supplied values equal current values.

If configuration commits and the reply is lost, retry recovers that acceptance; it does not reset later configuration. If a message was rejected before the Session existed, that request remains rejected after another request establishes the Session. A new intended submission uses a new key.

Workflow cancellation retains its existing recover-submission-then-stop contract. Configuration alone does not add a Session to the stop set, and admitted configuration is not rolled back.

## Why this operation rather than separate creation

A dedicated creation operation would be justified by a distinct caller need, such as asserting that a Session key is unused or reserving a Session without a complete baseline. Those behaviors have not been selected. The discussed behavior is to address a caller-named Session and apply configuration linearly, which one configuration operation expresses directly. Requiring a complete baseline before messages remains a domain invariant rather than a separate initial-configuration conflict policy.

Claude Code's Dynamic Workflows are useful prior art for task-result composition, but their documented script API exposes `agent(prompt, options)` rather than reusable Session initialization and updates. They do not decide this operation for OnePage. The [source comparison](../research/claude-workflow-session-initialization.md) separates that surface from outer workflow launch acknowledgement and replay.

## Decision and evidence

This decision replaces separate creation with first-configuration initialization in the core API. The owning Product, Architecture, Context and Verification contracts are aligned with it. It supersedes the special creation-reference resolver and first-message initialization candidates; those research and proposal records remain historical evidence. Exact function names, key encoding and wire types remain open. Configuration success acknowledges its committed effect; no generated Session ID or historical revision token is required to proceed.

Required evidence includes Run inspection followed by unchanged exact-key reuse in another Run, deterministic Run-local separation/replay, first full versus incomplete configuration, concurrent valid changes, immutable-field rejection, explicit equal-value instruction updates, message-before-configuration rejection, lost replies, replay after later changes, provider-independent acknowledgement, and cancellation with unanswered configuration/message intents. These are required implementation checks; this accepted documentation decision supplies no production test or provider evidence.
