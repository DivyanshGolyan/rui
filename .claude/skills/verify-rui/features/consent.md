# Consent

In ask mode, a proposed Bash command appears with its working directory.
Read the whole Action, use Left/Right to select Allow once/Deny, then press a fresh Enter after the selected choice has been shown.
There are no letter shortcuts: typing or pasting moves to the message/reason draft, not a choice.
Marked paste grants no approval authority.

## Sub-features

- `consent-show`: the Action disclosure shows the command, working directory and time limit; a long command initially shows `PgDn reads the rest`, not an enabled choice.
- `consent-read`: PgDn through the whole command before the Allow once/Deny selector becomes available.
- `consent-allow`: Left selects Allow once; a separate fresh Enter at the shown choice runs the command once.
- `consent-deny`: Right selects Deny; a separate fresh Enter denies it, nothing runs, and the denial is shown at the Action.
- `consent-paste`: pasted Enter or encoded arrow/Enter input cannot select or confirm an approval.

## How to get to it (user POV)

- In Session `approve` (or after `/configure --permission-mode ask`), send a request whose model reply proposes Bash.

## Driving it with verify-rui

Preconditions:

- `doctor` PASS; use an empty draft in a fresh terminal on `--session approve`.
- `GEN` below means the generation immediately before each action; record every returned generation and snapshot each changed state.
- The helper has no `--keys Left` or `--keys Right`: use `--hex 1b5b44` for Left and `--hex 1b5b43` for Right.
  Send Enter separately, only after the selected choice is shown; do not concatenate arrow and Enter into one burst.

- **Propose.** Run `$V term "$RUN" k1 --surface tmux-detached --session approve`, then wait for the composer.
  Send `$V send "$RUN" k1 --text 'consent check'`, wait for that draft, then send `--keys Enter`.
  Run `$V wait "$RUN" k1 --marker 'PgDn reads the rest' --after GEN` and snapshot the disclosure, including `? Record thirty progress steps` and the command start.
  Do not wait for `Run Bash` before reading: that is not the initial long-command disclosure.
- **Read.** Send `$V send "$RUN" k1 --keys PgDn` one page at a time, wait for a new committed frame (`--marker 'progress.log' --after GEN`), and snapshot each page.
  Continue until the delivered pages include `wc -l progress.log` and the current frame shows Allow once/Deny with `←→ choose · enter confirms`, not `PgDn reads the rest`.
  Reading, resize or choice movement retires the old offer; wait for the resulting prompt before the next decision key.
- **Deny.** Send `$V send "$RUN" k1 --hex 1b5b43`, then `$V wait "$RUN" k1 --marker '› Deny' --after GEN` and snapshot the selected Deny.
  Only then send `--keys Enter`; wait for a new frame with `Denied`.
  Verify `progress.log` remains absent (or unchanged if already present) and the provider's tool result is exactly `Permission denied.`.
- **Allow (manual case; not covered by the cited native denial run).** On a new, fully read proposal, first select Right and wait for a new `› Deny` frame as above.
  Then send Left (`--hex 1b5b44`) and wait for a newer frame showing `› Allow once` before sending a separate `--keys Enter`.
  Snapshot the selected choice before Enter, then wait for `Fixture tool summary`.
  Verify `project/progress.log` gains exactly 30 lines and the provider receives the command result.
- **Paste provenance (manual case; not executed in the cited native run).** On a separate fully read, ready proposal for each payload, inject bracketed paste containing encoded Enter with `--hex 1b5b3230307e1b5b3133751b5b3230317e`, or Right plus Enter with `--hex 1b5b3230307e1b5b430d1b5b3230317e`.
  These are `ESC[200~ ESC[13u ESC[201~` and `ESC[200~ ESC[C CR ESC[201~`, respectively; there is no typed Enter outside the paste.
  Check received bytes/provenance, pending Action and selected decision, unchanged `progress.log`, and absence of a permission-decision capture or provider tool continuation.
  Snapshot the actual resulting draft/notice; do not assume the selector remains visible after paste.
  A pasted `a` is not an approval-hotkey counterexample because typed `a` is not an approval hotkey either.
- **Proof and disposal.** Run `$V evidence "$RUN"`; retain per-page/choice snapshots, input bytes, exact decision capture/inspect and provider tool result, plus `progress.log` state before and after.
  Always run `$V cleanup "$RUN"`, including on the first error.

## Gotchas and authority

- The fixture proposes the same 32-line command for every `consent check`; `progress.log` grows by 30 lines per allowed run.
- Typing `a` or `d` enters the retained draft; Enter on a single choice letter warns `Use ←→ and Enter to choose; a message denies the call.` and decides nothing.
  A real message can deny the call and send a reason under its own fresh-frame rule.
  Clearing the text alone does not return to the selector: press Esc and wait for the choice before using arrows.
- Source authority is `src/session_consent.zig` (projection and letter refusal), `src/SessionScreen.zig` (delivered-frame offer/read gate), and `src/SessionFrontend.zig`/`src/TerminalEditor.zig` (arrow/Enter selection and paste provenance).
  The frontend tests `arrows move the choice only once input is fresh, and Enter decides the option shown` and `choice readiness: keys pumped by a redraw of the same choice act on the choice shown, and the Enter after a move waits for a frame showing it` describe freshness.
  `src/terminal_input_equivalence_test.zig` tests encoded controls inside marked paste; this is source/test inspection, not a claim that those tests or native paste cases ran for this documentation change.
- Existing native denial proof: `/Users/divyanshgolyan/.cache/verify-rui/runs/20261106T185401-e5362f2-27194/evidence/FINAL-ACCEPTANCE.md`, exact head `e5362f2e9e66950bc8393a86f583819f2f30f22b`.
  Use `terms/consent/shots/12-explicit-deny-selected` and `13-explicit-denial-completed`, plus `terms/mono-consent/shots/05-mono-denied` and provider requests 8/10.
  Earlier shots labelled `09-deny-selected`/`10-denial-completed` are not denial proof.
  Right/Enter denial and read gate were exercised twice at L2, including NO_COLOR; Left/Allow is source-verified only, and paste and L4 remain manual/unexecuted cases here.
- Physical arrows/Enter belong to [hardware-input](./hardware-input.md); helper injections here are L1–L3, never L4.
