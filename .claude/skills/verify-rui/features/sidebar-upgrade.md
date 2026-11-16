# Sidebar memory and updates

The list bottom has a divider above Settings, then quiet memory and the native version/update target below Settings. Overview exposes the same bottom widget at both widths; a narrow chat hides the list.

## Sub-features

- Current version, available update, Updating and retryable Update failed with a short failure reason when it fits.
- Separate Settings and version hit targets; Settings Version remains an upgrade entry point.
- A successfully upgraded conversation keeps its ordinary chat footer without upgrade notices.

## How to get to it (user POV)

Open Overview. The memory/version row sits below Settings. Click its version or update text to upgrade, and click the failure/retry text to retry. Settings opens the app panel; its Version row also starts Upgrade. Continue the already open conversation after installation.

## Driving it with verify-rui

Frame states: `sidebar-current`, `sidebar-available`, `sidebar-updating`, `sidebar-failure`, `chat-after-upgrade`, `day-sidebar-current`, `day-sidebar-available`, `day-sidebar-updating`, `day-sidebar-failure`, `day-chat-after-upgrade`

Build each pinned revision with `build FULLSHA --upgrade` before capture. This explicitly adds the same-source synthetic release actor and its source and binary hashes to the cached manifest; frames never builds it implicitly. Use the working frames.json as an explicit shared `--scenario` for before/after, selecting these states at `--sizes 140x40,46x30`. Every state gets a private managed installation and production Host, but Upgrade discovery is UID-global: a synthetic HOME does not isolate other Hosts owned by that account. Capture only under a dedicated fixture account such as `rui-s7-sidebar`, setting `VERIFY_RUI_UPGRADE_FIXTURE_USER=rui-s7-sidebar`. The runner refuses root and requires the explicit login name to match its non-root UID. Never use an account with unrelated Rui Hosts. The runner pauses and waits for its ordinary parent Host to retire before the first isolated Upgrade, retires every managed Host after its state, and restores the parent only when subsequent ordinary states need it. These boundaries are recorded in `upgrade-host-lifecycle.jsonl`; a failed Upgrade teardown stops the run rather than admitting another UID-global Upgrade. Only release HTTP responses and the existing provider fixture are synthetic.

Current and available use production discovery. Available advertises a newer metadata tag without installing its intentionally mismatched archive. Updating installs the valid actor from an older selected release and holds the existing after-publication file gate. Failure returns HTTP 403 at latest-release lookup. Both themes wait for the real post-attempt list read: the compact reason and the last-row `enter open` affordance must coexist, without the attempt-only Host paused row. Observing the failed run alone is too early. At 140 and 46 columns the reason is `Update failed: Couldn't reach GitHub`; memory is allowed to drop when the expanded reason needs its columns, never the reason. Chat-after-upgrade completes installation and relaunch while preserving the already open saved conversation. The same frame collector exports cells, text, ANSI, HTML and PNG. Per-state upgrade evidence records actor identity, candidate, selected installation and HTTP requests.

The shared scenario selects strict `comparison.before` row/notice expectations on the old revision and the ordinary expectations after. Before has no sidebar update target: the runner clicks Settings then Version, closes Settings after publication (when Escape cannot cancel), and captures the old global Publishing or failure diagnostic. After uses the native sidebar version hit target. Baseline availability has no visible control and retains its version beside Settings. Before assertions deliberately pin that old layout rather than accepting after-only assertions.

## Gotchas

No internal setters or synthetic painted UI are used. The publication gate stays held across both viewports, then is released during state cleanup. A normal unreleased pinned binary cannot replace the release actor. Runtime captures are L1 PTY input, not hardware proof. After both failure viewports are captured, an after-side native retry journey clears the HTTP 403, holds the archive response while capturing Updating, releases it and proves the selected installation and replacement ready Host. It then clicks Settings and Version, proving up-to-date behavior. Extra cells, HTML, ANSI, text and generations live under `journeys/STATE/`; primary frames retain the original failed state. Supply an explicit shared scenario when the baseline does not contain these new state names; default revision-specific pairing otherwise reports New screen.
