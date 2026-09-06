# Throwaway Patch scratch probe

Question: can helper-written scratch use upfront reservation and ordinary cleanup with small bookkeeping, including Host death while Git survives?

Run: `python3 research/patch-scratch-probe/probe.py` on macOS with `/usr/bin/git` and `/opt/homebrew/bin/git`. The script creates and removes private temporary fixtures. `results.json` is the final run. No OnePage production code is involved.

## Verdict

The candidate is feasible on the two installed Git builds. Close the snapshot's old file handle after hashing and saving its metadata, before Git runs. Reserve the helper's allowed output bytes once against the existing scratch total; keep the reservation until helper exit, safe handle closure and successful directory cleanup. One scratch-area lock inherited by helpers prevents restart cleanup from racing a surviving Git process. This remains a proposed mechanism pending integrated validation and acceptance, not release certification.

### Accounting and actual overlap

For the tested single-file text fixtures, let S be source bytes and P patch bytes. A candidate output bound is M=S+P, using checked arithmetic. Set child-only RLIMIT_FSIZE=M and disable core dumps. Reserve M before making the snapshot; this is accounting, not preallocated disk or RAM. The patch input's own retained scratch is separately charged. Other output containers and helper descriptors are separately owned.

The existing code keeps the preimage handle open through Git and only needs saved metadata afterward. Real Git unlinks that old inode and writes a replacement. In the many-line fixture, retaining the old handle kept 2,000,012 logical bytes alive after Git; closing it before Git left 1,000,008 bytes. The candidate reservation fell from 2,000,083 to 1,000,079 bytes. This is a simple unnecessary-lifetime fix, not allocator tuning.

Both Git builds passed replacement, growth, shrinkage, a large-line fixture, a roughly 1 MiB / 500,000-line fixture, and the retained-handle comparison. Exact output bytes matched. A deliberately too-small 32-byte child file limit stopped Git with SIGXFSZ and left only a partial scratch file; cleanup removed it. No semantic success is published by this harness.

The large-line fixture produces a roughly 1 MiB patch and deliberately exceeds historical source's 16 KiB patch constant; it explores the mechanism and does not certify that input as supported. The many-line fixture's patch is 75 bytes and source is 1,000,004 bytes.

### Crash and cleanup

One stable `scratch.lock` inode is opened and exclusively flocked by a stand-in Host. Git inherits that same open file description explicitly; unrelated child descriptors remain closed. After observing actual Git exec via ps, kill the Host while Git waits for input. On both installed builds:

- another open of the lock could not acquire it while the orphan Git remained alive;
- Git could still finish the patch after Host death, proving why early cleanup is unsafe;
- after Git exit, or after explicitly killing that helper, restart acquired the lock and removed the stale job;
- an injected real ENOTEMPTY removal failure retained the harness's reservation and occupied slot; successful removal then released them.

The cleanup counter check is a small policy harness, not fault injection through the production Host. Crash timing tested the before-write boundary with a real surviving helper, not every instruction during a write. The final run includes four crash cases across two builds.

Production must keep this lock inode stable, acquire it before scratch cleanup/admission, and close rather than explicitly LOCK_UN a shared description while helpers survive. This is a scratch-lifetime lock, not inheritance of semantic Store access. Failure to acquire rejects startup; it must not delete a live helper's tree or silently claim a fresh empty quota. No background cleanup service, directory scan per write, per-file database record or per-operation lock is needed. Restart may stream cleanup of the owned scratch area once exclusive ownership is established; failed cleanup prevents starting a fresh population.

### Memory and simplicity

The reservation needs one u64 per active Patch (8,000 bytes of value fields for 1,000), using the existing shared limit/used pair (16 bytes). These are field counts, not an actual Host structure-size measurement; alignment, existing custody and descriptor state remain additional. The scratch lock costs one persistent file per Host and one inherited descriptor in each active Git helper. No payload-sized buffer or persistent worker is added for accounting.

`/usr/bin/time -l` measured each real Git invocation, not the Python fixture generator. Final-run many-line peak physical footprint was 12,026,752 bytes on Apple Git 2.39.5 and 13,222,784 bytes on Git 2.55.0 (about 11.5 / 12.6 MiB). RSS was recorded separately. Git builds line metadata and materializes content; disk accounting does not remove that intrinsic helper cost. One observation per case is neither a stable performance estimate nor concurrent whole-Host qualification. Do not multiply it into a certified 1,000-helper budget or claim the 256 MiB total has passed.

## Boundaries still requiring integration proof

- RLIMIT_FSIZE bounds each file, not directory aggregate. The file-count proof relies on the admitted one-file regular text modification and selected Git flags/build, with no binary/create/delete/copy/rename/reject/index paths or other writers. Do not generalize this reservation to arbitrary Git invocations.
- M=S+P is justified for ordinary untransformed text additions, not arbitrary Git attributes, encodings or filters. Production must validate the closed invocation/environment and derive its supported maximum, or explicitly reject unsupported transformations; post-write measurement alone is insufficient. Core dumps and helper diagnostics must not create uncharged files.
- Samples measure retained inode overlap after Git; they do not sample every transient filesystem operation. The per-file kernel guard plus selected source/file-count analysis supply the intended bound. Ordinary input preparation still uses the existing growth accounting or this same reservation, without double charging the reserved region.
- Keep named directories bounded by live custody, retain charges on failed cleanup, and do not replenish after a crash before owned leftovers are safely removed. Reduced-cap restart and actual Host lock/descriptor construction remain integration cases.
- Git helper memory counts as OnePage overhead. The 1,000-operation mixed-workload target remains unqualified. This probe adds no executor concurrency default or memory controller.

## Source rationale

[Git v2.39.5 apply.c](https://github.com/git/git/blob/v2.39.5/apply.c): `write_out_one_result` removes then recreates modifications; `try_create_file` writes the result and can perform working-tree conversion; `create_one_file` has replacement-name paths. Apple Git carries vendor changes, so upstream reading is rationale rather than an exact Apple source identity. Actual behavior was tested on Apple Git 2.39.5 (Apple Git-154) and Homebrew Git 2.55.0. The production `src/patch_tool.zig` used for comparison was main d76c735, prepareSnapshot lines 410–457.

The first successful pass retained the old handle deliberately. A second pass added actual Git memory measurement; the final pass compared closing it early. Historical exploratory output was not used to claim statistical precision. Final reproducible cases and results are captured together here.
