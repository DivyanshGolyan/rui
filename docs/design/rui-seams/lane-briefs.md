# Rui Seams build: lane briefs

Divyansh approved starting the build on 2026-11-04 at 08:29Z ("yes").

The sources of truth are all on branch `claude/project-thread-t2tb7n` in `docs/design/rui-seams/`:
- `build-plan.md`: the units, the lanes, which lane owns which file, the format queue and the critical path.
- `ledger.md`: decisions D1 to D204. The latest line wins.
- `spec.md`: the design.

Working copies of the same files are in /mnt/project-files/rui-seams/spec/. The build map is at https://claude.ai/artifact/2SQdMtmZGFK9YYFiNngvbX.

## Rules for every lane

- One PR per unit, each on its own branch (`claude/<thread-branch>-<unit>`). Push and open it as a draft at hand-back so CI runs during review. A stacked PR's base is the previous PR's branch.
- Start the next unit's builder as soon as the current builder hands back (rui-orchestration-rules).
- Claude does no code or bug review, and runs no reviewer subagents (Divyansh, 06:57Z). Codex on the PR is the code review. Design reviews still happen, and so does a fresh-context redesign when the same class of finding keeps coming back.
- Merge once CI is green and Codex is clean, without asking (rui-pr-workflow).
- Before editing a file another lane owns, check that lane's open PRs. A PR that touches the same file lands after that lane's open PR (rule A).
- Format changes go through the format queue. None may land before the Store thread's migration runner, PR 6d. Each one ships a forward migration for SQLite and MySQL (D204).
- Every wire PR regenerates `openapi.json` once A1 lands.
- Prompt text (core tool schemas, delivery text) gets no tests.
- Brief each builder with its unit's ledger decisions, cited by D number.

## Lane T: Rui tools and codec

Owns `tools.zig`, `model_adapter.zig`, `codecs/`, `codec_abi.zig`, `model_settlement.zig`, `historical.zig` and `model_capability.zig`.

Order: T1a, then C1 while T1a is in review. Then T1b, which lands after lane K's F1. Then T2, T1c, T3, T5, T4, C2 and C3, following the plan's dependencies.

T2 and T3 may not merge until P1 passes. P1 is a live OpenAI probe with a real key, which Divyansh runs. Write P1's script early and send it to him through the coordinator.

## Lane K: Rui core, feed and agents

Owns `protocol.zig`, `configuration.zig`, `command.zig`, `reads.zig`, `session_view.zig` and `turn.zig`.

Order: F1 and K7 first. Then F2, K6, S1 (after T1b), K0, K1, K2, K3, K4 and K5. F3 comes last, after its premise is tested.

This lane is the critical path for the whole design: T1b, K0, K1, K2, K3. Keep it moving.

D177, D195, D178, D179, D180 and D191 to D193 attach to these units, as listed in the plan's "Drift's review" section.

## Lane M: Rui MCP client

New files `src/http1/` and `src/mcp/`.

Order: M1 and M2 in parallel. Then M3a, which needs T1b and A2. Then M3b and M4.

Drift's real server library goes into CI: `@modelcontextprotocol/server` 2.4.0, with `legacy: "stateless"`. M3b carries D177, D195, D182 and D184. Drift's `callTimeoutMs` is at least 1,800,000.

## Lane L: Rui launch and TypeScript client

Owns the Host start in `cli.zig`, `host_launch.c`, the new `launch_frame.zig`, the OpenAPI emitter, the new `clients/ts/` and the release scripts.

Order: P0, A1 and A2. Then A3a, A3b, A3c, S2 and A4.

A2 takes `store` as a SQLite directory. The Store thread's PR 9 adds the MySQL URL. A2 carries D181 and D196, and measures memory per waiting Turn in the #840 harness.

A3a carries D183, D185 and D198. A3b carries pause and resume. A4 adds `rui-linux-arm64` (D186), and its first npm publish waits for Divyansh.

## Store thread (existing)

6c, then 6d (the migration runner), then 7, 8 and 9, covering every Store line it confirmed at 08:28Z.
