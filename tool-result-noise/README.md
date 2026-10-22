# Tool-result noise evidence (lane T-01a16368, stack wip/land-30 @ 068b1d0c)

Linux x86_64 orb. Binaries: before = ReleaseSafe build of main bbb691ca; after = ReleaseSafe
`check` build of 068b1d0c's tree.

## Bytes, same typical successful call (`ls` of 3 files), real Host
`scripts/measure_result.py BINARY OUT.json`; asserts saved result == model function_call_output.
- `before.json`: 233 bytes (empty `stderr tail:` + two `Full …` paths)
- `after.json`: 72 bytes
- macOS before ~427 bytes is derived from code (+194-byte retirement line), NOT measured.

## Real running TUI
- `tmux-live.txt`, `tmux-details.txt`: tmux 100x30 capture, `rui session resume`, fixture provider.
  `tmux-model-outputs.json`: exact function_call_output bytes the provider received in that run.
- `foot/`: foot 1.13.1 under headless sway 1.7 (pixman, scale 2), grim screenshots, wf-recorder clip.
  Input through a tmux client inside foot (`scripts/capture.sh`).
  - `after-live.png` / `.txt`: ✓ success with no output; failure shows its stderr line.
  - `after-details.png` / `.txt`: /details shows full saved results; no empty stderr header, no retirement line.
  - `after-returned.png`: after Esc; byte-identical (`cmp`) to `after-live.png`.
  - `after-details.mp4`: 5.09 s, live → /details → Esc return (wf-recorder records on damage:
    frames at 0, 1.95, 1.95, 1.97, 5.09 s; `after-details-clip-last-frame.png` is the 5.09 s return frame).
- Discarded attempts: two direct-wtype foot captures dropped/merged keystrokes (prompts merged into one
  message); not published. The final foot run hit a 58 s outer timeout after all media were captured,
  before the Host wrote its outputs file; the tmux run above provides the model bytes for the same binary.

## Checks (logs/)
- `check.log`: first `zig build check` — FAILED (bash-owner single-window read; pyte missing). Retained.
- `check2.log`: `zig build check` on the lane tree — 98/98, exit 0.
- `test-logic.log`: first run FAILED 292/293 (wrong unit assertion); fixed run 293/293 is in the commit message.
- admission-debug, codex-h2, transport-h2: exit 0.
