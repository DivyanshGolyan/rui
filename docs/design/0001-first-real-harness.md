# First real harness design

Status: accepted for the first coding-task loop

Related specifications:

- [Build the first real one-page coding-agent loop](https://github.com/DivyanshGolyan/onepage/issues/2)
- [Make active capacity runtime-configurable and population-independent](https://github.com/DivyanshGolyan/onepage/issues/3)

Research basis:

- [`fx-pi-harness-lessons.md`](../research/fx-pi-harness-lessons.md)
- [`deepseek-harness-lessons.md`](../research/deepseek-harness-lessons.md)
- [`ghostty-lessons.md`](../research/ghostty-lessons.md)

Domain language:

- [`CONTEXT.md`](../../CONTEXT.md)

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

- The agent policy core has exactly one initial and maximum 64 KiB WebAssembly page.
- The core owns task phase, context selection, action interpretation, approval state, retry decisions, and termination.
- The native host supplies bounded mechanisms and may not infer the next agent action.
- One logical agent, one resident execution slot, one model operation, and one tool operation are sufficient for the first coding-task loop.
- Every operation follows submitted → accepted → completed.
- Accepted work can outlive the process and does not require a resident page.
- No callback reenters the core.
- Immediate and deferred completions follow the same path.
- Large payloads live in durable storage and cross the core interface through bounded windows and generation-tagged handles.
- Partial model output cannot authorize an effect.
- Mutations and commands require approval bound to the exact immutable operation descriptor.
- The first design must leave room for runtime-configurable slot capacity without implementing it yet.

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

This is attractive for several simultaneous clients: terminal, structured JSON, editor, and a future scheduler. It also gives clients durable cursors and explicit blob reads.

It is premature for the first task. No second real client currently needs the event and blob protocol, and exposing it would make callers understand five lifecycle concepts before the core loop has proved useful. A convenience facade would then be required for the common case.

Decision: reject for v1. Reconsider only after a second real client cannot use the process interface or `Harness` projections.

### 3. Process-level task invocation

Interface:

```text
onepage [--repo PATH] --model PROVIDER:MODEL TASK
onepage [--repo PATH] --model fixture:PATH TASK
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
  --model openrouter:MODEL \
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
- Open the durable task directory.
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

`open` borrows caller-owned fixed storage and adapters. The harness allocates no capacity after opening. The caller owns adapter and backing-storage lifetimes.

`offer` is the only producer-to-owner transfer. It performs no I/O, allocation, wait, or core call. Ownership transfers only when it returns `queued`.

`drive` is the only owner-thread transition entry point. It is non-reentrant and processes at most the configured transition and projection quanta. It may pay bounded durability latency.

Shutdown is an input followed by driving to `closed`; it is not a fourth lifecycle method.

### Input

```zig
pub const Input = union(enum) {
    start_task: TaskInput,
    completion: Completion,
    approval: ApprovalDecision,
    cancel: AgentIdentity,
    shutdown,
};
```

`TaskInput` is copied into fixed ingress storage before `offer` returns `queued`. Oversized input is rejected as a disposition.

`Completion` contains only stable identity, generations, a typed disposition, and a durable result reference. Large provider and tool bodies never enter the completion ring.

`ApprovalDecision` contains the agent and operation generations plus the digest of the descriptor and bytes displayed to the user. A stale or mismatched decision cannot authorize an effect.

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

Ordinary model, tool, approval, timeout, cancellation, and verification failures are typed durable results. `drive` errors are reserved for corruption, impossible state, adapter contract violation, failed durability, or an unreconciled transition that makes continued ownership unsafe.

### Offer dispositions

```text
queued
full
busy
closed
invalid
too_large
unavailable
```

`full` and `busy` leave ownership with the producer. `unavailable` means the current owner has failed stop and must be reconstructed.

## Authoritative ordering

### Starting an effect

```text
core publishes immutable submitted descriptor
-> publish submitted checkpoint
-> validate authority and resource bounds
-> append and sync accepted record
-> advance core to accepted
-> publish accepted checkpoint
-> admit effect to its adapter
-> release page at a quiescent yield
```

The adapter cannot observe an operation before durable acceptance. A slot cannot be released while its only copy of a submitted operation remains in the page.

### Completing an effect

```text
adapter spools complete bounded result
-> offer stable completion
-> restore and generation-check page
-> classify journal plus slot state
-> append and sync completed record when needed
-> apply completion through core ABI
-> publish completed checkpoint
-> expose committed projections
-> release or continue page
```

A journal-durable result absent from the page applies once without a second append. A duplicate is consumed idempotently. A stale generation never mutates state.

### Model dispatch

```text
core selects ordered durable context handles
-> reconstruct provider request deterministically
-> persist request intent and digest
-> serialize and validate request
-> admit provider delivery
-> mark delivery definitely_unsent or possibly_sent
-> stream volatile sanitized preview if desired
-> spool complete response
-> persist terminal result
-> offer completion
```

Verification builds reconstruct the request from durable records and compare it with the dispatched bytes. Transport and agent retry ownership are explicit; both layers cannot retry the same attempt.

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
-> execute immutable descriptor
-> persist typed result
-> offer completion
```

Approval never causes the host to decode mutable model text again.

## Internal seams and adapters

These seams are private to the harness implementation.

### Model port

Dependency category: true external.

Adapters:

- OpenRouter for live inference.
- Fixture model that validates the exact model-visible history before returning each response.

The adapter consumes one already-accepted typed request and finishes by publishing one durable result. It cannot call the core.

### Durable store port

Dependency category: local-substitutable.

Adapters:

- File journal, blob spool, and atomic checkpoint publisher.
- Temporary fault-injecting store for deterministic durability tests.

The store interface exposes semantic publications, not raw file calls to the harness caller.

### Tool execution port

Dependency category: local-substitutable.

Adapters:

- Bounded local repository search, read, guarded patch, and verification process execution.
- Deterministic or fault-injecting adapter for narrow lifecycle tests.

The anchor black-box test uses the real local adapter in a temporary Git repository.

### Projection consumption

The harness returns projections instead of calling a UI callback. The CLI renders them; tests record them. There is no UI callback capable of reentry or rolling back state.

### In-process implementation

The following need no adapter:

- core state reducer and action parser;
- prompt selection and request reconstruction;
- operation and generation allocation;
- approval digesting;
- completion classification;
- event projection;
- fixed-credit accounting.

Introducing seams for them would expose implementation rather than enable a real alternative.

## Tool and model protocol

The first action union is closed:

```text
search
read
propose_patch
verify
finish
stop
```

Exactly one action may be selected by a complete assistant response. A length-truncated or otherwise incomplete response authorizes nothing and produces a typed protocol failure.

Search and read are read-only. Patch and verification require exact approval. Each action has explicit field, nesting, path, byte, result, and execution bounds.

Adding an action changes the closed union, versioned encoding, policy validation, prompt schema, implementation, and tests. There is no dynamic tool registry in the first harness.

## Memory ownership

- Core mutable state and core-owned scratch: exactly one 64 KiB page.
- Native harness metadata and queues: caller-owned fixed storage, measured separately.
- Task text, transcript, request bodies, responses, patches, and command output: durable blobs and bounded windows.
- Tool output: bounded resident tail plus complete durable spool.
- JavaScriptCore, transport buffers, filesystem cache, subprocesses, and UI: outside the one-page claim and reported separately.
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

The fixture model verifies the actual request history, chooses search, read, patch, verify, and finish based on real typed results, and is not a timed transcript. The test approves the exact patch and command through standard input, then requires the repository to finish green.

### Harness seam

Open `Harness` with the real one-page core, fixed storage, fault-injecting durable store, and deterministic effect adapters. Test:

- every valid task/action state transition;
- immediate and delayed completions;
- full and busy admission;
- stale and duplicate generations;
- rejection and stale approval digests;
- partial or length-truncated model output;
- process exit before and after every semantic publication;
- recovery from accepted operations with no resident page;
- request reconstruction equality;
- fixed memory across repeated turns.

### Narrow internal tests

Keep mechanical tests for codecs, bounds, checksums, parsers, and the Wasm contract. Do not reproduce the complete lifecycle in every internal module test once the harness-seam tests cover it.

## Implementation order

1. Replace the synthetic core event accumulator with the closed task/action state machine while keeping the one-page verifier green.
2. Deepen the current harness and durable transition adapter into the accepted `open` / `offer` / `drive` interface.
3. Add semantic journal records and durable blob references required by one model request and one search result.
4. Add the fixture model and CLI for task → search → finish.
5. Add bounded read and a second model turn.
6. Add patch validation, digest-bound approval, and guarded application.
7. Add verification process execution, output spooling, and finish.
8. Add OpenRouter transport behind the model port.
9. Add crash injection across the now-real model, approval, patch, and verification boundaries.
10. Implement runtime-configurable active capacity from issue #3 using measured sizes and wait states.

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
- One active effect and a closed action union limit flexibility intentionally.

These costs are desirable in the first implementation. A second real client or action should create the evidence for another seam; hypothetical flexibility should not.
