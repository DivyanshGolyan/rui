# Throwaway observation batching experiment

Measured 2026-09-09 on the available Mac. Run `python3 research/observation-batch-prototype/bench.py` from the repository root. Python standard library only; temporary SQLite files and Unix socket are removed after execution. A child process serves requests over one persistent connection. No production code or live provider is used.

Question: does an observation batch help because of SQL query count or because of caller/core round trips?

The fixture has 100,000 rows indexed by integer primary key. Each mode performs exactly N indexed SELECTs per refresh and returns identical IDs/status values (asserted). Compare in-process queries, N sequential JSON requests over a persistent Unix socket, and one JSON request carrying N IDs. All use SQLite autocommit reads; batching does not add a snapshot transaction. There are three warmup rounds and 20 recorded rounds with rotated mode order. Source and raw results accompany this note.

| IDs per refresh | Local queries, median ms | Individual socket calls, median ms | One socket batch, median ms |
| --- | ---: | ---: | ---: |
| 1 | 0.0103 | 0.0357 | 0.0318 |
| 16 | 0.0981 | 0.4590 | 0.1285 |
| 64 | 0.3715 | 1.7561 | 0.4167 |
| 256 | 1.4887 | 6.9044 | 1.5923 |

Batching reduces encoding/dispatch/IPC overhead while retaining the same number of SQL queries. Individual reads remain small in absolute terms in this fixture. This supports keeping simple indexed SQLite reads and considering a bounded batch API for callers naturally observing many requests; it does not establish that production needs the endpoint.

Limits: Python and newline-delimited JSON, not Zig/HTTP; hot small status records, no concurrent writes, no large result bodies, one client, no mixed control workload, only 20 samples per cell. Maximum sample time is not a worst-case guarantee. The experiment does not measure query plans over OnePage's relational schema, sustained load or Linux behavior. No universal batch limit or production latency budget is selected.

[SQLite's guidance](https://www.sqlite.org/np1queryprob.html) explains why many small in-process queries need not have the client/server N+1 penalty. Our comparison isolates a separate process boundary where batching can save round trips. A batch need not promise an atomic snapshot or use a single SQL statement.
