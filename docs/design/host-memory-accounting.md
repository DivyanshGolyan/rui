# Host memory accounting from current evidence

6 September 2026. For [Set Host Runtime admission controls and budgets](https://github.com/DivyanshGolyan/onepage/issues/68). This assembles measured costs and named allocations; it does not allocate component budgets or certify the complete Host. The accepted whole-OnePage physical-footprint target is 256 MiB at the shared 1,000-operation default.

## What can be counted today

| Owner | Evidence or known allocation | What it does not establish |
| --- | --- | --- |
| Model transport and prototype scaffolding | 1,000 concurrent TLS streams with the tested curl/OpenSSL candidate and 16 KiB upload setting: 170.85 MiB median peak for small uploads. Larger-upload cases measured 160.75–182.70 MiB, one run per size/setting. | These are whole prototype process peaks, including its SQLite, custody and runtime. They are not a per-request allocation or complete Host footprint. Timing changes affect which allocations peak together. |
| Native Edit | At most 49,151 named heap-buffer bytes per simultaneous scan under the accepted 16,384-byte search limit. Two SHA contexts add 208 bytes on the tested build. | Continuation/path state, allocator/stack overhead, argument decoding, target checks and actual Host integration remain additional. No process or dedicated thread stack per Edit is selected. |
| Bash supervision/capture | Native disk-capture prototype at 1,000 ready children: 1.563 MiB median sampled parent footprint, 768.25 KiB above its own baseline, one thread. Exact captures, cancellation, quota failure and cleanup pass. | Not final Host cost: Store/durable controls, full command materialization, descendants and recovery are absent. The whole prototype baseline is not a per-child allocation. Model-selected child memory is excluded. |
| Client connections | Separate native prototype: 100 held transfers added about 1.75–1.81 MiB to that process's listener baseline; 256 added about 4.22–4.30 MiB. | The accepted 128 total/120 ordinary population has not been measured in the complete adapter. The fixture uses two touched 8 KiB windows per connection; that is not a new production buffer allowance. Header/control states and transition overlap need actual ownership accounting. |
| Shared parser/import | Paired native prototype: 140 bytes peak tracked parser heap, plus fixed parser/read/copy stack state and runtime; SQLite peaks about 177–363 KiB across tested fixtures. Process RSS roughly 2.6–2.8 MiB. Sequential range file costs 16 disk bytes per item in that representation. | 140 bytes is not total parser memory; process RSS is not incremental Host physical footprint. Full provider/semantic validation and final SQLite settings remain unqualified. Do not add this standalone process total on top of the model prototype. |
| Workflow Evaluator | Separate disposable process, included in whole-OnePage accounting. Current historical source has a 16 MiB engine heap limit, 512 KiB engine stack limit, 768 KiB input, 512 KiB output and 2 MiB bridge capacities. | These are different kinds of historical limits/capacities, not measured resident costs or accepted final allowances. They cannot be summed as process footprint. Final containment and simultaneous evaluator population must be explicit in the evaluator decision. |
| Diagnostics | One encoded-record window bounded at 4 KiB, plus fixed writer/rotation state. Retained history is disk, not a 128 MiB memory allocation. | Runtime/encoding/export overlap still counts. No RAM queue or retained in-memory history is selected. |
| Scratch accounting | Probe: 8-byte logical size per file and 16-byte shared used/limit state; fd-plus-size struct is 16 bytes with alignment. | These are named bookkeeping fields, not complete owner structs. Do not multiply the 8 GiB disk cap into RAM or add fields twice when already included in an owner. |
| Shared Host | Custody table, reactor, Store, command/capture windows, runtime/library state and allocator retention. | Final compiled sizes and overlap are not all available because production still implements the historical design. Dormant/history populations must not cause resident per-item growth. |

## How to combine them

Use disjoint incremental costs at a common measurement boundary:

`Host shared + model owners + Bash owners + Edit owners + clients + live evaluators/helpers`.

Within the Host, shared SQLite/parser/diagnostics/custody state is counted once. Include retained allocator/library memory once in the process observation. A borrowed buffer belongs to one owner at a time; simultaneous users need separately owned storage. Do not sum whole standalone executable peaks, or add buffers again when already included in a measured process peak. Kernel/socket resources and filesystem cache are observed separately under the existing qualification contract.

Let M, H and E be simultaneous model, Bash and Edit preparation/execution/cleanup custodians: `M + H + E <= 1,000`. Clients and evaluators have independent populations and must be included concurrently, not treated as spare execution slots. Permission waits retain no Edit workspace or scratch.

| Scenario | What is currently supported |
| --- | --- |
| 1,000 model streams | Largest observed optimized model fixture peak: 182.70 MiB. Arithmetic difference from 256 MiB: **73.30 MiB**. This is room for everything missing from that fixture, not a granted component budget or proven headroom under other traffic. |
| 1,000 maximum-search Edit scans | Named scan/search buffers: **46.874 MiB**; two tested hash contexts per scan add about **0.198 MiB**. Whole Host remains unmeasured. Source and replacement size do not multiply these buffers, but their scratch copies count on disk. |
| 1,000 Bash commands | Native supervision/disk-capture prototype: 1.563 MiB median sampled parent footprint. Final Host integration remains unmeasured; no universal per-Bash allocation follows. Selected command memory is excluded. |
| 500 models + 500 maximum-search Edit scans | Edit named buffers contribute **23.437 MiB**, plus other Edit state. The 500-model cost under the selected build/mix is not derived by halving a 1,000-stream process peak. Whole mix remains unmeasured. |
| 600 models + 300 Bash + 100 maximum-search Edit scans | Edit named buffers contribute **4.687 MiB**. Model/Bash/shared overlap still needs actual integrated measurement. |

No honest exact whole-Host total follows yet. The model fixture makes the target plausible enough to retain; it does not establish the target for all tools, clients and evaluator activity. No additional memory quota, RSS admission controller, guessed worker allowance, allocator tuning or per-kind pool is justified by this accounting pass.

## Concrete remaining work

1. Derive final compiled Host/custody, Bash, Edit continuation and adapter-buffer sizes, including which phases overlap and ordinary target-identity checks; the accepted design removes Git eligibility helpers. Keep physical-footprint qualification separate from allocation arithmetic.
2. Apply the accepted single-lifecycle evaluator containment/population from [Choose Workflow Evaluator containment limits](https://github.com/DivyanshGolyan/onepage/issues/90) and effective SQLite settings from [Choose SQLite storage and command-work limits](https://github.com/DivyanshGolyan/onepage/issues/95). Current source constants are evidence to review, not silently accepted policy.
3. When integrated implementation exists, measure all-model, all-Bash, all-Edit and mixed fixtures with concurrent clients/evaluator activity, then repeated churn and idle. Include saturated settlement/import/capture and controls. Report actual peak and retained footprint; do not claim dormant-history independence from active-only tests.

The remaining quantities require the integrated implementation rather than additional settings. The Host policy review can close while these explicit derivation and qualification gates remain; this note does not authorize production implementation or claim a complete numeric total.

## Reproducible evidence pointers

- Local `codex/host-capacity-scaling`: `/tmp/onepage-host-capacity-scaling/research/host-transport-simple-memory/README.md` and `host-transport-realistic-uploads/comparison.md`. These exact fixture/build observations replace obsolete system-curl or larger-buffer numbers. The worktree also contains private transcript aggregates: do not publish it wholesale.
- Local `/tmp/onepage-client-saturation-probe/research/client-saturation-probe/README.md`: baseline-subtracted client measurements and exclusions.
- Local `codex/exact-edit-probe`, commit `63581a1`: `/tmp/onepage-exact-edit-probe/research/exact-edit-probe/README.md`, code and buffer results. Formula: `N + max(16,384,N) + N - 1`, with `1 <= N <= 16,384`.
- Local `codex/parser-two-pass-probe`, commit `aa880d1`: `/tmp/onepage-parser-two-pass/research/matklad-experiments/parser/TWO_PASS.md`, raw results and methods. No complete provider claim.
- Local scratch-accounting probe `f64a692`: `/tmp/onepage-scratch-accounting-probe/research/scratch-accounting-probe/README.md`.
- Historical evaluator capacities: [workflow_protocol.zig](../../src/workflow_protocol.zig), interpreted with the accepted evaluator decision and subsequent workflow amendments.

No new benchmark ran for this synthesis. References and arithmetic were checked; production source is unchanged.

## Bash source audit

The [Bash supervision audit](bash-memory-accounting.md) confirms current source accumulates stdout/stderr in RAM and returns owned slices. It is not a representative implementation of the accepted disk-first capture path, so no misleading future per-Bash cost was measured. The note names actual ownership terms and required real-child/capture fixtures; no synthetic worker allowance is substituted.

## Bash prototype update

[Follow-up evidence](bash-memory-accounting.md#follow-up-prototype-evidence) now supports small native supervision at real 1,000-child concurrency. Local `codex/bash-supervision-probe` commit `58be5e5` preserves measurements and limitations. Earlier statements that no benchmark ran refer to the initial synthesis/source audit, before this follow-up. Do not add its whole-process baseline to another prototype or treat it as whole-Host qualification.

## Evaluator source audit

[Evaluator accounting inputs](evaluator-memory-accounting.md) distinguish current engine limits, child mappings, parent buffers and address-space settings from resident cost. The simultaneous evaluator population remains an explicit open choice; a one-at-a-time test is recommended for discussion, not accepted by the accounting note.

## Evaluator prototype update

The [serial evaluator experiment](evaluator-memory-accounting.md#serial-evaluator-experiment), local commit `edc82c5`, provides real-engine evidence: child lifetime peak RSS medians around 5.5–5.9 MiB for small/aggregation work and 19.6 MiB at deliberate heap exhaustion. RSS is not the physical-footprint target, and sampled child+parent physical observations remain incomplete integration evidence. One thousand queued tiny evaluations take about 11.4 seconds at one evaluator; serial concurrency remains a recommendation, not accepted by test authorization. Full parent/Store integration and revised evaluator policy still matter.

## Accepted evaluator population — 7 September 2026

The user has now accepted one evaluation lifecycle at a time per Host, including outcome handling and safe cleanup, with a 16 MiB engine heap ceiling, 1-second process CPU budget and 5-second parent-owned elapsed lifetime backstop. Earlier open-population wording is historical. The evaluator accounting term therefore has multiplier at most one lifecycle, including its parent capture/import resources until release. This is independent of the 1,000 model/Bash/Edit custody capacity. Native buffers remain derived implementation capacities; neither engine heap nor the tested 2 MiB arena is a total physical-footprint bound. Integrated whole-Host qualification remains outstanding.

## Host accounting closeout — 8 September 2026

The current matrix explicitly includes evaluator input/capture/publication overlap and retained spillover outside the active scratch-container subtotal. The one-lifecycle evaluator policy, SQLite ownership/settings decision and single-owner inspection decision are settled inputs. Historical source/prototype numbers above retain their original scope. Complete compiled sizes, retained-file representation, OS descriptor validation and integrated memory/control qualification remain implementation obligations; no new component allowance, helper pool or numeric total is selected.
