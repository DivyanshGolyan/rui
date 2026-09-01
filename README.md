# OnePage

OnePage is a resource-bounded, crash-resumable local runtime for programmable coding-agent workflows.

```text
Workflow Run
  └── keyed Turn membership

Session
  ├── linear Conversation
  ├── sparse Session Context revisions
  └── Turns
       └── Operations
            ├── Attempts
            ├── Completions
            └── Resolution
```

A Caller supplies a JavaScript Workflow Definition and stable Run Key. One native Zig Host Runtime owns Workflow Runs, reusable Sessions, Turns, providers, tools, permissions, recovery, capacities, and one SQLite Host Store. QuickJS is a disposable workflow evaluator, not another agent runtime.

Sessions are reusable linear Conversations and never terminal. One ordinary User input starts a Turn; a correlated permission or input response may resume it. Turns settle. One model response may produce multiple ordered Tool Calls, each represented as an independently recoverable child Operation.

Persistent model-visible defaults change through sparse Session Context Revisions. Each Turn freezes one Turn Contract, and each model Operation freezes one provider-neutral Model Request Manifest. Provider credentials and transport remain late-bound. Compaction changes only the bounded Model Context projection and never rewrites Conversation history.

SQLite rows and constraints are canonical authority. OnePage does not retain a second Session Ledger, reducer image, continuation blob, or resident Session graph.

## Current status

The checkout implements the deterministic single-Session Harness, SQLite Host Store, provider-neutral model path, Codex subscription adapter, permissioned Bash and one-file patch execution, effect-specific recovery, and disposable QuickJS evaluator kernel.

The remaining V1 work replaces the historical terminal-Session/ledger implementation with relational reusable Sessions and Turns, adds sparse model-context versioning, and then carries the proven components through durable Workflow Runs. GitHub issue #2 is the authoritative workstream.

## Normative contracts

- [`CONTEXT.md`](CONTEXT.md) — canonical language
- [`PRODUCT.md`](PRODUCT.md) — V1 product behaviour
- [`ARCHITECTURE.md`](ARCHITECTURE.md) — ownership and durable authority
- [`VERIFICATION.md`](VERIFICATION.md) — required evidence
- [`docs/style.md`](docs/style.md) — implementation discipline
- [`docs/spec/run-snapshot-v1.schema.json`](docs/spec/run-snapshot-v1.schema.json)
- [`docs/spec/interaction-response-batch-v1.schema.json`](docs/spec/interaction-response-batch-v1.schema.json)

Accepted ADRs are normative. Historical spikes, measurements, design records, and research explain how the project reached the current decisions but do not override them.

## Deterministic fixtures

```sh
zig build fixture-answer -Doptimize=ReleaseSmall
zig build fixture-bash -Doptimize=ReleaseSmall
zig build fixture-patch-deny -Doptimize=ReleaseSmall
zig build fixture-repair -Doptimize=ReleaseSmall
```

These use the same provider-neutral Conversation, Attempt admission, permission, recovery, and tool paths as the live provider adapter.

## Codex subscription

OnePage is its own Codex client. It does not invoke the Codex CLI or load an OpenAI SDK. Authorization uses OpenAI's browser/device flow and stores access, refresh, and account binding only in macOS Keychain.

```sh
zig build
./zig-out/bin/onepage --codex-login
zig build codex-live-repair
```

The live repair is opt-in and not part of `zig build check`. Credentials are not written to SQLite, the repository, Conversation, child-tool environments, or fixtures.

```sh
./zig-out/bin/onepage --codex-logout
```

## Requirements

- macOS on Apple Silicon
- Zig 0.16.0
- `/usr/bin/git`
- macOS system libcurl 7.85.0 or newer with HTTPS, asynchronous DNS, and thread-safe global initialization

## Validation

```sh
zig build check
zig build test -Doptimize=ReleaseSafe
```

Changes to the Workflow Evaluator, its protocol, QuickJS dependency, or evaluator build graph also run:

```sh
zig build workflow-check
```

## Architecture decisions

The newest foundational decisions are:

- [ADR-0018: SQLite is the sole durable content store](docs/adr/0018-use-sqlite-as-the-sole-durable-content-store.md)
- [ADR-0019: relational Session and Turn facts are authority](docs/adr/0019-use-relational-session-turn-authority.md)
- [ADR-0020: model-visible context is versioned sparsely](docs/adr/0020-version-model-visible-context-sparsely.md)

The complete ADR, research, spike, measurement, and historical-design collections live under [`docs/`](docs/).
