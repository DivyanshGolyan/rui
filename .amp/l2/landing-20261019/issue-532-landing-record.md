## L2 landed after reviewed exact-head qualification

This record is prepared for issue #532 because its integration dependencies include L2's ScratchBudget API. It does not close that issue, the remaining L2 capability seam or the architecture audit.

**Landed SHA:** [620c1ee48061aa9476e59342c7c67e77a2f3d757](https://github.com/DivyanshGolyan/rui/commit/620c1ee48061aa9476e59342c7c67e77a2f3d757). After Puck's explicit single-push release under Divyansh's standing approval, one non-force fast-forward push moved main from cdad to this exact candidate. `git ls-remote origin refs/heads/main` and a subsequent fetch independently verified actual remote main at 03:51:33Z on 2026-10-19. No merge or new commit was created.

- Approved candidate: [620c1ee48061aa9476e59342c7c67e77a2f3d757](https://github.com/DivyanshGolyan/rui/commit/620c1ee48061aa9476e59342c7c67e77a2f3d757), tree `134a51422aa53511cd93a4036989935e9a426fdc`.
- Independently fetched expected remote main: [cdad5aaf4dc43cbb7864f0fa0a4a08bf4f25a8ff](https://github.com/DivyanshGolyan/rui/commit/cdad5aaf4dc43cbb7864f0fa0a4a08bf4f25a8ff). Local main remains separate and unchanged. Rebasing the approved branch onto fetched main was a no-op; commit, tree, parents and reviewed delta are identical.
- Fresh required evidence: [Selected, attempt 2](https://github.com/DivyanshGolyan/rui/actions/runs/39174654494/attempts/2), 13/13 jobs successful, including hosted Linux and macOS; [both installed upgrades, attempt 2](https://github.com/DivyanshGolyan/rui/actions/runs/39174654493/attempts/2), 2/2 jobs successful. Both runs bind exact 620 and started at 03:20Z on 2026-10-19. No check failed during this requalification. No failed check may be retried into acceptance under this landing authorization.

Selected freshly executed all six required targets on each supported platform: `test-logic`, `admission-debug-integration`, `check`, `codex-h2-integration`, `evaluator-churn` and `transport-h2-integration`, all exit 0. Hosted policy passed 91 tests in 76.401s. Native units passed 640 with one skip on Linux and 638 with three skips on macOS. Both skip the opt-in 60-second witness; macOS also skips two Linux-only assertions. Linux artifact 12161382321 and macOS artifact 12161607393 were verified before execution. The logs contain no adoption of earlier same-tree acceptance; prior-attempt artifacts are excluded by the existing verifier.

Both installed-upgrade jobs exercised normal `~/.local/bin/rui` installation, startup at the default soft-256 descriptor limit, same-format saved work/configuration across reinstall and restart, and explicit schema21-to-24 refusal in detached and foreground modes with unchanged SQLite hashes. These are disposable hosted fixtures, not the user's live Store. No migration or backward-compatible reader was added.

Immediately before the push, fetched `origin/main` and the live remote ref both equaled exact cdad; the tracked worktree was clean and exact candidate/tree unchanged. Both attempt-2 success outcomes were rechecked. Afterward, fetched `origin/main` equals exact 620; separate local `main` remains unchanged at cdad. Full logs and snapshots are retained under `.amp/l2/landing-20261019/`.

The completed outcome adds a production-only import-cycle guard, moves bounded values below protocol and named scratch, and separates accounting-only `charge`/`chargeUpTo` from reclaim-capable `allocate`/`allocateUpTo`. All eight producers retain automatic reclamation. Old ScratchBudget reservation names fail compilation; no compatibility aliases remain. The unused queue growth pair is removed. Endpoint and CLI proposals are design-only; defaults, wire and Store format are unchanged.

The measured graph is **55 production modules and three cyclic components at base; 56 modules and two components at this candidate**. The removed component is protocol/named_scratch. Store/provider_output remains another lane's work; capability/selection requires the renderer-owned CLI seam. The guard excludes test-only imports, handles the root alias and nested test scopes, and prevents candidate allowance growth against trusted Git history. The independently sliced guard passes all 91 policy tests on the exact base.

Review scopes remain separate:

- [Sol adversarial PASS](https://ampcode.com/threads/T-01a15057-e51f-7625-9a34-66fd9b8c56b2) applies to historical ad16, not later runtime qualification or cross-family clearance.
- [Initial Opus review](https://ampcode.com/threads/T-01a15113-ed53-74f1-9e79-50abfa6dc313) conditionally passed ad16's production change and found two medium enforcement/test gaps and a low unused-interface issue.
- [Cloud Opus 5.5 correction PASS](https://ampcode.com/threads/T-01a1513f-4900-7238-a30c-1257ede7ab79) closes those findings on exact 620. It independently ran import tests, trust mutations, API probes and Linux native units. It did not run the owner's hosted macOS, integrations or installed upgrades. The candidate SHA and tree are unchanged from that review.

Known limits remain explicit. The separate pre-existing `core_boundary.zig` nested-test diagnostic scanner rejects an allowed diagnostic after an inner test closes; its native public-interface probe accepts the ordinary case and rejects the nested case. That owner was not changed, and there is no repository-wide scanner-closure claim. A future first-party named build import requires a checker update; the checker itself remains review-controlled. The reviewer observed a zero-exit `failed command` message, then confirmed direct-test and build-summary success; its reporting-path cause remains unestablished. No live provider, physical Mac, OS-crash, power-loss or complete release/resource qualification is claimed.

The owner-approved caller handoffs do not adopt or qualify the other lanes' redesigns. Renderer files remain untouched. No L5 work is included.

[Morning packet with checkpoint provenance and limitations](https://t-03h2noghnmrjiyn3rj97faubq-p26315.onamp.dev/l2-morning-packet.html).
