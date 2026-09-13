# Latifa

Latifa (formerly OnePage) is a resource-bounded, crash-resumable local runtime for programmable coding-agent workflows. JavaScript coordinates reusable conversations; native Zig owns execution, permissions, recovery and SQLite storage. Codex subscription is the first live provider.

## Status

The source implements the first redesigned runtime slice: an explicitly started Host, exclusive Store ownership, the direct configuration client, durable caller-side request capture, exact idempotent answer recovery, sparse Session updates, basic observations and bounded SQLite/content ingress. Model processing and every Workflow, tool, permission, stop and interruption surface enter in later implementation issues; the current message command reports that development limitation explicitly.

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

Requirements: Zig 0.16.0 and Python 3 for the process-level verification fixture. SQLite is pinned by the build.

```sh
zig build
./zig-out/bin/latifa serve --store /absolute/path/to/private-store
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

The applicable gates are:

```sh
zig build check
zig build cross-check
zig build measure-admission
```

`measure-admission` is an opt-in macOS resource run. Model/provider authentication and live checks are not available in this slice. Dependency licenses are recorded in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
`check` exercises both the ReleaseSafe production gate and the default Debug artifact shown above; `cross-check` compiles ReleaseSmall deliverables.
