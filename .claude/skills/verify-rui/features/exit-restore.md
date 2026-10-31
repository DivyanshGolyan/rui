# Exit and terminal restoration

`/exit`, Ctrl-C and SIGTERM close the client without stopping Host work. They restore the user's terminal (termios, main screen, cursor, mouse and paste modes) and print the resume command.

## Sub-features

- `exit-command`: `/exit` Enter exits 0.
- `exit-ctrl-c`: Ctrl-C (byte 0x03 in raw mode) exits 0 and discards the unsent draft.
- `exit-sigterm`: SIGTERM to Rui exits and restores the terminal.
- `exit-restore`: `stty -g` before equals after (PENDIN/FLUSHO masked), the alternate screen is left, and `Detached. Host work continues.` and `Resume: …` are on the main screen.

## How to get to it (user POV)

- Type `/exit`, press Ctrl-C, or have the terminal close or a signal arrive.

## Driving it with verify-rui

Preconditions:

- A terminal at the composer.

- **/exit.** Run `$V send "$RUN" e1 --text /exit`, then `--keys Enter`. `exit.json` shows `target_rc "0"`, `termios_restored true` and `alternate_screen_active_at_exit false`. `main_screen_plain_tail` contains `Resume: rui session resume --store`.
- **Ctrl-C with draft.** Type `unsent`, then `--keys C-c`. Same `exit.json` facts, and the provider count is unchanged.
- **SIGTERM.** Run `$V signal "$RUN" e3 TERM` with a draft present. Same facts. `injections.jsonl` records the PID and signal.
- **tmux pane state.** For tmux surfaces, run `$V screen "$RUN" e1 --label after-exit`. `tmux-flags.txt` shows `alternate_on=0 mouse_any_flag=0` and `pane_dead=1`, because `remain-on-exit` is on.
- **Proof.** `exit.json`, `output.bin` tail (`output_tail_hex`), snapshots.

## Gotchas

- The inner tty is revoked once the session leader exits on macOS. The wrapper shell takes `stty -g` before and after on the same tty, and the tap cannot read termios after exit.
- SIGKILL and native crashes cannot restore. Rui does not promise that.
