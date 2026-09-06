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
