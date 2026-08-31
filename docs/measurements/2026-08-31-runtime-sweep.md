# Runtime capacity and density baseline

This is the first whole-process measurement of the runtime-sized Activation Pool on top of the sole SQLite Host Store. It is implementation evidence for issue #3, not the final V1 density gate: model transport, asynchronous Attempts, effect subprocesses, JavaScript Workflow Runs, and true concurrent occupancy are not exercised.

The measured source is clean commit `90ff88743290cd2cd937e45a98451d38af4bf1be`. Each point uses a fresh ReleaseSafe process on a 16 GiB MacBookPro18,1 running Darwin 24.6.0 and Zig 0.16.0. Build artifacts are warm, the filesystem cache is uncontrolled, and values are medians of three independent processes with the complete observed range retained in the machine-readable artifacts:

- [`2026-08-31-runtime-sweep.jsonl`](2026-08-31-runtime-sweep.jsonl)
- [`2026-08-31-runtime-sweep-summary.json`](2026-08-31-runtime-sweep-summary.json)

Reproduce the run with:

```sh
zig build measure-runtime-sweep -Dmeasurement-repetitions=3
```

## Fixed runtime resources

The Activation Slot now contains only decoded Core State and is 168 bytes. Startup reservation is exact and linear:

| Active Capacity | Slot reservation | Pool metadata | Active Credit reservation | Observed Slot high water |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 168 B | 40 B | 1 B | 168 B |
| 10 | 1,680 B | 112 B | 10 B | 1,680 B |
| 100 | 16,800 B | 832 B | 100 B | 16,800 B |

Before each workload, a measurement-only probe borrows and dirties every Slot in the production pool, samples while all are held, releases them through the ordinary scrub path, and samples again. The physical-footprint and RSS deltas from runtime-open were zero at both boundaries for capacities 1, 10, and 100; the exact occupied high water proves all configured Slot bytes were touched. The completion workload itself remains sequential and uses one Active Credit at a time, so this is not evidence for 100 concurrent agents.

Other process-owned resources do not multiply with Active Capacity:

| Resource | Reservation | Observed high water | Lifetime |
| --- | ---: | ---: | --- |
| Live Harness owner | 8,112 B each | one in this sequential fixture | `Harness.open` to consuming `close`; zero owners remain after every workload |
| Semantic-validation workspace | 256,224 B | 256,200 B | one shared closure stage in V1 |
| Patch workspace | 16,408 B | 0 B in this fixture | one shared patch stage in V1 |

Opening an empty runtime added a median 950,464 B of macOS physical footprint (786,496–1,147,328 B) and 2,097,152 B of RSS (1,966,080–2,228,224 B). That process cost includes SQLite, libc, allocator effects, and operating-system accounting; it is not an Activation Slot cost.

## Dormant density

Each Dormant Session is created through the real Host Runtime, Harness, Session, and SQLite path, after which its Harness is destroyed. No live Harness, Slot, Active Credit, validation workspace, or per-Session filesystem object remains.

| Dormant Sessions | Physical-footprint delta | RSS delta | Final durable bytes | Sessions/s | Process disk writes |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 100 | 1,556,928 B | 1,556,480 B | 110,592 B | 1,459.769 | 13,320,192 B |
| 1,000 | 1,999,488 B | 1,998,848 B | 679,936 B | 1,310.154 | 195,039,232 B |
| 10,000 | 2,425,408 B | 2,408,448 B | 6,221,824 B | 1,252.281 | 2,336,571,392 B |

Between 1,000 and 10,000 Sessions, the median physical-footprint slope is about 47 bytes per additional Session and the RSS slope is about 46 bytes. This does not prove a literal resident object of that size: SQLite page residency and allocator/OS accounting are included, and the complete observed ranges overlap. It does show that dormant population is not retaining the 8,112-byte Harness or any fixed activation resource.

The storage path remains the dominant inefficiency. The 10,000-Session run wrote about 2.34 GB to produce about 6.22 MB of logical SQLite state—an observed ratio of roughly 376:1. Rollback-journal durability and one transaction per Session are included in that number. The sole-store cutover simplified ownership and atomicity, but did not remove the write work; changing transaction grouping or durability policy requires a separate measured design rather than being hidden inside this memory slice.

The v2 evidence also distinguishes final SQLite allocation from cumulative work:

| Dormant Sessions | SQLite logical / allocated | Pager writes / spills | SQLite heap before / after / workload high water |
| ---: | ---: | ---: | ---: |
| 0 | 57,344 / 57,344 B | 0 / 0 | 200,880 / 200,880 / 200,880 B |
| 100 | 110,592 / 110,592 B | 1,044 / 2 | 200,880 / 200,960 / 321,392 B |
| 1,000 | 679,936 / 679,936 B | 11,176 / 1,083 | 200,880 / 200,960 / 419,696 B |
| 10,000 | 6,221,824 / 6,340,608 B | 117,074 / 17,277 | 200,880 / 200,960 / 433,008 B |

## Completed lifecycle

The complete deterministic Harness-to-SQLite-to-provider-to-semantic-closure path completed 100 Sessions at each configured capacity:

| Active Capacity | Physical-footprint delta | RSS delta | Operations/s | Disk writes |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 2,638,400 B | 2,736,128 B | 216.394 | 85,639,168 B |
| 10 | 2,490,880 B | 2,605,056 B | 229.381 | 86,241,280 B |
| 100 | 2,753,152 B | 2,834,432 B | 222.985 | 86,032,384 B |

The observed ranges overlap. In this sequential workload, raising the declared Active Capacity from 1 to 100 adds only the exact fixed pool reservation and does not create a measurable throughput or whole-process-memory slope.

## Supported conclusion

This evidence supports the narrow current claim:

> Activation Slot reservation is exactly 168 bytes times configured Active Capacity, plus measured fixed pool metadata. Every configured Slot is dirtied, held, and released through the production pool before process residency is reported. Closed Harnesses are reclaimed immediately, and 10,000 Dormant Sessions retain durable SQLite state rather than resident Harness, Slot, Active Credit, or validation-workspace owners.

It does not yet support flat total RSS, true capacity-100 concurrency, provider-transport memory, effect-process memory, workflow-evaluator memory, or scheduling-latency claims. Those remain later vertical-slice gates.
