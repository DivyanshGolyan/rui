# Option A: explicit Session and Turn operations

> **Historical design exploration, published 6 September 2026.** The [normative architecture](../../../ARCHITECTURE.md) and [product contract](../../../PRODUCT.md) own the current design. Earlier signatures, issue ownership, status statements, and unselected alternatives below retain their original context; they are not a second current specification.

> Historical alternative: subsequent user decisions removed all direct-call idempotency keys and chose Session-addressed ordinary messaging. See the [revised proposal](../direct-session-cli.md). These examples are not the current recommendation.

Design candidate only. The CLI syntax and types below are illustrative, not implemented or accepted. This design treats the Session/Turn runtime as the shared execution module and the Workflow evaluator and direct CLI as consumers. It preserves one Host Runtime, one Storage Owner and the existing bounded execution machinery.

## Interface

```ts
type SessionPoint = {
  sessionId: SessionId;
  conversationRevision: Revision;
  contextRevision: Revision;
};

type DirectTurnAdmission = {
  key: DirectTurnKey;
  target:
    | { kind: "new_session"; workspace: WorkspaceRef; context: InitialContext }
    | { kind: "existing_session"; at: SessionPoint; contextPatch?: ContextPatch };
  message: ContentInput;
  contract: TurnOverrides;
};

type TurnAdmission = { key: DirectTurnKey; sessionId: SessionId; turnId: TurnId };

startTurn(input: DirectTurnAdmission) -> TurnAdmission;
inspectSession(sessionId) -> { current: SessionPoint; activeTurnId?: TurnId };
inspectTurn(turnId) -> CompleteTurnReport;
readTurnOutput(turnId, range) -> immutable answer bytes;
decidePermission(turnId, requestId, key, descriptorDigest, decision) -> DecisionReceipt;
cancelTurn(turnId, key) -> { turnId, key, intent: "recorded" };
```

`inspectSession` is deliberately a small current view, not a transcript listing. `inspectTurn` reports its current condition, exact actionable permission facts, immutable output reference on success, and terminal facts when present. It uses the accepted capture-before-delivery mechanism and content windows. Neither command opens a database from the client. No public historical snapshot service is needed.

Optional `inspectTurn --wait-ms N` waits for a terminal or actionable condition for a bounded duration and then returns a complete current report. It is read-only: expiry or client disconnect changes no execution intent and conveys no failure of the Turn. It must release database resources between observations. A bounded population of waiters, or CLI-side bounded polling, uses existing Host/CLI resource limits; this design does not require an event stream.

The first command atomically creates the Session, baseline context, Turn, initiating User Message and Conversation Entry. There is no empty-Session creation handshake. Existing Session admission checks both expected revisions and requires no nonterminal Turn. Sending new input to an already active Turn remains the existing distinct User Message operation, with its own key and applicability rules; `startTurn` never silently turns into steering.

Direct Model Interruption remains a distinct advanced control where already supported; cancelling a Turn must not be renamed to interruption. It is not necessary for the two-message usage example.

## First-request identity and replay

For direct admission, uniqueness is `(store, authenticated principal, direct_turn_key)`, within this admission operation only. The caller picks and retains a unique key before sending any bytes. It is not Session-scoped: a first request has no Session ID. The key binding includes the new/existing target discriminator, workspace, exact message bytes, context/patch and Turn-local inputs. This proposal avoids a new client-ID or workflow-like container solely to obtain a namespace.

The binding lives with the admitted Turn/provenance, with a uniqueness constraint, rather than a generic receipt ledger. Workflow admission retains `(run_id, agent_call_key)` and inserts the Run membership in the same admission transaction. An internal typed origin distinguishes the two sources without forcing their public interfaces into one generic union. Existing Turns cannot be adopted into another Run.

Authentication and access checks precede disclosure. Exact prior admission is then resolved before occupancy, current revision or terminality checks. A matching replay returns the same Session and Turn IDs even if the Session has advanced. Different content under the key conflicts. Current authorization must still permit disclosure; replay is not an authorization bypass.

A lost response is unknown. The CLI does not retry mutations automatically and does not maintain a hidden request journal. The caller explicitly reruns the identical invocation with the same key and unchanged input files. A rejection proves non-admission only when the server can establish it; a timeout does not.

## Two messages and a lost acknowledgement

All names below are proposed syntax. `onepage serve` is already running explicitly. The caller chooses unique keys in its own script and retains the input files unchanged for possible replay.

```sh
onepage turn start --key review-20260905-first \
  --new-session --workspace "$PWD" --message-file first.txt > first-admission.json
```

Suppose that response is lost. The next invocation repeats exactly the same command and key. It returns the original `{key, sessionId, turnId}` if the first invocation committed, or admits it once if it did not. It does not create a second Session.

```sh
onepage turn inspect "$TURN_1" --wait-ms 30000 > first-report.ndjson
onepage turn output "$TURN_1" > first-answer.json
```

The caller must validate the report's mandatory completion record before treating it as a complete report. The output command succeeds only after successful Turn settlement; it writes the exact schema value, or exact text answer, to stdout. Metadata belongs in the report, and command errors go to stderr/nonzero status. Successful report retrieval can describe a failed Turn without making the retrieval operation fail.

A successful terminal fact includes an immutable `after` SessionPoint captured when that Turn settles. The caller uses it for the second message:

```sh
onepage turn start --key review-20260905-second \
  --session "$SESSION" \
  --if-conversation "$TURN_1_END_CONVERSATION_REVISION" \
  --if-context "$TURN_1_END_CONTEXT_REVISION" \
  --message-file second.txt > second-admission.json
```

If another caller advanced the Session between the two messages, this is rejected as stale. It neither silently appends to the new head nor rewinds. The caller may inspect the current Session and intentionally submit a new request binding that point, with a new key. A changed retry is a new decision, not acknowledgement recovery.

Permissions remain explicit commands against exact Turn/request/digest identities. Waiting and answering permission requests need no extra LLM invocations unless the caller chooses to ask a model to decide.

## Current views versus replay-stable references

The `current` SessionPoint returned by `inspectSession` is an observation and may immediately become stale. The `after` SessionPoint attached to a settled Turn is a historical fact. It does not imply the Session is still there or currently available.

Workflow visibility must expose the settled Turn's historical `after`, never a fresh Session inspection. On deterministic replay, a keyed workflow call first reattaches to its existing Turn using the original binding; a new keyed continuation validates its expected SessionPoint only if it has not already been admitted. This remains correct when later Turns have already advanced the same Session.

The shell returns admission/inspection metadata separately from output bytes, so its existence does not force a schema-breaking envelope into workflow `agent()`. The workflow can later choose either an answer-plus-reference return or a distinct result/reference accessor. Both must use the same immutable terminal fact. The `agent()` shape remains a separate design choice.

A normal Session ID is never a sufficient historical continuation reference for deterministic workflow replay.

## Cancellation and authority

A standalone Turn needs durable cancellation intent. The smallest explicit addition is one keyed direct Turn cancellation fact, with the same immediate admission fence and effect-specific cleanup/reconciliation rules currently supplied by Run cancellation. A single shared classifier asks whether the Turn is fenced either by its direct cancellation or by its immutable Run membership's cancellation. Neither cancellation makes the Session terminal, and receipt does not claim physical work has stopped.

For an initially narrow policy, direct `cancelTurn` targets standalone Turns only; workflow-owned Turns are cancelled through their Run. This avoids silently changing the workflow failure propagation contract. It means a direct script may inspect a workflow Turn if authorized but cannot assume it owns that Turn's cancellation scope. A later design can allow single-member cancellation only with a defined workflow failure result.

Session access and Turn authority derive from stored Session/workspace scope, authenticated Principal and immutable admission provenance. A route containing a Turn ID is not authority. Run ownership remains orchestration provenance and a cancellation scope, not an artificial requirement for every permission or output read. A Turn inspection should disclose its workflow membership, when any, so callers know which cancellation target applies.

This requires carefully lifting existing Run-nested permission, interruption and content disclosure checks to explicit Session/Turn checks. It must not accidentally broaden capabilities formerly delegated only for one Run.

## Hidden mechanics and memory

The interface hides SQLite transaction ordering, new Session allocation, context resolution, provider requests, tools, recovery and effect custody. It does not expose evaluator scheduling or active-capacity controls. Dormant Sessions and terminal Turns are stored facts with no resident process or conversation graph. A short-lived client retains only bounded metadata and input/output buffers. Large answers remain content references until streamed; complete permission inspection uses the already accepted bounded capture workspace and charged temporary file.

## Tradeoffs and unresolved decisions

The explicit operations expose the important distinction between new Turn admission, later input to an active Turn, current inspection and exact historical continuation. Separate output reading keeps schema values unmodified and makes large answers straightforward to stream. There are more verbs than a single chat command, but they have independent retry and authority semantics the caller otherwise has to infer.

The direct-turn key namespace is simple but requires unique keys across the Principal's direct submissions within one Store. This is an intentional caller obligation; adding client scopes could reduce coordination but would introduce another identity to learn and persist.

This is a genuine domain change: direct admission provenance, standalone cancellation and authority/content reachability are currently Run-centric. It should not be described as merely adding CLI aliases. Nor does it require a second execution engine or an empty workflow wrapper.

Remaining decisions: whether terminal failure/cancellation expose an immediately usable `after` point depends on the unresolved pending User Message settlement rule; successful continuation is sufficient for this example. The exact workflow `agent()` reference interface, direct-turn cancellation representation, cross-consumer cancellation policy, and final public type/wire spelling are not settled by this candidate. The useful initial implementation slice is one successful two-Turn Session plus exact same-key replay and stale-point rejection, followed by the existing permission and effect-recovery invariants applied without a Run.

## Preferred continuation spelling: after a Turn

The common continuation command can name the preceding terminal Turn instead of transporting three related fields:

```sh
onepage turn start --key review-20260905-second \
  --after-turn "$TURN_1" --message-file second.txt
```

The server derives Session ID and both revisions from T1's immutable successful settlement, then applies the same exact expected-point admission. This is a historical predecessor, not "the latest Turn in that Session". If an independently admitted Turn advanced the Session, a new request fails stale. Exact replay of an already admitted second Turn still returns it even after later advancement.

This can be a native continuation target, `after: TurnId`, rather than mandatory CLI-side inspect/copy. It hides related identity assembly and removes a read request from the common path without introducing another stored reference type: the prior Turn already exists. The key's binding includes the predecessor identity; replay never substitutes its Session's current head. The first example accepts completed predecessors only until failure/cancellation continuation semantics are decided.

If both explicit SessionPoint and after-Turn targets are exposed, their canonical identity equivalence must be specified; the simplest initial surface can expose only after-Turn continuation for direct callers and retain exact points internally. Current Session inspection can identify its last settled Turn alongside active occupancy so a caller intentionally joining an existing conversation can select an explicit predecessor. Do not add a mode that implicitly chooses the current head during a mutation, since that makes an unknown-outcome retry sensitive to intervening work.
