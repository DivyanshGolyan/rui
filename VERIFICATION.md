# Verification

[ARCHITECTURE.md](ARCHITECTURE.md) owns behavior.
This document owns required evidence: the [canonical gates](#canonical-gates) and the [contract index](#contract-index).
Test production interfaces and real SQLite transactions against independent expectations.
Crash tests kill a fixture process and reopen in a fresh one; injected returned errors are fault tests.
Record revision, machine, dependencies, inputs and measurements.
Prototypes, source inspection and compilation are not production qualification; [research evidence](research/README.md) records those limits.
Git history keeps earlier test specifications and dated results.

## Canonical gates

- For test selection, fixture rules, composed gates, or caches, read [Canonical verification gates](docs/verification/gates.md).
- For candidate admission, landing cadence, promotion, or release publication, read [Landing and release evidence](docs/verification/release.md).
- For native platforms, resource campaigns, or release demonstrations, read [Native qualification and demonstrations](docs/verification/qualification.md).

## Contract index

ARCHITECTURE owns behavior; tests own cases.
Quoted names are Zig filters: `zig build test -Dtest-filter='model revisions'`.
Other identifiers name targets, `tests/integration/` fixtures, modes or functions.
`none located` means no check; `planned` means unimplemented behavior.
Neither is coverage.
Update rows with checks.


The subsystem references keep accepted behavior and required evidence together. Read the subsystem you change:

- [Admission and Session configuration](docs/contracts/admission.md#required-evidence).
- [Conversation, settings, and skills](docs/contracts/conversation.md#required-evidence).
- [Model requests and provider context](docs/contracts/model-io.md#required-evidence).
- [Tools, execution, and recovery](docs/contracts/execution.md#required-evidence).
- [Store transactions and representation](docs/contracts/store.md#required-evidence).
- [Session stops and outcomes](docs/contracts/sessions.md#required-evidence).
- [CLI operations and configuration](docs/contracts/cli.md#required-evidence).
- [Session UI and terminal lifetime](docs/contracts/session-ui.md#required-evidence), including shared full-list/sidebar row marks, state-age boundaries, alignment, 100 ms spinner frames and idle minute redraws.
- [Reports, Activity, and local protocol](docs/contracts/inspection.md#required-evidence).
- [Host ownership and lifetime](docs/contracts/host.md#required-evidence).
- [Resources and selection progress](docs/contracts/resources.md#required-evidence).
- [Diagnostic records and stderr](docs/contracts/diagnostics.md#required-evidence).
