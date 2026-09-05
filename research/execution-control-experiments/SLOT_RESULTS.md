# Fixed custody table scan experiment

Machine: Apple M1 Pro; macOS-15.7.7-arm64-arm-64bit-Mach-O.

Compiler: Apple clang version 17.0.0 (clang-1700.0.13.5); flags: `-std=c11 -O2 -Wall -Wextra -Werror`.

Run from the experiment worktree: `python3 research/execution-control-experiments/run_slots.py`.

The content-free record mirrors the existing integrated prototype's 128-byte layout. Seven warmed repetitions target 10 ms each; figures below are medians, with all raw elapsed times, checksums, actual rounded occupancy, and min/max recorded in `slot-results.json`. No allocations occur inside timed loops. Acquire loads, compare-exchange operations, noinline entry points, and a compiler memory barrier prevent hoisting the work out of the loops.

## Results

Each figure is microseconds per full table operation or whole completion burst, not per record. Occupancy is rounded down (capacity 1 at 10% or 50% therefore has zero occupied records).

| Capacity | Occupancy | State scan us | Dispatch scan us | Completion lookup burst us | Completion/reuse burst us |
| --- | --- | ---: | ---: | ---: | ---: |
| 1 | 0/1 | 0.001 | 0.017 | 0.001 | 0.003 |
| 1 | 0/1 | 0.001 | 0.021 | 0.001 | 0.003 |
| 1 | 0/1 | 0.001 | 0.017 | 0.001 | 0.003 |
| 1 | 1/1 | 0.001 | 0.021 | 0.002 | 0.019 |
| 10 | 0/10 | 0.005 | 0.198 | 0.001 | 0.006 |
| 10 | 1/10 | 0.005 | 0.191 | 0.002 | 0.019 |
| 10 | 5/10 | 0.005 | 0.200 | 0.016 | 0.121 |
| 10 | 10/10 | 0.005 | 0.198 | 0.030 | 0.284 |
| 50 | 0/50 | 0.026 | 0.978 | 0.001 | 0.029 |
| 50 | 5/50 | 0.026 | 0.835 | 0.041 | 0.144 |
| 50 | 25/50 | 0.026 | 0.827 | 0.229 | 1.152 |
| 50 | 50/50 | 0.027 | 0.839 | 0.471 | 4.059 |
| 100 | 0/100 | 0.053 | 1.609 | 0.001 | 0.056 |
| 100 | 10/100 | 0.053 | 1.670 | 0.187 | 0.335 |
| 100 | 50/100 | 0.053 | 1.635 | 1.000 | 4.047 |
| 100 | 100/100 | 0.053 | 1.633 | 2.071 | 15.491 |
| 1000 (exploratory) | 0/1000 | 0.536 | 16.289 | 0.001 | 0.584 |
| 1000 (exploratory) | 100/1000 | 0.529 | 16.160 | 16.769 | 15.982 |
| 1000 (exploratory) | 500/1000 | 0.537 | 16.145 | 85.043 | 368.926 |
| 1000 (exploratory) | 1000/1000 | 0.532 | 16.898 | 171.283 | 1466.167 |

## Interpretation and boundaries

The state scan reads every state word. The dispatch scan reproduces the prototype's failed DISPATCHABLE-to-ACTIVE compare-exchange plus active-state read, using model-kind records. Completion lookup searches from slot zero separately for each evenly distributed active handle. Completion/reuse seals all occupied records, sweeps sealed records, and reacquires first-free slots for each replacement; this generic allocator is an exploratory worst case, since the existing prototype admits known array positions. Reuse is packed at the start of the table.

The lookup and first-free admission loops can do quadratic work across a full burst. A sweep's low cost must not be presented as the cost of an entire burst. Capacity 1,000 is a sensitivity experiment, not a chosen product capacity.

Recommendation: retain the simple fixed table at the tested required capacities through 100. These isolated costs provide no current performance justification for adding an active/free index, so no indexed competitor was built. If capacity 1,000 or repeated large completion bursts become a real requirement, first try admitting a whole burst in one monotonic free-slot sweep; that removes repeated first-free scans without adding a second resident index. This is a follow-up candidate, not a measured implementation or a newly selected capacity.

These warm-cache, single-thread timings exclude SQLite, actual cleanup, callbacks, syscall cost, thread contention/cache-line transfer, materialization, scheduling/wake cost, and model/tool execution. The process was not CPU-pinned and the laptop was not isolated; short samples have scheduler noise. They cannot establish Host responsiveness, complete allocation cost, or crash correctness.

### Explicit scan cadence conversion

These are arithmetic estimates for one sweep per wake; they do not select polling or measure idle wake cost. An idle implementation can sleep until signalled. Percentage means one CPU core.

| Capacity, empty | State at 100/s CPU % | State at 1,000/s CPU % | Dispatch at 100/s CPU % | Dispatch at 1,000/s CPU % |
| --- | ---: | ---: | ---: | ---: |
| 1 | 0.00001 | 0.00010 | 0.00017 | 0.00170 |
| 10 | 0.00005 | 0.00054 | 0.00198 | 0.01977 |
| 50 | 0.00026 | 0.00265 | 0.00978 | 0.09778 |
| 100 | 0.00053 | 0.00527 | 0.01609 | 0.16086 |
| 1000 | 0.00536 | 0.05355 | 0.16289 | 1.62894 |

### Correctness assertions

Every repetition checks the exact occupied-record checksum. The native program checks occupancy after timing, exact reuse-generation sums, successful first-free reservation, and ACTIVE state before every simulated seal. These checks validate this benchmark's work, not production safety.
