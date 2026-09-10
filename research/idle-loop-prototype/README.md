# Throwaway idle-loop measurement

Measured 2026-09-09 on Apple M1 Pro/macOS, Apple clang 17, optimized native C. No production integration or Linux runtime claim. Source, host description and raw CSV accompany this note.

Question: is scanning a startup-fixed array cheap enough to run continuously?

## Prior art

[libuv design](https://docs.libuv.org/en/v1.x/design.html) waits for I/O when appropriate and computes its wait from pending work and timers. [curl_multi_poll](https://curl.se/libcurl/c/curl_multi_poll.html) waits for socket activity or a deadline, accepts extra application descriptors, and waits even when curl has no descriptors. These support ordinary event-driven waiting, not periodic arbitrary sleeps or a requirement to adopt libuv.

## Method

Each synthetic record is 256 bytes with a volatile state field initialized to neutral. The scan reads every state; volatile prevents removal by optimization. Scan-only mode loops continuously, checking elapsed time after each 1024 passes. Busy mode scans then polls a pipe with timeout zero. Wait mode scans then blocks in poll until the pipe becomes readable. A child emits a stop after two idle seconds, or 200 timestamps at roughly 5–10 ms intervals. Parent process CPU excludes child CPU. Event latency measures time from just before the child write until parent receipt; it includes IPC and OS scheduling. Each case ran once on a shared interactive machine, not an isolated performance rig. Poll overhead and scan-only costs are measured separately.

## Results

At 64 slots (16 KiB synthetic tracking array):

| Mode | Idle CPU, percent of one core | Scans in about two seconds |
| --- | ---: | ---: |
| Continuous scan only | 99.26% | 93,572,096 |
| Scan plus zero-timeout poll | 18.05% | 174,676 |
| Scan plus blocking poll | 0.0010% | 1 |

The scan-only 64-slot case averages roughly 21 ns per pass in this hot-cache synthetic loop. It is not production advancement cost. Across 4/64/1024 slots, scan-only consumed about 99% of one core; zero-timeout poll consumed 17.5–22.8%; blocking idle consumed 0.0006–0.0023%. Tiny idle CPU figures are short-run measurement-floor observations, not precise sustainable guarantees.

With 200 events at 64 slots, busy polling used 18.07% CPU with median/p99 receipt latency 8/31 microseconds; blocking wait used 0.215% CPU with median/p99 26/633 microseconds. The other capacities show the same qualitative tradeoff; see results.csv. The small sample and scheduling noise do not establish worst-case latency. No timers, SQLite queries, live transports, tool executions or loaded-slot advancement are modeled.

## Conclusion

Individual neutral scans are cheap; unrestricted repetition is not negligible. Keep the fixed full-array pass and use an ordinary OS/event-library wait when no immediate progress is possible. Blocking wait adds scheduling latency, but this run observed sub-millisecond p99 receipt latency. Production must still wake for commands and cleanup, honor timer deadlines, and avoid waiting when local work can progress. This is evidence for the baseline, not certification of OnePage latency or a selected polling backend.

## Reproduce

Compile `bench.c` with `cc -O2 -Wall -Wextra bench.c -o /tmp/onepage-idle-bench` from this directory. Run `/tmp/onepage-idle-bench 64 wait idle`, substituting `busy` or `scan`; use `events` for the event scenario with busy/wait. Each invocation emits one CSV row using the header in results.csv. The binary is disposable; no database or external service is used.
