---
status: amended by ADR-0019 and ADR-0021
---

# Keep the V1 runtime native-only

OnePage uses native Zig as the sole V1 agent runtime and defines no Wasm ABI or secondary lifecycle conformance target. SQLite-backed relational authority, the bounded Host Runtime topology in ADR-0021, and production-interface invariant tests directly verify V1 claims; compiling a second reducer target added a large test surface without an independent semantic oracle. A future shipping environment may introduce another target without preserving the removed experimental ABI.
