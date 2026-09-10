# OnePage: transactional Session core and Workflow Runtime

Consolidated 2026-09-09 for [architecture comparison #119](https://github.com/DivyanshGolyan/onepage/issues/119). The constituent decisions below were accepted in the architecture discussion. They form the current architecture direction; the final completeness/readiness review remains open and does not follow from this publication alone. Production implementation is not claimed. This record supersedes the assumptions in the earlier unselected architecture sketches, not their historical text.

## Explain it end to end

A client submits a message with an idempotency key. The Session core atomically saves its admission and key binding. Its local loop finds eligible work, reserves one of a fixed number of tracking records, commits an attempt and starts execution. Provider bytes go to scratch. Sequential validation produces a candidate; one transactional function saves its accepted content and meaning. Tool proposals use the same admission/execution/result cycle, with permission where required. The loop waits on OS events or deadlines whenever nothing can progress.

An Edit permission binds one path and a nonempty list of non-overlapping whole-line ranges with before/after text. Lines start at 1, with no columns; Bash supplies reads and no dedicated Read tool is required. Save and display the submitted proposal without a required target read. After authorization, check every range against the same pre-edit file state before mutation; any mismatch rejects the whole call without changes. Different files use separate calls. No relocation or whole-file freshness requirement. Execution builds checked output in charged unlinked scratch, then copies back through the same opened target handle, sets final length and flushes. Failure after mutation may mean partial changes. After a crash, an uncertain tool attempt becomes indeterminate and is never replayed automatically. The model can inspect and propose new work. Model requests retain their separate bounded replacement policy and frozen inputs.

Workflow Runtime is an ordinary client of this core and the public owner of the complete Run lifecycle. It saves a call's Run-scoped idempotency key and inputs before submission, then saves the answer separately. Lost answers are recovered by repeating the same request. Its private disposable JavaScript evaluator restarts from source and receives recorded results rather than repeating admissions. The runtime supplies fixed evaluator inputs and receives requested calls plus an outcome; JavaScript alone decides branch progress and joins. The evaluator never waits for requested Session work or receives live replies. See the [accepted boundary](evaluator-coordinator-boundary.md).

Session references are constructed by callers without core work. The first complete configuration establishes the durable Session; later updates apply in admission order. Configuration acknowledgement follows commit without model work, while message admission and final output remain distinct. No separate creation operation, generated-ID discovery or creation-reference resolver is required. Run-state inspection shows associated durable Session keys with identifying context; an agent can write an exact key unchanged into a later workflow to continue its current conversation. This requires no workflow-output metadata, previous-Run lookup or snapshot restore. Session keys and per-call request keys remain distinct; see the [accepted initialization decision](session-initialization-proposal.md).

Explicit instruction updates are preserved in model-visible history in order. A -> B -> A includes B and the second A; OnePage does not coalesce them. The next fresh assistant-response request includes all pending updates atomically, while existing requests and retries keep their frozen inputs. See the [instruction-history decision](instruction-update-history.md).

## Boundaries and ownership

| Part | Owns | Does not own |
| --- | --- | --- |
| Session core | Sessions, Conversation, settings, request bindings, permissions, Operation-owned current execution and final results; one transactional function per meaningful mutation | Run identity, workflow replay or workflow cancellation propagation |
| Execution loop and modules | Fixed tracking records; provider connections, Bash processes, Edit mechanics, scratch and cleanup | Durable workflow meaning or direct caller rendering |
| Workflow Runtime | Complete Run lifecycle, call intents/results, private evaluator lifetime/inputs/eligibility, unresolved-call records and cancellation sequence | A second branch/join interpreter, core-table access or tool retry policy |
| Private evaluator within Workflow Runtime | A bounded invocation of workflow code against supplied facts; JavaScript branches, joins and outcome | Durable heap, live storage/network access, Session execution or a public lifecycle |
| Local adapter and clients | Wire encoding, input/output presentation, retaining caller retry identity | SQLite internals or runtime advancement |

Workflow Runtime encapsulates its evaluator rather than exposing it as a peer module. The private computation interface and existing disposable child-process containment remain required. The initial server remains explicitly started and independent of CLI connections. Core and workflow persistence have independent transactions; one or multiple database files is not selected. Preserve [ADR-0026](../adr/0026-let-operations-own-current-execution-and-final-results.md): each Operation owns its exact request, current execution/retry facts and optional immutable Resolution/content references. Execution Evidence is transient; no durable Completion entity or separate Resolution ID is restored. A shared physical Store cannot become a reason to read another module's tables.

The [Session API contract](session-core-api-contract.md) exposes configure/send, observation/wait, exact permission decisions and Session stop. Existing exact model interruption remains available. An idempotency key binds the first committed admission answer, including rejection; a repeated key with different inputs conflicts. Accepted work can later complete, but the binding never retargets. ETags remain optional and unselected.

## Scheduling and resources

Allocate `active_capacity` content-free tracking records at startup. Neutral records do nothing; reservation, execution and cleanup occupy a record until safe release. Scan the fixed array directly. Select oldest eligible work using durable admission order and indexed bounded queries; permission waits and future retry deadlines do not obstruct younger eligible work. Waiting history lives in SQLite, not per-Session workers.

Handle events, save results, release cleaned-up records, fill capacity, then wait for client activity, provider/process/cleanup events or the next relevant deadline. No database-change watcher is needed. Buffers, TLS, SQLite and evaluator memory retain their separate budgets; static tracking does not mean the whole runtime has static allocation. Large Edit/filesystem work still needs bounded execution mechanics, unlike the measured synthetic neutral scan.

## Failure boundaries

| Boundary | Recovery |
| --- | --- |
| Core admission committed, reply lost | Repeat the idempotency key; recover original acceptance/rejection |
| Workflow submitted, answer not recorded | Repeat its saved submission; record the recovered answer |
| Permission saved, no attempt | Work remains eligible if applicable |
| Tool attempt admitted, no established result | Indeterminate; never replay, even if the crash may have preceded launch |
| Model attempt uncertain | Apply existing retry allowance with frozen request and possible duplicate cost |
| Workflow cancellation | Freeze new calls; resolve unanswered submissions; stop Sessions with accepted message calls; record completion only after required stops |

Submit-then-stop during cancellation can briefly start previously undelivered work and can apply a configuration change that is not rolled back. Session stops can affect other clients sharing that Session, and repeated stops after crashes may select newer work. These are accepted tradeoffs, not exactly-once effects or per-Run isolation.

## Product-promise audit

| Promise | Candidate assessment |
| --- | --- |
| Direct, reusable Sessions and immutable Conversation | Preserved by core ownership; request/result observation still needs wire design |
| Exact permission and honest tool uncertainty | Preserved with approved fixed patch and no-replay amendments |
| Client disconnection and crash recovery | Covered by durable identity/intents; protocol model evidence exists |
| Deterministic workflow replay and joins | Workflow Runtime records completed results and freezes each evaluator's visible set; integrated evidence remains required |
| Run inspection and permission-required reporting | May briefly lag across observations; never determines replay or cancellation completion |
| Faithful provider continuation and output schemas | Existing provider-owned contracts retained; not tested by new protocol models |
| Bounded memory and protected controls | Fixed tracking and OS wait fit; full runtime resource and latency gates remain unexecuted |
| Linux and macOS | Accepted platform mechanisms retained; new runtime measurements are Mac-only evidence |

## Remaining implementation and readiness work

Workflow observation is settled: record completed results through the ordinary core API, freeze each evaluator's visible set, and permit briefly stale progress displays. No globally atomic cross-Session report or batch API is required. The [two-Session walkthrough](two-session-workflow-trace.md) traces submission, joins, lost replies and cancellation. Durable generation mapping, notification/read integration and full resource evidence remain implementation work.

Edit input conventions are settled in the [owning decision](fixed-location-edit-approval.md#range-rules): one-based, start-inclusive/end-exclusive whole-line ranges, explicit newline bytes, EOF insertion and collective validation. Bash supplies reads and file/directory creation; Edit requires an existing file. Proposal display does not require a target read.

Routine implementation work includes canonical input/key encoding, SQL/index layout, result schemas, lost-wakeup-safe event registration, and client key persistence. These must be specified and tested for their slices, but do not need new general-purpose architecture layers. Remaining physical placement choices preserve the accepted evaluator child process, ownership boundaries and resource promises.

## Evidence and comparison

- [Idle-loop experiment](../../research/idle-loop-prototype/README.md): Mac synthetic scan cost and OS-wait CPU/latency; no production reactor proof.
- [SQLite protocol experiment](../../research/session-api-prototype/README.md): separate databases, lost replies and submit-then-stop; synthetic immediate stops.
- [TLA+ model](../../research/request-protocol-model/README.md): 12,420 bounded states, safety and conditional progress, two negative controls; atomic admission and fixed inputs are abstractions.
- [Transactional prior art](../research/transactional-operation-prior-art.md): direct transactional functions, validation separation and post-commit limitations.

Compared with the earlier integrated candidate, this moves workflow ownership behind an ordinary API and pays for saved submission intents. Compared with a pure decision-engine candidate, it keeps state-dependent checks and mutations in one function and tests actual transaction boundaries. It retains a single local execution owner rather than adding per-Session drivers. Independent observation no longer requires a cross-owner snapshot mechanism. Final readiness still requires the cross-module walkthrough and missing provider evidence; implementation must then satisfy the integrated verification gates. Historical records remain explicitly superseded where these accepted decisions replace them.
