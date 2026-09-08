# OnePage workflow verification

This is part of the normative [VERIFICATION.md](../../VERIFICATION.md) contract. [Corresponding architecture](../architecture/workflows.md) supplies the governing rules.

## Workflow replay

Required workflow fixtures must use the production QuickJS boundary and the proposed `export default async function workflow({ createSession, configureSession, sendMessage }, args)` signature (configuration naming and acknowledgement shape remain to be finalized). The revised API is not implemented yet; these are required checks, not passing evidence. They cover:

- idempotent Caller Run Key and stored invocation Workspace;
- distinct Run-local creation/configuration/message keys binding operation kind and complete inputs;
- empty Session creation with complete baseline and no model work;
- lost creation acknowledgement recovering the same Session ID;
- configuration effect and replay result committing atomically without model work;
- replay of an old configuration operation leaving a later change intact;
- configuration remaining committed after later message failure or a crash before sending;
- another client changing settings between configuration and message admission without an invented stale-view rejection;
- existing Session IDs used directly without wrapper or attachment;
- first and later messages sharing the same API, with exact schema output and frozen rejection;
- optional Session output schema persisting across messages, with ordinary text when absent and no schema mutation through message options;
- changing or clearing a schema after request A is constructed leaves A and its retries unchanged; the next applicable request uses the new configuration, and replay returns the original result without validating it against current settings;
- provider-boundary fixtures covering supported structured success, unsupported schemas, malformed or schema-invalid output, refusal, and incomplete generation without fabricated success, prose conversion, or automatic model repair calls;
- shared-work message callers receiving the same recorded result under the producing request's schema, without caller-specific schema expectations;
- creation alone excluded from the Run cancellation Session set;
- lost membership acknowledgement;
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
- results committing before dependency publication and during evaluation remaining discoverable by subsequent pulls, without Turn-completion notifications, a pending completion-ID queue or maintained ready set;
- considered results no longer causing unchanged reevaluation after publication, while a partial join may be reevaluated on a newly available result;
- no per-waiting-Run heap/callback/timer, accumulated missed ticks, or resident materialization of all candidate Runs; verify oldest-eligible selection with stable creation-time ties, immediate rechecks, and seconds-to-minutes Turn completion traces; distinguish ordinary service from sustained evaluator overload rather than claiming unconditional starvation freedom;
- deterministic `Promise.all` and `Promise.allSettled`;
- absence of `Promise.race` and `Promise.any`;
- crash recovery after partial keyed admission: fresh evaluation sees results finished during downtime, reuses committed operations, rejects changed bindings, and cannot publish abandoned-generation output; rollback of replacement admission leaves recoverable interruption, while committed dependency/output publication remains authoritative;
- fixed visibility during each live evaluation without requiring historical snapshot reconstruction or per-call first-visible markers;
- on-demand lookup without eager decoded results or a bridge-owned decoded-answer cache; measure native key/index storage separately; compare selective, sequential and parallel consumers, forward actual finding text into requests, and measure decoded bytes, allocation peaks and simultaneous physical footprint without assuming arbitrary user-held values fit;
- separate same-key calls receiving independent object values while repeated awaits of one Promise retain identity; mutation of one returned object never changes the saved outcome or a subsequent call's value;
- fixed membership capture followed by result-body materialization from captured immutable references, including a result committing between those phases; prove retention through existing owners, bounded native key comparison and content windows, exact non-ASCII/prefix/long keys, and distinct missing/null/failure outcomes;
- narrowly inherited read-only snapshot descriptors, closure of writable handles before spawn, no JS-visible filesystem/storage capability, and explicit failure for invalid ranges, short reads, lost captured content, allocation/CPU/deadline exhaustion and orphan-handle cleanup;
- full validation and known-key conflict detection before new admissions, call-input capture before later JS mutation, repeated-key consistency, read-only equal replay, and admission-time rechecks for new calls and cancellation/generation replacement;
- actual control, due cleanup and settlement service during a large admission sequence and long validation/materialization/replay comparison, with no active SQLite statement or borrowed shared workspace retained across a service turn; kill after a committed prefix, reopen into fresh evaluation, recover equal bindings without reapplying configuration, and atomically publish the complete next dependency set;
- final Workflow Output idempotency;
- actual allocation, transfer, CPU and lifetime bounds across source, arguments, results and repeated evaluation; and
- no JavaScript continuation or evaluator process retained at a barrier.

Qualify idle polling and busy selection using actual generation/dependency queries on the pinned SQLite build: empty Store, direct Sessions with no workflow dependencies, many waiting Runs with no ready work, shared-result fan-out, historical result growth and sustained independent pipelines. Record CPU, examined rows/VM work, lookup/owner time, memory and control latency. The [readiness probe](../../research/workflow-readiness/README.md) is a warm small-schema experiment, not passing Host evidence or a selected index set. Its one-second CPU extrapolation does not replace the accepted idle-CPU target.

Two workflow calls in one Workspace prove that independent Bash and Edit Operations may progress concurrently under Active Capacity, completions settle without sibling head-of-line blocking, and filesystem interference is reported as observed evidence rather than prevented by a Host fence. Fixtures prove Bash and Edit use the same Action lifecycle without a permanent Edit lane or global serialization.

## Run interface

Golden and hostile-input tests exercise the local HTTP adapter, thin CLI, and typed Host Runtime API independently. Compiled public types and golden fixtures must freeze the complete closed JSON contract before any replacement format is accepted. Those fixtures pin every field, union tag, omission rule, and integer encoding; IDs, revisions, offsets, and other `u64`-class values are strings. Markdown consumes the same logical scan and introduces no facts. Neither encoding exists inside the native semantic boundary, and no handwritten schema duplicates the compiled contract.

Tests cover:

- create/attach conflict by exact binding;
- direct and workflow Session messages sharing one primitive and canonical User Message kind, while only workflow operations carry Run-local replay keys;
- one Permission Decision per mutation and absence of a generic response batch;
- Local Owner Run cancellation and exact domain repeat/conflict behavior without a direct CLI key or whole-Run optimistic revision precondition; rejected access cannot mutate, while all admitted clients share authority;
- authorized and idempotent interruption of one exact unresolved Model Operation, including exact domain replay and rejection of conflicting input, inaccessible Store, Action target, resolved target, and terminal work without a whole-Run revision precondition;
- one Run Cancellation Intent fencing further evaluator generations and Run creation/configuration/message admissions, with the affected Session set derived from earlier committed message admissions; ordinary Session stops separately fence their selected work;
- first-commit-wins settlement when provider evidence and an applicable Session stop race, with late evidence unable to bypass the committed stop;
- multiple keyed admissions/Runs sharing one Turn, no automatic cancellation of other Runs, and no Session finality from Run cancellation;
- Session stop acknowledgement before completion, idle immediate completion, and selected-work terminal outcome plus atomic occupancy release determining completion independently of later Session activity;
- model stop completion while transport cleanup still retains its charged Physical Custody, without retry or acceptance of late output; started tools retain their existing evidence/reconciliation and ordered Tool Result obligations before work settles;
- a slow tool in one Session not delaying stop requests to later Sessions during bounded workflow cancellation traversal;
- identical ordinary Session-stop completion semantics for work submitted by the cancelling Run or another client, with Run cancellation completion waiting on the required stops rather than a separate submitted-by-this-Run predicate;
- ordinary stop/terminal facts deriving pending User Messages and Permission Requests in stopped work as inapplicable without per-item withdrawal state;
- bounded stop-pass traversal over distinct submitted-to Sessions, excluding creation/configuration/read-only use and retaining no resident Session population;
- crashes before the first stop, between stops, and after the last stop but before Run completion commit; recovery may repeat the full pass and must finish all required stops before recording cancellation completion;
- earlier successful or idle stops being repeated against newer work while Run cancellation is unfinished; this is permitted caller-coordination behavior, not a lost isolation guarantee;
- lost acknowledgement or server restart after durable Run cancellation completion returning the existing outcome without further Session stops, including after later Session continuation;
- stop/storage failure leaving Run cancellation unfinished; normal effect-specific cleanup remains recoverable independently, with no per-Session propagation receipt, idle-check record, durable cursor, or cancellation queue;
- immediate Interrupted Resolution for an active model request while its bounded Physical Custody drains independently;
- both SQLite orderings of Attempt admission and cancellation, plus both physical launch-boundary orderings after Attempt commit: pre-launch suppression or post-launch cleanup without changing the SQLite winner;
- Run cancellation of a Model Operation with no Attempt, retry-delayed eligibility, an unconsumed Dispatch Permit, a live stream, and sealed but unsettled output;
- cancellation of an Action with no Attempt, Bash process-group interruption, Edit cancellation before mutation as not applied, and a started Edit finishing bounded execution and reconciliation;
- one typed Tool Result for every accepted cancelled Tool Call, preserved in call-ordinal Conversation order before the cancelled Turn Outcome;
- concurrent client commands serialized by the sole server Storage Owner, using the same bounded classifier as internal advancement without a resident driver lease or client-owned recovery;
- retry-delayed unresolved model Operations remain `in_flight`, own no Active Credit, and become eligible through the bounded SQLite poll;
- one bounded drive quantum composing multiple separately atomic transitions, stopping at the documented conditions, and reporting whether immediate work remains;
- complete inspection captured from one committed view on the existing connection through bounded private batches, with revision and all facts read inside that view;
- integrated inspection queries and encoding under sustained polling with independently arriving controls and settlements; report per-class arrival/start/commit times, queue delay separately from single-capture delay, service progress and p95 acknowledgement against the existing target; include fixed-output growth in resolved history, unrelated work and rejected current candidates, shared admissions without multiplied permissions, and the full ordinary classifier; ownership selection does not count as passing this qualification;
- database admissions and settlements waiting during capture, then proceeding before delivery completes; later revisions do not invalidate a captured report and exact-target controls still reject stale actions;
- ready controls and ordinary settlement/advancement work receiving bounded driving turns before another queued inspection capture, with progress for inspection under sustained ready work; preserve the current complete read view, and measure each class's arrival, durable acknowledgement, actual interruption dispatch where applicable, and remaining single-capture delay separately;
- fixed-window encoding and escaping of strings both smaller and larger than a window, including escapes split at window boundaries, exact round trips, complete terminal framing, and explicit output failure without a successful truncated report; measure encoding, query/status derivation, and scratch-write cost separately;
- release of active SQLite statements and the read transaction before delivery, bounded memory during large capture, and private-scratch cleanup after success, failure, abandonment, or process death;
- explicit failure for incomplete capture or delivery, including missing terminal framing, plus measured whole-Host command delay, aggregate scratch, and retained memory under repeated polling and slow clients; include overlapping current-capture and completed-report scratch, abandonment, resource exhaustion, and filesystem-cache pressure independently of SQLite heap and resident buffers;
- immutable content range reads and sealed-source ingress through fixed windows;
- complete visibility of every actionable Permission Request and every other current logical collection member without logical caps, caller page sizes, or serialized continuation tokens;
- Run–Turn membership summaries that keep Agent Call Key separate from Turn identity and partition members into the exact derived conditions/outcomes;
- recursive workflow-visible values crossing the Run API as immutable typed content rather than native object trees;
- untrusted model/tool text isolated from control framing; and
- SIGINT, timeout, terminal closure, and output failure detaching without cancellation.
