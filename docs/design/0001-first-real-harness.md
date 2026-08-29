# First real harness design

Status: historical; superseded in part by `ARCHITECTURE.md`, ADR-0006, ADR-0008, and ADR-0009. ADR-0007 records the historical semantic precursor to ADR-0009.

`PRODUCT.md`, `ARCHITECTURE.md`, and `VERIFICATION.md` are normative. They supersede this document's raw Core image, effect-only operation journal, checkpoint-authority, Wasm, and delegation-scope details while retaining the accepted `Harness.open / offer / drive` interface, effect semantics, and two-tool product loop. V1 now includes caller-directed keyed Jobs through a disposable workflow evaluator; model-directed delegation remains post-V1.

Related specifications:

- [Build the first real one-page coding-agent loop](https://github.com/DivyanshGolyan/onepage/issues/2)
- [Make active capacity runtime-configurable and population-independent](https://github.com/DivyanshGolyan/onepage/issues/3)

Research basis:

- [`fx-pi-harness-lessons.md`](../research/fx-pi-harness-lessons.md)
- [`deepseek-harness-lessons.md`](../research/deepseek-harness-lessons.md)
- [`ghostty-lessons.md`](../research/ghostty-lessons.md)
- [`codex-cli-session-lessons.md`](../research/codex-cli-session-lessons.md)
- [`cursor-origin-wal-lessons.md`](../research/cursor-origin-wal-lessons.md)

Domain language:

- [`CONTEXT.md`](../../CONTEXT.md)

Architectural decisions:

- [`0001-append-only-conversation-tree.md`](../adr/0001-append-only-conversation-tree.md)
- [`0002-compose-agents-through-durable-delegation.md`](../adr/0002-compose-agents-through-durable-delegation.md)
- [`0003-treat-user-worktrees-as-external-truth.md`](../adr/0003-treat-user-worktrees-as-external-truth.md)
- [`0004-reconcile-uncertain-effect-attempts.md`](../adr/0004-reconcile-uncertain-effect-attempts.md)
- [`0005-use-two-tools-and-final-assistant-text.md`](../adr/0005-use-two-tools-and-final-assistant-text.md)

## Decision

The first useful OnePage agent has two modules at two deliberate seams:

1. `Cli` presents the process interface used by people and black-box tests.
2. `Harness` presents a three-entry owner-loop interface used by the CLI implementation.

These are not duplicate orchestration layers. `Cli` translates process input and output. `Harness` owns the agent lifecycle and every correctness-sensitive ordering rule.

```text
terminal / black-box test
          |
          | onepage [options] TASK
          v
        Cli module
          |
          | open / offer / drive
          v
      Harness module
          |
          +-- one-page policy core
          +-- durable journal and checkpoints
          +-- model and tool adapters
          +-- committed projections
```

The CLI is the highest product test seam. `Harness` is the highest deterministic lifecycle and fault-injection test seam. Provider, tool, storage, and output details remain internal seams rather than becoming product interfaces.

## Constraints

- The agent policy core is a target-neutral Zig reducer over exactly one caller-owned 64 KiB image.
- The production executor is native Zig. A one-page `wasm32-freestanding` build is a mechanically
  checked conformance target, not a production runtime dependency.
- The core owns task phase, context selection, assistant-response interpretation, permission state, retry decisions, and termination.
- The native host supplies bounded mechanisms and may not infer the next tool call or Final Answer.
- One logical agent, one resident execution slot, one model operation, and one tool operation are sufficient for the first coding-task loop.
- Every operation follows submitted → accepted → completed.
- Accepted intent can outlive the process and does not require a resident page; the corresponding external effect may remain uncertain.
- No callback reenters the core.
- Immediate and deferred completions follow the same path.
- Large payloads live in durable storage and cross the core interface through bounded windows and generation-tagged handles.
- Partial model output cannot authorize an effect.
- Mutations and commands require approval bound to the exact immutable operation descriptor.
- The first design must leave room for runtime-configurable slot capacity without implementing it yet.

## Session and context model

A task is not a session, and a conversation is not model context. V1 creates one durable session for one agent and one task, but keeps their identities distinct so the same session can later contain follow-up tasks without redefining stored history.

The session has two append-only durable surfaces:

1. The conversation tree contains immutable, parent-linked entries that may become model-visible. V1 advances only a `main` leaf, but every entry carries its parent relationship from the first implementation.
2. The operation journal contains recovery and effect-lifecycle records. These records never enter model context merely because they exist; an authoritative result becomes model-visible only through a committed conversation entry.

A branch is one root-to-leaf conversation path. Model context is a deterministic, bounded projection of the active branch for one model operation, not a stored or resident transcript. The core selects entries and bounded durable ranges; the host walks the branch and serializes that selection without adding, reordering, or summarizing semantic content.

Compaction is deferred as behaviour, not erased from the architecture. A future compaction operation will append an immutable context checkpoint that names the source interval, stable replacement projection or durable handles, retained tail, context-policy version, previous checkpoint, and digest. Context construction selects the newest valid checkpoint and replays later entries while the original branch remains available for audit, branching, and a different future projection. A checkpoint is published only after its complete replacement projection is durable; invalid or incomplete checkpoints fall back to an older checkpoint or the branch root.

Resume continues the same session and branch. A future conversation fork creates another branch over a frozen committed entry and operation-journal watermark within that session; it does not copy the parent transcript or create another session merely to represent alternate history. V1 permits neither navigation nor forking, but its entry identities and storage reads must preserve those semantics.

The resident core retains only stable session identity, the active conversation leaf, bounded selection state, and generation-tagged handles. The conversation tree and operation journal remain on disk and are traversed through bounded reads or an on-disk index; no resident object graph grows with conversation length.

## Session ownership and resume

At most one live `Harness` owns transition authority for a durable session. `Harness.open` acquires an exclusive operating-system lock for the session lifetime and durably advances its ownership epoch before it may restore, dispatch, or apply work. Every dispatch and completion carries that epoch in addition to agent and operation generations. A stale owner cannot dispatch, journal, or apply work after losing ownership; the current owner may accept a late completion from an older epoch only when it names an open durable attempt, then reconcile it through the normal completion path.

A new invocation and a recovery invocation are distinct product operations:

```text
onepage [--repo PATH] --model PROVIDER:MODEL TASK
onepage --resume SESSION_ID
```

Creating a session prints its stable identity before the first external effect. Resume restores the recorded repository binding, model selection, session, agent, task, and active branch; credentials remain external and must still be available to the relevant adapter. Harness accepts a Provider only as part of a provider-neutral `ModelBinding` that also carries the exact immutable model identity. Create always requires that binding. Resume may omit it for read-only/local reconstruction, but any resumed external model work requires the binding and validates its identity before provider dispatch or a new durable Result. The caller cannot replace the recorded model. If the session lock is held, the command fails without opening a second owner. Repeating task text creates a new session and never implies resume.

## Workspace continuity

Conversation reconstruction and workspace reconstruction are different claims. V1 operates on a user-owned Git worktree that may change outside OnePage, so the worktree remains external truth. The operation journal records the exact preimage identity, immutable mutation descriptor, observed postimage identity, and uncertainty disposition for each consequential repository operation; these are fields on the existing operation record, not a third history.

V1 patch operations touch exactly one regular file. One immutable Patch Intent binds the exact patch, preimage, and expected postimage before Authorization. Patch application is reconcilable, not transactionally atomic with the worktree: recovery classifies the current file as the expected preimage, expected postimage, or divergent. The preimage permits application only under the current Authorization and the V1 quiescent-target assumption, the postimage proves the intended mutation is already present, and divergence stops automatically with an indeterminate result. A later multi-file patch must define the same classification per file and may not claim all-or-nothing mutation without an isolated transactional mechanism.

On resume or delayed application, the harness compares the current workspace state with the expected generation and fails closed for reconciliation on mismatch. It never treats transcript text, command output, or an accepted-but-unreconciled operation as proof of repository state.

A future harness-owned isolated workspace may close every mutation path, store a durable Git baseline plus semantic mutations, and treat the checked-out repository as a disposable materialization. Cursor Origin's WAL-first repository reconstruction applies only in that mode. Physical mutation-log checkpointing in such a workspace is distinct from conversation compaction: the former preserves exact repository semantics, while the latter deliberately changes model-visible detail.

## Agent composition

Agents compose through durable delegation, not recursive calls. A delegation action creates a fresh child agent, session, and task as an external operation. The parent-child relation and accepted operation become durable before the child can run or the parent can release its page.

The child is an ordinary logical agent driven through the same `Harness`. It may delegate again without retaining any ancestor in memory. When the child reaches a terminal outcome, that outcome is durably summarized as the result of the parent's delegation operation and routed through the normal completion path. The child's full conversation does not enter the parent's model context implicitly.

Delegation creates a durable tree rather than a process stack. Scheduling, completion routing, restoration, and capacity admission use stable agent and operation identities directly; none walks the ancestry chain to advance an agent. The system imposes no product limit on logical delegation depth, although total logical population, disk use, total work, and serial critical-path latency still grow with the workload.

Topology independence is a measurable invariant: for one selected agent, activation, suspension, resume, admission, and completion routing perform bounded work and retain bounded memory independent of ancestor depth, descendant count, and sibling count. Global discovery and observability may query a durable topology index, but those paths are outside agent advancement and must paginate rather than hydrate the tree. Capacity limits apply to shared active resources and durable storage, never to nesting depth.

The V1 compatibility constraints are to avoid root-only identities, resident caller frames, synchronous reentry, and capacity accounting based on ancestry depth. V1 does not include a `delegate` action or child scheduler.

Any post-V1 execution policy must keep per-agent advancement independent of topology and avoid a product-level nesting-depth limit. A later closed-union `delegate` action can reuse submitted → accepted → completed, quiescent suspension, and typed results without changing the three-entry harness interface.

A child receives a bounded delegation packet selected by its parent, not a copied parent conversation. Resuming an agent restores only that agent; it never walks, hydrates, or awakens descendants. Direct durable runnable and completion records make each logical agent independently schedulable regardless of its position in the delegation tree.

## Designs considered

### 1. Owner-loop `Harness`

Interface:

```zig
Harness.open(config, storage, adapters) !Harness
Harness.offer(input) OfferResult
Harness.drive() !Progress
```

This design deepens the existing fixed-credit harness and durable transition adapter. It has the strongest locality for persistence-before-apply, checkpointing, page release, completion routing, stale generation rejection, and recovery. Its weakness is that ordinary callers must run the owner loop.

Decision: accept as the internal harness interface.

### 2. Protocol-driven `AgentRuntime`

Interface:

```zig
AgentRuntime.command(command) !CommandResult
AgentRuntime.drive(budget) !Progress
AgentRuntime.events(cursor, out) !EventBatch
AgentRuntime.readBlob(blob, offset, out) !BlobRead
AgentRuntime.close() !void
```

This is attractive if several simultaneous clients eventually exist, such as terminal, structured JSON, and editor integrations. It also gives clients durable cursors and explicit blob reads.

It is premature for the first task. No second real client currently needs the event and blob protocol, and exposing it would make callers understand five lifecycle concepts before the core loop has proved useful. A convenience facade would then be required for the common case.

Decision: reject for v1. Reconsider only after a second real client cannot use the process interface or `Harness` projections.

### 3. Process-level task invocation

Interface:

```text
onepage [--repo PATH] --model PROVIDER:MODEL TASK
onepage [--repo PATH] --model fixture:PATH TASK
onepage --resume SESSION_ID
```

This gives the common caller and employment-funnel demonstration the smallest possible interface. A deterministic fixture and a live model run through the same executable. Its weakness is poor embeddability if treated as the only module.

Decision: accept as the product interface, backed by the owner-loop `Harness` rather than replacing it.

## `Cli` module

### Interface

The process contract is its interface:

```text
arguments
environment
standard input
standard output
standard error
exit status
```

Interactive example:

```sh
onepage \
  --repo ./fixture \
  --model codex:MODEL \
  "Fix the failing parser test"
```

Deterministic example:

```sh
onepage \
  --repo ./fixture \
  --model fixture:./repair.fixture \
  "Fix the failing parser test"
```

### Responsibilities

- Parse the invocation and resolve the repository.
- Select and construct the model adapter.
- Reserve caller-owned harness storage.
- Create a durable session or explicitly resume one by identity.
- Acquire and retain exclusive session ownership before driving it.
- Start the task through `Harness.offer`.
- Pump external completions into `Harness.offer`.
- Call `Harness.drive` until suspended or terminal.
- Render committed projections.
- Collect approval input and offer a digest-bound decision.
- Wait for external readiness while the harness is suspended.
- Map the terminal outcome to a stable exit status.
- Restore the terminal after interruption or failure.

It must not reconstruct prompt context, select tools, decide retries, mutate the journal directly, apply completions, or call the core ABI around the harness.

### Output discipline

- Human output uses the primary terminal screen and ordinary scrollback.
- Model, repository, and subprocess bytes are treated as hostile and sanitized.
- In a later structured mode, machine-readable records go to standard output and prompts or diagnostics go to standard error.
- Non-interactive execution fails instead of waiting invisibly for approval.
- A terminal renderer failure cannot roll back a committed harness fact.

## `Harness` module

### Interface

```zig
pub const Harness = struct {
    pub fn open(
        config: Config,
        storage: Storage,
        adapters: Adapters,
    ) !Harness;

    pub fn offer(self: *Harness, input: Input) OfferResult;

    pub fn drive(self: *Harness) !Progress;
};
```

`open` borrows caller-owned fixed storage and adapters. The harness allocates no capacity after opening. The caller owns adapter and backing-storage lifetimes. Opening a durable session also acquires its exclusive lifetime lock and publishes a new ownership epoch before transition authority becomes available.

`offer` is the only producer-to-owner transfer. It performs no I/O, allocation, wait, or core call. Ownership transfers only when it returns `queued`.

`drive` is the only owner-thread transition entry point. It is non-reentrant and processes at most the configured transition and projection quanta. It may pay bounded durability latency.

Shutdown is an input followed by driving to `closed`; it is not a fourth lifecycle method.

### Input

```zig
pub const Input = union(enum) {
    start_task: TaskInput,
    completion: Completion,
    permission: PermissionDecision,
    cancel: AgentIdentity,
    shutdown,
};
```

`TaskInput` contains fixed identity fields and a durable reference to the bounded task bytes. It is copied into fixed ingress storage before `offer` returns `queued`; oversized task content is rejected before the reference is created.

`Completion` contains stable agent, operation, and ownership-epoch identity, both generations, and a durable result reference. The operation journal resolves the Session and Attempt relationship. Large provider and tool bodies never enter the ingress ring.

`PermissionDecision` contains the agent and operation generations plus the digest of the descriptor and bytes displayed to the user. A stale or mismatched decision cannot authorize an effect.

Cancellation is a durable request to stop further agent decisions, not a claim that an accepted effect did not happen. The harness admits no new operation after cancellation, but every accepted operation must still reach a terminal or indeterminate disposition. If a completion races cancellation, the journal records and reconciles the completion before the task reaches its cancelled outcome.

Shutdown stops new admission and asks the harness to relinquish ownership cleanly. `closed` is valid only after every accepted operation has a terminal or indeterminate disposition and the final checkpoint reflects it. If an adapter cannot stop or prove a result, shutdown records uncertainty according to the operation's effect class rather than discarding the operation.

### Progress

```zig
pub const Progress = struct {
    consumed: u8,
    committed: u8,
    dispatched: u8,
    stale: u8,
    duplicate: u8,
    projections: []const Projection,
    state: State,
    more: bool,
};

pub const State = enum {
    running,
    suspended,
    finished,
    closed,
    failed,
};
```

The projection slice is borrowed from caller-owned storage until the next `drive`. Projections contain compact fields or durable text references and become visible only after the authoritative fact commits.

Volatile edge projections, such as streaming text deltas, may be lost across a crash. Durable level projections, including approval-required, indeterminate, cancelled, and terminal outcomes, are regenerated from restored state on the first `drive` after `open` and whenever the authoritative state changes. Recovery therefore does not require an event cursor or make a previously displayed prompt authoritative.

Ordinary model, tool, approval, timeout, cancellation, indeterminate-effect, and verification failures are typed durable results. A timeout is a terminal attempt result produced by an adapter from the immutable timeout descriptor; the core has no implicit clock. If a crash prevents that result from becoming durable, normal effect-uncertainty recovery applies. `drive` errors are reserved for corruption, impossible state, adapter contract violation, failed durability, or an unreconciled transition that makes continued ownership unsafe.

### Offer dispositions

```text
queued
full
busy
closed
invalid
unavailable
```

`full` and `busy` leave ownership with the producer. `unavailable` means the current owner has failed stop and must be reconstructed.

## Authoritative ordering

The operation journal is authoritative for external-effect lifecycle. A checkpoint is an atomic snapshot of core state that may lag the journal. On disagreement, recovery restores the newest valid checkpoint and reconciles it forward from journal records; it never rolls the journal back to match the page.

An operation describes the logical external work and completes at most once. Each delivery or execution try has a stable attempt identity beneath that operation. Before an adapter may observe an attempt, the journal durably records its operation, attempt identity, ownership epoch, immutable descriptor digest, and recovery class.

### Starting an effect

```text
core publishes immutable submitted descriptor
-> publish submitted checkpoint
-> validate authority and resource bounds
-> append and sync accepted record
-> advance core to accepted
-> publish accepted checkpoint
-> append and sync delivery-attempt record
-> admit that attempt to its adapter
-> release page at a quiescent yield
```

The adapter cannot observe an operation before durable acceptance and attempt identity. A slot cannot be released while its only copy of a submitted operation remains in the page. A crash with no later attempt disposition is conservatively `possibly_executed` unless the adapter can prove `definitely_unsent`.

### Completing an effect

```text
adapter spools complete bounded result
-> offer stable completion
-> restore and generation-check page
-> classify journal, ownership epoch, attempt, and slot state
-> append and sync completed record when needed
-> apply completion through core ABI
-> publish completed checkpoint
-> expose committed projections
-> release or continue page
```

A journal-durable result absent from the page applies once without a second append. A duplicate is consumed idempotently. A stale generation never mutates state.

### Attempt dispositions and recovery

Every attempt is durably classified as one of three dispositions:

- `definitely_unsent`: the adapter proves that the external effect did not begin;
- `possibly_executed`: the effect may have occurred but no trustworthy terminal result is available;
- `terminal(result)`: the complete typed result is durable.

An exact late result may refine `possibly_executed` to `terminal(result)` while its operation remains incomplete. The first terminal result committed for an operation completes it. A later result from another attempt remains evidence but cannot complete or advance the operation again. Retry always creates a new attempt identity; transport and agent layers never retry the same attempt independently.

Recovery depends on the effect class:

| Effect | Recovery after `possibly_executed` |
| --- | --- |
| Model inference | A new attempt is permitted; duplicate provider work or billing is possible and reported. |
| One-file patch | Classify the file as preimage, postimage, or divergent; retry from the preimage only after authorization under the resumed invocation's selected permission mode, accept the observed postimage, and stop on divergence. |
| Bash | Never retry automatically; complete with an indeterminate result because the command may have external effects. |

Persistence ordering cannot make arbitrary external effects exactly once. Reconciliation and explicit uncertainty are part of the normal operation lifecycle, not exceptional telemetry.

### Model dispatch

```text
core selects ordered durable context handles
-> reconstruct provider request deterministically
-> persist request intent and digest
-> serialize and validate request
-> append and sync attempt identity
-> admit provider delivery
-> record definitely_unsent, possibly_executed, or terminal result
-> stream volatile sanitized preview if desired
-> spool complete response
-> persist terminal result
-> offer completion
```

Verification builds reconstruct the request from durable records and compare it with the dispatched bytes. A model retry creates a new attempt under the same operation. Possible duplicate billing is part of durable result accounting rather than hidden by an exactly-once claim.

### Consequential tools

```text
decode
-> structural validation
-> repository and resource validation
-> determine authority
-> dry run
-> publish approval-required projection
-> receive digest-bound decision
-> persist approved intent
-> append and sync attempt identity
-> execute immutable descriptor
-> persist typed result
-> offer completion
```

Approval never causes the host to decode mutable model text again. Bash uses the consequential-effect recovery class: permission applies to one exact immutable call, and ambiguous execution is indeterminate rather than automatically replayed.

## Internal seams and adapters

These seams are private to the harness implementation.

### Model port

Dependency category: true external.

Adapters:

- Codex subscription access for live inference.
- Fixture model that validates the exact model-visible history before returning each response.

The adapter consumes one already-accepted typed request. It receives an append-only candidate writer and synchronously returns one typed candidate-or-failure outcome. The Host alone seals or replaces the unpublished draft and later publishes Completion evidence. The adapter cannot call the core or publish Session authority.

Codex-specific SSE framing, first-terminal policy, status agreement, OAuth diagnostics, and the one-frame allocation-free JSON cursor remain inside the Codex adapter. They do not appear in the model port. A future adapter may combine many wire events or use its own bounded Host-owned scratch while returning through the same synchronous candidate-or-failure settlement seam. Authorization and model transports use the same deadline-owned native HTTP pattern: timeout interrupts the owned socket and the request task is joined before return.

The consolidated protocol, credential, retry, bounds, history, and go/no-go decision is recorded in the [Codex subscription feasibility result](../research/codex-subscription-feasibility.md).

### Durable store port

Dependency category: local-substitutable.

Adapters:

- File journal, blob spool, and atomic checkpoint publisher.
- Temporary fault-injecting store for deterministic durability tests.

The store interface exposes semantic publications, not raw file calls to the harness caller.
Crash-left provisional `.blob.tmp` writers are not semantic publications. They live in a wholly owned flat scratch namespace, separate from sealed history. After the Session lock establishes a new ownership epoch, startup validates and removes at most 16 exact draft files—sixteen times V1's single live writer capacity—and fails before deletion on excess or unexpected entries. Complete sealed blobs remain recoverable for later admission.

### Tool execution port

Dependency category: local-substitutable.

Adapters:

- Bounded Bash execution and guarded one-file `apply_patch` using controlled Git mechanisms.
- Deterministic or fault-injecting adapter for narrow lifecycle tests.

The anchor black-box test uses the real local adapter in a temporary Git repository.

### Projection consumption

The harness returns projections instead of calling a UI callback. The CLI renders them; tests record them. There is no UI callback capable of reentry or rolling back state.

### In-process implementation

The following need no adapter:

- core state reducer and assistant-response parser;
- prompt selection and request reconstruction;
- operation and generation allocation;
- approval digesting;
- completion classification;
- event projection;
- fixed-credit accounting.

Introducing seams for them would expose implementation rather than enable a real alternative.

## Tool and model protocol

The first tool vocabulary is closed:

```text
bash
apply_patch
```

`bash` accepts one bounded command plus timeout metadata and always runs from the bound Workspace through the host's sanitized environment. It covers repository inspection and verification without separate search, read, or verification tools. Resident output is bounded, complete output is spooled, and a `possibly_executed` Bash Attempt is never replayed automatically.

`apply_patch` accepts one unified diff for one regular file. The host stores the exact bytes, validates structure and confinement, checks applicability through controlled Git mechanisms, and submits the immutable call to the same permission gate as Bash. On permission, the host invokes `git apply` with controlled arguments and input; the model never supplies that host command.

The user selects one permission mode for each invocation. `ask`, the default, renders each exact Bash
or `apply_patch` descriptor and accepts an allow or deny decision. `bypass` durably auto-authorizes
each validated descriptor without prompting. Bypass changes only interactive admission: validation,
bounds, durable descriptor binding, patch preimage checks, and effect-recovery rules remain
mandatory. The mode is invocation-scoped and must be selected again on resume; an authorization
already committed for a specific Operation remains evidence, but the Session does not retain blanket
authority for later Actions. OnePage never auto-allows a Bash command because it appears read-only.
Deterministic tests inject exact decisions in `ask` mode and exercise the same descriptor path in
`bypass` mode. Permission changes admission, not the two-tool vocabulary.

A complete assistant response may contain at most one tool call. A valid tool call executes, its typed Result becomes a Conversation Entry, and the harness begins another model turn. Text accompanying a tool call is not final. A complete non-empty response with no tool call becomes the Final Answer and completes the Task turn.

A length-truncated, aborted, errored, empty, malformed, or multiple-tool response cannot authorize an effect or become the Final Answer. The harness returns a bounded protocol failure when recovery is safe and otherwise ends with a failure Outcome.

Adding a tool changes the closed vocabulary, versioned encoding, validation, prompt schema, implementation, and tests. There is no dynamic tool registry in the first harness.

## Memory ownership

- Core mutable state and core-owned scratch: exactly one 64 KiB page.
- Native call stack and executable text: outside the page claim and measured separately.
- Native harness metadata and queues: caller-owned fixed storage, measured separately.
- Task text, conversation entries, request bodies, responses, patches, and command output: durable blobs and bounded windows.
- Tool output: bounded resident tail plus complete durable spool.
- Transport buffers, filesystem cache, subprocesses, and UI: outside the one-page claim and reported separately.
- Sleeping logical agents: durable identity, records, checkpoint, and blob references; no resident object graph.

## Testing strategy

### Highest product seam

Spawn the real command against a temporary broken Git repository and fixture model:

```sh
onepage \
  --repo "$fixture_repo" \
  --model fixture:"$fixture_model" \
  "Fix the failing test"
```

The fixture model verifies the actual request history, inspects and verifies through Bash, requests `apply_patch`, and returns a Final Answer based on real typed Results. It is not a timed transcript. The test decides each exact call through standard input and requires the repository to finish green.

### Harness seam

Open `Harness` with the real one-page core, fixed storage, fault-injecting durable store, and deterministic effect adapters. Test:

- every valid task, tool-call, and Final Answer state transition;
- immediate and delayed completions;
- full and busy admission;
- stale and duplicate generations;
- rejection and stale approval digests;
- partial or length-truncated model output;
- process exit before and after every semantic publication;
- recovery from accepted operations with no resident page;
- exclusive session ownership, stale-owner dispatch rejection, and current-owner reconciliation of a matching late completion;
- explicit resume by session identity;
- crash recovery for every attempt disposition and effect class;
- regenerated approval and terminal projections after restoration;
- cancellation and shutdown races with accepted effects;
- one-file patch reconciliation from preimage, postimage, and divergent content;
- journal-ahead-of-checkpoint reconciliation;
- request reconstruction equality;
- fixed memory across repeated turns.

### Narrow internal tests

Keep mechanical tests for codecs, bounds, checksums, parsers, and the native image layout. Do not reproduce the complete lifecycle in every
internal module test once the harness-seam tests cover it.

## Implementation order

The foundation through the deterministic repair, Host Store, and provider-neutral model contract is complete. Remaining V1 work is organized as risk gates followed by vertical production slices with small review units:

1. Prove the official Codex subscription transport, implement one narrow Provider adapter, and let a real model complete a controlled repair through the existing capacity-one Harness. This happens before QuickJS so the current agent runtime and provider seam receive real-world feedback early.
2. Prove the disposable QuickJS kernel independently, including complete blocked-demand capture and deterministic Promise joins.
3. Build one durable one-Job Run through the bounded foreground advancement engine, keyed Job identity, disposable evaluation, cold-open resume, and committed observation.
4. Extend that path first with Active Credits, fan-out, and deterministic whole-blocked-set barriers, then with Workspace effect fencing.
5. Add durable interactions and stabilize the complete Run Service and CLI contract.
6. Carry the already-proven Codex adapter into the durable Workflow Run path, measure supported transport concurrency, and run the opt-in live repair through that final architecture.
7. Produce density evidence, package the deterministic demonstration, and run the residual recovery and declaration-coverage gates.

Host Store maintenance, generalized scheduling, provider and OAuth frameworks, custom SQLite VFS testing, and terminal infrastructure are post-V1 or rejected until a concrete consumer exists.

Every stage must leave a vertically executable command or test. Avoid horizontal registries, plugin frameworks, and unused protocol variants.

## Consequences

### Benefits

- The common user and the black-box test run one command.
- Callers cannot bypass durable ordering or mutate the core directly.
- The harness interface remains three operations while hiding the full agent lifecycle.
- Existing fixed-credit, crash-recovery, and checkpoint work deepens rather than being wrapped by a second orchestrator.
- Deterministic and live inference exercise the same model port and core loop.
- The design can add a caller-owned page pool later without changing the product interface.

### Costs

- `Harness` has a broad implementation and needs strong internal locality.
- Caller-owned storage makes `open` configuration exacting.
- `drive` may synchronously wait for semantic durability barriers.
- The process interface is not an embedding interface.
- One active effect and a two-tool vocabulary limit flexibility intentionally.

These costs are desirable in the first implementation. A second real client or tool should create the evidence for another seam; hypothetical flexibility should not.
