# Published waiting-agent memory benchmark

This page records the Linux model-wait benchmark in [Rui: a hundred agents in 2.5 MB](https://divyanshgolyan.com/posts/hundred-agents/).
It does not report a new run or a performance improvement in the current release.
To try Rui, return to [Install](../README.md#install) and [Run your first swarm](../README.md#run-your-first-swarm).

## Reported measurements

The values are private memory in MB, summed across all processes each harness starts.
Each value is the median of three runs.
These are not RSS measurements.
RSS counts shared program code in each process, which can inflate comparisons with harnesses that start one process per agent.

| Harness | 0 waiting agents | 1 | 10 | 100 |
| --- | ---: | ---: | ---: | ---: |
| Rui | 1.7 | 2.2 | 2.2 | 2.5 |
| pi | 85.6 | 93.6 | 97.5 | 112.4 |
| fx | 0 | 1.3 | 12.7 | 127.2 |
| Codex app-server | 14.7 | 25.5 | 49.6 | 206.5 |
| OpenCode | 174.2 | 529.8 | 556.7 | 650.7 |

fx starts no process at zero agents.
The [README chart](assets/waiting-agent-memory.svg) plots these four measured populations on linear axes.
Connecting lines join measurements and do not add measurements between them.

## Reported method and versions

The article reports measurements on a 4-core Linux cloud machine on 30 October 2026.
A fake model accepts requests and never answers, so each agent waits with an open model request.
Rui uses TLS and HTTP/2 in this test.
The other harnesses use plain HTTP.
Rui's requests carry one Bash tool, while the others carry 4 to 15 tools.
The feature sets are unequal.

The article identifies these builds:

| Harness | Revision or version |
| --- | --- |
| Rui | [50149807908283e044e3573f1b251d6a2f21e854](https://github.com/DivyanshGolyan/rui/commit/50149807908283e044e3573f1b251d6a2f21e854) |
| pi | SDK 1.4.0, all agents in one Node process |
| fx | 0.0.14, release-style build |
| Codex app-server | 0.164.0 |
| OpenCode | 1.19.4 |

## Scope and limitations

The measurements describe waiting for this fake model on that machine at those versions.
They do not establish memory costs for other models, providers, commands, or arbitrary active workloads.
Bash processes, real model output, request contents, and other workload differences can change memory use.
The results do not imply zero memory growth or a fixed few-KB cost for every agent.

The article's 10,000-agent estimate is a projection, not a measurement.
The README and chart omit it.
The article does not link raw datasets or reproduction scripts, and this documentation does not claim to reproduce the benchmark.
The published article and pinned Rui revision above are the sources for this report.
