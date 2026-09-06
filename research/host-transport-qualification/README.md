# System transport descriptor boundary

A single local plain-HTTP request succeeds with socket descriptor 1,023 and fails
at 1,024 and 1,100 in installed macOS libcurl 8.7.1. The easy API returns code 43;
the socket-action driver returns transfer code 7 despite a successful multi API
return. Ordinary low descriptors work in both modes. No concurrency or TLS is
needed to reproduce the boundary. The opensocket callback duplicates the socket
to the requested descriptor number before returning it to curl.

Run `python3 research/host-transport-qualification/run.py` on macOS. Compilation
uses system libcurl, warnings as errors, a temporary binary and a loopback HTTP
server. `results.json` preserves platform and exact source hashes. This is a
failure reproduction, not a TLS/security or supported-library qualification.

## Standard upstream candidate

Upstream fixed its Darwin poll/select policy in 8.11.0. See the cited
[primary-source research](upstream-research.md), including why the socket-action
API still encounters the older internal select limit. Current upstream 8.22.0
no longer supports Secure Transport; the candidate uses OpenSSL 3.6.3 plus
Apple SecTrust support. No source/config-header patch or HAVE_POLL_FINE override
was used, and no library was installed or production dependency changed.

The eight single-connection cases all succeed with the candidate, including
socket descriptors 1,024 and 1,100 through both APIs. `stock-results.json`
records these results. Original system-library source/results are preserved at
commit `77d9e82`; the current runner also accepts `--curl-build`.

Five local TLS/cancellation cases passed: 100, 500 and three repetitions of
1,000 concurrent streams, totaling 3,600 operations (3,595 ordinary successes
and five expected cancellations). The fixture confirms concurrent cohorts,
byte counts, exact target cancellation/server EOF, SQLite integrity, final
scratch release and descriptor return. It is not a byte-for-byte payload check.
At 1,000, cancellation-to-release median was 2.15 ms (range 1.62–2.30 ms).

The memory difference persists across the three large runs: lifetime peak
physical footprints were 248.83, 250.16 and 248.50 MiB, with median 248.83 MiB.
Median CPU was 1.024 of one core over the measured interval. The earlier
8.7.1/SecureTransport socket-driver matrix measured a 144.16 MiB median and
0.861 core at 1,000. These are different curl versions, TLS backends and build
configurations measured in different runs, not a controlled isolation of one
allocation source. The difference cannot yet be attributed specifically to
OpenSSL, certificate handling or a curl version change. It prevents carrying
the previous footprint numbers forward to this candidate.

| Streams | Candidate peak physical MiB | Request-to-release ms | Repetitions |
| ---: | ---: | ---: | ---: |
| 100 | 33.33 | 2.49 | 1 |
| 500 | 132.16 | 2.03 | 1 |
| 1,000 | 248.83 median | 2.15 median | 3 |

Recommendation: the installed system curl is unsuitable for an unrestricted
Host descriptor range; an arbitrary operation-count cap does not solve a
socket-number limit. A tested, application-shipped upstream build is a viable
direction, but do not select this exact candidate or its memory budget yet.
First determine whether the additional per-connection footprint is avoidable
with a small supported configuration change. Bundling also makes OnePage
responsible for dependency updates and packaging.

This is partial qualification. The TLS fixture uses a custom CA file with peer
and hostname verification enabled. That does not test native Apple trust-store
behavior: explicit CA-file behavior differs from default SecTrust. Negative
certificate/hostname tests, DNS concurrency and cancellation, TLS edge cases,
minimum-macOS compatibility, release packaging, dependency-update policy,
mixed Bash/network readiness, true client ingress, races/recovery and full
Host budgets remain unqualified. The recorded candidate links a local Homebrew
OpenSSL build dynamically and is not a distributable artifact. Native trust
and asynchronous-DNS/threadsafe features are compiled in, not a passing test
of every corresponding behavior.

## Reproduction and provenance

`build_candidate.py` downloads upstream 8.22.0 and builds a temporary static curl
archive against `/opt/homebrew/opt/openssl@3`, with no installation. The source
archive URL/hash, configure flags, effective config, compiled features, OpenSSL
version and linked library hashes are in `build-metadata.json`. This identifies
what ran; the archive hash was computed locally, not checked against a separately
signed release manifest. Repeating later against a changed Homebrew dependency
may produce different results; use the recorded versions/hashes for comparison.

```sh
python3 research/host-transport-qualification/build_candidate.py
python3 research/host-transport-qualification/run.py --curl-build /tmp/onepage-stock-curl-qualification/curl-8.22.0
python3 research/host-transport-qualification/run_tls.py --curl-build /tmp/onepage-stock-curl-qualification/curl-8.22.0
python3 research/host-transport-qualification/run_tls.py --capacity 1000 --curl-build /tmp/onepage-stock-curl-qualification/curl-8.22.0
python3 research/host-transport-qualification/summarize.py
```

The first TLS command writes `tls-results.json`; each single-capacity run writes
`tls-single.json`. The two additional recorded runs were saved as
`tls-repeat-2.json` and `tls-repeat-3.json`. `summarize.py` validates the recorded
TLS source hashes, checks and phase partitions and reproduces reported metrics.
The linker reported harmless duplicate ssl/crypto flags from curl-config; C
compilation used warnings as errors. No production tests are claimed.
