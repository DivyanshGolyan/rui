# Run inspection query-cost experiment

Publication note, 8 September 2026: the [subsequent ownership resolution](../../docs/adr/0024-capture-run-inspection-before-delivery.md#v1-ownership-resolution--8-september-2026) retained complete capture on the single Storage Owner. The design questions below record the experiment stage.

Measured 7 September 2026 on an Apple M1 Pro with 16 GiB RAM. This is a throwaway
native SQLite experiment, not the production Host, selected SQL schema, complete
classifier or public report format. It informs
[Choose SQLite storage and command-work limits](https://github.com/DivyanshGolyan/onepage/issues/95).

## Question and answer

Does a larger history inherently make current Run inspection expensive, or does
the expense depend on query shape, current unresolved work and returned output?

The tested current-fact access path avoided work proportional to resolved history.
For 18 returned Turn summaries, adding 900,000 resolved Operations left the measured
SQL work unchanged at 1,193 VM steps. Using only a general per-Turn index for the
same facts instead required 9,001,277 steps. Both paths reported zero full-table-scan
steps: scanning irrelevant history through an index is still expensive.

This does not establish that inspection is proportional only to its output.
One ready Turn with 100,000 unresolved Operations returned the same 126 bytes as
the one-Operation case, but this deliberately simple query inspected those
Operations to rule out in-flight work and enumerate permissions. That increased
work from 94 to 2,100,073 VM steps. Current-fact predicates also need examination.

Larger complete reports have their own cost. The 100,000-member case returned
22,222 permissions and about 10.12 MB, taking a 283.849 ms median capture. This
is a synthetic sensitivity point, not a production latency promise or a reason
to impose a timeout, membership quota or public pagination.

## What was modeled

The [field trace](../../docs/research/run-inspection-field-trace.md) identifies
canonical consumers and incomplete parts of the fixture. This experiment models:

- Run revision and Run-scoped, uniquely bound Turn memberships;
- terminal Turn outcome precedence;
- unresolved Operation current admission and future retry facts;
- exact unanswered Permission Requests, a granted request, and an independently
  executable sibling alongside a waiting permission;
- resolved historical Operations with retained admission provenance, decided
  historical permissions and separately stored content;
- unrelated Run membership and independently increasing current pending fanout.

Every generated nonterminal Operation has no additional sequencing prerequisite
beyond its specified permission/admission facts. Therefore the small query's
progress predicate is valid only for these cases. Permission denial, Session-stop
applicability, Run cancellation propagation, Tool Result publication and broader
model/tool sequencing are not modeled. They must use the real shared classifier.
An allowed request is used for the authorized-but-unstarted case; there is no
transient denied-but-unresolved assumption.

Here a **member** is one distinct bound Turn with one corresponding membership.
The fixture has no repeated keyed admissions to the same Turn. It does not select
how the public API groups or repeats such admissions. Integer reference values
are narrow stand-ins; their bodies, complete provenance and wire spellings are
not selected or verified. Terminal result references are fixture placeholders.

At most 100 fixture Operations carry current admitted-execution facts. Remaining
in-flight categories in large membership sweeps use retry waiting. Admitted/retry
cases have one unresolved Operation; fanout increases unadmitted ready or
permission-waiting siblings. There are no real external effects or Active Credits.
These populations are sensitivity inputs, not recommended workload limits.

## Method

`run.py` extracts the SQLite package pinned by `build.zig.zon`, compiles it with
the repository's `configureSqlite` macros and links `probe.c` with `cc -O2`.
The scratch connection uses DELETE/EXTRA, a 64 KiB suggested cache, explicit spill,
no mmap, file-backed temporary storage and no busy wait. These settings match the
starting experiment shape; this work selects no numeric SQLite memory policy.

Thirteen databases are seeded in fixed-seed shuffled order. For each database,
three fresh processes per mode each make three observations: query-only and
capture-to-scratch. This gives 234 observations, including 117 encoded captures.
Mode order alternates between repetitions. Each fresh process starts with a fresh
SQLite connection; later passes reuse it. Filesystem caches are not purged and
seeding warms them. The shared laptop is not an isolated latency test machine.

Every capture uses one read transaction, private keyset batches of 100 membership
summaries and reused per-Turn permission queries. Output flows through a fixed
64 KiB byte window to `tmpfile()` scratch. Statements and the read transaction end
before a small durable revision update models a control that was ready at capture
start. This is an owner-wait marker, not actual server acknowledgement, stop
propagation, cancellation dispatch or physical cleanup. File delivery is outside
the measured capture and retains no SQLite resources.

The general index is `(turn_id,id)`. The additional candidate index has the same
keys and `WHERE resolution IS NULL`. Both read the same canonical Operation rows;
neither stores a lifecycle category or adds semantic authority. The diagnostic
control omits only the partial index. Query plans and VM steps, rather than
full-scan counters alone, establish what work was avoided. Index maintenance,
write latency and the full production schema's costs are not measured.

Timers separately observe `sqlite3_step`, fixed-row formatting and scratch writes.
VM counters cover summary and permission statements, excluding the fixed header
lookup and subsequent control update.
They are partial, instrumented measurements: statement preparation, copies,
classification assertions, clock overhead and transaction setup also contribute
to total capture time. Scratch writes do not fsync disposable report files, and
filesystem cache/device costs are not comprehensively measured. SQLite high-water
is not whole-process or Host memory. The harness validates every emitted category,
member order and permission count; it independently parses a small delivered
report and checks its terminal completeness record. No production fault-injection
or power-loss guarantee is established.

## Results

Times are medians of nine encoded captures per case. See raw observations for
fresh/reused-connection labels and observed ranges; these are not p95/p99 claims.

| Case | Members | Permissions | Report bytes | SQL VM steps | Capture ms |
|---|---:|---:|---:|---:|---:|
| Baseline | 18 | 4 | 1,616 | 1,193 | 0.274 |
| 18,000 resolved historical Operations | 18 | 4 | 1,655 | 1,193 | 0.274 |
| 900,000 resolved historical Operations | 18 | 4 | 1,673 | 1,193 | 0.336 |
| Same 900,000, general index only | 18 | 4 | 1,673 | 9,001,277 | 117.286 |
| 100,000 unrelated Turns | 18 | 4 | 1,616 | 1,198 | 0.268 |
| 18,000 historical contents widened to 4 KiB | 18 | 4 | 1,655 | 1,193 | 0.272 |
| 1,000 members, ten old Operations each | 1,000 | 222 | 93,221 | 65,177 | 2.444 |
| 10,000 members, ten old Operations each | 10,000 | 2,222 | 971,706 | 655,257 | 25.127 |
| 100,000 members, ten old Operations each | 100,000 | 22,222 | 10,116,520 | 6,556,057 | 283.849 |
| Pending fanout 1,000 | 18 | 4,000 | 237,416 | 334,859 | 7.132 |
| Pending fanout 10,000 | 18 | 40,000 | 2,481,417 | 3,340,859 | 123.034 |
| One ready Operation | 1 | 0 | 126 | 94 | 0.214 |
| 100,000 ready Operations | 1 | 0 | 126 | 2,100,073 | 17.656 |

Reference IDs use decimal fixture identities, so adding history slightly changes
reference widths even when membership counts/classifications stay fixed.
The wide-content database was about 84.23 MB versus 1.99 MB for the matching
32-byte-content history case; inspection did not read those bodies. The 900,000
history cases used about 108.1 MB. These are database-size sensitivity points,
not disk-growth or cache-cold qualification.

## Decision implications

The data model need not be fully frozen before choosing whether elapsed time may
make complete inspection unavailable. That is a behavior decision. The supporting
query paths and ownership still need evidence against the responsiveness target.

This experiment supports avoiding resolved-history traversal through ordinary
indexes over current facts. It does not justify a wholesale model redesign,
new materialized phase, timeout or quota. It also exposes a remaining query-design
question: efficiently finding current actionable/progress facts without scanning
large irrelevant unresolved populations.

If tracked separately, the focused question is **which inspection query paths and
read ownership preserve complete reports while meeting control responsiveness?**
It should preserve exact authority, membership and permission semantics; measure
the full classifier and duplicate-admission cases; test representative report
fields and sustained polling; and evaluate changes only where work remains costly.
It is a design/evidence decision, not a speculative implementation slice or a
requirement to finish the entire database schema first.

No elapsed-time abort, new reader, journal change or narrowed status response was
selected by these measurements. Complete report availability and non-preemptive
read ownership cannot together imply a fixed worst-case control deadline for
arbitrarily large output. The accepted responsiveness target remains a workload
qualification target, with capture time included.

## Reproduction and evidence

```sh
python3 research/run-inspection-query-cost/run.py
```

The runner uses disposable databases outside the repository and removes them on
exit. Build products and extracted SQLite source live in ignored `generated/`.
New measurements are written to `generated/reproduction/` by default; use
`--output-dir PATH` to select another destination. Checked-in measurements remain
the original 7 September evidence. The published runner differs from its recorded
hash only in output routing and argument parsing.

Raw measurements record compiler/platform, dependency macros, source commit and
hashes of the experiment and local contract files. The local contract had other
uncommitted accepted amendments; its hash is not a claim that HEAD contains them.
The recorded architecture hash also predates this session's subsequent accepted
Q1 paragraph rejecting a database-size quota and admission reserve, and the later
inspection decision-ownership links. Neither amendment changes an inspection
predicate or experiment source.

- [Probe](probe.c)
- [Runner](run.py)
- [Raw measurements and provenance](results.json)
- [Query plans](query-plans.txt)
- [Field-to-fact trace](../../docs/research/run-inspection-field-trace.md)
- [External research](../../docs/research/run-inspection-cost-review.md)
