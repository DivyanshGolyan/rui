# Hardware input

Physical keys and the mouse wheel in a real GUI terminal (Terminal.app, iTerm2, Ghostty) attached to a run's tmux window. This is the only L4 surface. Byte replay (L1–L3) never counts here.

## Sub-features

- `hw-keys`: typed text, Enter, PgUp/PgDn, arrows, Esc, Ctrl-G and Ctrl-C from the physical keyboard.
- `hw-wheel`: physical wheel notches scroll the conversation. The terminal sends mouse reports or arrows (alternate scroll).
- `hw-consent`: physical `a`/`d` Enter on a fully read Action.
- `hw-focus-click`: clicking or focusing the window injects no draft text.

## How to get to it (user POV)

- Use Rui in a desktop terminal window with a keyboard and mouse.

## Driving it with verify-rui

Preconditions:

- A human is at the Mac and has said so. Never start this unattended.
- The pinned build exists for the head under test.
- Do not change Accessibility or Input Monitoring. None is needed: the window is an owned Terminal.app window running Rui under the tap, so only that window's bytes are recorded.

- **Guided session, about 5–6 minutes.** Run `$V physical FULLSHA`. It:
  - creates its own run and requires `doctor` PASS;
  - opens two Terminal.app windows: `verify-rui phys (owned test window)`, which runs Rui on Session `approve`, and `verify-rui COACH (read only)`, which shows one instruction at a time;
  - grades each step automatically from the bytes Rui received, committed frames, provider requests, capture keys and `project/progress.log`;
  - after the 13 direct steps, opens a third window attached to an owned tmux window on Session `demo` for 4 tmux steps;
  - ends with cleanup, keeping the evidence.
- **Direct steps:**
  - type `hello physical`: typed one key per chunk, no paste marker, draft shown;
  - Enter: one CR, one provider request with the exact text, one capture key with the same text, answer shown;
  - PgUp ×2: Browsing;
  - Ctrl-G: live;
  - wheel up: scrolls;
  - wheel down: live;
  - arrows ↑×3 ↓×3;
  - PgUp then Esc;
  - `consent check` + Enter: `Run Bash` shown;
  - PgDn until the choices are enabled;
  - `a` + Enter: exactly 30 lines in `progress.log`, tool summary sent;
  - a second proposal, then `d` + Enter: still 30 lines, tool result delivered;
  - Ctrl-C: rc 0, termios restored, alternate screen left.
- **tmux steps:** `hello tmux` + Enter; wheel up then Ctrl-G; `/status` (page shown, no provider request); Esc then Ctrl-C.
- **Result.** It prints `VERDICT PASS|ISSUES` and writes `evidence/physical/result.json` and `steps.jsonl`. Each step records its received bytes with monotonic times, its facts and a snapshot (`terms/phys*/shots/phys-NN-*`). A step not observed within its timeout is `MISSING`. The command then prints `FAIL: physical events missing` and exits 1. A missing step is never a pass.
- **Launch check, no human needed.** Run `$V physical FULLSHA --smoke`. It opens the owned window, reaches the composer, ends Rui with SIGTERM and checks restoration. It injects no input and is not hardware evidence.
- **Tooling rehearsal.** Run `$V physical FULLSHA --rehearse` (synthetic L1/L3 input, `REHEARSAL-PASS`). Run `--rehearse --no-tmux --rehearse-omit pgup wheel-up` as the negative control: it must print `REHEARSAL-ISSUES` and exit 1. A rehearsal validates the grader only.

## Gotchas

- Without a human this feature is BLOCKED. Synthetic CGEvent keystrokes need Accessibility. Even with it, they are synthetic and not physical.
- At byte level a wheel notch and an arrow key are identical (`ESC[A`/`ESC OA`). The wheel rows rest on the coach's instruction plus the bytes and their timing. Ask the human to use only the wheel during wheel steps.
- Terminal.app sends no DECRPM replies, so Rui does not enable `?1007` there. Wheel scrolling then depends on Terminal.app's own alternate-screen scrolling, which the wheel steps test.
- On a laptop, PgUp is fn+↑. If Terminal.app consumes it for its own scrollback, the step shows `pgup_sequences: 0`. That is a real finding for that terminal, not something to retry until it passes.
- Input capture covers only this owned tmux window. Never record other windows or the user's own typing elsewhere.
- A click that activates a mouse-tracking window can send a mouse report. Check `input.jsonl` for `ESC[M` before blaming the editor for a stray prefix.
