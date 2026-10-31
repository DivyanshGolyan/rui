# Codec sandbox measurements (U0)

Can WAMR run user-supplied codecs cheaply and safely enough for the
provider-plugin plan? `src/codec_runtime.zig` wraps WAMR 2.4.5's fast
interpreter. Nothing in the shipped binary calls it yet.

Machine: Claude Code cloud container, Linux x86-64, 4 vCPU (Intel Xeon
2.80 GHz), shared with other tenants, so throughput moves between runs.
Base: main 5a5c297. Builds are ReleaseSafe, the shipped build mode, for the
native code and the wasm module alike. Memory is in KiB from
`/proc/self/smaps_rollup`.

## Results

| Question | Result | Target in the design |
| --- | --- | --- |
| Decode throughput | 12.7 MB/s in wasm (range 10.8 to 14.0) vs 542 MB/s native in the same run, 43x slower | at least 50 MB/s: **missed** |
| Same, WAMR built without Zig's C safety checks | 27.5 MB/s (range 25.8 to 29.1) vs 683 MB/s native, 25x slower | **missed** |
| Metered cost | 17.9 interpreter steps per input byte | none |
| Memory while one job runs | +176 KiB anonymous, of which +84 KiB is the loaded 41 KB module and runtime | under 256 KiB: met |
| Memory after the module unloads | WAMR returns every byte it allocated (test); the process keeps +104 KiB the C allocator holds for reuse | 0: **not met at process level** |
| WAMR's own allocations | capped at 8 MiB across all modules and jobs; a table declared too large fails to instantiate (test) | none |
| Idle Host, branch vs main | 936 KiB private, 7,052 KiB RSS on both (3 alternating runs each) | unchanged: met |
| Shipped binary, branch vs main | identical code and data size (11,566,064 B code) | unchanged: met |
| Binary cost once a caller links it | +231,424 B stripped (12,281,984 to 12,513,408 B, +1.9%) | none |
| Largest WAMR native stack frame | 232 B below pushed registers (loader); the interpreter loop's is 120 B | at most 8 KiB: met |
| Metering deterministic | the same call needs exactly the same budget, every time and on fresh jobs (test) | yes: met |
| Load, begin, end | 548 us to load the 41 KB module; 31 us to begin a job; 50 us to end it | none |
| Clean `zig cc` build | Linux x86-64 built and run; Linux arm64 compiles and links | yes: met on Linux |
| macOS arm64 | compiles and links here only with one header missing from Zig's bundled macOS headers stubbed; Mac CI is the real check | runs: open |
| Preparation overhead | not measured: no codec exists yet to prepare a request | at most 10%: open |

## What the throughput number measures

The bench runs one scanner, `src/codec_runtime/scan.zig`, natively and as a
wasm module. It reads a Codex-like event stream (text deltas with escapes
and non-ASCII text, plus function-call argument deltas) in 64 KiB windows,
decodes every JSON string on its `data:` lines, and folds the decoded bytes
into a digest. Both builds must produce the same digest, so both did the
same work. The wasm side's time includes copying each window into the job's
memory, which a real codec's caller pays too.

The scanner is a byte-at-a-time state machine, the shape the design gives
interpret. At 17.9 steps per byte, 12.7 MB/s is about 4.4 ns per interpreter
step, and 27.5 MB/s about 2 ns. That is ordinary for an interpreter, so the
limit is the interpreter itself, not this wrapper. Zig's C safety checks in
ReleaseSafe roughly double each step's cost. In an earlier run (smaller
module build, same machine), turning instruction metering off made no
difference with those checks on (11.0 vs 10.8 MB/s) and moved the median
from 17.7 to 24.7 MB/s with them off, inside overlapping ranges. Metering is
not the main limit either way.

A real codec could take fewer steps per byte than this stand-in, or more.
The number to plan with is the steps per byte, which the bench prints for
any module.

## Memory after unload

`unloading the last module returns everything WAMR allocated` checks WAMR's
own allocation counter, which every WAMR allocation passes through, returns
to zero. The 104 KiB the process keeps is the C allocator holding freed
memory for reuse, plus WAMR's static data touched once. Fifty jobs leave the
same amount as five.

Private_Dirty is not used here: a freshly built binary's own code pages count
as private dirty until the kernel writes the file back, which inflated it by
about 100 KiB in this container. Anonymous memory counts what the sandbox
allocates.

## Build choices that change behaviour

- **Fast interpreter only.** No AOT, JIT, WASI, threads, shared memory or
  host functions. Software bounds checks, so WAMR installs no signal handlers
  and maps only the memory a module declares.
- **Shrunk memory off.** WAMR otherwise guesses from Zig and Clang globals
  that memory above the heap base is unused and cuts it from the module.
- **Alignment sanitizer off for WAMR's C.** WAMR reads unaligned values on
  purpose; with it on, loading any module traps. Other Zig C safety checks
  stay on, which costs about half the throughput (table above). Turning them
  off is a later call for U7.
- **Refusals at load.** Imports, a start function, and exports named
  `__post_instantiate` or `__wasm_call_ctors`, which this WAMR build calls
  while instantiating: those run before any call sets a budget, so a module
  could hang the Host there.

## Rerunning

- `zig build test-codec-runtime`: the sandbox's tests.
- `zig build codec-runtime-bench -- 32 7` (32 MiB corpus, 7 rounds); add
  `-Dcodec-runtime-c-safety=false` for the second throughput row.
- `sh research/codec-runtime/frames.sh BINARY` on the bench binary
  (`find .zig-cache -name rui-codec-runtime-bench`): native frame sizes.
- Size and idle memory: build `zig build -Doptimize=ReleaseSafe` on main and
  on this branch, compare `size` and `strip` output, run `sync`, then
  `python3 -I research/codec-runtime/idle.py MAIN_RUI BRANCH_RUI`.
- Cost once linked: `git apply research/codec-runtime/link-probe.patch`,
  which makes `rui` call the sandbox when `RUI_CODEC_RUNTIME_PROBE` is set,
  then build and strip as above.
