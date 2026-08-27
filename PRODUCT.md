# OnePage product contract

OnePage is a terminal-first coding-agent harness with a programmable workflow caller. One native Zig Host Runtime owns every agent Session, provider, tool, durable transition, and resident capacity. A caller supplies one JavaScript workflow; OnePage evaluates it in a short-lived, restricted QuickJS-ng subprocess and turns each keyed `agent()` call into a request to that single agent runtime. Many durable Jobs share one fixed resident pool on one host. Every active Core borrows one compile-time-sized Activation Slot; Dormant Sessions and waiting Workflow Runs retain compact durable facts without retaining an Activation Slot, thread, process, socket, database connection, JavaScript heap, or Conversation object graph.

The memory claim is not that the complete process or a serialized agent fits in the Activation Slot. OnePage bounds its own orchestration memory and reports the actual slot separately from native stacks, host pools, transport buffers, durable storage, and whole-process RSS. Memory intentionally consumed by model-requested Bash processes is workload memory: OnePage does not cap it, and reports it separately. The architectural claim is that OnePage-owned resident memory follows the configured active working set rather than total Session count, Conversation length, or historical completed work.

## V1 experience

V1 runs one foreground workflow at a time:

```sh
onepage run workflow.js [--args-file args.json] [--resource-profile NAME] [--dangerously-bypass-permissions]
onepage resume RUN_ID [--dangerously-bypass-permissions]
onepage cancel RUN_ID
```

The source has one standard form:

```js
export default async function workflow(
  { agent },
  args,
) {}
```

`args` is `{}` by default or the strict bounded data value read once from `--args-file`. `run` canonically binds its invocation working directory as the Run Workspace; every Job Session inherits it, and `resume` uses the stored Workspace regardless of its own current directory. V1 exposes one built-in Workflow Resource Profile named `default`; omitting `--resource-profile` selects it, and an unknown name fails before Run creation. Resume uses the Profile stored with the Run and never accepts a replacement. Resume and cancel never reread the source or arguments.

Only `agent({ key, task, input, schema, agent_profile })` crosses the durable host boundary; it is also the only supplied capability. Ordinary JavaScript functions, loops, arrays, and Promise composition express fan-out and sequencing without Host helpers or a durable DAG. `key` is a mandatory bounded UTF-8 identity unique within the Run. `task` is non-empty bounded user-task text. `input` is a strict bounded data value made model-visible with that task. `agent_profile` is optional and defaults to V1's sole built-in Agent Profile, `default`, which binds the Codex instructions, exact Model Contract, and Tool Catalog but grants no permission; an unknown name fails before Job creation. Optional `schema` uses OnePage's closed JSON Schema 2020-12 subset: `type`, `properties`, `required`, `additionalProperties: false`, `items`, `minItems`, `maxItems`, `minLength`, `maxLength`, `minimum`, `maximum`, and `enum`, composed without references or extension keywords. A schema-backed Final Answer must be exactly one UTF-8 JSON document after surrounding JSON whitespace. OnePage performs no Markdown-fence extraction, substring search, repair, or coercion; parse or validation failure rejects the Job as `JobOutputInvalid`. Without `schema`, the Job Output is Final Answer text. A failed Promise rejects with one frozen `JobError` carrying only bounded `code`, `job_key`, and `message`; V1 codes are `JobFailed`, `JobCancelled`, `JobIndeterminate`, `JobOutputInvalid`, `WorkflowDefinitionConflict`, and `ResourceExceeded`. Workflows may fan out many Jobs, await their Job Outputs, and compose later Jobs from those Outputs.

The workflow must explicitly return one bounded Workflow Output from the same strict data subset: null, Boolean, string, array, string-keyed plain object, or finite IEEE-754 number. Every string must be Unicode scalar text: a well-formed UTF-16 surrogate pair encodes as its standard UTF-8 scalar, while any lone surrogate is rejected without replacement or lossy encoding. An integral number must be within JavaScript's safe-integer range, and negative zero canonicalizes to zero. `undefined`, functions, symbols, bigint, non-finite numbers, unsafe integers, accessors, proxies, cycles, host objects, lone surrogates, and excessive structure fail the Run as `WorkflowOutputInvalid`. The Host canonically encodes and commits the Workflow Output before presentation. `run` and `resume` render that stored value as one terminal-safe canonical JSON line; interrupted output is replayed without reevaluating the workflow.

Each Job owns its own ordinary durable coding Session through the same native runtime and lifecycle. Its model may select only:

- `bash` for repository inspection, verification, and other command execution;
- `apply_patch` for one bounded regular-file mutation.

A complete non-empty assistant response with no tool call is the Final Answer. There is no finish or stop tool.

Conversation uses a provider-neutral semantic format for user text, assistant text, tool calls, tool results, and context checkpoints. A bounded immutable Tool Catalog describes the two tools to the model, while a separate closed host mapping decides what may execute. This keeps provider conversion independent of Bash and patch storage encodings without making tools dynamically executable.

The default `ask` permission mode requests a user decision for every exact tool descriptor. Explicit `--dangerously-bypass-permissions` authorizes validated descriptors without prompting for that invocation. Bypass never disables validation, fixed bounds, durable binding, patch preimage checks, Attempt admission, or effect-specific recovery, and it must be selected again after resume.

The evaluator runs source from the beginning against an immutable Visibility Snapshot of already-visible Job Outputs and stable failures. When it reaches unresolved Jobs, it returns the complete blocked set and exits. OnePage waits until that set is terminal, then starts a fresh evaluator and replays the same immutable source and arguments with a later Visibility Snapshot. JavaScript heap, Promise state, closures, and instruction position are never checkpointed. Provider timing is not workflow input: V1 does not promise physical-completion `Promise.race` semantics.

The terminal demonstrates durable workflow and Session identity, keyed reattachment, exact Action authority, crash recovery, explicit uncertainty, patch reconciliation, executable verification, and honest resource accounting. Deterministic fixtures provide reproducible fan-out, replay, repair, and targeted crash demonstrations. Codex is the first live provider and uses the user's ChatGPT subscription through one model-only provider-specific transport; it never embeds or delegates to a second agent loop.

## Product guarantees

- Every Activation Slot contains only bounded Core State and scratch used by production activation, carries no sizing filler or speculative reserve, and comes from a startup-reserved pool. Its actual compile-time size must not exceed 32 KiB in V1.
- One startup-fixed `active_capacity` bounds transferable Active Credits. Each credit is owned by exactly one live Harness, admitted external Attempt, or closure handoff; it never counts the same Session twice and capacity never grows after startup.
- One startup-fixed workflow-evaluation capacity of one bounds live QuickJS runtimes. Each evaluation has explicit heap, native bridge, stack, instruction-time, result-count, and result-byte limits and is also guarded by its parent process.
- Activating, advancing, suspending, and reusing a slot performs no general-purpose allocation inside Core.
- Dormant and closed Sessions and waiting Workflow Runs retain no Harness allocation, Activation Slot, Active Credit, thread, socket, subprocess, language-runtime object, Promise graph, or materialized Conversation graph. An In-flight Session retains no Harness or Slot but may retain the one bounded provider or tool resource owned by its admitted Attempt and Active Credit.
- A Workflow Run durably binds exact source bytes, arguments, workflow-semantics identity, Workflow Resource Profile, and every keyed Job specification. Replaying the same key with the same canonical specification reattaches; reusing it with different semantics fails closed.
- At most one admitted Bash or patch Attempt may target one Workspace at a time. The Workspace Effect Fence is acquired before Attempt admission and retained through terminal-evidence application; OnePage never guesses that a Bash call is read-only.
- Every acknowledged semantic transition is reconstructable from its ordered Session Ledger and immutable content. Live `offer` acceptance is not acknowledgement; the CLI acknowledges an input only after the Host Store transaction commits.
- Arbitrary Bash is never claimed to be exactly once or repository-confined. An uncertain Bash Attempt is not replayed automatically.
- A one-file patch binds exact Workspace, path, preimage, expected postimage, patch, and Authorization identity before mutation and reconciles observed state before any retry.
- Output and history larger than resident bounds are streamed or spooled outside the Activation Slot without retaining duplicate complete encodings in orchestration memory.

## V1 exclusions

- More admitted tools, runtime tool discovery or registration, MCP execution, plugins, skills, or hooks. The model-visible data contract is generic, but V1 offers and executes only `bash` and `apply_patch`.
- A model-visible Agent tool, recursive in-model delegation, or MCP-defined workflow primitive. Agent composition belongs to the caller-authored workflow in V1.
- A Node.js dependency, ScriptC compilation path, retained QuickJS VM, JavaScript bytecode cache, timer, module loader, filesystem, process, network, environment, credential, clock, or random capability inside workflow evaluation.
- Hostile multi-tenant isolation. The restricted evaluator is defense in depth for locally supplied workflow source, not a security boundary for mutually untrusted tenants.
- A TUI, editor integration, Web UI, or embedded terminal renderer.
- Multi-file patches, arbitrary filesystem mutation adapters, or a repository reconstruction promise.
- Automatic replay of an arbitrary command whose execution is uncertain.
- Multi-host scheduling, remote Session migration, distributed coordination, or external-effect exactly-once claims.
- Conversation navigation, compaction behaviour, or branching UI.
- A promise that total RSS, disk usage, model cost, model-requested workload memory, or dormant-agent storage equals the Activation Slot size. Workload subprocess memory is observed separately and is not capped by OnePage.
- A generalized scheduler, durable JavaScript DAG, independent model/tool/completion pools, dynamic RSS controller, fairness framework, group commit, or hot capacity resizing.
- A provider registry, generalized OAuth framework, model catalog requirement, automatic model fallback, or streaming UI.
- A custom SQLite VFS campaign or a claim that OnePage re-proves SQLite pager durability.
- Host Store snapshots, export, retention, Session deletion, blob garbage collection, shrinking, or cross-version migration.

## V1 responsibility rule

Every V1 subsystem must directly support a product guarantee, an external-effect safety boundary, or evidence required for the release claim. Prefer an existing dependency or an explicit platform assumption when it can own a mechanism without receiving OnePage policy or authority. Do not add an abstraction, pool, background owner, durable representation, or extension seam for a hypothetical second consumer. A broader design requires a current use, a simpler alternative that was rejected for a stated reason, and an accepted ADR.

## Demonstration standard

The primary demonstration runs a deterministic workflow that fans out keyed Jobs, blocks, destroys its evaluator, resumes from durable state, repairs a real fixture, crosses the patch effect boundary without concealing or repeating the mutation, and completes verification. It reports exact slot size, peak evaluator memory, provider transport memory, process RSS, durable bytes, and Job population separately. A separate density run first increases durable Jobs at fixed Active Capacity, then increases Active Capacity at fixed durable population. It reports population-independent resident resources and population-dependent disk cost separately.
