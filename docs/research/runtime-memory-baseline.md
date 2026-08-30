# Runtime memory baseline

## Scope

This is an implementation baseline, not the V1 density release report. It measures the real
ReleaseSafe Host Runtime, Harness, Host Store, deterministic provider, and lifecycle path. It does
not yet exercise concurrent asynchronous Attempts, Codex transport, Bash subprocess memory, or a
JavaScript Workflow Run. Those costs must remain separate rather than being inferred from this
fixture.

The measurements were taken at source commit `4253b801e979395f69627030de1f6e0e95665c5f` on a
16 GiB MacBookPro18,1 running Darwin 24.6.0. The command was:

```sh
zig build measure-runtime-sweep -Dmeasurement-repetitions=3
```

It writes the raw machine-readable observations to
`.zig-cache/onepage-runtime-measurements.jsonl`. Values below are medians of three independent
processes. `Physical delta` and `RSS delta` are measured from the opened runtime to the completed
workload so startup cost is not counted twice.

## Results

The median cost of opening an empty runtime over the already initialized fixture process was
852,096 B of macOS physical footprint and 1,982,464 B of RSS. It used one thread. The empty Host
Store and state directory occupied 76,413 durable bytes.

| Workload | Active Capacity | Physical delta | RSS delta | Operations/s | Durable bytes |
| --- | ---: | ---: | ---: | ---: | ---: |
| 100 Dormant Sessions | 1 | 491,584 B | 622,592 B | 852.937 | 127,373 B |
| 1,000 Dormant Sessions | 1 | 786,624 B | 884,736 B | 769.933 | 692,509 B |
| 10,000 Dormant Sessions | 1 | 901,312 B | 999,424 B | 769.976 | 6,065,341 B |
| 100 completed turns | 1 | 2,622,080 B | 2,719,744 B | 207.186 | 555,129 B |
| 100 completed turns | 10 | 2,720,320 B | 2,834,432 B | 197.985 | 551,033 B |
| 100 completed turns | 100 | 2,753,088 B | 2,867,200 B | 191.728 | 555,129 B |

The completion fixture is sequential. Its occupied high-water is one Slot at every configured
capacity. These points measure startup reservation and ordinary sequential overhead; they are not
evidence for 100 concurrent agents or provider calls.

## Fixed and variable footprint

| Resource | Owner and lifetime | Multiplier | Current evidence |
| --- | --- | --- | --- |
| Host Runtime and SQLite | Process, from runtime open to close | One | Empty-runtime physical-footprint delta is about 0.81 MiB in this fixture. SQLite has its own process-wide hard allowance and must be reported separately from current use. |
| Semantic-validation workspace | Host closure stage, borrowed only during admission | One in V1 | 256,224 B reserved, independent of Active Capacity. |
| Patch workspace | Host patch stage, borrowed only during preparation or reconciliation | One in V1 | 16,408 B reserved, independent of Active Capacity. |
| Activation Slot cells | Host, from runtime open to close | Exactly `active_capacity` | Each cell contains 168 B of decoded Core State and 8 B of generation/occupancy metadata. Capacity 1/10/100 reserves 168/1,680/16,800 Slot bytes plus 40/112/832 B of pool metadata. |
| Live Harness | Caller, from `Harness.open` to consuming `close` | Live owners only | The current owner is 8,088 B and is destroyed immediately. Historical open/close count has no retained Host list. |
| Dormant Session | SQLite and immutable content | Durable population | Durable bytes grow with population. The 1,000-to-10,000 resident delta is only 114,688 B in the median run, so no resident per-Session owner is visible at this scale. |
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
