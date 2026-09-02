---
status: amended by ADR-0021
---

# Treat User worktrees as external truth

OnePage's canonical relational rows are authoritative for Agent intent and observed outcomes, but they cannot reconstruct a User-owned worktree that other processes may change. Before Authorization, V1 binds each consequential mutation to one immutable Patch Intent containing the exact preimage, patch, and expected postimage. Recovery observes preimage, expected postimage, divergence, or invalid target and never treats transcript text as Workspace proof. OnePage provides no Workspace fence, quiescence assumption, isolation guarantee, or atomic compare-and-swap claim against arbitrary concurrent writers. Only a future runtime-owned isolated Workspace with closed mutation paths may treat a durable baseline plus semantic mutation records as authoritative and rematerialize its checkout as a cache.
