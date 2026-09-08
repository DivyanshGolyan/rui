> Historical planning record, superseded by the current Host decision aid.
> Unaccepted numbers and interpretations below are preserved as history.

# Minimal Host resource controls — working proposal

Prepared 6 September 2026 for [Set Host Runtime admission controls and budgets](https://github.com/DivyanshGolyan/onepage/issues/68).
This is a decision aid, not an accepted numeric matrix or implementation plan.
The owning contracts remain ARCHITECTURE.md, PRODUCT.md and VERIFICATION.md.

## Proposed grouping

| Resource | Existing owner/accounting | Why it needs protection | Release and overload | Evidence still needed |
| --- | --- | --- | --- | --- |
| Active external executions | One startup-sized Physical Custody table; model requests, Bash and Patch share Active Capacity | Each occupied record owns bounded OnePage execution machinery; logical completion can precede physical cleanup | Release after physical obligations finish; full capacity makes accepted work wait without a new Attempt or per-waiter resident resources | Complete model/tool mix, temporary executor assumptions and retained-idle footprint before a default; cancellation and wakeup at saturation |
| Aggregate temporary bytes | Existing charged scratch at each owner: outbound requests, captured output, parser metadata, ingress, current/completed inspection and temporary exports | A single large capture or many slow deliveries can exhaust disk independently of execution count | Release at each existing completion/failure/abandonment boundary; accepted storage policy waits before admission and fails affected execution after admission; incomplete ingress/reports cannot succeed | Logical versus allocated bytes, capture/import overlap, slow clients, cleanup and shared-volume storage faults; numeric quota remains open |
| Live local client connections and their bounded request/delivery state | Existing Host server | Clients exist without consuming external execution capacity; slow uploads/readers can retain sockets, parsing state and report scratch | Release on connection/request cleanup; precise admission/overload policy is still a decision, including access for stop/control requests under saturation | Bound in-flight work and retained reports per connection, idle/slow-client behavior, request envelope, connection churn and control progress |

These are proposed Host admission/accounting populations, not three promised
public configuration knobs. Active Capacity is already shared by models and
tools; no per-kind execution pools are proposed. One aggregate scratch budget
must charge bytes regardless of which existing owner created them. Its capacity
does not authorize the same amount of resident memory.

Diagnostics additionally retain their already-accepted bounded persistent
storage policy. It cannot be merged with temporary scratch reclamation:
diagnostic records deliberately survive ordinary restart and rotate/expire,
whereas scratch has execution/transfer lifetimes. Numeric diagnostic retention
is still open. Canonical conversation/results are not disposable diagnostics
and gain no history-cardinality quota from this proposal.

## Derive rather than duplicate

Do not start with independent model-socket, Bash-supervisor or generic
file-descriptor pools. First account for their fixed and per-owner costs:

- fixed Host/SQLite/evaluator/diagnostic resources;
- occupied execution records, using the relevant model/tool costs;
- live clients and permitted per-client in-flight uploads/deliveries;
- the single capture/import workspaces and any separately retained reports;
- bounded library-internal activity such as resolution and connection setup.

A derived descriptor bound is valid only if every owner and multiplier is
bounded. For example, a byte quota does not bound the number of zero-length
scratch files. A client count does not bound retained reports if one connection
can create arbitrarily many outstanding reports. These must be addressed in
the owning lifetimes/protocol before declaring their accounting covered.

Check the derived descriptor requirement against the process/platform limit
when validating capacity. This is not a claim that the OS promises all later
allocations or that a startup check replaces typed runtime failure handling.
OnePage-owned Bash supervision belongs in the Host accounting; the command's
own memory and descendants remain separately observed workload resources.

SQLite heap/cache/spill and evaluator containment remain with their existing
limit decisions. Include their costs in the whole-Host target rather than
adding another owner or duplicate budget for the same workspace.

## Measure without introducing a new admission rule

Whole-process footprint, retained-after-churn memory, CPU, kernel/socket costs,
filesystem cache/writeback, and control latency need verification targets.
They are not automatically additional runtime admission counters. An observed
RSS threshold is not an enforced memory bound. Any new pressure-based rejection
rule would need its own reliable measurement, affected owner and overload
semantics; this proposal adds none.

The recent approximately 170 MiB model-stream prototype result is partial
transport/SQLite/scaffolding evidence. It does not price the complete Host,
prove a hard maximum, or select 1,000 as a default. Existing diagnostic, client,
parser/evaluator and temporary Action costs still need inclusion. Do not choose
a complete Host limit by multiplying the model-only average by Active Capacity.

## Next decision

Define local-client saturation behavior while retaining access for stop and
other controls. A raw connection cap alone does not do that: all admitted
clients could be slow, leaving a new cancellation caller unable to connect.
The accepted service turns protect controls after they are ready inside the
Host; admission must also get them there. Decide this within the existing server
before choosing a connection count. Do not invent a separate control service,
reserved-slot count or timeout constant in this note.

Then choose the numeric matrix from named fixed costs, population multipliers,
headroom and overload behavior. FIFO/fairness details, numeric capacities,
scratch quota, client limits, diagnostic retention, public configuration
exposure and the supported transport build are not selected by this note.

## Client saturation candidate

This section is a proposal for the current decision, not an accepted contract.
The concrete scenario is a population of slow uploads or report readers filling
all ordinary client capacity while another local client tries to stop a Session.

Use the existing Unix-socket HTTP server and one bounded connection population:

- Handle one request and its response per connection, then close it. Do not
  admit pipelined requests or retain idle keep-alive connections. Each connection
  can therefore retain at most one upload or one completed report at a time;
  charge capture/delivery overlap explicitly in the scratch accounting.
- Admit long transfers and ordinary requests below the total connection bound.
  Leave a bounded amount of headroom for initial request classification and
  short controls. This is a restriction within the same population, not another
  server, thread pool or execution-credit pool.
- Classify a request from a bounded envelope before admitting its body or
  starting report capture. Ordinary work cannot consume the headroom after
  classification; reject overload before semantic mutation. Stop/control requests
  must themselves have bounded input, parsing and response state. A long wait
  for cancellation completion cannot occupy this short-control allowance;
  acknowledge the committed request and observe completion separately through
  the existing inspection path, subject to the final client wire contract.
- Bound how long an unclassified connection can hold its place, including
  trickled headers. Apply selected stall deadlines to body ingress and response
  delivery. Reclaim failed transfer resources through their existing owners.
  Large transfers making progress need not have an arbitrary total-duration cap.
- Keep acceptance, classification, rejection and cleanup work bounded per Host
  turn, alongside the already-accepted control and ordinary-work service turns.
  A client that does not read an overload/control response cannot retain its
  connection indefinitely.

The proposed user-visible tradeoff is explicit failure of a stalled upload or
report instead of indefinitely retaining its connection and temporary data.
Incomplete uploads publish nothing; incomplete reports cannot appear successful.
A connection timeout after a mutation committed does not undo it or permit
automatic replay of a keyless command. Existing acknowledgement-loss rules apply.
Disconnecting a client does not stop accepted durable work.

This protects control ingress against saturation by admitted ordinary transfers.
It does not promise that every stop caller connects immediately under arbitrary
connection floods, simultaneous controls or process-wide OS resource exhaustion.
Unclassified callers share the bounded headroom until their requests can be
identified. Deadlines prevent indefinite occupation by a fixed set of stalled
callers; they alone do not guarantee fairness under continuous replacement.
Do not claim a strict end-to-end control deadline from this structure.

Alternatives considered: a plain total cap plus timeouts leaves stop behind all
ordinary occupied connections until a timeout; evicting an arbitrary transfer
on every new connection makes churn disrupt healthy clients; a second control
socket introduces another endpoint and still needs its own admission rules.
The candidate keeps one endpoint and adds only the admission distinction needed
for the motivating scenario.

Before accepting or numbering the policy, resolve the client acknowledgement
and completion-observation contract, identify which commands qualify as short
controls, and derive the connection headroom and envelope/stall deadlines.
Verify saturation separately with slow uploads, slow report readers, trickled
headers, a stalled control-response reader and concurrent controls. Include
connection churn, explicit incomplete output, scratch release, mutation commit
followed by lost acknowledgement, and continuing progress of durable work.
Measure control admission and semantic acknowledgement separately from physical
execution cleanup. This is a design candidate, not production evidence.

## Accepted refinement — 6 September 2026

The user accepted the qualitative connection constraints summarized in
ARCHITECTURE.md, Server ownership and local clients: bounded connections with
control headroom, one request/response per connection, bounded headers with a
total deadline, and client-inactivity deadlines for transfers. Host processing
and backpressure are not client inactivity; healthy transfers gain no minimum
speed or total-duration rule. Timeouts preserve saved work and existing
acknowledgement-loss semantics.

VERIFICATION.md records 10-second headers and 60-second transfer inactivity as
provisional test inputs, not measured requirements or production defaults.
The preceding candidate remains historical proposal detail where it goes beyond
these accepted constraints. Exact short-control membership, acknowledgement/
completion wire behavior, numeric connection/headroom and header-byte bounds
remain open. No production implementation or saturation evidence is claimed.

## Unix-socket client evidence — 6 September 2026

The isolated follow-up prototype is preserved at
`/tmp/onepage-client-saturation-probe/research/client-saturation-probe/README.md`
on local branch `codex/client-saturation-probe`. It measures native Unix-socket
clients and immediately unlinked upload/report scratch, separately from the
production Host. Three repetitions at 16, 100 and 256 clients confirm bounded
per-client windows and one socket plus one scratch descriptor per held transfer.
At 100 uploads/downloads, the median added process physical footprint was about
1.75/1.81 MiB, with 200 additional descriptors. Kernel/socket memory outside
process accounting remains unmeasured. Reusable windows remain after cleanup;
descriptors and scratch return to baseline.

One extra classification/control place allowed all 60 serial fresh synthetic
control requests per transfer type at 100 clients to finish below 1 ms. Without
headroom, a fresh control failed at 16 held uploads. This measures transport
admission and a tiny synthetic response, not a committed Session stop, integrated
Host latency, concurrent-control fairness or a production headroom default.
Shortened deadline fixtures verified header trickling expiry, stalled upload/
report cleanup and slow progress surviving a longer total transfer duration.

The candidate protected set is Session stop, Run cancellation, exact Model
Interruption and Permission Decision admission. These use existing domain owners;
protection applies to bounded request admission and acknowledgement, not a wait
for cancellation/tool completion or a complete inspection report. This set is
recommended, not yet a resolved change to the client command contract. Header,
body and acknowledgement bounds must be checked against the final wire shapes.

For final counts, allocate from the remaining whole-Host memory and descriptor
budgets after fixed costs and external executions, using the verified client
multipliers. Scratch-byte capacity remains independent. The current evidence
prices clients but does not determine how much of the Host budget to allocate
to them. Do not promote 100/256 ordinary connections or one spare place from
probe controls to product defaults. The remaining headroom evidence is a bounded
concurrent-control/classification scenario; arbitrary churn is not covered by
the isolated saturation result.

## Accepted protected commands — 6 September 2026

The user accepted the previously proposed protected set: Session stop, Run
cancellation, exact Model Interruption and Permission Decision admission.
Protection covers bounded admission/acknowledgement; completion waits and large
reports use ordinary capacity. ARCHITECTURE.md and VERIFICATION.md now own this
requirement. Earlier candidate language above records the proposal at that time.

Retain the accepted connection policy and provisional 10/60-second timeout test
inputs. No further isolated connection tuning is required by the current
evidence. Select final connection/headroom counts with the whole-Host budget;
100 plus one spare remains a probe configuration, not a product default. The
Host budget decision stays open.

## Combined budget proposal

The [combined Host budget proposal](host-budget-proposal-2026-09-06-before-consolidation.md) assembles measured
costs and explicit planning allowances. Its proposed 256 MiB stress-case target, 1,000-active stress population,
128-client proposal, idle targets and temporary-disk candidate are not accepted
defaults. It identifies the unmeasured tool-heavy cost and remaining matrix
choices without treating the model-only measurement as a complete Host proof.

The user subsequently confirmed that 1,000 is a stress-test population only,
not a candidate startup default inferred from transport feasibility. Default
concurrency remains undecided. Keep the ordinary curl buffer improvement and
stop the TLS memory-tuning pass; the 256 MiB stress-case target remains proposed.

## Default capacity reconsidered — 6 September 2026

The user subsequently authorized proceeding with 1,000 as the planned shared
startup default, superseding the stress-only position above. The native tool
resource follow-up supports feasibility of 1,000 temporary workers/descriptor
sets but does not qualify real Patch/Git or full Host operation. ARCHITECTURE.md
and VERIFICATION.md carry the planned default and release obligations. The
256 MiB memory target and other unaccepted numeric proposals remain proposals.
