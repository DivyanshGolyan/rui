# tmux attached and detached

The same Rui journeys inside tmux. Detached means no client is attached (tmux sizes the window manually). Attached means one owned client on its own PTY, whose output is recorded as terminal `NAME.client`.

## Sub-features

- `tmux-detached`: Rui in a pane with no client; input by `send-keys`.
- `tmux-attached`: one owned client attached; input by `send-keys` (L2) or by typing into the client PTY (`--via client`, L3).
- `tmux-view`: tmux's own `capture-pane` matches Rui's committed frame.
- `tmux-status`: `/status` renders fully in an attached pane.

## How to get to it (user POV)

- Run `rui` inside a tmux session, or attach to one later.

## Driving it with verify-rui

Preconditions:

- `doctor` PASS. The private socket is `"$(jq -r .scratch "$RUN/run.json")/tmux.sock"`; `doctor` checks it once a tmux terminal exists.

- **Attached journey.** Run `$V journey "$RUN" a1 --surface tmux-attached`. It prints PASS, and `terms/a1.client/term.json` lists the client tty.
- **Client-typed input.** Run `$V send "$RUN" a2 --text '/status' --via client` and `--keys Enter --via client`. `injections.jsonl` shows `via: client`, and `terms/a2/input.jsonl` shows the bytes tmux forwarded.
- **Compare views.** Run `$V screen "$RUN" a2 --label status`. Diff `shots/status.committed.txt` (Rui's frame) against `shots/status.tmux.txt` (tmux's cells) and against `terms/a2.client/display.txt` (what the attached terminal shows).
- **Control.** Repeat with `--no-tap` to rule out the tap. That run records no `input.jsonl`, so rely on frames from `capture-pane`.

## Gotchas

- `window-size` is `manual` for detached runs and `latest` for attached runs. A late attach resizes the pane (SIGWINCH), and that is part of the attached journey.
- `remain-on-exit` is on, so dead panes stay inspectable until `cleanup`.
- Never use the default tmux server. Every tmux call goes through `-S` with the private socket.
