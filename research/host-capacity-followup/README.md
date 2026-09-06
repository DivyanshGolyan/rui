# Throwaway control and memory follow-up

Question: can stop handling and cleanup remain prompt during a completion burst, and what memory remains after ordinary cleanup?

**Verdict:** in this fixture, servicing both a stop request and its already-sealed cancellation result between ordinary results removes a substantial owner-side delay. After five waves, much of the remaining physical footprint is reclaimable allocator memory, with a much smaller volume of allocator-live allocations. These observations support simple control-service turns and ordinary resource cleanup; they do not select a concurrency default, an idle-footprint target or a production reclamation policy.

This extends the [capacity experiment](../host-capacity-scaling/README.md) for [Set Host Runtime admission controls and budgets](https://github.com/DivyanshGolyan/onepage/issues/68). Production code and accepted contracts are unchanged. The same temporary upstream curl 8.7.1 build with experimental Darwin `HAVE_POLL_FINE` override is used. The system-library limitation and dependency qualification from the earlier report remain open.

## Control experiment

Each case admits 100, 500 or 1,000 verified localhost TLS model streams. All upload 4 KiB and emit 100 small events per second for four seconds. Every stream except one emits its synchronized 64 KiB terminal item; the final operation stays open awaiting cancellation. An independent synthetic sender thread submits stop after the owner starts processing the first completed result.

The owner commits a stop row in a scratch `probe_stop` table and publishes cancellation to the reactor. The reactor removes the exact matching active transfer and seals its cancellation evidence. The server must observe EOF. The owner durably records typed cancellation, discards that operation's raw output, closes its spool and releases custody. The completion and cancellation checks establish exact counts and identities for this held target, not the production Run API or current normative schema.

Three modes separate the decisions:

- **1: whole pass.** Check for the stop only between complete owner passes.
- **2: between results.** Also check for the stop after each ordinary result. Cancelled-result cleanup still follows the normal table order.
- **3: between results including cancellation cleanup.** Also service the known cancelled target as soon as it is sealed, between ordinary results. This adds no second queue, worker or custody pool. It uses the target already identified by the pending stop.

Three repetitions per mode/capacity. The first matrix rotates capacities and reverses mode-1/mode-2 order in the middle rotation. The mode-3 follow-up uses three rotated capacity orders. These are small, sequential samples on a shared machine, not matched deterministic timing replays or percentile certification.

All timing columns are milliseconds from synthetic request publication; medians except the explicitly labelled maximum. The final column is the median within-run delay from reactor removal to owner release, so it need not equal the difference between other medians.

| Capacity | Mode | Stop committed | Transfer removed | Fully released | Maximum full release | Removal to release |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 100 | 1 | 5.08 | 6.96 | 58.41 | 76.52 | 51.68 |
| 100 | 2 | 1.06 | 6.38 | 68.56 | 79.52 | 61.37 |
| 100 | 3 | 0.81 | 7.11 | 7.75 | 8.28 | 0.64 |
| 500 | 1 | 149.63 | 161.73 | 332.39 | 383.75 | 168.62 |
| 500 | 2 | 1.01 | 46.83 | 317.40 | 393.11 | 283.68 |
| 500 | 3 | 1.38 | 52.80 | 53.32 | 70.30 | 1.18 |
| 1,000 | 1 | 62.91 | 155.86 | 765.38 | 786.27 | 576.73 |
| 1,000 | 2 | 1.71 | 8.73 | 393.76 | 679.23 | 391.63 |
| 1,000 | 3 | 1.30 | 138.83 | 139.26 | 161.81 | 0.52 |

Checking requests between results makes their durable handling prompt in this fixture, but acknowledgement alone conceals a backlog before full release. Mode 3 addresses that second owner delay. At 1,000, mode-3 post-removal cleanup takes a median 0.52 ms; most remaining request-to-release time is before reactor removal. These observations motivate measuring the reactor's own service intervals next if the selected control-latency target requires it. They do not justify adding an executor/scheduler framework or declaring stop latency solved.

The sender communicates through an atomic flag; this deliberately isolates owner scheduling. It does not measure client socket ingress, authentication, decoding or a production durable command protocol. The sender's short polling wait is outside the measured request interval. `pending_at_commit` includes the held target; it must not be used alone to claim ordinary work remained. The checks instead require request publication before ordinary-result completion. A single long import or SQLite commit remains non-preemptible. Completion-versus-stop races, crash/replay, multiple ready controls, fairness and real-provider cancellation remain outside this fixture. Server `terminal_write_seconds` includes waiting for cancellation here, so it is not purely a terminal-write duration.

## Memory experiment

A separate process runs five waves of 1,000 without cancellation. `malloc_zone_statistics(NULL, ...)` sums all malloc zones, per the macOS SDK header. `size_in_use` measures allocator-live allocated bytes, not reachability, a leak diagnosis, or total process memory. `size_allocated` is allocator reservation, not physical RAM. OS physical footprint is recorded independently.

| Phase | Live malloc MiB | Allocator reservation MiB | Physical footprint MiB |
| --- | ---: | ---: | ---: |
| Host idle before work | 0.29 | 55.00 | 2.56 |
| After wave 1 | 1.28 | 98.00 | 49.70 |
| After wave 2 | 1.40 | 98.00 | 59.14 |
| After wave 3 | 1.38 | 106.00 | 49.02 |
| After wave 4 | 1.39 | 106.00 | 60.16 |
| After wave 5 | 1.49 | 106.00 | 55.44 |
| Transport reactor/multi closed | 1.47 | 106.00 | 55.31 |
| SQLite closed | 1.34 | 104.00 | 54.16 |
| curl global cleanup completed | 1.34 | 104.00 | 54.16 |
| Two seconds of natural idle | 1.34 | 104.00 | 54.19 |
| After diagnostic allocator relief | 1.34 | 104.00 | 6.35 |

Ordinary cleanup released every operation's custody and charged scratch after each wave. The process had eight descriptors at each live-Host idle checkpoint, six after reactor closure and three after SQLite closure. Closing the remaining libraries and waiting did not substantially reduce footprint. A diagnostic `malloc_zone_pressure_relief(NULL, 0)` was then followed by a 47.84 MiB footprint reduction with unchanged live-allocation volume; the API itself reported zero bytes relieved. This is strong evidence that much of the residual footprint is reclaimable allocator memory, rather than accumulated live results. It does not account for every page or prove indefinite leak freedom or reuse of particular pages.

Live malloc bytes rise by about 0.21 MiB from first to fifth idle checkpoint. The five-wave run cannot establish whether that small residual stabilizes indefinitely. Phase differences are localization clues, not exact per-library attribution: framework/global caches, direct VM allocations and asynchronous reclamation can overlap snapshots. The two-second idle and relief observations occur after transport and database closure, so they do not establish a live-Host reclamation policy. Reclamation is a diagnostic control here, not a required correctness mechanism.

## Evidence and reproduction

**28 measured cases passed, with 19,400 settled operations: 19,373 ordinary successes and 27 expected cancellations.** Every cohort reached its full requested concurrent population. Generated and received body byte counts matched; stored counts equalled received counts minus the cancelled target's discarded raw bytes. SQLite integrity passed and final descriptors/scratch returned to baseline. These are length/framing/accounting checks, not a byte-for-byte comparison against expected payload buffers.

The first 19-case matrix is in `results.json`, with its measured source preserved at commit `ed9bee8`. `refined-results.json` captures nine mode-3 cases measured at commit `a28800c` and their source hashes. A later CLI-only guard rejects combining `--refined` with `--capacity`, which previously could mislabel a mode-1/mode-2 run; the measured commands used neither conflicting combination. The original and refined smoke results are retained separately. Exact hardware, toolchain, source hashes and custom libcurl configuration/archive hash are in the raw metadata. Existing limitations of the historical scratch schema, minimal validator, synthetic provider, load-generator interference and unmeasured whole-Host components continue to apply. No Bash/Patch workload or its OnePage-owned supervision machinery runs here. Kernel/file-cache accounting is outside the malloc/process measurements.

Run both matrices with:

```sh
python3 research/host-capacity-followup/experiment.py
```

It builds the same experimental dependency in temporary storage without installation and removes it afterwards. The recorded session built the dependency first, then ran `run.py --curl-build /tmp/onepage-capacity-followup-curl/curl-8.7.1` and the same command with `--refined`. The convenience wrapper composes those commands and was syntax-checked rather than rerun. Recompute the report without load using `python3 research/host-capacity-followup/summarize.py`.
