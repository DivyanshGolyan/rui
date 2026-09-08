# Historical Host budget issue body

Preserved before consolidation; current decisions live on the live issue.

## Accepted execution and diagnostic input

[Operations own current execution and immutable final results](https://github.com/DivyanshGolyan/onepage/issues/106#issuecomment-5556976932). Current facts live in SQLite; historical Attempt/Completion rows and separate Resolution identity are not authority. Preserve fixed-capacity content-free custody, bounded snapshots and shared import, with no resident object per dormant Operation. Numeric controls remain undecided here.

Default local diagnostic summaries persist with bounded retention; detailed capture is explicit and users can export recent diagnostics. Include diagnostic encoding/capture/rotation/export within the existing Host resource ownership. A diagnostic disk quota is not a RAM-buffer target. Account for retry churn, retained disk bytes, export, filesystem-cache/writeback and command latency without adding a second execution authority or history cache. Exact retry policy remains with its effect-budget owner.

## Inspection scratch and progress coordination — 6 September 2026

The accepted follow-up in #112 gives ready controls and ordinary settlement/advancement bounded turns between captures, with inspection progress under sustained ready work. It also requires fixed-window encoding with block writes. #95 retains service quantum, single-capture work/delay, and explicit incomplete-report failure/retry decisions; no strict deadline or abort quota is selected.

The completed synthetic evidence in #113 reached 602.88 MB of logical scratch with one completed wide report retained during the next capture, despite small resident buffers and a SQLite heap high-water of 181,840 bytes. These are distinct measurements, not a whole-Host memory bound or a product quota. Include current capture plus retained completed reports, slow clients, abandonment, temporary-disk exhaustion, and filesystem-cache pressure in existing aggregate admission/accounting and cleanup verification. No second reader, shared-workspace manager, or new implementation issue follows.

## Parser and SQLite evidence coordination — 6 September 2026

The accepted contract refinement in #112 and historical experiment publication in #113 make the disk-first path concrete without changing the single-owner topology. Account for bounded resident parser state separately from item/range metadata in charged scratch. No additional sharing between validation and inspection is required; the existing serial validation/import workspace remains.

#95 owns effective SQLite cache/spill/heap policy, failed-import behavior, and representative single-capture work/delay. This issue retains aggregate resource budgets and sustained-load coordination; include the resulting SQLite and scratch measurements in whole-Host accounting. Prototype parser allocations and heap/cache settings are evidence, not production defaults or integrated memory certification. No new implementation issue is created.

## Accepted execution-control simplification

[Accepted execution-control simplification](https://github.com/DivyanshGolyan/onepage/issues/68#issuecomment-5553520534) selects the qualitative mechanisms: one startup-sized in-memory custody table and plain scans, SQLite-mediated durable admission without a duplicate slot table, event-driven sleeping with required deadlines and the existing bounded retry poll preserved, and a bounded turn for ready controls before another queued inspection capture. No whole-process ban on post-startup allocation is introduced. This issue still decides numeric capacity/resource budgets, overload behavior, and retry-poll cadence; the query-work owner still decides acceptable single-capture delay and sustained-load fairness. Measurements remain evidence, not automatic defaults or ceilings.

## Architecture handoff

[Choose live Host ownership and cross-process command semantics](https://github.com/DivyanshGolyan/onepage/issues/100#issuecomment-5549173568) adds the local server and inbound-client population to this budget decision. Include its listed resource and overload obligations and linked prototype evidence. The experiment does not choose numeric budgets or certify the integrated server.

## Accepted inspection input

[The historical Run inspection decision](https://github.com/DivyanshGolyan/onepage/issues/39) captures complete reports on the existing connection before delivery. Budget one serial Host capture workspace and the separate population of completed reports retained by slow clients. Account for aggregate unlinked scratch, descriptors, bounded buffers, filesystem-cache pressure, cleanup, and retained-after-churn memory. Other database work waits during capture; admission/fairness and concurrent-polling verification must protect command progress. #95 owns the query/capture work policy. The synthetic timings select no numerical limits or durable collection quotas.

## Objective

Choose the minimum Host admission controls, numeric release budgets, and overload rules needed before implementation, using the integrated prototype and prior-art evidence rather than arbitrary constants.

This issue combines the former qualitative Host-control question from #87 with the numeric Host Runtime budget decision. VERIFICATION.md owns certification of the completed production system; implementation/certification slices will be created after design readiness.

## Contract to decide

- whether startup `active_capacity` needs a default, a configurable platform-derived maximum, or only validation against resources actually reserved;
- whether Active Capacity 100 is a release-certification target, product default, hard maximum, or some combination;
- which aggregate admission controls are required for Physical Custody, unlinked scratch, descriptors, sockets, temporary Action executors, filesystem/cache pressure, and shared import work;
- separate budgets for unopened, Store-open, and Host-started idle baseline; per-active OnePage memory; aggregate process high-water; SQLite heap/cache; kernel/socket pressure; transient disk; descriptors; and retained-after-churn state;
- which pressures are measured and reported rather than rejected at admission;
- how admission failure, mid-effect exhaustion, temporary backpressure, and fail-stop differ; and
- the initial retry-eligibility poll cadence, using measured Host CPU, SQLite work, retry lateness, and terminal-burst evidence rather than a second timer mechanism.

## Measurement model

Use issue #67's partial prototype evidence where its topology still matches the normative design, and report analytical and observed values separately for:

- Physical Custody reservation and occupancy;
- provider transport, TLS, sockets, resolver, descriptors, kernel buffers, and filesystem cache;
- I/O Reactor cost measured by #67, plus analytical provisional bounds for temporary Bash/Patch Action executors that #67 did not measure in their final topology;
- fixed borrowed windows and the shared validation/import workspace;
- SQLite heap, cache, database, journal/WAL, transaction work, and import bursts;
- unlinked request/output scratch logical and physical bytes plus raw/canonical overlap; and
- model-requested subprocess memory, reported separately as workload memory.

V1 has no permanent Patch lane. #67's serial-Patch measurements do not certify the replacement topology. #68 must set a conservative pre-implementation executor budget from explicit analytical assumptions; Production verification later certifies or revises that target before release under VERIFICATION.md. A content or disk budget never authorizes an equally large resident allocation. Retain library or executor machinery after use only when measured reuse is simpler and fits the approved idle envelope.

## Constraints

- Primary goals are memory efficiency and simplicity. Default to no control unless it protects a concrete resource or semantic guarantee.
- Durable Session, Turn, User Message, Operation, and history cardinality do not protect resident memory and gain no quota here.
- Do not duplicate SQLite command-work decisions owned by #95.
- Every retained control names one resource, population multiplier, owner, release boundary, typed overload result, and verification method.
- Workload observations are evidence, not automatic product ceilings.

## Acceptance criteria

- [ ] The chosen controls preserve one in-memory custody table and SQLite durable authority; measured wake/scheduling cost is reported separately from scan arithmetic, without an empty-table scan timer or whole-process static-allocation mandate.

- [ ] Every retained Host control and numeric budget has one protected resource, owner, multiplier, overload behavior, evidence, and verification method.
- [ ] Active Capacity 100 is classified independently as certification target, default, and hard maximum.
- [ ] Admission controls, configurable budgets, analytical bounds, observed high-water, and verification targets are distinct.
- [ ] No durable-backlog, per-Session, per-Turn, per-message, or generic content quota is introduced solely for memory safety.
- [ ] Process RSS/private dirty, virtual memory, kernel/socket, filesystem-cache, transient-disk, database, and workload-memory costs are kept distinct.
- [ ] Any unexplained per-active or retained-idle slope triggers architecture review before adding a pool, cache, buffer, or duplicate representation.
- [ ] The result gives #89 a finite pre-implementation limit matrix and publishes numeric production-certification targets in VERIFICATION.md without requiring the final implementation to exist first.

## Parent

- #85

## Blocks

- #89

## Related work

- Integrated prototype and evidence: #67
- SQLite limits: #95
- Production-system certification: VERIFICATION.md, Memory and density; no active implementation ticket during design.
