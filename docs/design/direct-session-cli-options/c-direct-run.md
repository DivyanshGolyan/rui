# Candidate C: a direct Run with exactly one Turn

> **Historical design exploration, published 6 September 2026.** The [normative architecture](../../../ARCHITECTURE.md) and [product contract](../../../PRODUCT.md) own the current design. Earlier signatures, issue ownership, status statements, and unselected alternatives below retain their original context; they are not a second current specification.

> Historical alternative: subsequent user decisions removed all direct-call idempotency keys and chose Session-addressed ordinary messaging. See the [revised proposal](../direct-session-cli.md). These examples are not the current recommendation.

Status: design alternative, not an accepted decision. Planning only.

## Shape

Keep a Run as the public admission, inspection, permission, content-access, and cancellation scope. Introduce exactly two closed kinds: Workflow Run and Direct Run. A Workflow Run admits keyed Turns through a disposable evaluator; a Direct Run atomically admits exactly one Turn without any evaluator. Both advance through the same existing Turn engine. A Session remains a reusable linear conversation and is never an execution owner.

This is stronger than disguising chat as a one-line workflow. Do not generate JavaScript, store synthetic workflow source/arguments, create Evaluation Generations, or instantiate QuickJS for direct work. Do not make Direct Run an extensible job type. Its one purpose is externally orchestrated conversation advancement.

A two-message chat consists of two Direct Runs advancing the same Session. Each Run owns only its own Turn. The additional Run identity is the central conceptual cost of this alternative.

## Native signatures and wire shape

```ts
type SessionRef = {
  id: SessionId;
  expectedConversationRevision: Revision;
  expectedContextRevision: Revision;
};
type DirectTurnInput = {
  session: { new: NewSessionSpec } | { continue: SessionRef };
  task: SealedText;
  contract: TurnContractInput;
  sessionContext?: SessionContextPatch;
};

admitWorkflowRun(input: WorkflowRunInput): WorkflowRunAdmission;
admitDirectRun(input: { key: RunKey; turn: DirectTurnInput }): DirectRunAdmission;

// Immutable admission facts, not current status or continuation readiness.
type DirectRunAdmission = { key: RunKey; runId: RunId; turnId: TurnId; sessionId: SessionId };

inspectRun(run: RunId): CompleteRunReport;
decidePermission(input: ExistingExactPermissionDecision): PermissionDecisionReceipt;
interruptModel(input: ExistingExactModelInterruption): ModelInterruptionReceipt;
cancelRun(input: ExistingRunCancellation): RunCancellationReceipt;
readContent(input: ExistingScopedContentWindow): ContentBytes;
```

HTTP can retain `POST /v1/runs`, using a closed `kind: workflow | direct` metadata discriminator. The adapter selects one of the two separately typed native methods; this does not require a generic native command/result union. The original Run key namespace includes the kind in its binding, so retrying a workflow key as direct work conflicts. Other selected resource routes stay unchanged.

Alternatively separate creation routes can preserve an untagged existing workflow request, but that is a route spelling choice rather than the defining architectural tradeoff. There must remain a single meaning for a Direct Run, not optional workflow fields in every input or row.

A completed direct report exposes its member Turn Outcome, answer Content Reference, and historical SessionRef. It has no invented Workflow Output. A failed or cancelled direct report exposes the typed Turn Outcome; whether and how a continuation reference is usable follows the unresolved failure/pending-message policy. Never silently call a failed Turn completed just because its Run can be inspected.

## Shell-first two-Turn example

Illustrative command notation only; no commands are implemented. Files below are caller-owned immutable replay inputs, not an automatic CLI journal.

```sh
onepage run direct --request first-turn.json > first-admission.json
# first-turn.json carries key chat-42/1, new Session settings, and exact task bytes.
# receipt: {key:"chat-42/1", runId:"r1", turnId:"t1", sessionId:"s1"}

onepage run inspect r1 --wait-ms 10000 > first-report.ndjson
# Complete report eventually carries completed t1, answer reference,
# and continuation {id:"s1", expectedConversationRevision:"8", expectedContextRevision:"1"}.

onepage run direct --request second-turn.json > second-admission.json
# second-turn.json carries a fresh key chat-42/2, that exact historical reference,
# and the second task. Receipt identifies r2/t2/s1.
onepage run inspect r2 --wait-ms 10000 > second-report.ndjson
```

A bounded wait can end with a complete nonterminal report. It does not claim completion, retain a SQLite transaction, or keep a Session resident. Caller shell logic can repeat inspection without an LLM call. Waiting connections and their small state are charged to existing connection budgets; the wire mechanism remains a separate small implementation choice.

### Lost response, including the first creation

If the first `run direct` loses its acknowledgement, the caller knows only `chat-42/1` and the exact original input. Reissue that same command explicitly. One transaction either finds its matching immutable admission and returns r1/t1/s1, or creates those facts if the original never committed. No Session ID lookup, durable receipt table, generated replacement key, or auto-retry is required.

Resolve an existing key and compare canonical binding before checking current Session occupancy or revisions. Otherwise a retry after t1 completes, or after a later t2 begins, would incorrectly fail. A changed task, context, Session reference, or kind with the same key conflicts. A fresh key carrying an old SessionRef fails stale-reference validation; replay does not authorize a new Turn at the current head.

The continuation in the report is tied to t1's terminal frontier. It must not be synthesized from s1's latest mutable head. A later t2 cannot change what t1 supplies to a replaying workflow or shell caller. Existing Turn Contract and immutable Conversation provenance may derive that frontier; if they cannot prove it, the minimal missing terminal fact must be committed, not replaced by a floating Session ID. This is still the open continuation design question, not a settled schema choice.

## Hidden mechanics

Direct admission checks Principal authority, Run-key binding, exact Session revisions, compatibility and occupancy, then atomically commits Run identity, the single Turn membership, Turn Contract, initiating User Message, and its Conversation Entry. A fresh Session and baseline context are created in that transaction when requested. There is no separately visible empty Session or half-created Run.

The membership can use one reserved internal direct-call key. It is not another caller parameter, and its identity is domain-separated from workflow Agent Call Keys. The existing at-most-one-Run-membership-per-Turn constraint remains intact.

The scheduler chooses Workflow evaluation only for the workflow kind. Direct execution uses existing relational runnable-Turn classification, effect admission and recovery. A Direct Run has no separate terminal result authority: its displayed terminal outcome comes from its sole Turn. Workflow terminal results retain their existing authority. Common Run identity and cancellation intent can remain common relational facts; the kind-specific workflow binding is separate rather than a nullable collection of fictitious direct-workflow values.

Cancellation still fences through immutable Run–Turn membership. Cancelling r1 cannot cancel a later t2 in r2 even though both use s1. Cancelling a Workflow Run cannot cancel a direct or other-workflow Turn that merely shares a Session. Existing terminal memberships retain valid history. Session identity confers access according to existing scope checks, but never transfers Run cancellation ownership. A Session has at most one active Turn, so conflicting direct/workflow admissions cannot run concurrently in that conversation.

Memory does not scale with Direct Run or dormant Session count. Extra cost is durable Run/membership rows and bounded query work, not resident QuickJS heaps or per-chat workers. Common inspection capture, immutable content windows, one SQLite connection, fixed active capacities and temporary scratch all remain unchanged. No numerical memory claim is justified without implementation measurement.

## Honest costs and comparison

Advantages:

- Reuses the selected Run-facing controls, content disclosure, cancellation fence, request-key scope and report capture.
- Gives the direct caller an independent cancellation scope immediately, without inventing a new Turn-cancellation authority model.
- Keeps workflow and external orchestration on the same Turn engine and supports direct work without evaluator memory.
- Lost first-creation acknowledgement uses an existing domain admission key, with no special discovery operation.

Costs:

- Every externally initiated Turn gains a Run identity although the caller primarily thinks in Sessions and Turns. Two chat messages mean two Runs.
- The glossary's current Run means Workflow Run. Widening it is a real domain change, not adapter glue. Run must now mean execution scope with two closed kinds, while Workflow Run remains precise.
- Workflow-only inputs, generation counts and output semantics need honest typed separation. Pretending they apply to direct work creates avoidable special cases.
- The direct Run has nearly the same lifecycle as its sole Turn. Reusing code does not by itself justify that extra public concept.
- This does not solve Session continuation by itself: historical references remain required in both consumers.

## Recommendation

Prefer this option only if preserving a common public cancellation/access/report scope is judged more valuable than making the direct caller manipulate only Sessions and Turns. It is a coherent, memory-bounded alternative, and substantially better than a synthetic JavaScript wrapper. Given the user's stated model that the runtime fundamentally advances Sessions and workflows are one consumer, a direct Session/Turn API likely expresses the intended boundary more clearly. Do not choose the uniform Run solely to avoid editing existing documents or routes; compare its extra caller-visible identity against the actual authority/cancellation changes of that simpler conceptual model.

Evidence read: CONTEXT.md Session/Turn/Run definitions; ARCHITECTURE.md lines 73–88, 174–180, 203–214 and 230; docs/design/client-server-interface-options/README.md selected resource operations and replay contract; candidate B's native-only agent-call restriction. This proposal explicitly changes that current restriction and does not present it as already authorized architecture.
