# Reports, Activity, and local protocol

[Architecture](../../ARCHITECTURE.md) owns shared guarantees, terminology, and the source map.
[Verification](../../VERIFICATION.md) owns global evidence rules and gates.

## Accepted contract

### Inspection and local protocol

### Capturing and delivering reports

A report may lag and has no global cross-Session revision.
The one in-memory exception is Session listing's `since` token: an opaque Host-opening hint that says which Sessions may have changed, not a revision any read can be asked to be "as of", never stored and void after a Host restart.

Reports have exactly two closed profiles. **Current**, the default, contains effective settings including the Label, `parent`, `created_at`, `context_estimate`, the Session work, `first_message` and `from_person_at` that Session listing reports, current execution state, the latest relevant outcome, pending-message count, every unresolved Action and actionable permission, accepted call outcomes still participating in the active Turn, the selected work's original Message key (active Turn's first admission or oldest unexcluded queued admission), and up to ten most recent applied Messages from terminal Turns with their keys and outcomes.
Selection and recent identities are committed Host facts, not local caller records; growing terminal history is excluded.
Explicit **Full** contains Current plus the following closed inventory:

- for a Session, every Session Context Revision; admitted Message with its binding, application or exclusion and public outcome; canonical Conversation entry; Turn; model or Action Operation with its public Resolution; Tool Call and ordered Tool Result, including bounded call rejection; Permission Request, Decision and Authorization; and committed Session stop or Model Interruption command with its public outcome.

Full model Operations include `offered_tools`, the sorted tool names in the effective offer frozen at that Operation’s admission.
Current settings and Full revision settings expose configured allowed intent as `tools` and loaded intent as `loaded_tools`; neither reconstructs an existing Operation’s offer.
An allowed or loaded edit, later discovery, or a changed Host tool set cannot change that Operation’s `offered_tools`.
The field reads the existing frozen tool-set identity; no stored copy or Store-format change is needed.

Every inventory member is represented.
Repeated content may reference an identified owning member that contains the complete bytes in the same Full report; revision content is owned by its first `(revision, field)` occurrence across instructions then output schema, and later occurrences name that owner directly.
Content omitted from the report requires a separate public read.
Physical Attempts, private provider continuation, credentials and internal storage rows are not report collections.
Adding another public historical collection requires changing this inventory.
Exact command and field spelling remains implementation work.

Capture the selected profile completely, in deterministic report order, with bounded traversal/encoding and charged scratch, releasing each owner's DB resources before delivery.
A slow client holds no transaction.
Service controls and settlement between queued reports without starving inspection; individual calls/captures/imports remain non-preemptible.
No report collection cap, report pagination/cursor, hard capture deadline, arbitrary section selector or successful partial report is permitted.
Current includes all unresolved and actionable work even beyond resident buffers; Full includes every member of the closed inventory above.
Larger strings stream through fixed windows/block writes; scratch/window size is not a field limit.
Completeness applies to the selected public profile, not every internal fact or one globally consistent instant.

The report owner retains completed scratch through delivery; the connection borrows bounded reads.
Capture failure releases incomplete scratch and returns an observation error.
Partial writes continue at the unsent offset; disconnect/timeout/delivery failure closes the exchange and releases scratch after pending I/O ends.
Slow delivery retains ordinary client capacity and scratch, with no detached report queue or execution credit.
Restart discards captures; new inspection observes current committed facts.

Reply writes establish nonblocking socket mode only at delivery, preserving request-ingress behavior.
Readiness promises some capacity, not a whole-window write.
Each available header/body window starts the existing 60-second socket-inactivity budget; only positive writes advance the unsent offset and renew that budget.
Interrupted waits/writes and `AGAIN` retry against the remaining budget, without renewal.
Store/report production between windows is excluded, so progressing replies have no total deadline.
Delivery failure ends the exchange without appending a second HTTP response or revoking committed work; existing reader, report-scratch, socket and connection-population owners retain their cleanup responsibilities.
No reply queue, worker, payload copy or new persistent state is introduced.

### Public Conversation pages

The separate `conversation_page` Host read is a filtered projection of canonical applied User entries, assistant text and completed Tool Results; it does not change Current/Full reports or persist a transcript.
Pending input, instruction updates, model-output items (including private reasoning and encrypted continuation), proposals and partial tool groups are outside this projection.
Full retains its complete inventory; Action inspection remains the exact approval-target read.
A missing Session or malformed/stale cursor fails without changing work.

`POST /v1/conversation-page` takes the ordinary wire envelope with `kind:"conversation_page"`, `session`, and decimal-string `end`, `before_position`, `before_ordinal`.
A first page has both `before` fields at `"0"`; `end:"0"` captures the current end, while a previously observed committed end fixes replay before any later work appends.
Cursor positions and ordinals must fit SQLite's signed integer domain; invalid public values are rejected before binding, not treated as canonical corruption.
The returned `end` fixes the last committed Session position at that read; subsequent pages echo it and pass the previous page's `before_position`/`before_ordinal` when `more` is true.
Results run newest-first, at most 16 items per page; Tool Results share their completed group's final acceptance position and use one-based call ordinals to break ties, descending within that reverse traversal.
Other entries use ordinal zero.
Once a group settles its final acceptance position is newer than any prior fixed end, so incomplete results cannot materialize behind an existing cursor.
Later appends are outside the fixed end.
Each item carries kind, position, ordinal, exact byte length and SHA-256, with `display:"omitted"`; no payload is silently shortened into a preview.
Reverse the retrieved sequence for chronological presentation.
An empty first page has no continuation, even if work later appends.

Continuation cursors must identify an actual public item in that Session at or before the fixed end.
The Store validates the same public identity used by exact content reads before applying the reverse keyset predicate; invented ordinals and private-only positions are invalid cursors, not alternate positions in the history.

Before exposing a returned page row, cursor or content reader, the Store validates the exposed content's public classification and metadata; ordinary entries also validate their producing admission or Operation and Turn in that Session.
A missing public identity remains an ordinary request error; contradictory ordinary provenance or private/missing exposed content under an existing public identity fences the Store rather than disappearing through a filtering join.
Privacy applies to the exposed content, not its projection backing: accepted provider source rows may legitimately be private.
These checks retain only constant-size identity/metadata values and no payload or cache; the existing page query's traversal time can still grow with canonical history.

`POST /v1/conversation-content` takes `session`, `position`, `ordinal` and `start` as decimal strings; it resolves the public item in that Session rather than trusting a caller-supplied digest.
Position and ordinal share the signed SQLite domain; invalid values fail as ordinary identities.
By default the raw octet-stream response contains at most 4 KiB, with total `X-Rui-Content-Bytes` and exclusive `X-Rui-Next-Offset`; repeat until the offset equals total.
A range can split UTF-8: join bytes before decoding/display.
Out-of-range or nonpublic identities fail without leaking content.
The server requests public byte ranges; the Store owns representation selection, positioning, decoding and validation.
Every public text is its own content row, so a range seeks directly.
Canonical readers hold no SQLite transaction over socket delivery.
The Host does not retain a traversal or per-Session content cache; each ordinary connection owns one fixed page buffer or read window and releases it at reply/close.
Bounded output/window storage does not imply linear traversal or bounded query time.
Optional spillover removal does not affect canonical Tool Results.

The optional trailing `stream:true` field requires `start:"0"` and delivers the complete public value in one fixed-length HTTP response through one sequential canonical reader and one 4-KiB delivery window.
`Content-Length`, `X-Rui-Content-Bytes` and `X-Rui-Next-Offset` all name the complete decoded byte length, not escaped backing bytes.
No content prepass, payload staging/cache or new Session-view route is implied.
The reader closes on completion, disconnect or failed delivery; Store resources close before each socket write, using the same reply-only nonblocking/progress-inactivity policy.
Every content reader hashes bytes it reads in order from the start and checks the digest before returning the window that reaches the end, so a whole-value read, including every stream and model replay, cannot succeed over damaged bytes.
A ranged read that starts past the beginning is not authenticated.
An empty or one-window canonical failure returns an error before successful headers.
A later fault fences the Host and closes an incomplete advertised body without another HTTP response; a caller must not treat that prefix as a complete value.
Sequential decoded work avoids repeated prefix positioning, but does not guarantee traversal time or a measured speedup.

### Typed Message and Action Resolution parts

`session inspect-part --session ID --admission ID --ordinal N` and `action inspect-part --session ID --action ID --ordinal N` read one zero-based part's typed metadata as JSON. The Message selector names a saved admission in that Session, including one that has not been applied; the Action selector names its saved Resolution. Text metadata contains its exact byte length and the [Store content digest](store.md#sqlite-and-representation); Image metadata also contains its MIME type. The `sha256` field is SHA-256 over the eight-byte big-endian length of `rui/content/v1`, followed by that domain and the part bytes; it is not the raw bytes' SHA-256. A missing ordinal returns `part:null`. Parts are ordered by ordinal, and a single Text value is ordinal zero.

`session read-image-part` and `action read-image-part` use the same selectors to stream the exact image bytes. A missing or non-image part fails. The Host resolves the selected public owner rather than accepting a content identity from the caller. The Store certifies a compound manifest and its ordered index before returning a part, advancing a bounded cursor between Store entries so other work can proceed. The existing public text readers retain their refusal of compound values.

### Tool Call proposals

A proposal is an accepted Tool Call in the model's output: Activity pages list each one as a call row, and Action inspection and replay read its fields.
Each proposal owns its position, producing model Operation and Turn, zero-based call ordinal, the actual optional Action ID, the closed optional rejection (`unknown_tool`, `invalid_arguments`), and exact length/content digest for `name`, `call_id` and `arguments`.
Accepted rejected calls stay after settlement and restart, with no invented Action.
Fields and classification are immutable; current permission or later outcomes do not rewrite them.
Every read resolves the Session/proposal again, not a global content digest, and checks producing Operation/Turn/call/Action linkage, the call's binding to its accepted item by ordinal, and public exposed metadata.
Each field's content must have the length and digest admission certified for this call.
Acceptance decoded every field once into its own content row; a reference to other content, including a deduplicated backing, is authority only when it matches that certificate.
The provider item ID is not a call field: it stays in the item bag, and its digest only rejects a duplicate item ID within one output; this persisted-format change follows the [Store format policy](store.md#store-format-and-upgrades).
Missing proposal identity is an ordinary unavailable read; contradictory provenance, missing owners or private/missing exposed fields fence rather than disappear.
Proposal metadata grants no authorization: a later approval still binds the freshly inspected exact pending Action through the existing decision route.

### Public Session activity

Session activity is a separate projection of eleven row kinds, not Conversation repurposed as an inventory: a person's or script's Message admission (`admission`), a sourced input (`received`, naming either its peer `sender` or its background `source_action`), applied User entry, assistant text, immutable Tool Call, complete-group Tool Result, hosted call, terminal Turn outcome, accepted Session stop, sent Message and refused send.
`received` mirrors `sent` for peer Messages and records final Action input with its Action identity; it split from `admission` on 2026-11-03 so a page can list a person's Messages alone (design thread on Rui's core and plug-in points).
Activity and public Conversation retain `source_action` as a nullable Action ID alongside the shared Resolution content reference. Terminal history labels that input `Background Action <id>`; person-only admission queries exclude it.
Admission, stop, send, refusal and every terminal outcome claim the existing Session sequence in their owning transaction, and each also records its commit time there.
No copied log or second frontier exists; this schema change follows the [Store format policy](store.md#store-format-and-upgrades).
A refused send's `send_failed.target` is required and nullable: it names the canonical attempted peer, including an unknown Session, or is null when the saved attempt has no valid Session reference.
The Store derives that peer from the full saved target with the shared ID grammar, resolves a label only for a peer, and leaves the original command target, digest, refusal and replay identity unchanged.
This read-time projection covers existing refusals as well as new ones; null does not distinguish refused creation from a malformed addressed send and never means that a Session was created or not created.
Every non-null peer remains strictly validated; a missing target or malformed peer is not an alternative null encoding.
The human row with no peer reads `! Message rejected — No valid target reference`; model transcript outlines use `(no valid target reference)` rather than a label or invalid attempted spelling.
Calls retain historical rejected proposals and all three complete field references under the proposal contract above.
Tool Results validate the complete group's accepted call/output-item and Session/Turn/attempt provenance before exposure; malformed sibling links fence even when the caller skips proposal rows.
Outcome provenance is the terminal Turn's causing model Operation, not a later Session Operation.
Full, Current and exact Action inspection retain their independent authorities.

Tool Call admission validates the original descriptor and atomically saves its nullable decoded description, bounded to 200 UTF-8 bytes, and the three accepted field lengths and digests on the immutable call.
Bash keeps its independent 100-byte argument bound; a valid Bash descriptor retains its label even when Bash is disabled and the call is rejected; malformed Bash descriptors and unknown tools have null labels.
The Store combines that admission-owned label with canonical outcomes for shared `ToolPresentation` metadata on Current, Activity, and Conversation.
There is no presentation table, copied log, frontend cache, or identity-to-description map.
One `tools.describe`, exhaustive over the Tool Catalog, gives every tool its description: Bash's is the one its model wrote, and a hosted web search, which has no field for the model to fill, gets one Rui writes from the provider's action at settlement: `Search “query”`, `Open site/page` (without the scheme or `www.`), `Find “pattern” in site/page`, or `Search the web` when the provider gives no details, on one line and cut with `…` within the saved 200-byte bound.
The search stays a model output item, not a Tool Call: the item row saves that description and whether it failed (Store schema 49).
Conversation and Activity pages return it at the item's own position as a `hosted_call` item that carries only its `ToolPresentation` and no content, and the frontend draws it as a tool row, so successes pack with Bash rows and a failure stands apart.
Divyansh chose to show one line per search on 2026-11-02 (web search PR 3).
Every screen draws a description as one line of prose: controls, bidi controls and `\` escape as on any terminal line, while `"` shows as written, since no escape contains one; an exact command or field still escapes `"` too.

Lightweight Current, Activity, Conversation and idle-classification reads validate call/Operation/Turn/Action linkage, complete sibling groups and public field metadata against the admission certificate without reopening command or private provider payloads.
Presentation read work is independent of command byte length, not call count or history size.
These reads trust immutable admitted metadata: later corruption confined to undisplayed payload bytes need not be detected by polling.
Full Session inspection, Action arguments/call-ID inspection, execution input and model replay check each field against its admission certificate and verify the digest of every byte they read; streamed public content retains its own integrity checks.
Canonical result content and proposal arguments remain unchanged; descriptions grant neither execution nor permission authority.
The additional per-call canonical data is at most 200 description bytes plus 120 field-certificate bytes, excluding SQLite row/page overhead; readers retain fixed-size metadata, not commands.

Each Activity page also captures `call_activity` under the same Store lock, with an exact total and at most the three oldest `(operation, ordinal)` identities awaiting presentation.
A page whose `kinds` are not every kind reads neither `call_activity` nor `queued`, and reports both empty.
Its boundary is the last returned row for a forward page with `more`, otherwise `(end, null)`, including backward opening.
At the same boundary the page reports `queued`: how many Messages without a sender were admitted and neither applied nor excluded, the oldest one's Admission position, and the newest one's admission ID and position.
Selection and a stop take admission-order prefixes, and Admission positions follow admission order, so the Store seeks the boundary in the index of those Messages by Admission position and walks down, stopping at the first taken: it reads the waiting Messages and one more, however many Messages precede or follow the boundary.
Unpublished groups retain all calls, including settled siblings.
Published calls retire only before that boundary or at its position through the presented one-based result ordinal.
Turn completion does not retire a call.
The fixed page end limits history rows, not current call activity, so newer calls remain visible during frozen catch-up.
The frontend commits this snapshot and its cursor together only after successful joined presentation.
Permission preparation consumes the same normal Activity scan before showing the freshly selected exact command.
Current's active attention and history-independent query contract remain unchanged.
This projection has fixed resident storage, not history-independent query cost.

`POST /v1/activity-page` takes `kind:"activity_page"`, `session`, nullable `end`, decimal-string `position`, nullable decimal-string `ordinal`, `direction:"forward"|"backward"`, `kinds`, the row kinds to list as a non-empty array of their names, each at most once and in this order: `admission`, `user`, `assistant`, `call`, `tool_result`, `hosted_call`, `turn_ended`, `stop`, `sent`, `send_failed`, `received`, `approval_requested`, `session_changed`, `compacted`, `model_call`; and decimal-string `limit`, from 1 to 16.
The cursor may name a row of any kind; the page lists only the asked kinds, and each row source is gated by the kinds before it reads, so a kind not asked for costs no read unless it shares a source with an asked one: `user` and `assistant` share the Conversation entries, and a `received`-only page passes over the person's admissions.
A person's Messages alone are one seek in the index of Messages without a Session sender or Action source, whatever the history's length; a page that lists received Messages reads all of a Session's Messages by position, as every unfiltered page does.
Null end captures the current committed end; zero freezes empty history.
Pages echo end/direction and return at most `limit` owned metadata rows with `more`, ordered by (position, ordinal).
Only complete Tool Result groups share positions, using one-based call ordinals; a Session's own `approval_requested` row shares its call's position at ordinal 1; a revision's `session_changed` rows share its position, numbered from zero; other rows, including forwarded child facts, use zero.
An `approval_requested` row (D115) follows each call whose Action was saved under an `ask` revision, whatever was decided since, and carries `session` (the Session whose Action it is), `action` (the id `permission_decision` names), `operation` and `call_ordinal`; it is dated by its Operation's settlement, which saved the Action.
Both `call` and `approval_requested` rows carry inline `description`, `tool` and `server` (D240, wire 14).
`description` is the saved D227 call line, at most 200 bytes, or null where no line was saved;
`tool` is the saved name, at most the tool-name bound, or null for an oversized rejected name (its full name remains in `fields[0]`).
`server` is the MCP server from the proposing Operation's frozen offer, null for built-ins or an unknown tool, never today's tool set.
These fields read existing call content, settlement and frozen-offer facts; no arguments are re-parsed and no Store-format change is needed.
The format 69 → 70 migration moved the saved wire-13 label to wire 14 on both engines; format 74 deletes the label, and opening neither reads nor writes one.
Opening either row through `activity-content` returns the call's original arguments JSON, including original whitespace and the description field.
A forwarded approval reads and certifies the child's canonical call and returns that same saved detail and arguments, not anything belonging to the receiving Session.
Core built-ins do not request permission; Bash and MCP calls under `ask` do.
That settlement stores the call's position on the Action as `approval_position` (Store format 51), and the feed seeks that column's partial index, so a page of approval requests costs the same however many calls ran without asking.
Forwarded `approval_requested` and `turn_ended` rows have their own receiving-Session position and carry the originating child's `session`, while all remaining fields come from the child's own Action or Turn facts.
A Session's own `turn_ended` row likewise carries its own `session`; forwarding does not alter the child's row or backfill a captured ancestor feed prefix.
A `session_changed` row (D138, D218) carries `revision`, `field` and required nullable `provider_text` (explicit `null` for ordinary changes).
An ordinary row names a setting the revision changed (`provider`, `model`, `instructions`, `tools`, `loaded_tools`, `permission_mode`, `output_schema`, `compaction_trigger`, `output_reservation`, `reasoning_effort` or `label`) and has null provider text.
The revision's commit writes those rows at one position, never edited; creation and an unchanged revision have none.
A refused effort update is also an immutable row, with `field:"reasoning_effort_refused"`, the revision whose effort was refused, and the provider report in `provider_text`, using the same bounded, control-normalized report as other provider failures.
Settlement writes it once at its own position even though it changes no setting, and never edits the revision or its original change rows.
A `compacted` row (D217) is a compaction that succeeded, at its compaction item's position (taken at settlement, so no earlier page gains it), carrying `operation` and `dropped`: how many conversation entries its floor left out beyond the one before it, zero for a compaction that made no room.
A `model_call` row (D179, D219) is one resolved model Operation, including failures and compactions, at its admission position with ordinal zero, dated by resolution.
It derives `model` from the Operation's immutable settings revision; `served_model` from stored model evidence (body first, then OpenAI header, then alternate header), never from the requested model; `input_tokens` from uncached plus cache-read plus cache-write tokens; `cached_tokens` from cache-read tokens; `output_tokens` from output usage; `status` from the resolution code; and `attempts` from the final attempt ordinal.
Missing served-model evidence, usage and timings are null, not zero.
The Operation row owns the last ended attempt’s timing pair. One attempt-ending writer snapshots live observations in the existing resolution or retry-scheduling UPDATE, before custody retires. A backoff resolution preserves the saved pair regardless of whether old custody is still attached, retired or lost on restart; replacement admission clears both fields before the replacement can launch. Custody is only the bridge for live observations, not retention across retry waits. The timing owner reads the published event and send boundaries before sampling the monotonic cutoff, yielding one immutable pair with `first_event_ms <= latency_ms` whenever the event is known. Callbacks after those reads cannot amend the pair. No later write amends a resolution.
Both timings describe the FINAL attempt only: `latency_ms` is request sent to the attempt-ending write (resolution or retry scheduling), and `first_event_ms` is request sent to the first HTTP response event (including an interim head), not the first token; a snapshot that observed no such event leaves it null.
No per-attempt history is stored; schema 68 adds two nullable nonnegative integer duration columns to `model_operation` on both engines without backfill.
D219 explicitly excepts these derived rows from fixed-prefix stability: resolution may reveal a `model_call` within an earlier captured end, at its original admission position, never relocated to settlement.
A forward follower already past that position does not replay it automatically; reread the earlier range to observe it.
A nonnull ordinal identifies an actual row in this Session and end.
Continue from the last returned row with that ordinal and the same end/direction.
Null ordinal denotes a sequence boundary, excluding all rows at position; position zero starts either traversal.
Forward catch-up captures a fresh end from the preceding end with null ordinal, so group ties are not replayed.
Apart from D219 model-call resolution above, later appends and group completion cannot backfill an earlier prefix.
Query work may grow with history; item bounds do not promise traversal latency.

`POST /v1/activity-search` takes `kind:"activity_search"`, `session`, `query`, `kinds`, nullable decimal-string `before_position` and `before_ordinal`, and decimal-string `limit` with the Activity page's kind and limit rules.
The query is 1 to 256 UTF-8 bytes; matching folds only ASCII A–Z and keeps every other byte exact, independent of the Store engine.
The Host streams existing public content through `ContentReader`, with a fixed 8 MiB content-byte scan budget per request, and SQL chooses only candidate identities, never text matches.
Searched text is Message text (admission, user, received and sent), assistant text, Turn-ending content, Tool Results, and a call's tool name followed by a newline and its stored arguments JSON; instructions, output schemas, usage, call IDs and private provider material are not searched.
The reply is `type:"activity_search"` with newest-first `items`, each naming `position`, `ordinal`, `kind` and up to three `hits`, and nullable `next` naming the last scanned entry.
A hit carries a UTF-8-aligned `snippet` of at most 160 bytes and decimal-string byte `offset` and `length` inside that snippet; when the full matched query exceeds the snippet bound, the highlight is its visible prefix, but matching still uses the entire query.
Malformed stored text bytes appear as `?` in snippets, one byte each, preserving byte offsets.
A budget-limited reply may contain no matches and still have `next`; the exclusive cursor proceeds to older entries, including when scanning stopped inside a large entry, rather than resuming that entry's remaining bytes.
`read_transcript` with `query` uses this same search, prints each matching entry's outline followed by quoted snippets, and preserves the query in its continuation hint; `query` with `full` is refused.
Search adds no Store format, index or SQL text-matching dependency.

`POST /v1/model-list` takes `kind:"model_list"` and returns `providers`: for each provider the Host serves, in Provider order, its `provider`, `source` and `models`, each an `id` with `known`, whether Rui's model catalog knows its facts.
A model the catalog does not list runs with default limits (see compaction).
The ChatGPT device sign-in (`codex`) has no list, so its `source` is always `catalog` and its models are the catalog's OpenAI IDs in catalog order.
At Host start and on every model-list request, the execution owner's HTTP/2 Client starts an OpenAI key's `GET BASE/models` (when served), a ChatGPT plan's `GET https://api.openai.com/v1/models` (when served) and an unauthenticated `GET https://models.dev/api.json`, each unless that fetch is already in flight.
Each has its own endpoint and stream beyond Active Capacity, including a catalog-only Host with no model slots.
No fetch reserves a model slot.
The plan's GET carries a lease from the Host's one sign-in worker, which serves it only when no model slot waits for that worker, and returns the lease as soon as the GET holds its own copy of the token; it never waits for a refresh, and a 401 on it forces none.
Without a usable sign-in the lease fails and `/v1/models` is never contacted.
The plan's list keeps only entries whose `visibility` is `list`, by `slug`, in server order.
Each provider's IDs (at most 512, 16 KiB together, per provider) stay in Host memory and are replaced on refresh.
While a provider's fetch runs its source is `pending` with the catalog's OpenAI IDs; after it, `live` with the provider's IDs in its order (IDs Rui cannot select are dropped), or `catalog_fallback` with the catalog's OpenAI IDs when it or its sign-in lease failed, answered with something else or listed more than that bound.
A refresh keeps the previous provider source while in flight; the initial provider fetch alone starts `pending`.
The reply signals refresh, then reads one selected fact generation from the Store and renders it with the independently retained provider lists; it does not wait for the network.
Its operation-owned facts and reply storage are released after the request; the Host retains no fact snapshot between requests.
Reply capacity derives from that selected generation, not the shipped snapshot's model count or ID bytes; the independent live-provider bounds remain unchanged.

The models.dev GET asks for identity encoding and sends `If-None-Match` with the saved ETag when present.
A 304 leaves the saved generation untouched.
Its page-allocated body is capped at 16 MiB and released immediately after the token-walk parser slims it in a scratch arena off the Host stack.
Setup, transport, status, parse and size failures print one stderr line and keep the saved catalog.
The Host retains no in-memory fact catalog.
After each fetch it retires the catalog origin's connection; a connection shared with other streams drains without interrupting them.
After the queued write's outer commit, it releases refresh-only prepared statements and SQLite's unused pager cache.
Discovery completion participates in the existing busy-to-idle heap-release edge; it adds no separate allocator trim point.
The shared integration boundary disables catalog discovery for all descendants by default, including detached Hosts; catalog cases explicitly supply their controlled test URL.
The Store saves `model_fact(model_id,context_window,efforts,openai_listed,generation)` and one `model_catalog_source(slot=1,etag,generation,fetched_at)` row.
`openai_listed` only records models.dev's OpenAI-list membership for the D151 merge and D154 list, not provider availability or a core capability.
The effort mask is format-defined: none=1, low=2, medium=4, high=8, xhigh=16 and max=32; its CHECK permits 0..63.
Bounded SQL batches share one queued write transaction, with source publication last: because `model_id` is the primary key, separately committed upsert batches would erase old facts before publication.
Readers therefore see the old or new catalog whole.
Removed IDs retain their older rows but current-generation reads ignore them; runtime SQL never deletes them.
ETags are nullable and bounded to 512 bytes; an oversized or duplicate response ETag refuses that refresh.
One Store read selects source presence and the corresponding generation's facts in the same statement, including a source-only result for an empty generation or absent requested ID.
Single-model admission reads and complete-catalog model-list reads share this selection rule; no consumer separately tests source existence before reading facts.
304 responses, failed refreshes and failed publication preserve the previously committed source; restart reads that same authority without waiting for discovery.

Each row has position/ordinal, `at`, and one closed tagged `value`.
`at` is the Host Unix second the row's owning fact committed: the admission for Message admission and sent Message rows, which is the same time on both rows of one Message; the Conversation entry for User and assistant rows; the producing Operation's resolution for a Tool Call; the group's last acceptance, the one at its greatest position, for a Tool Result (an Action's resolution, or the producing Operation's for a rejected call); and the fact itself for a Turn outcome, Session stop and refused send.
Times come from the Host wall clock: they order nothing, and they can repeat or step back across clock changes.
Message facts include original key/admission, exact content reference and queued/applied/excluded state, with Turn binding visible only after its application position.
A `turn_ended` row names how its Turn ended: `done`, `context_full`, `provider_refused`, `provider_unavailable`, `stopped`, `interrupted` or `failed`, beside the saved `code` it was judged from and the content of a done Turn's answer or a failed one's report.
The ending is read from the saved outcome, so it is no Store format: `completed` is `done`; `cancelled` is `stopped` when a Session stop selected the Turn and otherwise `interrupted` (a Model Interruption); `retry_exhausted` and a provider that could not be reached are `provider_unavailable`; `ResourceExceeded` is `context_full`; a refusal resending meets again (policy, quota, plan, model, sign-in, API key or a permanent HTTP status, by `failure_class`) is `provider_refused`; any other failure is `failed`.
An assistant row is `final` exactly when it is its done Turn's answer: the message the causing Operation selected by answer selection's rule (its last `final_answer` message, or with no phased message its last message), read from the saved items' phases rather than matched by text, so a repeated or blank answer still marks its own row, and only on a page whose end reaches the Turn's `turn_ended` row.
Stop selection/cutoff and pending/completed status are likewise evaluated at end.
The page's live work also carries `last_line`, the same bounded public last-line projection as a Session listing, read under that work's Store Access.
The live `work` object also carries required nullable `creator`, read from the same saved [Session provenance](sessions.md#session-provenance) as listing.
A non-null value is a canonical six-character Session reference; malformed IDs reject during decoding.
Detached children retain this creator even though they have no lifecycle parent.
Like live work, this preview may postdate a page's pinned historical end.
A listing row and completed live-work read carry `read_version`, the actual Store opening identity and commit generation sampled under their read Access (not a traversal's frozen `since`). The overview settles both into one keyed presentation row: newer revisions replace work and last line together, equal revisions retain that value after retry-clock normalization, and older reads cannot regress its state, detail or age. Conversation departure changes focus, not the accepted row. Listing membership and listing-only terminal-status accounting remain separate. Only a Host handshake establishes the opening identity; foreign reads cannot rebase it or consume listing tokens. The served Host and its Store tokens share that incarnation. A row outside membership is retained only while its conversation owns a reader, then retired with that producer.
This is a logical inventory prefix, not a historical transaction snapshot: immutable call classification remains attached to its item even at an interior end before the rejection-result position.
Call fields are in `name`, `call_id`, `arguments` order.
Content references carry exact decimal-string bytes and SHA-256; no preview truncation or private provider content enters activity.

A page's cost does not grow with the Session's history.
Each source of rows (Message admissions, User and assistant entries, Tool Calls, rejected calls and Action results by their acceptance, Turn outcomes, Session stops and refused sends) is read through an index on its Session and position: a range seek from the cursor in the page's direction that stops after 17 rows, the three groups merged and cut to the page plus one.
A Tool Result's group is judged only for the positions on the page, and a single row resolves by the same seeks at its own position.
A forward page's live call activity reads only the calls accepted after the page, and those still waiting.
A Store test holds an opening page and a forward page to equal SQLite VM steps after 10 and 10,000 earlier rows.

`POST /v1/activity-content` takes `kind:"activity_content"`, `session`, decimal-string `position` and `ordinal`, resolving the public row and provenance again.
Admissions, applied input, assistant text, complete Tool Results and outcome content (a completed Turn's answer or a failed one's report) stream completely once under the whole-stream reader/framing/failure contract above; calls and approval requests stream their original arguments JSON, and stops and contentless outcomes have no byte value.
Client returns owned fixed-size typed facts/cursors and synchronous borrowed content windows.
Invalid identities/cursors do not mutate work; contradictory canonical facts fence.
Ordinary connection capacity bounds readers, fixed metadata/scanner storage and 4-KiB windows; no worker, payload stage/cache or per-Session traversal survives return.
Persistent draft/input custody, terminal composition and the final one-pass opening/replay consumer remain separate work, including precommit preservation and postcommit fatality.
These reads alone do not complete opening.

### Work state and wait conditions

A Message observation follows its own `binding` or exclusion.
Unbound queued input may depend on a predecessor's active Turn; bound input depends on its own Turn.
Neither inherits an unrelated Turn's failure.
One Host function derives the required Message `state` with this precedence; readers switch on it instead of deriving it from `queue` or `work`:

| Condition, checked in order | Message `state` |
| --- | --- |
| The admission was rejected | `rejected`. |
| The Message has a terminal result | Its result status: `completed`, `failed` or `cancelled`. |
| A stop excluded the input | `cancelled`, without an invented binding. |
| The Session work's coarse progress is `waiting_for_permission` | `waiting_for_permission`, including unbound input queued behind that permission dependency. |
| The Message is bound to a Turn | `processing`. |
| Otherwise | `queued`. |

`queue` carries its admission ID and `admitted_at`, the admission's Host Unix second, as decimal strings; it has no status member.
`binding` carries the bound Turn, its current Operation and Attempt, including after a terminal result; it replaces the former `processing` object and says nothing by itself about completion.
Only nonterminal accepted Messages carry `work`, with the same Session `state` value as Current and list rows and nullable `first_action`, the earliest actionable Permission Request's Action ID. During automatic denial after a new Message, the work state may still be `approval` while `first_action` is null; the Message state remains `waiting_for_permission` until that work advances.
There is no separate coarse work status or duplicate Turn/Operation binding in `work`.
CLI `request inspect` adds `as_of` beside `key`, its Unix seconds at render, so a caller can compare that decimal string with `work.state.since` without knowing the time.

Optional `recovery` reports the bound Turn's Actions saved with `resolution_code='indeterminate'`, not an inferred Host restart or model retry.
It carries at most four `unknown_outcomes`, newest Actions first by descending Operation and then call ordinal, not by `resolved_at` chronology, each with decimal-string `action`, `operation`, call ordinal `call` and resolution Unix second `at`, plus nullable saved tool-call `description`.
`action` can be inspected with `rui action inspect`; `more` says whether older unknown outcomes were omitted.
Once present, recovery remains visible after the Message ends.
An indexed `EXISTS` in the Message observation gates the bounded recovery read through `action_operation_indeterminate`, so a Message without recovery pays no extra read and history never makes this read grow.

**Session work** is one derived value for the Session as a whole.
One pure core, `src/session_work.zig`, owns its precedence, and no phase is stored.
Each state carries `since`, the Host Unix second the Session entered it, read from the owning row's time.

The Host derives attention, group and valid actions with the work state, and readers switch on them instead of deriving them.
A true action indicates that admission accepts the intent if the described facts have not changed; admission can also accept an intent whose action is false.
`stop` is true when the Session has current or queued work a stop would end: a running or pending Turn, an owed tree obligation, or a queued Message.
`interrupt` is true only when there is an in-flight model Operation of the current Turn that interrupt would cut; it is not true for a completed Turn with an outstanding tree obligation.
`decide` is true when at least one permission decision is actionable.


| Condition, checked in order | Session work state | `since` |
| --- | --- | --- |
| A stop selected the active Turn, which is not yet terminal (its Bash Attempt is settling) | `stopping` | that stop |
| The active Turn's model Operation has an Attempt in flight | `working` | Attempt admission |
| The active Turn's model Operation waits for a retry due in the future | `retrying`, with due time, cause and the failed Attempt's ordinal, which is below the retry policy's maximum | retry scheduling |
| That retry is already due | `pending` | its due second, never before scheduling |
| A Bash or MCP Action the active Turn's Operation proposed is launched and unresolved | `bash`, with the oldest running call's ordinal (`call`; a running Host that predates it omits it, and a reader then gives the clock to the live line) and saved description (up to the shared 200-byte saved-call-line bound), the running count and the count awaiting permission | the oldest launch |
| Every unresolved Action the active Turn's Operation proposed awaits a Permission Decision | `approval` | the group's latest change, else the proposing resolution |
| Otherwise, with an active Turn | `pending` | the group's latest change, else the Operation's resolution |
| No active Turn, and an eligible Message is queued | `pending` | the oldest queued admission, or the latest outcome when that Message was queued before it |
| Otherwise settled own work, with a saved attached-tree obligation | `working` | the later of the own settled state and earliest owed work |
| No active Turn, and a stop excluded input newer than the latest Turn's input, after its outcome | `stopped`, cause `stop` | that stop |
| The latest Turn completed | `finished` | its outcome |
| The latest Turn was cancelled | `stopped`, cause `stop` when a stop selected it, else `interruption` | its outcome |
| The latest Turn failed | `failed`, with its code and, for a quota code, the saved `resets_at` | its outcome |
| No Turn | `idle` | Session creation |

- **Attached tree obligations (D239):** a Session owes its parent until its active
  Turn, eligible queued Message past its stop cutoff, unpublished forwarded rows,
  undelivered ending Message and recursively owed descendants have transferred
  into the parent's feed or eligible input. `src/store/domain/session_obligation.zig`
  alone reconciles that definition before commit in one set-based ancestor
  projection and streams their change-ring hints in the existing write batch.
  Maintenance adds no client-side ancestor rounds and skips unchanged values. The nullable `session.obligation_since` fact and its live
  parent index serve Current, listing and Activity reads; no reader scans attached
  Sessions or re-derives publication eligibility. Only otherwise settled own work
  becomes `working`; Turn, Operation and Action identities remain the Session's own.
  Standalone agents do not count. Format 73 backfills the frontier once; clearing
  the nullable fact removes its live index entry without DELETE authority or a
  second copy of the saved Session parent key.
- **Latest** and **before** follow the Session's order, never the clock, which can step back.
  A tool group's changes follow its proposal, and its resolutions follow one another by acceptance position; a queued admission and an outcome compare by position.
  An `allow_once` decision and a Bash launch claim no position: a decision is ordered against a resolution by time, and `bash` dates from the earliest launch time among running Actions.
  Authorization under `bypass` comes with the proposal and is not a decision.
- **`pending`** means eligible, not admitted.
  Whether Active Capacity is why it waits is not a Store fact; host information's slots in use supply that context.
- **A stop that selected no Turn** counts only if it excluded queued Messages.
  A stop that excluded nothing leaves the state unchanged.
- **A retry falling due** commits nothing, so Session listing's `since` does not report it.
  Every reader applies the same past-due rule when it reads, so a past-due retry reads `pending` everywhere.
- **`resets_at`** comes from the failed Operation's saved diagnostic.
  A missing or unreadable diagnostic reads `null` and fences nothing.
- **Inputs that contradict** the table's preconditions are canonical corruption, and the Store fences, as other readers do.
- **Message work** retains this full value as `work.state` while pending.
  Its coarse permission dependency informs the Host-derived Message `state` above, and `first_action` may still name an actionable sibling while Bash is running.

History supports recent entries, kind filters and after-position reads; unapplied input and reasons remain separately readable.

The Host reads a Message's admission, binding/exclusion, outcome and, while pending, Session work and earliest actionable Permission Request in one Store-owned observation, with the gated recovery read under the same ownership.
Work and recovery are client-neutral facts, not prompts or authorization instructions.
This is not a global cross-owner snapshot.
Current supplies a Session's summary and one-time work selection.
Repeated observation by the human frontend or caller-owned polling retains no connection between reads. A compound Message observation binds the content identity to its saved command and admission, then certifies the manifest and ordered index in bounded Store entries before returning it. Other Store work may proceed between entries.

All waits observe work; they do not start or resume it.
The adapter Session selections are not non-interactive CLI commands:

| Caller | Fixed selection | Returns when |
| --- | --- | --- |
| CLI `request wait` | The original request key in its captured or explicit Store | Request `state` is `completed`, `failed`, `cancelled`, `rejected` or `waiting_for_permission`. |
| Adapter default Session wait | Active Turn, otherwise oldest queued admission | Selected work is terminal or `waiting_for_permission`. |
| Adapter terminal-only Session wait | Same selection | Selected work is terminal. |

`rui request wait HANDLE` or `rui request wait --store PATH --key KEY` accepts optional `--timeout-seconds N`, a positive integer from 1 through 86400, default 300; other values are invalid arguments.
Handle resolution is the same as `request inspect`, without keeping the capture open between reads.
`client.waitCommand` owns the single poll loop, starting at 250 ms and rising to 2 s like the TypeScript feed follower.
It passes the last full reply's `since` token to `observeCommand`; `not_modified` retains that full observation and updates the token.
Busy or transient read replies matching the shared Host-unavailable classifier are retried within the timeout; transport disappearance and other read failures retain their existing failure path.
There is no new Host thread, resident waiter or held connection, and the client adds no thread.
Only this command installs SIGINT/SIGTERM handlers; the loop checks their flag between polls and sleeps interruptibly.
It prints the same JSON as `request inspect`, including CLI `as_of`, never the opaque `since` token.
Timeout or interruption leaves work unchanged and prints the latest full observation before returning exit 5 while still `queued` or `processing`.

A Session wait returns idle if no work exists and returns immediately when its condition already holds.
Later activity cannot retarget it.
The queue invariant drives successors, not the wait.
Closing an observing client changes neither work nor its saved request.
Attention does not create a Session phase or imply that progressing siblings are blocked.

On permission return, an adapter caller can read every actionable ID through a separate bounded-memory Current snapshot.
Later hints/results may reflect newer commits; only a decision revalidated against the Host's exact target authorizes an Action.
Full actionable IDs and indeterminate resolved Actions remain available in Session inspection, not in chat info.
Such commands may have run and were not replayed.
Older Turns require historical inspection.

Observation notifications are disposable hints; committed observations determine completion.
Required live-control publication remains mandatory for rescanning handed-off effects.
Inspection shows the unselected pending-message count beside current state or the latest outcome, including after failure.
Pending input is normal state, not an abandoned-input warning.
Excluded input remains distinguishable as not applied, with full content and reasons available through message reads.

### Outcomes and observation errors

Inspection and terminal-state waits return observed outcomes, including failure/cancellation, as data.
Failure to obtain an observation is a separate error, not evidence that the work failed or a submission was rejected.
State-changing core-command admission returns its committed acceptance or rejection under the core idempotency key protocol; communication loss leaves that answer uncertain until recovered.
These are distinct interfaces to the same authoritative facts.

All five core mutation handlers report Store infrastructure failure, after unchanged fencing, as HTTP 500 `{"version":"7","type":"invocation_error","code":"canonical_store_failure"}`, the same format as canonical observation/read failure.
This diagnoses the invocation, not a saved operation answer: it establishes neither rejection nor absence nor whether commit succeeded.
Ordinary accepted/rejected/replayed/conflict answers remain unchanged.
The captured Store, target, inputs and original key remain recovery authority; any caller receipt is context, not an outcome.
No server-side answer/replay/execution fields are fabricated for the fatal response.

The direct client's canonical-failure boundary validates the complete bounded JSON, string-only `version`/`type`/root `code`, and uniqueness of those consequential fields, including escaped-equivalent names.
Canonical authority requires HTTP 500, the current wire version and type `invocation_error`; nested codes and unknown fields receive syntax validation without becoming authority.
The mutation decoder and existing read classifier share this authority rule; mutation replies need no second parse.
A mutation envelope mixing root invocation diagnosis with operation-answer fields is invalid, not admission or fatal authority.
Caller-owned fixed storage retains no payload strings or general-heap dependency.
Mutation output retains typed HTTP status, validated bounded type/code when available, diagnostic reason and unconfirmed certainty, with original Store/Session/key/target as non-outcome context.
Captured JSON pairs its unchanged request handle with an `invocation_error`/`error` event rather than an admission.
Existing read/inspection raw output remains outside this mutation unit.
Interactive catches propagate canonical failure rather than resume with an apparent successful detachment.
Ordinary observation/transport failures keep their existing handling; this adds no retry or terminal owner.
Fatal diagnosis never replaces the original captured identity or demotes an earlier confirmed admission to unconfirmed.

`request inspect` presents the saved command's original rejection, queued/processing state, exclusion, failure, cancellation or completion as data.
`request read-result` explicitly streams its original public answer, or captured skill-refusal/reload outcome, when available.
Answer streams, including Action call ID and argument reads, withhold their final window until every advertised byte and EOF arrive, so a truncated read exits nonzero without complete-looking output.
Neither infers work failure from an observation error or substitutes the Session's latest result.
Before a Permission Decision in an ask-configured Session, normal interactive presentation shows the exact Workspace and complete decoded Bash command with the allow-once/deny choice, not numeric IDs.
Explicit inspection retains Action IDs, opaque provider call IDs and complete arguments.
A decision binds the exact Action target; presentation and inspection grant no authorization.

While observing a saved Message, the interactive caller describes only observed queue dependency and progress through the conversation's live line, without inventing tool text or a retry time.
Divyansh approved this on 2026-10-31 (front-end plan PR 3, mock CFWmXwCYELhK15T7LnR6ZF).
Unchanged observations produce no periodic reminders.
Permission attention beside in-flight work does not label the entire Session blocked.
A failed or cancelled saved Message remains distinct from a later answer in the same Session.
When the original submission loses its reply, its admission is uncertain until its saved request is recovered; when a confirmed admission later loses observation, the work remains accepted and is observed through the original key rather than resubmitted.
An indeterminate reported outcome never implies that an effect did not run or may safely be repeated.

### Wire format and command output

HTTP owns closed versioned JSON.
Non-interactive mutation receipts and metadata reads write one final complete JSON value on stdout, without interleaved events or prose.
Bounded streaming does not promise atomic pipe delivery or a resident result population.
Every such JSON value, and each JSON diagnostic, spells DEL and every non-ASCII code point as a `\u` escape through one CLI output owner, so names, Action proposals and Host replies cannot reorder or hide terminal output while decoded values stay exact.
Explicit content reads stream saved bytes only; a content reader that fails before content writes its typed diagnostic to stderr and leaves stdout empty.
Stderr carries pre-send recovery notices, including the generated-handle notice, and diagnostics.
A Message request alone also carries its sender's [environment](execution.md#bash-environment) as a framed prefix of its body; every other exchange's body is the JSON value alone.
A Message carries either its existing `text` envelope or an ordered `parts` array, never both. Each part is `{"type":"text","text":...}` or `{"type":"image","mime":"image/png"|"image/jpeg","data":...}`, with image data encoded as standard padded base64. The Host validates the decoded bytes and asserted MIME before admission. Message replies and accepted observations identify a compound input as `type:parts`, with the length and digest of its canonical ordered manifest; a single text retains its existing `type:text` identity.
Compiled public types and exhaustive goldens own fields, unions, omissions and integer encodings; `u64`-class values are JSON strings.
No handwritten duplicate schema or generic native command/result union is required.

The CLI's shared mutation renderer owns semantic JSON and contextual interactive replies, including concise Configure success.
Configure records validated admission before rendering.
Invocation errors retain the original Store, Session and key context and remain unconfirmed, even when successful interactive replies omit routine receipts.

Accepted mutation admission with complete successful delivery and disposal exits zero.
Rejected, conflicting or unconfirmed mutation admission is nonzero with distinct structured facts when deliverable; a delivered rejection or conflict exits 1 with its saved answer on stdout.
Its stderr names the replay the caller holds, which returns that same answer and never resubmits: `rui request recover HANDLE` for a generated capture, or `rui request recover --store PATH --record FILE --kind KIND` for an explicit one, because repeating the capture refuses the existing record.
A successful one-shot observation of pending, rejected, failed or cancelled saved work exits zero because the read succeeded.
`request wait` exits 0 (`done`) for `completed`, `failed`, `cancelled`, `rejected` or `waiting_for_permission`: this reports the observed condition, not successful work or permission approval.
It exits 5 (`later`, cause `wait_timed_out`, act `wait`) on timeout, or on SIGINT/SIGTERM while still `queued` or `processing`, after printing the latest full observation.
An `absent` observation exits 4 (`unconfirmed`, cause `request_absent`, act `recover`); the next step is `rui request recover HANDLE`, never a fresh submission.
Other read failures, including no serving Host, use the existing keyed read-error envelope and its exit status.
The stderr announcement after `session start` or `session send` is `request: H (wait: rui request wait H; if unconfirmed: rui request recover H)`.
Invocation, access, rendering, incomplete delivery and cleanup failure are nonzero.
An accepted answer stays authoritative if later cleanup fails.
Nonzero never proves noncommit.
Exact nonzero numbers are not another state protocol.

Conversation entry is quiet, without configuration banners or routine IDs.
Bash and `bypass`, the default, stay quiet: no notice or banner announces them. Permission mode is a setting and never appears as a chat-footer suffix.
Chat info’s Permissions field states `run without asking` or `ask first`; `session list` JSON retains the exact mode.
Existing Sessions preserve their saved mode.
User submissions are `›` blocks with their admission time and assistant prose has no role labels; concise tool outcomes stay quiet and the live line ends the conversation only while work is under way.
Divyansh approved this on 2026-10-31 (front-end plan PR 3, mock CFWmXwCYELhK15T7LnR6ZF).
Successful conversation omits protocol receipts and follow reminders; original captured request handles remain available through `/requests`.
If opening a Session started from the overview fails after its empty-Session Configure was confirmed, best-effort stderr guidance retains that request handle and an executable exact Store/Session resume command while preserving the original failure.
This reports admission only, not completion, and does not promise delivery under stderr contention or failed output credit.
These are presentation choices over existing Host facts, not new conversation or recovery authority; one-shot and JSON output remain unchanged.

### Connection capacity and control headroom

Connections serve one exchange then close, without pipelining or idle keepalive.
Intake uses lightweight transient exchange ownership that scales with simultaneous live exchanges, not dormant Sessions, retained history or already-admitted pending work.
Stream large values through bounded windows and charged scratch.
SQLite retains pending work; intake adds no application or durable queue.
Kernel backlog and serialized Store access may involve waiting.

Intake and durable admission make progress independently of execution credits, including when every credit holds a Bash caller sending a message.
Discovery, Session stop, Model Interruption and Permission Decision remain usable during supported ordinary load.
The former 12/10/2 connection quotas and thread-per-connection model are not constraints on the replacement.
Any caps, buffering or isolation machinery need demonstrated resource and progress justification.
Demand scaling does not promise unlimited memory or throughput; genuine descriptor, allocation, scratch and infrastructure failures preserve exact uncertainty recovery.

One local-work stack serves ordinary capture, reply production and cleanup; the other reserves stateful control service.
Ordinary work cannot borrow that control capacity.
Both retain canonical Store serialization and nonpreemptible I/O limits.
Successful local capture completion starts a fresh ordinary ingress inactivity wait, so Host processing does not consume the peer's next wait.
Discovery retains its absolute deadline.

Exchange custody lasts through import or rejection, delivery and required cleanup, including socket close and native handler retirement.
After delivery retires and local borrowers finish, intake closes the accepted socket independently of failed scratch reclamation.
Retained cleanup keeps its file handles, charge and exchange owner until reclamation succeeds.
Incomplete uploads publish nothing.
Every valid short control and its complete semantic response fit a field-derived bound, including framing and worst-case escaping, without content scratch.
Reject oversized discovery before body parsing, and route/kind disagreement as soon as `kind` is read, which is before any content capture when `kind` precedes the content.
A request's object members may come in any order, as JSON allows, so clients generated from `openapi.json` in any language can build bodies (D212).
Each member appears at most once, required members must all be present, and unknown members fail.
The parser takes two passes over the metadata it has so far: the first reads `version`, `kind` and `store` wherever they sit and counts content values as they arrive (`instructions` text and `outputSchema` objects in either spec, plus a Message's `text` or ordered `parts`), and the second fills the command, so each content value takes the capture its string arrived in.
Once `kind` is known, content the kind cannot carry fails before capture. Before `kind`, at most three scalar content strings are captured; an ordered `parts` array instead uses the shared scratch budget and the bounded part and image limits, even when it precedes `kind`.
Discovery keeps one acceptance-derived ten-second absolute deadline across headers, body and all reply/error writes.
Progress cannot renew it.
Mutation-response waiting and transfer inactivity follow [the client transport contract](cli.md#client-transport-and-observations).
Timeout releases temporary exchange state, not committed work.

Control service permits admission and durable acknowledgment, not a connection held until stop or cancellation completion.
Observe completion through subsequent one-shot reads.
If admission is unavailable or the reply is lost, the caller cannot infer whether a control committed.
Recover core controls with the original core idempotency key and inputs, preserving their committed selection.
Reconnection obtains a fresh complete observation, not a continuation of a partially delivered report.

### Live-control notification

Classify a connection after its complete request line, retaining the 16 KiB header bound and ten-second total header deadline.
Every accepted control result, including replayed acceptance and a reply deliberately dropped after commit, publishes one process-local changed hint before reply handling.
This publication is the required in-process progress signal for an already handed-off live effect; only the execution owner consumes it, scans the fixed execution slots and rechecks each candidate against canonical Store facts before cancelling transport.
The owner atomically clears the flag before scanning, so a publication racing the scan remains set for the next pass and earlier publications may safely coalesce into the current scan.
The hint carries no command or Operation identity and is never admission, settlement or recovery authority.
Before handoff and after sealed output, the already-required canonical handoff or settlement check can decide the control without that hint.
Restart destroys the old process's transports; the new owner reconstructs from canonical interruption facts rather than an old notification.

### Ingress ownership through admission

Ingress remains connection-owned through the receiving core owner's import or rejection.
Disconnect before complete capture releases it without mutation; once admission is in progress, disconnect cannot revoke it or close its source before commit/rollback and the last read.
Complete upload alone is not admission.
A lost state-changing core-command reply recovers through its core idempotency key.
Restart never imports leftover ingress.


## Required evidence


### Controls, inspection and local server


### Inspection and waits

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| [Typed Message and Action Resolution parts](#typed-message-and-action-resolution-parts) | `public-parts-integration` seeds Messages and Action Resolutions through the Store, then inspects all parts and exports PNG and JPEG bytes through the native CLI; `read-image-integration` checks a real `read_image` Action; `store/tests/action_parts.zig` checks ordering, metadata and byte reads, and the Store round-budget test checks each cursor step | The binary selector accepts images only. Existing text readers retain their compound-value refusal. |
| [Request and adapter waits](#work-state-and-wait-conditions) | `request_wait_integration.py`: completion and ask-mode permission return exit 0; timeout returns exit 5 with the latest observation; unknown key returns exit 4; Host stopped mid-wait returns the keyed read-error envelope and its status; restart mid-Bash exposes `recovery`; a Host-side count or lossless test observation proves a tier-2 `not_modified` hit while a sibling Session commits. Focused client tests pin poll schedule and state-to-exit mapping without sleeps; CLI argument tests pin the 300-second default and positive 86400-second bound. | Waits never start, resume or retarget work, or hold capture/Host resources between polls. Permission returns do not replace exact-target validation. Timing alone is not evidence of a token-tier hit |
| Current selection, pending count, ten recent Messages | `'Current facts'`, `current-facts-integration`, `store/sqlite_tests/` `'Current selects active then queued'` | Suppressing callbacks beyond 128 rows must fail the complete count. Fixed storage is not process memory or Mac evidence |
| [Per-key outcomes as data](#outcomes-and-observation-errors) | `human_cli_integration.py`, `store/tests/` `'Current reports progress alongside'` | Composed reads may span commits. A timeout proves neither rejection nor work failure |
| Configured allowed and loaded intent versus the frozen model offer | `store/tests/tool_set.zig` `'tool inspection distinguishes allowed loaded and frozen operation offers through edits'`: Current and Full reflect new intent, revision history retains prior intent, and both `full.model_operations[].offered_tools` and the provider request page retain the admitted offer across edits; empty/restricted sets, default-following loaded intent, explicit subsets and withdrawn MCP tools. `'stop_action effective offer preserves the historical settings limit'` checks the 129-name offer at the 128-name configured limit | `human_cli_integration.py tool-intent` / `tool_intent_cases.py` exercise the public CLI, resumed picker edits at 140 and 46 columns, and a frozen real provider request; TypeScript status mapping is checked in `clients/ts/test/requests.test.ts` |
| [Full report inventory](#capturing-and-delivering-reports) and scratch | `store/tests/` `'Full exposes exact closed'`, `'report scratch exhaustion'` | Latency and growth matrix: none located |
| Null and binding corruption rejection | `canonical_failure_integration.py nulls`, `bindings`, `null-interactive`, `binding-interactive` | Unfixed null witness fails at invalid-response; omitted binding check fails native mismatch and caller typed-error assertions, not setup |
| Keyed observation decoder | `canonical_failure_integration.py keyed`, `keyed-bindings`, `keyed-output` | `keyed-bindings` and `keyed-output` fail on unchanged baseline at omitted-binding and unknown-DOM assertions |
| Keyed owner footprint | `message_observation_resources.py BASELINE CANDIDATE` | Uninstrumented ReleaseSafe. Not aggregate memory or Mac |
| Session listing `since` | `change_ring` in `test-logic`: coverage after eviction, an entry point touching too many Sessions, the distinct changed set in ID order, one Workspace's entries, token grammar. `store/tests/` `'a since listing answers only the Sessions changed since its token, or everything'`; `store/sqlite_tests/` `'a Workspace's changed page reads only its own Sessions, however many others changed'`: with 4,095 distinct Sessions of another Workspace changed after the token, a scoped page takes the same VM steps as with none. `'a failed Workspace-key read fails and fences the entry point that touched its Session'`: an interrupted key read during a relabel and during a Message fails that command, commits nothing and fences. `store/tests/` `'a Session creation that rolls back never reaches a since listing'`. Every Store test runs under the test-build touch oracle, which panics when an entry point changes a Session's rows without recording it; `'the touch oracle names a Session whose rows changed without a touch'`. `protocol_reply.zig` `'a since reply answers its request's token'` and `'a traversal keeps its first page's token'`; `server.zig` `'an unchanged listing echoes its token'`. `session_list_integration.py`: an unchanged Store answers `not_modified` with the same token, a relabel answers exactly that row as `changed`, another opening's token answers `full`, and a malformed token is refused. `session_list_facts_integration.py`: a changed listing whose continuation is answered by a full first page prints that full listing alone, each Session once; a later page that fails, before or after that restart, prints nothing and exits nonzero | Spurious changes are allowed. `not_modified` taking no Store lock is by construction, not counted. Ring overflow under load is #557's measurement |
| Work classification domain | `session_work` in `test-logic`: attention and group across state kinds and optional IDs, transcribed from base client classifications; a collision test shows a current model call and an owed obligation can produce equal Work values. `store/tests/` `served work intents imply admission across permission and control states` checks each served intent against admission, including approvals superseded by a Message. | The derived action domain distinguishes model Operations from tree obligations. |
| [Session work](#work-state-and-wait-conditions) | `session_work` in `test-logic`: each table row and tie, a past-due retry reading `pending`, the coarse status map, a quota failure's reset time, and `error.CorruptStore` for inputs no writer produces. `store/tests/` `'Current, activity pages and Message progress report one work in each state'` and `'... through an approval'`, `'a stop that selected no Turn decides work only through the input it excluded'`, `'a quota reset is read from a saved record and never fences'`, `store/sqlite_tests/` `'contradictory work inputs fence the Store'`. With the clock stepped back: `session_work` `'the newer fact dates work, even when the clock stepped back'`; `store/sqlite_tests/` `'Session work dates a tool group by its last acceptance, even when the clock stepped back'` (approval after a denial, a settled group, and `bypass` Bash waiting after a sibling ran) and `store/tests/` `'queued input is pending from the newer of its admission and the latest outcome, even when the clock stepped back'` | Different reads may observe different commits. An `allow_once` decision against a sibling's resolution, and the earliest launch for `bash`, are ordered by time: neither claims a position |
| [Ancestor Activity forwarding](#public-session-activity) (D135, D180) | `store/sqlite_tests/` K4 forwarding regressions: three-level approval and ending feeds, ancestor allow/deny, unrelated and undelivered targets refused, replay, and injected commit failure between durable hops | Focused Store recovery; no OS-crash or power-loss claim |
| [Activity `at`](#public-session-activity) | `store/tests/` `'every activity row is dated by the fact that owns it'` and `'a Tool Result is dated by its group's last acceptance, even when the clock stepped back'`, `protocol_reply.zig` `'an activity row carries its time'`, `activity_integration.py` | None |
| [Model call Activity](#public-session-activity) (D179, D219) | `store/tests/` `'model_call derives frozen model and usage'`, `'model_call retry emits one row'` on SQLite and MySQL; `server_execution.zig` `'model resolution owner'` on SQLite and live MySQL (success/failure/interruption/stop/archive × prelaunch/no-response/first-response, with controls across live/backoff/replacement-prelaunch; backoff before and after custody retirement/reopen, replacement clears at admission; controls also inject callbacks during/after capture, including MySQL write-rerun; immutable after cleanup, coherent timing pairs, unchanged round budgets); `activity_golden_tests.zig`; `activity-integration`; `stack-frames` (shared row decode scratch, no per-item allocation); schema and MySQL `'model call timing'` migration tests; provider timing tests | One row per resolved Operation at admission, final-attempt timings (not retry totals), null first event when none arrived, frozen requested model, stored served-model evidence and usage, pagination and reopen. Format-68 nullable ALTER migrations preserve format-67 resolutions without backfill. |
| First Message, starter and `from_person_at` | `store/tests/` `'a list row carries its Session's Label, times, first Message, work and peers'`. `peer_integration.py`: B's first Message names A as its sender, A's names none, and only A has a Message from a person or script | Configure-only Sessions report `null` |
| [Conversation cursor bounds](#public-conversation-pages) | `protocol.zig` `'conversation cursor parser rejects'`, `conversation_page_integration.py` | None |
| [Ingress through admission](#ingress-ownership-through-admission) | `admission_integration.sh` | None |
| Slow report readers beside controls | `server_delivery_integration.py` | Mid-capture and partial-delivery failure: none located |


### Server ownership and connection capacity

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| [Client transport](cli.md#client-transport-and-observations) cancellation and backlog | `'transport cancellation'`, `test-full` | Backlog case Linux-only. Four mutation negatives must go red. Not File/sink preemption, Mac cancellation or aggregate footprint |
| [Host information](host.md#exclusive-store-ownership) probe and CLI status | `'Host information'`, `host-status-integration`; there a replacement Host's `started_at` is at or after the replaced Host's, in whole seconds, with no wait between them. `host_launch_integration.py`: one attached Host reports the same `started_at` in every reply and idles at `custody_occupied` 0. `control_integration.py` `prove_sealed_interruption_and_cleanup`: while an interrupted model Operation's settlement is held and its custody record with it, `host status` and Current both report `custody_occupied` 1 | Mode-000 denial needs non-root client. Held-connection descriptor negative: none located. A restart within the same second may report the same `started_at`, so no test shows a restart changing it. Start times order nothing across clock changes |
| Detached launch, C adapter argv witness and startup refusal | `host-launch-integration`, `host_launch_exit_test.py`, `'startup diagnostics'` | Linux does not qualify Darwin helper or PTY detach. PID SIGKILL is crash cleanup |
| [Exact-instance stop](host.md#infrastructure-shutdown) and effect-aware drain | `host-stop-integration`, `host_stop_integration_test.py`, `'shutdown fences'` | Not power loss. Forced kill is crash cleanup. Fixed-timeout and wait-removal mutations must fail. Python oracle is not native proof |
| [Ingress ownership](#ingress-ownership-through-admission), deadlines and retained cleanup | `'ingress'`, `host-status-integration` | Not disk latency or forced cleanup |
| [100 incomplete exchanges](#connection-capacity-and-control-headroom) beside controls | `'hundred incomplete'` | Burst is not an admission quota |
| Session-list resource census | `session_list_integration.py`, `session_list_release_proof.py` | Held-cleanup and leak negatives are opt-in, Linux |
| Reply delivery inactivity and drain | `'reply delivery'`, `server-delivery-integration`, `PeerCensus` | Run apart from load. Not Mac drain or SIGPIPE |
| Controls queue behind settlement | `'active model settlement'`, `control_integration.py` | Store hold proves exclusion, not latency. Unordered contention reports unavailable |
| Host reply and request bounds | `'exact worst-case'` | Each bound derives from the JSON shape its writer writes; full 128-byte keys, escaped Store, Session and workspace strings and escaped 96-byte codes. No fixed 8 KiB allowance |
| [Conversation pages](#public-conversation-pages) and streaming | `'public'`, `'sequential work'`, `'public assistant message provenance'`, `conversation_page_integration.py` | Exact message item, public part text, Session, Turn and Attempt bindings. Whole-value reads check stored bytes against their digest at the end; ranged reads past the start do not. No aggregate memory |
| [Session activity](#public-session-activity) and tool labels | `activity-integration`, `'tool label'` | `RUI_ACTIVITY_MEASURE=1` samples. No latency bound |
| [Content step faults fence](store.md#canonical-content-reads-and-retention) | `'public content SQLite step'` | None |
