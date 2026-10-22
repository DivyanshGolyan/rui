# Real tmux captures: peer and fold lines without byte sizes

Binary: `zig build --prefix /tmp/rui-demo-install` from the land commit's tree.
`demo-host.py` starts a real Host with a stub model, configures `demo/main` and
`reviewer`, and sends ordinary, folded and peer Messages through `rui session send`
(peer senders via `RUI_ADDRESS`). The TUI is the real
`rui session resume --store STORE -- demo/main`, run in a tmux pane; each file
is `tmux capture-pane -p` (`-e` for `*-ansi.txt`) of that pane.

| File | State |
| --- | --- |
| 01-live-80x24 | Opening at 80×24: inbound/outbound peer lines, `…` only when more follows, time at the right margin |
| 02-ctrl-o-outbound | Ctrl-O on `→ reviewer · Plan follows…` (no raw export: no conversation row) |
| 03-returned | Ctrl-O again: identical to 01 |
| 04/06 | Transcript at 80×24: fold row `┄ 4 more lines` with no size |
| 05-ctrl-o-inbound-long | Ctrl-O on the 200-byte-clipped single line |
| 07-80x12-top / 08 / 09 | Fold row lowest in view; Ctrl-O opens the folded user Message; back to identical rows |
| 10 / 11 | `← reviewer · Please review the patch…` lowest; Ctrl-O opens it with raw export |
| 12-60x24 / 12-59x24 | From 60 columns the time keeps the margin; at 59 no margin and long lines clip with `…` |
| 13 | 80×24 with the orb's NO_COLOR=1 |
| 14 | 80×24 with NO_COLOR unset, TERM=tmux-256color: lines and time dim (`ESC[2m`) |

## Real terminal screenshots (foot 1.x on headless sway, NO_COLOR unset)

`foot/` holds `grim` screenshots of the foot window running the same TUI, and
`ctrl-o.mp4` (`wf-recorder`, ~4.5 s): live view → Ctrl-O (`wtype`) on
`→ reviewer · Plan follows…` → Ctrl-O back. `80x24-returned.png` is
byte-identical to `80x24-live.png`. 60x24 keeps the time margin; 59x24 has none.
