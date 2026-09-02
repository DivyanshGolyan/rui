---
status: amended by ADR-0021
---

# Reconcile uncertain effect attempts instead of replaying operations

An admitted Operation may survive a crash even when OnePage cannot know whether its external effect occurred. OnePage therefore records each execution try as a distinct relational Attempt and chooses recovery from the Operation's exact typed descriptor: a model or Bash dispatch that may have begun is not automatically repeated as the same Attempt, while a one-file patch observes the preimage, expected postimage, divergence, or invalid target bound by its durable Patch Intent. After Physical Custody is lost, even an expected postimage cannot prove that OnePage's Attempt produced it, so recovery selects an Indeterminate Resolution with the observation rather than silently completing or reapplying the Patch. An indeterminate Bash Resolution becomes a Tool Result so the Agent can inspect external state and choose its next action; uncertainty alone neither forces User intervention nor terminates the Turn. This rejects generic automatic retry and any exactly-once claim for effects outside OnePage's transaction boundary.
