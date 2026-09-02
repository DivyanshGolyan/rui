# OnePage product

OnePage is a crash-resumable, resource-bounded local runtime for programmable coding-agent workflows. JavaScript expresses orchestration; native Zig owns Sessions, Turns, model requests, tools, permissions, recovery, and storage.

## V1 experience

A Caller runs:

```text
onepage run WORKFLOW --key KEY [--args-file FILE] [--format markdown|json]
onepage inspect RUN_ID [--format markdown|json]
onepage respond RUN_ID --responses FILE [--format markdown|json]
onepage advance RUN_ID [--format markdown|json]
onepage cancel RUN_ID [--format markdown|json]
onepage read RUN_ID CONTENT_REF [--offset N] [--length N] [--output FILE]
```

The Workflow Definition has one form:

```js
export default async function workflow({ agent }, args) {}
```

`agent({ key, task, input, schema, model, reasoning_effort, session, session_context })` is the only supplied capability. It starts or reattaches one durable Turn. Required `task` is the initiating User instruction; optional `input` is bounded strict data deterministically rendered into that same initiating User entry. A Turn advances one reusable Session through model Operations, Tool Calls, Tool Results, and Final Answer.

For continuation, `session` is exactly `{ id, expected_conversation_revision, expected_context_revision }`; omission creates the Session, complete baseline, and Turn atomically. `model` and `reasoning_effort` are Turn-local overrides. Optional `session_context` is a closed sparse persistent patch over model, instructions, enabled built-in Tool Keys, context policy, reasoning default, and output limit. It requires the Session reference's exact expected context revision and a Principal authorized to write the Session. Supplying the same component as both a persistent patch and Turn-local override is a conflict. The patch commits atomically with the new Turn and cannot change an active Turn.

`key` is unique within the Workflow Run and canonically binds the complete Turn specification. Equal replay reattaches; changed bindings conflict. A successful Turn returns Final Answer text or the exact locally validated strict-data value required by `schema`. Failures expose one bounded frozen Turn error.

Ordinary JavaScript functions, loops, arrays, `Promise.all`, and `Promise.allSettled` compose Turns. `Promise.race` and `Promise.any` are absent because physical completion order is not durable workflow input. Each Evaluation Generation runs from source against one immutable Visibility Snapshot and exits at its complete blocked set. No evaluator remains while a Run waits.

## Conversation

A Session contains one immutable linear Conversation. Conversation entries are User text, assistant text, Tool Calls, and Tool Results. Sessions are reusable and never terminal; Turns settle.

One ordinary User message begins a Turn. A model may request permission or bounded text input without releasing the Turn. A correlated response resumes that Turn. Once it settles and the Session is idle, another ordinary User message begins another Turn.

Conversation history is never rewritten. Context pressure creates append-only Compaction Checkpoints used only to construct later model requests.

## Model-visible context

Persistent Session defaults change through sparse Session Context Revisions. A change records only the modified model, Instruction Set, Tool Catalog, context policy, reasoning default, or output limit. The only V1 admission path is the optional Session Context Patch supplied while starting a Turn in an idle Session; revision, Turn, Contract, and initiating User entry commit together. A Turn freezes the resolved revision, explicit overrides, authority, date, timezone, Workspace facts, and output requirements in one Turn Contract.

Every model Operation freezes one provider-neutral Model Request Manifest. Replacement Attempts reuse it exactly. Credentials, HTTP headers, sockets, and provider caching remain late-bound transport details.

This preserves historical context without copying a complete system prompt on every Turn and prevents retry from drifting with ambient configuration.

## Tools and multiple calls

V1 executes `bash` and one-file `apply_patch`. The Tool Catalog is model-visible data; a separate closed Host mapping and exact Authorization decide what may execute.

One model response may contain multiple ordered Tool Calls. Each becomes an independently recoverable child Operation and may settle into SQLite as soon as it finishes. Bash and model Operations may run concurrently even within one Workspace; V1 keeps Patch execution on one private serial lane without claiming Workspace isolation. The next model Operation waits for every child result and receives Tool Results together in original call order, not physical completion order.

`ask` creates an immutable permission request for each exact validated descriptor. Explicit bypass authorizes the same descriptor without a request. Neither mode bypasses validation, Attempt admission, or effect-specific recovery.

## Workflow and Run interface

The Host owns the Workflow Run lifecycle behind six semantic operations: create or attach, inspect, respond, cancel, advance, and read content. Cancelling a Run atomically stops new evaluation and membership and requests cancellation of its nonterminal member Turns; their Sessions remain reusable. The CLI only composes these operations and renders committed Run Snapshots.

JSON is the complete versioned automation contract. Markdown is the default deterministic bounded model-facing view. Every actionable open Interaction Request appears in one snapshot. Process death, terminal closure, and shell timeout detach without cancelling durable work.

## Product guarantees

- SQLite is the sole recoverable OnePage-owned semantic and content store and the canonical relational authority; OS-held credentials are non-semantic security material.
- No Session Ledger, reducer image, continuation blob, or resident object graph duplicates canonical rows.
- At most one Turn is nonterminal in one Session.
- Each Attempt has at most one Completion; one Operation Resolution selects meaning across zero or more Attempts.
- Attempt admission precedes physical dispatch.
- Long-lived request and response content streams through bounded windows to dynamically charged, immediately unlinked scratch; no prompt-, response-, or output-sized resident allocation is multiplied by Active Capacity.
- Complete output is parsed only after its effect-specific terminal boundary in one shared Host validation/import workspace. Normal content, Completion, Resolution, and semantic consequence settle atomically.
- A retryable model Completion is the sole Completion-only exception: it commits with immutable future eligibility while the Operation remains unresolved and consumes no waiting memory or timer object.
- Model retry reuses one exact Model Request Manifest and records possible duplicate work or billing.
- Uncertain Bash is never replayed automatically; the Agent receives an indeterminate Tool Result.
- Patch recovery reconciles exact preimage, expected postimage, and observed state.
- Dormant Sessions, terminal Turns, and Blocked Workflow Runs retain durable bytes rather than live execution resources.
- One startup-fixed Active Capacity bounds concurrent external work.
- Workflow evaluation is disposable, deterministic at durable barriers, and independently bounded.
- Model-requested subprocess memory is workload memory and is measured separately from orchestration memory.
- Codex subscription transport is the first live provider but never owns Conversation, context selection, tools, permissions, or recovery.

## V1 exclusions

- Conversation branches, edit/delete, alternate answers, merge, or fork UI. A later fork creates a new Session with explicit ancestry.
- Unsolicited steering while a Turn is active, queued follow-ups, generic signals, arbitrary forms, credentials, or file uploads.
- Dynamic tools, MCP execution, plugins, skills, hooks, provider registries, automatic model fallback, or generalized OAuth.
- A model-visible Agent tool, recursive model-directed delegation, or durable RLM stack.
- Retained QuickJS, bytecode, Node, timers, imports, filesystem, process, network, environment, credential, clock, or random access inside workflow evaluation.
- MCP Tasks, ACP, A2A, daemon, public event stream, watch mode, webhook, push delivery, TUI, editor, or Web UI.
- Multi-host scheduling, distributed coordination, external-effect exactly-once claims, or arbitrary Bash sandbox claims.
- Backup, export, retention, deletion, garbage collection, shrinking, or compatibility migration for unreleased V1 databases.

## Demonstration standard

The release demonstration runs a deterministic 10–50 Turn workflow, kills OnePage at named semantic and physical handoff boundaries, resumes from SQLite, proves uncertain Bash is not replayed, changes a patch target during downtime and fails reconciliation safely, continues one Session across multiple Turns, changes model-visible context between Turns, executes independent same-Workspace Bash work concurrently, and emits one committed Workflow Output.

It reports whole-process RSS and separate slopes for Dormant Sessions, terminal Turns, Active Capacity, provider transport, SQLite, semantic validation, evaluator memory, immutable content, and workload subprocesses. The density run includes 0, 100, 1,000, and 10,000 Dormant Sessions and Active Capacity 1, 10, and 100.
