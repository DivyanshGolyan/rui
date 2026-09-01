# OnePage continuous-stream reactor capacity control

Status: throwaway measurement artifact for the Wayfinder task **Measure continuous-stream reactor service at Active Capacity 100**. This is not production code.

## Question

Can one Host-owned libcurl multi reactor drain 100 concurrent long-lived TLS/SSE model streams directly into unlinked disk spools without per-stream content buffers, per-effect workers, resident growth with duration, or unstable service at the required offered load?

## Machine and toolchain

- MacBookPro18,1, Apple arm64, 10 logical CPUs, 16 GiB RAM
- macOS 15.7.7 (24G720), Darwin 24.6.0
- Apple clang 17.0.0
- system libcurl 8.7.1, SecureTransport, LibreSSL 3.3.6
- HTTP/1.1, 100 separate localhost TLS connections

## Shape

`tls_sse_load.py` opens a synchronized workload of 100 TLS/SSE responses. The client uses one libcurl multi event loop. Each receive callback writes the borrowed libcurl bytes directly into that transfer's securely unlinked spool file. It retains only fixed counters and one spool descriptor per transfer; it does not parse SSE, accumulate content, or allocate diagnostics per callback.

The required worst event-count case sends one SSE delta per token at 100 tokens/s/connection, four semantic characters per token, for 10 seconds, followed by a synchronized 64 KiB terminal item per connection and `response.completed`. Provider batching and deliberately split transport writes are separate cases because event and callback boundaries are not semantic boundaries.

`run_matrix.sh` records raw JSONL results and macOS `vm_stat` snapshots. The clean runs sample process footprint every 50 ms and leave socket-queue scanning disabled so diagnostics do not dominate reactor CPU. The first matrix retains the more intrusive measurements as a conservative cross-check and contains the cancellation cases.

## Results

All 36 recorded transfers sets completed without an unintended client failure.

| Case | Repeats | Client CPU, one-core fraction | Receive callbacks/s | Bytes/s | Active physical delta over baseline | Threads added |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Required: 100 streams at 100 token-events/s | 5 | median 0.225, max 0.227 | median 9,802 | median 1,225,108 | median 4.719 MiB, max 4.797 MiB | 0 |
| Deliberately fragmented into three server writes/event | 3 | median 0.403, max 0.403 | median 28,698 | median 1,819,601 | median 4.735 MiB, max 4.766 MiB | 0 |
| Twice required event rate: 200 token-events/s | 3 | median 0.386, max 0.400 | median 19,104 | median 2,387,808 | median 4.703 MiB, max 4.813 MiB | 0 |

At the required rate, fixed measurement state included 205 open descriptors at peak: approximately 100 network sockets, 100 unlinked spool descriptors, and process/library descriptors. The configured-before-connect physical delta was about 0.55–0.61 MiB; it did not reserve content-sized buffers.

The one-minute required-rate soak processed 600,600 receive callbacks and 42,574,100 response bytes with zero failures. Active physical footprint stayed at a 4.813 MiB delta over baseline rather than growing with the 60-second custody duration. The spools occupied 46,284,800 physical filesystem bytes before close.

In the five clean required-rate runs:

- callback writes had a log-histogram p99 upper bound of 16.384 microseconds;
- the largest individual cached spool write ranged from 3.18 to 8.41 ms;
- a synchronized 6.25 MiB terminal burst completed across all 100 transfers within at most 66.12 ms; and
- the largest single `curl_multi_perform` call ranged from 41.99 to 50.40 ms.

The minute soak observed one 29.96 ms cached spool write and a 72.53 ms maximum `curl_multi_perform` call. Those tails must remain visible to the later end-to-end capacity proof, but they did not cause loss or resident growth.

Three cancellation runs removed 50 of 100 active handles after two client seconds. Median mean removal time was 30.16 microseconds/handle; the largest observed removal was 121.13 microseconds. All remaining transfers completed. The synthetic server observed all 50 disconnects over a 1.85–10.14 ms span.

The first, instrumented matrix found no sampled kernel receive backlog, but that is weak evidence because SecureTransport and libcurl may already have moved ciphertext into userspace before `FIONREAD`. Completion and byte equality are the stronger checks here.

## Machine-pressure accounting

Unlinked regular files remove content-sized process RSS but do not make their contents free: current file allocation grows with captured bytes and cached writes can occupy reclaimable or dirty filesystem pages. The short required-rate runs allocated 13.672 MiB across the 100 spools; the minute soak allocated 44.141 MiB.

Global `vm_stat` deltas were not attributable on this concurrently used Mac: file-backed-page deltas ranged from -145.9 to +119.6 MiB across short clean runs, while all runs recorded zero new swapouts and zero throttled pages. Therefore this control does not claim an exact cache-residency figure. The later evidence-boundary decision must treat allocated in-flight spool bytes as machine pressure, impose an aggregate byte admission limit, and separately evaluate cached versus no-cache/coalesced writes.

## Verdict

One startup-fixed network reactor is sufficient as the V1 baseline for 100 concurrent model transports on the measured macOS target. The required worst event-count workload consumes about one quarter of one core even with TLS and direct per-callback spool writes; the twice-rate and deliberately fragmented cases remain below half a core. There is no evidence justifying a second network reactor or any per-effect worker/thread.

This verdict is deliberately narrow. It does not choose the parser/import boundary, spool cache policy, Store command lane, Bash/Patch supervision, or final product memory budget. Those belong to the subsequent Wayfinder decisions and the full capacity-100 proof.

## Reproduce

```sh
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout key.pem -out cert.pem -days 1 \
  -subj '/CN=localhost' -addext 'subjectAltName=DNS:localhost'

chmod +x run_matrix.sh
./run_matrix.sh

MATRIX_PROFILE=clean \
RESULTS_FILE="$PWD/clean-results.jsonl" \
RAW_DIR="$PWD/clean-raw" \
./run_matrix.sh

MATRIX_PROFILE=soak \
RESULTS_FILE="$PWD/soak-result.jsonl" \
RAW_DIR="$PWD/soak-raw" \
./run_matrix.sh
```

Set `CERT_FILE` and `KEY_FILE` if the generated localhost certificate and key live somewhere other than the artifact directory.
