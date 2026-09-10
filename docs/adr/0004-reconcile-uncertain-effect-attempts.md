---
status: amended by ADR-0021
---

# Reconcile uncertain effect attempts instead of replaying operations

## Accepted amendment — Unified uncertain-tool recovery (10 September 2026)

Bash and Edit share the [no-replay rule](../design/unified-tool-recovery.md): if an admitted execution may have started and its outcome cannot be established, save an indeterminate Tool Result without mandatory Edit target inspection or comparison. The Agent may investigate with new ordinary tool calls. Preserve exact authorization, live effect cleanup and the separate model replacement policy. [ADR-0026](0026-let-operations-own-current-execution-and-final-results.md) continues to own current execution facts and final Resolution; old per-try authority and automatic reconciliation below are superseded.

## Accepted native Edit amendment — 6 September 2026

[ADR-0027](0027-use-an-in-process-exact-edit-module.md) replaces Git-backed unified Patch with the in-process exact Edit module behind the Action adapter. The closed executable inventory is `bash` and `edit`. Preserve permissions, exact preimage/postimage intent, uncertainty and recovery; Host authority stays separate from edit mechanics. Git-specific helper/scratch requirements and old Patch names below are historical where superseded. The current [Edit contract](../architecture/execution.md#native-edit-module) and [verification](../verification/execution.md#native-edit-verification) govern implementation; this is not production certification.


An admitted Operation may survive a crash even when OnePage cannot know whether its external effect occurred. OnePage therefore records each execution try as a distinct relational Attempt and chooses recovery from the Operation's exact typed descriptor: a model or Bash dispatch that may have begun is not automatically repeated as the same Attempt, while a one-file patch observes the preimage, expected postimage, divergence, or invalid target bound by its durable Patch Intent. After Physical Custody is lost, even an expected postimage cannot prove that OnePage's Attempt produced it, so recovery selects an Indeterminate Resolution with the observation rather than silently completing or reapplying the Patch. An indeterminate Bash Resolution becomes a Tool Result so the Agent can inspect external state and choose its next action; uncertainty alone neither forces User intervention nor terminates the Turn. This rejects generic automatic retry and any exactly-once claim for effects outside OnePage's transaction boundary.

## Accepted amendment — Operation-owned execution and results

[ADR-0026](0026-let-operations-own-current-execution-and-final-results.md) supersedes this record’s per-try authority and final-content ownership. Use the current [execution contract](../architecture/execution.md) and [verification](../verification/execution.md); retain the original wording as history.
