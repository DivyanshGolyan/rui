# OnePage product contract

OnePage is a resource-bounded, crash-resumable local Run service for JavaScript coding-agent workflows. A Caller supplies one Workflow Definition, arguments, and stable Run Key through the CLI. One native Zig Host Runtime owns the resulting Workflow Run, every keyed Job and agent Session, every evaluator process, provider, tool, durable transition, and resident capacity. It invokes a short-lived restricted QuickJS-ng Workflow Evaluator only to calculate the Run's next Job demand or terminal output. Many durable Jobs share one fixed resident pool on one host. Every active Core borrows one compile-time-sized Activation Slot; Dormant Sessions and Blocked Workflow Runs retain compact durable facts without retaining an Activation Slot, thread, process, socket, database connection, JavaScript heap, or Conversation object graph.

The memory claim is not that the complete process or a serialized agent fits in the Activation Slot. OnePage bounds its own orchestration memory and reports the actual slot separately from shared semantic-validation workspaces, native stacks, host pools, transport buffers, durable storage, and whole-process RSS. Active Credits bound active semantic work but are not preallocated bundles containing every possible parser, connection, stack, and subprocess resource. Memory intentionally consumed by model-requested Bash processes is workload memory: OnePage does not cap it, and reports it separately. The architectural claim is that OnePage-owned resident memory follows explicit host and stage capacities plus current work rather than total Session count, Conversation length, or historical completed work.

## V1 experience

V1 ships one local CLI adapter over the protocol-independent Run Service:

```sh
onepage run WORKFLOW --key KEY [--args-file FILE] [--resource-profile NAME] [--dangerously-bypass-permissions] [--format markdown|json]
onepage inspect RUN_ID [--format markdown|json]
onepage inspect --key KEY [--format markdown|json]
onepage respond RUN_ID --responses FILE [--dangerously-bypass-permissions] [--format markdown|json]
onepage advance RUN_ID [--dangerously-bypass-permissions] [--format markdown|json]
onepage cancel RUN_ID [--format markdown|json]
onepage read RUN_ID CONTENT_REF [--offset N] [--length N] [--output FILE]
```

`--responses FILE` accepts exactly the versioned [`InteractionResponseBatch`](docs/spec/interaction-response-batch-v1.schema.json) JSON contract. The invoking Principal is derived by the Run Service and is not caller-asserted data. A permission response echoes the immutable request identity and descriptor digest but not the operation identity or generation: the open request already binds those facts, and repeating them would create a second freshness surface. For example:

```json
{
  "api_version": "onepage.interaction-response-batch.v1",
  "responses": [
    {
      "request_id": "req_a91",
      "kind": "permission",
      "decision": "allow_once",
      "descriptor_digest": "sha256:0000000000000000000000000000000000000000000000000000000000000000"
    },
    {
      "request_id": "req_b14",
      "kind": "input",
      "response": {
        "type": "text",
        "text": "Use the existing migration."
      }
    }
  ]
}
```

A single-choice answer uses `response: { "type": "single_choice", "choice_id": "..." }`. The batch must contain unique request identities. The Run Service checks each input against its request-specific byte or option bound and rejects the complete batch when any response is unknown, withdrawn, already answered differently, malformed, unauthorized, or binding-mismatched.

`run`, `respond`, `cancel`, and `advance` drive the Run until it becomes `input_required`, reaches a supported `suspended` boundary, or becomes terminal. `inspect` is a pure committed read and never drives work. `read` returns immutable Run-owned content through bounded ranges. A signal, shell timeout, terminal closure, or broken pipe detaches the invocation without cancelling the durable Run; only `cancel` records cancellation intent. Terminal Runs are immutable, and `advance` on one returns its existing snapshot without reopening it.

The source has one standard form:

```js
export default async function workflow(
  { agent },
  args,
) {}
```

`args` is `{}` by default or the strict bounded data value read once from `--args-file`. `run` requires a Caller-supplied Run Key unique within the Host Store and canonically binds its invocation working directory as the Run Workspace. The same key and identical workflow, arguments, Workspace, semantics, and profile reattach to the same Run; changed bindings conflict rather than creating another Run. Every Run operation derives the local Principal and checks Run access; knowing a key grants no access. Every Job Session inherits the stored Workspace. Later commands never reread source or arguments or adopt their current directory. V1 exposes one built-in Workflow Resource Profile named `default`; omission selects it, and an unknown name fails before Run creation.

Only `agent({ key, task, input, schema, agent_profile })` crosses the durable Host boundary; it is also the only supplied capability. Ordinary JavaScript functions, loops, arrays, and deterministic Promise joins express fan-out and sequencing without Host helpers or a durable DAG. `Promise.all` and `Promise.allSettled` are supported; `Promise.race` and `Promise.any` are absent because physical Job completion order is not observable workflow input. `key` is a mandatory 1–128 Unicode-scalar identity, at most 512 UTF-8 bytes, unique within the Run; it is caller-defined data and is not restricted to the shell-safe system-ID grammar. `task` is non-empty bounded user-task text. `input` is a strict bounded data value made model-visible with that task. `agent_profile` is optional and defaults to V1's sole built-in Agent Profile, `default`, which binds the Codex instructions, exact Model Contract, and Tool Catalog but grants no permission; an unknown name fails before Job creation. Optional `schema` uses OnePage's closed JSON Schema 2020-12 subset: `type`, `properties`, `required`, `additionalProperties: false`, `items`, `minItems`, `maxItems`, `minLength`, `maxLength`, `minimum`, `maximum`, and `enum`, composed without references or extension keywords. A schema-backed Final Answer must be exactly one UTF-8 JSON document after surrounding JSON whitespace. OnePage performs no Markdown-fence extraction, substring search, repair, or coercion; parse or validation failure rejects the Job as `JobOutputInvalid`. Without `schema`, the Job Output is Final Answer text. A failed Promise rejects with one frozen `JobError` carrying only bounded `code`, `job_key`, and `message`; V1 codes are `JobFailed`, `JobCancelled`, `JobIndeterminate`, `JobOutputInvalid`, `WorkflowDefinitionConflict`, and `ResourceExceeded`. `JobIndeterminate` applies only when the Job's Session reaches a terminal Outcome without safely establishing success or failure; uncertainty about one tool Attempt is first returned to the Agent as model-visible evidence. Workflows may fan out many Jobs, await their Job Outputs, and compose later Jobs from those Outputs.

The workflow must explicitly return one bounded Workflow Output from the same strict data subset: null, Boolean, string, array, string-keyed plain object, or finite IEEE-754 number. Every string must be Unicode scalar text: a well-formed UTF-16 surrogate pair encodes as its standard UTF-8 scalar, while any lone surrogate is rejected without replacement or lossy encoding. An integral number must be within JavaScript's safe-integer range, and negative zero canonicalizes to zero. Object keys canonicalize at every nesting level, and one cumulative structural-entry budget covers the complete value rather than restarting for each nested container. `undefined`, functions, symbols, bigint, non-finite numbers, unsafe integers, accessors, proxies, cycles, host objects, lone surrogates, and excessive structure fail the Run as `WorkflowOutputInvalid`. The Host canonically encodes and commits the Workflow Output before presentation. A later snapshot or content read returns the same stored value without reevaluating the workflow.

Each Job owns its own ordinary durable coding Session through the same native runtime and lifecycle. Its model may select only two executable Actions:

- `bash` for repository inspection, verification, and other command execution;
- `apply_patch` for one bounded regular-file mutation.

A complete non-empty assistant response with no tool call is the Final Answer. The model may instead emit one provider-neutral, non-effecting `input_request` disposition with a bounded prompt and either a text or single-choice response shape. It creates no Action, Attempt, Authorization, or external execution. There is no finish or stop tool.

Conversation uses a provider-neutral semantic format with exactly four V1 entry kinds: user text, assistant text, tool calls, and tool results. A bounded immutable Tool Catalog describes the two executable tools to the model, while a separate closed host mapping decides what may execute. The Model Contract also declares the one `input_request` disposition and each provider adapter lowers it to its supported structured wire mechanism. Committing that disposition atomically appends its prompt as assistant text and creates the Interaction Request; accepting the response appends user text. This keeps provider conversion independent of Bash and patch storage encodings without making tools dynamically executable. V1 reserves no Conversation variant for unimplemented compaction.

The default `ask` permission mode creates one immutable permission Interaction Request for every exact validated tool descriptor. `User` is the Conversation role and may be fulfilled by a person or another Agent; it is not the Caller, Principal, or permission Authority. A permission Interaction Response is accepted only from a Principal whose delegated Authority covers the exact request, operation binding, descriptor digest, and decision. Under the default local trust profile, the invoking OS Principal may hold root Run authority; ask mode is then an auditable orchestration boundary rather than protection from that Caller. Explicit bypass authorizes validated descriptors without creating a permission request for that invocation. Bypass changes only how Authorization is obtained; it never disables validation, fixed bounds, durable binding, patch preimage and postimage checks, Attempt admission, or effect-specific recovery.

The Host owns the complete Workflow Run lifecycle behind six semantic operations: idempotent creation or attachment, committed snapshot read, atomic response submission, durable cancellation request, fenced advancement, and immutable content read. The CLI only composes those operations and renders their results. For each Evaluation Generation, the Host starts an evaluator from the beginning against an immutable Visibility Snapshot of already-visible Job Outputs and stable failures. When it reaches unresolved Jobs, it returns the complete blocked set and exits. The Run is durably Blocked while the Host waits for that set to become terminal; no evaluator remains live. The Host then commits a later Generation and starts a fresh evaluator with the same immutable Definition and arguments. JavaScript heap, Promise state, closures, and instruction position are never checkpointed. Provider timing and physical Job completion order cannot be observed by workflow code.

The product keeps public Run state separate from internal Workflow Run and Session state. A Blocked Workflow Run awaits Jobs; an Awaiting User Session has an open Interaction Request; an In-flight Session owns one admitted external Attempt. The Run Service reports `running`, `input_required`, optionally `suspended` only for a concrete supported non-user boundary, or one of `completed`, `failed`, and `cancelled`. `input_required` means at least one request is open and no other work in the Run can progress without a response. It never exposes an ambiguous generic `waiting` status.

Every open Interaction Request appears in the bounded `RunSnapshot`; actionable requests are never paginated. V1 supports runtime-issued `permission` requests and Agent-issued `input` requests whose response shape is either bounded text or one bounded single choice. Requests are immutable, identities are never reused, and replacement withdraws the old request and creates a new identity. Permission and conversational responses share one atomic bounded batch envelope but retain different validators. Unsolicited input, arbitrary forms, credentials, uploads, generic signals, and workflow-issued input are excluded.

The complete external representation is the versioned JSON `RunSnapshot` defined by [`docs/spec/run-snapshot-v1.schema.json`](docs/spec/run-snapshot-v1.schema.json). Markdown is the default deterministic, bounded, model-facing brief derived only from the same semantic value. It labels untrusted model and tool content, preserves trusted framing, marks presentation truncation, and directs the Caller to immutable content when the complete value is not inline. A JSON inline text or value part is always complete; content that does not fit inline is represented only by `content_ref`, whose optional preview may be truncated while the complete immutable bytes remain readable. Opaque identities, revisions, sequences, and byte offsets are strings in JSON. A successful CLI protocol operation exits zero even when the Run snapshot is `input_required`, `failed`, or `cancelled`; nonzero reports invocation, rejection, authority, driver, storage, infrastructure, interruption, or output failure.

Final text, complete permission descriptors, large diagnostics, and immutable artifacts are materialized as Run-owned content before their Harness generation or evaluator is released. A content reference remains valid while its Run is inspectable and supports bounded reads. A mutable Workspace path is not itself an immutable artifact.

The Run interface demonstrates durable workflow and Session identity, keyed reattachment, exact Action authority, crash recovery, explicit uncertainty, patch reconciliation, executable verification, and honest resource accounting. Deterministic fixtures provide reproducible fan-out, replay, repair, and targeted crash demonstrations. Codex is the required first live provider target through one model-only transport using the user's existing ChatGPT subscription. Issue #11's deterministic gate establishes the adapter and capacity-one Harness semantics; its attended live tracer remains required before the issue closes but does not block independent workflow-kernel work. A real Codex model must still inspect and repair a controlled repository through the existing Harness, canonical Conversation, and admitted Bash and patch tools before OnePage claims the subscription experience. The same adapter is later carried unchanged into durable Workflow Runs and measured concurrency. OnePage never embeds or delegates to a second agent loop.

## Product guarantees

- Every Activation Slot contains only bounded Core State and scratch used by production activation, carries no sizing filler or speculative reserve, and comes from a startup-reserved pool. Its actual compile-time size must not exceed 32 KiB in V1.
- One startup-fixed `active_capacity` bounds transferable Active Credits. Each credit is owned by exactly one live Harness, admitted external Attempt, or closure handoff; it never counts the same Session twice and capacity never grows after startup.
- Model adapters stream bounded Captured Model Output and release transport resources without retaining semantic-validation scratch. One shared V1 admission workspace validates each capture once and commits its Result meaning through the existing Session Ledger owner path; later readers trust that admitted authority and exact identities rather than reparsing for canonical formatting.
- Tool Calls retain exact bounded strict JSON arguments under a versioned Validation Profile and the Operation's Tool Catalog. Semantic-equivalent JSON need not share bytes. Bash and patch derive durable typed descriptors before external execution, so an effect never depends on first-time JSON interpretation after Attempt admission.
- One startup-fixed workflow-evaluation capacity of one bounds live QuickJS runtimes. Each evaluation has explicit heap, native bridge, stack, instruction-time, result-count, and result-byte limits and is also guarded by its parent process.
- Activating, advancing, suspending, and reusing a slot performs no general-purpose allocation inside Core.
- Dormant and closed Sessions and Blocked Workflow Runs retain no Harness allocation, Activation Slot, Active Credit, thread, socket, subprocess, language-runtime object, Promise graph, or materialized Conversation graph. An In-flight Session retains no Harness or Slot but may retain the one bounded provider or tool resource owned by its admitted Attempt and Active Credit.
- A Workflow Run durably binds exact source bytes, arguments, workflow-semantics identity, Workflow Resource Profile, and every keyed Job specification. Replaying the same key with the same canonical specification reattaches; reusing it with different semantics fails closed.
- A Workflow Definition cannot observe physical Job completion order. Each Evaluation Generation sees one immutable Visibility Snapshot, waits for its complete blocked set, and exposes no `Promise.race` or `Promise.any` intrinsic.
- Run creation requires a Caller Run Key. Every mutating operation is safe to retry after a lost acknowledgement under its operation-specific contract: creation reattaches or conflicts by exact binding, identical responses replay successfully while conflicting responses fail, advancement continues from committed state, and repeated cancellation succeeds.
- Exactly one fenced driver advances a Run. Inspection remains a pure committed read; notifications and rendering never carry authority.
- A `RunSnapshot` is a committed revisioned read model, not durable authority. It contains every open Interaction Request and bounded Job, output, failure, uncertainty, Artifact, and pagination metadata.
- Run-owned Content References remain immutable and readable for the inspectable lifetime of their Run, independently of Harness and evaluator lifetime.
- At most one admitted Bash or patch Attempt may target one Workspace at a time. The Workspace Effect Fence is acquired before Attempt admission and retained through terminal-evidence application; OnePage never guesses that a Bash call is read-only.
- Every acknowledged semantic transition is reconstructable from its ordered Session Ledger and immutable content. Live `offer` acceptance is not acknowledgement; the Run Service acknowledges an input only after the Host Store transaction commits.
- Arbitrary Bash is never claimed to be exactly once or repository-confined. An uncertain Bash Attempt is not replayed automatically; its indeterminate Tool Result is appended to Conversation so the Agent can inspect state and choose the next action without automatic User escalation.
- A one-file patch binds exact Workspace, path, preimage, expected postimage, patch, and Authorization identity before mutation and reconciles observed state before any retry.
- Output and history larger than resident bounds are streamed or spooled outside the Activation Slot without retaining duplicate complete encodings in orchestration memory.

## V1 exclusions

- More admitted tools, runtime tool discovery or registration, MCP execution, plugins, skills, or hooks. The model-visible data contract is generic, but V1 offers and executes only `bash` and `apply_patch`.
- A model-visible Agent tool, recursive in-model delegation, or MCP-defined workflow primitive. Agent composition belongs to the Caller-supplied Workflow Definition in V1.
- A Node.js dependency, ScriptC compilation path, retained QuickJS VM, JavaScript bytecode cache, timer, module loader, filesystem, process, network, environment, credential, clock, or random capability inside workflow evaluation.
- Hostile multi-tenant isolation. The restricted evaluator is defense in depth for locally supplied workflow source, not a security boundary for mutually untrusted tenants.
- A TUI, editor integration, Web UI, or embedded terminal renderer.
- MCP Tasks, ACP, A2A, a daemon, push delivery, subscriptions, webhooks, or a public event-replay protocol. These may later adapt the Run Service without becoming its authority.
- Arbitrary JSON Schema input forms, file upload, credential elicitation, unsolicited User messages, workflow-issued input, or a generic signal bus.
- Multi-file patches, arbitrary filesystem mutation adapters, or a repository reconstruction promise.
- Automatic replay of an arbitrary command whose execution is uncertain.
- Multi-host scheduling, remote Session migration, distributed coordination, or external-effect exactly-once claims.
- Conversation navigation, compaction behaviour, or branching UI.
- A promise that total RSS, disk usage, model cost, model-requested workload memory, or dormant-agent storage equals the Activation Slot size. Workload subprocess memory is observed separately and is not capped by OnePage.
- A public generalized scheduler, durable JavaScript DAG, user-tuned resource graph, dynamic RSS controller, fairness framework, group commit, or hot capacity resizing. Private fixed provider, effect, and semantic-admission permits may bound genuinely different resource classes while `active_capacity` remains the single ordinary user setting.
- A provider registry, generalized OAuth framework, model catalog requirement, automatic model fallback, or streaming UI.
- A custom SQLite VFS campaign or a claim that OnePage re-proves SQLite pager durability.
- Host Store snapshots, export, retention, Session deletion, blob garbage collection, shrinking, or cross-version migration.

## V1 responsibility rule

Every V1 subsystem must directly support a product guarantee, an external-effect safety boundary, or evidence required for the release claim. Prefer an existing dependency or an explicit platform assumption when it can own a mechanism without receiving OnePage policy or authority. Do not add an abstraction, pool, background owner, durable representation, or extension seam for a hypothetical second consumer. A broader design requires a current use, a simpler alternative that was rejected for a stated reason, and an accepted ADR.

## Demonstration standard

The first opt-in live demonstration gives Codex a controlled repository with a failing executable test and lets it inspect, patch, verify, and finish through the current Harness. This is an early provider and product-shape proof, not a deterministic correctness oracle. The primary release demonstration later runs a deterministic 10–50 Job workflow, terminates the process at named semantic crash points, advances from durable state, proves that uncertain Bash is not replayed, changes a patch target during downtime and fails reconciliation safely, and completes verification. It reports exact slot size, peak evaluator memory, provider transport memory, process RSS, durable bytes, and Job population separately. A separate density run measures 0, 100, 1,000, and 10,000 Dormant Sessions at fixed Active Capacity, then Active Capacity 1, 10, and 100 at fixed durable population. It publishes raw machine-readable results plus a concise table that separates population-independent resident resources from population-dependent disk cost. A 100,000-Session run is optional stress evidence, not a V1 gate.
