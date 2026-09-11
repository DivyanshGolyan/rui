# Latifa

Latifa (formerly OnePage) is a resource-bounded, crash-resumable local runtime for programmable coding-agent workflows. JavaScript coordinates reusable conversations; native Zig owns execution, permissions, recovery and SQLite storage. Codex subscription is the first live provider.

## Status

The source currently implements the earlier single-Session runtime, SQLite Store, Codex adapter, permissioned Bash and Git-backed patch execution, and a disposable QuickJS evaluator. Reusable Sessions/Turns, durable Workflow Runtime, the disk-first Host and native exact Edit are accepted designs awaiting implementation. Documentation and research results are not release certification.

The redesigned V1 targets Linux and macOS on x86-64 and ARM64 through capability-based prerequisites. Current build instructions support macOS on Apple Silicon. Runtime verification uses the available Mac; source/API evidence and cross-compilation support other targets, whose unexecuted behavior remains unverified.

## Intended experience

Start one local server explicitly, then use direct CLI/script calls or JavaScript workflows. Clients can disconnect while saved work continues. Restart recovers unfinished work under its original inputs and remaining budgets.

- Construct a Session key locally. First complete configuration establishes its conversation and Workspace; later configuration changes apply in order. Messages start or join its current work.
- Use stable request keys to recover the original acceptance or rejection after a lost configuration/message reply. Configuration completes at commit; accepted messages bind to a Turn, and workflow message calls return that Turn's final text or validated structured answer.
- Compose work with ordinary JavaScript functions, loops and deterministic Promise joins. Inspect a Run to find exact Session keys and reuse selected conversations in later workflows.
- Approve exact Bash/Edit actions or explicitly configure permission bypass. Bash reads and creates files; Edit applies checked whole-line replacements to one existing file. Uncertain tool effects are never automatically replayed.
- Retain immutable conversation and provider continuation in SQLite. Bound orchestration memory and temporary storage independently of model-requested subprocess memory.

[ARCHITECTURE.md](ARCHITECTURE.md) defines these behaviors, interfaces, recovery rules and limits. It includes their necessary rationale and terminology. [VERIFICATION.md](VERIFICATION.md) defines the evidence required to implement them. [AGENTS.md](AGENTS.md) contains working rules. These are the maintained documents; historical discussions remain in Git and issues, and runnable experiments are indexed in [research/README.md](research/README.md).

V1 excludes conversation branching/editing, attachments, automatic provider fallback, incompatible model switching, multi-host execution, plugins/dynamic tools, MCP execution, retained workflow VMs, storage migration, public event-stream/watch/webhook/push interfaces, TUI/editor/Web UI and a separate daemon manager. Native embedding and Durable Objects are design probes, not initial supported deployments.

[Issue #2](https://github.com/DivyanshGolyan/latifa/issues/2) owns readiness. Provider wire research, Session/client decisions and interface walkthroughs are resolved in the contract; final readiness stays open there. Production and live-provider qualification remain required. Create implementation slices when the contract is aligned; retired planning tickets do not mean implementation is complete.

## Build and try the current implementation

The current build still produces `onepage` and `onepage-workflow-evaluator`; the commands below use those names.

Requirements: macOS on Apple Silicon, Zig 0.16.0, `/usr/bin/git`, and system libcurl 7.85.0 or newer with HTTPS, asynchronous DNS and thread-safe global initialization. SQLite and QuickJS sources are pinned by the build.

```sh
zig build
zig build fixture-answer -Doptimize=ReleaseSmall
zig build fixture-bash -Doptimize=ReleaseSmall
zig build fixture-patch-deny -Doptimize=ReleaseSmall
zig build fixture-repair -Doptimize=ReleaseSmall
```

Fixtures use the same model, permission and recovery paths as the current live adapter. See [verification gates](VERIFICATION.md#canonical-gates) for checks appropriate to a change.

Latifa is its own Codex client; it invokes neither the Codex CLI nor an OpenAI SDK. Login uses OpenAI's browser/device flow and stores credentials in macOS Keychain. Live checks are opt-in:

```sh
./zig-out/bin/onepage --codex-login
zig build codex-live-repair
./zig-out/bin/onepage --codex-logout
```

Credentials stay out of SQLite, repository files, conversations and child-tool environments. The designed Linux credential mechanisms are not implemented by these commands. Dependency licenses are recorded in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
