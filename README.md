# Rui

Rui (रुई, Hindi for cotton) is a local runtime for coding-agent workflows. The goal: compose reusable conversations in JavaScript, let work continue after clients disconnect, and recover after crashes with bounded memory and temporary storage. Zig owns execution and recovery; SQLite stores durable state.

## Status

In development. The current runtime supports direct CLI Sessions, queued messages, text-model responses, retries, stops, exact model interruption, ordered Tool Call classification and authorized Bash execution. Trustworthy calls retain exact identities and arguments; valid Bash descriptors become inspectable Actions, while unknown tools and invalid descriptors become stable call-local rejections without execution authority. Exact keyed allow-once, saved bypass or denial decisions survive restart. Bash results include bounded combined excerpts and optional retained full-output paths; once every call has an outcome, core derives ordered Tool Results and continues the model Turn without another user message. Admitted Bash whose local custody is lost recovers as indeterminate and is never replayed automatically.

JavaScript workflows, Edit, structured answers and provider authentication are not implemented yet. Bash process-group stopping cannot prove containment of detached descendants, and retained full output is optional spillover that FIFO eviction or restart may remove without changing the saved result. Codex subscription is the planned first live provider; live-provider, power-loss, macOS Bash-runtime and complete 1,000-operation mixed qualification remain outstanding.

Targets Linux and macOS on x86-64 and ARM64. All four cross-compile. Broad runtime/resource qualification has run on Apple Silicon macOS. The model-queue workload has run on Linux and macOS; its macOS run passed the required physical-footprint target.

## Build

Requires Zig 0.16.0, Python 3, Perl, a C toolchain and Make. The build pins native dependencies.

```sh
zig build
zig build check
./zig-out/bin/rui serve --store /absolute/path/to/private-store
```

Model transport is disabled by default. Development testing requires an explicit `--provider-endpoint`: HTTPS or loopback HTTP, with no authentication attached. Run `./zig-out/bin/rui` to print command usage.

## Documentation

- [Architecture](ARCHITECTURE.md): accepted behavior, scope and recovery rules.
- [Verification](VERIFICATION.md): required checks and measurement setup.
- [Current qualification](tests/qualification/README.md#current-checks-and-qualification): evidence and remaining limits.
- [Research](research/README.md): design evidence and archived experiments.
- [Working rules](AGENTS.md) and [dependency notices](THIRD_PARTY_NOTICES.md).
