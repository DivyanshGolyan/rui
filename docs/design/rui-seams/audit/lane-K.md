# Lane K design audit: core, feed and agents (2026-11-05)

Scope: landed #876 #881 #884 #886 #903 #911 #912 #917 #922 #926 #948 #950 #952 #962 #968 #940; open #977 (K4, at 0f0364b4e) and #964 (S1, at f7bc0ed51). Paths are on origin/main unless a branch is named.

## Findings

1. **S1 lets `start_agent` choose its own provider and Workspace.** #964, `src/core_tools.zig:210` and `src/store/domain/command.zig` `parent_settings` (branch). D122, D140, D169.
   The PR removes the refusals for `spec.workspace` and `spec.provider` and stops copying them from the parent. A child can now run Bash in any directory, under a different provider. D122 says a child inherits both, and D140 says naming either is a tool error. No ledger line replaces those decisions, and the PR's ARCHITECTURE text rewrites them anyway. It looks like D133 (provider defaults; Workspace only with Bash) was applied to `start_agent`, but D133 governs `sessions.create`.
   Severity: blocks Drift (S1 is on Drift's path, and this reverses an approved decision).
   Fix: in `checkStartAgent`, keep refusing `spec.workspace` and `spec.provider`, and keep the parent copy in `startAgent`. Apply D133 only on the wire parser and `configurationBeforeWorkspace`.

2. **S1 still has Host defaults on the creation path.** #964, `configuration.zig:75` `defaultProvider`, plus `output_reservation`. D104, D111, D113, D133.
   - When more than one provider is served, `defaultProvider` falls back to `product_defaults.provider` ("codex"). D133 allows the default only when the Host has a single provider.
   - `output_reservation` is still a Host-defaulted setting (`product_defaults.output_reservation`). It is not in D113's spec, and D30 says the trigger is the one setting.
   - On the good side, the five required fields are enforced in both the parser and the domain, and `default_tools` is gone.
   Severity: design debt.
   Fix: refuse a missing provider when more than one provider is served (`incomplete_initial_configuration`). Either log `output_reservation` as a spec field or drop it from the creation wire.

3. **S1 keeps catalog and product fallbacks for old rows.** #964, `configuration.zig:267` `effectiveReasoningEffort` and `model_capability.zig:121`. D111, D209.
   A stored null effort still freezes the catalog default. A stored null trigger uses 115,200 tokens from `product_defaults`. `compactionPolicy` now ignores its `model` parameter (`_ = model`). This contradicts D209 ("the catalog never needs a default effort"), and C1 has to keep `default_effort` alive.
   Severity: design debt.
   Fix: add a forward migration that writes the effective effort and trigger into rows saved before D111. Then delete `defaultReasoningEffort`, the null branches and the dead parameter.

4. **S1 stores `/` as the Workspace of a Session without Bash.** #964, `configuration.zig:794`. D133. This decision is not in the ledger.
   "No Workspace" is saved as a real path. The PR's own ARCHITECTURE text says that enabling Bash later runs it in `/`.
   Severity: design debt.
   Fix: make `session.workspace` nullable (null meaning none), and refuse a later `tools` change that adds Bash while the Workspace is null. Or log the sentinel as a decision.

5. **S1 accepts `effort: null`, but only for unlisted models.** #964. D111, D165. This decision is not in the ledger.
   It is reasonable (D194), but D111 says every spec states an effort value.
   Severity: nit. Fix: log it.

6. **`start_agent` narrows tools through the old bitmask, so a child can never get an MCP tool.** #922 `command.zig:607` (`tool_set.maskSql`) and `:658`. D122, D113, D48.
   K1 checks narrowing on `tools_mask`/`ToolSet` built-ins. Any MCP name is refused with "only Rui's own tools can be narrowed to". This leaves two notions of a tool set: tool records (T1b) and the mask. S1 keeps the mask.
   Severity: design debt (needed before Drift's agents use Drift's tools).
   Fix: narrow by name against the parent's `tool_set_member` rows (set difference in SQL), and delete `toolSet(mask)` and `requestedTools`.

7. **The list of core tools is written out in five places.** #917/#922/#962: `tools.zig:191` `Runner.of` (pointer equality), `action.zig:71` SQL `CASE` by name, the `CoreTool` enum, `CoreNames`, and the three name arguments threaded through `core_facts`/`next_core_action`. D24, D46.
   Adding `find_tools` (T4) means editing all five, and the Bash path needs `NOT coreCallSql` as a special case.
   Severity: design debt.
   Fix: write one comptime `core_tools.names` list and generate `Runner.of`, `CoreTool`, the SQL `CASE` and the bind arguments from it.

8. **There are four separate writers of a "Message from another Session".** `command.zig:291` (peer send), `:485` (`message_agent`), `:578` (child ending, #948) and `:700` (`start_agent` task). D39, D41.
   They share only the final `INSERT`. Each repeats `queueCommand`, the digest-domain string, the key scheme and the sender-position step. Only the first calls the wake callback. D39's "same path" holds for the stored row but not for the module.
   Severity: design debt.
   Fix: one `admitFromSession(a, sender, target_head, key, domain, content_id)` that all four call, with the wake in one place.

9. **D139's "quiet" is read from a prefix of the command key.** #948 `action.zig:131`: `st.command_key>='rui.core/stop/'`. D139.
   The cause of an owed stop is already stored as `session_stop_owed.cause_ref`/`cause_position`. Quiet delivery is instead inferred by string-matching the key that `owedStopKey` builds, so one fact lives in two places, one of them a string encoding.
   Severity: design debt.
   Fix: store `caused_by_parent` (or `cause_ref`) on `session_stop` when the owed stop runs, and test that column.

10. **K4 stores each child ending twice for the direct parent.** #977 `turn.zig:146-147` (branch). D39, D180.
   Every Turn close writes both `session_ending_owed` (the Message) and a `session_forward` row of kind ending (the feed row). These are two durable queues, keyed by `turn_id`, for the same child-to-parent fact. Both tables are new in unreleased format 54.
   Severity: design debt (cheap to fix before 54 ships).
   Fix: let the first-hop `session_forward` row of kind ending also admit the Message when it is not quiet, and drop `session_ending_owed`.

11. **K4 names the wire field `session` and special-cases it in the TS client.** #977 `clients/ts/src/feed.ts:91` maps `session` to `sessionId`; `forward.zig` makes routing depend on a forward row. D135, D180.
   The rule that "an ancestor may decide only after it received the forwarded request" is not in the ledger. `read_transcript`'s outline (`read_transcript.zig:213`) does not show the new `session` field, so a parent cannot tell its own ending from a child's.
   Severity: nit.
   Fix: name the wire field `session_id` so the generic camel-case rule gives `sessionId`. Log the routing rule. Print the session in the outline line when it differs from the Session being read.

12. **D178 (`sessions.create` accepts `parent`) was never built.** It belongs to K1 per the build plan, line 176. `protocol.Configuration` has no `parent`, so only `start_agent` can set it. D27, D178.
   Severity: design debt.
   Fix: add `parent` to the creation configuration, with `start_agent`'s rules (inherit, only narrow) through the same `parent_settings` check.

13. **`session_changed` uses internal field names, and the refused effort change cannot be recorded.** #903 `protocol.zig:786`, `session_change` CHECK. D115, D137, D218.
   - The field names are `compaction_trigger`, `reasoning_effort`, `permission_mode` and `output_reservation`, while the spec says `compactAt`, `effort` and `permissionMode`. D115 asks for one name set everywhere.
   - D218 says events that change no setting (D137's refused effort change, with the provider's text) are rows too. But `revision>1`, the foreign key to `session_revision` and the closed field enum make such a row impossible to store.
   Severity: design debt.
   Fix: name the fields as the spec does, and give `session_change` a nullable revision with an event code and content.

14. **F1a's `turn_ended` carries more than D168 says, and duplicates the answer.** #876 `protocol.zig:816`. D109, D162, D168. Not in the ledger.
   - It carries `code`, the saved internal code (for example `ResourceExceeded`), which is not in the ledger.
   - For `done` it carries the answer's content, which is the same fact as the `final: true` assistant row. D168 says text only for `provider_refused` and `failed`.
   Severity: nit.
   Fix: drop `content` when the ending is `done`. Log `code`, or rename it to a closed set.

15. **K3 tells the parent only the ending's name.** #948 `command.zig:533` `endingText`. D122, D168.
   The text sent for a child's non-done ending omits the provider's text, which `turn_ended` carries for `provider_refused`/`failed`. The parent must call `read_transcript` to learn why.
   Severity: nit.
   Fix: append the saved report, when there is one, to the message text (D161 prompt text).

16. **"Pause" names two different things.** The CLI `rui host pause` (#940, `cli_args.zig:67`) shuts the Host down. D193's pause (#881, `/v1/control/host-pause`, TS `rui.pause()`) holds new Turns. D20 (one public interface) and D193.
   Severity: design debt.
   Fix: rename the CLI command `rui host stop`/`retire`, and add a CLI `host pause|resume` over the D193 route.

17. **F3 searches through a new route, not `/v1/conversation-page`.** #968 `server.zig:1747`. D13, D216. Not in the ledger.
   The search is `/v1/activity-search` over the Activity feed, which is arguably the better design (one feed), but it is not logged.
   Severity: nit. Fix: log it as replacing D13's route.

18. **K6 makes up a context window for unlisted models.** #911 `history_floor.zig:198` uses `model_capability.contextWindow`, which falls back to `product_defaults.unlisted_context_window` (128k). D217, D111.
   Severity: nit.
   Fix: for a model the catalog does not list, aim level 1 at the Session's own `compactAt`.

19. **`read_transcript` hard-codes `web_search` for every provider-run call.** #962 `read_transcript.zig:211`. D47.
   This is a provider favourite in core.
   Severity: nit. Fix: print the provider tool's recorded name.

20. **Core tool calls skip permission without a ledger line.** #917 `model_settlement.zig` ("A core tool acts only on the Store"). D58.
   Under `ask`, `start_agent` runs without approval. The child still asks, so this is reasonable, but it is not logged.
   Severity: nit. Fix: log it.

21. **The F2 unit is unfinished.** D179/D219's `model_call` row has no code on main or on either branch. D180 moved into K4.
   Severity: design debt (tracking only). Fix: schedule F2c.

## Checked and matching the design

- D24 holds: core tools resolve in one Store command with no Action process, though they ride on `action_operation` rows (see 7).
- D27: `session.parent_ref`, including its CHECK, is a core column.
- D38 and A-D14: the stop and context-full cascade goes through settled owed stops. K2b removed the runtime `DELETE` (D202).
- D115: the seven endings are derived at read time from saved codes, and one name set is used on the wire, in TS and in `read_transcript`.
- D217: K6 has a carried-forward `history_floor`, 3 levels, 4 bytes per token, each level a quarter of the last, and a `compacted {dropped}` row on every compaction.
- D218: stored `session_change` rows sit at the revision's position.

## PRs that match the design cleanly

#884 K8, #886 F2a+F2b-1, #911 K6a/b, #912 K6c, #926 K2, #950 K2b, #952, #962 K5 (apart from 19), #881 K7 (apart from the naming in 16).
