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

The [Session UI contract](docs/contracts/session-ui.md#required-evidence) requires owner-domain tests for memory fitting, the divider immediately above a single row with Settings and either memory or an update control, update-button states and separate drawn-target admission, and chat-only footer feedback, including narrow widths. Available, running and failed update labels replace memory completely, even when both would fit. Current and completed versions have no bottom label or target; available reads `Update to <version>`, running reads `Updating…`, and failure reads exactly `Update failed`, with its full diagnostic retained in Settings Version. Reverting mutations must fail the relevant assertions. Capture current, available, updating and failed sidebar states and the chat after an update in day and night at 140×40 and 46×30 using verify-rui, before and after. Frames are renderer evidence, not physical-input evidence.

## First launch list

Run `zig build test-logic -Dtest-filter='initial presentation core'` and `zig build test-native -Dtest-filter='initial list is queued'` and capture wide-launch, narrow-launch and chat before and after. The Session UI evidence row covers early, late, unavailable and empty live answers; PTY frames are not physical-terminal evidence.

## List tint padding

`GroupedList row inset is stable for selection hover and plain rows` checks shared row bounds at zero, narrow and wide widths in direct, indexed and no colour. Run the touched list, overview, panel, model-choice and palette owners, and remove the inset as a negative control. Capture before and after list and panel frames in day and night at 140×40 and 46×30 through verify-rui; these are renderer evidence, not physical-terminal evidence.

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
- [Session UI and terminal lifetime](docs/contracts/session-ui.md#required-evidence), including footer-domain and SessionChrome tests crossing visible/hidden list with context below, at and above half used at 46 and 140 columns. Require list-dependent name visibility, thresholded `N% context left`, no permanent info hint, retained clickable chat info and Alt-I in Keys; `human_cli_integration.py session-chrome` checks the native path, and frame recipes include context below half. The same contract requires shared full-list/sidebar row marks, state-age boundaries, alignment, 100 ms spinner frames and the earliest visible row-age/quota-countdown deadline, including header-only countdowns and minute-scale quota wording. Native empty-chat Escape and spinner repaint tests preserve all four row states at narrow width; frame resize tests reject old-viewport spinner commits until the resize reset and repaint commit. Input and User-message appearance evidence includes both widths and themes, preserved input/rule positions, the shared timestamp domain and indexed before/after frames; see the owning evidence table.
- [Reports, Activity, and local protocol](docs/contracts/inspection.md#required-evidence).
- [Host ownership and lifetime](docs/contracts/host.md#required-evidence), including frozen detached consumption, later-source upgrade admission and private-target capability refusal.
- [Resources and selection progress](docs/contracts/resources.md#required-evidence).
- [Diagnostic records and stderr](docs/contracts/diagnostics.md#required-evidence).

Upgrade discovery handoff verification runs the `UpgradeJob` discovery-handoff domain and the adopted-candidate precondition domain, including in-flight success/failure, cancellation, retained candidate custody and recovered transport. `upgrade-integration` keeps the exact `terminal_download_recovery` curl-attempt sequence: normal lookup failure, IPv4 lookup and checksums, then the archive over the same IPv4 owner, without a second discovery.

Sidebar verification covers the retained divider immediately above Settings, shared row geometry, updates replacing memory completely and whole update labels at narrow widths, hidden current/completed versions, exact short failure text, and transient paused/publication lines ending with the attempt. Day and night failure recipes wait for the same settled overview state without relying on the removed open hint; the Settings Version row retains the complete diagnostic.

Receipt-version control verification crosses discovered candidate versions below, equal to and above the selected receipt version with installed and unchanged publication outcomes and each Host outcome. Superseded endings retain the receipt version, not the old running client version, and update offers compare against that selected version.

The upgrade-integration selected-version FIFO case pins selected-installation inspection before any release HTTP request, including startup availability discovery, and requires Escape to reap that exact probe child without reaching discovery. The recovered-download case still requires one metadata/checksum discovery and IPv4 archive download through the same Download owner.
