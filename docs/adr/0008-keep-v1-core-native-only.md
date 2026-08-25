# Keep the V1 Core native-only

OnePage uses native Zig as the sole V1 Core executor and defines no Wasm ABI or secondary runtime conformance target. The exact native Activation Slot, canonical fixed-width Core State, allocator-free native lifecycle interface, and randomized native invariant traces directly verify the product claims; compiling the same reducer with the same compiler for Wasm added a large test interface and runtime harness without providing an independent semantic oracle. A future browser requirement may introduce a new adapter without preserving the removed experimental ABI.
