# OnePage

OnePage is a resource-bounded, crash-resumable local runtime for programmable coding-agent workflows.

```text
Workflow Run
  └── keyed Session operations and original results

Session
  ├── linear Conversation
  ├── User Message admissions
  ├── sparse Session Context revisions
  └── Turns
       └── Operations
            ├── current execution / retry facts
            └── immutable final Resolution and content references
```

A Caller supplies a JavaScript Workflow Definition and stable Run Key. One native Zig Host Runtime owns Workflow Runs, reusable Sessions, Turns, providers, tools, permissions, recovery, capacities, and one SQLite Host Store. QuickJS is a disposable workflow evaluator, not another agent runtime.

## Current status

The redesigned V1 must support Linux and macOS. The current implementation and existing build instructions remain macOS-specific; Linux support is not yet implemented or qualified. The [platform contract decision](https://github.com/DivyanshGolyan/onepage/issues/126) evaluates every macOS-only assumption and the mechanisms and evidence required on both systems.

The production source still implements the historical deterministic single-Session runtime, SQLite Host Store, provider-neutral model path, Codex subscription adapter, permissioned Bash and one-file patch execution, effect-specific recovery, and disposable QuickJS evaluator kernel. It does not yet implement the relational Session/Turn or disk-first Host Runtime decisions. The accepted native exact Edit module also remains design work: it replaces Git-based patch preparation/application, but production source still uses the historical tool.

The remaining V1 work replaces the historical terminal-Session/ledger implementation with relational reusable Sessions and Turns, adds sparse model-context versioning, and integrates the existing components into durable Workflow Runs with new production verification. [V1 design readiness](https://github.com/DivyanshGolyan/onepage/issues/2) indexes the remaining decisions and research; it is not an implementation checklist.

## Planning

Accepted behavior, ownership, terminology, and required evidence live in the normative documents below. Open decision and research issues hold unanswered questions; resolving one updates its owning documents. Implementation tickets are created when implementation is ready to begin against an aligned V1 contract, rather than maintained as parallel specifications during design.

The former implementation, cleanup, and release-verification tickets were closed as superseded planning, not completed work. Their useful requirements remain in the owning documents, and their source findings and original discussions remain historical evidence. The [cleanup record](docs/design/planning-cleanup-2026-09-05.md) maps those tickets to their owners. Future tickets should link the relevant contract sections and define one concrete implementation slice and its proof.

Readiness requires the V1 behavior decisions, provider evidence, and minimal resource matrix to agree with the docs. It does not require speculative post-V1 design, every SQL column, or every wire spelling to be settled. New evidence may still justify an explicit contract amendment during implementation.

## Normative contracts

- [`CONTEXT.md`](CONTEXT.md) — canonical language
- [`PRODUCT.md`](PRODUCT.md) — V1 product behaviour
- [`ARCHITECTURE.md`](ARCHITECTURE.md) — ownership and durable authority
- [`VERIFICATION.md`](VERIFICATION.md) — required evidence
- [`docs/style.md`](docs/style.md) — implementation discipline

The superseded Run Snapshot and Interaction Response Batch schemas were deleted rather than migrated. The replacement HTTP/CLI contract must publish its exact closed JSON fields, unions, omission rules, and integer encodings through compiled public types and golden fixtures; no new handwritten schema is accepted in advance of that implementation.

Accepted ADRs are normative subject to their explicit amendments; superseded passages retain historical meaning. The [accepted-baseline reconciliation](docs/design/accepted-baseline-2026-09-08.md) traces issue resolutions to their owners and distinguishes the open redesign from this baseline. Historical spikes, measurements, design records, and research explain how the project reached the current decisions but do not override them.

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

These are prerequisites for the current implementation, not the redesigned V1 platform scope:

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
- [ADR-0024: capture Run inspection before delivery](docs/adr/0024-capture-run-inspection-before-delivery.md)
- [ADR-0025: enforce execution contracts without historical result replay](docs/adr/0025-enforce-execution-contracts-without-historical-replay.md)
- [ADR-0026: Operations own current execution and final results](docs/adr/0026-let-operations-own-current-execution-and-final-results.md)
- [ADR-0027: native exact Edit replaces Git-backed Patch](docs/adr/0027-use-an-in-process-exact-edit-module.md)

The complete ADR, research, spike, measurement, and historical-design collections live under [`docs/`](docs).
