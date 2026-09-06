# Native evaluator workspace: actual usage and simple reuse

6 September 2026. Throwaway experiment based on serial-evaluator commit `edc82c5`. Production/main checkout unchanged.

## Finding

The historical 2 MiB bridge allocation is a capacity, not a per-evaluation claim of 2 MiB resident use. Instrumenting the actual FixedBufferAllocator shows about **148 KiB of claimed arena space** for tiny work, rising with source length and retained canonical request descriptions. The input frame, output frame, QuickJS heap, stack and parent are separate costs.

One straightforward improvement is justified: the **64 KiB key-validation workspace** finishes its job when input parsing returns, before the **64 KiB descriptor-encoding workspace** is used. Reuse that storage instead of reserving both. This reduces tiny-case claimed arena space to **84 KiB**, with no extra allocator, worker or pool.

It does not eliminate the need to bound actual native allocations. A synthetic 200-request workflow with 6,000-character request inputs uses about **1.24 MiB** of the reused arena because canonical descriptors are retained for exact identity comparisons. A near-capacity 245-request fixture succeeds after reuse where the original arrangement exhausts the arena. Those historical copies are a real resource consumer, not a reason to blindly accept the current 2 MiB value as final V1 policy. Future disk-first request representation may change this cost.

## What is inside

- 65,536 bytes for up to 4,096 key slices used during strict input validation.
- 20,672 bytes for `Evaluation`, including its two historical fixed 256-entry tables and other fields.
- A null-terminated source copy, whose size depends on source length.
- Originally a separate 65,536-byte descriptor encoder scratch region; reused with the key workspace in the candidate.
- Variable canonical request copies retained by `agentCall`, plus alignment.

The key slice values refer to immutable input bytes; recorded visible keys/payloads also point into that input, not into the key-array storage. Persistent source/state/request allocations remain distinct. Descriptor scratch is used only after parsing returns, and each retained descriptor is copied to separate arena storage before scratch reuse. This is a phase-lifetime argument, not a generic sharing framework.

The prototype's compile-time capacity check ensures key workspace can hold the historical descriptor window. The candidate exposes only the original descriptor window length, so it does not silently broaden descriptor input. These historical constants remain to be separated/derived during the selected output/protocol changes; this alias is not a proposed permanent policy coupling.

## Measurements

One execution per deterministic allocation fixture and variant; no timing or physical-footprint comparison is claimed. The printed `arena.end_index` is a high-water proxy here because this code performs no frees or rewinds during evaluation. It includes claimed aligned arena bytes, not OS page residency. Eliminating 64 KiB of arena reservations does **not** prove a 64 KiB RSS/physical-footprint saving; both variants still reserve the same 2 MiB mapping.

| Fixture | Original claimed bytes | Reused claimed bytes | Outcome |
| --- | ---: | ---: | --- |
| Tiny result | 151,792 | 86,256 | Both correct |
| 64-way fan-out | 156,038 | 90,502 | Both exact blocked keys |
| Partial replay | 156,038 | 90,502 | Both exact remaining keys |
| Aggregate 256 KiB of prior results | 156,070 | 90,534 | Both correct total |
| 60 KiB result | 151,808 | 86,272 | Both exact result |
| 20,000 temporary JS objects | 151,872 | 86,336 | Both correct count |
| Approximately 60 KiB source | 211,808 | 146,272 | Both correct |
| 200 requests × 6,000-character inputs | 1,367,778 | 1,302,242 | Both correct |
| 245 requests × 8,000-character inputs | 2,090,978 before failed allocation | 2,065,842 | Original BridgeArena failure; reused completes |
| Visible object with keys, then request encoding | 151,920 | 86,384 | Both correct |
| Duplicate argument key | 65,584 | 65,584 | Both reject DuplicateKey before execution |

All **22 assertions/cases passed**, including the expected baseline failure and candidate success near capacity. Python independently checks result values, exact strings, blocked-key order and failure classifications. Original/candidate used the same evaluator settings and synthetic fixture bytes; binary and instrumented-source hashes are in results. No saved user transcript content or providers were used.

This is allocator usage of the real historical evaluator with the accepted construction cleanup, not a final V1 native workspace budget, new result-size policy or whole-Host qualification. It preserves all historical input/output/entry/job caps. Large result streaming, keyed Session integration, complete parent/Store accounting and final shape/limit decisions remain separate.

## Reproduce

```sh
python3 research/evaluator-native-workspace/run.py
```

Requires the repository's macOS/Zig/QuickJS build prerequisites. The runner builds both variants from the known parent commit and leaves the instrumented reuse candidate in this throwaway branch. `baseline-evaluator.zig.txt` captures the comparison source. Each child inherits only stdio, has an empty environment, and exits normally; diagnostic stderr contains small aggregate usage records, never workflow content. The build passed with ReleaseSafe, and whitespace checks passed. Production test-suite certification is not claimed.
