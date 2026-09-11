# Recorded decoding measurements

All numbers are bytes. `engine peak` is backing allocator usable bytes, including engine/native runtime allocations; `JS used` is QuickJS's structural estimate at the loaded marker. Neither is process physical footprint. Footprint peaks are sampled, not continuous maxima.

| Case | Whole input staged | Engine peak | Native requested peak | Sampled physical peak | Retained-idle physical |
| --- | --- | ---: | ---: | ---: | ---: |
| bytes-65536 | False | 297,360 | 16,384 | 1,475,328 | 1,475,328 |
| bytes-1048576 | False | 1,280,400 | 16,384 | 2,409,216 | 2,392,832 |
| bytes-4194304 | False | 4,426,128 | 16,384 | 5,538,624 | 1,327,936 |
| items-1024 | False | 1,789,328 | 16,384 | 2,917,056 | 2,917,056 |
| items-16384 | False | 2,525,584 | 16,384 | 3,785,536 | 3,785,536 |
| selective | False | 1,281,936 | 16,384 | 2,474,752 | 2,458,368 |
| separate | False | 2,360,720 | 16,384 | 5,554,944 | 5,554,944 |
| promise | False | 1,281,936 | 16,384 | 2,441,920 | 2,441,920 |
| retained | False | 4,526,480 | 16,384 | 5,669,632 | 5,669,632 |
| burst | False | 4,526,480 | 16,384 | 5,735,168 | 5,718,784 |
| saved-1 | False | 297,360 | 16,384 | 1,491,776 | 1,491,776 |
| saved-32 | False | 297,360 | 16,384 | 1,377,024 | 1,377,024 |
| saved-1024 | False | 297,360 | 16,384 | 1,377,024 | 1,377,024 |
| heap-exhaustion | False | 12,876,176 | 16,384 | 14,025,600 | 1,393,536 |
| bytes-65536 | True | 297,360 | 65,548 | 1,508,096 | 1,491,712 |
| bytes-1048576 | True | 1,280,400 | 1,048,588 | 3,425,088 | 3,425,088 |
| bytes-4194304 | True | 4,426,128 | 4,194,316 | 9,765,696 | 1,344,320 |
| items-1024 | True | 1,789,328 | 1,052,680 | 4,080,448 | 4,064,064 |
| items-16384 | True | 2,525,584 | 1,114,120 | 4,834,112 | 4,817,728 |
| selective | True | 1,281,936 | 1,048,840 | 3,425,024 | 3,425,024 |
| separate | True | 2,360,720 | 1,048,840 | 9,897,088 | 9,897,088 |
| promise | True | 1,281,936 | 1,048,840 | 3,425,024 | 3,425,024 |
| retained | True | 4,526,480 | 1,048,840 | 6,685,504 | 6,685,504 |
| burst | True | 4,526,480 | 1,048,840 | 6,701,824 | 6,701,824 |
| saved-1 | True | 297,360 | 65,548 | 1,442,560 | 1,442,560 |
| saved-32 | True | 297,360 | 65,548 | 1,442,560 | 1,442,560 |
| saved-1024 | True | 297,360 | 65,548 | 1,442,560 | 1,442,560 |
| heap-exhaustion | True | 12,876,176 | 4,194,316 | 18,170,752 | 1,328,000 |

## Engine accounting at the loaded marker

| Direct case | Allocator live | QuickJS allocation accounting | JS used estimate |
| --- | ---: | ---: | ---: |
| bytes-4194304 | 4,422,032 | 4,328,096 | 4,289,846 |
| items-1 | 1,276,304 | 1,182,368 | 1,144,118 |
| items-16384 | 2,521,488 | 2,230,928 | 2,077,949 |
| promise | 1,260,944 | 1,167,048 | 1,131,678 |
| retained | 4,526,480 | 4,431,048 | 4,304,952 |

## Parent preparation and saved population

| Saved results, each 65,536 payload bytes | Scratch logical | Scratch allocated | Python preparation peak | Parent prepared physical | Child bytes read |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 | 65,548 | 69,632 | 50,338 | 24,151,872 | 65,548 |
| 32 | 2,097,536 | 2,101,248 | 50,338 | 24,168,256 | 65,548 |
| 1,024 | 67,121,152 | 67,121,152 | 50,338 | 24,119,104 | 65,548 |

Parent cold physical footprint after dependency build/loading: 23,676,736 bytes. Each native child receives one read-only prepared file plus three stdio streams. Preparation and integrity checking reuse bounded chunks; the child never reads unselected records. Global vm_stat snapshots in the saved-1024 rows are contextual system-wide cache/page counts, not attributable OnePage memory.
