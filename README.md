# Rui

Rui (रुई, Hindi for cotton) is a local runtime for coding-agent workflows. It keeps reusable conversations working after clients disconnect and recovers durable work after crashes with bounded memory and temporary storage. Zig owns execution and recovery; SQLite stores durable state.

## Status

Rui is in development. Today the direct CLI can configure reusable Sessions, queue messages, receive text-model responses, stop or interrupt work, inspect proposed tools, authorize Bash and read saved results. Keyed requests, permission decisions and admitted work survive restart.

The precise model is documented in [Architecture](ARCHITECTURE.md): valid Bash descriptors become inspectable Actions, unknown tools and invalid descriptors become stable call-local rejections, and a Bash attempt that loses local custody resolves as indeterminate rather than replaying automatically.

JavaScript workflows, Edit, structured answers and provider authentication are not implemented. Bash process-group stopping cannot contain detached descendants. Retained full output is optional: FIFO eviction or restart may remove it without changing the saved result. Codex subscription is the planned first live provider; live-provider, power-loss and complete 1,000-operation mixed qualification remain outstanding.

Targets Linux and macOS on x86-64 and ARM64. All four cross-compile. Broad runtime/resource qualification has run on Apple Silicon macOS. The model-queue workload has run on Linux and macOS; its macOS run passed the required physical-footprint target.

## Build

Requires Zig 0.16.0, Python 3, Perl, a C toolchain and Make. The build pins native dependencies.

```sh
zig build
zig build check
./zig-out/bin/rui serve --store /absolute/path/to/private-store
```

Model transport is disabled by default. Development testing requires an explicit `--provider-endpoint`: HTTPS or loopback HTTP, with no authentication attached. Run `./zig-out/bin/rui` to print command usage.

## Try the implemented development path

Use the deterministic integration fixture as the runnable example of the current path: configure a Session, submit a message, inspect an Action, decide it, then observe the result.

```sh
zig build bash-integration
```

The fixture starts its own local Host and provider endpoint; it is a development test, not a live-provider quickstart. For direct exploration, use the commands printed by `./zig-out/bin/rui`: `serve`, `configure`, `message`, `inspect-session`, `allow-action` or `deny-action`, and `read-result`.

## Read next

- To explain ordinary work, recovery, ownership or resource policy, read [Architecture](ARCHITECTURE.md).
- To change Session behavior or verify an implementation slice, find the owning behavior in Architecture and its required evidence in [Verification](VERIFICATION.md).
- To run or interpret qualification, start with [current qualification](tests/qualification/README.md#current-checks-and-qualification); it records revision-specific observations and their limits.
- To inspect design evidence or archived experiments, read [Research](research/README.md).
- Contributors should follow [working rules](AGENTS.md). Dependencies and notices live in [third-party notices](THIRD_PARTY_NOTICES.md).
