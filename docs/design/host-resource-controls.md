# Host resource decision — current state

For [Set Host Runtime admission controls and budgets](https://github.com/DivyanshGolyan/onepage/issues/68),
within [Wayfind the minimal V1 limit model](https://github.com/DivyanshGolyan/onepage/issues/85).
Consolidated 6 September 2026. This is a decision aid; ARCHITECTURE.md and
VERIFICATION.md own accepted requirements. No production implementation is
claimed. Earlier discussion is [preserved as history](archive/host-resource-controls-2026-09-06-before-consolidation.md).

## Accepted

| Choice | Meaning |
| --- | --- |
| Planned default: 1,000 shared active executions | One custody table for models, Bash and Edit preparation/execution/cleanup. Not 1,000 preallocated transports, not one worker per operation, not a hard maximum. Real resource validation and release qualification remain required. |
| Full execution capacity makes accepted work wait | Existing SQLite facts hold waiting work without a new Attempt or resident queue. Physical cleanup frees capacity; cancellation of waiting work needs no execution credit. |
| Configurable default scratch cap: 8 GiB | One aggregate allowance for temporary data held at once; no preallocation. Prompt safe release by existing owners. Canonical state and persistent diagnostics remain separate; temporary copies count. Private logical file sizes, including sparse gaps, are charged with growth reserved before I/O. Published spillover retains its Host-produced charge until name removal/Host closure; external mutation or retained handles are outside the enforced allowance. |
| Disk-first temporary content and ordinary cleanup | Fixed/shared memory windows and one shared temporary-file policy: protect current work, release unused files promptly, reclaim optional retained files oldest-first when space is needed. No custom memory allocator or separate per-tool retention system. |
| Explicit storage failure semantics | Known unavailability before Attempt admission waits; exhaustion after admission safely ends affected execution with explicit failure. No RAM fallback, silent truncated success or automatic redispatch. Failure to save semantic state fences dispatch and stops the Host; explicit restart uses recovery. |
| Protected client access | Bounded connections with ordinary traffic unable to consume all classification/control headroom. Session stop, Run cancellation, exact Model Interruption and Permission Decision admission receive protection; completion waits and large reports use ordinary capacity. |
| Bounded client lifetime | One request/response per connection, bounded headers, total header deadline and transfer-inactivity deadline. Host work/backpressure is not client inactivity. 10/60 seconds are accepted initial defaults, not passing production evidence. |
| Keep the ordinary curl improvement | The tested 16 KiB upload-buffer option improved the candidate-library fixtures. Stop TLS tuning; supported-build qualification remains separate. |
| Separate application state and diagnostics | Canonical user state remains durable. Diagnostics default to a configurable 128 MiB retained-history cap per Host, replacing oldest records with no additional age-based expiry. Detailed capture remains opt-in; retention cannot change execution authority. |

## Final policy package accepted

The user accepted the [complete package](host-final-recommendations.md):
128 total clients / 120 ordinary / 8 classification-control headroom; 16 KiB
headers and 8 KiB short controls/replies; 10/60-second deadlines; 16 rotating
diagnostic files with 4 KiB records, shared-cap detail and scratch-backed
best-effort export; one-second retry polling; startup configuration; and the
whole-Host memory, CPU, control-latency and retry-discovery targets now owned by
VERIFICATION.md. Values are policy choices and qualification requirements, not
measurements or passing production evidence.

The [owner audit](host-resource-owner-audit.md) and real-Git follow-up preserve historical Patch evidence. Native Edit and the accepted ordinary-file-access amendment supersede Git preparation/application and eligibility helpers. The [current matrix](host-resource-matrix.md) covers the accepted owners; complete compiled workspace/descriptor quantities remain implementation derivations, not new policy choices. No production qualification is implied.

Descriptor requirements are derived from complete owner multipliers and checked
against actual availability; do not invent a parallel descriptor pool. Byte
quotas alone do not bound empty scratch files. Temporary Action executor costs
need an honest pre-implementation assumption tied to an intended implementation,
then production evidence; the artificial worker probe does not provide it.

SQLite settings/query work and evaluator containment remain with their existing
Wayfinder decisions. Their costs must be included in the eventual Host total;
this ticket does not choose their internal limits or bypass the finite-matrix
readiness gate. No new speculative implementation tickets are needed.

## Temporary disk decision accepted

The user accepted a configurable default **8 GiB aggregate scratch cap** after
confirming that temporary files are released once no longer needed and safe to
close. This is a cap on concurrently held temporary data, not reserved disk or
retention of old files. Canonical state and persistent diagnostics remain
separate; temporary copies count. Existing exhaustion behavior is unchanged.

The user subsequently accepted logical-file-byte accounting after the direct
prototype: reserve growth before I/O, refund unused reservation after partial
writes/errors, leave overwrites unchanged, and release charges after successful
truncation or final safe close. Outstanding reservations count against the cap;
owner handoff preserves charges and simultaneous copies count separately.
Initial unlinking does not free a charge. One owner per file prevents bypass
writes or unsafe release. Filesystem allocation and real volume exhaustion
remain separately observed/handled. ARCHITECTURE.md and VERIFICATION.md own
the detailed contract; configuration spelling remains implementation work.

## Evidence that remains useful

- Current curl candidate: approximately 171 MiB median peak at 1,000 small-request
  streams after the buffer change; larger-request cases reached 182.70 MiB.
  These are transport/scaffolding fixtures, not a complete Host budget.
- Unix-client probe: about 1.8 MiB added process footprint and 200 descriptors
  for 100 held transfers. One extra place admitted serial synthetic controls;
  it does not derive total client count or simultaneous-control headroom.
- Published parser/SQLite evidence supports bounded windows and verified spill;
  experiment settings are not automatically production defaults.

The [withdrawn budget model](host-budget-proposal.md) explains which assumptions
were removed. Existing raw experiments remain intact on their local branches.
The 1,000-worker probe is excluded from actual tool-cost justification.

## Logical-byte accounting prototype

The user requested a direct check of the proposed write-boundary accounting.
Local branch `codex/scratch-accounting-probe`, commit `f64a692`, preserves source,
raw results and methodology at
`/tmp/onepage-scratch-accounting-probe/research/scratch-accounting-probe/README.md`.

The candidate uses one logical-size value per exclusively owned file and a
shared limit/atomic-used pair. Reserve growth before pwrite; refund unused
reservation after partial writes/errors; overwrites add no charge; successful
truncation and final safe close return their charge. Sparse holes count. No
per-write allocation, directory scan or SQLite transaction is needed. Pending
reservations remain charged so concurrent owners cannot oversubscribe.

The exact added logical-size values total 8,000 bytes for 1,000 files, plus a
16-byte shared budget, with containing-record alignment accounted separately.
Correctness and eight-writer cap-race checks passed, including real kernel
partial-write/EFBIG behavior. Thirty comparative real-I/O cases showed no
consistent timing penalty, but five repetitions per case were too noisy for a
precise overhead or equivalence claim. See the report's full timing table.

The user accepted the simple logical-byte accounting shape after this report. It assumes one owner per file and no bypass writes.
Physical filesystem allocation, quota changes and real Host pending-I/O/semantic
integration remain separate obligations. No extra counter cache or accounting
service is justified by this experiment.

## Diagnostic history default accepted

The user accepted a configurable **128 MiB retained diagnostic-history cap per
Host**, oldest-first replacement, persistence across ordinary restart, and no
additional age-based expiry rule. It is a disk policy allowance, not a measured
memory requirement or a fixed-days retention guarantee. Small structured
summaries remain default; detailed payload capture remains explicit and bounded.
Application state and scratch accounting remain separate. The owning documents
now record this choice; the subsequently accepted final package supplies rotation, capture and export mechanics.

## Native Edit accepted

[ADR-0027](../adr/0027-use-an-in-process-exact-edit-module.md) replaces unified Patch with exact Edit, implemented as a separate native module inside the Host behind the Action adapter. Matching and copying reuse one 16 KiB window with explicit search/overlap storage; source and replacement stream. Host authority remains separate from file-editing mechanics. There is no independent crash isolation or new process/thread pool.

The Git-helper scratch design and proposed four-Patch cap are superseded/not selected respectively. The previous 1,000-Git-helper memory conflict no longer describes the chosen preparation/application design, but actual Host memory is not yet qualified. The 16 KiB search-text bound, shared preparation capacity and scratch file roles are accepted. Remaining implementation accounting covers service-turn work, complete workspace/descriptor constants and ordinary target-identity checks. The accepted file-access amendment removes Git eligibility checks. These derivation and qualification obligations do not require another Host policy decision.

## Current memory accounting

See [Host memory accounting](host-memory-accounting.md) for measured costs, named allocations and missing terms. No exact whole-Host total is claimed; the model prototype's 73.30 MiB difference below the target must cover unrepresented owners, and is not an assigned budget.
