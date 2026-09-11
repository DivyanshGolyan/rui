# Queued-message state-machine prototype

Open `index.html` directly. It is self-contained and keeps state only in memory. To serve it locally, run `python3 -m http.server 18769 --bind 127.0.0.1 --directory research/queued-message-prototype` from this worktree.

This is a discussion artifact for [Choose unapplied-message behavior after a failed Turn](https://github.com/DivyanshGolyan/latifa/issues/144), not an accepted contract or production implementation. It compares the owning docs at `ffac60f0a5c1550b44c8e6955210f601910bb91d`, the issue's unaccepted alternative, and the user's proposed automatic continuation. The user has since selected automatic continuation and processing-owned caller results in the linked decision ticket. This archive preserves the comparison as reviewed, including the questions that were still open when the HTML was built; the owning architecture and verification documents carry the accepted contract.

One Luna research agent per runtime produced the source evidence: [Pi](pi.md), [DeepSeek Harness](deepseek.md), [OpenCode v2](opencode.md), and [Codex](codex.md). Each distinguishes the inspected version, queue layer, and source evidence from execution. The HTML embeds the decisive links and limits so it can be shared alone.

Verification on 2026-09-11: exercised all seven guided sequences through browser controls; inspected the failure comparison and external runtime panel at 390 × 844; confirmed no horizontal page overflow at that width; loaded and interacted with the public Cloudflare URL. The initial agent-browser screenshot command stalled, so visual inspection used the in-app browser. This is phone-size emulation, not a physical-phone or Safari qualification. No upstream tests or provider calls were run.

The temporary tunnel serves only a copy of `index.html` in `/tmp/latifa-queue-public`, not the repository. The HTTP server and tunnel run as separate background processes; their PID and log files are `/tmp/latifa-queue-http.{pid,log}` and `/tmp/latifa-queue-tunnel.{pid,log}`. The link requires those processes and the host to remain running.
