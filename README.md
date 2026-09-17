# Rui

Rui (रुई, Hindi for cotton) is a local runtime for coding-agent workflows. The goal: compose reusable conversations in JavaScript, let work continue after clients disconnect, and recover after crashes with bounded memory and temporary storage. Zig owns execution and recovery; SQLite stores durable state.

## Status

In development. The current runtime supports direct CLI Sessions, queued messages, text-model responses, retries, stops, exact model interruption, and ordered Tool Call classification. Trustworthy calls retain exact identities and arguments; valid Bash descriptors become inspectable Actions, while unknown tools and invalid descriptors become stable call-local rejections without execution authority. Saved request keys recover original answers after a lost reply or restart; pending permission requests, denials and rejected calls also survive Host restart.

JavaScript workflows, Bash execution, Edit, allow-once permission, Tool Result publication/continuation, structured answers and provider authentication are not implemented yet. The current Bash slice admits valid proposals under `ask` or `bypass`, reports every unresolved Action with its saved authorization, and supports keyed sibling-local denial; it never launches a process. Codex subscription is the planned first live provider; production and live-provider qualification remain outstanding.

Targets Linux and macOS on x86-64 and ARM64. All four cross-compile. Broad runtime/resource qualification has run on Apple Silicon macOS; the model-queue qualification also runs on Linux, where portable counters provide development evidence and macOS physical footprint remains unavailable.

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
