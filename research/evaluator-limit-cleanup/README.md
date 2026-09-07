# Remaining evaluator limit checks

7 September 2026. Throwaway branch based on `13b6e59`, macOS 15.7.7 / Darwin 24.6.0 / Apple Silicon / Zig 0.16.0. Production checkout unchanged. No saved workflows, external model requests or machine-wide limit changes.

## Step-count replacement

`python3 research/evaluator-limit-cleanup/run.py` builds the actual evaluator baseline and a candidate replacing the 4,096-job rejection with a CPU/wall interrupt check before each pending JS job. It leaves the candidate in the throwaway source. All 16 fixture/variant outcomes pass independent checks:

- Tiny, fan-out, partial replay, prior-result aggregation, heap exhaustion and ordinary CPU-loop outcomes are preserved.
- A finite loop of 10,000 `await 0` steps fails the baseline's Microtasks cap and correctly returns 10,000 in the candidate.
- An endless `await 0` loop fails at Microtasks in the baseline and at CpuTime in the candidate.

Every child exits normally; none reaches the Python seven-second emergency timeout. ReleaseSafe builds pass. This qualifies this job-draining replacement, not complete native parsing/encoding CPU coverage, final parent lifetime enforcement or the production suite. Other historical limits remain. The unused historical counter/constant remain in this minimal candidate to isolate the tested change; final cleanup would remove them.

## Mac address-space setting

Compile `rlimit_as.c` with `clang -O2 -Wall -Wextra -Werror` and run it in a fresh process. The probe attempts the historical 64 MiB RLIMIT_AS; this Mac returns EINVAL (22). The probe records that failure and exits before mapping/touching its optional 96 MiB test allocation. It did not demonstrate exceeding an successfully installed limit. Only the probe process is affected.

`zig run research/evaluator-limit-cleanup/zig_resource_fields.zig` reports `has_AS=false; has_RSS=true`. Installed Zig 0.16.0 std/c.zig defines Darwin RSS as enum field 5 and AS as an alias declaration. OnePage's `@hasField(...,"AS")` condition is false, so the evaluator currently skips that setter on this target. Changing it to a declaration check alone would expose the rejected 64 MiB setting, not install useful protection.

Apple's [kernel setter](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/kern_resource.c#L1560) validates RLIMIT_AS against mapped address-space use and rejects a limit below existing usage. This is corroborating upstream source, not proof that the published revision matches the installed kernel. Address-space size is not physical RAM. The local failure and skipped branch are directly reproduced; do not generalize them into a claim that every Mac address-space limit is ineffective.

Recommendation: retire this unsupported fixed 64 MiB setting for the supported macOS V1 build. Keep explicit engine/native allocation bounds, structural guards, one-evaluator population, CPU/elapsed containment and whole-Host physical-footprint qualification. Do not invent an RSS polling killer, special Mach memory service or universal VM number. Other future supported targets need their own concrete purpose/evidence before an address-space guard is introduced. This is a pending design recommendation, not production removal.

## Remaining source/count guards

The source audit finds materialization/work consumers, not independent workflow promises: source copies, argument decoding, visible-result input frames, key metadata arrays, request arrays and serialization frames. Recommend replacing independent byte/item/request quotas with bounded actual allocation, streaming transfer and time checks as those representations are replaced. Source compilation still requires contiguous engine/native storage; arbitrary workflow size is not promised. Retain array bounds until their replacement, duplicate-key and immutable request checks, checked wire lengths/arithmetic, strict data validation, native/engine recursion protection, bounded diagnostics, and safe failure/publication behavior. Full workloads exceeding the old boundaries must pass integration; this experiment does not implement those replacements.
