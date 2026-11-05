# Design audit, lane T (tools, codec, catalog), 2026-11-05

Scope: landed #875 T1a, #887 T1b-1, #897 T1b-2, #910 T1c, #879 T2, #915 T3, #920 T1d-1, #923 T1e, #927 T1d-2, #943 T1d-3, #954 T4a, #956 C1a, #928; open #976 T4b, #974 C1b (on S1), #970 C2a.
Read at origin/main 98d5acd97 and the PR heads. Line numbers are on origin/main unless the finding names a PR branch.

## Findings

1. **The tools_mask survives under the tool sets, and settlement checks calls against it.** #887, #915, #954, extended by #976. D48, D49, D54, D110.
   - The code: `tool_set.zig:47-57 maskSql` and `:75 everMaskSql` turn a saved set back into a built-in bitmask. `model_settlement.zig:544,1185-1202` builds `Offered` from that mask through `ToolSet` and the compiled records (`tools.zig:243-275, 507-523`). Request rendering, by contrast, reads the saved records (`historical.zig:520-560`). So the fact "what Operation k offered" lives in two places. An MCP member maps to bit 0 ("unknown until Rui runs it", tool_set.zig:49-51), so a call to an offered MCP tool settles `unknown_tool`, and a withdrawn MCP tool can never get "This tool was removed." #976 grows the mask to 6 bits (`toolBit .find_tools => 32`).
   - Intended: D48 says the record replaces `tools_mask`, and D49 says a call is checked against the records the request offered.
   - Severity: **blocks Drift**, because M3b's MCP calls cannot settle.
   - Fix: settlement reads the offered set's members (name, owner, server, record id) from the same `tool_set` that rendering reads. `Offered` becomes a slice of saved records. `withdrawn` becomes the names present in an earlier revision's set and absent from this one, worked out in SQL. Delete `toolBit`, `maskSql`, `everMaskSql`, `ofMask`, `all_tools_mask` and `configuration.toolSet(mask)`. Land this before M3b.

2. **Each built-in tool is a special case in about eight places.** #875, grown by K0/K5 and #976. D46, D48, codebase-design lens.
   - The code: one tool means a `BuiltInTool` tag (`built_in_tool.zig:9`), a `record()` arm (`tools.zig:207`), a pointer test in `Runner.of` (`:199`), a `Call` arm and a `describe` arm (`:291-330`), a `CallFacts` field (`:533-560`), a name compare in `inspectCall` (`:589-600`), a `toolBit` and a `<tool>_name` argument on every `core_facts` read (#976 `command.zig:452,635,724`). The interface is as large as the implementation, and adding `find_tools` touched every one of these.
   - Severity: design debt.
   - Fix: one core-tool table of `{record, runner, describe, check}`. `inspectCall` looks the name up once. `core_facts` takes the set of core names. With finding 1 done, the enum is needed only to seed the Host's built-ins.

3. **Turning `web_search` on or off costs a cache miss, and the ledger does not record that.** #915, `ARCHITECTURE.md:883-884`. D53.
   - The code: under v2, provider-run tools stay in the top-level `tools`, because the probe (`research/responses-tools-probe`) showed a hosted tool inside `additional_tools` is silently ignored. Toggling one changes the top.
   - Intended: D53 says nothing costs a cache miss.
   - Severity: design debt.
   - Fix: log a D-line that accepts this exception, citing the probe. Or decide that provider-run tools are fixed at Session start, so the change becomes an error (or a new Session) rather than a silent miss.

4. **D76's clause on gpt-5.5 is neither built nor replaced.** #915, #879. D76.
   - The code: every new Session pins `openai-responses/2` (`provider_name.zig` facts), and v2 declares tools in the history for any model. The probe ran only on gpt-6.1-sol.
   - Intended: D76 says "gpt-5.5 and older do not get `additional_tools`". Building that would need a model list, which D56 and D77 forbid. The code rightly has none.
   - Severity: design debt.
   - Fix: log a line that drops D76's model clause, or probe gpt-5.5 once and record the result.

5. **The refused-effort path is not built.** #879. D137, D218.
   - The code: nothing retries without the `configuration_update` item, keeps the old effort, or writes the "effort change refused" `session_changed` row. A grep on main finds no such path. Build-plan T2 included it, and D218 expects these rows. No open unit owns it now.
   - Severity: design debt.
   - Fix: give it a unit (T2b) or log it as deferred.

6. **One `find_tools` call is one revision and one row.** #976, `store/domain/find_tools.zig run()`. D138.
   - The code: one call loads up to 8 tools as one revision with one `loaded_tools` row. The limits of 1-8 words and at most 8 loads per call are not in the ledger.
   - Intended: D138 says every tool that `find_tools` loads is its own change-list entry with its own row.
   - Severity: nit.
   - Fix: keep the simpler shape and log "one `find_tools` call is one revision", together with the two caps.

7. **`find_tools` brings a second word-search engine.** #976 against #968 F3. D216, cross-PR coherence.
   - The code: #976 matches in SQL with two new markers, `@contains_ascii` and `@content_contains_ascii` (`rsql.zig`). Folding is done by SQLite `lower()`, by a 26-step `REPLACE` chain on MySQL, and by joining adjacent MySQL chunks. F3 already landed `word_search.zig` (`fold`, a streaming `Matcher` with a carry) as D216 requires: "SQL only narrows... folding defined once in Zig". The same rule now lives in two engines, with two folding definitions.
   - Severity: design debt.
   - Fix: SQL lists the candidate unloaded members. Their names and descriptions stream through `word_search.Matcher`. Drop the two rsql markers.

8. **"Host catalog" is a new name for concepts the ledger already has.** #920, #923. `tools.zig:103 Catalog`, `schema.zig:476-488 host_catalog`. D50, D110, D119, D147.
   - The concept is in the ledger: D50 is the Host's list of tools, and D147/D119's "saved tool copies" are what an unreachable server keeps. The shape is good: one saved set of records stored by content, and a Session's set is selected from it by name.
   - The name and the table are new and not logged. "Catalog" collides with the model catalog (D78-D81, the C units) and with ARCHITECTURE's "Tool Catalog", which means the model-visible definitions.
   - Severity: design debt.
   - Fix: log a D-line along these lines: "the Host tool set is the set the last Host start saved; an unreachable server's saved copies are its members with that `server`". Rename the type and table to `HostTools`/`host_tool_set`, so "catalog" means models only.

9. **"Which set does a request offer" is computed in many places.** #954. D49, D174.
   - The code: `coalesce(loaded_tool_set_id,tool_set_id)` is written out in `historical.zig:682,684,688,1031`, `model_settlement.zig:544`, `tool_set.zig:75` and #976 `find_tools.zig`.
   - Severity: nit.
   - Fix: one SQL helper, `tool_set.offeredSql(rev)`. Or store the loaded set as non-null, which also removes the NULL-means-equal special case.

10. **New configure codes and a storage rule are not in the ledger.** #920, #954.
    - The codes `unknown_tool`, `loaded_tools_not_in_tools` and `loaded_tools_unreachable` are new.
    - The rule that NULL `loaded_tool_set_id` means "all of `tools`" is new.
    - The rule for a `tools` change that omits `loaded_tools` (`ARCHITECTURE.md`, T4a paragraph) is new.
    - Severity: nit.
    - Fix: log all of them.

11. **`tool_record.owner` stores something close to "who runs it".** #887, #923, `schema.zig:432`. D46, R9.
    - The code: `owner` stores `rui|provider|mcp`, next to `server`. Who runs a tool is then derived partly from `owner` and partly from pointer identity (`Runner.of`).
    - Intended: D46 says the runner is derived, not stored, and R9 was replaced.
    - Severity: nit.
    - Fix: say in the ledger that `owner` is the "owning server" kind of D48, not the runner. Derive the runner in one place, which is the table from finding 2.

12. **The saved catalog has no reader, and the OpenAI id list is in two places.** #974 C1b against #970 C2a. D79, D153, D154.
    - The code: C1b's `model_capability.zig` reads `catalog.shipped` directly, and partly at comptime (`model_help`, `ids_without_max_effort`, `model_catalog.openai_ids`). C2a saves `model_fact` and has an `openai_ids` SQL read that nothing calls. Its own text says "admission/compaction still read the compiled table". The OpenAI id list exists both as comptime `openai_ids` and as SQL `model_facts.openai_ids`.
    - Intended: D79's fallback order (saved, then shipped) needs a catalog chosen at run time.
    - Severity: design debt.
    - Fix: the Host holds one runtime catalog value, a sorted entries slice: the saved one if present, else shipped. `model_capability` functions take that value, and `model_list` and the help text read it. C2a should land this wiring. Otherwise the seam has one adapter, shipped, and the saved catalog is dead data.

13. **Any effort on an unlisted model is refused.** #974, `configuration.zig:255` with `model_capability.supportsReasoningEffort`. D137, D80, D194, D208.
    - The code: `supportsReasoningEffort` returns false for a model the catalog lacks, so any effort on such a model is refused as `unsupported_reasoning_effort`.
    - Intended: D137 checks effort only "when the model is known". D80 and D194 say a new model works at once with the spec's values, and a provider refusal is the faithful error.
    - Severity: design debt.
    - Fix: for an unknown model, accept any effort in the grammar.

14. **One provider is baked into the catalog format and the Store schema.** #956 `models_dev.zig` parse, `model_catalog.zig:12 Entry.openai`; #970 `model_fact.openai`. D78, D151, D154.
    - The code: the provider name `openai` is fixed in the catalog's entry format, and C2a writes it into the Store schema.
    - D151 and D154 do ask for this. D78 says model facts are "not per provider".
    - Severity: nit.
    - Fix: name the flag for what it means (`openai_listed`, used for the D151 merge and the D154 list). Keep it out of any core logic other than those two.

15. **A client default sits in the core provider table.** #974, `provider_name.zig:44 default_compaction_trigger = 244800`. D207.
    - The code: D207's client product default sits in the core provider-facts switch, while `product_defaults.zig` owns client defaults. Separately, `model_list = .table` and `Source.table`/`table_fallback` keep the name of the hand table they no longer refer to.
    - Severity: nit.
    - Fix: move the value to `product_defaults` and key it by provider. Rename `table` to `catalog`.

16. **C2a edits schema 54 instead of bumping.** #970, `schema.zig` 53→54 step. D173, D215.
    - The code: `model_fact` and `model_catalog_source` are folded into the existing 53→54 step, and 54's bootstrap digest is rewritten. Schema 54 is not released (the newest tag is v0.53.1), but it is already shared by K2/K3, 8b and T4a.
    - Intended: D173 says each format PR bumps its own version.
    - Severity: design debt, process.
    - Fix: either log "PRs may share an unreleased version", or bump to 55.

17. **`model_fact.efforts` is stored as a raw bit mask.** #970.
    - The code: the column holds the bit mask of `EnumSet(ReasoningEffort)`, so the Store format depends on the order of the Zig enum's tags.
    - Severity: nit.
    - Fix: add a CHECK on its range and pin the order with a comment and test, or store the effort names as text.

## Fidelity checks that passed

- D48: records are stored once by content, the digest covers name, owner, server and both texts, and a reworded tool becomes a new record (#875, #887, #923).
- D174 is followed. There is no new change table: revisions and the Operations' frozen settings are the change list. The core-made key `rui.core/find_tools/<action>` goes through `core_command` (#976).
- D53 and D75 are followed. The v2 codec works out effort and tool declarations by comparing Operation k with Operation k-1 from saved facts, starts again at a compaction anchor, and has no model list or model favourites in codec or core (#879, #915).
- D78: one entry per model id, from a generated snapshot. The hand-copied Codex rows are deleted in C1b. D151's merge rule is implemented in `models_dev.parse`.

## PRs that match the design cleanly

- #875 T1a, as a staged step. Finding 1 is a T1b follow-up.
- #897 T1b-2: `tools` as names, D214 grammar.
- #910 T1c: providers list the tools they run, and `provider_tool_missing` (D47, D150).
- #927 T1d-2 and #943 T1d-3: reports and list rows carry tool names.
- #956 C1a: shipped catalog, apart from nit 14.
- #928: no design surface in this lane.
