# #272 native allocation witness

The [disposable measurement patch](allocation-witness.patch) applies to exact committed base `8b3b57396b3141e2e8ecaed4ad6d382eb8c60a46` (patch SHA-256 `a7558ff9adfc0558b716c72329bc176460e0dcda94e39c0dfc4c954c674a79bd`). It reuses the prior #263 curl/OpenSSL allocation hooks, compiles them only into a disposable instrumented binary, and reports requested-live/lifetime-peak bytes at Host readiness and after each managed transfer. No hook or diagnostic is part of the production build. To reproduce in a fresh disposable checkout of that base:

```sh
git apply /path/to/allocation-witness.patch
zig build -Doptimize=ReleaseSafe
python3 tests/integration/codex_h2_integration.py zig-out/bin/rui
```

The synthetic Codex fixture needs Python `h2==4.3.0`, OpenSSL and on macOS `TMPDIR=/private/tmp` to avoid the `/var` symlink rejected by the credential owner. Both native runs passed: TLS peer negotiated ALPN h2, three managed streams used one connection, curl reported HTTP version 3 (HTTP/2) each time and new-connection counts 1/0/0. The snapshots below are **requested allocator bytes**, not physical footprint or isolated per-request allocations. Peaks are lifetime peaks since each Host began.

| Platform / instrumented binary SHA-256 | Ready curl live/peak | Ready OpenSSL live/peak | Operations 1/2/3 curl live (peak at 3) | Operations 1/2/3 OpenSSL live (peak) |
| --- | ---: | ---: | ---: | ---: |
| Linux x86-64 `1eb49ca733275ad28376cf231f65ba7da04edfcdd24a327cd60d50a9bea2f5b7` | 0/0 | 97,009/111,405 | 108,826 / 109,003 / 109,348 (111,487) | 652,465 / 652,465 / 652,465 (687,820) |
| macOS arm64 `85d3122c1e39d56233ab7de8ccb34d3eeac57cdb7bfa2ed0069943bbb5ccf859` | 0/0 | 100,240/100,967 | 108,898 / 109,075 / 109,420 (111,559) | 671,204 / 671,204 / 671,204 (708,175) |

The hooked curl counter includes nghttp2; OpenSSL counts allocations routed through its registered memory hooks. These process-global counters omit other allocation origins, allocator metadata and native library copies outside the hooks; they cannot be added to RSS/footprint or interpreted as a simultaneous sum of independent peaks. Hooked binaries perturb allocation behavior. This fixture uses synthetic credentials and a trusted local TLS peer, **not the live subscription route**. The separate uninstrumented `gpt-6-luna` public-caller journey passed on both platforms at `3d4c0e0`; its Linux Host VmHWM was 17,326,080 bytes, while the Mac Host resource sample was unavailable.

A first instrumented Linux live login stopped at `LoginExpired` before any provider request. Newly authorized Linux and macOS runs then passed the complete public-caller journey with their instrumented binaries: one private reasoning item (401/419 reasoning tokens on Linux/macOS), exact approved Bash once, no effect or POST on committed recovery, one post-restart live request, four curl HTTP/2 observations and same-Host reuse 1/0/0. All response bodies reported `gpt-6-luna`; correlation, served-model headers and direct ALPN observations were absent. Both runners deleted their isolated Stores and credentials afterward.

| Live platform | Ready OpenSSL live/peak | Each pre-restart operation OpenSSL live/peak | Fresh Host operation OpenSSL live/peak | Pre-restart curl live after operations 1/2/3 (lifetime peak at 3) | Fresh Host curl live/peak |
| --- | ---: | ---: | ---: | ---: | ---: |
| Linux x86-64 | 97,009/111,405 | 1,386,969/1,432,219 | 1,386,969/1,432,219 | 124,608 / 123,333 / 125,067 (127,662) | 124,597/125,397 |
| macOS arm64 | 100,240/100,967 | 678,661/716,464 | 678,661/716,464 | 123,512 / 122,225 / 123,981 (126,561) | 124,516/125,316 |

These values characterize one hooked run per platform, not uninstrumented footprint, a per-connection allocation quota or live refresh. The instrumented Linux Host VmHWM was 18,030,592 bytes before restart; the native Mac Host resource sample was unavailable. The hook alters allocation behavior, so compare these requested-byte counters only within their stated boundary. The uninstrumented journey remains the behavioral qualification; this disposable overlay observes native TLS allocation through the same production transfer owner.
