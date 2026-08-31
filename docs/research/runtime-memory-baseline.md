# Runtime memory baseline

## Scope

This is an implementation baseline, not the V1 density release report. It measures the real
ReleaseSafe Host Runtime, Harness, Host Store, deterministic provider, and lifecycle path. It does
not yet exercise concurrent asynchronous Attempts, Codex transport, Bash subprocess memory, or a
JavaScript Workflow Run. Those costs must remain separate rather than being inferred from this
fixture.

The measurements were taken from a clean tracked tree at source commit
`b6943d92fddee5efa063a0c42a5adbe83da9be6a` on a
16 GiB MacBookPro18,1 running Darwin 24.6.0. The command was:

```sh
zig build measure-runtime-sweep -Dmeasurement-repetitions=3
```

It writes raw observations to `.zig-cache/onepage-runtime-measurements.jsonl` and a deterministic
summary to `.zig-cache/onepage-runtime-measurements-summary.json`. Each point runs in a fresh process;
build artifacts are warm, and the filesystem cache is uncontrolled. Values below are medians of three
independent processes followed by the complete observed range. `Physical delta` and `RSS delta` are
measured from the opened runtime to the completed workload so startup cost is not counted twice.
Durable bytes include only the Host state directory, not the fixture Workspace.

## Results

The median cost of opening an empty runtime over the already initialized fixture process was
966,848 B of macOS physical footprint (868,480–1,114,432 B) and 2,080,768 B of RSS
(1,998,848–2,195,456 B). It used one thread. The empty Host Store occupied 49,152 durable bytes.

| Workload | Active Capacity | Physical delta, median (range) | RSS delta, median (range) | Operations/s, median (range) | Durable bytes, median (range) |
| --- | ---: | ---: | ---: | ---: | ---: |
| 100 Dormant Sessions | 1 | 475,200 B (475,200–475,328) | 573,440 B (540,672–573,440) | 914.177 (892.554–928.583) | 96,016 B (96,016–100,112) |
| 1,000 Dormant Sessions | 1 | 721,088 B (639,168–819,392) | 786,432 B (704,512–884,736) | 855.878 (800.595–882.954) | 657,056 B (657,056–665,248) |
| 10,000 Dormant Sessions | 1 | 901,312 B (868,544–983,232) | 933,888 B (245,760–966,656) | 730.819 (729.478–787.966) | 6,021,696 B (6,013,504–6,050,368) |
| 100 completed turns | 1 | 2,556,288 B (2,523,520–2,704,128) | 2,719,744 B (2,686,976–2,768,896) | 195.795 (174.223–204.344) | 540,156 B (519,676–540,156) |
| 100 completed turns | 10 | 2,704,064 B (2,458,112–2,769,664) | 2,785,280 B (2,588,672–2,834,432) | 192.818 (182.525–202.332) | 523,772 B (519,676–531,964) |
| 100 completed turns | 100 | 2,490,752 B (2,425,280–2,736,704) | 2,654,208 B (2,572,288–2,850,816) | 181.717 (174.171–185.154) | 527,868 B (523,772–531,964) |

The footprint ranges overlap across completion capacities. This sequential fixture does not show a
resident memory slope from reserving another 99 small Activation Slots. Throughput fell from a median
195.795 to 181.717 operations/s between capacities 1 and 100, but this three-sample run does not
identify a cause.

| Workload | Median wall time | Median CPU time | Median disk reads | Median disk writes |
| --- | ---: | ---: | ---: | ---: |
| 100 Dormant Sessions | 109.388 ms | 99.676 ms | 0 B | 12,791,808 B |
| 1,000 Dormant Sessions | 1.168 s | 1.070 s | 16,384 B | 189,095,936 B |
| 10,000 Dormant Sessions | 13.683 s | 11.815 s | 1,495,040 B | 2,356,015,104 B |
| 100 completed turns, capacity 1 | 510.739 ms | 468.083 ms | 40,960 B | 71,798,784 B |
| 100 completed turns, capacity 10 | 518.625 ms | 475.617 ms | 20,480 B | 71,532,544 B |
| 100 completed turns, capacity 100 | 550.305 ms | 490.110 ms | 45,056 B | 71,499,776 B |

The durable representation stays small, but the SQLite workload writes far more bytes than the final
state occupies. This is an observed end-to-end storage cost, not yet proof of one defective component.
The next storage investigation should attribute transaction, WAL, checkpoint, and filesystem work
before changing durability behavior. Package idle wakeups were zero at every median point; interrupt
wakeups were zero except for the 10,000-Session workload, whose median was three.

The completion fixture is sequential. Its occupied high-water is one Slot at every configured
capacity. These points measure startup reservation and ordinary sequential overhead; they are not
evidence for 100 concurrent agents or provider calls.

## Fixed and variable footprint

| Resource | Owner and lifetime | Multiplier | Current evidence |
| --- | --- | --- | --- |
| Host Runtime and SQLite | Process, from runtime open to close | One | Empty-runtime physical-footprint delta is about 0.92 MiB in this fixture. SQLite has its own process-wide hard allowance and must be reported separately from current use. |
| Semantic-validation workspace | Host closure stage, borrowed only during admission | One in V1 | 256,224 B reserved, independent of Active Capacity. |
| Patch workspace | Host patch stage, borrowed only during preparation or reconciliation | One in V1 | 16,408 B reserved, independent of Active Capacity. |
| Activation Slot cells | Host, from runtime open to close | Exactly `active_capacity` | Each cell contains 168 B of decoded Core State and 8 B of generation/occupancy metadata. Capacity 1/10/100 reserves 168/1,680/16,800 Slot bytes plus 40/112/832 B of pool metadata. |
| Live Harness | Caller, from `Harness.open` to consuming `close` | Live owners only | The current owner is 8,088 B and is destroyed immediately. Historical open/close count has no retained Host list. |
| Dormant Session | SQLite and immutable content | Durable population | Durable bytes grow with population. The 1,000-to-10,000 physical-footprint delta is 180,224 B in the median run, so no resident per-Session owner is visible at this scale. |
| Provider or tool Attempt | Adapter, from durable admission to terminal evidence | Concurrent admitted Attempts | Not exercised here. It must own no Harness, Slot, or semantic-validation workspace and must be measured at real concurrency. |
| Workflow evaluation | Disposable evaluator process | One live evaluation in V1 | Not exercised here. Blocked and terminal Runs must retain zero evaluator processes. |
| Model-requested Bash tree | Workload process | Model-selected work | Outside the orchestration-memory bound; observe and report separately. |

## Missteps exposed

1. **Retaining closed handles confused misuse detection with ownership.** The runtime kept every
   closed 8,088-byte Harness until process shutdown. At 10,000 historical opens this produced an
   approximately 83.9 MiB physical-footprint slope. Making close consuming and destroying the owner
   immediately reduced the same median incremental footprint to about 0.88 MiB.
2. **Named bounds were mistaken for necessary state.** Two 4 KiB arrays lived in every Activation
   Slot even though production had no reader or writer for either. Moving scratch responsibility to
   the stages that actually use it reduced each Slot from 8,360 B to the 168-byte decoded Core State.
3. **A compile-time proof was mistaken for a product capacity.** `SlotPool(1)` proved one bounded
   activation but could not express a startup Host decision. One runtime-sized allocation now owns
   exact closed capacity without adding a scheduler or fallback path.
4. **Structure size was too easy to present as process cost.** The fixture now reports whole-process
   RSS and macOS physical footprint alongside exact requested reservation, metadata, occupancy, disk
   growth, time, CPU, threads, wakeups, page-ins, and I/O. Neither the 32 KiB ceiling nor the 168-byte
   current Slot is a per-agent process-memory claim.
5. **Fixture data was mixed with durable Host state.** The old durable-byte total included the sibling
   Workspace. The fixture now gives Host state and mutable task files separate roots, and a regression
   test proves Workspace growth cannot change the durable-state measurement.

The common correction is ownership by job and lifetime: durable authority belongs on disk; decoded
semantic state belongs in a short-lived Slot; closure scratch belongs to the closure stage; transport
state belongs only to an admitted Attempt; and workflow state belongs to a disposable evaluation.
Making those jobs explicit removed memory and code rather than requiring a more elaborate allocator.

## Next evidence

The next vertical slice should use an ordinary JavaScript Workflow once the Run/Job driver can hold
real asynchronous work. Hold durable population fixed, drive Active Capacity 1, 10, 50, and 100,
dirty every Slot through production activation, and separately report execution cells, worker stacks,
libcurl/TLS/resolver state, parser windows, immutable output occupancy, evaluator child memory,
latency, throughput, cancellation, and workload subprocess memory. Until then, this baseline supports
the dormant-density and startup-reservation claims only.
