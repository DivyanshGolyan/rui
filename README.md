# OnePage

OnePage is a resource-bounded, crash-resumable local runtime for programmable coding-agent workflows.

```text
Workflow Run
  └── keyed Turn membership

Session
  ├── linear Conversation
  ├── User Message admissions
  ├── sparse Session Context revisions
  └── Turns
       └── Operations
            ├── Attempts
            │    └── at most one Completion
            └── Resolution
```

A Caller supplies a JavaScript Workflow Definition and stable Run Key. One native Zig Host Runtime owns Workflow Runs, reusable Sessions, Turns, providers, tools, permissions, recovery, capacities, and one SQLite Host Store. QuickJS is a disposable workflow evaluator, not another agent runtime.

Sessions are reusable linear Conversations and never terminal. One initiating User Message starts a Turn; later User Messages use the same admission primitive and may extend it at the next assistant-response model-Operation boundary. Internal compaction leaves pending messages untouched. A Permission Decision authorizes or denies one exact proposed Action and is not Conversation content. Turns settle. One model response may produce multiple ordered Tool Calls, each represented as an independently recoverable child Operation.

Persistent model-visible defaults change through sparse Session Context Revisions. Each Turn freezes one Turn Contract, and each model Operation freezes one exact Model Request Manifest. Provider credentials and transport remain late-bound. Compaction changes only the bounded Model Context projection and never rewrites Conversation history.

SQLite rows and constraints are canonical authority. OnePage does not retain a second Session Ledger, reducer image, continuation blob, or resident Session graph. The approved Host Runtime streams variable request and response content through bounded memory windows to non-authoritative unlinked scratch, then imports sealed evidence through one shared validation workspace.

## Current status

The production source still implements the historical deterministic single-Session runtime, SQLite Host Store, provider-neutral model path, Codex subscription adapter, permissioned Bash and one-file patch execution, effect-specific recovery, and disposable QuickJS evaluator kernel. It does not yet implement the relational Session/Turn or disk-first Host Runtime decisions.

The remaining V1 work replaces the historical terminal-Session/ledger implementation with relational reusable Sessions and Turns, adds sparse model-context versioning, and then carries the proven components through durable Workflow Runs. GitHub issue #2 is the authoritative workstream.

## Normative contracts

- [`CONTEXT.md`](CONTEXT.md) — canonical language
- [`PRODUCT.md`](PRODUCT.md) — V1 product behaviour
- [`ARCHITECTURE.md`](ARCHITECTURE.md) — ownership and durable authority
- [`VERIFICATION.md`](VERIFICATION.md) — required evidence
- [`docs/style.md`](docs/style.md) — implementation discipline

The superseded Run Snapshot and Interaction Response Batch schemas were deleted rather than migrated. Issue #39 must publish the replacement CLI's exact closed JSON fields, unions, omission rules, and integer encodings through compiled public types and golden fixtures; no new handwritten schema is accepted in advance of that implementation.

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
- [ADR-0021: the Host Runtime is disk-first and bounded](docs/adr/0021-use-a-disk-first-bounded-host-runtime.md)
- [ADR-0022: Runs use the Host Runtime's narrow typed API](docs/adr/0022-expose-runs-through-the-host-runtime-api.md)
- [ADR-0023: provider continuation has no duplicate replay authority](docs/adr/0023-preserve-provider-replay-without-silent-degradation.md)

The complete ADR, research, spike, measurement, and historical-design collections live under [`docs/`](docs/).
