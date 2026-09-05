# Runtime experiment evidence

Published 6 September 2026 from three isolated research branches. These are historical investigations supporting the local-server and bounded-execution design, not alternate production implementations.

| Investigation | Evidence | Original commit |
| --- | --- | --- |
| Shutdown, cancellation, and recovery conventions | [Prior-art comparison](shutdown-cancellation-recovery-priors.md) | `b153fd3` |
| Native local HTTP memory and connection churn | [Method, limitations, and raw results](../../research/http-memory-probe/README.md) | `9cd9e20` |
| Slot scans, idle wakes, custody/recovery, and stop latency during capture | [Native probes and recorded results](../../research/execution-control-experiments/README.md) | `4be2d74` |

The original source and measurement files are preserved. Historical recommendation language is not a claim that the related design decisions remain open. Current accepted behavior belongs in the normative documents; the [V1 design index](https://github.com/DivyanshGolyan/onepage/issues/2) identifies remaining decisions. No numeric limit is selected by publishing these results, and no live provider was contacted for publication.

The probes build temporary executables and use synthetic data. Read each runner before reproducing: some overwrite their adjacent result files. Preserve this recorded dataset and direct a fresh run to separate output or a disposable copy. Local benchmarks do not prove integrated Host memory, provider behavior, power-loss safety, or release-grade latency.
