# Cell arena verification

These PNGs compare main `62e124645e626ed3d538e97c2e9c0fb69789e0e0` with the cell-arena implementation `4f0a2268ad5164bb77efebf75287429f8af46d0a`.
They came from committed terminal frames, using the verify-rui skill's plain PTY and libghostty-vt observer at 120×40, then its HTML/Playwright PNG renderer.
The two clients shared one isolated fixture Store so Session identities and content matched.
Only the model provider was mocked.
The overview, conversation, and settings pairs are byte-identical PNGs; their decoded cells, styles, theme, visible cursor, and re-encoded painted ANSI also match exactly.
The hidden cursor's unused position is not a visible cell and is excluded from the painted comparison.
This is L1 synthetic PTY evidence, not physical keyboard or mouse coverage.

| State | Main PNG | Branch PNG | Shared PNG SHA-256 |
| --- | --- | --- | --- |
| Overview | [main](main-overview-120x40.png) | [branch](branch-overview-120x40.png) | `0602fce7713d6fca1520f46985dc226d9696cbe3e13969e1d04a9b4ecbb6d8f5` |
| Conversation | [main](main-conversation-120x40.png) | [branch](branch-conversation-120x40.png) | `155d5470919c67a5c3f2f4a6ba59c6e952ac0f590db3ddcf639f2306a78a1d7f` |
| Settings | [main](main-settings-120x40.png) | [branch](branch-settings-120x40.png) | `a56b17e52f3408eae20b3b5230f7641f4d370a1acbad42d1d23f9c2e51934db0` |

The full scripts, manifests, raw cells/ANSI/HTML, memory samples, and logs are saved under `/mnt/project-files/libvaxis-memory/pin-pr/`.
The accepted frame run was `/home/claude/.cache/verify-rui/runs/20261113T085116-62e1246-27114`; its scratch Store was archived and its owned processes cleaned up.
PNG rendering initially lacked `NODE_PATH`; the saved matching frames were rendered afterward with `/opt/node-tools/node_modules` and `/opt/pw-browsers`.
A later redundant capture attempt could not align the live age clocks and was not used; none of the accepted evidence was normalized or replaced by that attempt.

## Memory

Measured with Zig 0.17.1 ReleaseSafe, the deep dive's `tui_mem.py` and alternating `ab.sh` loops, three repetitions per variant/size/state in the same container, using smaps Private_Dirty after five seconds and `sync`.
The Store had the same 63 answered fixture turns as the deep dive; scrolled means 30 PageUp inputs via L2 tmux send-keys.
There were 24 samples and no harness errors.
Drawn row and character counts matched for every main/branch pair; asynchronous age labels can differ between sequential samples.
The memory run was `/home/claude/.cache/verify-rui/runs/20261113T084109-62e1246-9796` and was also cleaned up.

| Size | State | Main KiB median [min, max] | Branch KiB median [min, max] |
| --- | --- | --- | --- |
| 120×40 | Idle | 5,624 [5,624, 5,628] | 4,020 [4,012, 4,020] |
| 120×40 | Scrolled | 5,632 [5,632, 5,632] | 4,016 [4,016, 4,016] |
| 250×70 | Idle | 12,136 [12,136, 12,140] | 6,108 [6,108, 6,112] |
| 250×70 | Scrolled | 12,180 [12,180, 12,180] | 6,152 [6,152, 6,156] |

Main's binary SHA-256 was `d50dca9d274605cac1e017ca4f2e27ca5625414bf676320054219e6285542d10`.
The branch binary SHA-256 was `a7ad9baebb09365bcbd919bfb566111700401d2cc9dacb4bf6d7a3f5fa2d815e`.
This saves between-frame memory; peak frame-construction memory and CPU were not measured.
