# Store transactions and representation

[Architecture](../../ARCHITECTURE.md) owns shared guarantees, terminology, and the source map.
[Verification](../../VERIFICATION.md) owns global evidence rules and gates.

## Accepted contract

### Canonical state and transactions

Canonical relations are the source of truth, not a second lifecycle image.
Relational constraints enforce identities, parentage, ordering, at-most-once message selection and projection, one active Turn per Session, one terminal Turn outcome, one optional final Resolution per Operation, exact request bindings and content publication with its first durable reference.
No ledger/reducer image, permanent Completion, separate Resolution ID, cached lifecycle phase or shadow frontier duplicates authority.

One meaningful mutation owns one cohesive function.
It validates bounded syntax/content, reserves custody if admitting execution, then enters `BEGIN IMMEDIATE`.
Inside the transaction it performs bounded current-state checks and guarded writes, then verifies affected rows.
State-dependent checks stay inside.
Only after commit may it release the consequence.
Rollback releases unused reservation and grants no dispatch.
Private helpers may simplify calculation/query mechanics without a mandatory classifier framework.

Every Store entry point runs its locked body through one canonical access that declares the body's ordinary outcomes, such as a missing Session, a stale binding or a superseding control; a declared outcome the body cannot return fails to compile.
The Store returns ordinary outcomes unchanged and fences itself on every other error from the body, including a failed SQLite step, before the caller sees it.
Argument checks before the lock return without fencing.
A caller may still escalate an ordinary outcome, such as a stale settlement, to a dispatch fence.
A public read never escalates.
It answers its ordinary refusal, such as `ContentIsParts`, to the caller, and dispatch fences only when the Store has fenced itself.

### Store format and upgrades

The Store's format version is the `format` row of `store_meta`, and SQLite's `PRAGMA user_version` repeats it so an older binary refuses the file cheaply.
Before any write, open compares the format and then each table's and index's stored CREATE text with the DDL this binary renders, so a Store missing an object, holding an extra one, or carrying a changed column, CHECK or index is refused as the wrong schema.
The Host opens schema 51 (41 let a failed, overflowed or retry-exhausted Turn outcome reference its report content; 42 saves each Model Output Item's replay rule, judged once at import, and replaces raw items with the neutral form: `model_output_item` keeps kind, phase, part count and an item bag; `model_output_part` keeps each part's array, kind, text and part bag; no answer or string projection tables remain; and content payloads are non-null with their recorded length; 43 certifies a Tool Call by its name, call ID and arguments only, since the provider item ID lives in the item bag, stores usage as four neutral counts beside the provider's report, pins each Session's codec (`openai-responses/1` for `codex`) and optional codec options of at most 512 bytes at creation, checks a provider label's syntax instead of a provider list, so adding a provider is no format change, and keeps each Session's [prefix seal](model-io.md#prefix-seal); 44 stores a message's text once, as the item's message text row, with each text part keeping only its length into it, while a reasoning part keeps its own private row; 45 orders the index of Messages without a Session sender by Admission position; 46 names each Tool Call's Session on its row, and indexes every Activity row source by Session and position, so an Activity page is a range seek whatever the history's length; 47 makes the schema's tables expressible on SQLite, Postgres and MySQL and holds every statement to the reserved-name and `rowid` rules: no name any engine reserves outside its keyword place, no `rowid` (Sessions carry `created_seq` and Commands `command_seq`, each allocated max+1 in its creating transaction), a stored Workspace digest and key, foreign keys checked when each row is written rather than at commit, non-null key columns, byte-length checks, and the format marker in `store_meta`, while statements keep SQLite-only forms such as `unixepoch`, `GLOB`, `||`, `IS`, `INDEXED BY`, `ON CONFLICT`, `INSERT OR IGNORE` and `printf` until the typed statements bring their dialect rules; 48 and 49 record OpenAI web search; 50 drops the per-Session read-through position that 46 added; 51 makes a Command's `command_seq` its primary key and `command_key` unique, and indexes Commands by target, kind and `command_seq` in place of `command_seq`'s own index, so a Session's decisions, stops and interruptions are a range seek, and indexes Tool Calls by Session, Operation and call ordinal, and rejected Tool Calls and resolved Actions by Session, Operation and acceptance position, in place of the rejected calls' index by Operation, so a Session's calls and Tool Results are a range seek on their own tables, indexes revisions by Session and content so a Full report finds each content's first revision in SQL, and limits `store_meta`'s key to its three names, because MySQL keys only bounded text): a Store at any earlier version is rejected as unsupported and requires a compatible build or a separate fresh Store.
Schema 51 is the migration baseline (Divyansh, D204): every later format change ships one forward step in `schema.migrations`, for SQLite and MySQL, and the build fails when `schema_version` and the steps disagree, and `tests/ci/test_store_schema_version.py` fails when a step whose `from` is below the released schema_version differs from its text at the release.
A SQLite Store at a format from 51 up to the current one takes each pending step at open, in one transaction that also sets its format, and commits only when every foreign key holds and every object's text equals a fresh bootstrap's; otherwise nothing changes and the Store is refused.
The typed statement marker `@index(name)` renders as `INDEXED BY name` on SQLite.
On MySQL it renders as `FORCE INDEX (name)` only when `schema.mysqlCanForceIndex` confirms that the named MySQL DDL index uses real columns; generated-leading and functional partial indexes remain unhinted, since forcing their lowered keys can turn a lookup into a full index scan.
MySQL open includes every forceable index's canonical name in its catalog comparison and refuses a renamed index as `store_schema_behind` before any write; server-generated keys remain checked by definition.
This admission digest is computed, not stored or pinned by Store format, so tightening its comparison changes no format or migration.
Rui runs no DDL on MySQL (D203).
`rui store schema --engine mysql` prints this build's canonical `schema.ddl(.mysql)` as one SQL file for the DB team to apply to an empty database.
With `--from N` it instead prints every forward MySQL migration from format N to this build's format, oldest first (D223); the current format prints empty stdout successfully, and formats outside the migration baseline through the current format are usage errors naming that range, with no stdout.
The composed migration finishes with one update of the saved format to this build's value; individual steps remain `schema.mysqlMigration(from)`, and this command never applies the SQL.
The step to 52 lets tool records name an MCP server and keeps the Host tool set (T1e).
The step to 53 records a Session's parent (D27).
The step to 54 records the stops and ending Messages an attached child owes (D38, D39), ancestor feed forwarding in `session_forward` (D135, D180), and gives each Store a random `store_id` in `store_meta`, which a Store needs to open.
The step to 67 folds the separate ending-Message queue into the first-hop forward row, preserving unsettled Messages and settled/suppressed status across upgrade before dropping `session_ending_owed`.
On MySQL it also adds the `store_owner` row a Host's ownership fence checks and the `content_chunk` rows that hold content bytes in place of `content.payload`, and gives each non-unique partial index a generated first column that is NULL where its predicate fails, so a walk of one Session's rows skips the rows SQLite's index leaves out.
The step to 55 adds the saved model facts and their catalog source.
The step to 56 adds the bounded outcome-unknown Message recovery index and moves saved wire 8 metadata to wire 9.
The step to 57 adds archive intents and requested archive values, extends the command kind set, while retaining the unreleased wire 9.
The step to 58 moves saved wire 9 metadata to wire 10 for nullable failed-send peers; it changes no saved command or refusal rows.
The step to 59 adds immutable skill catalog metadata and its ordinary turnless instruction provenance, retaining unreleased wire 10 without rewriting earlier Conversation content.
The step to 60 adds `message_skill` and the Conversation's skill entries (kind 4, naming their `message_skill` row), rebuilding `conversation_entry` on both engines, and moves Store wire metadata to 11; earlier rows are unchanged.
The step to 61 widens saved call descriptions on `model_tool_call` and `model_output_item` to 200 UTF-8 bytes on both engines; existing rows need no rewrite.
The step to 63 drops `model_operation.usage_content_id`, rebuilding `model_operation` on SQLite, and deletes each saved raw usage report no other row references; the four counts are unchanged, and the file keeps the freed pages until it is vacuumed.
The step to 64 renames `host_catalog` to `host_tool_set` and `action_operation.bash_timeout_ms` to `attempt_timeout_ms`, without changing their contents.
The step to 65 freezes each Operation's effective tool offer, retaining its settings revision's offer for old Operations.
The step to 66 freezes configured effort sources and admitted effort emission/fallback, records immutable refusal provenance in `session_change`, and moves saved wire 12 metadata to 13.
The step to 68 (D179, D219) adds nullable final-attempt `latency_ms` and `first_event_ms` to `model_operation`, without backfilling old resolutions.
The step to 69 freezes each model Operation's effective context window as a non-null integer in 0..4294967295, with no default (D238).
It backfills every old Operation using its frozen settings revision's exact model and a literal mapping of the pre-change shipped snapshot, using 128,000 for absent or null windows, not the mutable saved catalog.
This pins legacy escalation policy; the old rows did not retain their admission-time saved window, and migration does not claim to recover it.
Existing floors, levels, counts, resolutions and references are preserved.
The step to 74 deletes the saved wire label from `store_meta` on both engines (Divyansh, 2026-11-13), whatever it reads; a new Store writes none and opening compares none.
`store_meta`'s key CHECK still names `wire_version`, because narrowing it would rebuild the table on SQLite.
The step to 75 adds retained current pin pointers and immutable requested pin values, and extends the Command kind set to include pinning.
A nullable unique `session_pin.command_key` references the immutable Command that established the current pin; its existing `command_seq` is the pin order.
Unpin and archive intent clear that pointer with a typed Session-head update, retaining the row.
The SQLite step preserves all Commands and their references while widening the kind CHECK.
The operator-run MySQL step resolves the exact old kind CHECK in the current database catalog, because its generated name can differ between fresh and previously migrated Stores.
An absent or ambiguous match refuses before DDL; unrelated checks and foreign keys remain unchanged.
The step to 80 adds nullable `session.creator_ref` as a foreign key to `session.session_ref`, with a CHECK excluding self-creation.
Both engine migrations backfill it from existing `parent_ref` values and leave unknown historical detached creators null.
Validated creation writes this immutable provenance for attached and detached children; lifecycle attachment remains in `parent_ref`.
[Session provenance](sessions.md#session-provenance) owns the distinction and its public meaning.
The step to 82 records each Message admission's source kind, backfills it from the sender and source Action, and indexes person inputs by that kind. Kinds 4 and 5 are reserved for future sources.
The step to 84 adds an index on creator and Session references for creator-subtree reads.
The step to 88 fills each null `session.creator_ref` from the Session sender of that Session's first admitted Message when the sender is another Session, the rule [Session provenance](sessions.md#session-provenance) applies to new admissions; it sets no `parent_ref` and changes no existing creator.
The step to 89 adds `core_command.missing_settings`, the set of settings a `missing_settings` rejection named (bits of model 1, Workspace 2, provider 4), set exactly when the code is `missing_settings`; it deletes saved `incomplete_initial_configuration` rejections and their sender rejection entries, which recorded no set, so their keys become fresh and their senders' feeds lose those refusal entries. The content those rows referenced, such as a refused Message's text, stays in `content` unreferenced: no Store step or transition deletes content, and a migration that tried would have to prove no other row shares it.
The step to 90 keeps each MCP tool's name as its server listed it, beside the offered name: `tool_record.remote_name` is empty when it equals the offered name, so every row saved before the step keeps its meaning and digest.
The step to 92 adds the `app` tool record owner and the app policy columns `replay`, `restart_limit` and `wait_ms`, with CHECKs that keep them zero on every other owner and bounded on `app`; every existing row takes the zero policy, so its meaning and digest are unchanged, and the unique key includes the policy.
SQLite rebuilds `tool_record` at 92 and MySQL adds the columns and replaces the owner CHECK.
The step to 93 moves the codec and its codec options from each Session to each of its revisions, so an Operation's Binding is read from its frozen revision; every existing revision takes its Session's values, and the Session keeps no codec.
The step to 94 adds `session.app_tool_set_id`, the content-addressed app tool set a Session declares (NULL: none), and `session.app_lane`, the lane root whose declaration the Session runs on; [the app lane rule](sessions.md#app-lane) owns what a lane is and how a child takes one. `app_lane` is fixed at creation and never updated. Each existing Session takes the lane of its root, read from `parent_ref` by one recursive pass; no existing Session declares app tools. An existing detached child therefore starts its own lane: before 94 the Store records no fact that separates a creation parent from a provenance-only sender (both set `creator_ref` alone), so the step does not guess one from command keys. Sessions created after the step take their lane at creation by the app lane rule. Both columns are added in place on SQLite and MySQL, with their foreign keys and CHECKs (a zero declaration and a malformed lane are refused). The step changes no existing row's meaning: every Session without a declaration keeps its behaviour. The same step adds `session_revision.app_tool_set_id`, so each revision keeps the declaration its configure set. A configure that carries `appTools` validates the declaration once (`tool_record.app_tools`) and saves its records as one content-addressed tool set in the same transaction as the Session update; an empty list or null clears the set.
Each format PR appends its own version and step; even unreleased steps and digests already on main are immutable (D226).
The schema writes each closed value set as fixed literals, so the Store format never silently follows a code enum, and changing a set is a format change that needs a new version.
Provider labels and codec names are open by design (Divyansh, 2026-10-31 provider-plugin design): the schema checks their syntax, and a Host refuses a label or codec it does not serve.
Sessions store a Label and creation time.
A Session's revisions each pin their codec and codec options as part of their immutable binding; a read for a revision whose pinned codec or options this Host cannot build requests with fences rather than re-encoding under another grammar.
The Store records the Host Unix second at which each state-bearing fact committed: a Turn outcome; a model Operation's Attempt admission, retry scheduling and resolution, exactly one of which is set, matching its state; an Action's authorization, first launch and resolution; and a Session stop, a refused send and a Conversation entry.
CHECKs tie each time's nullness to its row's state, so no writer can leave a stale or missing time.
A Turn's state is `outcome_code`, so `outcome_at` is tied to it rather than to `outcome_position`: Session work reads the time of a Turn whose code is set, and the position is a separate claim that activity revalidation requires exactly when the code is set, so a valid Store has all three together.
`turn.continuation_operation_id` stores one derived fact: the current Operation of an active Turn that can continue without input, because that Operation resolved as `answer`, `compacted` or `context_overflow`, or every one of its tool calls was fulfilled by a rejection, its Action Resolution or an accepted immutable background receipt.
One Store helper owns the column: it evaluates that predicate and sets the column inside every transaction that can make it true.
It is stored because it keys the `turn_tool_continuation` partial index, so tool continuation selection walks only ready Turns in Operation order instead of every active Turn.
The index holds at most one entry per Session, its active Turn.
Admitting the Turn's next Operation moves `operation_id` past the stored value, which retires the index entry without a clearing write, and a CHECK keeps the stored value at or below `operation_id`.
When neither selection finds work, the Store checks every active Turn's stored fact against the predicate and fences on any disagreement, because a missed write would leave the Turn waiting forever.
A partial index holds each recipient's Messages without a Session sender by Admission position, and the stop-exclusion index is ordered by cutoff and then position.
Three partial indexes that are empty in a valid Store let activity revalidation prove that no row lacks its position without reading history.
Four lifecycle CHECKs are null-total, because SQLite accepts a CHECK that evaluates to NULL.
Each model Operation's retry allowance derives from `attempt_ordinal`, its sole durable Attempt ordinal, and its uncertainty from an absent Resolution with a zero `retry_due_at_ms`, so neither has a column of its own.
An Action stores one permission fact, `authorized`, set only when the Action is proposed under a `bypass` revision or an accepted `allow_once` decision names it; it is stored because it keys the admission index, which cannot see revisions or decisions.
A denial is the `denied` Resolution, which a CHECK keeps apart from `authorized`.
Configuration revisions, like Sessions, accept only `permission_mode` 0 (`ask`) and 1 (`bypass`).
`model_operation.auth_refresh_claimed` records that an Operation has used its one credential refresh.
Without that fact, a 401 after a refreshed 401 and an intervening transient failure would leave the same saved row as a first 401 after two transient failures, so no rule could allow exactly one refresh per Operation.
Sessions, configuration revisions and model Operations store nullable reasoning effort.
The format admits initial configuration revisions under their first Message command and saves configuration rejection codes for initial Messages.
Session IDs are six lowercase Crockford characters, with nullable, unique Action sender handles.
Saved tool masks are restricted to no tools or Bash, without an unavailable-tool rejection code or Edit catalog entry.
The format retains per-message public text certificates on Model Output Items and the exact source item ordinal on assistant Conversation entries, content metadata before its payload, nullable nonnegative usage counts and selected-Turn stop indexes.
There is no backward compatibility by default: beyond D204's forward steps, old-Store readers, dual formats and compatibility aliases require Divyansh's explicit authorization.
An unsupported Store must fail promptly in foreground and detached startup, naming the Store, found and supported versions, and recovery options without modifying saved work.

Model Operation outcomes record output facts (`answer`, `tool_proposals`, `compacted`) independently of whether the Turn completes or continues; a completed Turn still records `completed`.
Provider failure classes preserve ordinary, context-overflow and retryable facts, with Turn and compaction policy deciding continuation inside the Store transaction.
Provider adapters own grammar and interpretation.
The Store owns identity, provenance, proposal authentication and atomic publication of immutable neutral items and provider bags with certified public text; tool classification is a pure decision invoked inside that transaction.

Usage counts are the only usage the Store keeps; the provider's raw usage report is not retained.
The provider parser admits only counts within SQLite's signed integer range, and their sum saturates at its maximum, preserving every compaction-threshold decision.
Served-model observations are one opaque bounded `model_evidence` BLOB: version byte `1`, followed by three little-endian unsigned 16-bit byte lengths and their exact UTF-8 bytes, in body, `openai-model`, `x-openai-model` order.
A zero length means that source was absent; requested identity is never substituted.
The adapter certifies each valid source independently even when their values differ.
The maximum certificate is 775 bytes (three sources of at most 256 bytes each).
The Store persists these bytes without interpreting provider grammar.
Stores older than the migration baseline are rejected, not replayed through an old reader or migrated.

Recovery is an explicit choice: use a compatible build at the original Store path, or back up the stopped Store and select a separate fresh Store.
Rui never automatically recreates an incompatible Store.
Store identity binds the canonical original path; moving or copying its directory does not relocate that identity.
A SQLite selector mismatch refuses startup with `store_identity_mismatch` (exit 6), naming the saved original and actual canonical folders without changing the identity.
Restoring a backup requires exclusive access to the original path and preservation of any replacement Store before restoration.
The [recovery instructions](../store-reset.md) leave the original Store untouched.

The Host runs a SQLite Store's pending migrations at startup under its Store ownership lock, and first backs the Store up itself, with no approval prompt: SQLite's online backup API copies `<name>.sqlite3` beside itself as `<name>.backup`, a path one byte shorter so it fits wherever the Store does, replacing an earlier copy and touching no other file, and syncs the copy and its directory.
If the backup fails, nothing migrates and the Store is refused.
The copy is as large as the Store and stays until the next migration replaces it or the user deletes it.
On MySQL, backing the Store up before applying a migration's text is the DB team's job.
Installation alone does not open the Store for writes, migrate it, reset it or change credentials.
The schema owns `migration_baseline` and current format at Host startup; unequal formats are not necessarily incompatible, and version punctuation does not establish the supported range.
The report distinguishes unchanged, supported through startup migration, unsupported and unknown compatibility.
If candidate facts are absent, it reports unknown and leaves validation to Host startup without starting a candidate Host to probe it.
The installer's read-only Store probe uses the defaults-selected Store, which is not necessarily the client's explicitly selected active Store.
MySQL schema application and backup remain operator-owned.

`rui upgrade` replaces an eligible managed released selection with the latest published stable release, then calls the same restart-all core as `rui host restart --all` for every running same-user Host. The read-only check names the discovered Host count, Stores and unsupported reasons.
`rui upgrade --check` is read-only and starts no Host.
Shell `rui upgrade` prints its check report, then one line naming what it does next (`Installing Rui 0.83.0...`, or that the selected release is published again), then a result whose first line is the verdict (`Upgraded to Rui 0.83.0` or `Installation unchanged at Rui 0.83.0`) before any Host line.
The sidebar version button and the Version row of app settings start the same Upgrade run, available from the overview or with a conversation open. The sidebar draws compact progress in place; Settings retains its Version feedback, without sending a command to the model or adding an updater service.
The overview owns the one run and runs its worker once its own and the conversation's Client work has settled; both screens hand Esc to that run.
At startup the same UpgradeJob owner first completes the selected installation probe, including its cancellable `--version` child, before any release HTTP request. It then performs one read-only release discovery, without a Host census, Host hold or installation. It publishes only the optional newer version to the presentation core. The job retains the validated release candidate and its Download owner. A requested upgrade joins that discovery and passes both into the check/install path without fetching release metadata or checksums again; fresh installation inspection and the Host census still happen after the request. A request adopting in-flight discovery retains its failure or cancellation as the attempt outcome. An already-observed background failure stays quiet until a user request begins a fresh attempt; a later retry starts with a fresh Download owner.
It checks (`Checking for updates…`), then installs a found release at once, with no Enter step even while Sessions work, and its first line says what the restart will do: `Preparing Upgrade · restarts every eligible Host (2 found) · esc cancels`.
Esc cancels while it checks or prepares, before Esc clears the draft, and not once publishing starts (`Publishing; cancelling no longer rolls back`); the overview can then say `Restarting Hosts…`. The sidebar keeps `Updating…` until completion, then shows the installed number quietly or a retryable `Update failed`; completion creates no global footer notice.
When this run installs a different Rui, compatible or incompatible with the old client, the terminal leaves through its ordinary cancellation, save-flush and restoration path, then the CLI replaces its process image with the published selection's `bin/rui` (same PID and terminal, never PATH or the old executable).
It reopens the overview or the same conversation (`Overview.Options.open`), pinning the old client's actual canonical Store explicitly and preserving its explicit `--provider` and `--model` selectors, every per-Session chat draft, including the open editor's bytes, caret, recall anchor and rejection state; the overview has no draft.
A changed saved Store cannot redirect this restart.
The new screen shows the installed version quietly in the sidebar, with no upgrade notice in the chat footer; scroll position resets.
A run that installs nothing does not relaunch, even if it activates an already-selected Host build.
An unresolved capture or recovery handle, failed save, retained cleanup path, run failure, activation recovery/owner instruction or PATH warning prevents relaunch: ordinary departure guidance remains intact, including the old-client restart instruction when needed.
Old-client-only protocol/restart holds do not themselves prevent relaunch: verified target-public readiness with a new instance and the answering managed executable's target release version, bracketed by matching authenticated peer generations, is distinct from activation failure or uncertainty. A different wire grants no ordinary-request readiness or invented Host facts; a concurrent same-version owner can satisfy activation.
Timeouts, malformed replies, failed activation and uncertain/replacement identities still retain their recovery guidance.
Guidance already known keeps the old screen open; resolving it later does not turn an ordinary quit into a delayed relaunch, and a later successful run cannot swallow an earlier retained report.
If handoff preparation or process replacement fails, the ordinary departure remains; replacement failure also says the new Rui could not be started.
Shell `rui upgrade` never replaces another terminal's client.
Divyansh chose in-place TUI restart on 2026-11-12, superseding manual restart after a successful inline installation.
Esc cancels the check as it cancels an install still preparing, and so does leaving rui.
The Upgrade worker says where the whole run stands (checking, installing and its step, cancelling, ended) each time that changes, and the overview stores that one value (`session_upgrade.Upgrade`), which both screens read: Host requests wait, Esc is the run's and another Version-row activation is a no-op by it alone.
A conversation keeps only that its own reading of the Session predates a run: when the old client continues after a run that does not relaunch, it says `Reading this chat…` and holds its Host requests until that read settles, then resumes chat-only footer feedback. Upgrade feedback remains in the sidebar and Settings.
One pure core, `upgrade_status`, turns that value into the Settings Version field, sidebar update button and overview status line. A conversation never projects upgrade progress or completion into its footer.
`UpgradeJob.ending` alone derives the small failure reason from the run error: a download failure says "couldn't reach GitHub" even while settings hides the status bar. The restored shell report retains curl's last stderr line.
Divyansh chose this on 2026-11-09 (TUI rework plan, "/upgrade without a page"), replacing the `UpgradePanel` page and its Install step.
It retains the draft, selected Session and unresolved capture handles through handoff and never replays indeterminate effects.
Restart can interrupt work in every Session across all affected Stores, not only the selected Store.
No running Hosts means install only; absent Stores are not started. The pre-install census is warning-only: post-publication discovery includes Hosts started during preparation.

The TUI handoff is a cross-version contract: the departing binary writes it and the selected binary reads it.
`RUI_RELAUNCH` names an absolute `HOME/.rui-relaunch/<32 lowercase hexadecimal digits>.json` path; the directory is current-user-owned mode 0700, the exclusive random file is a current-user-owned regular file of mode 0600 with one link, and neither final component is followed through a symlink.
It belongs neither to the Store nor to a shared temporary directory.
Before fresh-Session admission, the CLI's one relaunch-startup owner consumes the environment value once, authenticates the location and file, unlinks the file before accepting its contents, and ignores missing, unreadable, malformed, unsupported-version or nonmatching canonical Store handoffs.
A valid handoff reenters existing work through the same startup owner as `rui session resume`, opening its conversation when present or the overview otherwise; unreadable preferences and absent local provider credentials cannot trigger fresh-session admission or login.
The CLI owns the decoded payload through that synchronous run; the overview restores per-Session drafts and the ending line before terminal startup and never rereads the environment or handoff file.
A failed cleanup names the retained private path rather than silently losing cleanup guidance.

Version 1 is compact UTF-8 JSON, with these fields in this order and explicit null/default fields:
`{"v":1,"store":"/store","open":null,"overview":{"bytes":"","cursor":0,"anchor":null,"rejected":null},"drafts":[],"line":""}`.
`open` is null or the six-byte Session ID to open; each `drafts` entry is `{"id":"k7m2qx","snapshot":<snapshot>}`, with no repeated ID.
`overview` remains in the shared v1 schema for compatibility. `Overview.zig` emits the empty snapshot shown above and ignores legacy overview snapshot bytes on restore; the unchanged generic `relaunch_handoff.zig` codec still validates and round-trips legacy nonempty snapshots.
Each per-Session `snapshot` preserves draft text in `bytes`, a byte-offset `cursor` at a UTF-8 boundary, a nullable recall `anchor` (`{"position":<u64>,"end":<u64>}`), and nullable `keymap.Refusal` tag text in `rejected`.
`line` retains the run's new-client ending for cross-version handoff compatibility: an incompatible old-client ending becomes `Upgraded to <version>` rather than asking for another restart; only a confirmed Host restart adds `Host restarted`. The current screen restores drafts and the open chat without displaying that global completion notice.
Each draft is bounded by `SessionInput.capacity`, the Store and ending line by their existing owner capacities, and the sparse draft population by the Session ID domain, not a smaller handoff-only limit.
The encoded size bound allows six JSON-escaped bytes per input byte plus fixed field/integer overhead for that population; the reader streams into owned decoded drafts rather than allocating the file's advertised size.
The exact v1 bytes are pinned in `relaunch_handoff.zig`.

The thin upgrade coordinator composes `InstallationOutcome` with the restart-all batch of per-Host outcomes. Under its publication lock, `Installation` records `Receipt.selected_after` and `selected_version` from the same chosen build. Upgrade revalidates that pinned build against the receipt identity, never selects through PATH or substitutes the discovered candidate, and calls the restart-all owner once.
Every versioned result (sidebar number, Settings field and relaunch handoff) uses that receipt version, even if another publisher won or restarting Hosts fails. A superseded unchanged publication carries the selected receipt version to the sidebar even when no Host restarted and the old client does not relaunch; only an available release newer than that selected version becomes an update offer. Before publication, the UI says `Preparing Upgrade` without promising a target version; publishing and restarting remain version-neutral. The optional available release comes only from read-only discovery and never substitutes for the publication receipt.
For each eligible Host the coordinator follows the [detached launch admission contract](host.md#detached-launch-admission), reobserves the exact old instance and process generation, stops it, and waits for process and runtime/Store lease retirement before starting the target. Check/start/status share the captured Host environment, cwd `/` and null stdin. Only `host_start.spawn` constructs Host-child argv; Lifecycle constructs public command argv, not a second launch specification.
Upgrade keeps no single-Store activation path. The TUI derives selected-Store compatibility from that Store's per-Host outcome; failure or unsupported-owner guidance from any Store remains visible and prevents a relaunch from swallowing it.
Per-Host result lines and totals are the same as the standalone command. A whole bounded typed start refusal crosses the batch and coordinator unchanged; known check/start refusals, failed or unconfirmed Hosts produce `host_restart_failed` (operate, exit 6) after reporting successful binary publication. Unsupported Hosts remain explained successful skips. Unknown future refusal codes or incomplete output never become success. Publication is never rolled back for a restart failure.
A replacement race, failed stop or start, or unsupported or application-owned launch configuration must not blindly stop another process and is reported as installed but not activated or unconfirmed as appropriate.
An already-installed target can still need activation of an older running Host.
Source and release installers invoke the newly published command's `rui host restart --all` after publication; failure prints its receipt and a note without failing or undoing installation.
`host_coordinator` owns restart-all and Upgrade activation in fresh processes that leave the inherited session before accepting a task, independent of the Bash tool (and Host) that launched the caller; no Host thread is added.
The coordinator process, like every other launch of "this same build" (a Host child, the Darwin malloc re-exec), runs the executable `self_executable` pinned at process start, because its task and event pipe are private to one build. Darwin's `std.process.executablePath` follows the launch path again on each call, and that path is usually the `~/.local/bin/rui` symlink publication repoints, so a later read names the newly published build; `tests/ci/platform_boundary.py` refuses any other reader.
Upgrade hands off the publication receipt's pinned target and HOME over a private bounded pipe. The worker runs the whole shared restart-all batch, with fresh discovery after publication; no checked launch snapshot or private Host environment crosses the pipe. There is no separate single-Host activation task.
Cancellation is checked before handoff; once accepted, the entire batch finishes retirement and pinned startup even if the caller departs or its report pipe closes.
Restart-all similarly completes every discovered target after the originating Host stops, without identifying that Host or reordering it last.
Closed stdout cannot abort remaining restarts: outcome counts are retained and receipts fall back to the existing optional stderr diagnostic boundary; closed diagnostics remain best-effort, not a new log registry.
`--all` is required (`option_required` without it); per-Store restart selection is not exposed yet.
`runtime_directory` alone owns per-user runtime naming, without creating a runtime directory or Store; `host_endpoint` owns the interface directories and their census. Client discovery unions those sockets with same-user process hints, uses serve_grammar's single running-source reader and existing saved DIR placement, then authenticates the resolved peer and hinted generation. DIR routing is retained independently of wire Store identity; unreadable positively identified Hosts get individual failures. No registry or start record is added.
Socket discovery retries transient refusal for at most 200 ms inside the shared observation deadline, and a census shares one 200 ms window across all its sockets, so unanswered sockets cost one window, not one each; failed transport alone never establishes absence.
A socket that still refuses or has vanished at connect gets a fresh look at its interface directory on every census path, including when the same-user process list cannot be read (`ps` fails or exits unsuccessfully), where the census also records its own failure. A free directory lock proves the endpoint dead and it is dropped silently either way, while a busy lock keeps its per-Host failure. A live but unreadable socket or a wrong wire keeps its per-Host failure.
The census in `host_endpoint` removes each derived interface directory whose lock it can hold and verify, and observes the rest: a directory whose lock is held by a live or starting Host is left alone, and an empty directory is removed. Legacy flat `<hash>.sock` sockets from older releases are not censused and are never removed.
A socket whose directory lock is busy, a socket node Rui did not make, or a connected unreadable peer remains unconfirmed and counts as a failure with its socket path and recovery advice.
The Store lease is never endpoint liveness and never authorizes removing a socket: only a free, verified interface directory lock proves a Host dead. A Host start sweeps the other derived interface directories with the same census, and a proven-dead endpoint is removed there and in discovery.
The client authenticates a socket peer, takes its launch Store as a hint, validates the canonical socket through `platform`, then confirms Store, PID and instance: a Host on the current wire answers a read-only Host-info request on that socket, and a Host on another wire is read through its own executable (see below).
Unreadable identities are reported rather than guessed; relative or unavailable Store hints cannot grant activation authority.
`host_restart_all` observes and activates one Host at a time through `HostLifecycle`, requiring the same discovered instance before activation; it keeps no Host registry or mirrored launch policy.
Its pure report function consumes every `ActivationOutcome` and `Limitation`, keeping each Host-directory-first line and success/failure category together; failures and unconfirmed restarts yield an operational caller error.
A new ready instance on DIR's socket whose answering managed executable has the target release version counts as restarted, even if a concurrent starter won. Neither an exact launched child nor the pinned executable path is required. For a different wire, target public status supplies bounded instance/Store/capacity facts bracketed by matching authenticated peer generations; only that complete proof permits `client_incompatible` success with selected-client advice. Negative final observations, unknown status envelopes and version/instance mismatches never establish success.
Already-target and newer Hosts remain untouched, and unsupported launches are left running with their reason.
Managed released and source Host builds are eligible; source Host versions come from their retained executable's bounded `--version` output through the same numeric version parser as restart-all's target.
Unknown managed, ineligible and foreign builds remain application-owned; a managed source build without a verified numeric version grants no activation plan.
Upgrade installation eligibility still requires a selected managed release, independently of the running Host's build kind; a source-started Host newer than that release is superseded without interruption, otherwise normal activation can restart it.
The target is the pinned installed selection, with a verified numeric version; an unversioned source target is reported without stopping Hosts.
No running Hosts prints `No running Hosts.` and starts nothing.
Source/release installers and `rui upgrade` use this one install-wide restart owner; only installation eligibility differs.

Lifecycle control observation is separate from ordinary client readiness.
Upgrade reads the complete bounded Host-info envelope on the current wire, with matching HTTP and body versions and peer PID from that same connection.
An explicit wrong-wire response names another wire, and that Host is observed through its own executable: `<exe> host status --store DIR` supplies its instance, Store, active capacity and settings digest, whatever wire its envelope carries. The envelope's version is never checked against ours, and no per-wire decoder exists.
Malformed, unavailable or unknown envelopes, an unreadable executable, and a failing or unparseable `host status` grant no authority and leave the Host running.
A Host on another wire is paused through its own executable with `host pause --store DIR --instance HEX` for the captured exact instance. Its process generation (gone or zombie) and runtime/Store lease must retire; a different authenticated owner holding the lease is eligible for adoption, never another stop. Control facts from another wire never grant Session access.
Target source admission precedes interruption and covers read/apply, detached rejection, placement/anchoring, provider finishing, resolution and sealing without database access. Targets with no check are refused before stop.
MySQL follows ordered stop then start: the replacement's own Store lock acquisition/readiness, not runtime retirement or coordinator SQL polling, proves database ownership. A typed start failure does not abandon later batch entries.
When departure guidance prevents relaunch, a terminal client that cannot speak the new Host's protocol retains its draft and unresolved handles in a local recovery hold rather than reattaching or resending work.

`src/Installation.zig` is the sole final publication owner; source and release shell installers invoke the same staged native helper.
A `release_candidate` follows the HTTPS redirect chain from `https://ruicode.com/releases/latest` and reads curl's effective URL, requiring the exact `https://github.com/DivyanshGolyan/rui/releases/tag/v` prefix and a canonical stable version.
It derives pinned SHA256SUMS and archive URLs on `https://ruicode.com/releases/download/vX.Y.Z/`, without GitHub's rate-limited JSON API. The archive must appear exactly once in SHA256SUMS; that membership and digest pin the candidate before archive download.
`upgrade_process.Download` owns curl options for release discovery, checksums, and archives in both CLI and terminal upgrades.
Each download has one 300-second deadline across at most two attempts, with a 10-second connection timeout on each attempt.
The first attempt uses the system's normal address-family selection.
An ordinary curl exit 6 or 28 permits one IPv4 retry only when at least 10 seconds remain on that same deadline.
With curl configuration files disabled and no other curl timeouts enabled, an early exit 28 is a connection-phase timeout, including DNS stalls after redirects.
An exhausted transfer deadline, cancellation, signals, HTTP errors, certificate errors, and other exit codes do not trigger a retry.
After an IPv4 retry succeeds, later downloads in that upgrade use IPv4 once. A fresh upgrade starts with normal selection again.
The retry replaces a partial archive rather than appending to it. SHA-256 verification and publication rules remain unchanged.
The released shell installer disables curl configuration files and applies the same exit-code and remaining-budget retry rule to its archive download, with conservative whole-second rounding of curl transfer time. The native updater uses the timeout and retry-code literals in `src/download_policy.zig` directly. Release generation reads those literals from the pinned source for the shell installer. It validates the downloaded archive before publication.
Recovery changes neither system DNS settings nor certificate verification. The existing checking and preparation UI remains unchanged.
A final nonzero curl exit is a distinct download failure, not release validation or preparation failure; nothing has been published.
The native bootstrap can download pinned SHA256SUMS and archive assets for historical v0.56.4 using the current native publication owner, without executing its old uncooperative installer.
A permanent prefix-scoped lock serializes participating writers, with final managed eligibility and numeric release-order checks under the lock.
External historical installers do not participate and have no new serialization or no-downgrade guarantee.
Intentional source installation retains its distinct replacement policy.
Automatic upgrade refuses selected source and unknown-identity builds; the standalone release installer can intentionally convert those managed selections without overwriting application-owned commands.
`installation_path` owns read-only PATH observations and sanitized advice shared by native clients and modern shell installers.
Complete builds remain available for running processes, but retained executables do not guarantee rollback after Store migration.

A release version has the form `0.S.N`.
`S` is the released commit's `schema_version`, and `N` counts earlier releases with the same schema.
The release workflow publishes qualified `main` commits, and versions never decrease.
The `stable` branch is a compatibility pointer to the last successfully published release, not another integration branch.
A build reports `unreleased` unless its commit has a matching release tag.
[Issue #523](https://github.com/DivyanshGolyan/rui/issues/523) records the approved decision and unresolved conversion and relocation work; it does not authorize a new migration or reset policy.

Development test Stores and associated configure captures are recreated for changed formats, not migrated.
This does not authorize recreating user Stores.
Public activity search was added to wire label `8` after v0.53.1 shipped it: an added request needs no new label, and an older Host answers it as unknown.
Wire label `8` changed after v0.50.0 shipped `7` when the Host dropped the `proposal_page` and `proposal_field` requests, and when the Activity page gained `kinds`, `limit` and the `received` row kind and the Host dropped the `person_message` request, which Divyansh asked for on 2026-11-03.
The Store keeps no wire label (format 74): a client and a Host compare the wire the running Host reports in `host_info` and refuse each other as incompatible, so a wire change needs no Store format step.
It has one canonical configure shape, which includes the omission-aware provider and Label fields, and one canonical Message shape, on which any Message may carry `require_model` (digest domain `rui/core/message/v4`, which binds the flag; a Message without it keeps its digest).
Pre-provider captures are not accepted or defaulted to Codex.

### Store durability

One thread at a time holds the Store: its connection, its scratch and its id allocator.
A caller that finds the Store free holds it and runs its entry point on its own thread; a caller that finds it busy queues its request and sleeps, and the holder runs queued requests in arrival order before it lets go, so each waiter wakes once, with its answer.
A holder runs at most 64 requests for others, then hands the Store to the next waiter.
Writes the holder runs back to back share one transaction: each later write runs in a savepoint, so a write that fails rolls back alone, and no caller hears its answer until the batch's COMMIT; a failed COMMIT fences the Store and every write in the batch hears the Store as fenced.
A lone write costs BEGIN and COMMIT, as before; on MySQL its COMMIT shares the message of its last writes.
A Message's commit callback runs once the batch's COMMIT succeeds, before any of its writers hears an answer.
A dispatch check is never run for its caller: the holder hands that caller the Store, which keeps it until it has launched the Attempt or Action, so no stop commits between the check and the launch.

The Host opens the Store database with `locking_mode=EXCLUSIVE`, `journal_mode=WAL`, `synchronous=NORMAL` (with `fullfsync` on macOS) and a 4-MiB `journal_size_limit`.
Each commit appends to `rui.sqlite3-wal`, which survives a process crash at once.
The WAL is synced before anything outside the execution loop can observe a commit: before another thread hears any answer, read or write, and before the loop hands the Store to a launch of a model call or Action.
One sync covers every earlier commit, because the WAL is append-only, so the loop's settlements and admissions in one stretch share a sync ([#2086](https://github.com/DivyanshGolyan/rui/issues/2086)).
An OS crash or power loss can therefore lose only commits no client, provider or Action has seen, which is the same as crashing before them; every acknowledged commit survives on storage that honors sync.
`NORMAL` also syncs the WAL before each checkpoint, so the database file never holds a page the WAL could lose.
A failed sync fences the Store, like a failed COMMIT.
Automatic checkpoints copy committed pages into `rui.sqlite3` and truncate a grown WAL to the limit; a clean close checkpoints and deletes the WAL.
A crash leaves committed frames only in the WAL until the next open replays them, so the database file alone is not a Store: copy or restore the whole Store directory, including any `-wal` file.

Exclusive locking means the Host holds the database file lock from its first read until close and keeps the WAL index in its own memory, so no `-shm` file exists.
No other process, including `sqlite3` or another Host, can read the Store while a Host owns it; external inspection waits for the Host to stop.
The WAL name needs four bytes beyond the database path, within the eight reserved for the former rollback journal.

### SQLite and representation

Enforce a finite internal SQLite heap, deriving cache/window/statement capacities against whole-Host targets; no separate caller SQLite tuning or artificial database/page-count quota/emergency reserve.
Large incremental imports must not retain payload-sized dirty-page memory.
Verify effective spill/cache/heap enforcement, not merely setter success.
Use the exclusive WAL and observed-commit sync of [Store durability](#store-durability), mmap off, file-backed temporary work, immediate `busy_timeout=0`, foreign keys, defensive/untrusted-schema configuration, the query planner stability guarantee (plans never depend on bound values, so a cached statement is never re-prepared) and disabled unused attachment/extension/trigger/worker features.
Required features need concrete consumers.

#### Compound Content values

A value-holding owner names one Content row. Its form is bytes or parts; existing rows and every value containing exactly one Text part use bytes, with their existing identity and semantic digest. A parts value is public and holds one to 1,500 ordered Text or Image parts, except that a single Text is never a parts value. Each part names ordinary public bytes Content. A saved refusal retains its original input as primary content and any diagnostic as secondary content; legacy refusals whose input was not retained leave it unavailable.

The parts payload is the canonical manifest: each entry contains its kind, byte length, digest and kind metadata, followed by the entry count. Its identity uses the `rui/input-parts/v1` domain and is the existing ordered input digest. The id-only `content_part` index holds each part alive with foreign keys; the manifest alone owns ordering, kind, metadata and count. Saving looks up the manifest first and owns all parts and index writes in the producer's transaction. A Cursor certifies the manifest digest and canonical decoding, contiguous index ordinals, and each part's public byte form, length and digest before yielding any part. Inconsistency fences the Store.

Every public reader projects a stored value through one rule, without reading the manifest: a bytes row is its text identity, and a parts row is its identity with the Session-scoped owner of its parts, the Message admission or the Action. An Action's Resolution has the Action as owner only when the Action's own tool result carries it; a rejection or background notice holds no parts. A parts value at an owner with no parts owner, such as an assistant entry, an outcome, a rejection or a background notice, fences the Store. The parts list certifies the manifest when it is read. Public byte identity and metadata routes return `ContentIsParts` for a parts value. Activity search reads the manifest through the Cursor, charging its bytes to the scan budget first, and matches each Text part on its own; Image bytes are never searched. Request preparation reads Message and Action Resolution parts through the Cursor and passes their original bytes to the codec. Selection accounts for the parts rather than the manifest. This representation keeps existing owner references and byte accounting, avoids per-Message association reads on text, and keeps kind metadata out of SQL; a new kind extends the manifest codec rather than the schema.

#### Canonical content reads and retention

A canonical Content Reference is a durable identity, not an open file or transferable SQLite handle.
Its owning interface reads into bounded caller-owned buffers.
The Store reuses one read-only SQLite blob handle only within a locked entry point and closes it before releasing access, including errors and pending historical scans.
Logical readers retain identities, copied windows and decoding cursors, never SQLite handles or read transactions across socket delivery, callbacks or preparation yields.
For streaming content whose logical length or known encoded extent exceeds 1 MiB, each reader optionally owns one 128 KiB heap window of copied source bytes, keyed by source identity and offset.
Readers never share these bytes.
Allocation happens outside Store access; allocation failure keeps the original bounded reads rather than fencing the Host.
Closing the reader frees its window.
One hundred such readers own at most 12.5 MiB of additional copied payload, with no inline Store or worker-stack window.
Reopening across windows still repeats overflow-page traversal; synchronous work within one entry point needs no heap window and reuses SQLite's overflow-page index.
Closing a reader invalidates its cursor, not previously delivered caller-owned bytes or the reference.
Close readers before their parent view.
Scratch ranges/view-scoped handles cannot be stored as canonical references.
Adapters receive no SQLite connection.
Private continuation access remains exclusive to the Operation-bound provider view.

Committed content remains available for saved requests, historical Operation views and recovery.
Temporary cleanup cannot invalidate it; V1 selects no canonical-content garbage collection or new lease.
Read failures cannot masquerade as EOF/successful prefixes; missing/corrupt required content follows the Host-wide storage-fault boundary.
Content readers read stored rows directly and hold no decode window; each hashes what it reads in order from the start and checks the digest at the end, as above.
Trusted local facts need no repeated external-syntax validation.

#### Connection recovery and representation bounds

After transaction error, resolve rollback and confirm autocommit before reuse; uncertain connections cannot continue.
Bound query work through indexes and service between transactions, not window-size assumptions.
`SQLITE_LIMIT_VDBE_OP` limits compiled size, not runtime; its `SQLITE_NOMEM` is not necessarily physical exhaustion.

Derive SQL/row/parameter bounds from actual statements and pinned representation, not workload percentiles or durable-history quotas.
Keep guards until replacement storage/traversal is safe.
Distinguish invariants, fixed consumer boundaries, adjustable resource budgets and verification targets; only the first three reject work.

Before Store ownership or readiness, the Host observes inherited descriptors and `RLIMIT_NOFILE`, then computes its simultaneous requirement with checked arithmetic.
Linux enumerates `/proc/self/fd`, or checks the bounded range with `F_GETFD` when procfs is unavailable and the limit is finite.
An unlimited Linux limit requires procfs; macOS enumerates `/dev/fd`.

For configured Active Capacity \(C\), the supported-burst requirement is \(I + F + T + 503 + 2 + E(C) + A(C)\):

| Term | Descriptor requirement |
| --- | --- |
| \(I\) | Inherited open descriptors. |
| \(F\) | 7 for Store lease, database, journal, temporary storage, directory sync and listener ownership. |
| \(T\) | The HTTP/2 Client's waker: 1 Linux eventfd or a 2-descriptor macOS pipe; plus 1 catalog socket and, when configured, 1 OpenAI key model-list socket. |
| 503 | 100 ordinary exchanges at five descriptors each, plus two controls and one discovery socket. Default mode treats these as workload populations, not admission quotas. |
| 2 | Intake wake socket pair. |
| \(E(C)\) | 0 when \(C=0\); otherwise \(5C+5\). |
| \(A(C)\) | 0 without managed authentication or execution places; otherwise 6 on Linux or 7 on macOS for the independent authentication worker. |

With three inherited descriptors, a default managed Host (\(C=100\), Codex transport and authentication) needs 1044 descriptors on Linux and 1046 on macOS for full intake, and 450 fewer for ten-client intake.
A Linux 1024/1024 session fits 96 ordinary clients without a raise. macOS's default soft limit of 256 fits after the Host raises its own soft limit, provided the hard limit and OS per-process ceiling cover the full requirement; a lower ceiling reduces intake, never Active Capacity, and a hard limit of 256 refuses startup.

An ordinary exchange peaks at a socket, two sealed content files, and overlapping writer/read-only handles for the third value in a creating Message.
Absolute POSIX opens use `AT_FDCWD` without a directory descriptor.

A model slot budgets one request file, two response aliases and one socket: the HTTP/2 Client tries addresses one socket at a time and never holds more connections than streams.
A Bash slot may own two captures, two parent pipe ends and one optional stdin writer.
These are exclusive cases of at most five descriptors, not additive pools; the Bash/full mixed maximum still determines \(E(C)\).
The five serial excess descriptors cover preparation (including both stdin aliases and their directory), trust loading, cleanup or Bash spawn.
Spawn retains two child output pipe ends and the stdin read-only alias until `posix_spawn` returns; absent stdin opens `/dev/null` in the child.
Authentication headroom is separate because its worker can overlap those transitions.
Execution descriptor headroom is unchanged; creating-Message spec content raises only the ordinary-exchange population.

Host availability takes priority over concurrent intake throughput.
Before Store ownership, startup raises a low soft `RLIMIT_NOFILE` toward this requirement without raising the hard limit; macOS also caps the request by `kern.maxfilesperproc` and `OPEN_MAX`, never `RLIM_INFINITY`.
If the OS still cannot supply the default burst of 100 ordinary clients, the Host selects the largest fitting ordinary intake capacity, with a minimum of 10, leaving execution capacity unchanged and budgeting two controls plus one discovery socket.
Reduced mode separately bounds ordinary exchanges through cleanup, controls at two and discovery at one, with total intake sockets bounded by ordinary capacity plus three; excess classified requests receive their class-specific public busy response before content acquisition.
Under pressure, unclassified peers relinquish a place before its successor is accepted, preserving control/discovery progress without an unbudgeted socket or eviction of classified work.
Default mode retains demand-scaled intake.
`host status` and startup diagnostics report effective/default intake and the effective descriptor limit.
Below the minimum, startup fails promptly with `RLIMIT_NOFILE`, capacity and limit-remediation guidance; detached startup must surface the error rather than hide it behind readiness uncertainty.
No descriptor-credit pool or future-owner reservation is introduced.
Later acquisition failures follow the acquiring owner's cleanup rules.

Names, references and idempotency keys preserve exact text as specified in [admission terminology](admission.md#names-references-ids-and-idempotency-keys): no trimming, case folding, Unicode normalization or arbitrary whitelist.
The representation layer must preserve those distinct scopes rather than treating all keys as one 128-byte class.
Derive wire/request/acknowledgment/error bounds from each complete public value and worst-case escaping; other keys gain no length quota without an actual consumer requirement.
Validate positivity/nonreuse and arithmetic for actual identity/ordinal consumers; SQLite INTEGER requires signed-64 representability where used.
Binding/content SHA-256 digests are domain-separated 32-byte values, not authentication.
Validate OS/API paths including NUL, complete derived suffixes and socket terminators.
Finite selectors preserve supported model/tool names; media/schema/diagnostic types follow their actual consumer.
No generic identifier validator or silent truncation.


## Required evidence

### Interface and owner checks

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| [Compound Content values](#compound-content-values) in Action Resolutions | `store/tests/action_parts.zig` `'compound Action Resolution'`, `store/tests/action.zig` `'EXR-10 an Action read projects a compound Resolution'` | Ordered bytes survive reopen and background delivery; Action reads project the owned parts value without walking the manifest. Maximum-part background replay yields, and damaged manifests, indexes and parts fence. Engine coverage follows the common Store tests. |
| Times pinned to state | `store/sqlite_tests/` `'each state-bearing row keeps exactly the time its state owns'`: a direct UPDATE that changes state without its time is rejected. `'every transition dates its fact from the Host clock'` | Wall-clock order is not asserted |
| [Store format](#store-format-and-upgrades) closed value sets | `store/sqlite_tests/` `'closed value columns accept exactly their values'`: each enumerated Command kind, Conversation entry kind, Model Output Item kind, reasoning effort and Action Resolution column accepts its listed values and rejects others on a CHECK | A Conversation entry kind outside 1 to 3 is rejected by both its column CHECK and the kind-specific CHECK, so the probe cannot tell which one rejected it |
| Session position claims | `store/sqlite_tests/` `'claiming Session positions stops at the largest position, and fails when its write does not land'`: inside a write transaction, a claim ending at the largest position succeeds, a claim past it fails without moving the counter, and a claim whose guarded write changes no row fails with `CorruptStore` | The guard on the read value cannot be observed alone: within one write transaction no other writer moves the counter between the read and the write |
| Store tests per engine | `tests/ci/store_conformance.py` split `store/tests.zig`, since divided by domain into `store/tests/` and `store/sqlite_tests/`: after it moves raw SQL onto the fixtures, tests that name no SQLite mechanism stay there, and those that open a Store run once per `store_testing.Engine` through `forEachEngine` (SQLite only until the MySQL engine lands). `test_store_conformance.py` fails when the code of `store/tests.zig` or `store/tests/` names the SQLite module or C API, the connection, the statement cache, engine passes, the content read counters or a Store opened by its path, or imports sqlite.zig. Fixture SQL (`store_testing.exec`, `queryU64`, `withoutForeignKeys`) fails the build when it fails `rsql.portabilityError`, or when outside its string literals it holds a word of `fixture_sqlite_words`, a word starting `sqlite_` or `pragma_`, or `AS TEXT` (`'a fixture's SQL is portable Rui SQL and names no SQLite mechanism'`, over `fixture_text_cases`); the codemod reads those word lists from rsql.zig, which owns every fixture rule (`rsql.fixtureRendering`), and `test_store_conformance.py` fails when its verdict on a case differs. `RUI_TEST_REQUIRE_ENGINES` has one parser, `wire/required_engines.zig`, which pg_tests.zig also calls: tokens must equal `sqlite`, `mysql` or `postgres` (`'RUI_TEST_REQUIRE_ENGINES names engines by exact token'`), and a listed `mysql`, which no `Engine` builds, fails every conformance test (`'a required engine these tests do not build fails them'`). `'each Store entry point takes its round budget on its common path'` pins, on one driven path each, the rounds (`Access.run` and `commit`) of each function that enters the Store, and its content rounds (`readRaw` of a non-empty window) per engine. `'every function that enters the Store has a round budget'` reads every Store file but its tests and wire clients (import_architecture.py checks the list), and fails when a function calls `enter(self, ...)` with no budget, when an `enter(` call's first argument is not `self`, or when a `*ForTesting` function enters but is not in `entering_fixtures`. Each population-size work test of `sqlite_tests/` but five has a twin in `tests/`, named with `, in rounds`, that holds its rounds at the same two sizes | The checks do not run any engine but SQLite. The fixtures' text is not rendered for another dialect yet. A round budget holds only for the driven path, not for every input. The codemod's own scan of fixture text applies the word lists but not rsql's reserved-name and `IS` rules, which the compile applies. Five work tests have no rounds twin: each times a statement, or one `ReadAccess` run, that it drives itself outside any entry point |
| Store statement table | `rsql.Read` and `rsql.Write` look each statement up in `store/rsql_table.zig` by its text (the entry's declaration name, so the compiler's own lookup does it) and by a signature of what the checks read from Args and Row (each field's SessionHead-ness, Row's field names, `.compound`, the kind). An entry serves its SQLite text, MySQL template and facts only while the table's `inputs` equals the build's fingerprint of the files the comptime path reads (`rsql_table_inputs` in `build/product.zig`); anything else is checked and rendered at comptime as before (SH-92). The same fingerprint gates the schema's generated objects, DDL, MySQL migrations and bootstrap digest; an individual MySQL migration is the prefix left after its next cumulative migration (or the final format update) is removed. A missing schema or stale inputs takes the comptime path. Fixture text (`store_testing.exec`, `queryU64`, `withoutForeignKeys`, and `mysql_testing`'s send) goes through `rsql.fixtureTemplate`, which serves the table's `fixtures` entry for that text under the same `inputs`, and otherwise applies every fixture rule and renders it at comptime; an entry exists only for a text that passed those rules, so a hit skips them. `python3 tests/ci/rsql_table.py generate` builds the product and unit roots with `-Drsql-collect=true`, where no entry or schema is served and statements, fixture texts and schema export what the comptime path produced, and writes the table from those records; `check` requires exact statements, schema values and inputs and matching renders for fixture entries present in both tables; missing or unused fixture entries pass and cost compile time or dead lines (CI-84). The check runs in the Linux `check` gate and beside `check-full` in promotion, never in the PR tier. Policy runs `rsql_table.py fingerprint`, which fails when the table records other inputs than the listed files hash to (CI-85), and the build prints a warning naming the regenerate command when it compiles against such a table | A statement missing from the table, or a table with a stale fingerprint, compiles at comptime speed rather than failing. Only statements the product and unit roots declare, and fixture texts the unit roots reach, are collected. `ObligationProjection`'s own texts still render at comptime. The generator reads ELF symbols, so it runs on Linux |
| Store SQL on MySQL 8.4 | `store/mysql_dialect_check.zig`, in the unit binary. With `RUI_TEST_MYSQL_SOCKET` and `RUI_TEST_MYSQL_ROOT_PASSWORD` set, it logs in as root over that Unix socket, creates the database `rui_dialect_check`, sets `schema.mysql_session`, and runs each `schema.objects(.mysql)` statement, then a touch-oracle table in `rui_dialect_check_oracle` and the oracle's MySQL triggers (`sqlite.touchOracleTriggers(.mysql, ...)`), each on its own. `'the schema's MySQL DDL and the touch oracle's MySQL triggers run on MySQL 8.4'` fails listing every refused statement with MySQL's error. On its first use in the process, each text `cachedTyped` prepares (as `S.mysql`), the opening's sender sweep, and each statement of the fixture text `store_testing.exec` and `queryU64` run (`withoutForeignKeys` included) is PREPAREd, then DEALLOCATEd, on that database. A refusal logs the text and MySQL's error at err level, which fails the test that reached it without stopping it, so one run lists every refused text it reaches. At compile time, `rsql.portabilityError` refuses as a name every word of `rsql.mysql_reserved`, MySQL 8.4's reserved words as its manual lists them, unless the grammar reads the word as a keyword where it stands (`'every word MySQL 8.4 reserves is a name Rui SQL refuses, unless the grammar reads it as a keyword'`). `'PREPARE on the check's database refuses what MySQL 8.4 refuses'` requires errors 1054, 1093, 1055 and 1235 from four probes. On Linux CI, shards that run `test`, `check` or the `check-full` execution part start `mysql_server.py`'s image with the image's own settings (durability included) and add `mysql` to `RUI_TEST_REQUIRE_ENGINES`, so a missing variable or a failed login fails the run. `check` and `check-full` launch the unit binary through `host_process.py exec`, whose `INHERITED` includes `live_engines.VARIABLES`; `test_live_engines.py` checks that the launcher keeps each of them and that every `RUI_TEST_MYSQL_*`, `RUI_TEST_PG_*` and `RUI_TEST_REQUIRE_ENGINES` name the Zig source or `check.yml` spells is listed there. The check rewrites the file `RUI_TEST_MYSQL_RECORD` names with the DDL statements it ran, the PREPAREs it issued, the refusals, and the probes refused as expected; after the targets run, `live_engine_step.py verify mysql` fails the shard when that record is missing or counts no PREPARE. A change to `src/store.zig`, to `src/store/` outside the Postgres client, or to `mysql_server.py` selects `test` or `check` in review and opt-in local diagnostics, and `select_tests.py` fails a selection in which a rule of `LIVE_RULES` keeps none of the targets that start its server; `test_selection.py` pins `LIVE_MYSQL_TARGETS` and `LIVE_POSTGRES_TARGETS` to `check.yml`'s conditions. `select()`'s documentation and CI-policy shortcuts only add a reason, so every rule still matches every path; `test_selection.py` checks that a lone change to each path a rule names (a literal pattern, or each tracked file a glob matches) selects something in both phases, that rule's targets in review, and for a live rule a target that starts its server. Elsewhere, without the variables, both tests skip and nothing is prepared | Only texts the unit run reaches are prepared; a statement no test reaches renders at comptime but is never prepared. A later test that reaches an already refused text does not fail again. PREPARE binds no value and runs nothing, so literal typing and binding, guards and row counts, multi-statement batches, transactions, CHECK and foreign-key behaviour, collation and query plans wait for PR 8's conformance run. `failReadsOf` and the fixtures of `store/sqlite_tests.zig` and `store/sqlite_tests/`, which go through `store_testing.sqlite_only` (no portability rule, no MySQL check), are not checked; `store_conformance.py` keeps `sqlite_only` out of `store/tests.zig` and `store/tests/`. Nothing here fires the MySQL oracle triggers. They note a sender's Session only when a column both Sessions read changes, narrower than SQLite's `UPDATE OF` |
| MySQL round trips, direct and behind ProxySQL | `store_rounds_cases.py`, run by `settings-integration` wherever CI starts MySQL. A relay counts every query a settings-document Host sends for four one-Turn operations and an idle window, and holds the counts to `BUDGET`: commits and write round trips exact, the total an upper bound, idle zero. It measures twice, against MySQL 8.4 and against ProxySQL 3.0.11 fronting the same server with multiplexing on, with the same budget | Linux only; skipped without `RUI_TEST_MYSQL_*`. ProxySQL must offer `caching_sha2_password` (`default_authentication_plugin`), which is not its default, and 3.0.5 and older lack a handshake capability the driver requires. A session that holds the Store's `GET_LOCK` stays on one server connection, so the run does not show a Store's statements moving between server connections |
| [MySQL Store ownership](host.md#exclusive-store-ownership) across a lost connection and a second Host | `python3 tests/formal/check.py`, run in policy by `tests/ci/test_formal_models.py` when `tests/formal/` changes: TLC checks the TLA+ model `tests/formal/mysql_ownership/MysqlOwnership.tla` against at-most-once saving, truthful saved and not-saved reports, rerun only while unsaved, and no commit from a Host after another opened; each guard's mutation must break a named rule. The `verify-mysql-ownership` skill maps each model step to code and holds the sync commit | Bounded: two Hosts, three batches, two losses, six sessions. Multi-primary MySQL is a non-goal; under it a reconnect may rerun a batch an old session still commits, the fence stops the duplicate and the Host fences (kept as an expected violation) |
| [Store migrations](#store-format-and-upgrades) | `schema.zig` 'schema 61 migration preserves saved call rows and accepts 200 UTF-8 bytes' migrates populated format 60, preserves rows and dependents, checks both columns' byte boundaries, foreign keys and reopening. `schema.zig`'s comptime gate fails the build when `schema.migrations` lacks the step to `schema_version`, holds a step past it, or holds steps out of order. `tests/ci/test_store_schema_version.py` compares each step whose `from` is below the released schema_version with its source text at the release tag, whitespace outside strings aside, and fails on a dropped, added or changed one; `test_shipped_steps_rule` proves it on a fixture release where a shipped step and its neighbours are edited together. It also fails on any step whose statements are not all string literals (`test_steps_are_literals_only`), so the source compared is the text that runs; a CHECK copied wrong into a step fails the migration tests below, since the schema's own CHECK passed `rsql.expressionError`. `store/sqlite_tests/` `'a Store at the migration baseline with its rows takes every migration at open and reads as a fresh Store'` builds a Store from `migration_baseline.sqlite.sql` and `migration_baseline_rows.sql`, opens it through `Store.open`, and compares every table's rows with a fresh Store given the same rows; with no step it proves the snapshot equals the current schema. `'a migration that rebuilds a referenced table from the schema's text keeps its rows and references, and the Store opens'` and `'a migration that leaves other text than bootstrap's, or a broken reference, or runs on another format, commits nothing'` drive `schema.migrate` with steps of their own. `'a migration whose step fails leaves its backup and the original Store readable, and replaces an earlier backup'` checks that the copy and the Store both hold format 7 and their rows and pass `integrity_check`, that an earlier copy is replaced and files whose names only begin like it are kept, and that a backup that cannot be written refuses the Store before any step runs; `'a Store at the maximum path backs itself up before a migration'` writes the copy for a Store whose path is the longest the Store allows. `store/mysql_dialect_check.zig` `'a MySQL Store at the migration baseline with its rows takes every migration to the current schema's shape and rows'` runs `migration_baseline.mysql.sql`, the rows and the combined `schema.mysqlMigrationFrom(migration_baseline)` text printed by `store schema --from` in one database and `schema.ddl(.mysql)` and the rows in another, seeds saved baseline format, older wire metadata and a Store selector, then compares their information_schema tables, columns, indexes, CHECK clauses and foreign keys and every table's rows and admits the migrated database through the production `mysql_open.open` path; it runs inside the live dialect check, and each pass adds to the record's `migrations` count, which `live_engines.py` requires to be nonzero on every shard that starts MySQL | The rows come from a Store at 51 that the Store fixtures wrote; `sent_rejection` holds none. MySQL constraint names are not compared, since MySQL generates them. Nothing checks a step against a Store a released build wrote. |
