# Active-Turn User Input prior art

Date: 2026-09-03

Status: research comparison, not a normative contract. Primary sources only.

> Decision status: ADR-0022 and completed issue #93 supersede this note's candidate split between steering, next-Turn input, and generic Interaction Responses. V1 has one User Message admission primitive, no durable-backlog quota, and separate typed Permission Decision and interruption/cancellation commands. The normative docs own the settled race and projection rules.

## Question

What do current agent harnesses, model-provider APIs, and durable workflow
systems establish about active-Turn steering, queued follow-up input,
interruption, cancellation, partial output, transport reattachment, retry, and
recovery, and which lessons transfer to OnePage without introducing resident
Session machinery or provider-owned semantic authority?

This is the research answer for [Establish active-Turn User Input prior
art](https://github.com/DivyanshGolyan/onepage/issues/76).

## Verdict

Current systems support five distinct things that are often hidden behind the
word "message":

1. input that begins a new conversational turn;
2. steering that belongs to the active turn and is applied before a later model
   request;
3. a follow-up intentionally queued to begin a later turn;
4. a correlated answer to an approval or input request; and
5. interruption or cancellation, which is control intent rather than
   Conversation content.

Codex exposes the clearest public contract. `turn/steer` requires the expected
active Turn ID, adds input without starting another Turn, and returns the Turn
that accepted it. Its agent loop drains pending input before a later model
request. Codex's terminal client separately tracks same-Turn steers and
next-Turn queued messages. This is strong evidence for explicit intent and
Turn binding, but not for Codex's resident `Session` and `VecDeque` machinery.

Provider APIs do not generally rewrite an already sampled model request. A
harness either lets that request reach a terminal boundary or aborts it, then
places new input into a later request. OpenAI can persist, retrieve, cancel, and
reattach to some background Responses by provider ID; the ordinary Anthropic
Messages stream can be aborted but has no equivalent durable request object.
Those are transport capabilities, not Conversation semantics.

Temporal and Restate provide the strongest recovery lesson: acknowledge an
external message only after it is durable; let replaceable workers discover and
apply it later; keep cancellation request separate from cancellation outcome;
and persist retry timing rather than retaining a timer or waiter. OnePage can
obtain those properties more simply from normalized SQLite rows and bounded
queries. It should not import event-history replay, checkpointed workflow
stacks, resident input queues, or provider-owned Session authority.

The smallest transferable V1 shape is therefore:

- make the caller's intent explicit: **steer**, **next Turn**, **interaction
  response**, or **cancel**;
- commit every accepted input, its immutable content reference, Principal,
  idempotency identity, target Session, and expected active Turn/revision in one
  SQLite transaction before acknowledging it;
- apply Steering Input in arrival order immediately before the next Model
  Operation, with SQLite—not a resident queue—as the backlog and barrier;
- keep ordinary steering non-interrupting; only explicit cancellation may stop
  admitted physical work;
- treat partial model deltas as non-authoritative preview/scratch; only a
  terminal validated provider result may become an assistant Conversation
  entry; and
- treat provider retrieval or stream reattachment as Attempt-level transport
  recovery. It cannot become a second semantic authority.

One question remains deliberately unresolved for the decision tickets: when
Steering Input and a just-finished model Completion race, which commit order may
admit the old response's Tool Calls or Final Answer? Prior art establishes the
safe boundary and the need for exact targeting, but it does not choose
OnePage's semantic winner.

## Terms used in this comparison

The products below use `turn`, `run`, `session`, `interrupt`, and `resume`
differently. This note uses OnePage's meanings:

- **Turn**: one episode from initiating User input to Final Answer or typed
  terminal outcome;
- **Model Operation**: one provider-neutral model request within that Turn;
- **Steering Input**: unsolicited User guidance for a nonterminal Turn, to be
  applied before a later Model Operation;
- **queued follow-up**: input intentionally waiting to begin a later Turn;
- **Interaction Response**: a correlated answer to an existing Interaction
  Request; and
- **transport reattachment**: retrieving or continuing observation of one
  provider request, not resuming a Turn.

This taxonomy is descriptive for the research. The canonical names still need
the domain decision named by the Wayfinder map.

## Comparison matrix

| System | Active work input | Interruption and partial output | Retry, recovery, and state topology | Transfer to OnePage |
| --- | --- | --- | --- | --- |
| [Codex app server](https://github.com/openai/codex/blob/498d40b29f6028dec9ef80af672ba1258980b54a/codex-rs/app-server/README.md) | `turn/steer` accepts input only for an in-flight regular Turn, requires `expectedTurnId`, optionally carries `clientUserMessageId`, returns the accepting Turn ID, and emits no new `turn/started`. The [agent loop](https://github.com/openai/codex/blob/498d40b29f6028dec9ef80af672ba1258980b54a/codex-rs/core/src/session/turn.rs) drains pending input before a later model request; pending input keeps the same Turn alive. The TUI keeps [steers, rejected steers, and queued next-Turn messages separately](https://github.com/openai/codex/blob/498d40b29f6028dec9ef80af672ba1258980b54a/codex-rs/tui/src/chatwidget/input_queue.rs). | `turn/interrupt` is a separate method. Streaming deltas are observer events; completed items and Turn completion have distinct notifications. A steer does not mutate the provider request currently sampling. | Core owns a rich resident Session and input queues. A pending steer is later recorded through the ordinary user-prompt path. Thread history is persisted, but the resident queue is not an appropriate crash-authority design for OnePage. | Copy explicit steer versus queue intent, exact active-Turn targeting, client idempotency identity, and boundary delivery. Do not copy the Session graph, resident queues, or inference that API acknowledgement alone means durable acceptance. |
| [OpenAI Agents SDK](https://openai.github.io/openai-agents-python/results/) | A paused `RunState` can accept additional input; the runner places staged input immediately before the next model call. Human approvals resume the same run state rather than starting a fresh user turn. | A streamed run is incomplete until its iterator ends. `cancel()` stops immediately; `cancel(mode="after_turn")` lets the current turn finish. The caller must continue draining events while cancellation and persistence settle. | Sessions can use client-side stores such as SQLite, while `conversation_id` and `previous_response_id` select provider-side continuation instead; the SDK says not to layer both mechanisms for one run. | Copy "apply before next model call" and separate immediate versus graceful stopping concepts only where OnePage needs both. Keep OnePage's SQLite rows authoritative rather than serializing an SDK `RunState` or adopting provider Conversation ownership. |
| [OpenAI Responses API](https://developers.openai.com/api/reference/cli/resources/responses/methods/retrieve) | One Response has fixed input. New user guidance requires another Response; `previous_response_id` or a provider Conversation can supply server-managed continuity. | Responses expose terminal and nonterminal statuses including `completed`, `failed`, `cancelled`, and `incomplete`. Stream events have sequence numbers. A background Response can be [cancelled](https://developers.openai.com/api/reference/cli/resources/beta/subresources/responses) and retrieved later; streaming retrieval can use `starting_after` to continue after a known sequence number. | A stored background Response has a durable provider identity and can outlive the observing connection. Provider Conversations can append response input/output automatically. | Store provider response ID, status, and sequence cursor as Attempt/Completion evidence when used. Reattachment may continue observing the same Attempt. Never let the provider's stored Conversation replace OnePage Conversation or accept an `in_progress`/partial item as semantic output. |
| [Claude Code](https://code.claude.com/docs/en/changelog) and [Claude Agent SDK](https://code.claude.com/docs/en/agent-sdk/streaming-vs-single-mode) | Claude Code has accepted messages while working since 2025; its current changelog describes queued messages and fixes around them. Agent SDK streaming input supports multiple sequential messages, additional context during long work, and interruption. The public SDK contract does not precisely specify a durable acceptance point or the same-Turn versus next-Turn cutover. | Agent SDK exposes `interrupt()` in streaming-input mode. For the ordinary Anthropic Messages API, callers may break iteration or abort the stream; streamed `tool_use` JSON is incomplete until its block terminates. | Streaming-input mode is a live long-lived process and bidirectional transport. Resume/continue restores saved sessions, but the SDK documentation does not promise that an acknowledged, not-yet-consumed active-work message survives process loss. | Treat Claude's UI behavior as evidence that messages during long work are necessary, not as an authority model. Require OnePage's admission acknowledgement to mean committed SQLite state. Do not infer completion from visible text or copy a long-lived stdin/session process. |
| [Claude Managed Agents](https://platform.claude.com/docs/en/managed-agents/events-and-streaming) | `user.message` events are queued and expose `processed_at`; null means not yet processed. `user.interrupt` may be sent before a redirecting `user.message`. | A model response stops immediately when the interrupt is applied, while a running tool can delay application. An interrupted model request produces no final buffered message event; preview deltas end at the terminal model-request span. | Anthropic persists session events and sandboxes server-side. Sessions can be resumed by sending another message; this is a provider-hosted agent service, not merely an LLM transport. | Copy the observable distinction between accepted/queued and applied, plus intent-versus-effect cancellation. Do not make this cloud service OnePage's V1 authority or topology. Its event IDs may later be external evidence only. |
| [Google ADK](https://github.com/google/adk-python/blob/00430445f5c3554f07ed1c7f8c3da66dff1f9adb/src/google/adk/agents/live_request_queue.py) | `LiveRequestQueue` is an unbounded in-process `asyncio.Queue`; content can be marked `partial`, meaning it does not complete the current model turn. Live bidirectional input is transport-local. | Live content, activity markers, audio, and close requests share the queue. ADK's [Session service rejects partial events](https://github.com/google/adk-python/blob/00430445f5c3554f07ed1c7f8c3da66dff1f9adb/src/google/adk/sessions/base_session_service.py) before updating Session state or history. | ADK has pluggable Session services for events/state, but durable execution is a separate concern; Google's [Restate integration](https://google.github.io/adk-docs/integrations/restate/) adds durable LLM/tool calls, pause/resume, and crash recovery. | Useful negative precedent: bidirectional capability does not make an in-memory live queue recoverable. OnePage should persist accepted text/content first, then wake a bounded scheduler. Do not adopt mutable Session state or partial-turn flags as semantic authority. |
| [Temporal](https://github.com/temporalio/documentation/blob/430d1bfb6c614a6079fd73d0b6b405d78b2f7476/docs/develop/go/workflows/message-passing.mdx) | Signals are asynchronous durable messages; Updates can validate, mutate workflow state, and return an acknowledged result. Update-with-Start atomically chooses an existing execution or starts one, and its docs require idempotent handlers for client-failure retries. | Cancellation is a durable request handled by workflow/activity code. A client timeout is not proof that an Update was rejected or failed. | The service persists Event History; a replaceable worker rebuilds workflow state by replay after crash. Timers and messages do not require a resident waiter. | Copy durable-before-ack input admission, idempotent client identities, exact target/occupancy checks, and durable retry eligibility. Do not copy replay, cached workflow stacks, handlers as semantic authority, or a generic signal bus. |
| [Restate](https://docs.restate.dev/services/invocation/managing-invocations) | Durable Promises and awakeables accept external input while an invocation is suspended; named promises or IDs correlate the response. | Cancellation is non-blocking and reaches handler code at an await point; it can fail to take effect. Kill is a distinct forceful operation that may leave inconsistent effects. Detached one-way work is not undone by cancelling its parent. | [External-event waits](https://docs.restate.dev/foundations/actions) and timers consume no active handler resources and survive restarts. Invocations use durable journals and support idempotency keys, retry, attach, pause, and resume. | Copy no-resident-waiting, correlation, idempotency, and cancellation-intent/outcome separation. OnePage's relational facts can provide these without a durable continuation, generic journal, or replay engine. |

## Findings by design question

### 1. Steering and queued follow-up are different semantics

Codex makes the split concrete. An app-server steer targets an exact active
Turn and changes no Turn settings. Its terminal client separately retains
messages intended for the next Turn and sends one only after the current Turn
completes. Claude Code's changelog likewise refers to messages queued while
Claude is working, while Agent SDK documentation describes sending additional
context and changing direction during work.

OnePage should not guess intent from message wording. A protocol command should
state whether the input:

- belongs to the current Turn;
- waits to initiate the next Turn;
- answers a named Interaction Request; or
- requests cancellation.

If V1 chooses to expose only steering plus cancellation, an attempted
next-Turn queue should be explicitly unsupported rather than silently treated
as steering. This preserves a future-compatible distinction without requiring
all four surfaces immediately.

### 2. The safe delivery point is before a model request, not inside one

Codex drains pending input before constructing a later model request. OpenAI
Agents stages extra input immediately before the next model call. Anthropic's
ordinary Messages API accepts one fixed message list per request; aborting its
stream stops observation/generation rather than injecting new prompt tokens.

For OnePage, the earliest general boundary is therefore **immediately before
the next Model Operation**:

- steering that arrives while a model request is sampling waits for settlement
  or explicit cancellation;
- steering that arrives after Tool Calls were admitted cannot retract those
  effects, so it waits for their ordered Tool Results and precedes the next
  Model Operation; and
- no SQLite transaction or resident waiter remains open while it waits.

The race at model settlement needs a separate policy decision. Two reasonable
outcomes remain:

1. always admit a complete model result, then append steering and continue the
   same Turn; or
2. if steering committed first, preserve the Completion as evidence but do not
   admit stale Tool Calls/Final Answer, then resolve or supersede the model
   Operation according to an explicit rule.

Codex demonstrates the first family of behavior; safety-sensitive steering
such as "do not delete" motivates the second. Research cannot select the winner
without OnePage's product policy.

### 3. Accepted, applied, and observed are different facts

Codex returns the active Turn ID that accepted a steer. Claude Managed Agents
go further: the submitted event exists before `processed_at` is populated.
Temporal distinguishes an asynchronous Signal accepted by the service from an
Update whose handler result the caller awaits.

OnePage needs the same externally visible distinction without a lifecycle
enum:

- **accepted**: the admission transaction committed the input and target;
- **applied**: a later Model Request Manifest includes that input's Conversation
  entry or projection; and
- **settled/rejected**: canonical facts prove it cannot be applied, for example
  because its expected Turn lost the admission race.

These conditions should be derived from input, Conversation, Manifest, Turn,
and outcome relationships. They do not require a persisted `pending/applied`
phase column.

### 4. Interruption is not steering

Codex exposes `turn/interrupt` separately from `turn/steer`. OpenAI Agents has
immediate and after-current-turn cancellation. Claude Managed Agents queues an
interrupt event, marks it processed only when applied, and may take longer to
apply while a tool is running. Restate explicitly distinguishes cooperative
cancel from forceful kill and warns that cancellation cannot undo detached or
already-performed effects.

The transferable rule is:

- ordinary Steering Input never implies cancellation;
- Cancellation Intent is a separate durable command;
- signalling a socket, provider request, or subprocess is only volatile
  physical action;
- the current model's incomplete bytes never become an assistant Conversation
  entry; and
- a Turn becomes cancelled only after admitted work is reconciled and durable
  facts establish the terminal outcome.

This matches OnePage's existing distinction between Cancellation Intent and
effect evidence. New User Input should not blur it.

### 5. Partial output is preview or scratch, not Conversation

OpenAI and Anthropic streaming protocols emit deltas before terminal response
events. Anthropic explicitly permits partial JSON deltas for a Tool Call and
only establishes the completed block later. Claude Managed Agents says a model
request ending through error or interruption produces no final buffered message
event. OpenAI Responses exposes `in_progress`, `cancelled`, and `incomplete`
status separately from `completed`.

OnePage has no V1 streaming UI. It can therefore use the simpler rule:

- stream provider bytes to bounded disk scratch;
- keep only transport/parser windows in memory;
- validate once the effect-specific terminal boundary is observed;
- commit complete immutable content with Completion and Resolution; and
- discard unsealed scratch after interruption or crash.

No steer requires preserving or constructing a "semantically correct partial
assistant message." A later request starts from committed Conversation only.

### 6. Transport reattachment is narrower than Turn resume

OpenAI background Responses provide the unusual strong case: the provider
stores a Response, exposes a durable ID and status, and can stream retrieval
from a later sequence number. Reconnecting can continue observation of that
same provider operation. Anthropic's ordinary Messages stream exposes abort,
but no corresponding retrieve-and-continue endpoint. Provider-hosted agent
Sessions offer broader recovery by owning the entire agent execution, which is
outside OnePage's V1 trust boundary.

OnePage should classify recovery as follows:

- same durable provider response identity, retrievable after disconnect: the
  same Attempt may reattach and gather terminal evidence;
- no retrievable provider identity or a definitively ended request: a retry is
  a new Attempt bound to the same immutable Model Request Manifest; and
- provider session/conversation state: optional evidence or optimization, never
  a substitute for OnePage Conversation, Resolution, or Turn Outcome.

### 7. Retry and recovery require no resident input object

Temporal Signals/Updates, Restate Durable Promises, and provider-managed event
queues all demonstrate that an accepted message can outlive the process that
will consume it. Their heavier replay/journal machinery is unnecessary for
OnePage because SQLite already owns canonical normalized facts.

After restart, one bounded query can find:

- Steering Inputs targeting a nonterminal Turn that are not represented in a
  later Model Request Manifest;
- queued next-Turn inputs whose Session has become idle, if that surface is
  admitted in V1;
- cancellation intent whose physical work still needs reconciliation; and
- interaction responses whose correlated request remains open.

The Host may keep a borrowed row, content reference, and current validation
window while processing one admission. It needs no per-input task, timer,
promise, queue node, Session graph, or retained message bytes.

### 8. Exact targeting and idempotency are mandatory

Codex requires `expectedTurnId` for `turn/steer` and accepts a caller message ID.
Temporal's Update-with-Start documentation calls out client-failure retries and
idempotent handlers. Restate exposes idempotency keys and returns the same
retained result rather than executing a duplicate invocation.

A OnePage active-input command should bind at least:

- Principal and authority;
- Session ID;
- expected active Turn ID and expected Conversation revision for steering;
- explicit input intent;
- caller idempotency key;
- exact immutable content reference and digest; and
- bounded admission size/count policy.

Equal replay should return the original admission. Reusing the key with changed
bindings should conflict. A stale expected Turn should never silently steer a
new Turn that happened to become active.

## Recommended decisions for the Wayfinder map

The following are supported strongly enough by prior art to become defaults in
the later domain decision:

1. **Introduce an explicit active-Turn input concept.** Keep it distinct from
   initiating User input, Interaction Response, and Cancellation Intent.
2. **Define steering as same-Turn input applied before a later Model
   Operation.** Do not promise token-level mutation of a request already in
   flight.
3. **Make admission durable before acknowledgement.** SQLite owns pending
   inputs and their arrival order; a Host wake is advisory and replaceable.
4. **Require exact expected-Turn and idempotency bindings.** Never route a stale
   message to whatever Turn is active at processing time.
5. **Keep cancellation explicit and cooperative.** Reconcile admitted effects
   before terminal Turn cancellation; do not turn ordinary guidance into an
   interrupt.
6. **Exclude partial assistant messages from Conversation.** Deltas remain
   scratch/preview until terminal validation.
7. **Keep provider recovery behind Attempt.** Retrieval and reattachment may
   improve cost and duplicate-work behavior, but SQLite remains semantic
   authority.
8. **Expose accepted versus applied in observer snapshots.** Derive both from
   canonical relations rather than persisting a second lifecycle state.

The map must still decide:

- the race winner when Steering Input commits near model settlement;
- whether a complete but superseded model response is retained only as
  Completion evidence or also enters Conversation;
- whether V1 exposes explicit next-Turn queuing or only steering;
- how multiple Steering Inputs are grouped into one Conversation projection and
  Model Request Manifest;
- the admission count and byte bounds; and
- what happens to unapplied input when the targeted Turn settles before it can
  be used.

## Simplicity opportunities

1. **One durable relation, no input state machine.** Represent identity,
   target, intent, content, and arrival order once. Derive acceptance,
   applicability, application, and rejection from its relations to Turn,
   Conversation, Manifest, and outcome facts.
2. **One delivery boundary.** All ordinary steering is considered immediately
   before a Model Operation. Do not add token hooks, per-tool callbacks, or a
   priority scheduler.
3. **No resident queue.** Commit then issue a coalescing Host wake. Every wake
   triggers a bounded canonical query; missed or duplicated wakes change only
   latency.
4. **No automatic language classifier.** The caller states steer, queue,
   respond, or cancel. The model does not decide which control path the User
   intended.
5. **No provider-generalized resume.** Each adapter reports whether an exact
   provider request is retrievable. The common model remains Attempt,
   Completion, and Resolution.
6. **No partial-message repair.** An interrupted model response contributes no
   assistant Conversation entry. A later Model Operation receives committed
   context and complete User input.
7. **No generic signal bus.** The closed input commands cover User guidance,
   correlated responses, and cancellation. Workflow signals and arbitrary
   application events remain out of scope.

## Verification implications

Whichever semantics the map selects, production tests should include:

- two identical steer admissions and one changed-binding replay;
- stale expected Turn, stale Conversation revision, unauthorized Principal,
  oversize content, and exhausted pending-input capacity;
- crash before and after input admission commit, before Host wake, while the
  current model request is streaming, and immediately before the next Model
  Request Manifest commits;
- steering racing with a Final Answer, a response containing Tool Calls, Tool
  Call admission, the final sibling Tool Result batch, cancellation intent, and
  terminal Turn Outcome;
- multiple Steering Inputs with permuted physical arrival but fixed committed
  ordinals;
- explicit next-Turn input, if supported, surviving process death and Session
  occupancy release without a resident waiter;
- cancellation during model sampling and during a long Bash Action, proving
  partial bytes never become Conversation and admitted effects are reconciled;
- OpenAI background-response reattachment versus a provider without durable
  response retrieval, proving both yield the same OnePage semantic result; and
- Active Capacity 100 with pending User Inputs, proving resident memory is
  bounded by active transport/validation windows rather than input population.

## Sources

Primary sources consulted on 2026-09-03:

- [Codex app-server protocol](https://github.com/openai/codex/blob/498d40b29f6028dec9ef80af672ba1258980b54a/codex-rs/app-server/README.md)
- [Codex Turn loop](https://github.com/openai/codex/blob/498d40b29f6028dec9ef80af672ba1258980b54a/codex-rs/core/src/session/turn.rs)
- [Codex TUI input queue](https://github.com/openai/codex/blob/498d40b29f6028dec9ef80af672ba1258980b54a/codex-rs/tui/src/chatwidget/input_queue.rs)
- [OpenAI Agents SDK results and resumable state](https://openai.github.io/openai-agents-python/results/)
- [OpenAI Agents SDK streaming and cancellation](https://openai.github.io/openai-agents-python/streaming/)
- [OpenAI Agents SDK Sessions](https://openai.github.io/openai-agents-python/sessions/)
- [OpenAI Responses retrieval](https://developers.openai.com/api/reference/cli/resources/responses/methods/retrieve)
- [OpenAI Responses cancellation](https://developers.openai.com/api/reference/cli/resources/beta/subresources/responses)
- [Claude Code changelog](https://code.claude.com/docs/en/changelog)
- [Claude Agent SDK streaming input](https://code.claude.com/docs/en/agent-sdk/streaming-vs-single-mode)
- [Claude Agent SDK user input](https://code.claude.com/docs/en/agent-sdk/user-input)
- [Anthropic Messages streaming](https://platform.claude.com/docs/en/build-with-claude/streaming)
- [Claude Managed Agents event stream](https://platform.claude.com/docs/en/managed-agents/events-and-streaming)
- [Google ADK `LiveRequestQueue`](https://github.com/google/adk-python/blob/00430445f5c3554f07ed1c7f8c3da66dff1f9adb/src/google/adk/agents/live_request_queue.py)
- [Google ADK Session event admission](https://github.com/google/adk-python/blob/00430445f5c3554f07ed1c7f8c3da66dff1f9adb/src/google/adk/sessions/base_session_service.py)
- [Google ADK Restate integration](https://google.github.io/adk-docs/integrations/restate/)
- [Temporal message passing](https://github.com/temporalio/documentation/blob/430d1bfb6c614a6079fd73d0b6b405d78b2f7476/docs/develop/go/workflows/message-passing.mdx)
- [Temporal Event History](https://github.com/temporalio/documentation/blob/430d1bfb6c614a6079fd73d0b6b405d78b2f7476/docs/encyclopedia/event-history/event-history.mdx)
- [Restate invocation cancellation and recovery](https://docs.restate.dev/services/invocation/managing-invocations)
- [Restate durable external events](https://docs.restate.dev/foundations/actions)
