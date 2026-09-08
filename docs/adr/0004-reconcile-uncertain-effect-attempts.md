---
status: amended by ADR-0021
---

# Reconcile uncertain effect attempts instead of replaying operations

## Accepted native Edit amendment — 6 September 2026

[ADR-0027](0027-use-an-in-process-exact-edit-module.md) replaces Git-backed unified Patch with the in-process exact Edit module behind the Action adapter. The closed executable inventory is `bash` and `edit`. Preserve permissions, exact preimage/postimage intent, uncertainty and recovery; Host authority stays separate from edit mechanics. Git-specific helper/scratch requirements and old Patch names below are historical where superseded. The current [Edit contract](../../ARCHITECTURE.md#native-edit-module) and [verification](../../VERIFICATION.md#native-edit-verification) govern implementation; this is not production certification.


An admitted Operation may survive a crash even when OnePage cannot know whether its external effect occurred. OnePage therefore records each execution try as a distinct relational Attempt and chooses recovery from the Operation's exact typed descriptor: a model or Bash dispatch that may have begun is not automatically repeated as the same Attempt, while a one-file patch observes the preimage, expected postimage, divergence, or invalid target bound by its durable Patch Intent. After Physical Custody is lost, even an expected postimage cannot prove that OnePage's Attempt produced it, so recovery selects an Indeterminate Resolution with the observation rather than silently completing or reapplying the Patch. An indeterminate Bash Resolution becomes a Tool Result so the Agent can inspect external state and choose its next action; uncertainty alone neither forces User intervention nor terminates the Turn. This rejects generic automatic retry and any exactly-once claim for effects outside OnePage's transaction boundary.

## Accepted amendment — Operation-owned execution and results

[ADR-0026](0026-let-operations-own-current-execution-and-final-results.md) supersedes historical Attempt/Completion authority, separate Resolution identity and Completion-owned final-content bindings in this record. Operations own current execution/retry facts, immutable final Resolution values and required final content by reference. Existing effect-specific uncertainty, request freezing, accepted continuation, public replay and bounded-memory guarantees remain in force. The original text remains historical decision evidence; the current [execution contract](../../ARCHITECTURE.md#host-runtime-execution-and-settlement) and [verification requirements](../../VERIFICATION.md#operations-attempts-and-recovery) govern implementation.
