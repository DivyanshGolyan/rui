# Consent

In ask mode, a proposed Bash command appears with its working directory. The user reads it and types `a` Enter to allow once or `d` Enter to deny. Pasted choices do not grant approval.

## Sub-features

- `consent-show`: the `Run Bash` prompt shows the full command, the working directory and the time limit beside the choices.
- `consent-read`: a long command needs PgDn to read fully before the choice is accepted.
- `consent-allow`: `a` Enter runs the command once and the answer follows.
- `consent-deny`: `d` Enter denies it, nothing runs, and the denial is shown at the Action.
- `consent-paste`: a pasted `a\r` is not approval.

## How to get to it (user POV)

- In Session `approve` (or after `/configure --permission-mode ask`), send a request whose model reply proposes Bash.

## Driving it with verify-rui

Preconditions:

- `doctor` PASS. Use a fresh terminal on `--session approve`.

- **Propose.** Run `$V term "$RUN" k1 --surface tmux-attached --session approve`, wait for the composer, then `$V send "$RUN" k1 --text 'consent check'` and `--keys Enter`. Run `$V wait "$RUN" k1 --marker 'Run Bash'`: the frame shows the command start and the working directory next to the prompt.
- **Read.** Run `$V send "$RUN" k1 --keys PgDn` repeatedly, `wait` after each, until the frame shows `wc -l progress.log`. Snapshot each page.
- **Allow.** Run `$V send "$RUN" k1 --text a` then `--keys Enter`, then `wait --marker 'Fixture tool summary'`. `project/progress.log` exists with 30 lines (`wc -l`), and `provider.jsonl` shows `tool-summary`.
- **Deny.** On a second proposal (`consent check` again), send `d` and Enter. `progress.log` is unchanged, the denial is shown at that Action, and the provider receives a tool result reporting denial.
- **Paste is not consent.** On a new proposal, send `--hex 1b5b3230307e610d1b5b3230317e`. No command runs and the prompt remains.
- **Proof.** Run `$V evidence "$RUN"`, plus `wc -l` of `progress.log` before and after, plus snapshots labelled per page.

## Gotchas

- The fixture proposes the same 32-line command for every `consent check`. `progress.log` grows by 30 lines per allowed run.
- The choice is accepted only once the command has been fully shown. Typing `a` early is a separate check, not an allow.
- Hardware a/d (physical keys) belongs to [hardware-input](./hardware-input.md). Here it is L1–L3.
