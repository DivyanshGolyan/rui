# Throwaway Host capacity scaling experiment

Question: what does OnePage-owned transport, custody, output spooling and serial result storage cost at 100, 500 and 1,000 simultaneous operations? Can memory justify a tiny concurrency default?

**Verdict:** this model-stream path completed at 1,000 with a median observed peak process footprint of 147.45 MiB. The measurements do not justify a default of 10 on memory grounds. They also do not select a default, certify the whole Host, or establish a universal 1,000-operation ceiling. The clearest constraints exposed here are platform transport compatibility, descriptor demand, allocator retention and long uninterrupted result-storage work.

This is isolated research for [Set Host Runtime admission controls and budgets](https://github.com/DivyanshGolyan/onepage/issues/68), derived from the historical [integrated capacity prototype](../host-runtime/integrated-capacity-proof/integrated_capacity.c) at repository commit `d76c735`. It retains that prototype's historical scratch schema and minimal validator. Those are measurement scaffolding, **not** the accepted current Operation-owned execution schema or production validation.

## Results

Three fresh-process repetitions per capacity, rotated as 100/500/1,000, 500/1,000/100, and 1,000/100/500. Peak and CPU columns are medians; descriptor and owner-work columns are maxima across repetitions.

| Streams | Peak process MiB | CPU fraction of one core | Max descriptors | Longest owner work interval ms |
| ---: | ---: | ---: | ---: | ---: |
| 100 | 18.27 | 0.236 | 208 | 61.70 |
| 500 | 75.99 | 0.694 | 1,008 | 312.98 |
| 1,000 | 147.45 | 0.863 | 2,009 | 515.81 |

Peak means the operating system's process-lifetime physical-footprint high-water, read after closure. It includes this prototype's fixed baseline and temporary import allocations. The shared Store/reactor idle baseline was about 2.4 MiB. The observed 100→1,000 slope is approximately 147 KiB per additional stream; it is an empirical sizing estimate for this exact workload/build, not a maximum per arbitrary operation. Each custody record itself is only 128 bytes. All runs reserve the same 128,000-byte array, so the cross-capacity slope excludes growth of that array.

CPU covers admission, connection setup, streaming and result storage in the measured process. It excludes the local server. A fraction of 0.863 means 86.3% of one core averaged across that interval, not 86.3% of this ten-core machine. The owner interval includes disk-occupancy instrumentation, all ready settlements, SQLite commits and resource release. It is neither pure table-scan cost nor a measured stop-command delay; it exposes a place where a naive driving loop can postpone other owner work.

All 12 final cases passed: **15,800 successful transfers and 1,513,907,800 exact stored body bytes**. Every wave proved its full concurrent cohort had connected and uploaded before any response body started. Generated, received and SQLite-stored lengths matched; database integrity checks returned `ok`; each case ended with zero charged scratch and the original descriptor count. These success checks are distinct from resource-policy acceptance.

## Repeated cleanup and duration

- Five waves of 1,000 in one process: peak 147.30 MiB. Between-wave idle footprints were 48.49, 64.42, 62.67, 53.64 and 52.75 MiB. Descriptors returned to eight and charged scratch to zero after every wave. Five waves do not prove an indefinite steady-state bound.
- A separate five-wave run reached peak 146.70 MiB. Its final idle footprint was 62.38 MiB; after a final `malloc_zone_pressure_relief(NULL, 0)` probe it measured 6.53 MiB. The API reported zero bytes relieved despite the observed footprint change. This is an observed reclaim opportunity, not a selected reclamation policy or proof that all retention is harmless. Relief happened only after the last wave.
- Extending one 1,000-stream wave from four to twenty seconds increased stored body content from 85.58 to 177.14 MiB while peak footprint remained 147.72 MiB. Charged scratch high-water reached 169.31 MiB. This supports disk-first streaming for these inputs; it does not account for kernel/file-cache memory or unbounded response shapes.

## The platform failure and experimental continuation

The original system-libcurl run passed at 100 and 500 but failed at 1,000 before streaming. `curl_multi_poll` returned an unrecoverable polling error with `EINVAL`. The tiny [descriptor boundary probe](fd-boundary/README.md) isolates the cause with one socketpair: descriptor 1,023 works, whereas 1,024 and above fail in this installed polling wrapper; native `poll` works for the same descriptors. Raising the process FD limit does not fix a descriptor-number boundary.

An alternate native-poll/socket-action driver bypassed the wrapper, but the installed libcurl still failed 984 connection attempts at 1,000. Only 16 uploads reached the server, so that cohort correctly failed its barrier and was excluded from successful capacity figures. The exact internal cause of those connection failures was not independently isolated. The original failed matrix and diagnostic attempts remain in `initial-failure.json`, `poll-failure.json` and `native-system-curl-failure.json`.

The final successful matrix uses a **temporary, statically linked upstream curl 8.7.1 build with `HAVE_POLL_FINE` explicitly enabled**, SecureTransport TLS, and the original `curl_multi_poll` driver. This is an experimental override: upstream 8.7.1 deliberately disables poll on Darwin because of historical platform defects. Passing this fixture is not approval to override that setting in production. The build differs from Apple's system build; final comparisons use this single build consistently. No library was installed, no system limit changed, and no production source was edited.

The temporary build also required explicit server-authentication/key-usage extensions on the self-signed local certificate; the initial certificate-validation failure is preserved in `custom-curl-certificate-failure.json`. The successful runs retain peer and hostname verification. Certificates and private keys exist only in disposable case storage.

Primary sources: [curl 8.7.1 select fallback](https://github.com/curl/curl/blob/curl-8_7_1/lib/select.c), [descriptor validation](https://github.com/curl/curl/blob/curl-8_7_1/lib/select.h), [Darwin poll exclusion](https://github.com/curl/curl/blob/curl-8_7_1/m4/curl-functions.m4), and [socket-action API](https://curl.se/libcurl/c/curl_multi_socket_action.html).

## Workload and measurement boundaries

- MacBookPro18,1, 16 GiB RAM, ten logical cores, macOS 15.7.7, Clang 17; exact versions, build configuration, source hashes, raw samples, case order and driver observations are in `results.json`.
- One reactor, a content-free custody array, disk spools and one SQLite owner with a shared 4 KiB import window. Every model request uploads 4 KiB over localhost HTTP/1.1 TLS. Each response emits 100 one-token events per second, four characters per token, followed by a synchronized 64 KiB terminal text item and completion event. No real providers, credentials or paid calls.
- The local Python load generator is excluded from Host process measurements. It reached about 717 MiB RSS in one churn run. It runs on the same machine and can affect scheduling; raw generation duration and CPU are retained. The first churn wave's nominal four-second generation took about 4.32 seconds. Server `setup_seconds` is first-to-last completed-upload spread, not full handshake time.
- Runs set their own FD soft limit to 8,192, per-operation output limit to 1 MiB and aggregate charged scratch limit to 256 MiB. These are experimental guardrails, not product defaults. One case runs at a time with disposable SQLite/WAL/spools; the largest retained result body within a case is about 428 MiB. Runner deadlines and PID-specific cleanup bound failures.
- SQLite is system 3.43.2, WAL/FULL sync, mmap disabled, requested cache `-256`. Effective reported cache use reached 397,312 bytes. Heap accounting was unsupported; reported zero counters must not be interpreted as zero heap use. No hard heap limit was certified.
- `active` fields are componentwise sampled high-waters after owner passes and can miss short peaks. The headline uses process-lifetime high-water instead. `max_storage_allocated` and `max_live_spool_allocated` are sampled occupancy, not exact disk-overlap maxima. Native-driver `max_poll_ns` measures the skipped wrapper and is not meaningful; the final matrix uses the original driver.
- Bash command/descendant memory is outside the question. This fixture starts no Bash/Patch operations and therefore **does not measure their OnePage-owned supervision/executor costs either**. Evaluator, parser completeness, Host control API, client population, diagnostics/export, normal production schema, crash recovery, process/kernel/socket/file-cache attribution and whole-Host tail latency remain outside this experiment.

## What follows for the budget decision

Keep shared active capacity and account for OnePage-owned costs. Use measured per-path costs plus the remaining shared Host costs and headroom to propose a configurable default. Do not infer a universal default from this one stream shape or multiply the tiny custody record size and call that the whole cost.

The platform polling path must support the desired descriptor range. The Host driving path must give controls bounded turns through completion bursts. Whole-Host budgeting must include library retention after cleanup. These are concrete evidence gaps for the existing owners, not reasons to cap model-chosen Bash workload memory or introduce another scheduler/pool. No numeric default, maximum or production implementation is selected here.

## Reproduce

One command from this throwaway worktree (macOS, Python 3.14, Clang, make and openssl):

```sh
python3 research/host-capacity-scaling/experiment.py
```

It downloads the pinned source archive, checks its recorded SHA-256, builds into a temporary directory without installation, runs the full matrix, and removes build/case storage. The resource observations are written to `results.json`. The script captures the same build recipe used for the recorded run; the recorded session built that dependency first and then ran `run.py --curl-build /tmp/onepage-capacity-curl-build/curl-8.7.1`.

For the system-library smoke/reproduction use `run.py --smoke` or `run.py --capacity 1000`; these overwrite `smoke.json` or `single.json`. `--native-poll` selects the failed alternate-driver experiment and supports model-only fixtures. Recompute report values without load with `python3 research/host-capacity-scaling/summarize.py`. The final matrix and tiny boundary reproduction were executed; the convenience wrapper's composed build recipe was not separately rerun.
