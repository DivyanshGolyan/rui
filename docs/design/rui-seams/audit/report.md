# Design audit: landed work and open PRs (2026-11-05)

I checked about 79 commits on main since 11-04 and 10 open PRs against the ledger (D1 to D219). This was a design audit, not a bug review. The full findings, 72 in all, are in the lane files: [lane-T.md](lane-T.md), [lane-K.md](lane-K.md), [lane-ML.md](lane-ML.md) and [lane-D.md](lane-D.md). I checked every blocker below against the code myself. My fixes are logged as D220 to D230.

## Blockers for Drift (7)

1. **Calls are still checked against the old tool bitmask** (T, #887/#915/#954, extended by #976). Requests are built from the saved tool records, but settlement turns the saved set back into the built-in bitmask (`src/store/domain/tool_set.zig:47` `maskSql`, `model_settlement.zig:544,1185`). An MCP tool has no bit, so when a model calls one of Drift's tools the call fails as `unknown_tool`. K1's child narrowing uses the same mask, so a child can never be given an MCP tool. That breaks D48 and D49. **D220:** check calls against the saved set and delete the mask. This must land before M3b.
2. **S1 (#964, open) lets a child choose its own provider and workspace.** That reverses D122 and D140: a child could run Bash in any directory. It looks like D133, which is about `sessions.create`, was applied to `start_agent` (`core_tools.zig`, the removed refusals). **D221:** put the refusals back before #964 merges.
3. **The MCP call line is the tool name** (M, #944). `rui_call_description` is not saved, and the TUI rebuilds the line by re-reading the arguments, so the feed and Drift see only the tool name. That breaks D62 and D143. **D227:** save the line once at settlement, up to 200 bytes.
4. **The TS client cannot pass MCP servers** (L, main and #969). `Rui.connect` has no `tools` option, so Drift's own server is never offered. That breaks D3 and D132. **D228:** add `tools` and write it to the frame as `mcpServers`.
5. **The MySQL start error codes don't match D136** (Store, #963). MariaDB is folded into `mysql_version_unsupported`, and one durability code covers both variables (`src/store/engine/mysql_refusal.zig`). **D222:** use the D136 names, one code per variable, plus `mysql_unreachable` and `mysql_login`.
6. **The DB team can't get upgrade SQL** (Store, #963). The forward migration exists only inside the build. D203 has the DB team apply every change, and every merge is a release (D173), so Drift's first upgrade would be stuck. **D223:** add `rui store schema --engine mysql --from N`.
7. **No private CA for MySQL TLS** (Store, #963). Only system trust is checked, so RDS or Aurora would fail to connect. **D224:** add `ssl-ca=<path>` to the URL, and never a skip-verify option.

## Design debt worth fixing now (cheap while format 54 is unreleased)

- **One tool list, five places** (T and K). Core tools are listed separately in `Runner.of`, a SQL CASE, `CoreTool`, `CoreNames` and the `tools.zig` handlers, so adding `find_tools` meant editing every one of them. Fix: one table of core tools that everything else reads.
- **Bash and MCP have no shared runner** (M, #960/#944). MCP has its own Store entry points and its own SQL inside core settlement. Fix: one runner interface, with Bash and MCP as its two adapters (D44). Three different "who runs this tool" answers would collapse into one.
- **Two queues for one child ending** (K, #977). K4's `session_forward` sits beside K3's `session_ending_owed`. Fix: merge them before 54 ships.
- **Two word-search engines** (T, #976 against F3). `find_tools` folds case in SQL, while `word_search.zig` folds it in Zig. Fix: `find_tools` uses `word_search.zig` (D216).
- **Catalog read twice** (T, #974 and #970). C1b reads the shipped catalog, but C2a saves a refreshed one that nothing reads. Fix: one run-time choice, saved first and shipped as the fallback (D79). **D229:** a model the catalog doesn't list accepts any effort.
- **Naming and numbering.** "Host catalog" becomes "Host tool set" (D225). C2a takes schema 55 rather than rewriting 54 (D226).
- **Engine branches above the seam** (Store). Code outside the Store tells the engines apart four different ways, and the Store id is kept three times on MySQL. Fix: one `Target` open, and engine facts asked of the adapter.
- **A sent call still ends as failed or cancelled** (M). D60 and D146 say "outcome unknown". Fix it with the runner interface.
- **Two spec spellings on the wire** (L, #969): camelCase in presets, snake_case in `/v1/configure`. Fix: camelCase everywhere (D172).
- **Also open:** the D179/D219 `model_call` row isn't built, D178 (create with a parent) isn't built, and the D137/D218 refused-effort path has no owner.

## Ledger updates
D230 records that PR 7 built a combining queue instead of a Store thread, and that MySQL reconnect is deferred to 8e. D76's "older models get no additional_tools" clause should be dropped, because applying it would need a model list.

## Clean
T: #875, #897, #910, #927, #943, #956. K: #884, #886, #911, #912, #926, #950, #952, #962. M and L: #874, #877, #880, #883, #893, #895, #898, #900–#902, #906, #909, #913, #919, #930, #941, #955. Store: #862, #863, #870, #871, #873, #885, #918, #929.
