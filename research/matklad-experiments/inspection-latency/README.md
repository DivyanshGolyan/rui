# Inspection latency follow-up

> **Historical experiment published 6 September 2026.** The [publication notes](../PUBLICATION.md) distinguish measured fixture behavior from the current contract. `contract.md` is an unchanged historical ADR snapshot; its original relative links retain their source-document context.

This is a native sensitivity experiment against pinned SQLite, extending the existing single-connection and reactor-contention research. It is not the unimplemented inspection endpoint, real derived status queries, or a whole-Host latency measurement. The accepted [inspection contract](contract.md) keeps one complete read view on the sole Storage Owner connection; ready controls receive a turn before another capture. Current source-document hashes and commit are in [provenance](contract-provenance.json).

## Questions

- How much does escaping and encoder implementation affect capture time?
- Can inspection backlogs postpone a ready settlement even when a control receives its promised turn?
- What does a between-batch time/byte budget accomplish, and what does it break?
- Can complete reports be delivered after intervening writes without retaining SQLite resources?

## Method

The fixture derives from the existing `research/inspection-capture-proof/single_connection.c`. It uses an indexed Run membership/Turn join, precomputed status, 64 KiB SQLite cache, DELETE/EXTRA, mmap disabled, and the repository-pinned SQLite compilation macros. Each fresh process captures eight reports sequentially. Capture reads revision and all rows under one transaction, escapes strings into NDJSON and writes to immediately unlinked scratch. Large content remains represented by synthetic references. Row order/count, no full scans/sorts, stable revision, finalized statements and completed read transactions are asserted.

One control and one settlement are modeled as ready at the beginning of the first capture. Both commit a small revision update on the same connection. The control runs immediately after that capture. The settlement either runs just after the control, or waits until all eight reports finish. These are measured owner scheduling delays for already-ready work: no socket ingress, arrival thread, actual Session stop traversal, Completion import, or effect interruption occurs. The dispatch timestamp is only a synchronous post-commit marker. It must not be presented as actual interruption dispatch latency. The earlier reactor-contention experiment remains the evidence for that separate boundary.

Three repetitions per configuration run sequentially in fixed-seed shuffled order. Each uses a newly seeded database and a fresh process. Filesystem caches are not purged; no device latency or tail guarantee follows. The fixture's 128/1,024-byte binding fields repeat newline, quote, backslash and ordinary bytes to stress escaping. These are deliberately adversarial synthetic strings, not a proposed wire format or a typical transcript distribution.

The bytewise control uses per-byte locked stdio calls and `fprintf` for control escapes. The buffered version uses one bounded 8 KiB encoding array for each fixture field and one block write. Fields are bounded by the fixture to 1,024 bytes; the production encoder must handle arbitrary permitted strings through windows. Both keep memory independent of report population. The comparison isolates a mundane implementation cost before drawing architectural conclusions.

Private batches contain 10, 100 or 1,000 rows. Optional delays of 1 or 50 ms after each flushed batch emulate slow scratch service. They are explicit sleeps, not actual disk contention, ENOSPC, or kernel stalls. Experimental budgets check elapsed time or scratch position after a batch; exceeding one ends the transaction, closes/discards incomplete scratch, and yields to the control. No partial report is returned and no cursor or transaction survives the yield. A new attempt restarts from the beginning.

At most one previously completed report is retained during the next capture, and is then discarded as an abandoned delivery. The last complete report is read only after both mutation commits. This verifies bounded retained population and separation from SQLite lifetime, not slow-client backpressure or timed network delivery. Report bytes and aggregate logical scratch are recorded; physical disk allocation and filesystem-cache pressure are not measured. Footprint after churn is an endpoint, not peak RSS or whole-system memory. SQLite high-water includes the connection and its cache. Aborted scratch contributes to total attempted bytes.

## Measured results

72 fresh measurement processes completed: 36 per encoder, three repetitions per configuration, eight capture attempts per process (576 total). Times below are medians in milliseconds, not tail bounds. Memory stayed small even when capture delays were large.

| Case | Buffered control acknowledgement | Buffered settlement acknowledgement | Bytewise control acknowledgement |
|---|---:|---:|---:|
| 1,000 records | 2.58 | 2.97 | 9.86 |
| 10,000 records | 16.51 | 16.99 | 88.54 |
| 100,000 records | 161.94 | 162.29 | 848.46 |
| 100,000 wide records | 758.42 | 758.84 | 4561.31 |
| 10,000; settlement after eight reports | 15.62 | 132.02 | 84.17 |
| 10,000; 1 ms injected per batch | 178.23 | 179.24 | 256.60 |
| 100,000; experimental 10 ms abort budget | 11.19 | 11.66 | 11.32 |
| 1 ms stalls plus 10 ms abort budget | 11.01 | 11.44 | 12.40 |
| 50 ms stall plus 10 ms abort budget | 61.60 | 62.16 | 62.46 |
| Experimental 1 MiB abort budget | 4.14 | 4.57 | 18.10 |
| 10,000; batches of 10 | 26.98 | 27.46 | 94.73 |
| 10,000; batches of 1,000 | 14.48 | 14.84 | 87.12 |

Ordinary reports were 0.55 MB, 5.49 MB and 55.04 MB; wide reports were 301.44 MB. Holding the prior wide report during another capture reached **602.88 MB logical scratch**, despite a maximum SQLite heap high-water of **181,840 bytes**. Buffered process physical-footprint endpoints after churn ranged up to **1,557,248 bytes**. These exclude external filesystem-cache cost and do not prove whole-Host memory bounds.

The eight-attempt backlog delayed a ready settlement to 132.02 ms versus 16.99 ms when it received a turn after the first report in the matching baseline. Both configurations served the control after the first report. This shows the scheduling policy difference, without claiming a production starvation bug.

Every budgeted run aborted all eight captures: **no complete report** was produced. Time-budget cases normally yielded near 11 ms, while the injected 50 ms batch stall delayed acknowledgement to a 61.60 ms median. The 1 MiB quota overshot to 1,097,918 bytes because it is checked only after a batch. These are cooperative abort experiments, not strict deadline or disk-reservation enforcement.

The buffered run also exported one synthetic report to temporary storage and independently parsed every row in Python. Escaped strings round-tripped exactly; revision and terminal count matched; removing the terminal record failed the completeness oracle. Native assertions verified rollback/release on budget abort, delivery after both durable updates, exact ordered row counts, and absence of retained statements/read transactions. No fault injection for actual I/O errors or power loss was performed.

Raw evidence: [buffered results](results.json), [bytewise control results](bytewise-results.json), [buffered source](probe.c), [control source](bytewise-probe.c), [runner](run.py). Separate source copies preserve the exact control measured before the encoder improvement; they are disposable experimental fixtures, not proposed production modules.

## Interpretation

The same single-owner architecture can have very different capture delays depending on encoder and report width. Use fixed-buffer encoding before adding another reader or changing journaling. Smaller private batches improve the granularity of abort checks but do not make a successful complete capture preemptible.

Giving ready settlement/advancement work a bounded turn between captures prevents an inspection backlog from monopolizing the owner. This belongs in the existing Host driving loop, not a new scheduler subsystem. The experiment has one ready request of each class and a finite backlog; it does not establish sustained-load fairness or select a service quantum.

A time budget can bound cooperative work between observation points. It cannot interrupt a blocked write: a 50 ms injected stall exceeds a 10 ms budget before the check can execute. More fundamentally, repeated bounded attempts at an oversized report all fail. A byte quota has the same availability tradeoff. Neither is a compatible way to promise complete inspection of arbitrarily growing collections plus a strict maximum control delay on one nonpreemptive owner. Budgets remain an explicit behavior decision, not a selected 10 ms or 1 MiB product limit.

Keep the single-reader design pending real query/encoder measurements and an agreed responsiveness target. Specify fair turns for ordinary ready work as well as controls. If real complete reports exceed that target, decide explicitly whether inspection may fail for resource exhaustion, whether report work can be reduced without losing required facts, or whether snapshot/read ownership must change. This exercise does not justify selecting WAL, public pagination, a second reader, or a public snapshot service.

## Reproduction

```sh
python3 research/matklad-experiments/inspection-latency/run.py
# Slower encoder control:
python3 research/matklad-experiments/inspection-latency/run.py --bytewise
```

Requires macOS, Clang, Zig (to locate/fetch the pinned package), Python 3.12+. Generated binaries and extracted SQLite are ignored. Synthetic databases and scratch are temporary. No user transcripts, real Stores, providers or production source are touched.
