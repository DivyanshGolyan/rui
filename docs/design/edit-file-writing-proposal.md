# Edit physical writing decision

Accepted 2026-09-09. Design amendment only; no production implementation or runtime evidence is claimed. This follows the [accepted Edit input and approval contract](fixed-location-edit-approval.md) and [execution walkthrough](message-edit-trace.md).

## Decision

After authorization and Attempt admission, open the existing target without creation or truncation. Stream it once into a charged, immediately unlinked output scratch file, validating each approved expected slice and substituting its replacement. Only after every check and complete output construction succeeds, copy that output back through the same opened target handle in fixed-size chunks. Set the final length after the copy, flush under the selected file-completion contract, and report the established outcome.

The logical phases are build/check, copy back, finish. They are private live execution state, not new durable workflow stages. Scratch is discarded on process loss and cannot authorize recovery or replay. Permission still happens before reading the target.

## Why this mechanism

| Option | Benefit | Cost or conflict |
| --- | --- | --- |
| Shift bytes inside the target | Can avoid a complete output scratch file | Growth, shrinkage and mixed multi-range changes require careful copy direction and overwrite avoidance. Validation must still finish before mutation. |
| Prepare output and rename it over the path | One pathname publication rather than a copy-back interval | Replaces the file object; existing open handles and other hard links do not become handles to the replacement. Requires a deliberate target-identity decision, named same-filesystem staging and metadata policy. |
| Prepare output and copy back | Simple sequential passes; retains the opened file object and uses existing unlinked scratch | Writes the complete output and needs output-sized temporary disk. A failed copy can leave partial changes. |

Use the third option under the existing no-implicit-inode-replacement contract. Partial-write uncertainty is already represented in the accepted tool policy. This does not broaden eligibility of multiply linked files or select new symlink behavior.

## Bounded resources

Use the existing reusable 16 KiB copy window, with separately accounted bounded input/comparison state. No complete file, line, replacement string or edit list must be resident. Traverse proposals in source order through existing bounded content facilities; any variable index belongs in charged scratch rather than a growing resident collection. Exact proposal-order encoding remains implementation work.

The new output scratch holds the complete edited file. A 100 MiB output therefore needs about 100 MiB of logical temporary disk for that output, not 100 MiB of resident buffering. Input materialization and metadata retain their own charges; this is not a total per-attempt disk or memory estimate. Check growth against the shared scratch allowance before writing scratch. Failure while building output leaves the target untouched. This mechanism does not need a separate full source snapshot because it reads the opened target into the prepared output before target mutation; external-writer coordination remains the caller's responsibility.

The Edit module owns its handles, offsets, phase and scratch. The execution loop must give copy work bounded service turns, retaining these small live cursors between turns. Fixed-size calls do not guarantee fixed wall-clock filesystem latency. Whole-host responsiveness and memory still require integrated measurement; no new worker/thread pool is selected by this decision.

## Failure and cancellation

- Before the first target mutation: failed checks, scratch exhaustion or cancellation can report not applied after safe cleanup.
- During copy-back: handle short writes, interrupted calls and arithmetic bounds. A failed write may have changed bytes; report that uncertainty honestly. Do not truncate the original first.
- After copy-back: truncate a longer old tail to the exact new length. An empty result still requires a target mutation through truncation. A truncate or flush failure must not be reported as unchanged or successful completion.
- After mutation begins: retain custody through safe execution, outcome collection and cleanup under the existing cancellation policy; do not promise cancellation rollback.
- After process loss without a saved result: report indeterminate, discard scratch, never automatically repeat or repair the edit. No required target inspection is added.

Keeping the same opened file object does not prove the pathname remains bound to it when another process renames or replaces paths concurrently. Preserve existing eligibility and safe-handle checks; the caller-coordination contract does not become isolation. File flush completion also does not make file mutation and SQLite result publication one atomic action.

## Evidence and limits

[ADR-0027](../adr/0027-use-an-in-process-exact-edit-module.md) explicitly prohibits silently replacing required inode/target semantics with atomic rename. Its older search, pre-approval snapshot and reconciliation requirements are superseded by its explicit amendments and the current Edit contract. The historical implementation at `src/patch_tool.zig:450` already copies prepared output to an opened source and syncs it, but first changes its length and uses Git preparation, whole-file digest checks and older eligibility rules. That is source evidence for an existing copy-back mechanism, not implementation of this decision.

[POSIX write/pwrite](https://pubs.opengroup.org/onlinepubs/9699919799.2018edition/functions/write.html) supplies positional writes and requires handling the count actually written. [POSIX rename](https://pubs.opengroup.org/onlinepubs/9799919799/functions/rename.html) describes replacement of directory entries and continued references to the old file. [Apple's archived truncate reference](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/truncate.2.html) documents changing the opened file's length and failure cases. These are API semantics, not current-platform runtime certification.

Required implementation evidence includes mixed growth/shrinkage, chunk-split lines and expected text, late validation failure with no target mutation, scratch exhaustion, partial writes, final-length failure, flush failure, cancellation around first mutation, process death before result publication, target identity, and bounded resource/control behavior. This decision has not been implemented or runtime-tested.
