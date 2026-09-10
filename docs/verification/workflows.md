# OnePage workflow verification

This is part of the normative [VERIFICATION.md](../../VERIFICATION.md) contract. [Corresponding architecture](../architecture/workflows.md) supplies the governing rules.

For evaluator construction or lifetime changes, also run the [evaluator lifecycle checks](../../VERIFICATION.md#evaluator-lifecycle).

## Workflow replay

Required workflow fixtures exercise the public Workflow Runtime and its production private QuickJS boundary, using local `session(name)` references, configuration and messages. Function names/key encoding remain implementation choices; the revised API is not implemented yet. These are required checks, not passing evidence. They cover:

- idempotent Caller Run Key and stored invocation Workspace;
- Run-local configuration/message call keys scoped into distinct core Request Identities, separate from Session keys and internal Turn IDs;
- pure `session(name)` construction with no core calls, generated-ID discovery, durable Session or hidden resource ownership;
- first complete configuration atomically saving Session, baseline and original core request answer without model work; incomplete initialization leaves no partial Session;
- unknown-Session messages saving a definite rejection that same-key retries retain after another request initializes the Session;
- lost configuration acknowledgement recovering the same acceptance without reapplying settings;
- configuration effect and core request answer committing atomically, followed by independently recoverable workflow answer recording;
- fresh configuration of an existing Session applying mutable fields linearly without original-baseline comparison, while immutable Workspace/access violations reject;
- replay of an old configuration operation leaving a later change intact;
- configuration remaining committed after later message failure or a crash before sending;
- another client changing settings between configuration and message admission without an invented stale-view rejection;
- exact full Session keys accepted unchanged for direct reuse across Runs without wrapper, attachment or snapshot semantics;
- first and later messages sharing the same API, with exact schema output and frozen rejection;
- optional Session output schema persisting across messages, with ordinary text when absent and no schema mutation through message options;
- changing or clearing a schema after request A is constructed leaves A and its retries unchanged; the next applicable request uses the new configuration, and replay returns the original result without validating it against current settings;
- provider-boundary fixtures covering supported structured success, unsupported schemas, malformed or schema-invalid output, refusal, and incomplete generation without fabricated success, prose conversion, or automatic model repair calls;
- shared-work message callers receiving the same recorded result under the producing request's schema, without caller-specific schema expectations;
- declaration/configuration alone excluded from the cancellation stop set, while accepted configuration is included in inspection association;
- lost core acceptance before workflow reply recording recovered through the original saved intent;
- evaluator death before and after Turn admission;
- complete unresolved-dependency capture with branch-local progress: scanner A's verifier requests become eligible while unrelated scanner B remains unfinished; an explicit final join still waits for its required results;
- returned-value/Promise completion: a direct unawaited message followed by a valid returned value still includes and admits its descriptor before successful terminal publication, without waiting for its result or stopping its Session; pending root Promises suspend, while fulfilled roots do not wait for unrelated unresolved calls;
- an admitted unawaited message completing later does not reevaluate a terminal Run; an unawaited continuation needing an unavailable result is not retained or executed after evaluator exit; explicit awaits/joins retain required follow-up work;
- returned-root rejection follows the existing failure path; prevalidation, admission failure, cancellation and generation fencing still prevent a false successful Workflow Output, and already committed admissions retain their existing recovery semantics;
- staged fan-out and synthesis, including an empty finding list, branch failure handled by the workflow, and stable per-finding verifier keys across replay;
- completion-order authoring traces: B alone available, then A and B available, preserve verifier identities and inputs when keys derive from scanner/finding identity; a completion-sensitive shared counter reusing a key with different inputs fails prevalidation; stable-order joined inputs remain equal across reevaluation. Do not claim these checks detect mistakes that generate distinct new keys or prove arbitrary JavaScript mutation deterministic;
- the [branch-progress crash traces](../design/workflow-branch-progress.md): saved result before the next pull, results arriving during evaluation/publication, request commit before acknowledgement, and duplicate discovery without duplicate keyed admission; prove live and restart discovery without retaining waiting JavaScript heaps;
- the asynchronous pull loop admitting another ready Run after evaluation cleanup without a mandatory one-second gap, and arming one shared one-second timer only after no eligible work is found;
- model/tool I/O, controls and settlements making progress during evaluator and timer waits; measure the separate non-preemptible Storage Owner lookup cost;
- startup finding new, suspended-now-eligible and interrupted-generation work through their distinct saved facts; abandon the interrupted generation and capture a fresh view, even without a newly finished dependency; reject cancelled/terminal or stale admission;
- core results obtained and saved through ordinary APIs, including lost observation replies; workflow-recorded results committing before dependency publication and during evaluation remain discoverable by subsequent pulls, without a core-table join, mandatory completion notification, pending completion-ID queue or maintained ready set;
- considered results no longer causing unchanged reevaluation after publication, while a partial join may be reevaluated on a newly available result;
- no per-waiting-Run heap/callback/timer, accumulated missed ticks, or resident materialization of all candidate Runs; verify oldest-eligible selection with stable creation-time ties, immediate rechecks, and seconds-to-minutes Turn completion traces; distinguish ordinary service from sustained evaluator overload rather than claiming unconditional starvation freedom;
- deterministic `Promise.all` and `Promise.allSettled`;
- absence of `Promise.race` and `Promise.any`;
- crash recovery after partial keyed admission: fresh evaluation sees results finished during downtime, reuses committed operations, rejects changed bindings, and cannot publish abandoned-generation output; rollback of replacement admission leaves recoverable interruption, while committed dependency/output publication remains authoritative;
- fixed visibility during each live evaluation without requiring historical snapshot reconstruction or per-call first-visible markers;
- on-demand lookup without eager decoded results or a bridge-owned decoded-answer cache; measure native key/index storage separately; compare selective, sequential and parallel consumers, forward actual finding text into requests, and measure decoded bytes, allocation peaks and simultaneous physical footprint without assuming arbitrary user-held values fit;
- separate same-key calls receiving independent object values while repeated awaits of one Promise retain identity; mutation of one returned object never changes the saved outcome or a subsequent call's value;
- fixed saved-result membership capture followed by result-body materialization from captured immutable references, including a result committing between those phases; prove retention through existing owners, bounded native key comparison and content windows, exact non-ASCII/prefix/long keys, and distinct missing/null/failure outcomes;
- narrowly inherited read-only snapshot descriptors, closure of writable handles before spawn, no JS-visible filesystem/storage capability, and explicit failure for invalid ranges, short reads, lost captured content, allocation/CPU/deadline exhaustion and orphan-handle cleanup;
- full validation and known-key conflict detection before new submission intents, call-input capture before later JS mutation, repeated-key consistency and read-only equal replay; workflow transactions recheck cancellation/generation, while independent core admission checks request identity and Session applicability without Run-aware fencing;
- control, due cleanup and settlement service between bounded admission/validation/materialization stages, without a mandated manual-yield parser or extra worker; release active statements and borrowed workspaces before a service turn, measure non-preemptible calls/publication, kill after a committed prefix, reopen into fresh evaluation, recover original bindings without reapplying configuration, and atomically publish the complete next dependency set;
- final Workflow Output idempotency;
- actual allocation, transfer, CPU and lifetime bounds across source, arguments, results and repeated evaluation; and
- no JavaScript continuation or evaluator process retained at a barrier.

Qualify idle polling and busy selection using actual generation/dependency queries on the pinned SQLite build: empty Store, direct Sessions with no workflow dependencies, many waiting Runs with no ready work, shared-result fan-out, historical result growth and sustained independent pipelines. Record CPU, examined rows/VM work, lookup/owner time, memory and control latency. The [readiness probe](../../research/workflow-readiness/README.md) is a warm small-schema experiment, not passing Host evidence or a selected index set. Its one-second CPU extrapolation does not replace the accepted idle-CPU target.

Two workflow calls in one Workspace prove that independent Bash and Edit Operations may progress concurrently under Active Capacity, completions settle without sibling head-of-line blocking, and filesystem interference is reported as observed evidence rather than prevented by a Host fence. Fixtures prove Bash and Edit use the same Action lifecycle without a permanent Edit lane or global serialization.

## Run interface

Golden and hostile-input tests exercise the local HTTP adapter, thin CLI, Workflow Runtime and Session core interfaces independently. Compiled public types and golden fixtures must freeze the complete closed JSON contract before any replacement format is accepted. Those fixtures pin every field, union tag, omission rule, and integer encoding; IDs, revisions, offsets, and other `u64`-class values are strings. Markdown consumes the same logical scan and introduces no facts. Neither encoding exists inside the native semantic boundary, and no handwritten schema duplicates the compiled contract.

Tests cover:

- create/attach conflict by exact binding;
- direct and workflow Session configuration/messages sharing core Request Identity semantics, with workflow call keys scoped by Run identity and canonical User Message kind unchanged;
- one Permission Decision per mutation and absence of a generic response batch;
- Local Owner Run cancellation and exact domain repeat/conflict behavior without a direct CLI key or whole-Run optimistic revision precondition; rejected access cannot mutate, while all admitted clients share authority;
- authorized and idempotent interruption of one exact unresolved Model Operation, including exact domain replay and rejection of conflicting input, inaccessible Store, Action target, resolved target, and terminal work without a whole-Run revision precondition;
- one Run Cancellation Intent fencing new evaluator generations and call creation; recover saved unanswered configuration/message submissions before deriving the stop set from accepted messages, with no Run-aware core fence; ordinary Session stops separately fence selected work;
- first-commit-wins settlement when provider evidence and an applicable Session stop race, with late evidence unable to bypass the committed stop;
- multiple keyed admissions/Runs sharing one Turn, no automatic cancellation of other Runs, and no Session finality from Run cancellation;
- Session stop acknowledgement before completion, idle immediate completion, and selected-work terminal outcome plus atomic occupancy release determining completion independently of later Session activity;
- model stop completion while transport cleanup still retains its charged Physical Custody, without retry or acceptance of late output; started tools retain evidence, safe cleanup and ordered Tool Result obligations; custody loss records uncertainty without mandatory inspection or replay;
- a slow tool in one Session not delaying stop requests to later Sessions during bounded workflow cancellation traversal;
- identical ordinary Session-stop completion semantics for work submitted by the cancelling Run or another client, with Run cancellation completion waiting on the required stops rather than a separate submitted-by-this-Run predicate;
- ordinary stop/terminal facts deriving pending User Messages and Permission Requests in stopped work as inapplicable without per-item withdrawal state;
- bounded stop-pass traversal over distinct submitted-to Sessions, excluding declaration/configuration/read-only use and retaining no resident Session population;
- crashes before the first stop, between stops, and after the last stop but before Run completion commit; recovery may repeat the full pass and must finish all required stops before recording cancellation completion;
- earlier successful or idle stops being repeated against newer work while Run cancellation is unfinished; this is permitted caller-coordination behavior, not a lost isolation guarantee;
- lost acknowledgement or server restart after durable Run cancellation completion returning the existing outcome without further Session stops, including after later Session continuation;
- stop/storage failure leaving Run cancellation unfinished; normal physical cleanup and unified tool uncertainty remain independently owned, with no per-Session propagation receipt, idle-check record, durable cursor, or cancellation queue;
- immediate Interrupted Resolution for an active model request while its bounded Physical Custody drains independently;
- both SQLite orderings of Attempt admission and an applicable Session stop, plus both physical launch-boundary orderings after Attempt commit: pre-launch suppression or post-launch cleanup without changing the SQLite winner;
- Run cancellation of a Model Operation with no Attempt, retry-delayed eligibility, an unconsumed Dispatch Permit, a live stream, and sealed but unsettled output;
- cancellation of an Action with no Attempt, Bash process-group interruption, Edit cancellation before mutation as not applied, and a started Edit retaining safe execution/cleanup while custody remains, or recording uncertainty if custody is lost;
- one typed Tool Result for every accepted cancelled Tool Call, preserved in call-ordinal Conversation order before the cancelled Turn Outcome;
- concurrent client commands serialized by the sole server Storage Owner, using the same owning transactional operations as internal advancement without a resident driver lease or client-owned recovery;
- retry-delayed unresolved model Operations remain `in_flight`, own no Active Credit, and become eligible through the bounded SQLite poll;
- one bounded drive quantum composing multiple separately atomic transitions, stopping at the documented conditions, and reporting whether immediate work remains;
- complete composed Run inspection using workflow records and ordinary core observations, with no cross-owner table reads or global revision claim; progress between observations and stale permission indicators must still be safe under exact-target controls;
- exact full keys and existing identifying label/context for all associated durable Sessions, including configured-only Sessions, with association derived from accepted configuration/messages rather than declarations or a core Run-membership table;
- W1 inspection followed by an agent supplying the selected full key directly to W2; preserve the shared Session's current state/history, avoid Workflow Output metadata or previous-Run plumbing, scope W2 request identities to W2, and keep W1's original bound results unchanged;
- inspection of a Run declaring an unused reference, a rejected configuration, repeated accepted calls and a lost core reply; declarations/rejections alone add no association, equal Session keys need no duplicate display, and recovery discovers committed acceptance before reporting the association;
- integrated workflow traversal, core observations and encoding under sustained polling, varying resolved history, unrelated work, configured-only associations and rejected candidates; measure queue delay, owner-call time, whole-report latency and p95 durable control acknowledgement against the existing target;
- ready controls, ordinary settlement/advancement and inspection receiving service opportunities under repeated reporting; measure each class's actual progress, while individual observations, library calls and atomic publication remain non-preemptible;
- fixed-window encoding and escaping of strings both smaller and larger than a window, including escapes split at window boundaries, exact round trips, complete terminal framing, and explicit output failure without a successful truncated report; measure encoding, query/status derivation, and scratch-write cost separately;
- release of each owner's active SQLite statements/read resources before delivery, bounded memory during composed capture, and private-scratch cleanup after success, failure, abandonment or process death;
- explicit failure for incomplete capture or delivery, including missing terminal framing, plus measured whole-Host command delay, aggregate scratch, and retained memory under repeated polling and slow clients; include overlapping current-capture and completed-report scratch, abandonment, resource exhaustion, and filesystem-cache pressure independently of SQLite heap and resident buffers;
- immutable content range reads and sealed-source ingress through fixed windows;
- complete visibility of every actionable Permission Request and every other current logical collection member without logical caps, caller page sizes, or serialized continuation tokens;
- accepted message-call summaries keeping Agent Call Key, Session key and internal Turn identity distinct, preserving original work results and derived conditions/outcomes without integrated core Run membership;
- recursive workflow-visible values crossing the Run API as immutable typed content rather than native object trees;
- untrusted model/tool text isolated from control framing; and
- SIGINT, timeout, terminal closure, and output failure detaching without cancellation.

## Shared identity and workflow submission

Exercise configuration and messaging through both direct callers and Workflow Runtime. Matching requests recover the original acceptance or definite rejection before current-state admission checks; changed input conflicts without replacing the saved answer. Lost replies, restart, later configuration and later Session reuse cannot reapply old configuration or retarget a message. Distinct fresh requests preserve intentional identical operations. Malformed envelopes without usable identity and failed commits cannot fabricate saved answers.

Inject crashes before saving an intent, after saving but before submission, after core commit but before workflow answer recording, and after that recording. Verify core state/request answers and workflow call records use independent transactions and owner interfaces. Stable Run-scoped keys survive restart, distinguish fresh Runs and reject namespace ambiguity. A batch API is optional; scalar calls must suffice without core-table access.

Cancellation first stops new calls, then recovers every unanswered saved submission with its original inputs. Cover previously undelivered configuration and message requests that now commit before stop, definite rejections, unavailable core/storage and crashes between replies or stops. Configuration effects are not rolled back. Only accepted messages add stop targets, even though configuration-only Sessions remain visible in inspection. No cancellation completion may forget an unanswered submission or unfinished required stop. Tool Attempts are outside this request retry protocol and are never automatically replayed.

## Workflow Runtime and private evaluation

Exercise the complete public Run lifecycle without caller-managed evaluator setup. Independently test the private evaluator with no results, one available result, joined results and failures using real fixed input/output values. Preserve all process/protocol/containment gates; private calculation tests do not establish persistence, submission or recovery.

Evaluation receives source, arguments and fixed saved results, emits all encountered requests plus the returned root's waiting/value/failure outcome, and makes no live core call. JavaScript owns branch and Promise decisions; native code submits the output afterward without a second dependency graph. New results remain absent during the live generation and become discoverable afterward for a nonterminal Run. Prepared immutable input may be read through bounded native lookup.

Fresh-process recovery abandons interrupted evaluation and uses currently saved original results, reuses committed calls and fences stale publication. A fulfilled root can complete with unrelated calls pending after required validation/admission; their later completion cannot reopen the Run. Pure caller-owned references require no creation-result resolver or generated-ID lookup. Inspection-based reuse uses the exact full Session key and ordinary new Run-scoped request identities; it adds no metadata to the workflow return value.
