# Platform contract review

Decision: [Choose Linux and macOS platform contracts and portability seams](https://github.com/DivyanshGolyan/onepage/issues/126).

Status: accepted through live discussion and the #126 resolution. The normative owners record the selected mechanisms. This is accepted design, not implemented behavior or a release-support claim; tested, compiled and inferred compatibility remain distinct.

## Accepted choices

- Support Linux broadly through explicit capabilities and prerequisites rather than a distribution allowlist. Aim at x86-64 and ARM64 on Linux and macOS; no arbitrary exclusion of Intel Macs. Exact minimum OS/kernel/libc versions follow the selected build and required APIs, with incompatible targets diagnosed rather than silently degraded.
- Validate runtime behavior on the user's available Mac. Use source/dependency evidence, portable mechanisms and cross-compilation checks for other targets. A Linux distribution/CPU runtime test matrix is not required. Record tested, compiled and inferred compatibility separately; do not call unexecuted tests passing. This explicitly amends the previous mandatory runtime qualification on both operating systems. It does not waive local behavior/resource gates or change intended behavior on Linux.
- External native callers and Durable Objects remain design probes, not initial supported deployments.
- Keep macOS Keychain. Linux may use explicitly configured Secret Service or an explicitly selected owner-only plaintext credential file for unattended use. Never silently fall back from secure storage to plaintext. Atomic refresh persistence, account binding, restricted ownership/access, exclusion from semantic storage/logs/tool environments and explicit failures remain required. Plaintext is readable by same-user programs, including authorized Bash; this accepted tradeoff amends the prior OS-store-only prohibition. No custom encryption format or startup unlock key is required.
- Use configurable disk-backed scratch. Validate access and identify known memory-backed filesystems explicitly; memory-backed scratch cannot establish the disk-first guarantee. A temporary directory's name is not evidence of its backing medium.
- Require a local filesystem for the Host Store initially; shared/network-mounted stores are unsupported. A remote server may run OnePage against its own local disk.
- Bundle a pinned libcurl, selecting the latest stable version when implementation begins and updating deliberately. Do not resolve a floating latest version during builds. TLS dependencies and certificate trust must be explicit. Keep SQLite and QuickJS pinned and bundled.
- Use installed Bash, with an optional configured executable path. OnePage owns launch, timeout, cancellation and cleanup; arbitrary shell commands need not behave identically on both platforms.
- Retain process-group cleanup and existing external-effect uncertainty. Do not promise termination of detached descendants, rollback, or automatic replay of uncertain Bash.

## Mechanism ownership

These selections preserve the accepted guarantees. They are not a new generic platform framework.

The selected mechanism inventory is owned by [ARCHITECTURE.md](../../ARCHITECTURE.md#selected-platform-mechanisms). It covers TLS/trust, SQLite, Store locking/socket identity, exact Edit, scratch/spillover, evaluator limits, core dumps, and measurement/build evidence.

## Why these choices

- [Curl certificate verification](https://curl.se/docs/sslcerts.html) documents Apple SecTrust with an OpenSSL-compatible backend and Linux certificate-file trust. Pinning transport dependencies does not require freezing the operator's trust roots.
- [SQLite threading](https://www.sqlite.org/threadsafe.html) explains why a single-thread build cannot be made serialized at runtime. [SQLite synchronization](https://www.sqlite.org/pragma.html#pragma_synchronous) and [fullfsync](https://www.sqlite.org/pragma.html#pragma_fullfsync) separate transaction synchronization from macOS full-device synchronization requests. No performance or power-loss result is inferred from those API choices.
- [Linux process limits](https://man7.org/linux/man-pages/man2/getrlimit.2.html), [core collection](https://man7.org/linux/man-pages/man5/core.5.html), and [dumpability](https://man7.org/linux/man-pages/man2/PR_SET_DUMPABLE.2const.html) support the child-scoped enforcement options.
- [Portability inventory](https://github.com/DivyanshGolyan/onepage/blob/5150f17d33507eba25a042450db51d05f793dd7b/docs/research/linux-macos-portability.md) owns the fuller nine-area evidence matrix. Its former embedding and qualification assumptions are amended by the subsequent user decisions above.

## Publication and next dependency

Accepted policy additions are recorded in PRODUCT.md, ARCHITECTURE.md, VERIFICATION.md and README.md. Bundled OpenSSL with native/configured trust was explicitly accepted; routine mechanisms were derived within the authorized scope. No production code, build, credential access, dependency installation or live provider test is part of this work.

The issue resolution records acceptance; the map must use the amended evidence policy rather than its earlier mandatory two-platform execution wording. Preserve original research and historical resolutions; link the amendment. Next is [Compare complete architecture designs for OnePage](https://github.com/DivyanshGolyan/onepage/issues/119). The subsequent [Session core and Workflow Runtime direction](consolidated-architecture.md) records accepted module choices; final completeness remains a separate review, not a consequence of this inventory’s row count.
