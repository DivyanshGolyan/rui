# Effect-failure classification: simplicity-oriented prior art

Research date: 2026-09-02

This note reviews the proposed issue #66 failure classifier against primary-source database,
runtime, retry, subprocess, and agent-tool-loop practice. It is design research, not a normative
decision. Production source changes remain paused.

## Verdict

The proposed policy is directionally sound, but it should not become a six-state runtime machine or
one global lifecycle classifier. The simpler review shape is four **control dispositions**, with
typed reason codes beneath them:

1. `defer_without_attempt` — local capacity is unavailable, so no Attempt is admitted.
2. `reattempt_same_operation` — a completed model Attempt is safe and authorized to retry later
   using the exact Model Request Manifest.
3. `resolve_operation` — select the Operation's semantic result and atomically publish its already
   defined bounded consequence, such as a Tool Result or failed Turn Outcome when no legal
   continuation remains. This research does not define another model-visible input primitive.
4. `stop_host` — the sole semantic store or shared runtime machinery is unusable, so OnePage cannot
   safely admit or settle work.

Cancellation is not a fifth failure disposition. It is a committed Cancellation Intent, a narrow
best-effort request to interrupt physical custody, and eventual settlement of admitted work.

The original six cases remain useful as a policy table, but cases 3, 4, and 6 are all instances of
`resolve_operation`; case 5 needs a narrower definition; and case 2 needs an explicit replay-safety
condition. Implementation keeps these decisions local: admission decides whether to defer,
settlement decides whether to retry or resolve, and Host control decides whether canonical authority
is unusable. This recommendation is an inference from the sources below, not a claim that any cited
system has OnePage's exact domain model.

## Minimal decision table

Each command-specific pure decision should select a fixed relational command, not a lifecycle phase:

| Input fact | Disposition | Fixed consequence |
| --- | --- | --- |
| No Active Credit | `defer_without_attempt` | Insert nothing; Operation remains eligible. |
| Retryable model transport/provider result and retry policy remains | `reattempt_same_operation` | Commit the Attempt Completion and durable `eligible_at`; leave the Operation unresolved. |
| Potentially model-addressable output rejection | `resolve_operation` | Commit Completion + Resolution. #91 must separately decide whether V1 has an existing canonical input that can authorize another Model Operation; do not invent an implicit validation diagnostic here. |
| Definite or indeterminate Action observation | `resolve_operation` | Commit Completion + Resolution + typed Tool Result; the Agent chooses any later Action. |
| Retry/repair/work bound exhausted | `resolve_operation` | Resolve the current Operation and commit a typed failed Turn Outcome; Session remains reusable. |
| Persistent loss of Host Store usability or fatal shared-runtime invariant | `stop_host` | Admit and launch nothing further; manufacture no Turn outcome; recover from SQLite on restart. |

The reason-code vocabulary remains effect-specific. Reducing dispositions does not erase whether the
observation was a rate limit, timeout, non-zero exit, output overflow, Patch conflict, lost custody,
or corrupt Host Store. It prevents each reason from acquiring its own queue, timer, phase, or state
machine.

## Why these distinctions are necessary

### Capacity deferral is not a failed Attempt

Industry queues distinguish readiness from execution capacity. Oban keeps scheduled or retryable
work durable until its timestamp arrives, then available work still waits until queue capacity can
claim it. Its stager checks durable work every 1,000 ms by default and bounds each staging pass
([Oban job lifecycle](https://oban.hexdocs.pm/job_lifecycle.html),
[Oban staging options](https://oban.hexdocs.pm/Oban.html#module-staging-jobs)).

OnePage needs less machinery because V1 has one Host and SQL is already the authoritative backlog.
An indexed, bounded `eligible_at <= now` query once per second is therefore conventional and
defensible. It does not require Oban's persisted `scheduled`, `available`, or `retryable` phases.
No Active Credit means no Attempt, no Completion, and no error shown to the Agent.

### Retryability is the conjunction of failure class and replay safety

Google Cloud's retry guidance makes this conjunction explicit: transient responses such as 408,
429, 5xx, socket timeouts, and disconnects are candidates for retry, but retry safety also depends
on idempotency; permanent authorization or configuration failures require a changed request
([Google Cloud retry strategy](https://docs.cloud.google.com/storage/docs/retry-strategy)). AWS's
standard SDK policy similarly retries only selected transient errors, bounds total attempts, and uses
bounded backoff with jitter; its adaptive mechanism is explicitly an advanced rather than general
default
([AWS SDK for Rust retry configuration](https://docs.aws.amazon.com/sdk-for-rust/latest/dg/retries.html)).

For OnePage, `transient` alone is therefore insufficient. A replacement model Attempt is permitted
only when policy accepts possible duplicate provider work or billing and reuses the exact immutable
manifest. Provider idempotency or retrieval should be used when available. Bash and Patch remain
non-replayable by OnePage.

The durable row should store the earliest retry eligibility, not retain a sleeping Turn object.
The fixed bounded Host poll is the sole V1 retry trigger; neither an advisory retry wake, a resident
deadline heap, nor a per-Turn timer carries authority. `eligible_at` must use a documented
UTC wall-clock interpretation because a process monotonic clock cannot survive restart. Clock jumps
are an accepted scheduling tradeoff and should be covered with an injected test clock.

### A changed request is correction, not retry

Stripe's primary idempotency contract returns the first result for an exact key replay and rejects
reuse with different parameters. Its low-level guidance distinguishes intermittent network errors,
which repeat the same request and key, from content errors, which require correcting the request and
using a fresh identity
([Stripe idempotent requests](https://docs.stripe.com/api/idempotent_requests),
[Stripe advanced error handling](https://docs.stripe.com/error-low-level)).

That distinction matches OnePage's Operation boundary. An output-size or known model-output contract
violation should resolve the old model Operation. Whether V1 can then admit another Model Operation
depends on an independently defined canonical input; this research does not manufacture a
validation-diagnostic input. Silently changing the old manifest would turn correction into an
unrecorded retry mutation.

The phrase "model response violates OnePage's contract" is too broad, however. Only a
**model-addressable** rejection belongs here. An unsupported provider wire shape, digest failure,
validator invariant violation, or adapter bug is not something the model can repair; it must be
classified as provider incompatibility or a Host-fatal invariant according to its exact cause.

### Action failures belong in the model-visible tool loop

The Model Context Protocol explicitly distinguishes protocol failures from tool-execution failures.
It recommends returning actionable tool failures with `isError: true` and says clients should provide
them to the language model so it can self-correct
([MCP Tools error handling](https://modelcontextprotocol.io/specification/draft/server/tools#error-handling),
[MCP CallToolResult schema](https://modelcontextprotocol.io/specification/2025-06-18/schema#calltoolresult)).
The OpenAI Agents SDK likewise runs tools, appends their results, and calls the model again; it can
turn an unavailable tool into a `function_call_output` error and resume the model rather than ending
the run
([OpenAI Agents runner loop](https://openai.github.io/openai-agents-python/running_agents/#the-agent-loop),
[model-visible tool errors](https://openai.github.io/openai-agents-python/running_agents/#tool_not_found_behavior)).

This is strong prior art for OnePage's uniform Action rule: a trustworthy observation from Bash or
Patch becomes a bounded typed Tool Result, and the Agent decides whether to issue another Action.
It is not evidence for passing arbitrary exception strings to the model. OnePage must retain stable
codes, safe details, and explicit bounds.

Subprocess APIs also preserve terminal observations rather than converting every non-zero exit into
runtime collapse. POSIX-style `waitpid` reports normal exit, exit status, or terminating signal and
releases child resources; Go's `os/exec.Cmd.Wait` returns an `ExitError` for unsuccessful exit,
distinguishes I/O errors, waits for I/O copying, and releases resources
([Linux `waitpid(2)` manual](https://man7.org/linux/man-pages/man2/waitpid.2.html),
[Go `os/exec`](https://pkg.go.dev/os/exec#Cmd.Wait)). This supports treating spawn failure, non-zero
exit, timeout-after-reap, output overflow, and lost custody as data for settlement rather than reasons
to stop the Host.

"Any Action outcome" must mean any **validly classified Action observation**. An invariant failure in
the shared process supervisor or Patch machinery is not a Tool Result merely because it happened
while an Action was running.

### Host failure is a fail-stop boundary, not a universal SQLite error bucket

The crash-only paper argues that keeping important non-volatile state in dedicated state stores and
making restart run the same recovery path can reduce stop/recovery mechanisms
([Candea and Fox, *Crash-Only Software*](https://www.usenix.org/conference/hotos-ix/crash-only-software)).
This supports stopping and reconstructing the whole OnePage Host when its shared core machinery dies.
It does not imply that an ordinary effect failure or every SQLite return code should crash the Host.

SQLite documents materially different result classes:

- `SQLITE_BUSY` is concurrent database activity for which busy handlers and retry are provided;
  `BEGIN IMMEDIATE` itself can return BUSY, and once it succeeds SQLite guarantees later operations
  through COMMIT on that database will not return BUSY
  ([SQLite result codes](https://www.sqlite.org/rescode.html#busy),
  [transactions](https://www.sqlite.org/lang_transaction.html#deferred_immediate_and_exclusive_transactions)).
- `SQLITE_CONSTRAINT` is the expected mechanism by which `PRIMARY KEY`, `UNIQUE`, and other constraints
  reject a write. The default ABORT policy backs out the failed statement without replacing existing
  rows
  ([SQLite ON CONFLICT](https://www.sqlite.org/lang_conflict.html)).
- `SQLITE_FULL`, persistent `SQLITE_IOERR`, `SQLITE_CORRUPT`, unusable `READONLY`/`CANTOPEN`,
  `SQLITE_NOMEM`, `SQLITE_INTERNAL`, and `SQLITE_MISUSE` indicate loss of storage usability or a core
  invariant and are appropriate fail-stop candidates according to the exact extended code
  ([SQLite result codes](https://www.sqlite.org/rescode.html)).

Therefore the disposition must be "Host Store or shared runtime is unusable," not "SQLite returned an
error." Expected idempotency conflicts, stale revisions, authorization rejections, and bounded busy
handling remain ordinary command results.

## SQLite arbitration and cardinality

The proposed cardinalities are sound:

```text
Attempt   -> zero or one Attempt Completion
Operation -> zero or one Operation Resolution
```

SQLite defines transaction commit as all changes occurring or none, including across OS crash or
power loss under its documented filesystem assumptions
([SQLite atomic commit](https://www.sqlite.org/atomiccommit.html#introduction)). A write transaction is
serialized against other writers, while `PRIMARY KEY` and `UNIQUE` constraints can reject the losing
settlement proposal. Foreign keys can enforce parentage, but they must be enabled on every connection
([SQLite transactions](https://www.sqlite.org/lang_transaction.html#read_transactions_versus_write_transactions),
[foreign-key configuration](https://www.sqlite.org/foreignkeys.html#fk_enable)). If power-loss
durability is promised under WAL, SQLite documents that writers sync the WAL at every commit only
with `synchronous=FULL`
([SQLite WAL durability](https://www.sqlite.org/wal.html#performance_considerations)).

The settlement command should use plain INSERT and explicit comparison, not `INSERT OR REPLACE`:

1. Begin the fixed `BEGIN IMMEDIATE` command and load the bounded canonical snapshot.
2. If no Completion exists, validate and insert it with every same-boundary consequence.
3. If a Completion exists and the settlement identity and digest are identical, return idempotent
   success.
4. If they differ, reject `attempt_already_completed` and discard the transient losing artifact.

SQLite's REPLACE conflict algorithm deletes the pre-existing row before inserting the new one, which
would violate write-once evidence
([SQLite ON CONFLICT](https://www.sqlite.org/lang_conflict.html#replace)). Stripe's idempotency behavior
provides a useful external analogue: retain the first result, return it for the same request, and reject
the same identity with different parameters
([Stripe idempotent requests](https://docs.stripe.com/api/idempotent_requests)).

"First valid commit wins" is safe only when **Completion means one terminal observation**, not a log
of every callback. A timeout or cancellation callback must first end or detach the physical operation
according to its effect contract; merely sending a signal is not terminal evidence. Swift structured
concurrency makes the general point that cancellation is cooperative: it sets a flag and runs handlers,
but control does not leave a structured scope until children actually complete
([Swift structured concurrency](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0304-structured-concurrency.md#cancellation)).
For Bash, the terminal Completion should incorporate the final reap observation. For model transport,
closing/abandoning custody defines what later callbacks may no longer publish. Physical cleanup can
still race; durable semantic settlement cannot.

## Necessary distinctions versus accidental complexity

Necessary:

- no Attempt versus a completed Attempt;
- retrying the exact model Operation versus changing model-visible input in a new Operation;
- observed Completion versus selected semantic Resolution;
- definite Action result versus indeterminate external effect;
- model/tool-local failure versus loss of the sole semantic authority;
- durable Cancellation Intent versus physical interruption and Host shutdown.

Accidental for V1:

- a persisted retry phase in addition to `eligible_at` and canonical facts;
- a resident retry queue, per-Turn timer, sleeping worker, or retained Active Credit during backoff;
- separate state machines for every error code;
- automatic Bash or Patch replay;
- Completion ranking, conflicting-evidence journals, or `INSERT OR REPLACE` settlement;
- an in-process supervisor and ownership-generation protocol for restarting failed shared runtime
  components;
- treating cancellation as an error subclass.

## Edge cases the contract must state

1. **Retry safety is provider-specific.** A timed-out model request may still consume provider work or
   billing. The same-manifest policy accepts that uncertainty; future server-side conversation,
   preserved-reasoning, or compaction identifiers may change replay safety and belong in the provider
   wire-contract research.
2. **Retry scheduling depends on wall clock.** Persist UTC `eligible_at`, clamp provider delays to the
   configured policy, order and index the due query deterministically, and limit it by currently
   available Active Credits. Test forward and backward clock steps.
3. **A retryable Completion must not resolve the Operation.** Once retry policy is exhausted, the same
   transaction must resolve the model Operation and fail the Turn; otherwise the relational graph has
   an exhausted unresolved Operation.
4. **Potentially model-addressable rejection is narrower than validation failure.** #91 must decide
   whether any existing canonical input can carry safe actionable feedback before admitting another
   Model Operation. Provider incompatibility, corrupt content, and runtime invariants take different
   paths; this research adds no validation-diagnostic primitive.
5. **Tool diagnostics are bounded semantic content.** Raw stderr, rejected model output, provider
   prose, and scratch artifacts do not automatically become Conversation entries.
6. **BUSY and constraints are not Host-fatal.** Classify exact SQLite extended codes and distinguish
   expected command rejection from loss of database usability.
7. **Only the effect owner terminalizes evidence.** Timeout and cancellation may signal that owner;
   EOF, process exit, and validation are inputs to its effect-specific terminal path. SQLite rejects
   duplicate or conflicting publication, but it does not choose physical truth among competing
   observers.
8. **The publication contract resolves the earlier drift.** ADR-0019, ADR-0021, and issue #69 now
   constrain Attempt to zero-or-one Completion, reject conflicting replay, and distinguish the sole
   retryable-model Completion-only exception from locally decidable same-transaction settlement.

## Recommendation for Q15

Approve the policy as a review table implemented by local decision points:

> Command-specific pure decisions map bounded canonical facts to one of four fixed outcomes: defer
> without Attempt, complete and durably re-attempt the same model Operation after `eligible_at`,
> complete and resolve with one typed semantic consequence, or stop the Host because canonical
> authority is unusable. Error codes refine evidence; they do not create lifecycle states.
> Cancellation is a separate committed intent protocol.

Keep the six current scenarios as tests of the local admission, settlement, and Host-control
decisions. Do not implement them as one global classifier or as six queues, phases, handlers, or
durable statuses.
