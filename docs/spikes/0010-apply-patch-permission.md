# Durable one-file patch permission

> Historical evidence. The exact patch-permission boundary remains relevant, but ADR-0009 replaces
> the persistence mechanics and issue #9 owns the current Patch Intent and reconciliation slice.

Issue #8 stops before mutation. The host accepts exact unified-diff bytes from the model, validates
one tracked regular file, captures its opened preimage, and binds any permission decision to that
immutable subject. Issue #9 owns the controlled mutation and reconciliation path.

## Validation boundary

`patch_tool.zig` rejects malformed, binary, oversized, multi-file, traversal, absolute, mode-changing,
rename, copy, special-file, and symlink-shaped inputs before permission or Attempt creation. It opens
each path component through no-follow directory handles, rejects multiply linked files, hashes the
opened file, requires the path to be tracked, and passes the exact patch bytes to a fixed `git apply --check`
invocation through standard input. The model cannot supply the Git command or its arguments.

The validation result contains the exact target path, patch digest, preimage digest and size, inode,
and a workspace digest derived from those values. Validation never invokes `git apply` without
`--check`, so every acceptance and rejection test keeps the target bytes unchanged.

## Permission evidence

The patch bytes live in a bounded durable blob. A fixed-size binding records:

- the patch Operation identity and generation;
- the ownership epoch that displayed or decided the call;
- the patch blob reference and descriptor digest;
- the target preimage digest, size, and inode;
- the workspace digest; and
- the `allow`, `ask`, or `deny` classification.

An `ask` classification publishes an `approval_required` journal fact before reading input. A crash
while input is pending therefore regenerates `PatchApprovalRequired` from the journal after the model
completion is restored; a transient prompt is never the authority. The terminal UI shows the exact
patch plus the bound Operation, generation, descriptor digest, and workspace digest. It renders
control, non-ASCII, and backslash bytes through an unambiguous escaped form, so model-selected bytes
cannot emit terminal control sequences or spoof the approval prompt.

The final decision gets its own immutable binding and `permission_decided` fact. A denial produces a
typed `denied` Result. If the worktree changes between display and approval, revalidation produces a
typed `stale` Result. Both Results become Conversation Entries before a second model request. An
allowed and still-current patch remains durable but unexecuted as `PatchExecutionDeferred` for #9.

## Proof

The ReleaseSafe suite covers every structural rejection class, target and parent symlinks, exact
preimage capture, denial, an approval made stale by an external write, an allowed patch that performs
no mutation, and two fresh resumes of a durable approval-required projection. The deterministic demo
is:

```sh
zig build fixture-patch-deny -Doptimize=ReleaseSmall
```
