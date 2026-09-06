# Scratch logical-byte accounting probe

Question: is reserving file growth before writes, with one shared counter,
simple and memory-efficient, and what overhead does it add to real scratch I/O?

Throwaway C11 implementation on arm64 macOS 15.7.7, Apple Clang 17.0.0 -O2.
No production Host, SQLite, providers or new runtime architecture. Run:

```sh
python3 research/scratch-accounting-probe/run.py
```

The runner builds in a unique temporary directory. Each fresh subprocess creates
and immediately unlinks its own scratch files, closes them on completion, and
writes no durable user data. Maximum benchmark file content held at once is
128 MiB. Thirty measured I/O cases write 3.75 GiB cumulatively, not concurrently.
These are normal cached scratch writes without fsync; this is not a storage
latency or durable-throughput benchmark.

## Small implementation

- One 8-byte logical size per file. The fixture's fd-plus-size struct is 16 bytes
  with alignment; it contains no content buffer. Size tracking is also present
  in the comparison path, so that path does not pretend offset tracking is free.
- One shared 16-byte budget: 8-byte limit and 8-byte atomic used count. The atomic
  reports lock-free on this machine. This is not a cross-platform guarantee.
- A growth operation reserves `max(old_size, offset + requested) - old_size`
  with an atomic compare/exchange before pwrite. The subtraction/check avoids
  exceeding the cap even when owners race. A full successful growing write
  performs one successful reservation CAS, potentially retrying under contention;
  no zero-byte refund atomic is issued.
- The file's actual size advances only by the returned write extent. Partial
  writes or errors refund the unused reservation. Sparse gaps count as logical
  bytes. Offset overflow rejects before reservation or I/O.
- Overwrites within existing size require no budget change. Successful shrinking
  ftruncate refunds removed bytes; failed truncation leaves the charge intact.
- Final close releases the remaining charge only after all use is finished.

Each file has exactly one owner at a time. Other threads may own other files and
share the budget, but may not concurrently write/truncate/close this same file.
No independent writable duplicates or mmap paths can bypass accounting. Transfer
of ownership is synchronized by the caller, not by relaxed atomic accounting.
The counter protects quantity, not file lifetime. A new file growth mechanism
must preserve the same reservation boundary; direct ftruncate growth is absent.

Reservations remain charged during I/O, so concurrent in-progress writes cannot
oversubscribe. Once operations quiesce, total charge equals summed logical sizes.
No directory scanning, per-write fstat, heap allocation, content duplication,
SQLite transaction, global file registry or mutex around disk I/O is needed.
The fstat calls in this artifact only verify the completed phases.

## Correctness checks

All checks passed on real unlinked files:

- append, in-place overwrite, exact aggregate cap and rejected growth;
- successful shrink releasing space another file can immediately use;
- sparse write charging the hole, zero-length write and offset overflow;
- actual kernel partial pwrite (10 bytes out of 16) and subsequent EFBIG;
- failed ftruncate through an injected invalid descriptor keeping the charge;
- final close returning all charges to zero;
- eight simultaneous writers sharing a 64 KiB cap: exactly four 16 KiB chunks
  were admitted, all held until the fixture verified total charge at the cap,
  then all owners closed and returned the counter to zero.

The partial-write fixture briefly lowers only its subprocess RLIMIT_FSIZE to
10 bytes and ignores SIGXFSZ there, then restores the prior limit. It does not
fill the user's filesystem. This is a real partial write/EFBIG case, not a disk-
full proof. The first development attempt used /dev/fd to obtain a read-only
view; macOS preserved writable descriptor behavior. That invalid test assumption
was replaced by explicit EBADF injection before the recorded passing runs.

## Comparative I/O measurements

Five fresh-process repetitions per case; writer populations rotate and accounting
order reverses across repetitions. Each case writes 128 MiB total in 16 KiB
chunks, with 1, 2 or 8 owners and one scratch file per owner. Baseline and counted
paths use the same file-size bookkeeping and pwrite boundary; the baseline skips
shared-budget reservation/refund. Start is synchronized. Timing includes final
file cleanup and worker joins; file creation precedes timing in both paths.

| Writers | Wall median without / with accounting, ms | CPU median without / with, ms |
| --- | ---: | ---: |
| 1 | 129.89 / 115.81 | 85.23 / 82.38 |
| 2 | 162.19 / 123.27 | 138.24 / 145.34 |
| 8 | 120.09 / 135.35 | 552.46 / 523.94 |

Wall times were noisy: individual results ranged from 77.81 to 348.72 ms across
cases. The eight-writer median was about 13% slower with accounting while its
CPU median was lower; two writers had about 5% higher CPU but lower wall time.
These five repetitions per case do not isolate a reliable percentage overhead
or establish performance equivalence. Lower times with accounting are not a
speedup claim. They show no consistent penalty across concurrency points and
no result that currently justifies a more complicated counter design.

Reported lifetime process physical high-water ranged below 1.13 MiB across both
paths; worker buffers and native runtime overhead dominate that whole-process
measurement. It cannot resolve an 8-byte/file increment. Exact state size is the
stronger memory evidence: 1,000 logical-size counters need 8,000 bytes, plus the
shared 16 bytes, with alignment of their containing records accounted separately.
The implementation adds no resident growth with bytes written.

## Recommendation and limits

Keep this simple accounting shape as the logical-byte policy candidate. Do not
add per-owner caches of credits, batching or another accounting service without
actual integration evidence of contention. Its cost is fixed bookkeeping at the
existing write boundary, not a pass over file contents.

The proposed logical-byte basis is not accepted merely because the prototype
passes. It charges sparse holes and does not model filesystem block rounding,
compression, clones, metadata, kernel buffers or filesystem cache. Actual volume
exhaustion remains independent of the configured cap. Real Host output-owner
integration, descriptor lifetimes, pending I/O, storage faults, cancellation,
quota changes and replay/commit semantics are outside this narrow fixture.
Checks verify syscall results, sizes and charges, not every payload byte.
The 8 GiB default is already accepted; numeric test caps/chunks are not new
product constants. No production code or normative policy changed here.
