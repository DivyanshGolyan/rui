# GitHub pull request watcher invariants

These rows cover the watcher domain: URL validation, observation reduction, response normalization and delivery. Later rows join as the watcher transport and Host runner land.

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
