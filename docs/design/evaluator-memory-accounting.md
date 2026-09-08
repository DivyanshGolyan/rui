# Evaluator memory: current accounting inputs

6 September 2026. Read-only input for [Set Host Runtime admission controls and budgets](https://github.com/DivyanshGolyan/onepage/issues/68) and [Choose Workflow Evaluator containment limits](https://github.com/DivyanshGolyan/onepage/issues/90). No new evaluator limit is accepted here.

The evaluator runs the workflow's JavaScript orchestration against a snapshot, returns its next requests/result and exits. It is not the model request or Bash command, and blocked workflows retain no evaluator process. All evaluator process memory is OnePage-owned and belongs in the aggregate footprint, including parent preparation/capture overlap.

Current source exposes different kinds of quantities:

- QuickJS engine heap limit: 16 MiB. `JS_SetMemoryLimit` constrains engine-managed allocations; it is not the whole child process footprint.
- Engine stack guard: 512 KiB. This is a guard setting, not an independent allocated memory block to add automatically.
- Child input/output/bridge allocations: 768 KiB, 512 KiB and 2 MiB capacities, totaling 3.25 MiB of requested mappings. Which pages are resident depends on use; this is not measured footprint. Historical exit-time full-buffer overwrites remain in source although the accepted lifecycle already removes them.
- Parent output storage: 512 KiB capacity, plus diagnostic/read state, source/snapshot preparation and the I/O implementation. It remains live separately from the child's allocations.
- 64 MiB `RLIMIT_AS`: an address-space setting in historical source, not a measured resident ceiling or proven cross-platform physical-memory enforcement.

These values come from `src/workflow_protocol.zig`, `src/workflow_evaluator.zig`, `src/workflow_evaluator_main.zig` and `src/workflow_evaluator_parent.zig`. They are historical implementation inputs awaiting the evaluator decision; do not sum them into an asserted 20/64 MiB resident price. Existing output/frame/cardinality limits reject some saved workflow examples, so simply measuring accepted tiny fixtures would not establish support for intended workflows.

The missing population multiplier matters as much as per-evaluator cost. The current owning architecture specifies disposable evaluators and no resident blocked-workflow state but does not give an explicit approved simultaneous evaluator population. The 1,000 model/Bash/Edit custody default does not silently grant 1,000 evaluator processes, and the old withdrawn budget's assumed single evaluator is not an accepted default either.

## Recommendation to discuss, not selected policy

Start by testing one live evaluator at a time, driven asynchronously so the Host keeps servicing I/O and controls. Waiting evaluations remain derived from durable Run facts, not a resident queue or warm process pool. Serialize only short workflow evaluation, not the model/Bash/Edit work it starts. Complete result import and safe parent/child cleanup must be included in the lifecycle accounting; an apparently exited child is not permission to accumulate detached output buffers.

This is an explicit concurrency choice with a throughput tradeoff: expensive JavaScript can delay other workflows' next evaluation even while already-launched work continues. Measure representative replay/fan-out/aggregation workloads and control responsiveness before accepting it. The existing per-evaluator CPU/wall/memory policy also needs review in its owning ticket; this recommendation does not select those constants or assert a fairness bound.

After population is settled, measure child plus parent incremental cost at meaningful phases, with representative large inputs/results and near-boundary heap behavior, using the accepted no-descriptor-scan/no-exit-overwrite construction. Retain process/RSS/address-space distinctions. The result then fills the evaluator term in the Host accounting. No production change or new benchmark ran for this audit.

## Serial evaluator experiment

The user authorized testing the recommendation without selecting a concurrency policy. Local `codex/evaluator-serial-probe`, commit `edc82c5`, preserves the real QuickJS candidate, driver and raw results at `/tmp/onepage-evaluator-serial/research/evaluator-serial-probe/README.md`. Main-checkout production is unchanged. Candidate construction removes the already-rejected descriptor scan and exit-time mapping overwrites; the historical engine/frame/output limits remain unchanged.

1,126 synthetic evaluations passed expected values/failure classifications and cleanup. Ordinary workload medians were roughly 10–20 ms including startup; 20,000 temporary objects took 21.452 ms. OS child peak RSS medians were 5.516 MiB for tiny completion, 5.922 MiB for 256 KiB prior-result aggregation and 19.578 MiB at deliberate heap exhaustion. Sampled physical footprint is retained separately and may miss short peaks; it must not be substituted for a complete bound. The parent prototype reads input from disk and streams output; it omits actual Store preparation/publication and is not the historical parent API.

One-at-a-time bursts: 50 tiny jobs finished in 0.462 seconds; 1,000 finished in 11.409 seconds. A runaway delayed the next tiny job by 1.010 seconds under the historical CPU limit. The parent's active-child poll-loop gaps were small, but they exclude spawn/setup and are not durable-control latency. A 700 KiB result still fails the historical 64 KiB result limit; this is a compatibility gap, not successful large-report qualification.

Recommendation remains one evaluator initially with explicit burst queueing, pending acceptance and the evaluator policy review. Do not add parallel processes solely on speculation, accept the historical payload caps silently, or call the complete Host qualified. Earlier no-benchmark wording above describes the source audit before this follow-up.

## Limit audit and experiment-attribution correction

[Evaluator limit audit](evaluator-limit-audit.md) traces every current constant to its actual consumer and separates independent resource protection from representation-driven caps. Its recommendations are pending, not source deletions. The 700 KiB test hits the 512 KiB output builder before the later 64 KiB result check; both map to `WorkflowOutputBytes`. Earlier wording attributing that fixture specifically to the 64 KiB limit was too precise. No raw measurements change.

## Native workspace measurement

At the user's request, local prototype `codex/evaluator-native-workspace`, commit `399fa3f`, measured actual arena usage and a disjoint-lifetime reuse candidate. Report: `/tmp/onepage-evaluator-native/research/evaluator-native-workspace/README.md`. Tiny work claims 151,792 bytes of the existing 2 MiB arena; reusing the 64 KiB parsing-key workspace for later descriptor encoding reduces that to 86,256 bytes. This measures aligned allocator space, not touched physical pages or whole-process memory. The existing two fixed request/visibility tables and other Evaluation fields total 20,672 bytes on this build.

All 22 fixture/variant cases passed expected values and failure classifications, including validation-key use before descriptor reuse. Retained request copies still matter: 200 requests with 6,000-character inputs use 1,302,242 arena bytes after reuse. A 245-request case exhausts the original arena but succeeds after reuse. This supports ordinary phase-local buffer reuse and continued bounded native ownership, not a final native budget or a guaranteed 64 KiB RSS saving. Main production and numeric policy remain unchanged; output/frame redesign may remove further copies.

The user subsequently accepted phase-local buffer reuse and explicit bounded native ownership. The final numeric capacity remains open. The accepted requirements are recorded in ARCHITECTURE.md Disposable evaluator construction, ADR-0014 and VERIFICATION.md; the prototype remains evidence rather than production integration.

## Current population and time policy — 7 September 2026

The user has now accepted one evaluation lifecycle at a time per Host, including outcome handling and cleanup, with a 1-second process CPU budget and 5-second parent-owned elapsed lifetime deadline after successful spawn. Earlier pending-policy paragraphs are dated evidence. The engine heap limit is 16 MiB; native layout/capacities are implementation-derived and separately measured. Waiting workflows retain no evaluator. Apply one live evaluator lifecycle to the accounting multiplier, including retained parent capture/import resources until release; the standalone prototype parent baseline must not be counted twice in the Host. Full integration and physical-footprint qualification remain outstanding.

## Address-space source correction — 7 September 2026

The historical 64 MiB address-space constant is skipped on the tested Mac: Zig exposes AS as an enum declaration alias, while the source asks `@hasField`. A direct C setter probe returns EINVAL at 64 MiB. See the final limit audit and local `a461cdd` experiment. This is not an enforced resident or address-space ceiling for the measured evaluator builds. The proposal is to remove that Mac policy rather than enable a failing setter; actual engine/native allocation protection and total physical-footprint qualification remain.
