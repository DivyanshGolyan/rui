# Simple curl memory audit

Research scope: curl 8.22.0 with OpenSSL 3.6, one multi handle, approximately 1,000 concurrent HTTPS streams. User accepts roughly 250 MiB; the question is whether the fixture accidentally duplicates or retains something, not how low custom tuning can force the number. No measurements or production changes were made in this research subtask.

## Recommendation

Audit the certificate configuration and upload-buffer setting. If they explain no material waste, keep the ordinary upstream settings and accept the measured footprint. Do not add allocator tricks, change TLS libraries, or redesign the transport merely to reduce this number.

## Concrete checks

- **Certificate-store sharing is worth verifying.** curl caches CA stores for 24 hours by default. OpenSSL's implementation shares the store through the multi handle, but a non-null CA directory prevents this cache path even when a CA file is supplied. A build-detected directory can therefore matter without an application explicitly setting it. For a fixture intentionally trusting only its generated CA file, explicitly clearing `CURLOPT_CAPATH` is a straightforward configuration correction to test. For production, preserve the user's intended trust sources; blindly dropping a directory is not a memory optimization. [Cache option](https://curl.se/libcurl/c/CURLOPT_CA_CACHE_TIMEOUT.html), [directory default and clearing semantics](https://curl.se/libcurl/c/CURLOPT_CAPATH.html), [exact implementation](https://github.com/curl/curl/blob/curl-8_22_0/lib/vtls/openssl.c).

- **Check the upload setting, not just the shared upload scratch.** The documented default is 64 KiB, minimum 16 KiB; allocation is on demand. In 8.22, each request's send queue also uses `upload_buffer_size` as its chunk size, with a one-chunk soft limit. Draining a chunk ordinarily retains it as a spare; normal upload completion does not itself free that queue. Thus a small request followed by a long response can retain request send capacity. A 16 KiB setting is a documented knob worth testing if large default send buffers are the actual duplication; it is not evidence of a leak, and throughput for large real request bodies must remain acceptable. [Option](https://curl.se/libcurl/c/CURLOPT_UPLOAD_BUFFERSIZE.html), [request queue lifecycle](https://github.com/curl/curl/blob/curl-8_22_0/lib/request.c), [spare behavior](https://github.com/curl/curl/blob/curl-8_22_0/lib/bufq.c).

- **Receive scratch is already shared.** The exact multi implementation borrows and returns one `xfer_buf` across transfers, and also has shared upload scratch. Shrinking `CURLOPT_BUFFERSIZE` therefore should not be sold as saving 16 KiB for every connection in this design. Per-request send queues and TLS buffers are different allocations. [Exact multi implementation](https://github.com/curl/curl/blob/curl-8_22_0/lib/multi.c).

## Reasonable upstream tradeoffs, not obvious mistakes

curl 8.22 enables read-ahead and requests a TLS read buffer of `0x401e * 4` bytes, about 64 KiB. Its comment explicitly describes throughput experiments behind this choice. It does not set `SSL_MODE_RELEASE_BUFFERS`. Those are intentional library defaults, not evidence that OnePage forgot to clean up. [Pinned curl source](https://github.com/curl/curl/blob/curl-8_22_0/lib/vtls/openssl.c).

OpenSSL provides an opt-in mode to release drained read/write buffers; modes other than AUTO_RETRY are off by default. curl also exposes an SSL context callback through which an application could change such settings. That is backend-specific tuning with allocation/throughput tradeoffs, so it is outside the user's requested 'stop doing something dumb' pass. Do not promise the documentation's approximate per-idle-connection saving for this active workload. [OpenSSL mode contract](https://docs.openssl.org/3.6/man3/SSL_CTX_set_mode/), [curl callback](https://curl.se/libcurl/c/CURLOPT_SSL_CTX_FUNCTION.html).

HTTP/2 can multiplex requests on fewer connections when both endpoints support it; curl enables multiplexing by default. `PIPEWAIT` can avoid speculative extra connections while protocol negotiation completes, at the cost of waiting. The per-connection client stream default is 100, and server limits also matter. This is not a reason to force the 1,000-connection fixture into a different workload or adopt a global operation limit of 100. It is a later production compatibility/performance check, not a correction to memory ownership. [Multiplexing](https://curl.se/libcurl/c/CURLMOPT_PIPELINING.html), [waiting tradeoff](https://curl.se/libcurl/c/CURLOPT_PIPEWAIT.html), [stream limit](https://curl.se/libcurl/c/CURLMOPT_MAX_CONCURRENT_STREAMS.html), [peer SETTINGS_MAX_CONCURRENT_STREAMS](https://www.rfc-editor.org/rfc/rfc9113.html#name-settings-parameters).

## Evidence qualification

The pinned source was fetched directly from upstream with curl for inspection; browser raw-source snapshots showed older line counts, so source links above use the version tag rather than unreliable cached line anchors. Local inspected copies: `/tmp/onepage-curl822-openssl.c`, `/tmp/onepage-curl822-request.c`, `/tmp/onepage-curl822-bufq.c`, `/tmp/onepage-curl822-multi.c`. Actual build options, fixture options, and measured impact must be established by the parent task.
