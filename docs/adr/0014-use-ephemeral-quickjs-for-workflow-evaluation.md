# ADR-0014: Use ephemeral QuickJS for workflow evaluation

Status: accepted

OnePage has one agent runtime: the native Zig Host Runtime. It owns every Workflow Run, evaluator
process, Job, Session, provider, tool, permission, durable transition, and resident capacity. V1 also
needs a programmable Workflow Definition that can compose many durable agent Jobs without turning
workflow topology into Host policy.

V1 therefore ships a pinned, unmodified QuickJS-ng dependency as a disposable Host-managed Workflow
Evaluator. The CLI only composes Run Service operations; it does not own the Run or coordinate Jobs. Each
evaluation runs in a fresh subprocess. It evaluates exact stored source from the beginning
against immutable arguments and one run-local snapshot of terminal Job Outputs and stable failures. `agent()` either
reattaches a visible terminal Job or durably ensures a pending Job. At quiescence the evaluator
reports `Completed`, `Blocked`, `Failed`, `Deadlocked`, `ResourceExceeded`, or `ProtocolFailed`, then
exits. For `Blocked`, the Workflow Run durably waits for the complete blocked set to become terminal
before the Host starts a fresh Evaluation Generation. No JavaScript heap, Promise resolver, closure,
instruction pointer, or bytecode survives a Job barrier.

This is reconstructive replay, not continuation checkpointing. Provider completion timing and physical
Job completion order are not observable workflow inputs. V1 exposes deterministic joins through
`Promise.all` and `Promise.allSettled` but removes `Promise.race` and `Promise.any` from the allowed realm. The workflow
semantics identity binds the engine version, allowed intrinsics, runner protocol, exact `{ agent }` capability bootstrap,
value encoding, Job canonicalization, and Workflow Resource Profile. An incompatible identity fails closed.

V1 exposes one built-in Workflow Resource Profile and one built-in Agent Profile, both named `default`;
omission selects them and unknown names fail before durable creation. Run creation also binds the
canonical invocation working directory as the Workspace, and later advancement uses that stored identity.

`agent({ key, task, input, schema, agent_profile })` is the only supplied workflow capability. Its key is
mandatory within a Workflow Run; the same key and canonical Job digest reattach, while a changed
digest conflicts. `agent_profile` selects immutable instructions, exact Model Contract, and Tool
Catalog; it grants no permission or workflow resource. Optional `schema` defines the locally validated
canonical Job Output; without it the Output is Final Answer text. Ordinary JavaScript functions,
loops, arrays, and deterministic Promise joins own composition; V1 supplies no workflow helper API or durable DAG. Each Job owns one
ordinary Session. V1 exposes no model-visible Agent tool.

The evaluator uses a raw allowlisted realm. It has no filesystem, process, network, environment,
credential, wall-clock, randomness, timer, general module-loading, or bytecode capability. Source is
read, bounded, hashed, stored, and supplied by the Host; later advancement never rereads the path. The bridge
accepts only bounded null, Boolean, Unicode-scalar string, array, string-keyed plain object, and finite IEEE-754
number values. Valid UTF-16 surrogate pairs encode as their standard UTF-8 scalars; lone surrogates
are rejected without replacement. Integral numbers must be safe integers and negative zero canonicalizes to zero. It
rejects `undefined`, functions, symbols, bigint, accessors, proxies, cycles, host objects, unsupported
prototypes, lone surrogates, non-finite numbers, unsafe integers, and reentrant conversion. The root must explicitly return one valid value;
the Host commits it as Workflow Output before rendering, while an invalid return fails as
`WorkflowOutputInvalid`.

QuickJS heap, stack, interrupt time, microtasks, native bridge allocation, protocol bytes, visible
Job Output bytes, Job counts, diagnostics, and cumulative evaluations are explicitly bounded by the
stored Workflow Resource Profile. A parent
watchdog and deliberately constructed descriptor and environment tables remain authoritative outside
the engine. These controls are suitable for a single-user local capability-constrained workflow; they
are not hostile multi-tenant isolation.

QuickJS-ng is fetched through Zig's package mechanism at an exact source URL and hash and ships with
its license notice. V1 accepts source only, has no Node or ScriptC fallback, retains no hot evaluator,
and exposes no stable public IPC protocol. A retained runner, trusted external Node client, daemon,
or stronger OS sandbox requires measured demand and a separate decision.
