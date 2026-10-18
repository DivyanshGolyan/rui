# Status and navigation

`/status` shows the Session's settings and current work as a browsing page. The user scrolls history with PgUp/PgDn, arrows or the wheel, returns to live with Esc, End or Ctrl-G, and loses no draft.

## Sub-features

- `status-page`: `/status` shows `Session: NAME`, `Permission:` (bypass is described only here), `Work:` and the compaction rows, under `Browsing · Esc returns`.
- `status-refresh`: a second `/status` during or after work shows current `Work:`, not stale text.
- `details`: `/details` shows full saved tool output.
- `scroll-page`: PgUp/PgDn move by pages, and repeated PgUp reaches `Start of conversation`.
- `scroll-wheel`: wheel reports (SGR `ESC[<64;x;yM` / `ESC[<65;…`) scroll like arrows.
- `return-live`: Esc, End (empty draft) and Ctrl-G return to the latest messages with the draft unchanged.

## How to get to it (user POV)

- Type `/status` or `/details` and Enter. Press PgUp/PgDn/Up/Down or use the wheel. Press Esc, End or Ctrl-G.

## Driving it with verify-rui

Preconditions:

- A run with `--seed 3` or more, `doctor` PASS, and a terminal on `demo`.

- **Status.** Run `$V send "$RUN" s1 --text /status`, `--keys Enter`, then `$V wait "$RUN" s1 --marker 'Session: demo' --after G`. The frame starts with `Browsing · Esc returns` and contains `Permission: bypass (Bash runs without asking)` and `Work: idle`.
- **Return.** Run `$V send "$RUN" s1 --keys C-g` and `wait --marker '›' --composer --after G`. The live view shows no `Browsing` line.
- **Refresh during work.** Send `slow please` and Enter, then `/status` while it streams. `Work:` names the running Message. After the answer, `/status` again shows `Work: idle`.
- **Page.** Run `$V send "$RUN" s1 --keys PgUp` repeatedly until `wait --marker 'Start of conversation'`. Then `PgDn` until the composer is live.
- **Wheel bytes (L1–L3 only).** Run `$V send "$RUN" s1 --keys WheelUp`. The frame scrolls. This is byte replay, not hardware.
- **Draft survives.** Type `keep me`, PgUp, then Ctrl-G. The caret row is still `› keep me` and the provider count is unchanged.
- **Proof.** Snapshots per step, plus `frames.jsonl` gens and times.

## Gotchas

- Rows wrap at narrow widths. Match `Permission:` rows by joined words, as `permission_row` does in `human_cli_integration.py`.
- After Esc, wait for the next frame before sending more input (the lone-Esc deadline).
- `/status` typed on a non-empty draft is draft text, not a command. Clear the draft first (`--keys BSpace` repeatedly).
