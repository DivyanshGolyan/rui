# Rui core and Seams: build plan

Plan only, 2026-11-04. It cuts the design in `ledger.md` (D1 to D172) and `rui-design-spec.md` into small PRs, orders them, and names the critical path.
Code facts were read on origin/main at 98ad3a4c (after #869).
Every unit cites the ledger decisions it builds; a builder reads those, not this file, for what to build.

## The short version

- The design holds together. Mapping it onto the code found four corrections and no contradictions; they are D173 to D176 below.
- The work is 35 PRs in four new lanes, beside the DB thread's own series. Eight of them depend on nothing and can start today.
- The real limit is not the amount of work. It is a handful of large shared files (`protocol.zig`, `configuration.zig`, `schema.zig`, `model_settlement.zig`, `command.zig`). PRs that edit the same file must land one after another (rule A), so the plan gives each shared file one owning lane and keeps every other PR in new files.
- Critical path for the whole design: tool records in memory, then tool records stored, then the core-tool runner, then `start_agent`, then the stop cascade, then child answers delivered. Six PRs.
- Critical path for Drift is the DB thread's series: the open PRs 5e-2b to 6b, then PR 7 Store thread, PR 8 MySQL, PR 9 Host wiring. Drift runs only on MySQL (Divyansh, 06:46Z). Everything else Drift needs (tool records, MCP tools, launch frame, spec, presets, TS client) is two chains of four PRs in other lanes and must land before PR 9 so it never becomes the wait.
- One step needs Divyansh: a live probe against OpenAI with a real key (P1). It is needed only before the codec PRs T2 and T3 merge, not before they start.

## Design corrections found while mapping

These are technical calls, logged as new ledger lines.

D173. Replaces D119 and D164's "one format bump". Every merge to main ships a release, so one bump shared by many PRs would force one giant PR. Instead, each PR that changes the Store format bumps `schema_version` itself and adds its `bootstrap_digests` row. Format-changing PRs land one at a time in the order below. From the migration runner on, each such PR also ships its forward migration for SQLite and MySQL, checked in CI (D204).

D174. The Session's "one append-only change list" (D53, D138) is today's `session_revision` table plus the settings each Operation freezes. It is not a new table. The codec works out each change by comparing Operation k's frozen settings with Operation k-1's, as D75 already says. What is new is that a revision can come from the core (a `find_tools` load, an MCP rewording) as well as from a client's `configure`, so `session_revision.command_key` must allow a core-made key.

D175. Moves the launch frame out of the DB thread's PR 9 (changes D108). The frame (D112, D130) is built early in its own PR with `store` taking today's SQLite Store directory. PR 9 then only adds the MySQL URL form of `store` and the MySQL rules for `runtimeDir` and the Store id (D114, D158). Drift itself runs only on MySQL; the early frame lets the TS client and MCP work be built and tested in CI before MySQL lands, and keeps PR 9 small.

D176. Wording fix to D169: the Bash environment a child inherits is the parent's environment held in Host memory (`SessionEnvironments.zig`), not a saved one; Rui never stores it. Also, D76's test line numbers are stale: the cache proof tests are at `src/model_adapter.zig:3566`, `:3594` and `:3630`.

Already done on main, so not in this plan: D56 parallel calls (#868), D57 no strict mode (#869), D11's `kinds` filter and the `person-message` removal (#860), D96 (#857), D97 (#858).
D111 is smaller than it looked: a per-Session token trigger already exists (`compaction_trigger`, schema.zig:161); the work is making it required and deleting the 90% default (`product_defaults.zig:32`).

## How the work is cut

Each PR is one change with its own evidence and keeps the suite green.
Sizes are rough: S under about 300 changed lines, M up to about 1,000, L more (L units are split where a clean split exists).

### Lanes and file ownership

A lane is one build thread with its own machine, because two Zig release builds on one 4-core box slow each other down.
A lane owns its shared files: another lane's PR that must touch one of them lands after the owner's open PR on that file, re-checked against newest main (rules A and B in rui-pr-workflow).

| Lane | Owns | Units |
| --- | --- | --- |
| T, Tools and codec | `tools.zig`, `model_adapter.zig`, `codecs/`, `codec_abi.zig`, `model_settlement.zig`, `historical.zig`, `model_capability.zig` | T1a, T1b, T1c, T2, T3, T4, T5, C1, C2, C3 |
| K, Core, feed and agents | `protocol.zig`, `configuration.zig`, `command.zig`, `reads.zig`, `session_view.zig`, `turn.zig` | F1, F2, F3, S1, K0, K1, K2, K3, K4, K5, K6, K7 |
| M, MCP | new `src/http1/`, new `src/mcp/` | M1, M2, M3a, M3b, M4 |
| L, Launch and clients | `cli.zig` Host start, `host_launch.c`, new `launch_frame.zig`, new OpenAPI emitter, new `clients/ts/`, release scripts | P0, A1, A2, S2, A3a, A3b, A3c, A4 |
| D, Store (existing DB thread) | `src/store/` engine files, `Store.zig`, `access.zig`, `rsql.zig` | 5e-2b, 5e-3, 6a, 6b, 7, 8, 9 |

`schema.zig` and `store/tests.zig` are shared by D, T and K. Their order is the format queue below.
`build.zig` and `tests/ci/select_tests.py` get small additive edits from several lanes; a conflict there is resolved by keeping both sides and rerunning prepush.

### Format queue

Store format changes land in this order, each bumping the schema version once (D173):
1. DB thread 5e-2b (schema 51), then 5e-3, 6a, 6b as already planned, then the migration runner (D204), owned by the DB thread, before any other format change.
2. T1b tool records.
3. F1 ending names, if the PR keeps stored names (otherwise no bump).
4. K1 `parent` column.
5. T3 core-made revision keys.
6. C2 saved catalog.
7. DB thread PR 8 (MySQL DDL in the format pin) and PR 9 (Store id), whenever they are ready; they may take any slot.

## Units

Each line: id, size, what it builds, ledger refs, depends on.

### Premise checks (first, rule 6)

- **P1** (script, Divyansh runs it) Live probe against OpenAI's Responses API with a real key: a mid-conversation `configuration_update` effort change and an `additional_tools` item both keep `cached_tokens`, a call to a removed tool returns the "removed" result, and hosted `web_search` works. Pass/fail table saved under `research/`. Refs D75 to D77, D103, D150. Depends on nothing. Gates the merge of T2 and T3.
- **P2** (inside F3's design) Word search over stored content: SQLite keeps text in content blobs and MySQL in 128 KiB `content_chunk` rows, so a match can straddle a chunk edge. Write the premise down and test it on both engines before F3 is built.

### Lane T: tools and codec

- **T1a** (M) Tool records in memory. A tool becomes a record (name, description, input schema, owner); request rendering (`model_adapter.zig:951`) and call checking (`tools.zig:308` `inspectCall`, `:344` `classifyCall`) work from a list of records. Still backed by today's mask, no format change. Refs D48, D49, D46. Depends on nothing.
- **T1b** (L) Tool records stored. Records saved once by content; the Session, each revision and each Operation reference a tool set instead of `tools_mask`; the wire `tools` field becomes a list of names (`protocol.zig:132` `ToolsField`). Format bump. Refs D48, D49, D50, D104. Depends on T1a, and lands after F1 (shares `protocol.zig`, `reads.zig`).
- **T1c** (S) Provider-run tools first class. Each Provider Adapter lists the tools it runs (both OpenAI Adapters list `web_search`); a spec naming one the provider lacks is refused with `provider_tool_missing`. Refs D46, D47, D150, D166, A-D74. Depends on T1b.
- **T2** (M) Codec `openai-responses/2` for effort. Top-level effort fixed to the Session's starting effort; a `configuration_update` item at each Operation where frozen effort changed; an "Operation boundary" element in the history view; a refused change retried without the item and recorded as a revision note. Extends the cache proof tests. Refs D29, D75, D76, D77, D137, D165, D174. Depends on T1a (same files). Merge gated by P1.
- **T3** (M) Tool changes without a cache miss. Tool added, removed or reworded becomes a revision (core-made key, D174); the codec emits `additional_tools` at that Operation; a removed tool keeps its description and a call to it returns "this tool was removed". Format bump for core-made keys. Refs D53, D54, D55, D138, A-D76. Depends on T1b, T2. Merge gated by P1.
- **T4** (M) `find_tools` and `loadedTools`. A core tool that matches words against names and descriptions and loads matches through T3's path; `loadedTools` defaults to all of `tools`. Refs D52, D160. Depends on T3, K0.
- **T5** (M) Model switch. `update` may change the model within the provider; the next request rebuilds from the visible conversation. Refs D192. Depends on T2, S1.
- **C1** (M) Shipped catalog. A build step turns a models.dev snapshot into a compact table of effort levels and context window per model id; `model_capability.zig`'s hand-copied Codex rows go away while its functions keep their callers. Refs D78, D79, A-D79, D151, D154. Depends on nothing.
- **C2** (M) Catalog refresh. Fetch `models.dev/api.json` at Host start and on each model-list request with ETag (checked: served over HTTP/2, so the existing h2 client on the Reactor does it), save the slim result in the Store, fall back to saved then shipped. Format bump. Refs D79, D80, D153. Depends on C1.
- **C3** (S) The model picker groups the same id across providers. Refs D81. Depends on C1.

### Lane K: core, feed and agents

- **F1** (M) Feed endings. `outcome` becomes `turn_ended` with the ending set `done`, `context_full`, `provider_refused`, `provider_unavailable`, `stopped`, `interrupted`, `failed`; the last assistant entry of a Turn carries `final: true`; each entry carries an opaque `cursor`; entry text inlined up to 16 KiB with `truncated`. Today's names live in `turn.zig:20-69` and `failure_class.zig`. Refs D9, D109, D115, D162, D168, D170, D134, D30. Depends on nothing.
- **F2** (S) New feed rows. `session_changed`, one per revision, and `approval_requested` with the Action id as `requestId`. Refs D115, D138. Depends on F1.
- **S1** (M) The agent spec at `configure`. `model`, `effort`, `compactAt`, `tools` and `permissionMode` required; the 90% default deleted; `compactAt` above a known context window refused with `compact_at_too_large`; `workspace` required only with `bash`; the TUI and CLI fill their own defaults on the client side. Refs D104, D111, D113, D133, D165, D166. Depends on T1b.
- **K0** (M) Core-tool runner plus `message_agent`. A core tool call resolves inside the core as a command, with no Action process; `message_agent` is the first one, built on today's peer admission (`command.zig:137`); peer text shrinks to pointing at the tools. Refs D24, D41, D43. Depends on T1b.
- **K1** (M) `start_agent` and `parent`. One saved step keyed by the call id creates the child Session with `parent`, admits its task and returns its id; the child inherits workspace, provider and environment and may only narrow tools and permission; a wider spec is a tool error. Format bump. Refs D27, D37, D122, D140, D169, D176. Depends on K0.
- **K2** (S) Stop cascade. Stopping a Session, or "context full" on it, stops its attached children (`command.zig:554` `stopSession`). Refs D38, A-D14, D139. Depends on K1.
- **K3** (M) Child endings delivered. Every child ending except one caused by the parent's stop is admitted to the parent as a message and wakes it. Refs D39, D122, D139, D161. Depends on K2 (same file), F1.
- **K4** (S) Approvals up the tree. A child's `approval_requested` appears in every ancestor's feed, and `decide` on any ancestor routes to the child. Refs D135. Depends on K1, F2.
- **K5** (M) `read_transcript` without search. Outline by default, `kinds`, `before`/`limit`, `full` with chunking, over any Session. Refs D42, D163. Depends on K0, F1.
- **K6** (S) Compaction makes room. When the compaction request would not fit, drop the oldest messages from it until it fits, and record the count on the feed. Refs D191. Depends on F1.
- **K7** (S) Host pause. A control that holds every new Turn until resume, shown in Host status. Refs D193. Depends on nothing.
- **F3** (M) Word search, shared by `/v1/conversation-page` and `read_transcript`'s `query`. Refs D13, D42. Depends on P2, K5.

### Lane M: MCP

- **M1** (M) HTTP/1.1 client, sans-I/O, driven by the existing Reactor with no new thread; plain HTTP to loopback only. Refs D66, D120. Depends on nothing.
- **M2** (M) MCP 2026-07-28 protocol core, sans-I/O: request headers and `_meta`, JSON and SSE replies, `tools/list` paging, `tools/call` results and JSON-RPC errors. Fixture tests. Refs D64, D65, D101. Depends on nothing.
- **M3a** (M) MCP servers as a tool source. `mcpServers` in the launch frame; tools fetched at Host start and saved as records; name collisions refused at start; an unreachable server keeps its saved copies; `rui_call_description` added to each tool. Refs D45, D50, D62, D105, D110 (start-time fetch), D120, D142, D143, D147. Depends on M1, M2, T1b, A2.
- **M3b** (M) MCP calls. Calls run as Actions with Bash's ask/bypass permission; the description is stripped and the server gets only its own fields; 10-minute limit; "failed, not run" before the request left, "outcome unknown" after; server errors become tool results. A CI test runs Drift's real server library (`@modelcontextprotocol/server` 2.4.0). Refs D58 to D62, D144 to D146. Depends on M3a.
- **M4** (S) Reworded, added or removed MCP tools are appended to each Session's revisions before its next model call. Refs D55, D110. Depends on M3a, T3.

### Lane L: launch and clients

- **P0** (S) Contract text. Delete the Workflow Runtime from ARCHITECTURE.md and add Seam and Adapter to the term table. Every other contract change (D95, D124, D159) lands inside the PR that changes the code. Refs D36, D126. Depends on nothing.
- **A1** (M) `openapi.json` emitted at build from the Zig request structs (`protocol.zig`, fixed `Bounded` fields) and reply shapes (`protocol.zig:2215` `Hole`), checked in, with a CI diff check and a test that parses one generated example of every request. Refs D172. Depends on nothing. Each later wire PR regenerates the file.
- **A2** (M) Launch frame. `rui host serve` reads one 4-byte length plus JSON frame from stdin (`v`, `store` as a SQLite directory, `provider: {kind: "openai_key", baseUrl, key}`, `runtimeDir`); the key stays in memory; readiness is `/v1/host-info` on the socket in `runtimeDir`; stdin closing runs infrastructure shutdown bounded at 10 s, then exit; refusals at open are `RuiStartError` codes. Refs D5, D70, D108, D112, D118, D130, D131, D136, D149, D175. Depends on nothing.
- **S2** (S) Presets. `presets` in the launch frame; `sessions.create` and `start_agent` name one and override fields; the resolved spec is copied at start. Refs D22. Depends on A2, S1.
- **A3a** (M) TS package skeleton. Types generated from `openapi.json`; Unix-socket transport; `Rui.connect` spawns the child, writes the frame, waits for readiness; `close()`, the `exit` event, restart with backoff and retry by keys. Refs D2, D3, D107, D116, D118, D127, D129, D131, D172. Depends on A1, A2.
- **A3b** (M) Sessions. `sessions.create`, `getSession`, `sessions.list`, `send` with `kind:driftId` keys and `env`, `update`, `stop`, `decide`, `interrupt` (no-op when idle), `models()`. Refs D7, D8, D14, D15, D16, D17, D121, D123, D128, D167, D171. Depends on A3a.
- **A3c** (S) Feed. `listActivity` as an async iterator with `after` and `follow` polling (250 ms rising to 2 s), and `readContent`. Refs D9, D10, D117, A-D117, D134, D168, D170. Depends on A3b, F1.
- **A4** (S) npm packaging. `rui` plus optional `rui-linux-x64` and `rui-darwin-arm64`, found with `require.resolve`, built by the release workflow. Publishing to npm is outward-facing, so the first publish waits for Divyansh. Refs D125, D127. Depends on A3a.

### Lane D: Store (DB thread, already planned)

5e-2b (#862), 5e-3 (#863), 6a (#870), 6b (#871) are open. Then PR 7 Store thread, PR 8 MySQL engine with the open-time refusals and the `commit_seq` fence (D86, D87, D156, D157), PR 9 Host wiring, which now extends A2's frame with the MySQL `store` URL, `runtimeDir` rules and the Store id (D114, D158, D175).

## Order and critical path

### Start today (no dependencies)

T1a, C1 (lane T); F1, K7 (lane K); M1, M2 (lane M); P0, A1, A2 (lane L); plus P1 for Divyansh whenever convenient.
Within a lane, builders are pipelined: PR N+1's builder starts when PR N's builder hands back (orchestration rule 1).

### Dependency graph

```
T1a ─► T1b ─┬─► T1c
            ├─► S1 ─► S2 (also needs A2)
            ├─► K0 ─┬─► K1 ─► K2 ─► K3        ◄── critical path (whole design)
            │       ├─► K5 ─► F3 (needs P2)
            │       └─► T4 (also needs T3)
            ├─► T3 (also needs T2, P1) ─► M4
            └─► M3a (also needs M1, M2, A2) ─► M3b
T1a ─► T2 (merge needs P1)
F1 ─► F2 ─► K4 (also needs K1)
F1 ─► T1b (lands after), K3, K5, A3c
A1 + A2 ─► A3a ─► A3b ─► A3c
            A3a ─► A4
C1 ─► C2, C3
DB: 6b ─► 7 ─► 8 ─► 9 (extends A2)
```

### Critical paths

1. Whole design: T1a, T1b, K0, K1, K2, K3. Six PRs: two in lane T, then four in lane K, so lane K is the lane to keep moving once T1b lands.
2. Drift (MySQL only): the DB series 5e-2b to 6b, 7, 8, 9 is the critical path. Beside it, Drift also needs A2, A3a to A3c, T1b, S1, S2, F1, M3a and M3b, as two chains of four (T1a, T1b, M3a, M3b and A1, A3a, A3b, A3c), which must land before PR 9. Agents (K1 to K4), `find_tools` and catalog refresh are not needed for Drift's first conversation.

### Pace rules for this run

- Hub PRs first. T1a, F1 and T1b unblock the most units, so they get the first reviews.
- Keep T1b reviewable despite its reach: T1a moves all logic to records first, so T1b is mostly storage and wire.
- Every wire PR regenerates `openapi.json` in the same commit; the CI diff check from A1 turns a forgotten regeneration into a red build instead of a review finding (orchestration rule 5).
- No Claude code or bug review of implementation PRs, and no reviewer subagents (Divyansh 2026-11-04 06:57Z). Codex on the PR is the code review. Claude still does design reviews, and a fresh-context redesign when the same class of finding keeps coming back.
- Measure per-stage times (build, CI, Codex, merge) on the first three PRs before naming a pace limit (orchestration rule 11).

## Threads to start

Four build threads plus the existing DB thread:
- "Build Rui tool records and codec" (lane T): T1a, then C1 while T1a is in review.
- "Build Rui feed, spec and agents" (lane K): F1 first.
- "Build Rui MCP client" (lane M): M1 and M2.
- "Build Rui launch and TS client" (lane L): P0, A1, A2.
The DB thread gets D175 (PR 9 extends the launch frame instead of creating it).

Each thread writes a brief per PR from the ledger decisions the unit cites, follows rui-pr-workflow and rui-orchestration-rules, and checks this plan's lane table before touching a shared file.

## Drift's review

Folded in on 2026-11-04: D177 to D193 (drift-review-triage.md). Unit changes: M3b gains D177, D182, D184; F2 gains D179, D180; A2 gains D181; A3a gains D183, D185; A3b gains `pause`/`resume`; A4 gains D186; K1 gains D178; new units T5, K6, K7.
