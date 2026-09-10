# Session-based workflow interface

## Instruction history amendment — 10 September 2026

The [instruction-history decision](instruction-update-history.md) supersedes net-content coalescing below: preserve every explicit admitted update, including equal text, through canonical update identity. First configuration and every later configuration acknowledgment represent durable commit, without waiting for provider work.

## Accepted amendments — 10 September 2026

The accepted [Session initialization and reuse decision](session-initialization-proposal.md) supersedes separate creation, generated-ID discovery and implicit first-message initialization: callers construct references locally; first complete configuration establishes the Session; exact full keys from Run-state inspection can be used unchanged in later workflows. The [shared request contract](shared-request-identity.md) gives direct and workflow configuration/message submissions the same stable acceptance/rejection replay, with independent workflow bookkeeping. The original discussion below is historical where it differs.

> **Historical design exploration, published 6 September 2026.** The [normative architecture](../../ARCHITECTURE.md) and [product contract](../../PRODUCT.md) own the current design. Earlier signatures, issue ownership, status statements, and unselected alternatives below retain their original context; they are not a second current specification.

Status: accepted public shape with remaining settings and durable-mapping decisions, 5 September 2026. The user wants Sessions, messages, conversation entries, and answers as the public model, with Turns internal to execution. This records the accepted shape and traces its recovery obligations; it does not resolve the continuation decision or silently replace the existing workflow replay-key contract.

The accepted behavior below is published in the [interim Session and workflow decision record](https://github.com/DivyanshGolyan/onepage/issues/101#issuecomment-5550876667). Affected implementation, verification, budget, and planning issues have been amended. Workflow messages now return a Promise of their recorded answer. Separate creation and the plain-ID `createSession`/`sendMessage` surface are accepted. Optional Session output schema and provider-boundary validation are accepted. Other supported settings and exact stop/Run settlement integration remain open. The [Turn Contract grouping is removed](turn-contract-removal.md), and unfinished cancellation uses the accepted repeatable stop pass; no production implementation is implied.

## Choices accepted during the decision session

**Local trust.** One trusted local owner per explicitly started server and Store. The local Unix-socket access boundary admits clients acting for that same owner. All admitted clients share Session/Run access; V1 adds no per-agent identities, roles, Session ACLs, or delegation machinery. Store identity, exact target validity, cancellation fences, and private provider-content disclosure rules remain distinct from per-caller access control. Tool execution uses the Session's explicit ask/bypass setting at each Action admission and retains exact Action Authorization; access to the server does not automatically select bypass.

**New work versus replay.** A new workflow message uses the Session as it exists at admission. Another trusted client's intervening message is ordinary collaboration, not grounds for a stale-observation conflict. Ordinary continuation requires no expected historical Conversation/Context revision from the caller or hidden stale-observation check. A replayed workflow operation instead recovers its original committed admission and the recorded result of the work that accepted that message. Request preparation still freezes exact inputs for each model Operation; a message arriving after a request was frozen cannot change that request.

**Caller-agnostic Session operations.** A Caller is one input or observation source. The server maintains no caller-specific conversational position, ownership lease, remembered read frontier, or requirement that a Caller has seen the latest change. A read captures Session facts as of its observation. A message is admitted against current Session state. A wait selects current work once when it begins and observes that work to settlement; subsequent work cannot extend the existing wait. There is no separate answer owed to each input source. Workflow replay recovers the original submission/result in Run bookkeeping, not in per-caller Session state.

**Independent persistent configuration.** Session settings persist until explicitly changed. Configuration is a separate operation from message submission; illustrative spelling is `configureSession(sessionId, changes, { key })`. The sparse change and its recorded workflow result commit atomically, and omitted settings remain unchanged. Replaying a completed configuration key returns its result without reapplying old settings. A later message failure does not roll back the change. Other clients can change settings between configure and send; that interleaving is ordinary composition, not a revision conflict. Configuration alone does not start model work or add a Session to the Run's message-based cancellation set. Exact acknowledgement shape remains open; the request-construction rule below selects the timing boundary.

**Request construction — accepted.** A new model request is constructed from one committed view of current Session configuration and its applicable canonical inputs. Its Model Request Manifest freezes the selected revision, resolved settings, input references, and request semantics. Later changes affect only requests not yet constructed; replacement Attempts reuse their existing manifest. There is no Turn-wide copy of model settings, per-setting activation queue, or requirement that every intermediate configuration value be used. Configuration alone creates no model work. Validity and continuation compatibility remain separate from this common construction boundary.

**Append-only model context — accepted direction.** Append-only model-visible updates are the accepted direction. Keep the initial instruction prefix stable and preserve previously supplied messages and provider continuation. Later instruction/context changes enter at a fixed position in the model-visible history, using a provider-supported representation; new requests must preserve continuation compatibility as well as their own immutable retry inputs. Session configuration remains current state and changes independently of message submission. This does not make every Host setting a conversational message, require exposure of every unused intermediate value, authorize Workspace rebinding, or adopt a particular provider's tool/effort update protocol. Appended system instructions are a distinct Conversation Entry kind, visible in Session history alongside messages and tool results. The name is System Instruction, not a generic Context Update. First inclusion commits with the next assistant-response request as described below; exact storage/wire encoding remains implementation work. Existing permission admission and supported compaction contracts remain in force.

**System Instruction first inclusion.** The next assistant-response request admission compares current instruction content with the last applied value and commits any new instruction together with that request and eligible user-input projections, after preceding tool results. Retry reuses the original entry and manifest; rollback creates none of those new facts. Unused intermediate settings produce no instruction, and a revision-only change does not count as changed instruction content. Pre-admission compaction uses already-applied inputs; after admitted overflow it covers the instruction already recorded. No pending instruction queue, applied flag, or duplicate receipt is needed. The [storage and recovery traces](system-instruction-first-inclusion.md) specify the boundary cases; exact columns/wire tags remain implementation work.

**Persistent permission mode.** Session configuration defaults to `ask` and may explicitly change during active work. Each child Action admission selects the current mode and atomically records its configuration provenance, exact descriptor, and pending Permission Request or bypass Authorization. A change leaves existing requests pending and existing Authorizations valid, even before an Attempt starts; running actions are unaffected. Recovery reuses committed admission facts. Configuration creates no work and replay never reapplies an old mode. The same sparse history supplies provenance without a Turn-wide permission snapshot or resident worker. Cancellation and exact-target applicability still apply.

**Optional Session output schema.** Ordinary text is the default. A schema persists until changed or cleared through Session configuration, using the same request-construction boundary as other model settings. The adapter translates it into the supported provider mechanism and parses and validates the model-generated result against the producing request's frozen schema. The Host retains settlement and result authority. Shared-work callers receive that same recorded outcome; later configuration and replay cannot reinterpret it. There is no per-message schema, prose conversion, or automatic model repair call. Exact schema subset and error encodings are implementation work. Codex subscription support is assumed for planning, without claiming a live compatibility test.

**Workflow message completion.** `sendMessage(sessionId, message, { key, ... })` returns a Promise that fulfills with the recorded final text or exact schema-validated value of the work accepting that message, and rejects with its frozen failure or cancellation. The caller can await immediately or keep the Promise and await later. The same Run-local submission key identifies its result; no separate workflow wait call or wait key is needed to obtain that answer. This replaces the admission-returning workflow send proposal. Direct CLI admission acknowledgement and live Session wait semantics remain unchanged.

**Session-stop completion — accepted.** A stop completes when its selected work has a durable terminal outcome and atomically releases logical Session occupancy; an idle stop completes immediately. The saved request can be acknowledged earlier. Existing tool settlement and ordered Tool Result obligations remain required; model physical cleanup retains its resource owner and charged capacity independently. Completion does not require remote provider acknowledgement, promise that billing stopped, or wait for future Session activity. Workflows request required stops promptly before awaiting their completion, using the same rule regardless of submitter.

**Workflow cancellation.** Cancelling a Workflow Run first prevents further evaluation and message submissions from that Run, then stops current work in every distinct Session to which the Run has submitted a message. Each Session stop has the ordinary server semantics regardless of which client requested it. It can stop work started by another workflow, including work started after the cancelled Run's own use of that Session finished. Shared clients observe the same stopped work; their workflows are not automatically cancelled. A Session remains reusable, and explicit continuation is allowed after its stopped work settles. An unfinished Run cancellation may repeat its entire stop pass after a crash, including successful or idle stops; callers coordinate Session reuse until cancellation finishes. Only durable completion of the Run cancellation prevents further propagation on recovery.

These choices supersede the earlier last-message-bound handle, historical-state checks, candidate per-peer Principal policy, and cancellation isolation based on one Run per Turn. The complete Session interface is not yet resolved. Supported settings, replay ordering and admission mapping, the durable mapping of the selected cancellation behavior, and explicit context-patch semantics must be completed without silently restoring per-caller authority or revision guards on ordinary messages.

The glossary records Local Owner and the amended Run Cancellation Intent meaning. Owning GitHub issues now carry the accepted changes: implicit local-owner access, preserved tool permission semantics, Session-current messaging, shared work, and cancellation through stops of used Sessions. Full normative-document integration remains a handoff after the remaining interface choices; older authority, revision, and exclusive-membership text is historical where it conflicts with the published amendment. Older interface alternatives remain historical comparisons, not competing accepted policies.

## Accepted shape

```js
export default async function workflow({ createSession, configureSession, sendMessage }, args) {
  const writer = await createSession({ key: "writer" });
  const reviewer = await createSession({ key: "reviewer" });
  const draft = await sendMessage(writer, args.task, { key: "draft" });
  const review = await sendMessage(reviewer, `Review:\n${draft}`, { key: "review" });
  return await sendMessage(writer, `Revise using:\n${review}`, { key: "revise" });
}
```

Creation commits the Session, complete baseline, and creation binding without a message or model call. It returns a plain Store-relative ID; empty Sessions are valid. Another workflow can pass an existing ID directly to `sendMessage`. No `get`, `ref`, handle, or attachment operation is supplied.

Creation, configuration, and messages have distinct keys in one Run-local namespace, binding operation kind and complete inputs. Creation replay recovers the same ID; message replay recovers its original admission/result. Creating alone does not add a Session to the Run cancellation set. Dormant Sessions retain disk facts, not resident workers or Promise graphs.

The message function returns an ordinary Promise of exact text/schema output or a frozen rejection. Invocation expresses submission; awaiting expresses dependency, not a new current-work lookup. Ordinary `try/catch`, `Promise.all`, and `Promise.allSettled` handle failures. A deliberate retry is a new keyed message. Configuration is independent and persistent. Output schema is optional persistent Session configuration; no separate Turn Contract remains. Any retained Turn-wide budget stays scoped to the Turn; budget choices remain with #91.

## What wait means

For the direct CLI, a live wait observes current Session work selected once when the wait starts. Later work cannot retarget that pending wait. This remains an ordinary caller-agnostic server observation.

For a workflow submission, awaiting the returned Promise observes the work bound to that submission at admission. It does not perform a later Session-current lookup. Delaying `await`, another caller's input, or replay cannot retarget that Promise to newer work. Reawaiting the same Promise observes the same result. The submitted message may join already-active work; other inputs may contribute to the shared outcome, and already-frozen provider requests remain unchanged.

If work needs permission, workflow evaluation remains blocked and the evaluator exits; external inspection exposes the Permission Request. The Promise does not fulfill with a permission object in place of schema output. Failed/cancelled work rejects with its recorded typed failure. The [accepted pending-message rule](session-terminal-failure.md) preserves unprojected input as not applied after terminal failure/stop and requires explicit resubmission for later work.

No independent workflow wait is needed to retrieve a submitted message's result. Standalone workflow observation of work without a submission is a separate, unselected capability; it is not justified merely by the existence of the live CLI command.

## Restart trace

Using the accepted example above:

1. Draft completes and its keyed submission/result are durable.
2. Review completes. The evaluator or Host dies before revision is admitted.
3. A fresh evaluation recovers the same Session identities through their recorded creation keys, and the draft and review calls recover their original admissions and results. They perform no fresh Session-current answer selection or repeat submission.
4. Revision is new, so its message uses current Session state at admission.
5. If revision had already been admitted before the crash, its key instead recovers that admission. If completed, it returns the recorded revision answer without more model work to reconstruct local variables.

Actual in-flight provider work retains the accepted effect-specific crash recovery and retry rules, including possible replacement requests and billing. Keyed workflow replay does not promise external exactly-once execution.

## Handles and memory

A Session handle is a small temporary wrapper around Session identity. Each message Promise resolves through its keyed admission/result; the handle does not hold a caller-specific Session position. It is not a per-Session worker or durable JavaScript object. On a blocked boundary, the evaluator, handles, and Promise graph disappear; re-evaluation reconstructs temporary values from durable facts. Re-evaluation reconstructs them from recorded admissions and outcomes.

Live handles and answers within one evaluation count toward the existing evaluator limits. Dormant Sessions retain storage, not these wrappers. No conversation history is copied into the handle and no server-side registry of resident Session objects is introduced by this interface.

## Reads

The direct Session consumer retains conversation-entry reads with recent/filter/after selection and bounded content windows; type filtering precedes taking the last N matching entries. Private provider continuation remains excluded, and unapplied message content remains independently inspectable. History selection does not limit complete actionable-control inspection.

A standalone `session.read(...)` capability inside replayable workflow code is not selected by the Promise-result decision. If a concrete workflow needs it, its original observation identity and bounded replay data must be specified separately. The selected `send` result path requires no general observation journal or caller read frontier.

## Syntax simplification assessment

Positional message text removes the repeated message property and follows the CLI's established input shape. Keys and optional bounded input remain named message options. Schema and model settings belong to separate Session configuration. The native semantic request can stay the same; positional syntax belongs to the evaluator-facing adapter.

The selected workflow operation combines submission and its result in `send(): Promise<Answer>`. Ordinary Promise composition supports immediate or later awaiting and joins across independent Sessions. A separate wait method/key, new result envelope, special thenable, or retained JavaScript continuation is not needed for that result. The direct CLI deliberately acknowledges admission; consumer return timing need not be identical. Session creation and reference exposure remain open.

JavaScript/TypeScript supports both result-returning Promises and start/handle interfaces; neither is a language mandate. Google GenAI [Chat.sendMessage](https://googleapis.github.io/js-genai/release_docs/classes/chats.Chat.html#sendMessage) returns the response Promise, while Temporal [WorkflowClient](https://typescript.temporal.io/api/classes/client.WorkflowClient) exposes both execute-for-result and start-for-handle. These sources informed the completion choice; their scheduling, history retention, and ownership semantics are not adopted.

Automatic workflow keys are a different tradeoff. The probe shows a legal Promise.all workflow whose host-call order changes from A,B to A,C,B after A and B both settle. C is newly reachable on replay. A global ordinal would reuse B's identity for C. Binding validation would reject this as a mismatch, preventing a valid workflow from progressing; skipping validation risks incorrect reuse. Stable keys identify B regardless of the new ordering.

That result does not rule out every keyless design. Replaying historical visibility stages, controlling logical promise delivery, carrying branch-aware identities, or restricting the workflow language could provide alternatives. Each changes execution machinery or supported JavaScript, and needs its own proof. The smallest change to the existing engine is to keep keys. Do not use a numbering mismatch as permission to rerun completed downstream work automatically.

## Bounded model check

A [TLA+ model of Session admission, settlement, and replay](../../research/session-replay-model/README.md) checks one Session, one keyed workflow operation, one keyless external submission, and up to two crashes. The corrected rules pass the bounded safety checks; three deliberately broken variants expose duplicate admission after a lost acknowledgment, a later Session answer replacing the original answer, and successful settlement stranding a newly admitted message. Conditional progress checks also pass under the stated restart/resume and provider assumptions.

The model supports keeping identities internal and checking pending messages atomically with successful settlement. Its original observation target is tied to admission, consistent with the selected workflow message-result direction. It does not model reusable multi-message workflow interfaces, the live Session-current wait operation, or selected cross-workflow cancellation propagation. The model remains historical evidence for immutable observation and admission recovery, not a complete verification of this revised interface. Multi-message admission bindings, Session reference reconstruction, and the durable cancellation mapping still need completion.

## Remaining design choices

**Workflow operation identity.** Existing `(Run, key, binding)` lookup is proven design input. Hiding Turn IDs does not require removing these keys. Automatic call numbering would need a separate proof across fan-out, nested loops, promise continuations, failures, and branches. Physical completion order must not influence operation identity. An ergonomic signature is not evidence that this problem disappeared.

**Concurrent writers — selected.** New workflow messages target the Session's current state. Intervening input from another admitted client does not cause a stale-observation conflict. Replay recovers the original admission and answer rather than submitting again against current state. This replaces the earlier historical-revision recommendation.

**Cross-workflow Session reuse — selected.** Another Workflow Run can use the same Session ID to continue the shared conversation. Workflow keys are Run-local; the same spelling in two Runs does not identify the same submission. Session sharing includes messages admitted to the same active work, so more than one workflow may receive that work's outcome. The earlier one-Run-membership-per-Turn restriction cannot express this full contract and must be revised. Sharing does not imply isolation between workflow contributions; cancellation propagates through ordinary Session stops as selected above.

**Workflow completion — selected.** The [submission/result identity checks](../../research/workflow-result-identity/README.md) support the chosen keyed message-result Promise, without an independent wait key. This changes workflow `send` from admission completion to work completion and leaves live Session-current wait unchanged. Those evaluator checks do not implement durable Session integration.

**Active messaging and sharing — selected principle.** The server coordinates the Session irrespective of input source. Each admission uses current committed state; each fresh wait selects current work once. Two uses of the same Session ID do not maintain independent positions. Workflow bookkeeping preserves each keyed admission/result and recorded admission order where it affects meaning. Session creation and plain-ID reference exposure are selected; settings allocation remains open. Separate replayable reads/waits remain unselected capabilities, not prerequisites for the chosen send operation.

**Failure and cancellation.** The [accepted pending-message rule](session-terminal-failure.md), checked in a separate bounded model, preserves unprojected admissions as not applied with a causal failure/stop reason and excludes them from implicit continuation. Projected context remains recorded without claiming provider consumption. A [local relational mapping](../../research/session-failure-mapping/README.md) uses the existing failed Turn Outcome at a safe settlement boundary, with pre-request or same-Turn Resolution provenance; the [pending-message decision](https://github.com/DivyanshGolyan/onepage/issues/102) is published and implementation remains outstanding. Workflow cancellation now selects the shared Session behavior above; its crash-safe storage mapping remains to be checked.

## Cancellation mapping and verification obligations

The affected Session set can be derived from the cancelled Run's committed message admissions, deduplicated on disk after further Run submissions are fenced. Merely reading a Session does not add it to this set. No resident Session registry, per-client ownership, or interested-workflow count is selected.

The implementation serializes each ordinary stop with Session advancement. Run Cancellation Intent plus the existing terminal Run outcome distinguish unfinished cancellation from completed cancellation. An unfinished pass can restart from the beginning after a crash; it need not remember which Sessions were previously checked. Use bounded disk queries and disposable traversal state, without per-Session propagation receipts, idle-check records, or a durable progress cursor. Commit Run cancellation completion only after every required stop in a full pass completes under ordinary Session-stop semantics, regardless of who submitted the stopped work. There is no separate wait-only-for-this-Run's-work predicate; a crash before that commit may repeat the pass. After completion commits, recovery performs no further stops. Existing Session stop/settlement facts remain authoritative for work already stopped. Callers coordinate overlapping use and early continuation. See the [accepted trace](workflow-cancellation-stop-mapping.md#accepted-simplification).

Required checks for this amendment:

- A and B contribute to the same work; cancelling A stops it and gives B its cancelled result without cancelling B's whole Run.
- A's earlier work is complete and B has started newer work in that same Session; cancelling A stops that current work too.
- A Session is idle when stopped; if A's cancellation is still unfinished after a crash, a repeated pass may stop later work in that Session. No idle receipt is required.
- A stop succeeds but Run cancellation completion is not committed; recovery may repeat it against current work. Once Run cancellation completion commits, lost acknowledgement/recovery performs no further propagation.
- A crash occurs between stops of two Sessions, or after the last stop but before completion commit; recovery may repeat the full pass and must complete the required stops before recording Run cancellation completion.
- A message from the cancelled Run races cancellation; it either commits before the fence and contributes its Session to propagation, or is rejected afterward.

These are unverified obligations for the revised design. Existing evaluator probes and single-Session models do not establish them. Semantic stopping retains the accepted effect-specific cleanup rules and makes no guarantee that a remote provider immediately stops processing or billing.

## Other designs considered

[Stateless Session functions](session-workflow-options/b-session-functions.md) expose start, message, wait, and optional read as functions. A plain reference carries Session ID plus an admitted-message cursor. It makes historical references explicit and easy to serialize, but asks authors to pass and replace that reference at each continuation.

[Completed exchanges](session-workflow-options/c-completed-exchanges.md) combine admission and waiting into one operation returning answer plus a historical Session position. This minimizes methods and avoids mutable handles. Its costs are a result envelope, a public position concept, and no initial Session ID until the answer completes.

[Session handles](session-workflow-options/a-session-handles.md) preserve the caller's conversational model and exact answer values while separating admission and settlement. Their cost is precise private reference semantics and alias/concurrency rules. They were an earlier recommendation; the later plain-ID comparison supersedes them.

## Follow-through

The selected workflow message operation returns a recorded result through its existing submission key. Separate empty-Session creation returning a plain ID is selected; settings allocation and durable mapping still need completion. Internal Turns, message provenance, and keyed Run bindings should remain canonical wherever they suffice; no generic event ledger or snapshot subsystem is selected.

[Choose replay-stable Session continuation from agent results](https://github.com/DivyanshGolyan/onepage/issues/101) remains open. Accepted behavior has been published as an interim comment and integrated into affected issue bodies; other supported settings, exact configuration acknowledgement, and storage mappings remain explicitly pending; Turn Contract removal is selected and budget decisions retain their existing owners; workflow message completion timing is selected. The direct CLI's no-key contract remains unchanged. No production implementation, passing integrated recovery proof, issue closure, or commit/push of these local documents is implied.
