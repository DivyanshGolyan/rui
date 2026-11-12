# UTF-8 reader measurements

Release profile; all sizes in bytes. Decode overlap is the maximum simultaneous engine + native backing allocation, including allocation headers, allocator rounding and old/new blocks during forced-moving realloc. It excludes fixed C stack, libc bookkeeping and OS memory; those are not heap-allocation counters.

| Input | Method | Input bytes | Decode overlap peak | Native requested workspace | Native backing peak | Decode checkpoint CPU (µs) |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| ascii-4m | reader | 4,194,313 | 4,444,720 | 16,384 | 16,896 | 26,597 |
| late-wide-4m | reader | 4,194,316 | 8,622,640 | 16,384 | 16,896 | 26,217 |
| all-scalars | reader | 4,382,601 | 4,543,024 | 16,384 | 16,896 | 15,937 |
| wide-key | reader | 1,048,606 | 2,351,664 | 16,384 | 16,896 | 9,740 |
| items-1024 | reader | 18,437 | 292,400 | 16,384 | 16,896 | 4,959 |
| ascii-4m | staged reader | 4,194,313 | 8,671,792 | 4,210,697 | 4,243,968 | 23,952 |
| late-wide-4m | staged reader | 4,194,316 | 12,849,712 | 4,210,700 | 4,243,968 | 25,024 |
| all-scalars | staged reader | 4,382,601 | 8,933,936 | 4,398,985 | 4,407,808 | 16,964 |
| wide-key | staged reader | 1,048,606 | 3,433,008 | 1,064,990 | 1,098,240 | 10,613 |
| items-1024 | staged reader | 18,437 | 311,344 | 34,821 | 35,840 | 3,922 |
| ascii-4m | public chunks + join | 4,194,313 | 14,591,024 | 16,384 | 16,896 | 28,226 |
| late-wide-4m | public chunks + join | 4,194,316 | 24,129,584 | 16,384 | 16,896 | 32,321 |
| all-scalars | public chunks + join | 4,382,601 | 13,984,816 | 16,384 | 16,896 | 26,382 |
| wide-key | public chunks + join | 1,048,606 | 5,668,400 | 16,384 | 16,896 | 9,719 |
| items-1024 | public chunks + join | 18,437 | 292,400 | 16,384 | 16,896 | 5,273 |

## Process memory and retained allocations

These are separate from allocation counters. The physical column is a sampled macOS task footprint; maximum RSS is an OS high-water mark. Neither is a JS heap measure.

| Input/method | Sampled physical peak | Maximum RSS | Engine live at released idle | Engine live after runtime free |
| --- | ---: | ---: | ---: | ---: |
| late-wide-4m / reader | 9,782,016 | 10,682,368 | 193,520 | 0 |
| burst / reader | 4,490,624 | 5,259,264 | 193,520 | 0 |
| late-wide-4m / staged reader | 13,960,000 | 14,893,056 | 193,520 | 0 |
| burst / staged reader | 6,177,984 | 6,995,968 | 193,520 | 0 |
| late-wide-4m / public chunks + join | 23,315,520 | 40,386,560 | 193,520 | 0 |
| burst / public chunks + join | 8,406,144 | 9,273,344 | 193,520 | 0 |

## Identity and reads

| Case / method | Invocations | File bytes read | Full lifecycle CPU (µs) |
| --- | ---: | ---: | ---: |
| ascii-4m / reader | 1 | 8,388,617 | 753,060 |
| late-wide-4m / reader | 1 | 8,388,623 | 750,641 |
| separate / reader | 21 | 2,754,990 | 26,048 |
| promise / reader | 1 | 131,190 | 22,058 |
| retained / reader | 4 | 8,388,752 | 220,633 |
| burst / reader | 12 | 6,291,888 | 159,641 |

Release: 111 cases, 16,777,216-byte QuickJS setting, 8,388,608-byte native requested-allocation ceiling, one-second soft CPU/two-second hard CPU and five-second parent timeout. Same workload and policy per compared method. The full lifecycle CPU includes the independent content oracle; the earlier checkpoint includes startup and decoding.

Diagnostics: 165 ASan/UBSan cases; every one of 28 reader and 28 staged-reader backing allocation points in the nested fixture was fault-injected. Small-block arenas are disabled via the pin's sanitizer macro so individual allocations reach the instrumented allocator. Diagnostic CPU/lifetime limits are 10/30 seconds; these results do not qualify release timing.
