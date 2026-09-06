# System libcurl descriptor boundary probe

Run `python3 research/host-capacity-scaling/fd-boundary/run.py` from this throwaway worktree.

The probe creates one local socketpair and duplicates one endpoint to descriptor numbers 1023, 1024, 1100 and 2000. It compares a one-millisecond `curl_multi_poll` with one extra descriptor against native `poll`. It opens only a handful of descriptors, performs no HTTP transfers and changes only its own descriptor soft limit. The executable is temporary; raw results remain in `results.txt`.

On the measured macOS system libcurl 8.7.1, descriptor 1023 succeeds while 1024 and larger produce `CURLM_UNRECOVERABLE_POLL` / `EINVAL`. Native poll succeeds on all. This isolates a descriptor-number boundary, independently of concurrency or memory load. It matches curl's select fallback, which validates descriptors against FD_SETSIZE. This is experimental platform evidence, not production policy.

Primary source: https://github.com/curl/curl/blob/curl-8_7_1/lib/select.c#L313-L342 and https://github.com/curl/curl/blob/curl-8_7_1/lib/select.h
