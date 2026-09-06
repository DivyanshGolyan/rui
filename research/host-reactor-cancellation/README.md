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
