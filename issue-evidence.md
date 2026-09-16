## Experiment evidence — decision remains open

Reran the existing native inspection probes at revision `02a0382`, then repeated the key capture/control-marker cases sequentially on this Mac (three runs each; eight complete captures per run). A real SQLite commit stands in for a control ready at the beginning of capture; this does not execute the redesigned Host or Session stop.

Sequential observed time until the control-marker commit:

- 100000-wide: 691.0–707.2 ms; median 695.4 ms.
- 100000-small: 149.8–151.6 ms; median 149.8 ms.
- 10000-small: 15.3–19.7 ms; median 15.4 ms.
- 10000-slow-scratch: 174.9–176.0 ms; median 175.7 ms.
- 1000-small: 2.2–3.8 ms; median 2.2 ms.

All 120 sequential captures completed with the expected row counts and no aborts. The original probe runner also passed its complete-report framing/content oracle and expected-failure checks. The separate larger capture sweep completed, but overlapped the first scheduling sweep; do not treat those timings as isolated benchmarks. The sequential repeat above removes that overlap; other machine activity remains uncontrolled.

The slow-scratch case injects 1 ms per 100-row batch. Wide rows use 1,024-byte escape-heavy synthetic fields, not 1,024-byte Session references. This is synthetic query/encoding/scratch cost with old membership schema and DELETE-journal control-marker commits, not current API completeness, real cancellation latency, whole-Host p95, Linux or production qualification. Three samples are not tail-latency qualification.

Evidence and exact sequential driver remain local in `/tmp/latifa-report-latency-20260913/`: `sequential-results.json`, `recheck.py`, `capture-sweep.json`, and the original probe's refreshed `results.json`. No contract or production changes.

Recommendation for discussion: retain complete reports for now. These results establish size/stall sensitivity, but do not justify public pagination or a new summary operation by themselves. Integrated capture/import/control qualification remains required; the user has not yet accepted a resolution.
