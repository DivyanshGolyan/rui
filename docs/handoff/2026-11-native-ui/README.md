# Rui native UI: machine handoff

**STOPPED / UNQUALIFIED.** These branches preserve work for transfer; they are not a ready-to-merge stack or a claim that tests or admission are green. The user requested that implementation stop and work be published for another machine. No main merge, rebase, reset or force push is authorized by this handoff. Check current main, branch protection and repository landing instructions before resuming. Do not merge any partial slice merely because it has an archival ref.

## Starting points

All names below are under `handoff/2026-11-native-ui/`. Checkouts overlap and have different bases: reconcile deliberately, do not treat their tips as independent features or blindly combine them.

| Branch suffix | Exact commit | Meaning |
| --- | --- | --- |
| `ledger-wip` | `95eec6dcb0ab2bdb7944af8df459edd9e85fabb4` | Latest native migration plus incomplete, uncompiled request-ledger changes. |
| `native-core` | `e81d57aaf37d5f5c275725227653474cb579f560` | Clean native migration before ledger WIP. |
| `skills-local` | `62f8ac0d37f663f67c6da9ca5d53c5229249c873` | Unpublished #1062 child fix; preserve its history. |
| `model-picker` | `2d5800e2e9e1097be06ab54de3c2f35fd7ba92a9` | Isolated native picker and fixture work, not integrated into native core. |
| `core-9c` | `9c149b13e166aff3eda034dae82f1f8f010927d8` | Earlier combined core; its unfiltered logic run was red. |
| `queue-native` | `c16642c18c8a5ce9bd41ca31b63f224d88480100` | Earlier queue implementation checkpoint, not a finished native migration. |
| `queue-earlier` | `ffb3eb4f9ebfa04a03e058092f160ad9be43db69` | Related queue checkpoint. |
| `ceremony` | `61d75b11384a000c43b60b981bfca266566b772a` | Earlier command/archive deletion and focused custody test checkpoint. |
| `sent-history` | `515408105fa981b1dfb1e26fc48f901d68a20cbf` | Partial source/history work, not complete long-message reachability. |
| `approval` | `64542e82575a61401ee7974f0cfbeec0ad114d8c` | Earlier approval/capacity checkpoint, not integrated qualification. |
| `composer` | `f35d063c47509271b8f992512fe0737fb269f2a2` | Earlier composer-edge checkpoint; later product decision is plain text. |
| `ceremony-tests-wip` | `6b676a5f4754e4f25f04e9d820ca1ebeddfa1395` | Incomplete, unqualified integration-test migrations. |
| `continuation-regression-wip` | `0736462efd94590233c37585eab09bc1b3507504` | Unrun long-body regression, not a continuation implementation. |
| `queue-source-wip` | `6637585490277345ea0d9733d19c2a4357d050ae` | Partial staged queue source, not integrated UI. |

`checkpoints.tsv` maps preserved task worktree heads to exact `checkpoints/<full SHA>` refs. These include historical and experimental states; rows marked diagnostic mutants are **never for integration**. The archival refs are snapshots, not CI qualification or independent landing candidates. `patches/` preserves two external partial diffs; their corresponding commits and applicability must be checked before use.

## Product direction and outstanding work

Read `decisions/rui-ui-product-decisions.md` and `decisions/rui-vxfw-implementation-plan.md` first. The accepted direction is a high-level vxfw-owned native UI, one plain-text multiline composer with destination-specific drafts and cursors, normal scrollable feed, disk-first bounded working set, exact authenticated source access, deliberate Action confirmation, and the other agreed changes recorded there. These documents describe decisions and a plan, not shipped behavior. The two upstream libvaxis clones referenced by old notes were local-only; reconstruct the pinned upstream from `build.zig.zon` and apply the repository patch rather than assuming the clone or dependency cache transferred.

The durable submitted-intent unit was authorized in the existing private request ledger. At stop, only partial `src/client.zig` and new `src/NativeRequestLedger.zig` work existed. It has not been compiled or reviewed. The existing real failure showed a definitely-unsent compound original could be lost after fatal exit; honest shutdown messaging alone does not preserve it. Complete and independently review the typed record, atomic publication, explicit recovery, observed-Host authority, compound reason/decision continuation, v1/old-reader compatibility and crash boundaries before claiming custody. This is not ordinary draft autosave, and no user Store or protocol/schema rewrite was authorized.

Full sent-Message continuation and all-authoritative-pending queue remain unfinished: preserve source identity and authenticated content, bounded resident data, quote/fence provenance, safe long no-newline fragments, both reading directions, exact anchors and canonical/echo/stop paths. Do not treat a gap, truncated raw interval, fixed preview, or source-only helper as full conversation reachability. Native picker, Action integration, compact Activity, remaining commands and child skill composition still require coherent integration and relevant real-Host/terminal tests. Product decisions supersede obsolete UI sketches and old history/footer/quote-gutter assumptions.

## Evidence and caveats

No build, test, review or gate was rerun for this stop-and-publish handoff. Earlier results are tied to their exact pins. The earlier combined core `9c149b13` full logic run failed two overview panel tests. The later native migration has scoped positive Host/PTY results, but is not an accepted preview; an original 900-second test-runner timeout remains unexplained, and the fatal not-published submitted-original loss is unresolved. Do not use individually passing tests to relabel the original timeout or other runs green.

PR #1062's published head was `439fa104c6a00c7419e88482f785bde7cd26a573`; local `skills-local` includes the unpublished `62f8ac0d` legacy refusal-binding correction. A completed full canonical run at 62f was red at its TypeScript stage because local dependencies were missing; a later dependency-corrected TypeScript stage passed separately. This does not retroactively make that full run green. Recheck the current PR, child owner's coordination, comments, parent and actual remote rules before publication or qualification.

`context/` contains preserved contemporaneous coordination notes; their machine-specific `/tmp` and home-directory paths and intermediate ref status are historical, not paths available on the next machine. Raw runtime logs, screenshots, private Host/Store data, credentials, build caches, node_modules and the prior local preview executable were not uploaded. The user-visible `mock/` is a source-only fictional design preview, not a production build or acceptance evidence. Reproduce necessary evidence on the new machine with isolated, pinned clean source and owned fixtures. An untracked `zig-pkg` symlink in a disposable local build checkout was a dependency-cache link, not task source, and was not copied.

Before any further push, PR readiness or landing, independently verify exact current heads/base and run the repository-required checks on the actual combined candidate. Only whole-stack delivery is contemplated; this handoff authorizes no merge.
