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

## Sidebar and upgrade feedback

The [Session UI contract](docs/contracts/session-ui.md#required-evidence) requires owner-domain tests for memory fitting, update-button states and drawn-target admission, and chat-only footer feedback, including narrow widths. Reverting mutations must fail the relevant assertions. Capture current, available, updating and failed sidebar states and the chat after an update in day and night at 140×40 and 46×30 using verify-rui, before and after. Frames are renderer evidence, not physical-input evidence.

## Input-contained panels

The [Session UI contract](docs/contracts/session-ui.md#required-evidence) requires shared placement evidence for the command list, chat info and Settings inside the input rules, plain unboxed backgrounds and the usual selection bar, compact command overflow and matching `esc` footers. The `panels-command-list`, `panels-chat-info` and `panels-settings` verify-rui recipes cover night at 140×40 and 46×30. Run the affected native owner tests, the panel integration group and verify-rui recipe unit/map tests. Frame recipes are required capture inputs, not a claim that frames have been captured.

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
- [Session UI and terminal lifetime](docs/contracts/session-ui.md#required-evidence), including shared full-list/sidebar row marks, state-age boundaries, alignment, 100 ms spinner frames and the earliest visible row-age/quota-countdown deadline, including header-only countdowns and minute-scale quota wording. Native empty-chat Escape and spinner repaint tests preserve all four row states at narrow width; frame resize tests reject old-viewport spinner commits until the resize reset and repaint commit. Input and User-message appearance evidence includes both widths and themes, preserved input/rule positions, the shared timestamp domain and indexed before/after frames; see the owning evidence table.
- [Reports, Activity, and local protocol](docs/contracts/inspection.md#required-evidence).
- [Host ownership and lifetime](docs/contracts/host.md#required-evidence).
- [Resources and selection progress](docs/contracts/resources.md#required-evidence).
- [Diagnostic records and stderr](docs/contracts/diagnostics.md#required-evidence).

Upgrade discovery handoff verification runs the `UpgradeJob` discovery-handoff domain and the adopted-candidate precondition domain, including in-flight success/failure, cancellation, retained candidate custody and recovered transport. `upgrade-integration` keeps the exact `terminal_download_recovery` curl-attempt sequence: normal lookup failure, IPv4 lookup and checksums, then the archive over the same IPv4 owner, without a second discovery.

Sidebar fix-round verification covers the retained divider, owner-supplied compact failure reason and whole-label fallback at narrow widths, and transient paused/publication lines ending with the attempt. Day and night failure recipes wait for the same settled overview state without relying on the removed open hint; the Settings Version row retains the complete diagnostic.

Receipt-version control verification crosses discovered candidate versions below, equal to and above the selected receipt version with installed and unchanged publication outcomes and each Host outcome. Superseded endings retain the receipt version, not the old running client version, and update offers compare against that selected version.

The upgrade-integration selected-version FIFO case pins selected-installation inspection before any release HTTP request, including startup availability discovery, and requires Escape to reap that exact probe child without reaching discovery. The recovered-download case still requires one metadata/checksum discovery and IPv4 archive download through the same Download owner.
