# Atomic checkpoint publication

## Question

Can a process terminate at every checkpoint publication barrier without making the durable agent unrecoverable or causing a completed operation to append twice?

## Protocol

`checkpoint_store.publish` owns the complete publication order:

1. encode the canonical checkpoint into the caller's exact-size buffer;
2. create or truncate a same-directory temporary file;
3. write the complete encoded checkpoint;
4. sync the temporary file;
5. close it;
6. atomically rename it over the final checkpoint;
7. sync the parent directory.

The API accepts an already-open parent directory and basename paths. This makes the directory sync target unambiguous and avoids path allocation. The publisher owns no allocator or dynamic state.

## Process crash matrix

`zig build checkpoint-crash -Doptimize=ReleaseSmall` repeats the real journal/JSC operation at four boundaries:

| Injected exit | Final checkpoint after restart | First recovery | Second recovery |
| --- | --- | --- | --- |
| after temporary write | old accepted page | apply durable completion | duplicate |
| after temporary-file sync | old accepted page | apply durable completion | duplicate |
| after rename | new completed page | duplicate | duplicate |
| after parent-directory sync | new completed page | duplicate | duplicate |

Each case starts from a fresh accepted checkpoint and a one-record journal. The crash child first appends and syncs the completed record, mutates the real one-page JavaScriptCore slot, then exits at the selected checkpoint boundary. Two more fresh processes recover through `durable_transition.Adapter`.

The supervisor requires the boundary-specific exit status. The expected first recovery disposition is also enforced, so an old checkpoint cannot silently appear new or vice versa.

## Measured result

```text
atomic checkpoint crash suite
publication boundaries 4
fresh child processes  16
old/new canonical only pass
journal reappend         0
```

Each recovery reports a 128-byte journal and exactly 1,536 bytes of fixed native control metadata. Every build asserts that the combined `Harness`, Session fence, durable adapter, and JSC slot bridge remain at most 1,536 bytes.

The control figure excludes JavaScriptCore, the core's 64 KiB linear-memory page, the fixed 65,600-byte checkpoint encoding buffer, file-system cache, process runtime state, and durable files.

## Unit proof

The deterministic store test injects a returned error at the same four boundaries. It decodes the final file after every interruption and accepts only the previous or replacement canonical checkpoint. Temporary files are never recovery truth.

The integration proof uses operating-system process exit rather than a returned error. It therefore also proves that deferred cleanup is not required for correctness.

## What this proves

The active owner can publish a core page without keeping an in-memory rollback copy or per-agent recovery object. Before rename, the old canonical checkpoint remains authoritative. After rename, the new canonical checkpoint is authoritative. The durable completion record reconciles either page.

This exchanges disk writes and sync latency for fixed resident metadata. That trade is appropriate while an agent waits mostly on network and tool I/O.

## Limits

The suite injects process exits, not sudden power removal or storage-controller failure. It verifies program ordering and restart behavior around the operating-system durability calls. It does not independently certify a file system's power-loss guarantees.

The current caller allocates one 65,600-byte encoding buffer. It is fixed per active owner, but it dominates the 1.5 KiB control metadata. A later spike can write the 64-byte header and existing one-page memory through vectored I/O, removing the duplicate page-sized buffer while preserving the same protocol.

Recovery is still driven by reoffering the known completion. The next scheduler spike should scan from a durable journal cursor into fixed admission credits, without constructing a resident agent catalogue.
