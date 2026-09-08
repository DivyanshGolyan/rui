# Workflow generations and dependency publication

Accepted workflow behavior and transaction responsibilities, consolidated 8 September 2026. Exact schema and file representation remain implementation choices; this is not a production recovery guarantee. [Choose workflow reevaluation eligibility and wake-ups](https://github.com/DivyanshGolyan/onepage/issues/114) records acceptance; the [closeout review](workflow-114-resolution.md) distinguishes the settled design from remaining implementation and qualification. See the [branch trace](workflow-branch-progress.md) and [readiness comparison](workflow-readiness-comparison.md).

## Information that must remain distinct

| Information | Consumer |
| --- | --- |
| Run-local call key, operation kind, complete inputs and original result binding | Equal replay recovers the same creation/configuration/message operation; changed binding conflicts. |
| A generation's immutable result visibility | The live evaluator receives fixed input; recovery captures a fresh view. |
| Latest published unresolved dependencies | Polling identifies results that permit further evaluation. |
| An admitted unfinished generation versus the latest published generation | Recovery replaces interrupted evaluation; publication changes the dependency basis only when complete. |

These are existing semantic responsibilities. Two Run references may make the last distinction explicit, or constrained generation records and indexes may derive them. Do not additionally store duplicate lifecycle flags merely to mirror the references. This note does not freeze SQL column names.

## Accepted recovery: capture a fresh view

After a Host crash, abandon the interrupted evaluation and start from source with currently available original keyed results. If G2 saw A while B was pending, and B finished before restart, replacement G3 sees both. An already submitted verifier is reused by its key. Changed inputs under that key conflict. No result is injected into a running evaluation.

The earlier sparse first-visible-generation proposal served reconstruction of historical views and is superseded. Do not add those markers solely for recovery. The accepted on-demand input direction captures fixed membership and then materializes immutable bodies outside that read transaction. Native lookup uses explicitly inherited read-only input descriptors; exact directory/file layout remains a candidate. It may be discarded on interruption. Original result ownership and typed availability still distinguish missing results, stable failures and successful null values.

## Creation and configuration

The staged implementation mapping treats creation/configuration acknowledgements as keyed results too. A newly discovered call is admitted by the Host after evaluator output validation. Its Promise resolves in a subsequent generation that includes the saved acknowledgement. A new Session ID therefore becomes available before that later evaluation submits messages to it. A configuration call recovers its original acknowledgement; replay does not repeat a newer configuration mutation.

The ID-based interface example declares `createSession` as `Promise<SessionId>` and awaits it; its historical per-message schema options are superseded. See [the interface evidence](workflow-interface-round2/b-data-functions.md). Current [Workflow Runs](../../ARCHITECTURE.md#workflow-runs) and ADR-0014 still require disposable evaluation against a fixed input. Resolving new calls in a later generation fits that shape without a bidirectional Host RPC inside the evaluator. This staged treatment follows fixed-input evaluation and post-evaluation admission; it is not passing reusable-Session integration or a newly selected configuration acknowledgement shape.

These extra evaluations need not wait for the one-second idle timer: publication can leave a now-completed acknowledgement among the unresolved dependencies, making the next pull immediately eligible.

## Three transaction responsibilities

1. **Fresh-generation admission:** validate Run/cancellation/evaluation identity and establish G. Replacement admission atomically supersedes the interrupted evaluation; rollback leaves it discoverable for another recovery attempt. Capture fixed membership in a subsequent read view, which defines result inclusion independently of the admission timestamp. Materialize those retained original results outside that read transaction; preserve no historical inclusion metadata.
2. **Keyed operation admission:** use each creation/configuration/message command's existing atomic binding and effect/admission contract. Several commands may commit separately and interleave as already permitted. A fresh evaluation after a crash recovers equal keys rather than applying the operations again. Validate complete evaluator output before publishing its effects; generation/cancellation checks fence stale output.
3. **Generation publication:** publish a complete validated outcome/dependency basis and change the Run's published generation atomically. Do not expose a partial dependency set. An unresolved key is judged against G's captured view, so it stays in the published set if its answer completed after that view was captured. The next pull finds the answer from current facts.

Creating/configuring a Session still commits its acknowledgement with its owned mutation. A message binds its original work at admission and gets its immutable answer later. Logical request deduplication does not promise exactly-once provider or tool effects.

This separates command atomicity from generation publication rather than making all discovered calls one giant transaction. The accepted validation/failure ordering is complete prevalidation, independent fenced admissions preserving committed prefixes, then atomic final publication. Implementing that sequence still requires bounded-memory handling of a large dependency publication. Large admission/publication transactions may occupy the Storage Owner for significant time; streaming alone does not shorten them.

## Small relational model evidence

The [executable model](../../research/workflow-readiness/generation_model.py) and [recorded output](../../research/workflow-readiness/generation-model-results.json) check fixed live visibility, fresh recovery with newer results, reuse/conflict of partially admitted keys, replacement rollback, stale publication fencing, dependency publication races, recovery without new results, and cancellation/terminal fencing.

This is an abstract Python SQLite fixture, not production JavaScript or a process-crash harness. Pending sets are supplied by the fixture. Fixed inputs are small in-memory dictionaries for convenience, not a bounded production snapshot design. Result owners stand in for typed Session acknowledgement/Turn outcome ownership. The fixture does not establish actual Session mutation atomicity, external effects, exhaustive interleavings, large fan-out, power-loss safety or production resource guarantees.

## Accepted selection policy

Select the oldest eligible Run by creation time with a stable identity tie-breaker. Finish its evaluation/publication or failure cleanup, service other Host work, then immediately query again. Wait asynchronously for one second only when no Run is eligible. There is no rotating cursor, sweep bound or ready queue. This supersedes the earlier unselected rotating-scan candidate.

Evaluations should take milliseconds while Turns take seconds to minutes. A throwaway SQLite query and loop probe supports this baseline under that workload assumption. With a modeled 20 ms lifecycle, 100 Runs with two-second Turns and 1,000 Runs with minute-long Turns each serviced every Run. A simultaneous 1,000-Run burst drained in 20 seconds of modeled evaluation work. These are conditional virtual-time traces, not measured evaluator throughput. The real asynchronous timer fixture started two ready Runs 24.7 ms apart and kept its independent heartbeat running.

The candidate query scanned 1,000 waiting Runs with one dependency in 0.574 ms median CPU, and 100,000 in 59.077 ms. Sixteen dependencies increased the 1,000-Run scan to 4.115 ms. A one-second timer does not make arbitrary dependency populations cheap. Sustained overload can also starve younger Runs even when each Turn is much slower than one evaluation; this is an explicit qualification limit, not a reason to introduce another scheduler now. Full evidence is on local prototype branch `codex/workflow-oldest-loop-probe`, under `research/workflow-oldest-loop/`.

## Accepted design and remaining implementation

Fresh evaluation after interruption and independent keyed admissions followed by atomic generation publication are accepted. Exact acknowledgement values remain with #101. Concrete representation, bounded fixed-input capture, dependency publication cost and query/service qualification are implementation work under the existing owners. The accepted authoring contract requires stable source-derived keys and inputs, with stable-order explicit joins for cross-branch requests. Equal-key conflicts are enforced; arbitrary completion-sensitive shared mutation is not made deterministic or comprehensively detected. No historical promise-delivery log or mutation-policing mechanism is selected.

## Input capture prototype follow-up

The local throwaway branch `codex/workflow-input-capture-probe`, commit `bb7a6ea7fdfe521081ec3759cfb8e594694bde63`, contains `research/workflow-input-capture/README.md`, runnable C/JavaScript/Python and raw results. It uses pinned QuickJS and SQLite with a temporary input file and ordinary answer Map. Ninety evaluations produced 84 correct successes and six explicit allocation failures without partial publication. The approximately 8 MiB small-record fixture succeeded, while a similar serialized total in larger records exhausted the engine allocation limit. Separately committed new request admissions dominated measured time; Host service between commits remains integration work.

These are warm synthetic measurements, not production qualification or a selected lazy-input design. Capture/parser buffers still materialize a complete result record, and all visible answers remain in the engine map. Production large-record streaming, scratch lifecycle, actual control service, cancellation/recovery and fair selection remain open. No accepted resource limit changes follow from the prototype.

## Accepted consultation follow-up

The user selected on-demand decoding without a bridge-owned decoded-answer cache. Separate invocations return independent deserialized objects; reawaiting one Promise preserves identity. Keep immediate available-result delivery, independent keyed admissions with real Host service between them, read-only equal replay, complete prevalidation and atomic final publication. The owning contract now permits narrow metadata capture and native read-only input descriptors. A two-file immutable directory/body representation is the next prototype candidate, not a required public format. Full-text parallel and sequential consumers must distinguish unnecessary retention from genuinely simultaneous JS values.

## On-demand prototype evidence

The local throwaway branch `codex/workflow-lazy-input-probe`, commit `c57dd39b082a64f16b759cebbbbb3c4539650b4b`, contains the report, source and raw measurements in `research/workflow-lazy-input/`. A fixed on-disk directory and bodies, inherited read-only handles and native lookup removed eager decoding without changing immediate available-result delivery. The approximately 8 MiB large-record sequential fixture succeeds with about 0.5 MiB peak engine backing allocations where eager loading fails; its parallel counterpart still fails. The approximately 16 MiB sequential case also succeeds, with about 4.6 MiB backing allocations, while the selective case decodes only two answers. Backing allocation includes engine arena/allocator effects and is not the 16 MiB internal accounting counter or whole-process footprint. Lookup adds CPU when all results are reached; all captured bodies are still copied.

Nine assertion groups cover fresh-object/Promise identity, exact keys and result types, after-capture completion, prevalidation conflict, truncated input, CPU/elapsed limits, control and settlement service, real process-kill recovery after four admissions, and cancellation/generation fencing. The controlled memory sweep has 48 invocations: 32 successful publications and 16 evaluation failures without admission, including two generic null-reason failures not attributed to a proven specific resource cause. The service comparison acknowledges its synthetic control after four admissions rather than after all 1,024. It is not production p95 qualification.

This prototype keeps one full encoded result for conversion and one full encoded request record for validation, implements no aggregate scratch charge or actual Session mutation, and does not qualify arbitrary large records, retention/GC, parent death during evaluation or full effect recovery. Main production code is unchanged. The accepted direction has evidence; exact representation hardening, native conversion and fair query/service integration remain implementation/qualification work.

## Accepted authoring example

Accepted 8 September 2026. If only scanner B is visible, a shared completion counter can assign B's verifier `verify:0`. When a later evaluation sees both scanners, A can take `verify:0` instead. Existing binding prevalidation rejects this changed request. Keys such as `verify:B:0` and `verify:A:0`, using stable scanner identities and positions within their original recorded findings, preserve the intended bindings in both views. Inputs must follow the same rule; a stable key alone does not fix completion-sensitive request content.

A small Node.js Promise trace executed these two visibility cases and asserted both the counterexample and preservation with source-derived keys. It is a JavaScript illustration, not production QuickJS/Host integration evidence. Production coverage is required by VERIFICATION.md. The runtime need not detect an erroneous distinct new key as a replay conflict; authors own that correctness.

## Accepted completion boundary

Accepted 8 September 2026. The returned value or Promise owns workflow completion; there is no separately constructed dependency DAG. A pending root uses the complete encountered unresolved-call set for conservative discovery. A fulfilled root proceeds through descriptor validation/admission and terminal publication without waiting for unrelated unresolved calls. Already admitted Session work continues, but JavaScript continuations are discarded with the evaluator and no later result reopens the Run. The existing rejection, validation, cancellation and generation-fence paths still apply. See ARCHITECTURE.md Workflow Runs and VERIFICATION.md; this documents the accepted behavior, not implemented evaluator/protocol conformance.
