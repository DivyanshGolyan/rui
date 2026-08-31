# Runtime capacity and density baseline

This is the first whole-process measurement of the runtime-sized Activation Pool on top of the sole SQLite Host Store. It is implementation evidence for issue #3, not the final V1 density gate: model transport, asynchronous Attempts, effect subprocesses, JavaScript Workflow Runs, and true concurrent occupancy are not exercised.

The measured source is clean commit `55f4b1f383de22f9d90e56a95e766f390982e848`. Each point uses a fresh ReleaseSafe process on a 16 GiB MacBookPro18,1 running Darwin 24.6.0 and Zig 0.16.0. Build artifacts are warm, the filesystem cache is uncontrolled, and values are medians of three independent processes with the complete observed range retained in the machine-readable artifacts:

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
| 10 | 1,680 B | 112 B | 10 B | 168 B |
| 100 | 16,800 B | 832 B | 100 B | 168 B |

The completion fixture is sequential, so it dirties and releases one Slot and one Active Credit at a time. These points prove startup reservation and release; they are not evidence for 100 concurrent agents.

Other process-owned resources do not multiply with Active Capacity:

| Resource | Reservation | Observed high water | Lifetime |
| --- | ---: | ---: | --- |
| Live Harness owner | 8,112 B each | one in this sequential fixture | `Harness.open` to consuming `close`; zero owners remain after every workload |
| Semantic-validation workspace | 256,224 B | 256,200 B | one shared closure stage in V1 |
| Patch workspace | 16,408 B | 0 B in this fixture | one shared patch stage in V1 |

Opening an empty runtime added a median 1,016,064 B of macOS physical footprint (917,696–1,081,600 B) and 2,162,688 B of RSS (2,080,768–2,228,224 B). That process cost includes SQLite, libc, allocator effects, and operating-system accounting; it is not an Activation Slot cost.

## Dormant density

Each Dormant Session is created through the real Host Runtime, Harness, Session, and SQLite path, after which its Harness is destroyed. No live Harness, Slot, Active Credit, validation workspace, or per-Session filesystem object remains.

| Dormant Sessions | Physical-footprint delta | RSS delta | Final durable bytes | Sessions/s | Process disk writes |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 100 | 1,409,344 B | 1,425,408 B | 110,592 B | 1,278.658 | 13,258,752 B |
| 1,000 | 1,917,376 B | 1,916,928 B | 684,032 B | 1,136.674 | 192,995,328 B |
| 10,000 | 2,818,624 B | 2,768,896 B | 6,217,728 B | 1,063.449 | 2,361,253,888 B |

Between 1,000 and 10,000 Sessions, the median physical-footprint slope is about 100 bytes per additional Session and the RSS slope is about 95 bytes. This does not prove a literal resident object of that size: SQLite page residency and allocator/OS accounting are included. It does show that dormant population is not retaining the 8,112-byte Harness or any fixed activation resource.

The storage path remains the dominant inefficiency. The 10,000-Session run wrote about 2.36 GB to produce about 6.22 MB of final Host state—an observed ratio of roughly 380:1. Rollback-journal durability and one transaction per Session are included in that number. The sole-store cutover simplified ownership and atomicity, but did not remove the write work; changing transaction grouping or durability policy requires a separate measured design rather than being hidden inside this memory slice.

## Completed lifecycle

The complete deterministic Harness-to-SQLite-to-provider-to-semantic-closure path completed 100 Sessions at each configured capacity:

| Active Capacity | Physical-footprint delta | RSS delta | Operations/s | Disk writes |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 2,523,584 B | 2,605,056 B | 183.030 | 85,331,968 B |
| 10 | 2,720,256 B | 2,768,896 B | 184.240 | 85,942,272 B |
| 100 | 2,638,272 B | 2,719,744 B | 183.424 | 85,336,064 B |

The observed ranges overlap. In this sequential workload, raising the declared Active Capacity from 1 to 100 adds only the exact fixed pool reservation and does not create a measurable throughput or whole-process-memory slope.

## Supported conclusion

This evidence supports the narrow current claim:

> Activation Slot reservation is exactly 168 bytes times configured Active Capacity, plus measured fixed pool metadata. Closed Harnesses are reclaimed immediately, and 10,000 Dormant Sessions retain durable SQLite state rather than resident Harness, Slot, Active Credit, or validation-workspace owners.

It does not yet support flat total RSS, true capacity-100 concurrency, provider-transport memory, effect-process memory, workflow-evaluator memory, or scheduling-latency claims. Those remain later vertical-slice gates.
