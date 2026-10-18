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

- A human is at the Mac.
- `doctor` shows the Accessibility state (informational). Do not change system permissions.
- A tmux terminal exists: `$V term "$RUN" h1 --surface tmux-detached --session approve`.

- **Open window.** Run `$V gui "$RUN" h1 --open`. Terminal.app opens attached to `h1`. `injections.jsonl` records `via: gui-open`.
- **Human types the checklist** `gui` printed. After each item the agent runs `$V screen "$RUN" h1 --label hw-NN`.
- **Bytes received.** `terms/h1/input.jsonl` holds exactly what the physical terminal sent. Classify each chunk: key, mouse report (`ESC[<…M` or X10 `ESC[M…`), focus report (`ESC[I`/`ESC[O`) or terminal reply.
- **Proof.** Snapshots, `input.jsonl` and the human's statement of what they pressed, with times.

## Gotchas

- Without a human this feature is BLOCKED. Synthetic CGEvent keystrokes need Accessibility. Even with it, they are L3.5 synthetic and not physical.
- Input capture covers only this owned tmux window. Never record other windows or the user's own typing elsewhere.
- A click that activates a mouse-tracking window can send a mouse report. Check `input.jsonl` for `ESC[M` before blaming the editor for a stray prefix.
