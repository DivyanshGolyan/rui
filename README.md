# Latifa

Latifa (formerly OnePage) is a resource-bounded, crash-resumable local runtime for programmable coding-agent workflows. JavaScript coordinates reusable conversations; native Zig owns execution, permissions, recovery and SQLite storage. Codex subscription is the first live provider.

## Status

The source implements the first four redesigned runtime slices: an explicitly started Host, exclusive Store ownership, direct configuration/message clients, durable caller-side request capture, exact idempotent answer recovery, sparse Session updates, immutable ordered message admission and completed text-model Turns. Core selects an eligible queued prefix, freezes its historical view, launches one disk-backed Responses request, captures and validates the complete SSE response, and atomically saves ordered private provider output with the public answer. The original message key reads its complete answer after client or Host restart. A later Turn reconstructs the Session from canonical host input and private provider output without relying on provider-side storage. Automatic retry/recovery of interrupted Attempts and every Workflow, tool, permission, stop and interruption surface enter in later implementation issues.

The redesigned V1 targets Linux and macOS on x86-64 and ARM64 through capability-based prerequisites. The current build cross-compiles all four targets. Runtime and resource verification uses the available Apple Silicon Mac; the other targets remain compile-only evidence until exercised on their platforms.

## Intended experience

Start one local server explicitly, then use direct CLI/script calls or JavaScript workflows. Clients can disconnect while saved work continues. Restart recovers unfinished work under its original inputs and remaining budgets.

- Construct a Session reference locally. First complete configuration establishes its conversation and Workspace; later configuration changes apply in order. Messages enter its queue and start or join work at an input boundary. Eligible queued input resumes work after failure without another message.
- Workflow authors name submissions; Runtime saves an internal UUIDv4 with each durable intent for delivery retries. Direct callers and Workflow launchers retain their request keys and captured inputs before sending.
- Use stable idempotency keys for every state-changing core command to recover its original acceptance or rejection after a lost reply. Retried stops retain their original work selection, including idle stops. Configuration completes at commit; accepted messages retain their queue admission identity and bind to a Turn when taken for processing. Workflow message calls wait for that processing result, not an earlier Turn's failure.
- Compose work with ordinary JavaScript functions, loops and deterministic Promise joins. Inspect a Workflow to find exact Session references and reuse selected conversations in later workflows.
- Approve exact Bash/Edit actions or explicitly configure permission bypass. Bash reads and creates files; Edit applies checked whole-line replacements to one existing file. Uncertain tool effects are never automatically replayed.
- Retain immutable conversation and provider continuation in SQLite. Bound orchestration memory and temporary storage independently of model-requested subprocess memory.

[ARCHITECTURE.md](ARCHITECTURE.md) defines these behaviors, interfaces, recovery rules and limits. It includes their necessary rationale and terminology. [VERIFICATION.md](VERIFICATION.md) defines the evidence required to implement them. [AGENTS.md](AGENTS.md) contains working rules. These are the maintained documents; historical discussions remain in Git and issues, and runnable experiments are indexed in [research/README.md](research/README.md).

V1 excludes conversation branching/editing, attachments, automatic provider fallback, incompatible model switching, multi-host execution, plugins/dynamic tools, MCP execution, retained workflow VMs, storage migration, public event-stream/watch/webhook/push interfaces, TUI/editor/Web UI and a separate daemon manager. Native embedding and Durable Objects are design probes, not initial supported deployments.

[V1 design readiness was accepted](https://github.com/DivyanshGolyan/latifa/issues/124#issuecomment-5651285657) on 2026-09-13 after the integrated walkthrough. The [readiness map](https://github.com/DivyanshGolyan/latifa/issues/2) records the completed design work. Implementation proceeds in bounded slices under the accepted contract; production and live-provider qualification remain required. Retired planning tickets do not mean implementation is complete.

## Build and try the current implementation

Requirements: Zig 0.16.0, Python 3, Perl, a C toolchain and Make. The opt-in production measurement commands additionally require Go 1.27.1. SQLite 3.53.4, curl 8.22.0 and OpenSSL 3.6.3 are pinned by the build.

```sh
zig build
./zig-out/bin/latifa serve --store /absolute/path/to/private-store
```

The partial development transport is opt-in so it cannot make a live provider call. To exercise this slice, start the Host with an HTTPS endpoint, or with loopback HTTP for a deterministic local fixture. The Host rejects non-loopback plaintext endpoints. No authentication is attached in this slice.

```sh
./zig-out/bin/latifa serve \
  --store /absolute/path/to/private-store \
  --provider-endpoint http://127.0.0.1:8000/responses
```

In another shell, configure a Session. The record path must be in a private directory; retry reuses that durable capture after a lost reply or client restart.

```sh
./zig-out/bin/latifa configure \
  --store /absolute/path/to/private-store \
  --record /absolute/path/to/private-records/configure.json \
  --key configure-1 \
  --session direct/reviewer \
  --workspace /absolute/path/to/workspace \
  --model gpt-6-astra

./zig-out/bin/latifa retry \
  --store /absolute/path/to/private-store \
  --record /absolute/path/to/private-records/configure.json \
  --kind configure
```

Submit a complete message from a file or from stdin. Acceptance identifies its immutable queued admission; retry reuses the captured record and never reads the original source again.

```sh
./zig-out/bin/latifa message \
  --store /absolute/path/to/private-store \
  --record /absolute/path/to/private-records/message.json \
  --key message-1 \
  --session direct/reviewer \
  --text -

./zig-out/bin/latifa retry \
  --store /absolute/path/to/private-store \
  --record /absolute/path/to/private-records/message.json \
  --kind message

./zig-out/bin/latifa observe-command \
  --store /absolute/path/to/private-store \
  --key message-1

./zig-out/bin/latifa read-result \
  --store /absolute/path/to/private-store \
  --key message-1
```

The applicable gates are:

```sh
zig build check
zig build cross-check
zig build dispatch-integration
zig build measure-admission
zig build measure-message-admission
zig build measure-model-dispatch
zig build measure-model-output
```

The measurement steps are opt-in macOS resource runs. Provider authentication, structured-answer validation, automatic retry/recovery of interrupted Attempts, tool execution and live checks are not available in this slice. Dependency licenses are recorded in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
`check` exercises both the ReleaseSafe production gate and the default Debug artifact shown above; `cross-check` compiles ReleaseSmall deliverables.
