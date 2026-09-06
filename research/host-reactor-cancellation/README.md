# Reactor cancellation experiment

Throwaway macOS probe, not production code or a selected capacity/latency policy.

Initial `results.json`: 18 paired runs at 100, 500 and 1,000 TLS streams.
Mode 1 checks cancellation after the completion batch; mode 2 also checks before
and after waiting and between completion messages. The owner uses the previously
measured mode 3, servicing cancellation cleanup between ordinary settlements.
All cases pass the fixture's byte-count, SQLite, cancellation and cleanup checks.

The pending phase array is ordered: other, scan, poll, pipes, perform,
completion messages, cancellation. It partitions durable stop commit to handle
removal plus easy-handle cleanup. Most delay is inside `curl_multi_perform`.
That includes callbacks and scheduling; it does not identify a libcurl internal
cause. `phase_at_commit` is unassigned in this first version and must be ignored.
`completions_before_cancel` includes completions before the request, and phase
maxima measure segments, not necessarily whole batches.

See ../host-capacity-followup/README.md for the synthetic held-open-target
fixture and its limitations, and ../host-capacity-scaling/README.md for the
experimental curl 8.7.1 build with HAVE_POLL_FINE overridden on Darwin.
The measurements do not qualify a supported transport build.

Run: `python3 research/host-reactor-cancellation/run.py --curl-build /path/to/curl-8.7.1`.
Add `--smoke` for a small run. Source hashes and environment are in each JSON.

## Per-socket follow-up

`socket-results.json` compares mode 2 with mode 3 in 18 further paired runs:
three repetitions at each capacity, rotated capacities and reversed mode order
in the middle repetition. Mode 3 uses the existing fixed-size native poll/socket
interest prototype and `curl_multi_socket_action`, checking cancellation between
individual ready socket events as well as between completion messages. One
reactor, one owner, the same custody array and the same import workspace remain.
The alternate backend's fixed interest/poll arrays already existed in the probe;
this experiment adds no worker, dynamic queue or allocator policy.

| Concurrent streams | Mode 2 median request to release | Mode 3 median | Mode 3 maximum observed |
| ---: | ---: | ---: | ---: |
| 100 | 6.90 ms | 1.95 ms | 1.99 ms |
| 500 | 45.59 ms | 1.97 ms | 2.07 ms |
| 1,000 | 138.01 ms | 2.10 ms | 2.18 ms |

At 1,000, median time pending inside network processing fell from 135.170 ms to
0.107 ms. All nine mode-3 stop commits sampled the network-processing phase,
so these were not merely idle-reactor requests. That phase includes socket
bookkeeping, callbacks and scheduler delay; it does not locate an exact internal
libcurl instruction. The snapshot is sampled just after the commit timestamp.
The entire driver and readiness batching change together; this is evidence for
the combined per-socket driver with control checks, not an isolated causal
measurement of one added check.

At 1,000, median lifetime peak physical footprint was 147.58 MiB versus 144.16
MiB, and CPU was 0.868 versus 0.861 of one core over the full measured work
interval. Smaller cohorts were also comparable; see [comparison.md](comparison.md).
There is no observed material memory/CPU penalty, but three runs on a shared
machine do not prove equivalence or a universal improvement.

All 36 measured cases passed: 19,200 operations, comprising 19,164 ordinary
successes and 36 expected cancellations. Four additional 10-stream smoke cases
passed. Checks cover full concurrent TLS cohorts, generated/received/stored
byte counts, the exact held-open target, server EOF, typed scratch cancellation,
SQLite integrity, scratch release and descriptor return. This is byte-count
agreement, not a byte-for-byte content comparison. The phase partitions sum
exactly to commit-to-removal-and-cleanup in every measured run.

The initial source and raw data are preserved at local commit `7439cb6`.
`phase_at_commit` is assigned in the socket follow-up; the earlier zero values
remain historical evidence and are not used. Both matrices record exact source
hashes, compiler/environment, curl configuration and static archive hash.
Reproduce the validation and tables with `python3 research/host-reactor-cancellation/summarize.py`.
The current runner writes `socket-results.json`, `socket-smoke.json`, or
`socket-single.json` for a `--capacity` pair. To repeat the earlier matrix, use
its preserved commit in a separate worktree. Build the experimental dependency
with `python3 research/host-capacity-scaling/build_probe_curl.py /tmp/your-probe-curl`.

### Recommendation and limits

Use this as evidence for a single reactor with cancellation opportunities between
socket events. Cancellation happens outside libcurl callbacks. Cancellation is
checked before borrowing the next completion message; removing handles can
invalidate that message. Socket interest generations are rechecked after
cancellation so a removed/reused descriptor is not dispatched from an old poll
snapshot. These follow the documented [socket-action API](https://curl.se/libcurl/c/curl_multi_socket_action.html),
[removal rules](https://curl.se/libcurl/c/curl_multi_remove_handle.html), and
[completion-message lifetime](https://curl.se/libcurl/c/curl_multi_info_read.html).

This is a mechanism recommendation, not a newly accepted product requirement.
No capacity default, strict latency bound, idle-memory target or dependency build
is selected. A single socket action, timeout action, callback, import or commit
remains non-preemptible. The fixed poll table, model-only backend and 10 ms wait
are fixture choices. Production mixed Bash/network readiness, real client
arrival/wakeup, many simultaneous controls, sustained fairness, stop/completion
races and recovery are not exercised. The target deliberately cannot finish
normally, and the fixture schema is historical prototype scaffolding rather
than the current Operation-owned production design.

Both modes use the same experimental static curl 8.7.1 Darwin build with
HAVE_POLL_FINE enabled; this does not resolve the earlier system-libcurl
high-descriptor failures or qualify a production library. Source inspection and
these finite runs do not establish a worst-case service bound. The remaining
budget decision needs explicit product targets and evidence on the supported
transport build, followed by integrated Host verification.
