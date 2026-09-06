# Simple transport memory check

The user accepts approximately 250 MiB for the measured 1,000-stream fixture
provided we are not missing an ordinary improvement: “The goal is not to be
clever but rather stop doing something dumb.” This does not select an overall
Host memory budget or waive the remaining transport qualification.

## Finding

One documented curl option makes a material difference for this small-upload,
long-response fixture. `CURLOPT_UPLOAD_BUFFERSIZE` defaults to 64 KiB and permits
16 KiB. Every fixture request uploads 4 KiB. The exact curl 8.22 source uses the
setting for a per-request send queue as well as shared upload scratch; drained
queue chunks can remain as spares through the response. It is reasonable to
avoid reserving large send capacity for known-small requests. See the official
[upload-buffer contract](https://curl.se/libcurl/c/CURLOPT_UPLOAD_BUFFERSIZE.html),
[request implementation](https://github.com/curl/curl/blob/curl-8_22_0/lib/request.c)
and [queue implementation](https://github.com/curl/curl/blob/curl-8_22_0/lib/bufq.c).

Using the exact previously tested curl 8.22.0/OpenSSL 3.6.3 build, six runs compare
64/16/16/64/64/16 KiB upload buffers at 1,000 simultaneous TLS streams. The only
experimental change is the upload-buffer option. No TLS-context callback,
allocator tuning, extra worker, connection-pool redesign, or library patch is
introduced.

| Upload buffer | Median peak physical footprint | Median CPU, one-core units | Median request-to-release | Median measured work interval |
| --- | ---: | ---: | ---: | ---: |
| 64 KiB | 253.95 MiB | 1.022 | 1.965 ms | 5.973 s |
| 16 KiB | 170.85 MiB | 1.019 | 1.966 ms | 5.943 s |

The observed median reduction is 83.11 MiB, about 33%. Do not equate that entire
reduction with exact live queue bytes: allocation size classes, transient peaks
and allocator behavior are not separately instrumented. Three repetitions per
setting on a shared machine establish a repeatable effect in this fixture,
not a universal memory guarantee or proof of identical performance.

All six cases pass: 6,000 operations, 5,994 ordinary successes and six expected
cancellations. Checks cover concurrent cohorts, generated/received/stored byte
counts, exact target cancellation and server EOF, SQLite integrity, scratch
release and descriptor return. They are not byte-for-byte payload comparisons.
All measured phase partitions exactly cover commit-to-removal-plus-cleanup.

## What the web/source audit ruled out

- curl already shares receive scratch across the single multi handle. Reducing
  that buffer is not a per-connection saving. [Receive-buffer documentation](https://curl.se/libcurl/c/CURLOPT_BUFFERSIZE.html).
- CA-store caching defaults to 24 hours. An inherited CA directory can block
  sharing in the OpenSSL path, but this candidate's effective config has no
  default CA directory and the fixture sets none. We found no such accidental
  cache-disabling configuration to correct. This is a configuration/source
  audit, not a measured count of shared store objects. [Cache documentation](https://curl.se/libcurl/c/CURLOPT_CA_CACHE_TIMEOUT.html),
  [exact cache criteria](https://github.com/curl/curl/blob/curl-8_22_0/lib/vtls/openssl.c).
- The roughly 64 KiB TLS read buffer is an explicit upstream throughput choice.
  OpenSSL exposes opt-in buffer release and curl exposes a TLS-context callback,
  but neither is needed for this result. Leave those internals alone for this
  pass. [Pinned implementation](https://github.com/curl/curl/blob/curl-8_22_0/lib/vtls/openssl.c),
  [OpenSSL modes](https://docs.openssl.org/3.6/man3/SSL_CTX_set_mode/).
- The fixture deliberately forces fresh HTTP/1.1 connections and closes them
  after use. The current production adapter also sets those options. Reuse is
  ordinary curl guidance worth reviewing during transport integration, but
  changing it would not collapse this simultaneous HTTP/1.1 cohort. HTTP/2
  multiplexing changes the workload and requires provider/build qualification;
  do not claim it as an already established fix for this measurement.
  [Connection reuse guidance](https://curl.se/libcurl/c/CURLOPT_FORBID_REUSE.html).

The broader [primary-source research](upstream-research.md) distinguishes these
checks from deliberate library tradeoffs.

## Recommendation and limits

Use the documented smaller upload buffer as the candidate for small requests.
Keep larger-request throughput as a separate verification case before selecting
one setting for every production upload. This fixture sends only 4 KiB request
bodies; it does not validate large model-context uploads, slow receivers or
unusual backpressure. Reducing the buffer is a sizing tradeoff, not proof curl's
general-purpose default is defective. Production code and normative numeric
policy are unchanged.

Stop the memory optimization pass here. There is an ordinary, measured
improvement, and the remaining TLS defaults do not establish accidental waste.
No custom allocator, explicit reclamation, backend sweep or new framework is
justified by the user's target. Native trust, minimum-platform packaging,
DNS/transport edge cases, crash/recovery and complete Host budgets remain the
separate qualification work identified in the earlier report.

## Reproduction

Use the previously recorded candidate build; its exact configuration and
OpenSSL/archive hashes are in
[build metadata](../host-transport-qualification/build-metadata.json).

```sh
python3 research/host-transport-simple-memory/run_tls.py --curl-build /tmp/onepage-stock-curl-qualification/curl-8.22.0
python3 research/host-transport-simple-memory/summarize.py
```

The runner writes `tls-results.json` and records exact source hashes. Its matrix
is fixed at 1,000 streams and the two upload settings; inherited `--capacity`
is not a selector for this matrix. `--smoke` instead runs one 10-stream/16 KiB
case (not executed in this pass). The script uses the candidate's ordinary
curl-config static-link flags; the linker ignores duplicate ssl/crypto flags.
C compilation uses warnings as errors. No production tests were run.
