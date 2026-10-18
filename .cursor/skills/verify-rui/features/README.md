# Rui renderer verification map

The maintained source for verifying Rui's full-screen interactive terminal. Read [../SKILL.md](../SKILL.md) for launch, doctor, evidence and cleanup, then use the matching feature file as the recipe.

## Baseline preconditions

- A pinned build exists: `$V build FULLSHA --source CLEAN_WORKTREE` (`V=.cursor/skills/verify-rui/scripts/verify-rui`).
- Each experiment has its own `RUN=$($V new FULLSHA --seed 3 --label NAME)`, and `$V doctor "$RUN" --expect-sha FULLSHA` prints `PASS`.
- Session `demo` is bypass with three seeded answers. Session `approve` is ask with no history.
- Never drive a Store, Host or tmux server this run did not start.

## Driving conventions

- Every step pairs one `send` with one `wait --after GEN` on a committed frame. Record the generation each step returns.
- Use `screen --label NN-what` before and after every state change you claim.
- Name the surface (`pty`, `tmux-detached`, `tmux-attached`, `gui`) and the input layer (L1 FIFO, L2 send-keys, L3 attached-client bytes, L4 physical) with every result.

## Proof and skip reporting

- Visible proof is a committed frame. Side-effect proof is `provider.jsonl`, plus `request list` and `request inspect`, plus `exit.json`.
- Temporal claims need `frames.jsonl` timestamps, or the `timeline.txt` from `$V evidence`, not a still.
- Report an unreachable path with the command tried and the unmet precondition. A skipped surface is not verified through another.

## Features

- [Compose and submit](./compose-submit.md): draft entry, multiline paste, a single submission, the answer and capture correlation.
- [Consent](./consent.md): approval prompt reading, allow `a` and deny `d`, and pasted choices.
- [Status and navigation](./status-navigation.md): `/status`, `/details`, PgUp/PgDn, arrows, wheel, Ctrl-G and Esc.
- [Exit and terminal restoration](./exit-restore.md): `/exit`, Ctrl-C and SIGTERM restore termios and the screen.
- [tmux attached and detached](./tmux.md): the same journeys through a private tmux server, with or without a client.
- [Hardware input](./hardware-input.md): physical keys and wheel in a GUI terminal (L4, needs a human).
