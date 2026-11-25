# GitHub pull request watcher invariants

These rows cover the watcher domain, GitHub transport and request pressure. Later rows join as the Host runner lands.

| Id | Level | Invariant | Seam | Owner test | Source |
| --- | --- | --- | --- | --- | --- |
| PRW-1 | Module | Only bounded, canonical GitHub.com pull request URLs are accepted. | `parseUrl` | `PRW-1 URL accepts only bounded unambiguous GitHub pull requests` | `src/github_pr_watch.zig` |
| PRW-2 | Module | A head race rejects the observation; only semantic snapshot changes are reported. | `reduce` | `PRW-2 typed observations reject head races and report only semantic changes` | `src/github_pr_watch.zig` |
| PRW-3 | Module | The latest observation for each check identity and status context determines the aggregate without treating missing or partial coverage as passing. | `reduce` | `PRW-3 latest check runs and status contexts determine aggregate checks` | `src/github_pr_watch.zig` |
| PRW-4 | Module | Latest applicable reviewer decisions determine the observed review state for the current head. | `reduce` | `PRW-4 latest applicable reviewer decisions determine observed reviews` | `src/github_pr_watch.zig` |
| PRW-5 | Module | Bounded remote data becomes typed facts, distinct check run IDs remain separate, and review decisions apply only to their observed head. | GitHub response parsing | `PRW-5 remote responses normalize to typed checks and reviews` | `src/github_observation.zig` |
| PRW-10 | Module | A refused foreground publication retains the latest baseline without spending a sequence. | Watch delivery | `PRW-10 foreground retains latest baseline without spending a sequence` | `src/github_watch_delivery.zig` |
| PRW-34 | Module | An uncertain publication remains frozen while later changes coalesce. | Watch delivery | `PRW-34 uncertain publication remains frozen while later changes coalesce` | `src/github_watch_delivery.zig` |
| PRW-35 | Module | A closed observation is retained for settlement and is not published as progress. | Watch delivery | `PRW-35 close is retained for settlement and never published` | `src/github_watch_delivery.zig` |
| PRW-36 | Module | Closing suppresses a definitely refused earlier transition. | Watch delivery | `PRW-36 closing suppresses a definitely refused earlier transition` | `src/github_watch_delivery.zig` |
| PRW-37 | Module | The terminal outcome includes the latest unpublished observation. | Watch delivery | `PRW-37 terminal outcome includes the latest unpublished observation` | `src/github_watch_delivery.zig` |
| PRW-38 | Module | A terminal-only observation is not counted as a dropped update. | Watch delivery | `PRW-38 a terminal-only observation is not a dropped update` | `src/github_watch_delivery.zig` |
| PRW-39 | Module | Changed dimensions encode as a set. | Watch delivery encoding | `PRW-39 changed dimensions encode as a set` | `src/github_watch_delivery.zig` |
| PRW-6 | Module | Pagination destinations stay on the approved endpoint. | GitHub pagination validation | `PRW-6 pagination links stay on the approved endpoint` | `src/github_observation_fetch.zig` |
| PRW-8 | Module | GitHub CLI discovery and token acquisition use the selected account in a scrubbed, noninteractive environment. | GitHub CLI helper | `PRW-8 gh discovery and exact account token use a scrubbed noninteractive environment` | `src/github_transport.zig` |
| PRW-9 | Module | Requests use fixed approved paths and reject invalid targets. | GitHub transport | `PRW-9 paths are fixed and reject unvalidated targets` | `src/github_transport.zig` |
| PRW-15 | Module | Rate limits expose bounded retry times without exposing remote error text. | GitHub response classification | `PRW-15 rate limits expose only bounded retry times` | `src/github_observation_fetch.zig` |
| PRW-16 | Module | Fetch rejects stale heads and marks incomplete or truncated collections as partial. | GitHub observation fetch | `PRW-16 fetch rejects stale heads and bounds incomplete collections` | `src/github_observation_fetch.zig` |
| PRW-20 | Module | The cache isolates responses by account, endpoint, page, and head. | Watch cache | `PRW-20 cache isolates account endpoint page and current head` | `src/github_watch_pressure.zig` |
| PRW-22 | Module | Parsed GitHub response allocations are wiped when released. | GitHub response parsing | `PRW-22 response parsing wipes decoded temporary data` | `src/github_observation_fetch.zig` |
| PRW-24 | Module | Preflight failures remain bounded in the authorized descriptor and reveal no account names. | Watcher descriptor | `PRW-24 preflight failures remain bounded in the authorized descriptor` | `src/github_pr_watch_descriptor.zig` |
| PRW-30 | Module | The GitHub CLI helper deadline covers a running child even after it closes its pipes. | GitHub CLI helper | `PRW-30 gh helper deadline covers a running child and a child that closes its pipes` | `src/github_transport.zig` |
| PRW-32 | Module | A cancelled request does not open a connection. | GitHub transport | `PRW-32 cancelled request never opens a connection` | `src/github_transport.zig` |
| PRW-33 | Module | The fixture origin is restricted to numeric IPv4 loopback. | GitHub fixture origin | `PRW-33 fixture origin is restricted to numeric IPv4 loopback` | `src/github_watch_origin.zig` |
| PRW-41 | Module | Account validation rejects invalid GitHub logins. | Watcher descriptor | `PRW-41 account validation rejects invalid logins` | `src/github_pr_watch_descriptor.zig` |
| PRW-42 | Module | Preparation binds an explicit or sole account and preserves account discovery when required. | Watcher descriptor | `PRW-42 preparation binds explicit and sole accounts and preserves discovery` | `src/github_pr_watch_descriptor.zig` |
| PRW-45 | Module | The cache bounds retained entries and bytes. | Watch cache | `PRW-45 cache bounds retained entries and bytes` | `src/github_watch_pressure.zig` |
| PRW-46 | Module | The request budget rejects excess requests without waiting. | Watch request budget | `PRW-46 budget exhausts without waiting` | `src/github_watch_pressure.zig` |
| PRW-47 | Module | At entry capacity, the cache evicts one entry when adding another. | Watch cache | `PRW-47 cache evicts one entry when at capacity` | `src/github_watch_pressure.zig` |
