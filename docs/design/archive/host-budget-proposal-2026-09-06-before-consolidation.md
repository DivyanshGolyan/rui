> Historical planning record, superseded by the current Host decision aid.
> Unaccepted numbers and interpretations below are preserved as history.

# Combined Host budget — proposal

Prepared 6 September 2026 for [Set Host Runtime admission controls and budgets](https://github.com/DivyanshGolyan/onepage/issues/68).
These are proposed engineering targets and test populations, not accepted
product defaults, enforced RSS limits or production measurements.

## Proposed memory target

Target **256 MiB of OnePage-owned process physical footprint** at the proposed
1,000-active-execution qualification point, including OnePage-owned helper
processes and a live evaluator. Report individual process RSS/physical footprint
and the sum separately; this sum is not an exact measure of system-wide physical
pages because processes can share mappings. Model-selected commands and their
workload descendants remain separately observed. OS socket/kernel memory and
filesystem cache/writeback must also be reported separately; 256 MiB is not an
all-system RAM guarantee.

| Allocation in the target | MiB | Basis and obligation |
| --- | ---: | --- |
| Active execution machinery | 200 | Largest recent optimized 1,000-model prototype peak was 182.70 MiB, including its small SQLite/scaffolding baseline. Rounding up leaves about 17 MiB within this allocation. Replacement Bash/Patch machinery has no equivalent evidence; 200 MiB is an explicit provisional aggregate requirement for those mixes, not a measured cost. |
| Shared Host work and evaluator | 32 | Proposed allowance for fixed Host state, SQLite, serial parsing/import/capture, diagnostics encoding and one evaluator. Current evaluator source allows 16 MiB engine heap plus approximately 3.75 MiB of input/output/bridge/engine-stack limits, before native/runtime overhead. Those source settings remain subject to the evaluator decision; this is a planning cross-check, not measured residency or adoption of those limits. |
| Local clients | 4 | Proposed 128 total connections at a conservative 32 KiB per-client planning allowance. The native probe touches 16 KiB windows and measured roughly 1.8 MiB extra at 100 transfers. The larger allowance covers metadata/allocator slack provisionally; it does not include separately reported kernel/socket memory or report disk bytes. |
| Unassigned integration margin | 20 | Explicit headroom for costs missing from isolated experiments. A policy allowance, not additional allocated memory or an admission counter. |
| Total | 256 | A pre-implementation target to test, not a current guarantee. |

The isolated experiments overlap fixed/library costs, so their process totals
must not be summed as if they were disjoint allocations. This partition is an
engineering allocation against a proposed total. Production ownership and
measurements must establish where every cost belongs.

The recent current-candidate transport samples retained 40.28–49.92 MiB after
one 1,000-request wave with all custody and scratch released. Do not demand a
return to the cold baseline or transplant older-library reclamation experiments.
Propose **32 MiB cold idle** (no live evaluator) and **96 MiB retained idle after
churn**, including retained client windows, as separate verification targets.
The cold/retained totals are allowances for integration, not observed full-Host
values. Keep ordinary cleanup and reuse; a miss first requires attribution.
No pressure-triggered cancellation, custom allocator or forced reclamation rule
follows from these targets.

## Proposed capacity and client populations

- Carry **1,000 shared active executions as the planned startup default**.
  The user reconsidered the stress-only position and authorized proceeding
  with this default after reviewing its role as a ceiling rather than an
  up-front allocation. It remains a stress/qualification population too, not
  a hard maximum or a passing production guarantee. The native tool-resource
  probe supports feasibility of basic worker/descriptor costs; real Patch/Git
  and mixed Host qualification remain required. The 256 MiB target is still
  proposed, not an accepted memory guarantee or startup reservation.
- Propose **128 total local clients: 120 ordinary plus 8 places of classification/
  short-control headroom**. Total size follows the proposed 4 MiB client allowance
  at 32 KiB/client. Eight represents a proposed test scenario of several local
  callers submitting short controls together; it is a policy allowance, not a
  concurrency percentile inferred from traffic. The existing single-control
  probe does not validate eight simultaneous controls or header contention.
- Preserve the already-accepted 10-second header and 60-second transfer-inactivity
  test inputs, one exchange per connection, protected command set and overload
  semantics. Completion waits and large reports remain ordinary traffic.
- Do not add per-model/per-tool credit pools, memory-weighted scheduling or a
  second client service to make a fixture fit. The accepted single shared
  Active Capacity remains. If tool costs exceed the proposed envelope, revise
  the shared capacity or memory target explicitly from those costs.

The provisional tool obligation is demanding: 200 MiB / 1,000 is about
204.8 KiB of incremental OnePage-owned execution machinery per active tool on
average, with fixed work charged separately. A separate native helper process
per tool might exceed it even before useful work. No current measurement proves
this allocation achievable. Model-owned Bash memory is excluded; OnePage-owned
supervision is not. The 256 MiB target can be accepted as an engineering goal
without pretending this unknown is resolved.

## Descriptors and temporary storage

Do not select a universal descriptor ceiling from the current process limit.
Derive the requirement from fixed owners plus the largest supported execution
mix, client sockets/files, serial parser/report metadata, evaluator pipes and
bounded library activity. The existing model probe's roughly socket-plus-spool
shape omits some production outbound-request/metadata lifetimes. The client
probe establishes two descriptors per retained transfer, so 128 clients require
up to 256 for that shape, plus the listener and other fixed owners. Validate
startup requirements against actual platform/process availability and keep
explicit runtime allocation failure. This is not a new descriptor pool.

Temporary bytes and diagnostics need separate disk choices. Do not turn the
256 MiB RAM target into a disk quota, and do not invent a numeric disk default
just to complete this table. A concrete sizing scenario already includes
1,000 simultaneous 4 MiB request bodies (3.90625 GiB if all materializations
overlap), captured output/metadata, current report capture, and retained complete
reports. The prior wide-report fixture reached 602.88 MB of logical scratch.
An **8 GiB aggregate temporary-byte candidate** would leave about 4.09 GiB after
that request cohort for the other scratch owners; it is a proposed disk-space
tradeoff, not a proven bound sufficient for arbitrary histories or outputs.
Logical versus allocated-byte charging and storage-admission progress remain
requirements to resolve before choosing it. Accepted pre/post-admission storage
failure semantics remain unchanged. No canonical-history quota is introduced.

Diagnostic retention remains separately owned persistent storage. Its numeric
budget needs summary encoding/retention expectations and detailed-capture
behavior; there is no traffic-based derivation in the current evidence. Leave
it explicit rather than assigning an unexplained number.

## What this proposal settles if accepted

It selects a whole-Host memory target and a small finite set of qualification
populations, with named provisional allocations. It does not close the Host
budget decision: tool/executor descriptor and memory assumptions, concurrent
control evidence, temporary-byte accounting and quota, diagnostic retention,
retry-poll cadence and latency/CPU targets remain to finish its numeric matrix.
SQLite and evaluator settings remain with their existing decision owners and
must fit the proposed shared allocation; implementation certification follows.

No production code, numeric normative contract or published default changes
with this proposal.

## Evidence pointers

- Optimized current curl: local branch `codex/host-capacity-scaling`,
  `research/host-transport-simple-memory/README.md` and
  `research/host-transport-realistic-uploads/README.md`, under
  `/tmp/onepage-host-capacity-scaling`; peak and post-wave values are in the
  matching raw result files. Dependency selection is still separate.
- Unix client probe: local branch `codex/client-saturation-probe`, commit
  `cda05c5`, `/tmp/onepage-client-saturation-probe/research/client-saturation-probe/README.md`.
- Published parser/SQLite evidence: `research/matklad-experiments/parser/README.md`
  and `research/matklad-experiments/sqlite-import/README.md` in this checkout.
- Current evaluator source: `src/workflow_protocol.zig`, `Limits`. Source bounds
  are not production physical-footprint measurements or settled V1 limits.

## Tool resource follow-up

Local branch `codex/tool-budget-probe`, commit `b5f9cd8`, preserves
`/tmp/onepage-tool-budget-probe/research/tool-budget-probe/README.md`, source
and raw results. Three native runs successfully held 1,000 temporary workers
with 64 KiB touched stack each and 6,000 fixture descriptors. Whole-process
physical footprint was 79.20–79.24 MiB in the worker phase; joins and descriptor
cleanup returned to baseline counts. The fixture retains both pipe ends to
avoid launching workload processes. Native kernel costs, real Patch/Git memory,
full stack use, CPU/contention and mixed Host operation are not measured.
This supports proceeding at 1,000 without claiming full tool qualification.
