# Agent harness domain-model prior art

Research date: 2026-09-01

## Question

What durable concepts do mature or actively developed coding-agent harnesses use for:

- a continuing conversation;
- one caller input and the work it causes;
- one model response and its tool calls;
- retries and external effects;
- multi-turn objectives; and
- background work?

The immediate OnePage question is which domain owns each invariant. Whether `Job`, `Turn`, `Run`, or another name appears in the public vocabulary is secondary.

## Sources and pins

This review used detached local clones and primary source only.

| Project | Pinned revision | Maturity considered |
| --- | --- | --- |
| [Codex CLI](https://github.com/openai/codex/tree/82099786163f3c05facf09078136679e18b64279) | `82099786163f3c05facf09078136679e18b64279` (2026-09-01) | implemented Core and app-server protocol |
| [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness/tree/b150a551b8d465e31e418e1b2eaf5e79bbb7d28e) | `b150a551b8d465e31e418e1b2eaf5e79bbb7d28e` (`dsh-0.1.1-rc.2`, 2026-08-21) | implemented harness |
| [Pi](https://github.com/badlogic/pi-mono/tree/853a80d26c90a14c1886f0ebb8ffaae133ca2185) | `853a80d26c90a14c1886f0ebb8ffaae133ca2185` (2026-08-28) | implemented resident Agent plus specified, partly stubbed durable harness |
| [OpenCode v2](https://github.com/anomalyco/opencode/tree/8ba434b5973856b2f32b8cd3543e154b25c413e6) | `8ba434b5973856b2f32b8cd3543e154b25c413e6` (2026-08-29) | implemented v2 Core and protocol |

Pi's durable `AgentHarness` is important design prior art, but it is not fully implemented at this pin: restoration and the principal drive methods still return `HarnessNotImplemented`. Conclusions below distinguish its working `Agent` loop from its target durable design.

## Executive conclusion

There is strong convergence on the responsibilities and weaker convergence on their names.

```text
continuing conversation
  caller input-to-yield interval
    model-response/tool cycle
      physical provider or effect attempt
```

The four projects spell that hierarchy differently:

| Project | Conversation | Input-to-yield interval | Model response plus tools | Physical try |
| --- | --- | --- | --- | --- |
| Codex | Thread | Turn | Step | request/retry |
| DeepSeek | Session | Turn | Step | request attempt |
| Pi | Session/Lane | Run | Turn / generation step | Attempt |
| OpenCode | Session | not first-class; execution busy period | Step | internal attempt |

No reviewed harness uses `Job` as the ordinary conversational unit or as the conventional name for a collection of Turns:

- DeepSeek and OpenCode use Job for backgroundable Bash, shell, or subagent work.
- Codex uses Task for the process-local executor that drives a Turn.
- Pi has no Job/Task domain entity; its caller-bounded aggregate is Run, represented durably as `Operation(kind = run)`.

The simplest OnePage model is therefore:

```text
Run                 workflow execution and orchestration only
  Session           reusable conversation
    Turn            one admitted caller input processed until the agent yields
      Operation      one model request or proposed external effect
        Attempt      one physical execution try
        Completion   what physically happened
        Resolution   what OnePage may safely do next
```

`Job` should not be part of the core harness vocabulary. If workflow evaluation needs an internal record to correlate a pending `agent()` promise, that record should point directly to the Turn it started. A future multi-Turn objective should be introduced only when it has independent behavior; `Goal` is the clearest prior-art name.

The surveyed `Step` responsibility remains useful but does not require another OnePage entity. One model Operation already owns the exact request manifest, response, retries, usage, and causal Tool Calls. Its child Action Operations and their ordinals derive the model/tool cycle. A Step may be a diagnostic projection over those relations; persisting it would duplicate identity and settlement.

## Responsibility boundaries

The strongest lesson is not the hierarchy above. It is that the same few responsibilities recur, and the cleaner harnesses avoid letting one resident object own all of them.

### 1. Durable conversation authority

Owns:

- conversation identity and lineage;
- the complete provider-neutral message/content history;
- durable user, assistant, and tool-result facts;
- stable defaults whose lifetime is the whole conversation; and
- compaction references or projections without deleting history.

Does not own:

- a live model client, worker, parser, tool process, or evaluator;
- whether a driver happens to be resident;
- workflow scheduling; or
- physical retry state that has not been durably admitted.

Every reviewed system has this responsibility, although Pi's implemented `Agent` still combines it with a resident driver. DeepSeek's Session/Surface split is the clearest: the log is authority and model context is a projection. OpenCode similarly stores Messages while deriving active history after compaction. Codex stores Thread Items and separately reconstructs turn/model context.

For OnePage, SQLite should be the sole authority for this domain. A loaded Conversation, Core, Harness, or Session object is a bounded working view, never a second source of truth.

### 2. Input admission and routing

Owns:

- idempotently accepting caller input;
- deciding whether it starts new work, steers active work, or waits for later work;
- binding the input to the exact conversation and caller-visible request identity;
- permission/input-response freshness and authority checks; and
- making acceptance durable before acknowledgement.

Does not own:

- provider dispatch;
- the final answer;
- tool execution; or
- an in-memory queue whose loss changes meaning.

All four systems have this responsibility even when they do not give it a separate public object: Codex has start/steer submission, DeepSeek has durable Inbox splice/claim semantics, Pi has steer/follow-up/next-run queues, and OpenCode has a durable Session Inbox. OpenCode demonstrates the cost of stopping at admission: because no causal outer execution record exists, it cannot directly answer which output settled one admitted prompt.

OnePage should keep admission as a narrow transactional command over SQLite. It does not require a separately resident Inbox service.

### 3. Input-to-yield coordination

Owns:

- the causal interval from admitted input until the agent yields;
- the effective caller contract and whole-interval budgets;
- sequencing repeated model/tool cycles;
- cancellation of this interval; and
- its typed outcome.

Does not own:

- the complete Session lifetime;
- workflow-wide orchestration;
- provider wire details;
- the actual authority to perform an external effect; or
- resident state after the interval blocks or ends.

Codex and DeepSeek make this a Turn. Pi makes it a Run. OpenCode leaves it implicit in a busy execution period, which permits efficient coalescing but weakens input-to-output causality. This is the responsibility OnePage most needs to model explicitly; its name is less important than its invariant.

The coordinator should be disposable. It reads committed state, performs one bounded quantum, commits the next facts, and releases memory before any durable wait.

### 4. Model-response/tool-cycle execution

Owns:

- one exact model-visible context;
- one provider request and response;
- actual model/tool catalog/limit identities used;
- tool proposals caused by that response;
- usage and provider finish/failure facts; and
- whether settled tool results require another model cycle.

Does not own:

- conversation defaults;
- a multi-cycle caller outcome;
- provider-independent permission authority; or
- the implementation thread/socket after settlement.

Codex, DeepSeek, and OpenCode call this Step; Pi calls it Turn/generation. OnePage already has a narrower durable model Operation with Attempt and Resolution identity. Binding the exact Model Request Manifest to that Operation preserves the responsibility without another canonical object or resident state machine.

### 5. Provider transport and conversion

Owns:

- authentication and refresh for one provider;
- provider request encoding;
- transport, streaming grammar, and provider-specific terminal semantics;
- bounded conversion into the provider-neutral response format; and
- provider compatibility failures.

Does not own:

- Session mutation;
- tool permission or execution;
- conversation history policy;
- retry after semantic admission; or
- durable meaning.

The surveyed harnesses all translate at the provider edge. OnePage's existing immutable request cursor, append-only candidate writer, typed dispatch outcome, and Host-only settlement seam are a strong version of this boundary. The provider's bytes remain provisional evidence until Host admission.

### 6. External-effect recovery

Owns:

- the exact proposed effect descriptor;
- validation and permission binding;
- physical Attempt admission;
- Completion evidence;
- effect-specific replay/uncertainty policy; and
- Resolution into the next safe action.

Does not own:

- the model's conversational intent beyond the exact proposal;
- the whole Step or Turn outcome;
- workflow scheduling; or
- a generic assumption that every failure is retryable.

Other harnesses often embed this responsibility inside tool execution or a background Job registry. OnePage needs it as an explicit domain because crash-consistent effect-specific recovery is one of the product's distinguishing claims. It should remain below the model-cycle coordinator and should publish a tool result into Conversation only after resolution.

### 7. Workflow orchestration

Owns:

- evaluating the caller's JavaScript workflow;
- dependencies and concurrency among agent calls;
- mapping completed/blocked calls back to workflow values;
- workflow-level cancellation and final output; and
- reconstructing evaluation from immutable workflow state.

Does not own:

- Session history;
- model/tool policy hidden from the individual call;
- provider or tool execution;
- permission authority; or
- a resident QuickJS heap while blocked.

None of the surveyed single-agent cores makes workflow orchestration part of its conversation domain. OnePage should keep Run/QuickJS above the harness and let an `agent()` call admit and await the input-to-yield unit directly. If several such calls form a larger objective, the workflow already expresses that composition; another durable conversational aggregate is duplication unless it owns independent behavior.

### 8. Resource admission and physical execution

Owns:

- Active Credits, Activation Slots, provider cells, workers, sockets, and process handles;
- population bounds and backpressure;
- cancellation delivery and shutdown; and
- measured memory/descriptor/time budgets.

Does not own:

- business or conversation state;
- whether a Session is semantically active;
- durable outcomes; or
- retry policy.

Codex's internal Task and DeepSeek/OpenCode background Job registries are examples of physical execution/control abstractions rather than conversation aggregates. OnePage should keep these handles process-local and derivable from durable admitted work.

### 9. Observation and projection

Owns:

- bounded Session/Run snapshots;
- transcript and model-context views;
- telemetry and progress summaries;
- immutable content references; and
- deterministic JSON/Markdown rendering.

Does not own:

- authority-bearing responses;
- lifecycle transitions;
- hidden mutable state; or
- independent facts not present in committed storage.

DeepSeek's Surface and OpenCode's projected Messages show why projection is a responsibility, not authority. OnePage snapshots should be rebuildable reads over SQLite.

## Recommended dependency direction

The domains should depend inward on committed facts, not sideways on live objects:

```text
Workflow orchestration
        |
        v
input admission -> input-to-yield coordinator -> model-cycle coordinator
                                                |              |
                                                v              v
                                      provider transport   effect recovery
                                                \              /
                                                 v            v
                                            SQLite authority
                                                   |
                                                   v
                                         observation/projection

resource admission surrounds execution but owns no semantic facts
```

This is a responsibility map, not a requirement for nine services or object types. Responsibilities that share one transaction may live in the same deep Zig module. The rule is that one responsibility must not acquire another's authority merely because the implementation calls it synchronously.

## Comparative domain map

### Codex CLI: Thread -> Turn -> Item, with Step-scoped execution

Codex's public app-server model is explicit:

- `Thread` is the continuing conversation. It owns identity, lineage, provider, workspace, status, and optionally loaded Turns ([Thread](https://github.com/openai/codex/blob/82099786163f3c05facf09078136679e18b64279/codex-rs/app-server-protocol/src/protocol/v2/thread_data.rs#L199-L273)).
- `Turn` owns identity, ordered Items, status, errors, and timing ([Turn](https://github.com/openai/codex/blob/82099786163f3c05facf09078136679e18b64279/codex-rs/app-server-protocol/src/protocol/v2/thread_data.rs#L352-L387)).
- `TurnStatus` is `completed | interrupted | failed | inProgress` ([status](https://github.com/openai/codex/blob/82099786163f3c05facf09078136679e18b64279/codex-rs/app-server-protocol/src/protocol/v2/turn.rs#L29-L37)).
- `ThreadItem` contains user messages, agent messages, reasoning, command executions, file changes, MCP calls, and other observable facts ([item union](https://github.com/openai/codex/blob/82099786163f3c05facf09078136679e18b64279/codex-rs/app-server-protocol/src/protocol/v2/item.rs#L229-L335)).

`turn/start` accepts the user input and turn-effective overrides such as model, approval policy, sandbox, reasoning effort, output schema, environment, and collaboration mode ([TurnStartParams](https://github.com/openai/codex/blob/82099786163f3c05facf09078136679e18b64279/codex-rs/app-server-protocol/src/protocol/v2/turn.rs#L147-L258)). Input can start a new Turn or steer the exact active Turn; acceptance does not imply that persistence or sampling has finished ([TurnInputMode and submission](https://github.com/openai/codex/blob/82099786163f3c05facf09078136679e18b64279/codex-rs/protocol/src/turn_input.rs#L131-L193)).

One Codex Turn contains the model/tool continuation loop. A function call is executed and returned in the next sampling request; an assistant-only response completes the Turn ([loop contract](https://github.com/openai/codex/blob/82099786163f3c05facf09078136679e18b64279/codex-rs/core/src/session/turn.rs#L141-L160)). User input received while the model runs may be drained into a later Step of the same active Turn ([steering](https://github.com/openai/codex/blob/82099786163f3c05facf09078136679e18b64279/codex-rs/core/src/session/turn.rs#L295-L320)).

Codex distinguishes the Turn contract from a sampling Step. `TurnContext` contains turn-wide configuration and initial settings, while `StepContext` captures the exact immutable settings, tool router, MCP binding, environment, token budget, and instructions used for one sampling request ([TurnContext](https://github.com/openai/codex/blob/82099786163f3c05facf09078136679e18b64279/codex-rs/core/src/session/turn_context.rs#L185-L246), [StepContext](https://github.com/openai/codex/blob/82099786163f3c05facf09078136679e18b64279/codex-rs/core/src/session/step_context.rs#L14-L33)). This allows later Steps in one Turn to use updated settings without rewriting earlier execution facts.

Codex's internal `SessionTask` is not a user-domain Job. It is the Tokio executor for regular turns, reviews, and compaction ([task contract](https://github.com/openai/codex/blob/82099786163f3c05facf09078136679e18b64279/codex-rs/core/src/tasks/mod.rs#L171-L203)). The active Turn holds that running task, cancellation token, and mutable pending approvals/input as process-local execution state ([ActiveTurn](https://github.com/openai/codex/blob/82099786163f3c05facf09078136679e18b64279/codex-rs/core/src/state/turn.rs#L32-L106)).

Codex therefore supports `Session/Thread -> Turn -> Step`, and gives no support to an additional conversational Job aggregate.

### DeepSeek Harness: Session -> Turn -> Step; Goal spans Turns

DeepSeek defines the hierarchy directly in its glossary: a Turn is one drain of admitted input, ending when the model and tools stop or policy intervenes; a Step is one model request plus the tool executions caused by that response ([glossary](https://github.com/deepseek-ai/deepseek-harness/blob/b150a551b8d465e31e418e1b2eaf5e79bbb7d28e/docs/glossary.md#L35-L39)).

The `Session` is the append-only source of truth. Model history is a separate surface projection over selected Session events ([Session contract](https://github.com/deepseek-ai/deepseek-harness/blob/b150a551b8d465e31e418e1b2eaf5e79bbb7d28e/packages/core/session/README.md#L1-L7)). Turns and Steps are durable brackets in that log rather than independently mutable objects:

- `turn/start` and `turn/end` carry a Session-local Turn number and typed Turn outcome ([events](https://github.com/deepseek-ai/deepseek-harness/blob/b150a551b8d465e31e418e1b2eaf5e79bbb7d28e/packages/core/session/src/types.ts#L230-L256)).
- `step/start` and `step/end` bracket user input, provider output, assistant message, and tool calls/results ([events](https://github.com/deepseek-ai/deepseek-harness/blob/b150a551b8d465e31e418e1b2eaf5e79bbb7d28e/packages/core/session/src/types.ts#L253-L301)).
- Replay checks sequential Turn/Step numbering, correct nesting, and same-Step tool-call/result pairing ([invariant](https://github.com/deepseek-ai/deepseek-harness/blob/b150a551b8d465e31e418e1b2eaf5e79bbb7d28e/packages/core/session/src/invariant.ts#L69-L143)).

DeepSeek has a real multi-Turn concept, but calls it `Goal`: a durable objective with revision, `active | paused | blocked | complete` phase, blocked reason, and a bounded number of goal rounds ([Goal](https://github.com/deepseek-ai/deepseek-harness/blob/b150a551b8d465e31e418e1b2eaf5e79bbb7d28e/packages/goal/goal/src/types.ts#L15-L83)). Goal is explicitly state attached to a Session, not a scheduler or separate conversation ([glossary](https://github.com/deepseek-ai/deepseek-harness/blob/b150a551b8d465e31e418e1b2eaf5e79bbb7d28e/docs/glossary.md#L23-L27)). Each continuation round becomes an ordinary Turn.

DeepSeek's `Job` means background execution. It tracks kinds such as Bash or subagent work with status, output, cancellation, and an owning Session; its default registry is process-local ([Job types](https://github.com/deepseek-ai/deepseek-harness/blob/b150a551b8d465e31e418e1b2eaf5e79bbb7d28e/packages/jobs/jobs/src/types.ts#L13-L45), [local registry](https://github.com/deepseek-ai/deepseek-harness/blob/b150a551b8d465e31e418e1b2eaf5e79bbb7d28e/packages/jobs/jobs-local/src/index.ts#L1-L40)). It is orthogonal to conversational grouping.

Exact provider/model/instructions/tools are resolved and logged per Step request, seeded by Agent-scoped defaults. The Goal and background Job do not own that execution contract ([request construction](https://github.com/deepseek-ai/deepseek-harness/blob/b150a551b8d465e31e418e1b2eaf5e79bbb7d28e/packages/core/agent-loop/src/agent.ts#L422-L513)).

### Pi: Session -> Run -> Turn; durable Run is an Operation

Pi uses the same underlying layers with different names. Its implemented SDK has a resident `Agent`; one `prompt()` or `continue()` invocation is a Run; and that Run may contain several Turns. Pi explicitly defines one Turn as one assistant response plus its tool calls/results ([event type](https://github.com/badlogic/pi-mono/blob/853a80d26c90a14c1886f0ebb8ffaae133ca2185/packages/agent/src/types.ts#L422-L444)). If tools require another model response, the loop emits another `turn_start` and `turn_end` within the same Run ([loop](https://github.com/badlogic/pi-mono/blob/853a80d26c90a14c1886f0ebb8ffaae133ca2185/packages/agent/src/agent-loop.ts#L211-L273)).

Pi's target durable harness makes the caller interval explicit:

```text
Session
  Lane
    Operation(kind = run | compaction | navigation)
      generation step
        Attempt
        ToolBatch
```

The public `runId` is the durable `operationId` retained under a friendlier compatibility name ([run identity](https://github.com/badlogic/pi-mono/blob/853a80d26c90a14c1886f0ebb8ffaae133ca2185/packages/agent/docs/harness.md#L2090-L2116)). A Run snapshots queue, compaction, and tool-execution policy; each generation snapshots effective Lane configuration, stream options, and retry policy; each Attempt persists output/context limits before dispatch ([generation contract](https://github.com/badlogic/pi-mono/blob/853a80d26c90a14c1886f0ebb8ffaae133ca2185/packages/agent/docs/harness.md#L1038-L1065)).

Steering can enter between Turns. Follow-up is consumed only when the Run would otherwise end, and can extend that same Run with another Turn. `nextRun` targets a later Run. A new user message is therefore not necessarily a new Run ([checkpoint](https://github.com/badlogic/pi-mono/blob/853a80d26c90a14c1886f0ebb8ffaae133ca2185/packages/agent/docs/harness.md#L1448-L1464)).

Pi has no Job or Task domain entity. It shows that a caller-owned interval above model cycles can be useful, but calls it Run. Its broader internal name, Operation, exists because compaction and navigation share admission, recovery, and outcome machinery.

### OpenCode v2: Session -> Inbox/Message; Step is explicit, Turn is not

OpenCode has the least normalized conversational grouping:

```text
Project / Location
  Session
    Inbox item
    Message
    execution busy-period events
      Step events correlated by assistantMessageID
```

`Session.Info` is long-lived and owns lineage, Project, selected agent/model, usage, timestamps, and only the latest execution outcome ([Session](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/schema/src/session.ts#L31-L58)). A prompt call returns a durably admitted Inbox item, not a Turn or assistant result ([prompt endpoint](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/protocol/src/groups/session.ts#L338-L357)).

One execution is a process-local busy period that may coalesce wakes, promote several steering inputs, run continuation Steps, and consume a queued next input before becoming idle ([coordinator](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/core/src/session/run-coordinator.ts#L27-L42), [runner](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/core/src/session/runner/llm.ts#L47-L160)). Execution events have no independent ID and only the latest terminal result is projected onto Session ([events](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/schema/src/session-event.ts#L219-L239)).

Step is more concrete. A Step is correlated by assistant-message ID and records the exact agent/model, provider state, usage, cost, tool calls, finish, errors, and workspace changes ([Step events](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/schema/src/session-event.ts#L308-L365)). Retries are internal physical attempts within that logical Step unless partial durable output forces a continuation message.

OpenCode does have `Job.Service`, but it is a process-local background-work registry for shell and subagent tool calls ([Job service](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/core/src/job.ts#L93-L185)). It is absent from the conversational API.

OpenCode demonstrates that a harness can operate without a first-class Turn. The cost is equally clear: there is no direct durable answer to “what was the outcome of this admitted prompt?” because prompts, busy periods, and Steps are intentionally decoupled. OnePage needs not copy that ambiguity merely because it is workable.

## What actually converges

### 1. Session or Thread is the reusable conversation

The continuing transcript, lineage, and workspace/provider defaults live at this level. It is not normally terminal after one assistant answer. Closing, archiving, deletion, or retention are separate lifecycle actions.

### 2. One model response and its tools form a real boundary

DeepSeek, Codex, and OpenCode call it Step. Pi calls it Turn. This boundary owns the exact provider request, assistant response, tool proposals/results, usage, and retry facts.

### 3. Exact execution facts are narrower-lived than conversation defaults

All four distinguish stable conversation/agent defaults from what was actually used for one provider request. Codex and DeepSeek snapshot Step settings explicitly; Pi snapshots generation/attempt state; OpenCode records actual agent/model on the Step/assistant message.

### 4. Job commonly means background work

Where the term exists, it identifies cancellable shell, Bash, or subagent execution. Reusing it for the main conversation aggregate would overload the most consistent meaning found in the sample.

### 5. A multi-Turn objective is optional

Only DeepSeek gives it a clear independent domain model, `Goal`. Pi's Run can be extended by follow-up and therefore span several model cycles, but is primarily the accepted caller invocation. Codex and OpenCode do not require a multi-Turn objective aggregate for ordinary chat.

### 6. Transcript and model context are different views

All four keep provider-neutral conversation data and derive provider input at the edge. Compaction changes the model-visible context without erasing the complete human/audit history.

## Where the projects disagree

### Turn versus Step

There are two established vocabularies:

```text
Codex / DeepSeek
Turn = one admitted input processed until the agent yields
Step = one model response plus its tools

Pi
Run  = one caller invocation until the agent yields
Turn = one model response plus its tools
```

OpenCode largely avoids naming the outer unit and calls the inner unit Step.

For OnePage, `Turn` should mean the outer input-to-yield interval because:

- it matches Codex, the first V1 provider and primary user reference;
- it matches ordinary chat language: a user takes a turn, then the agent takes a turn;
- it makes `send user input -> await Turn outcome` direct;
- it avoids adding Pi's Run inside OnePage's already established Workflow Run.

OnePage need not adopt every prior-art noun. Its model Operation already owns the exact request,
Attempts, Completion evidence, Resolution, and causal Tool Calls. That is sufficient to reconstruct
the repeated model/tool cycle that other projects call a Step.

### Mutable versus frozen settings inside a Turn

The reviewed harnesses can re-resolve some settings between model requests. That flexibility is not free. OnePage should distinguish:

- **Session Context Revision:** sparse persistent defaults whose unchanged components continue by reference;
- **Turn Contract:** resolved caller policy, context revision, runtime facts, authority, output contract, and Turn-wide budgets frozen at admission; and
- **Model Request Manifest:** exact provider-neutral model, instructions, tools, Model Context, limits, and output contract bound to one model Operation.

V1 need not support changing the Turn Contract mid-Turn. A new model Operation may use a later Conversation projection or Compaction Checkpoint while retaining the same Turn Contract. Replacement Attempts reuse the same manifest.

## Recommended OnePage vocabulary

| Term | Meaning | Lifecycle owner |
| --- | --- | --- |
| `Run` | One durable workflow evaluation and its orchestration graph | Run Service / workflow layer |
| `Session` | Reusable linear Conversation and sparse persistent context history | Host Store |
| `Turn` | One admitted ordinary User input, processed through model and Action Operations until Final Answer or terminal outcome | Session |
| `Operation` | One model request or proposed Action where exact input, Attempts, and recovery matter | Turn |
| `Attempt` | One physical try of an Operation | Operation |
| `Completion` | Durable evidence of what physically happened during an Attempt | Attempt |
| `Resolution` | OnePage's durable interpretation of the Completion and safe next action | Operation/Attempt reconciliation |
| `Goal` | Optional future objective spanning multiple Turns; absent until it has independent product behavior | Session or workflow layer |
| `Job` | Do not use in the V1 harness domain | none |

### Turn outcome

A Turn ends with exactly one typed outcome:

- `completed`: durable Final Answer output is available;
- `failed`: the Turn cannot safely proceed, with a typed failure code such as resource exhaustion; or
- `cancelled`: explicit cancellation was admitted.

Operation uncertainty remains separate evidence rather than another Turn outcome.

`input_required` is a derived nonterminal condition. A correlated response resumes the same Turn. The Session remains reusable after terminal Turn outcome; a later ordinary caller input creates another Turn.

### Multiple Tool Calls

One model Operation may resolve to several ordered Tool Calls. Each call creates one child Action Operation with the model Operation as its causal parent and one call ordinal. The next model Operation waits for every child Tool Result and orders them by call ordinal rather than completion time. This relation supplies the useful grouping that Step would otherwise duplicate.

## Consequences for the current OnePage plan

1. Remove `Job` from the core Session lifecycle and from requirements that merely mean “one agent invocation.”
2. Make `Turn` the idempotently admitted unit of caller input and the object returned/awaited by `agent()`.
3. Map each workflow `agent()` key directly to one Turn. The workflow already supplies composition; the harness should not duplicate it with a Job aggregate.
4. Bind exact request facts to the model Operation and derive model/tool-cycle grouping from causal child Operations. Do not add a durable Step entity.
5. Keep `Operation -> Attempt -> Completion -> Resolution` for effect-aware recovery. Do not call external-effect work a Step or Job.
6. If a future feature needs a durable objective spanning several independently prompted Turns, introduce `Goal` with a narrow objective/phase/budget contract. Do not infer it from Session activity or retrofit Job.
7. Keep provider-neutral Conversation and context components in SQLite and translate provider formats only at dispatch/admission edges.

## Decision test

A proposed durable entity earns a table only if it owns at least one invariant that no existing entity can own clearly.

- Session earns identity, transcript, lineage, and reusable defaults.
- Turn earns input idempotency, a frozen caller contract, input-to-output causality, cancellation, and a typed outcome.
- Model Operation earns the exact request manifest and provider response; causal child Operations supply model/tool-cycle correlation.
- Operation/Attempt earn effect-aware retry and uncertainty semantics.
- Job currently earns nothing that these entities and workflow composition do not already own.

That is the simplification supported by the prior art.
