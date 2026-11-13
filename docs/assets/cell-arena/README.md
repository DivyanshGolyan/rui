# Cell arena verification

These PNGs compare main `62e124645e626ed3d538e97c2e9c0fb69789e0e0` with the cell-arena implementation `4f0a2268ad5164bb77efebf75287429f8af46d0a`.
They came from committed terminal frames, using the verify-rui skill's plain PTY and libghostty-vt observer at 120×40, then its HTML/Playwright PNG renderer.
The two clients shared one isolated fixture Store so Session identities and content matched.
Only the model provider was mocked.
The overview, conversation, and settings pairs are pixel-identical PNGs; their decoded cells, styles, theme, visible cursor, and re-encoded painted ANSI also match exactly.
The hidden cursor's unused position is not a visible cell and is excluded from the painted comparison.
PNG provenance (`caBX`) chunks are signed independently by the environment, so whole-file hashes differ even though every decoded RGBA pixel matches.
The hashes below deliberately cover decoded RGBA bytes, not provenance metadata.
This is L1 synthetic PTY evidence, not physical keyboard or mouse coverage.

| State | Main PNG | Branch PNG | Shared decoded RGBA SHA-256 |
| --- | --- | --- | --- |
| Overview | [main](main-overview-120x40.png) | [branch](branch-overview-120x40.png) | `73288fd528dd5651a21b4e9d540e6dcef0cc739412b4312de11efdf32940ca84` |
| Conversation | [main](main-conversation-120x40.png) | [branch](branch-conversation-120x40.png) | `a6e553f7a74192e917a30e0cbb2abe30df74e746dba8768f7b6b4f5ae7b0c6d9` |
| Settings | [main](main-settings-120x40.png) | [branch](branch-settings-120x40.png) | `410ae0f1006b8c6dc8337aee9e825222c50ba83f35a760efc0d1cdac07f31a83` |

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

## Earlier ground-strip merge follow-up (historical)

Main `271491cb7987ccc35bb7156c7cff240a883c9fdb` was merged, without rebasing, in branch merge commit `89451d4161f34c61e2c2bbab93172fbe50e4178f`.
Both builds now retain #1403's uncovered-ground-strip design and #1409's covered-pane test correction.
The comparison below supersedes the old memory table for current-main claims; the PNGs above remain explicitly historical evidence, not new post-merge captures.

The quick rerun used the same ReleaseSafe Zig 0.17.1 build, 63 answered fixture turns, alternating main/branch process launches, five-second settling, `sync`, and smaps Private_Dirty.
There were three repetitions at each size, idle only: 12 samples, zero harness errors, and matching drawn row/character counts for every corresponding pair.
No samples were excluded, including the higher first main sample at 120×40.

| Size | Current main KiB median [min, max] | Merged branch KiB median [min, max] | Saved KiB |
| --- | --- | --- | --- |
| 120×40 idle | 5,044 [5,040, 5,212] | 3,872 [3,872, 3,872] | 1,172 (23.2%) |
| 250×70 idle | 10,032 [10,032, 10,036] | 5,968 [5,964, 5,972] | 4,064 (40.5%) |

Current-main binary SHA-256 is `9d5a8589592213e8f8045cdebb1bc9d2d10410a194eac2eefe1a8cb065abdc47`.
Merged-branch binary SHA-256 is `f1f62b13eb18a87bdadae84675004e8d983d6dfdb86e73d7768e00e80cbdd7c0`.
Evidence and scripts are under `/mnt/project-files/libvaxis-memory/pin-pr/merge-followup/`.
The owned memory run was cleaned up and its Store archived.

`zig build -j1` passed.
`zig build test -j1 -Dtest-filter=AppScreen -Dtest-filter=SessionFrontend -Dtest-filter='Stack keeps every composed cell' --summary all` passed all 184 tests.
The new strip allocator test failed when Ground.strip was deliberately put back on the general arena; that mutation was restored.
`python3 tests/ci/prepush.py` passed all 83 development steps (3,664 tests passed, 3 skipped) and all 55 macOS type-check steps under the isolated ordinary test account.
Scrolled memory, fresh post-merge screenshots, peak memory, CPU, physical input, and macOS runtime behavior were not rerun in this follow-up.

## Current-main Root/sign-in merge follow-up

Merged main `c5cfe9276381d5838a03ad1ac97616c0e0268be6` in merge commit `08e2751354cfce0df950918aab01c01b5d6259ec`, without rebasing.
Root retains main's browser-sign-in setup and callback state; its new test DrawContext and SignIn's new test DrawContext supply cell_arena.
All 38 surface-buffer allocation sites use cell allocators; metadata stays on the general arena.
Main also changed SignIn.draw, so the idle A/B was rerun rather than reusing old memory results.

Both pinned builds used Zig 0.17.1 ReleaseSafe through zb, with the external launcher enforcing -j1.
The same deep-dive harness alternated main and branch, three repetitions per size, with the same 63 answered fixture turns and five-second settling plus sync before reading smaps Private_Dirty.
All 12 samples completed without errors; drawn row/character counts match for each pair, and no samples were excluded.
This table supersedes earlier tables for current-main claims; the PNG pairs above remain historical, not fresh post-merge captures.

| Size | Main c5cfe927 KiB median [min, max] | Branch 08e27513 KiB median [min, max] | Saved KiB |
| --- | --- | --- | --- |
| 120×40 idle | 5,044 [5,044, 5,048] | 3,876 [3,876, 3,880] | 1,168 (23.2%) |
| 250×70 idle | 10,040 [10,040, 10,044] | 5,976 [5,976, 5,980] | 4,064 (40.5%) |

Main binary SHA-256: `551fb8d89a8764e3fa814e4f77d1deb3743adb6b701200923c07184edee850b3`.
Branch binary SHA-256: `34def74bc68657eff5a535ca0b467f5fe8e5a2de6fb5623b4fe0dbf836d81265`.
Full evidence is under `/mnt/project-files/libvaxis-memory/pin-pr/root-merge-followup/`.
The run `/home/rui-cell/.cache/verify-rui/runs/20261113T121347-c5cfe92-11926` passed doctor and was cleaned up with its Store archived.

`zb zig build -j1` passed under the ordinary rui-cell account with Python 3.12.
`zb zig build test -j1 -Dtest-filter=Root -Dtest-filter=SignIn -Dtest-filter=sign_in -Dtest-filter=app_settings -Dtest-filter=model_choice -Dtest-filter=model_picker -Dtest-filter=provider_name -Dtest-filter=Overview -Dtest-filter=SessionFrontend -Dtest-filter=AppScreen -Dtest-filter='Stack keeps every composed cell' --summary all` passed 46/46 steps and 395/395 tests, including both allocator regressions.
`zb python3 tests/ci/prepush.py` passed 690 policy tests (7 skipped), 42 installer cases, 83/83 development steps (3,673 tests passed / 3 skipped), and 55/55 macOS type-check steps.
TypeScript wire.ts regeneration was skipped because clients/ts/node_modules is absent; no wire change is authored here.
As before, fresh screenshots, scrolled memory, peak memory, CPU, physical input, and macOS runtime behavior were not rerun.
