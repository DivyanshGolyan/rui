# Compute-only evaluation and TigerBeetle prefetch

Research date: 2026-09-10. Primary-source comparison for the evaluator/coordinator discussion. No design amendment or measured OnePage performance claim.

## Located passage

The exact reference is Matklad's [What is an Invariant?](https://matklad.github.io/2023/10/06/what-is-an-invariant.html), 6 October 2023, in the TigerBeetle section. Transaction execution uses prefetched objects; disk work is separated and can be batched, leaving serial in-memory execution. This concerns transaction business logic, not the absence of disk I/O from the complete durability protocol.

His [Static Allocation For Compilers](https://matklad.github.io/2025/12/23/static-allocation-compilers.html), 23 December 2025, provides the qualification: startup-only allocation depends on bounded work-unit inputs and outputs. Variable compiler workloads do not inherit that guarantee simply by allocating a fixed arena. The article explores separating growing outputs from bounded intermediate processing; its compiler proposal is exploratory, not measured proof.

## Transfer to OnePage — inference

The useful shape is prepare inputs, evaluate JavaScript, then validate/save/perform the requested work. An evaluator need not hold model connections, wait on Session creation or receive live model results. Logical Session references can be emitted as data for the coordinator to resolve; their exact API/failure behavior is still under discussion.

Potential benefits follow from the boundary:

- Waiting Runs need no retained evaluator heap or Promise graph. Memory depends on active evaluator capacity rather than the number of waiting Runs.
- One bounded evaluation workspace can be reclaimed after each lifecycle; lifetime and cleanup are easier to account for. This does not select pooling or reuse of a live engine across Runs.
- No live result arrival changes JavaScript inputs halfway through a pass. The coordinator services I/O independently and decides when another evaluation is worth scheduling, without interpreting branch logic.
- Input preparation and requested-work handling can use bounded batches outside JavaScript. Separate owners can measure input I/O, decoding, computation and publication independently.
- Fixed inputs permit isolated evaluator tests without real Sessions, models or a live database.

These are architectural opportunities, not demonstrated speedups. Recompilation/replay, parsing and allocation still consume CPU. User JavaScript values can grow or exhaust memory. A compute-only interface does not establish startup-only allocation, fixed execution time or a no-failure computation.

## Crucial distinction: no effects versus no reads

The [accepted on-demand decoding decision in #114](https://github.com/DivyanshGolyan/onepage/issues/114#issuecomment-5573647755) supplies native lookup through prepared read-only input descriptors. JavaScript sees only a fixed key-to-original-result view and has no filesystem/network API. But the native bridge may read and decode an immutable result while JavaScript runs. That design is isolated from live state, not literally disk-I/O-free.

A strict all-inputs-in-memory pass would remove those reads, at the cost of resident encoded input and any decoded values. It can preload results a particular evaluation never uses; dynamic branches make the actually used subset difficult to know without executing JavaScript. Memory mapping would not by itself establish a no-disk-I/O phase because page faults can fetch data.

Therefore separate two proposed invariants:

1. JavaScript only computes from fixed inputs and returns requested work; no live Session/database/model operations occur through its calls.
2. The entire evaluator performs no disk reads after execution starts.

The first provides the clean ownership boundary. The second is an additional physical-storage choice that needs workload measurements. On-demand decoding can satisfy the first while trading I/O and repeated decoding for lower resident retention. Do not change that decision merely to match the TigerBeetle analogy.

## Next useful evidence if requested

Compare a representative workflow under prepared on-demand result lookup and eager input loading. Measure total lifecycle CPU/time, peak engine/native/whole-process memory, bytes actually read/decoded, unused prefetched bytes and explicit exhaustion. Keep identical visible results and requested calls. Existing #114 prototypes are scoped evidence for the on-demand choice, not a new comparison against a strictly no-read evaluator. No new prototype was run in this research pass.
