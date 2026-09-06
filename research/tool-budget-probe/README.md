# Tool resource primitives at capacity 1,000

Throwaway native macOS probe, 6 September 2026. No production Host, Bash, Git,
SQLite, workload subprocesses or provider traffic. This tests resource costs,
not tool behavior, throughput, cancellation or a chosen executor topology.

```sh
python3 research/tool-budget-probe/run.py
```

Apple arm64 macOS 15.7.7, Apple Clang 17.0.0, -O2. The recorded three runs used
that same compiler command followed by the same Python subprocess loop; the
checked-in wrapper places the executable in a unique temporary directory.
Each subprocess alone raises its own descriptor soft limit to 8192 within the
existing hard limit. No system settings are changed. Run results are preserved
including any failure, and the wrapper reports a nonpassing run explicitly.

## Shape and measurements

Baseline includes 1,000 fixed records, each with a 128-byte custody field and
fixture handles. The process creates two immediately unlinked empty scratch
files and two pipes per record. It retains both pipe ends so no child process
is needed. Thus there are 6,000 extra descriptors, including 2,000 fixture-only
write ends. One byte is written into each pipe; these are not full pipe buffers.
The historical shared-reactor Bash prototype instead retains four descriptors
per execution in its parent: two pipe read ends and two output scratch files.

The next phase creates 1,000 temporary pthread workers. Each has a 256 KiB
configured stack, writes every byte of a 64 KiB stack array, waits on a shared
condition, then reads the array and returns a checked checksum before joining.
No per-worker content buffer or additional worker process exists. The fixed
stack size and touched amount are experiment controls, not selected production
limits or proven actual Patch stack requirements.

Three fresh-process runs all created 1,000 workers and completed successfully:

| Phase | Physical footprint range | Threads | Open descriptors |
| --- | ---: | ---: | ---: |
| Baseline | 0.92–0.94 MiB | 1 | 3 |
| Pipes and empty files | 0.92–0.94 MiB | 1 | 6,003 |
| Workers waiting | 79.20–79.24 MiB | 1,001 | 6,003 |
| Workers joined | 0.94–0.95 MiB | 1 | 6,003 |
| Files/pipes released | 0.94–0.95 MiB | 1 | 3 |

The worker phase adds about 78.3 MiB physical footprint and 296.875 MiB virtual
address space over the baseline. Virtual address reservation is not resident
memory. Process RSS is recorded separately. All checksums, joins and closes
passed; no scratch paths remain because files were unlinked on creation.
These are phase samples, not continuous peak measurements or long churn tests.

Pipe and file creation produced no resolvable increase in the sampled process
physical footprint. This does not mean the resources are free: kernel pipe,
thread and descriptor memory is unmeasured, and empty scratch files do not
exercise disk throughput, filesystem cache or output-storage consumption.

## Budget implication and limitations

At the proposed 1,000 shared Active Capacity, the basic local OS resource shape
worked on this Mac. The worker fixture fits beneath the proposed 200 MiB active
machinery allowance. It is therefore not evidence for reducing the candidate
capacity solely because temporary workers or thousands of descriptors exist.

It does not establish that 1,000 actual Patch executions fit. Real stack depth,
Git helpers invoked by OnePage, filesystem operations, allocator behavior,
semantic import, clients, evaluator, mixed traffic and CPU contention remain
unmeasured. OnePage-owned helpers remain charged to OnePage, even though
model-selected Bash workloads are observed separately. Fully touching all
256 KiB stacks would itself cost about 250 MiB before other work; do not mistake
64 KiB touched stack for an enforced physical bound. The current source still
uses historical implementation forms, so it is not proof of the new Host.

Use 1,000 as the planned shared startup default, subject to actual resource
validation and release qualification, rather than forcing a smaller number from
unmeasured concerns. Keep the one shared credit table and accepted backpressure.
No permanent worker pool, per-kind admission pool or memory-triggered scheduler
is justified by this primitive-cost probe. The 256 MiB total remains a proposed
engineering target, not a measurement of the complete runtime.
