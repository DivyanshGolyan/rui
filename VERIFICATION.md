# Verification

[ARCHITECTURE.md](ARCHITECTURE.md) owns behavior.
This document owns required evidence: the [canonical gates](#canonical-gates) and the [contract index](#contract-index).
Test production interfaces and real SQLite transactions against independent expectations.
Crash tests kill a fixture process and reopen in a fresh one; injected returned errors are fault tests.
Record revision, machine, dependencies, inputs and measurements.
Prototypes, source inspection and compilation are not production qualification; [research evidence](research/README.md) records those limits.
Git history keeps earlier test specifications and dated results.

## Canonical gates

- For what a test must be, invariant catalogs, and moving tests onto those rules, read [Test requirements](docs/verification/testing.md).
- For test selection, fixture rules, composed gates, or caches, read [Canonical verification gates](docs/verification/gates.md).
- For candidate admission, landing cadence, promotion, or release publication, read [Landing and release evidence](docs/verification/release.md).
- For native platforms, resource campaigns, or release demonstrations, read [Native qualification and demonstrations](docs/verification/qualification.md).

## Sidebar and upgrade feedback

The [Session UI contract](docs/contracts/session-ui.md#required-evidence) requires owner-domain tests for memory fitting, the divider immediately above a single row with Settings and either memory or an update control, update-button states and separate drawn-target admission, and chat-only footer feedback, including narrow widths. Available, running and failed update labels replace memory completely, even when both would fit. Current and completed versions have no bottom label or target; available reads `Update to <version>`, running reads `Updating…`, and failure reads exactly `Update failed`, with its full diagnostic retained in Settings Version. Reverting mutations must fail the relevant assertions. Capture current, available, updating and failed sidebar states and the chat after an update in day and night at 140×40 and 46×30 using verify-rui, before and after. Frames are renderer evidence, not physical-input evidence.

## Input-contained panels

The [Session UI contract](docs/contracts/session-ui.md#required-evidence) requires shared placement evidence for the command list, chat info and Settings inside the input rules, plain unboxed backgrounds and the usual selection bar, compact command overflow and matching `esc` footers. The `panels-command-list`, `panels-chat-info` and `panels-settings` verify-rui recipes cover night at 140×40 and 46×30. Run the affected native owner tests, including the consent/panel adoption and focus domain and the single-list Settings layout domain, the panel integration group and verify-rui recipe unit/map tests. Frame recipes are required capture inputs, not a claim that frames have been captured.

## Settings Keys scrolling

The [Session UI contract](docs/contracts/session-ui.md#required-evidence) requires a bounded Keys viewport that makes the full shortcut reference reachable without shrinking or changing a retained draft. Exercise unmodified Up/Down by row, Page Up/Down (including shifted page keys) by viewport, both ends and overscroll, narrow and short viewports, resize and reopen at the top, and verify every shared key row becomes visible. Cover the actual input/close path and assert the exact retained draft and input geometry before, during and after scrolling; include a broken-scroll or bounds negative control. Capture the relevant changed-binary terminal cells at wide and narrow sizes, including a scrolled view. These are required checks and captures, not evidence that they have been run; renderer frames do not establish physical input.

## First launch list

Run `zig build test-logic -Dtest-filter='initial presentation core'` and `zig build test-native -Dtest-filter='initial list is queued'` and capture wide-launch, narrow-launch and chat before and after. The Session UI evidence row covers early, late, unavailable and empty live answers; PTY frames are not physical-terminal evidence.

## List tint padding

`GroupedList row inset is stable for selection hover and plain rows` checks shared row bounds at zero, narrow and wide widths in direct, indexed and no colour. Run the touched list, overview, panel, model-choice and palette owners, and remove the inset as a negative control. Capture before and after list and panel frames in day and night at 140×40 and 46×30 through verify-rui; these are renderer evidence, not physical-terminal evidence.

## Feed inset and activity spacing

Run native owners `SUI-4`, `SUI-17`, `SUI-19` and `SUI-30`, plus the overview and session-chrome integration groups. Capture before and after User bands and activity at 140×40 and 46×30 with verify-rui. These frames establish renderer output, not physical input.

## Contract index

The [Session UI invariant catalog](docs/invariants/session-ui.md) names the screen-seam owners for the welcome and chat tabs.

ARCHITECTURE owns behavior; tests own cases.
Quoted names are Zig filters: `zig build test -Dtest-filter='model revisions'`.
Other identifiers name targets, `tests/integration/` fixtures, modes or functions.
`none located` means no check; `planned` means unimplemented behavior.
Neither is coverage.
Update rows with checks.


The subsystem references keep accepted behavior and required evidence together. Read the subsystem you change:

- [Admission and Session configuration](docs/contracts/admission.md#required-evidence).
- [Conversation, settings, and skills](docs/contracts/conversation.md#required-evidence).
- [Model requests and provider context](docs/contracts/model-io.md#required-evidence), including the shared tool-result route, MCP image ordering, a single text budget, failure and replay, and synthetic provider request evidence.
- [Tools, execution, and recovery](docs/contracts/execution.md#required-evidence).
- [Store transactions and representation](docs/contracts/store.md#required-evidence).
- [Session stops and outcomes](docs/contracts/sessions.md#required-evidence).
- [CLI operations and configuration](docs/contracts/cli.md#required-evidence).
- [Session UI and terminal lifetime](docs/contracts/session-ui.md#required-evidence), including footer-domain and SessionChrome tests crossing visible/hidden list with context below, at and above half used at 46 and 140 columns. Require list-dependent name visibility, thresholded `N% context left`, no permanent info hint, retained clickable chat info and Alt-I in Keys; `human_cli_integration.py session-chrome` checks the native path, and frame recipes include context below half. The same contract requires shared full-list/sidebar row marks, state-age boundaries, alignment, 200 ms spinner frames and the earliest visible row-age/quota-countdown deadline, including header-only countdowns and minute-scale quota wording. Native empty-chat Escape and spinner repaint tests preserve all four row states at narrow width; frame resize tests reject old-viewport spinner commits until the resize reset and repaint commit. Input and User-message appearance evidence includes both widths and themes, preserved input/rule positions, the shared timestamp domain and indexed before/after frames; see the owning evidence table. `widget_style.zig` `line stitches use thread in every capability` checks horizontal and vertical stitch glyphs and thread foreground across Unicode/ASCII and direct, indexed and no-colour depths.
- [Reports, Activity, and local protocol](docs/contracts/inspection.md#required-evidence).
- [Host ownership and lifetime](docs/contracts/host.md#required-evidence), including settings admission, frozen detached consumption, later-source upgrade admission and private-target capability refusal; [SH-47](docs/invariants/store-host.md) and [CLI-26/CLI-18](docs/invariants/cli-inspection.md) own saved-path and refusal cases.
- [Resources and selection progress](docs/contracts/resources.md#required-evidence), including fitting output, optional spill yielding, live scratch charges and retained-queue handoff.
- [Diagnostic records and stderr](docs/contracts/diagnostics.md#required-evidence).

Release watch verification runs SH-143 to SH-145 (`ReleaseWatch`: first poll, the 50 to 70 minute gap, a failed read keeping the offer, the newer-build rule, and settle) and SH-72 (every run reads the release itself, after inspecting the selection). `upgrade-integration` keeps the exact `terminal_download_recovery` curl-attempt sequence: the background read's lookup, then the request's own lookup failing normally, its IPv4 lookup and checksums, and the archive over that same IPv4 owner.

Sidebar verification covers the retained divider immediately above Settings, shared row geometry, updates replacing memory completely and whole update labels at narrow widths, hidden current/completed versions, exact short failure text, and transient paused/publication lines ending with the attempt. Day and night failure recipes wait for the same settled overview state without relying on the removed open hint; the Settings Version row retains the complete diagnostic.

Receipt-version control verification crosses discovered candidate versions below, equal to and above the selected receipt version with installed and unchanged publication outcomes and each Host outcome. Superseded endings retain the receipt version, not the old running client version, and update offers compare against that selected version.

The upgrade-integration selected-version FIFO case pins selected-installation inspection before any release HTTP request by the requested check; the TUI's startup release read does not wait for that probe, and Escape reaps that exact probe child without the check reaching the release lookup. The recovered-download case still requires the background lookup, then the request's IPv4 lookup and checksums, and the archive through the same Download owner.
