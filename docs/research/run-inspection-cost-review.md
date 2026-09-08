# Run inspection cost review

Publication note, 8 September 2026: subsequent [inspection ownership resolution](../adr/0024-capture-run-inspection-before-delivery.md#v1-ownership-resolution--8-september-2026) retained the single Storage Owner and complete capture without an elapsed-time abort. Questions below describe the research stage; measurements remain synthetic evidence, not production qualification.

Research, 7 September 2026. This note informs [Choose SQLite storage and command-work limits](https://github.com/DivyanshGolyan/onepage/issues/95); it makes no contract decision and selects no timeout. No production benchmark was run.

Follow-up: the [field-to-fact trace](run-inspection-field-trace.md) and [native query-cost experiment](../../research/run-inspection-query-cost/README.md) now separate resolved-history access, current unresolved fanout and report size. The current-fact index kept measured SQL work unchanged when 900,000 resolved Operations were added; the general per-Turn index alone scanned that history. Current unresolved work can still increase query cost even for a small answer. These remain scratch-schema findings, not production qualification or a selected inspection policy.

## Finding

Investigate query and report shape before selecting a timeout policy. A large database does not by itself justify slow status reads. Distinguish a small current-state answer from the complete inventory that OnePage currently promises. A complete inventory necessarily processes its returned members and encoded bytes; avoidable history scans, irrelevant fields and poor encoding can add much more work. This is a design hypothesis to investigate, not an established production bug.

[ARCHITECTURE.md](../../ARCHITECTURE.md#run-interface) requires every Run–Turn membership summary, including terminal categories, and every actionable Permission Request. Categories derive from current committed facts; history reads are separate and do not replay history on every poll. [ADR-0024](../adr/0024-capture-run-inspection-before-delivery.md) uses one read transaction on the sole Storage Owner connection and writes the report to scratch before releasing that owner. Therefore encoding and scratch-write time also delay database commands. Client delivery happens afterward and retains no database resources. Large variable content already remains separate immutable references.

## Inputs to latency

| Input varied independently | Why it matters | Interpretation to test |
|---|---|---|
| Returned memberships and actionable permissions | More required entries must be read and encoded | Necessary complete-inventory cost |
| Historical Operations, Attempts and content, with current facts and returned memberships fixed | Unnecessary replay or scans can grow despite an unchanged answer | Avoidable query/data-design cost if observed |
| Unrelated Runs | A missing Run-scoped access path can examine irrelevant rows | Verify indexes and query plans |
| Encoded fields, lengths and escaping | More bytes and CPU work before capture ends | Keep the report narrow and encoding incremental |
| Query access paths and repeated work | Scans, sorts, joins or repeated statement preparation may add cost | Measure real statements rather than query count alone |
| Cache state and scratch service | Physical I/O or slow writes increase time | Test representative cache and storage conditions |
| Polling frequency and competing ready work | Queue wait is separate from one capture's execution | Measure complete command latency and fairness |

These are analytical factors, not measured OnePage production regressions. SQLite documents indexed retrieval, covering indexes and sort avoidance; indexes remove irrelevant search work but do not eliminate the output of matching rows. [SQLite query planning](https://www.sqlite.org/queryplanner.html).

## What the existing experiment proves

The [inspection latency fixture](../../research/matklad-experiments/inspection-latency/README.md) uses precomputed status and an indexed membership/Turn join. Its [query](../../research/matklad-experiments/inspection-latency/probe.c) asserts no full-scan steps or sorts. It does not implement real status derivation. Ordinary 100,000-record output is 55.04 MB; the wide case is 301.44 MB, using deliberately escape-heavy synthetic strings. For ordinary 100,000 records, buffered encoding reduced modeled control acknowledgement from 848.46 ms to 161.94 ms without changing the ownership architecture. These are medians from synthetic owner scheduling, not production control latency or a justified report size. The experiment establishes sensitivity to encoding and bytes; it does not establish that Run history makes status intrinsically expensive.

## Useful PlanetScale posts

- [Problem solving with PlanetScale Insights](https://planetscale.com/blog/problem-solving-with-insights) distinguishes rows read from rows returned, query latency from traffic volume, and index problems from schema/application design problems. Apply that diagnostic order before choosing a resource policy.
- [Query performance analysis with Insights](https://planetscale.com/blog/query-performance-analysis-with-insights) gives a concrete example: deleting only 500 matching records still approached scanning a table above 100 million rows as matching records became sparse. An appropriate index fixed it. A batch size is not a bound on examined work.
- [Egress problems and where to find them](https://planetscale.com/blog/database-egress) recommends fetching fewer unnecessary bytes and reducing unnecessary repetition. OnePage has no remote SQLite round trip or cloud egress bill; the transferable concern is report projection, encoding, scratch volume and polling frequency.
- [When the Postgres query planner goes rogue](https://planetscale.com/blog/when-the-postgres-query-planner-goes-rogue) treats blocking a harmful query as temporary containment, followed by execution-plan investigation and a query/index/statistics fix. Its Postgres incident does not establish SQLite behavior, but reinforces separating containment from root-cause design.
- [On benchmarking](https://planetscale.com/blog/on-benchmarking) calls for realistic workload shape, cache conditions, latency distributions, configuration disclosure and checking the harness itself. A synthetic report's byte distribution must not silently become a product workload assumption.

PlanetScale's [N+1 post](https://planetscale.com/blog/what-is-n-1-query-problem-and-how-to-solve-it) emphasizes network round trips. SQLite explicitly explains that many small in-process queries can be efficient: [Many Small Queries Are Efficient In SQLite](https://www.sqlite.org/np1queryprob.html). Inspect repeated scans and measured execution cost; do not rewrite clear local SQLite queries merely to minimize statement count.

## Next evidence needed for the decision

1. Trace every required summary field to the exact current facts needed. Identify any unnecessary historical traversal or content fetch, without silently narrowing the accepted report.
2. Compare fixed returned membership/current-fact counts with growing history/content and unrelated Runs; separately grow returned membership counts while holding per-member history fixed.
3. Record query plans, full-scan and sort counters, VM work, rows emitted, encoded bytes, query/derivation time, encoding time, scratch-write time and owner queue delay. SQLite provides [EXPLAIN QUERY PLAN](https://www.sqlite.org/eqp.html) and [statement status counters](https://www.sqlite.org/c3ref/c_stmtstatus_counter.html); VM steps are a work indicator, not a clock deadline.
4. Use plausible narrow fields alongside adversarial width/escaping. Measure cold and warm behavior, repeated polling and ready control/settlement service. Treat synthetic results as design evidence until the actual endpoint exists.

If latency grows mainly with history that the answer does not need, fix the access path or representation. If it grows mainly with required output, decide whether the caller needs the entire inventory on every status observation. That latter choice changes product/API scope and requires human agreement; neither a summary endpoint nor pagination is selected here. Only then revisit whether residual capture cost warrants an abort policy or ownership change.
