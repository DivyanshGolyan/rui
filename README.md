# L5 landing evidence preservation

This evidence-only orphan branch preserves L5's landing at [e59ac70902ac05ce7ae9ab082e2ca46d83fc18e6](https://github.com/DivyanshGolyan/rui/commit/e59ac70902ac05ce7ae9ab082e2ca46d83fc18e6), tree `702c162bab2c04932e7b983875020e0009ca9d1c`, after L2 base [620c1ee48061aa9476e59342c7c67e77a2f3d757](https://github.com/DivyanshGolyan/rui/commit/620c1ee48061aa9476e59342c7c67e77a2f3d757). It contains evidence and this reference only. It has no source checkout or workflows and does not change main.

## Verify and read the archive

From the downloaded branch root, run:

```sh
sha256sum -c .amp/l5/SHA256SUMS
tar -tzf .amp/l5/l5-landing-evidence-20261019.tar.gz
```

On macOS, use `shasum -a 256 -c .amp/l5/SHA256SUMS`. Extract the archive into a separate directory to read its `l5/` tree.

The archive is the original 562,460-byte preservation upload, unchanged. Its SHA-256 is `9fd237389992e8ca5d5a37cd01340ca9bf229b8b5c6b97b52cc45d089cf5162f`. This Git branch replaces reliance on the temporary Amp download URL.

The archive retains 55 text files and three directory entries. It includes original failed and mutation attempts, the pinned pstack source files, historical local and hosted logs, fresh post-L2 qualification logs, patch/range-diff equivalence, pre-push checks, push output, three independent remote observations and the exact published landing-record readback. The Python environment and build products are not included. Evidence remains as captured, including the initial `jq -r` readback's extra newline. The exact JSON-body comparison succeeded with `jq -j`.

## Acceptance and limits remain separate

Fresh [Selected run 39197130026, attempt 1](https://github.com/DivyanshGolyan/rui/actions/runs/39197130026) passed all 13 jobs. [Installed-release run 39197130021, attempt 1](https://github.com/DivyanshGolyan/rui/actions/runs/39197130021) passed on Ubuntu and hosted macOS. Both bind exact landed head. Earlier evidence does not replace these outcomes.

Sol and cloud Opus reviews cover original approved [1cb0a53b806c716f5da9e7ee220d54679e6e1667](https://github.com/DivyanshGolyan/rui/commit/1cb0a53b806c716f5da9e7ee220d54679e6e1667). The equivalent rebase and fresh assembled-head checks are separate evidence, not new reviews. The accepted raw argv-read test gap, original digest discrepancy, reviewer transport build's unknown-cause fail-then-pass, mutation-count discrepancy, skipped assertions and optional/unrun checks remain recorded. Import-safe conversion covers only the Session-list suite/proof pair, not the excluded control/model-fixture chains. No broader architecture or release qualification is claimed.

The [landing record on #532](https://github.com/DivyanshGolyan/rui/issues/532#issuecomment-6259668631) remains authoritative for the single non-force fast-forward, scope, review limits and exact gates. Issue #532 remains open. This evidence publication is not another code or main-branch change.

## The orb is not a downstream requirement

The renderer owner explicitly confirmed that it needs nothing from the L5 orb. Shared implementation is already on main; this branch preserves the logs and transfer files independently of the orb. No L5 build, test, Host, watcher or server remains active locally. Automatic post-main upgrade CI runs on standard GitHub-hosted Ubuntu/macOS workers and needs no live local process. A pending hosted run is not a failure and is not retried here.

Archival preserves `/tmp/rui-complect-l5`, the evidence repository and original artifacts. It does not remove a worktree, delete evidence, close #532, restart qualification or qualify the renderer's rebased binary.
