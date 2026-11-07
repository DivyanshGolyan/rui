# Status and navigation

`/status` shows the Session's settings and current work as a browsing page. The user scrolls history with PgUp/PgDn, arrows or the wheel, resumes live by scrolling to the actual end or Ctrl-End (End only with an empty draft); Esc or Ctrl-G retains page-return navigation, and loses no draft.

## Sub-features

- `status-page`: `/status` shows ` Status · NAME · ID`, the `Permissions` row (bypass is described only here), the `Work` section and the compaction rows, under `Browsing · Esc returns`.
- `status-refresh`: a second `/status` during or after work shows the current `Work` state, not stale text.
- `details`: `/details` shows each saved tool result's last 8,192 raw bytes, marks shortened results with `Earlier output omitted`, and retains full canonical raw export.
- `scroll-page`: PgUp/PgDn move by pages without a Browsing header; the footer says Looking back. All-fitting/no-older Up/PgUp changes no cells; `/history` can reveal Start of conversation. Appends preserve the first content; downward motion joins retained newer output before following at the actual end. View-capacity limits and real retention gaps have distinct footer labels.
- `scroll-wheel`: the physical wheel scrolls. Rui enables alternate scroll (`?1007h`) when the terminal reports it reset, so the terminal sends arrow keys. Rui does not enable mouse tracking.
- `return-live`: Esc, End (empty draft) and Ctrl-G return to the latest messages with the draft unchanged.

## How to get to it (user POV)

- Type `/status` or `/details` and Enter. Press PgUp/PgDn/Up/Down or use the wheel. Press Esc, End or Ctrl-G.

## Driving it with verify-rui

Preconditions:

- A run with `--seed 3` or more, `doctor` PASS, and a terminal on `demo`.

- **Status.** Run `$V send "$RUN" s1 --text /status`, `--keys Enter`, then `$V wait "$RUN" s1 --marker 'Status · ' --after G`. The frame starts with `Browsing · Esc returns` and ` Status · ` with the Session's ID, marks the `Effort` row with `›`, contains `Permissions     bypass · Bash runs without asking`, and its `Work` section's state matches `$V rui "$RUN" session inspect --store STORE ID`, where ID is `sessions.demo` in the run's `run.json` (with seeded history that is `completed`, not `idle`).
- **Return.** Run `$V send "$RUN" s1 --keys C-g` and `wait --marker '›' --composer --after G`. The live view shows no `Browsing` line.
- **Refresh during work.** Send `slow please` and Enter, then `/status` while it streams. The `Work` section names the running state. After the answer, the open page must not keep `Working` once `Working…` is gone (a known 968d909 defect, C1); a fresh `/status` shows the completed work.
- **Settings.** On `/status`, `Down` moves `›` to `Permissions`, then over the Session's fixed `Model`, `Store` and `Instructions` to New Sessions' `Model`; `Shift-Down` and PgDn still scroll. Enter on `Permissions` puts `/configure --permission-mode ` in the draft with `bypass` and `ask` listed; Down, Enter runs it and the page comes back with `ask · Bash asks first` and `›` on `Permissions`. Enter on `Name` puts `/configure --label` and the current name in the draft.
- **Page.** Run `$V send "$RUN" s1 --keys PgUp` repeatedly until `wait --marker 'Start of conversation'`. Then `PgDn` until the composer is live.
- **Wheel path (L1–L3 only).** Rui scrolls the wheel through alternate scroll (`?1007h`), so a terminal turns the wheel into `Up`/`Down`. `--keys Up` therefore stands in for the wheel, except on `/status`, where `Up` and `Down` move `›`. `--keys SGRWheelUp` sends an unsolicited mouse report, which Rui ignores by design. Both are byte replay, not hardware.
- **Draft survives.** Type `keep me`, PgUp, then Ctrl-G. The caret row is still `› keep me` and the provider count is unchanged.
- **Proof.** Snapshots per step, plus `frames.jsonl` gens and times.

## Gotchas

- Rows wrap at narrow widths. Match `Permissions` rows by joined words, as `permission_row` does in `human_cli_integration.py`.
- After Esc, wait for the next frame before sending more input (the lone-Esc deadline).
- `/status` typed on a non-empty draft is draft text, not a command. Clear the draft first (`--keys BSpace` repeatedly).
