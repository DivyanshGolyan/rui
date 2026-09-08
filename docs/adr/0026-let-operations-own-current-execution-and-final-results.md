---
status: accepted
---

# Let Operations own current execution and final results

An Operation owns its exact work, current execution/retry facts and optional immutable final Resolution value; its identity also identifies that result. Historical Attempts and Completions and a separate Resolution entity are unnecessary for the accepted crash/recovery guarantees. Keep accepted content separately by reference under the producing Operation, with exact request/execution provenance; bounded diagnostics serve failed-try investigation independently of recovery.

The user accepted the current-state direction after comparing complete crash/race traces and then accepted direct Operation ownership of final results. This trades immutable historical joins for guarded atomic current-state updates. The required distinctions remain: never admitted, admitted but uncertain, retry waiting and immutable final meaning. Attempt remains a fresh physical-try identity recorded on the Operation; Execution Evidence is transient until required retry facts or final meaning commit. The Host owns admission/settlement and policy, while adapters and Physical Custody own live delivery and cleanup. Resolution can precede physical cleanup and does not prove external effects or billing stopped.

The [execution contract](../../ARCHITECTURE.md#host-runtime-execution-and-settlement) owns exact invariants and [verification requirements](../../VERIFICATION.md#operations-attempts-and-recovery) define falsifying crash/race and accounting cases. Preserve the [memory envelope](../../ARCHITECTURE.md#capacity-and-memory) and [bounded diagnostic behavior](../../ARCHITECTURE.md#local-diagnostics-and-application-state); current state lives in SQLite, never in resident objects for dormant work. No measured RAM, CPU or I/O improvement is claimed.

This amends earlier per-try ownership, Completion-owned content, separate Resolution identity and historical-eligibility contracts. Accepted request freezing, output/compaction fidelity, authorization, public replay, Bash/Patch uncertainty and shared-Session cancellation remain. Numeric retry policy and diagnostic storage/quotas retain their existing owners; exact SQL columns and constraints are implementation work within this contract. Historical records describe their original designs and are not production evidence.

Decision discussion: [Choose the execution model and its verification contract](https://github.com/DivyanshGolyan/onepage/issues/106). Supporting comparison: [Compare complete execution models against crash and race scenarios](https://github.com/DivyanshGolyan/onepage/issues/105#issuecomment-5556881068).
