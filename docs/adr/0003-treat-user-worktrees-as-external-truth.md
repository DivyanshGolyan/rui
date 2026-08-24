# Treat user worktrees as external truth

OnePage's operation journal is authoritative for agent intent and observed outcomes, but it cannot reconstruct a user-owned worktree that other processes may change. V1 binds each consequential mutation to expected preimage and observed postimage identities, then stops for reconciliation when the workspace diverges instead of replaying blindly. Only a future harness-owned isolated workspace with closed mutation paths may treat a durable baseline plus semantic mutation records as authoritative and rematerialize its checkout as a cache.
