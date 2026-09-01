# ADR-0014: Use ephemeral QuickJS for workflow evaluation

Status: accepted

One native Zig Host Runtime is the only agent runtime. A Host-managed QuickJS evaluator receives one immutable Evaluation Generation, evaluates the stored Workflow Definition from source against one Visibility Snapshot of terminal Turn Outputs and stable failures, returns one terminal outcome, and exits. No JavaScript heap, Promise resolver, continuation, bytecode, or completion callback survives a durable barrier. Caller-defined Agent Call Keys map directly to durable Turns. Equal canonical membership reattaches; changed binding conflicts. Physical Turn completion order is not observable, so V1 supports deterministic joins and excludes `Promise.race` and `Promise.any`.
