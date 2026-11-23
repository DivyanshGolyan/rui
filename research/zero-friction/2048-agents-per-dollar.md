# #2048 Agents per dollar on small paid boxes

Researched 2026-11-23. Prices and sizes were read from vendor pages that day (sources at the end).
Every agent count below is **arithmetic on Rui's published waiting-agent benchmark**, not a new measurement.
Labels: **[read]** = read in a primary source; **[calc]** = arithmetic from read figures; **[est]** = estimate or inference; **[unverified]** = not checked against a primary source.

## Answer

On every small box, Rui's resident memory never sets the agent limit. CPU, file descriptors and provider rate limits set it first (at 8 KB per extra waiting agent, a 1 GB box fits about 85,000 agents by memory alone). For comparison, a 1 GB box fits about 2,300 pi agents, about 350 Codex app-server agents, about 140 OpenCode agents and 0 to 1 Claude Agent SDK agents.
The box price only matters when agents spend most of their time **waiting** (on people, events or long model streams), for example persistent per-user or per-channel agents, or a VPS or Railway service that holds many sessions open.
For busy coding agents, token spend is one or more orders of magnitude above box spend. Anthropic says this about its own SDK [read: Agent SDK hosting, "Cost"]. So a lower memory ratio barely moves those bills.

## Inputs

### Memory per harness (private MB, Linux, waiting on a never-answering fake model) [read: docs/waiting-agent-memory.md]

| Harness | 0 | 1 | 10 | 100 | Base (MB) | Marginal per agent, 1→100 [calc] |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Rui | 1.7 | 2.2 | 2.2 | 2.5 | 1.7 | ~0.003 MB (0.3 MB over 99 agents); 0→100 average 8 KB |
| pi (one Node process) | 85.6 | 93.6 | 97.5 | 112.4 | 85.6 | 0.19 MB (0→100 average 0.27) |
| Codex app-server | 14.7 | 25.5 | 49.6 | 206.5 | 14.7 | 1.83 MB (0→100 average 1.92) |
| OpenCode | 174.2 | 529.8 | 556.7 | 650.7 | ~530 after first agent | 1.22 MB after the first agent |
| Claude Agent SDK | — | — | — | — | — | One `claude` subprocess per session [read] |

The fits below use **base + 100-agent average × N** (conservative for pi, Codex and OpenCode, since their 1→100 slope is lower). For OpenCode they use 530 MB + 1.22 MB × N.
Beyond 100 agents every figure is a **linear projection** [est]; the benchmark measured only up to 100.

**Claude Agent SDK per-agent memory [read, labelled]:**
- Anthropic: "One agent session maps to one subprocess. Running N concurrent sessions takes N subprocesses." Sizing guide: "1 GiB RAM, 5 GiB disk, and 1 CPU per agent is a reasonable starting point", and "a floor, not the ceiling" [read: code.claude.com/docs/en/agent-sdk/hosting].
- User report anthropics/claude-code#61425 (v2.1.148, Linux, May 2026): `ps` shows 363 MiB and 487 MiB RSS for two idle CLI instances (the title says ~700 MB). The issue was closed as stale [read]. RSS counts the shared binary pages, so private memory per extra process is somewhat lower [est].
- This report uses **1 GiB (vendor sizing)** and **~0.4 GB (observed RSS, optimistic)** as the two bounds.

**Codex SDK (TypeScript):** "It spawns the CLI and exchanges JSONL events over stdin/stdout" [read: openai/codex sdk/typescript README]. So it is one `codex` process per running thread. The Python SDK "controls the local Codex app-server over JSON-RPC" [read: Codex SDK docs]. The per-process cost of `codex exec` was not measured. A rough guess is the app-server's 1-agent figure (~25 MB per process) [est]. The tables use the app-server figures.

**Rui CPU:** ~3–4 ms of one core per model call [memory note, not a published figure]. At 3.5 ms, one full core handles ~285 model calls/s. At one call per agent every 10 s, that is ~2,850 agents per core [calc/est]. On a 1/16-vCPU slice, it is ~18 calls/s, or ~180 agents at that call rate [calc/est].

## Box prices and sizes [read 2026-11-23]

| Box | Price | vCPU | RAM | Disk |
| --- | --- | ---: | ---: | ---: |
| GitHub Actions standard Linux, private repo (ubuntu-latest x64) | $0.006/min ($0.36/h); arm64 $0.005/min | 2 | 8 GB | 14 GB |
| GitHub Actions standard Linux, public repo | free (standard runners) | 4 | 16 GB | 14 GB |
| Hetzner CPX02 (Regular Performance, HEL1) | €5.49/mo excl. VAT (FSN1/NBG1 €6.49) | 1 | 1 GB | 20 GB |
| Hetzner Cost-Optimized | from €5.99, marked "Currently not available" | — | — | — |
| DigitalOcean Basic | $4/mo · $6/mo | 1 | 512 MiB · 1 GiB | 10 · 25 GiB |
| Cloudflare Container `lite` | $5/mo Workers Paid + $0.0000025/GiB-s memory (≈$1.62/mo always-on) + disk ≈$0.36/mo + active CPU $0.00002/vCPU-s [calc] | 1/16 | 256 MiB | 2 GB |
| Cloudflare Container `basic` | ≈$6.48/mo memory + ≈$0.73/mo disk + CPU [calc] | 1/4 | 1 GiB | 4 GB |
| Cloudflare Durable Object | $12.50 per million GB-s; billed for 128 MB per object "regardless of actual usage"; 400k GB-s included. An always-awake object costs ≈$4.05/mo [calc] | — | 128 MB isolate cap | 10 GB SQLite/object |
| Fly.io shared-cpu-1x (iad/ewr) | $2.19 (256 MB) · $3.69 (512 MB) · $6.70 (1 GB); extra RAM $6/GB/mo | 1 shared | 256 MB–1 GB | volume extra |
| Railway Hobby | $5/mo incl. $5 usage; $10/GB-month RAM, $20/vCPU-month, billed on usage | ≤48 | ≤48 GB | — |

GitHub's free plan minutes for private repos were not read [unverified].

## Waiting agents that fit, by memory [calc/est]

The tables assume an OS reserve of ~300 MB on a VM, ~500 MB on a runner and ~50 MB in a container [est].

| Box (usable MB) | Rui | pi | Codex app-server | OpenCode | Claude Agent SDK (1 GiB / 0.4 GB) | Binding limit |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| GH Actions private, 8 GB (~7,500) | memory not binding (~940k projected) | ~27,600 | ~3,900 | ~5,700 | 7 / ~18 (disk guidance 5 GiB/agent → 2) | Rui: 2 cores, fds, provider limits. Claude: RAM/disk. 6 h job cap [unverified] |
| Hetzner CPX02 / DO $6, 1 GB (~700) | not binding (~87k) | ~2,290 | ~357 | ~140 | 0 / 1 | Rui: 1 shared core (~2,850 agents at 1 call/10 s), fds. Others: RAM |
| DO $4, 512 MiB (~230) | not binding (~28k) | ~540 | ~112 | 0 (first agent ~530 MB) | 0 / 0 | Others: RAM |
| CF Container lite, 256 MiB (~200) | not binding (~24k) | ~430 | ~96 | 0 | 0 / 0 | Rui: 1/16 vCPU (~180 agents at 1 call/10 s), 2 GB disk |
| CF Container basic, 1 GiB (~970) | not binding | ~3,300 | ~500 | ~360 | 0 / 2 | Rui: 1/4 vCPU (~700 agents at 1 call/10 s) |
| Fly shared-cpu-1x 256 MB / 1 GB | same as CF lite / 1 GB VM | | | | | shared-CPU baseline [unverified] |
| Railway (pay per GB-month) | ~$0.00008/agent-mo | ~$0.0027 | ~$0.019 | ~$0.012 (+$5.30 base) | ~$4–10/agent-mo | Memory is billed directly, so the ratio *is* the bill |

**Durable Objects:** Rui is a native binary and does not run in a DO isolate. Cloudflare lists pi, OpenCode and Flue as harnesses that run in Durable Objects, and Claude Code and Codex as running in Containers driven by a DO [read: developers.cloudflare.com/agents/harnesses]. A DO is billed for 128 MB whatever it uses, so with one agent per object harness memory does not change the bill. It matters only when many agents are packed into one object under the 128 MB cap. The DO-port memory of pi and OpenCode was not measured; the benchmark was Node and Bun on Linux.

Per dollar [calc]: on the private Actions runner ($0.36/h), Claude SDK costs ≈$0.05/agent-hour. pi costs ≈$0.000013, Codex ≈$0.00009 and OpenCode ≈$0.00006 per agent-hour if the box is filled. On a €5.49 VPS, OpenCode costs ≈€0.04/agent-month and Codex ≈€0.015. Claude SDK does not fit at vendor sizing.

## Limits other than memory

- **Disk:** Anthropic advises 5 GiB per Claude SDK agent [read]. That caps a 14 GB Actions runner at 2 and a 2 GB CF lite container at 0. The other harnesses' transcripts and workdirs were not sized [unverified].
- **File descriptors:** Each in-flight HTTP/1.1 request holds a socket. A per-process harness also holds 3+ stdio fds per child. Rui's HTTP/2 multiplexing shares connections (repo research/transport-memory: 1,000 streams on one connection) [read]. The common Linux default soft `nofile` of 1024 for services (systemd) is an assumption from prior knowledge [unverified]. Below ~1,000 agents it caps any harness that opens a socket per waiting request, unless it is raised. Actions runner ulimit [unverified].
- **Workers connections:** six simultaneous connections waiting for response headers per invocation [read]. A streaming model call frees its slot once headers arrive.
- **DO CPU:** 30 s per request by default, up to 5 min [read].

## Who would notice (named, with evidence)

- **anthropics/claude-code-action** runs Claude Code "entirely on your own GitHub runner", and its usage example uses `runs-on: ubuntu-latest` [read]. **openai/codex-action** also uses `runs-on: ubuntu-latest` [read]. Each job is one agent on one runner, so the runner minute, not memory, is the cost unit. The token bill dominates [read: Anthropic hosting "Cost": ~$0.05/h container vs "dollars in tokens"]. A lower memory ratio changes their bill only if many agents share one job. **Verdict: unlikely to notice.**
- **Cloudflare Agents harnesses:** Claude Code and Codex run in Containers driven by a DO, and pi and OpenCode run in DOs [read]. Container memory is billed by provisioned instance type, so a 1 GiB-per-agent harness pays for `basic` or larger per agent, while a few-MB harness could share one `lite`. **Verdict: would notice for idle or long-lived agents.**
- **Claude Agent SDK "long-running" and "multi-agent container" patterns** (email triage, Slack bots, per-user sites) [read]. These hold idle subprocesses at ≥1 GiB each, so box RAM is the real cost while tokens are near zero. **Verdict: the clearest case.**
- **Railway or VPS self-hosters** of OpenCode or Codex app-server: Railway bills used GB-month directly [read]. **Verdict: notices only at hundreds of idle agents.**
- Busy coding fleets (Codex cloud, Claude Code on the web, hosted sandboxes) mostly use larger sandboxes and are token-bound. **Verdict: not affected.** No primary evidence was read for their box sizes [unverified].

## Unverified / not done

- Linear extrapolation past 100 agents; the codex exec per-process cost; Claude Code private (not RSS) memory; pi and OpenCode memory inside Durable Objects.
- Rui's 3–4 ms CPU per call is a memory note, not published.
- Fly shared-CPU baseline, the Actions ulimit and job-time cap, GitHub free minutes, the systemd nofile default.
- No named product was found running *many* agents per small VPS or Fly or Railway machine. That gap was not searched exhaustively.

## Sources (read 2026-11-23)

- Rui benchmark: /home/user/rui/docs/waiting-agent-memory.md; transport: /home/user/rui/research/transport-memory/README.md
- https://docs.github.com/en/actions/reference/runners/github-hosted-runners · https://docs.github.com/en/billing/reference/actions-runner-pricing
- https://www.hetzner.com/cloud/regular-performance/ · https://www.hetzner.com/cloud/
- https://www.digitalocean.com/pricing/droplets
- https://developers.cloudflare.com/containers/pricing/ · https://developers.cloudflare.com/durable-objects/platform/pricing/ · https://developers.cloudflare.com/durable-objects/platform/limits/ · https://developers.cloudflare.com/workers/platform/limits/ · https://developers.cloudflare.com/agents/harnesses/ · https://developers.cloudflare.com/agents/harnesses/claude-code/
- https://docs.fly.io/about/pricing · https://docs.railway.com/reference/pricing/plans
- https://code.claude.com/docs/en/agent-sdk/hosting · https://github.com/anthropics/claude-code/issues/61425
- https://raw.githubusercontent.com/openai/codex/main/sdk/typescript/README.md · https://learn.chatgpt.com/docs/codex-sdk
- https://github.com/anthropics/claude-code-action (docs/usage.md) · https://github.com/openai/codex-action
