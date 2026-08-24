# Reconcile uncertain effect attempts instead of replaying operations

An accepted operation may survive a crash even when OnePage cannot know whether its external effect occurred. OnePage therefore records each execution try as a distinct attempt with a durable disposition and chooses recovery by effect class: replay only when safe, reconcile observable mutations, and stop with an indeterminate result when neither is possible. This rejects generic automatic retry and any exactly-once claim for effects outside OnePage's transaction boundary.
