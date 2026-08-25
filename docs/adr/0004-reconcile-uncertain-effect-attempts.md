# Reconcile uncertain effect attempts instead of replaying operations

An accepted Operation may survive a crash even when OnePage cannot know whether its external effect occurred. OnePage therefore records each execution try as a distinct Attempt with a durable disposition in the Session Ledger and chooses recovery by effect class: retry only when safe, reconcile observable mutations, and stop with an indeterminate Result when neither is possible. This rejects generic automatic retry and any exactly-once claim for effects outside OnePage's transaction boundary.
