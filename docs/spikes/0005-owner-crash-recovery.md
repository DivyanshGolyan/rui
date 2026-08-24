# Fixed-credit owner crash recovery

## Question

Does the fixed-credit harness still preserve durable-before-apply ordering when it drives the real operation journal and the real JavaScriptCore execution slot, and when the process actually exits at the boundary?

## Proof shape

`zig build owner-crash -Doptimize=ReleaseSmall` runs four fresh child processes:

1. `owner-prepare` creates one submitted core operation, appends and syncs its accepted record, advances the core to accepted, and checkpoints the one-page slot.
2. `owner-crash-after-sync` restores that checkpoint, offers one completion through `Harness`, appends and syncs the completed record through `operation_log.Writer`, and exits with status 86 from the post-persist fault hook. It never calls the slot adapter.
3. The first `owner-recover` restores the still-accepted core page. `durable_transition.Adapter` finds the synced completion, classifies it as durable, skips a second append, applies it through the core ABI, and checkpoints the completed page.
4. The second `owner-recover` restores the completed page. The adapter classifies the same durable completion as a duplicate and performs no mutation.

The parent supervisor requires the injected child exit status. A normal return, signal, or different status fails the spike.

## Deep seam

The new `durable_transition.Adapter` owns the relationship between three facts:

- the completion offered to the fixed-credit owner;
- the accepted and completed records in the durable journal;
- the operation state in the currently restored execution slot.

The adapter scans the journal without building a resident per-agent index. It returns:

- `stale` when the offered identity or generation does not match the restored owner, or no accepted record exists;
- `applicable` when an accepted record exists but no completed record does;
- `durable` when the completed record exists but the slot has not applied it;
- `duplicate` when both the journal and restored slot contain the completion.

Journal corruption, invalid record order, a result mismatch, or a slot ahead of its journal is an error. `Harness.drive` now treats classification errors like persistence and apply errors: it retains the credit, marks the owner unavailable, and requires reconstruction.

## Measured result

The passing run reports:

```text
owner prepare          accepted operation durable
owner recover          applied; journal 160 B; control 1536 B
owner recover          duplicate; journal 160 B; control 1536 B
fixed-credit owner crash suite
fresh child processes 4
crash boundary        completion fsync -> slot apply
forced exit observed  86
first recovery        applied durable completion
second recovery       duplicate, no mutation
```

The 1,536-byte figure is fixed native control metadata: `Harness`, `durable_transition.Adapter`, and the JSC slot bridge, including its open checkpoint-directory handle. It excludes JavaScriptCore, the 64 KiB core linear-memory page, the 65,600-byte checkpoint encoding buffer, journal and checkpoint files, process runtime memory, and build machinery.

The durable journal remains exactly two canonical 80-byte records after both recoveries. No recovery appends another completion.

## Bounds

Every build enforces:

- `@sizeOf(Completion) == 40`;
- `@sizeOf(Harness) <= 1,536` bytes;
- `@sizeOf(durable_transition.Adapter) <= 192` bytes;
- one initial and maximum Wasm page;
- no `memory.grow` instruction in the emitted core.

The adapter adds no allocator and retains no dynamic collection. Its journal scan trades recovery compute and disk reads for zero resident index growth.

## What this proves

This is no longer an in-memory crash simulation. An operating-system process terminates after the completion record's file sync and before any call that can mutate the restored slot. Two later processes independently prove application and idempotent replay through the production core ABI and checkpoint format.

The result supports a narrow claim: logical agent count does not require resident transition objects or a resident journal index. The active owner uses fixed control metadata, one execution page, and bounded staging storage; suspended agents remain journal and checkpoint records on disk.

## Remaining boundary

Checkpoint replacement now uses the atomic publisher and crash matrix in [`0006-atomic-checkpoint-publication.md`](0006-atomic-checkpoint-publication.md). This spike's original direct-write limitation is retained there as a tested old-or-new checkpoint invariant.

The remaining recovery limitation is manual reoffering of the known completion. Durable Session ownership and epoch fencing are implemented in [`0007-durable-session.md`](0007-durable-session.md); a scheduler must still scan a durable journal cursor into fixed admission credits without constructing a resident agent catalogue.
