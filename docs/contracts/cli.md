# CLI operations and configuration

[Architecture](../../ARCHITECTURE.md) owns shared guarantees, terminology, and the source map.
[Verification](../../VERIFICATION.md) owns global evidence rules and gates.

## Accepted contract

### Public operations

The adapter exposes Session configuration/messages, keyed result reads, observations/history/wait, permission, exact Model Interruption and stops.
Driving is internal, not public `advance`.

#### CLI modes and commands

The live human conversation mode handles input, approvals and resume while attached.
The non-interactive mode serves agents and scripts: mutations return admission receipts, reads observe once and content reads explicitly stream saved bytes.
There is no `exec`, `follow` or `wait-session` command and no compatibility waiting mode.
`request wait` is a client-side observation loop for one fixed request, not a Host waiting route: it never starts, resumes or retargets work and holds neither the capture record nor any Host resource between reads.
Caller scripts can wait for that request and then read its saved answer with `request read-result`; Sessions should use Message delivery and end their turn rather than hold a Bash execution slot waiting.

The CLI uses shallow resource-first commands with one canonical spelling per operation:

| Resource | Operations |
| --- | --- |
| `session` | `start`, `configure`, `send`, `inspect`, `list`, `stop`, `interrupt-model`, `read-conversation`, human `resume` |
| `request` | `inspect`, `wait`, `recover`, `read-result`, `list` |
| `action` | `inspect`, `allow`, `deny`, `background`, `stop`, explicit saved-content reads |
| `host` | `start`, `stop`, `status`, `serve` |
| `defaults` | `inspect`, `configure` |
| `auth` | explicit operator `login` |
| `model` | optional read-only `list` |

`request` means a submitted caller command, not a provider model request.
Inspection observes once.
Recovery retransmits original captured intent with its original identity and may admit it if it never committed.
A keyed result read streams only the originally bound terminal public answer, without private provider items.
Request listing enumerates local captures, not Store-wide work history.
Existing explicit Store/key/record routes and exact hex selectors remain available.
Renaming introduces no new runtime entity or authority, deeper command hierarchy or compatibility aliases.

#### Configuration and input

Ordinary fresh `session configure` without a Session selector or preset captures creation intent and the selected Workspace, provider and any selected model before transmission; the Host chooses its recommended model only when the model is omitted and resolves omitted settings; the Store allocates the ID at commit and the accepted reply returns it.
Fully explicit settings bypass unused preferences.
`session configure --preset NAME` captures the named Host Settings preset and only explicitly supplied overrides, without filling fresh defaults. The shared resolver applies the preset first, then the Host fills remaining omitted settings. Presets are not supported on `session start`; they cannot be used to update an addressed Session. On preset creation, `default` sends null for policy overrides: a null output reservation clears it, while null effort and compactAt request the Host defaults. Empty instructions, empty tool lists, `--label ""` and `--text-output` remain explicit overrides.
The CLI checks every supplied model's syntax before capture, input reads or Session mutation.
A refused model diagnostic names the ID and lists the [IDs Rui lists](#supported-model-ids).
A typed ID with valid syntax that Rui does not list is admitted with one line, `Rui does not list ID; it uses default limits`, and runs with [default limits](model-io.md#choosing-and-validating-compacted-context).
`session configure --parent ID` without a Session selector and `session start --parent ID` capture the existing create-only parent relation.
They send the creation spec through the native inherit-and-narrow owner: provider, Workspace and saved Bash environment come from the parent, configured allowed tool names and Permission Mode may only narrow, and explicit provider or Workspace overrides remain present for canonical refusal even when equal.
The CLI adds neither its default provider nor its current directory to an attached spec.
For attached creation without a preset, the CLI sends any selected model and explicit choices, with saved effort and Permission Mode separately as creation preferences; the Host resolves omitted settings at admission. An omitted compaction trigger uses the inherited provider: with a Codex parent and `gpt-6.1-sol` it is 244,800 tokens whether the saved provider is OpenAI or Codex. Before this change the saved OpenAI case sent 945,000 while the saved Codex case sent 244,800. An explicit `--compaction-trigger TOKENS` fixes the threshold and is preserved.
An attached spec with explicit model, effort, Permission Mode and concrete compactAt bypasses unused binding preferences, so an absent HOME or stale saved provider cannot prevent its canonical parent refusal.
Missing or archived parents and parent on an addressed update reach the saved native refusals.
Addressed configuration preserves the exact canonical ID and sparse update inputs.
It does not probe existence, inherit the configuring agent's settings or apply creation defaults to an existing peer.
`session send` requires an already configured Session.
A later send failure does not undo accepted configuration.

`session start` captures one Message mutation with fresh-Session configuration and an empty requested Session ID.
Initial configuration accepts the same agent spec and streamed instruction and schema content as Configure; with Message text, one request carries at most three sealed content values.
Inside one Store transaction, it validates the sender and configuration, allocates an ID through the same collision-safe allocator as configure, and admits the first Message to that new ID.
Its successful stdout is the same JSON mutation receipt as `session send`, with the allocated six-character ID in `.context.session` and the request handle in `.context.key`, followed by newline: admission rather than execution or completion.
Only the accepted `session start` receipt adds `configuration` immediately after `context`, containing `provider`, `model`, effective `reasoning_effort` and `effort_source`.
For an unattached start, `provider` is the concrete resolved provider.
For an attached start, `provider` is null and `parent` is the captured parent ID: the receipt reports the omitted inherited binding without guessing its value.
The effort source is `flag` whenever `--reasoning-effort` was given (including `default`); otherwise it is `saved` when the captured saved preference is non-null and equals the Host-returned effective effort, and `model_default` otherwise. This label compares the captured preference with the answer and does not infer support from a client catalog.
Without an override, the effective effort is the Host product choice: `low` when supported (also for an unlisted model), otherwise the lowest listed effort, otherwise null.
The provider, model and effective effort come from the saved creation answer for the immutable first revision, including on replay. Retrieving that answer is bounded independently of Session history; it does not scan a Full report. Rejection output and `session send` receipts are unchanged.
Replay returns the original allocated ID, Message admission and result even after cancellation or restart; changed creation settings or Message bytes conflict with the original request key.
Rejection creates no Session.
Any canonical failure rolls back allocation, revision and Message together.
This is not a configure/send wrapper.
It uses the existing Message endpoint, captured request kind and observation/result contracts.

CLI Message text comes only from stdin for `session start` and `session send`.
Instructions come only from stdin through `session configure --instructions -`.
File-valued text/instructions flags and inline or positional Message operands are unsupported, including after `--`.
A start cannot also read separate instructions; it uses fresh defaults, and explicit instruction changes require a separate configure operation.
Complete UTF-8 bytes, NULs and trailing newlines remain unchanged under existing content bounds.
Empty Message stdin refuses before capture publication or admission.
Empty instruction stdin is an explicit empty update.
Reject unknown options, duplicate singleton options even when equal, conflicting selectors and two consumers of stdin before capture or transmission.
An option value spelling `--help` remains data.
Domain validation and saved rejection stay with the existing owners.

CLI failures cross one catalog boundary and render a stable code with accepted inputs and a concrete repair when their cause is mapped.
Unmapped legacy failures remain on an explicit shrink-only pending inventory, render `internal_unexpected` without a raw Zig name and exit 1.
The detection owner distinguishes malformed Store paths (exit 2), unusable Store directories (exit 6) and a Store with no serving Host (`host_not_serving`, exit 6); the latter prints the exact `rui host start --store PATH` command.
An unreachable Host is absent only when the Store lock is free; a missing or refused control socket while that lock is held is `host_stopping` (exit 5), with advice to wait for shutdown before restarting and retrying.
A Host from another Rui version that does not speak this rui's protocol is `host_incompatible` (exit 6); pause it with the Rui version that started it, then start it again with this rui.
Other transport failures while the lock is held, or a failed lock probe, do not establish either condition and retain their original classification.
Missing input or endpoint paths never imply that no Host serves the selected Store.
Failure after upload begins leaves admission unconfirmed; inspection or recovery must retain the original identity.

#### Help and prerequisites

Root help (`rui --help` or `rui -h`), resource help and operation help succeed with useful stdout and zero exit without a Host, credentials, preferences, TTY or state changes.
Invalid fresh invocation exits 2 with a catalog stderr diagnostic naming the relevant flag or field, accepted inputs and repair.
A positional Session ID on a command whose selector is a flag names `--to ID` or `--session ID` rather than mistaking the ID for Message text.

The CLI derives exit status from admission certainty and the catalog remedy, not the rejection code alone:

| Exit | Caller action |
| --- | --- |
| 0 | Done. |
| 1 | Failed for a cause not classified above; stderr names it. Treat it as unknown: do not assume the request was or was not sent unless stderr says so. |
| 2 | Invalid fresh invocation; nothing was sent. Fix the invocation. |
| 3 | Rui answered with a saved refusal. Correct the request; a resend needs a new key. |
| 4 | Admission unconfirmed. Run `rui request recover HANDLE` (or the printed explicit-record recovery); never resubmit with a new key. |
| 5 | Retry the same request unchanged later (Host busy, Host stopping or result not ready). |
| 6 | Repair the environment, then retry unchanged (known stopped/unreachable Host, sign-in required or locked Store). |

An error enters 2-6 only once its cause is mapped; every other failure stays exit 1 until it is.

Uncertainty takes precedence over remedy: a busy-looking mutation response without a confirmed admission remains exit 4, not 5.
Multiple outcomes, including `session stop --all`, aggregate in cautious order **4 > 1 > 6 > 5 > 3 > 2 > 0**, never numeric maximum or first failure.
A nonzero exit may follow acceptance; it does not authorize a new identity.

Saved rejections render one catalog line on stderr with their existing wire code, input flags or fields, accepted values and repair.
The ending says the rejection was saved, replays as saved and needs a new key for a resend; stdout JSON is unchanged.
Replay advice uses the saved code, never current argv values, current Session settings or a live accepted subset.
Today's ambiguous saved codes remain honest about every possible cause; splitting them and saving witnesses belongs to the later wire/Store change.
The static saved-code facts are replay-affecting and must not be silently reinterpreted in a compatible Store.
HTTP statuses and wire spellings are independent of this CLI exit policy and remain unchanged.

Command/option definitions own syntax and scoped help; public types and goldens own semantic fields.
There is no second catalog, generic JSON-command input mode, schema generator or registry.
Ordinary non-interactive calls never implicitly start a Host, sign in or enter setup.
The receiving Host owns provider authentication and refresh; client-local credential readiness is not a peer-admission prerequisite.

#### Session listing

The protected `POST /v1/list-sessions` read enumerates the Store's accepted, configured Sessions, including those with no Messages and none in local request captures.
The public client `listSessions` streams one complete JSON page to caller-owned output, not through client SQLite.
Request fields are `version`, `kind`, canonical `store`, `workspace` (exact canonical stored path or `null` for all), string-valued `after`/`ceiling` (both `"0"` initially), and optional `archive` (`active`, `archived`, or `all`, default `active`).
A first page may also carry `since`, an opaque token from an earlier reply.
Response `session_list` has up to eight `sessions`, then `delta`, a new `since` token, and `next` as either `null` or a continuation.
Each row has exact `reference`, `workspace`, `provider`, `model`, `tools`, `permission_mode`, and `archive_state`; nullable decimal-string `pin_order`, derived from the current pin Command; nullable `parent` (the lifecycle attachment reference, otherwise `null`); required nullable `creator` (the immutable creation-provenance reference, including detached children); nullable `label`; `created_at`; configuration `revision`; activity `end`; nullable `first_message` (position, admission, `admitted_at`, nullable Session `sender` and content reference); `work`, the Session's [Session work](inspection.md#work-state-and-wait-conditions) state with `since` and that state's facts plus the latest Turn, Operation and first actionable Action; and `peers.from_person_at`, the admission time of the latest Message without a Session sender.
A non-null `creator` is a canonical six-character Session reference; malformed IDs reject during decoding rather than becoming null.
Listing reads `creator` from the Store's [Session provenance](sessions.md#session-provenance), independently of the lifecycle `parent` field.
Rows also carry nullable `last_line`: `{position, text}`, with a string-valued activity position and nullable text.
It is the later by position of the newest ended Turn's outcome and the oldest pending approval's call.
Completed Turn text is the first non-blank line from at most the first 1 KiB of public answer content, cut to at most 200 UTF-8 bytes at a code point with “…” when longer.
Private content and failure or stop outcomes have null text; an approval uses its saved `model_tool_call.description`.
Deciding an approval removes that candidate, falling back to the newest ended Turn; a Session with neither candidate has null `last_line`.
These derived facts join the existing row-settings read, adding no list-page round, stored copy, Host cache or write.
`work` is the same value that activity pages, Current and Message observations carry.
With `since`, the Host answers one of three `delta` values.
`not_modified` means no row has changed on this Host since the token; it is answered before any Store entry, lock or scratch, and never while the Store is fenced.
`changed` returns only the Sessions in the request's scope whose rows may have changed since the token, read fresh, in reference order, eight per page; its continuation carries the same `since`, the first page's `through` and the last `after_reference`, and a continuation the hint no longer covers restarts as a `full` first page.
`full` is the ordinary traversal in creation order, when `since` is absent, too old or from another Host opening (a Host opens its Store once, so an opening is one Host instance); its continuation carries `after`/`ceiling` without `since`.
Each page's token covers its own rows, and a traversal reports its first page's token.
A reply may include Sessions that did not change; it never omits one that did.
Reuse the same Workspace and archive filters with `next`; a new traversal begins with zero/zero.
Full pages apply the archive filter before pagination.
The `active` filter includes `archiving` so unfinished work remains visible.
Changed pages include out-of-filter archive updates so a cached view can remove rows that no longer match.
A filter change discards the old rows, token, and continuation before a fresh full traversal.
The first read fixes a `created_seq` high-water mark while under the Store lock; accepted later configurations may update existing summaries but newly created Sessions do not enter the traversal.
Sessions are not deleted, so `created_seq` keeps creation order.
The Workspace index (Workspace digest, then `created_seq`) and the global `created_seq` index bound each keyset scan.
An `all` archive filter visits only the next nine rows.
Selective archive filters may scan hidden candidates before finding nine eligible rows, with indexed archive and stop lookups for each candidate.
In the worst case that scans the scope, but retained IDs and returned rows remain bounded by the page.
No mutable last-activity order or second Session registry exists.
The one exception is in memory: the Host keeps a fixed ring of its most recent 4,096 (Session, commit counter, Workspace key) entries, recorded where its commit counter advances, by every write path for each Session it touched.
A Workspace's key is the `created_seq` of its first Session, stored on each of its Sessions when it is created; Workspaces are immutable and Sessions are not deleted, so the key never changes.
A writer reads it with one seek when it first touches a Session, inside its own transaction, so a failed read fails that entry point and fences the Store like any other canonical read; nothing is read after the commit.
An entry point that touches more than four Sessions, or rolls back after changing rows (a Session it created no longer exists), forgets everything before it.
A `changed` page reads the asked Workspace's key with one seek, makes one pass over the ring's entries in memory, and then reads only the rows it shows, at most eight; Sessions in other Workspaces never reach SQLite, however many changed.
Like the [history memo](model-io.md#history-memo), the ring is derived, never durable and never read by recovery: it is a hint that answers `since`, may report spurious changes, restarts with the Host, orders nothing a reader can observe and grants nothing; overflow or restart degrades to `full`.
In test builds, SQLite triggers record every Session whose rows an entry point changed, and the Store panics when that entry point did not record it.
Each row's work, first Message and `from_person_at` are derived under the same Store lock from that Session's own indexed rows, by a fixed number of seeks that does not grow with its history.
Nothing is cached or persisted as a Session phase.
`end` says where a forward activity read resumes.
Full or current inspection of a chosen reference remains a separate observation.
Each list page is fully captured into charged, unlinked scratch under the Store lock, then delivered with no SQLite cursor or transaction held over a slow client; disconnect and release close that owner.
The eight-row bound limits worst-case escaped workspace/reference/model/label/description/code output without truncating any identity or fact.
The worst-case row size is derived at compile time from the fields' bounds and must fit a 32-KiB budget.
Concurrent captures follow the live-exchange resource contract.
`rui session list [--store PATH] [--all] [--archived|--include-archived] [--since TOKEN]` selects the explicit/saved/HOME Store and filters by canonical cwd unless `--all`.
It collects the rows of bounded pages in unlinked scratch, not memory, and prints one complete JSON value with the traversal's `delta` and `since` once the last page is read.
A failed page prints nothing and exits nonzero.
A changed traversal that restarts as `full` drops the rows it collected, so each Session appears once.
This read never starts a Host, imports local records or selects a Session for resume.

Client interprets each list exchange as owned `SessionListReply` facts: a complete eight-row-bounded page or a validated HTTP status/type/code read failure.
Rows retain the exact reference, Workspace, model and Label strings, named provider, closed tools, Permission Mode, times, first Message, Session work and `from_person_at`; slices borrow the fact value independently of scratch/reply-buffer reuse.
Validation also checks that the Label is valid, that each work state carries exactly its own facts, that the first Message's sender is a canonical reference, and that `delta` and `since` are present, with no rows on `not_modified` and the request's own token echoed there.
`SessionTraversal` in `src/protocol_reply.zig` owns one traversal's cursor, ceiling and `since`.
Validation requires the version/type, all row fields and explicit nullable `next`, rejects consumed duplicates and duplicate references/tools, checks every row against the requested Workspace, and requires a full page plus increasing canonical signed-SQLite cursor positions with the same continuation ceiling.
Non-null `next` requires `after < ceiling`: a ninth matching row must exist beyond the eighth row's position.
A full final page with `next:null` remains valid, as does a request cursor at its ceiling for an empty terminal probe.
Unknown extensions are syntax-validated and discarded.
CLI human and semantic JSON output use these facts only after the whole page validates, never raw Host spelling or unknown metadata; failure is nonzero and cannot establish absence, rejection or noncommit.
The typed decoder requires the body at file offset zero and consumes exactly `[0, report.bytes)`, rejecting zero, malformed/truncated promised input and physical EOF before the promise ends; backing-file bytes beyond that range are ignored without changing the borrowed file.
Transport writes start at the destination's current offset, without rewind or truncation; callers place each body appropriately, and the CLI uses fresh scratch.
Caller-owned unlinked report scratch, one 4-KiB input window and 12-KiB parser scratch support maximum escaped configured fields; exhaustion fails explicitly, without truncation.
There is no Session registry, resident population/history cache, new transport exchange or successful partial page.
Current/attention and Full remain separate report families.

#### Store selection and defaults

Human `rui session resume` enters an already configured Session and retains its address within the interactive process; chat info displays its effective Folder, Permissions and label.
Every destination-bearing command selects its Store by explicit `--store`, then the private saved default, then `$HOME/.local/share/rui/store`.
Explicit selection does not read preferences.
Scripts can pin destinations with `--store`.
Existing Stores use the private canonical validator, including supported aliases.
`host serve` may create a missing selected explicit or HOME Store.
A missing or invalid saved Store fails rather than selecting another.
Captured requests retain their recorded Store across preference edits.

`rui defaults inspect` reads defaults without writing; `rui defaults configure` saves explicit Store/provider/model, notification, effort and permission edits.
A saved Store is the global default for commands without `--store` (captured requests keep their recorded Store), so `defaults configure --store` names it on stderr; stdout and exit status are unchanged.
Interactive `/setup` keeps the same future-default capability.
After a successful change in a conversation it prints one line, `Saved defaults for future Sessions. Active Session unchanged.`, and follows it with the Store, provider and sign-in report only when the next Session cannot start as saved; app settings shows the saved defaults themselves.
The overview’s `/setup` keeps the full report.
`--notifications on|off` on either saves whether an open overview or conversation sends [desktop notifications](session-ui.md#desktop-notifications); it is on by default and changes no Session.
`--reasoning-effort LEVEL` on either saves the effort new Sessions start at, and `default` clears it.
Every fresh Session may use saved effort and Permission Mode independently of explicit provider and model selectors. The client captures these as creation preferences, and the Host uses a supported saved effort when effort is omitted, otherwise the model default. A saved permission applies when valid and within parent authority; otherwise the Host uses its default, which remains subject to parent authority. Explicit effort or permission wins, including an effort reset to default, and remains subject to normal validation rather than fallback. Addressed updates do not send creation preferences; admission refuses an update carrying them.
`--permission-mode ask|bypass` on `rui defaults configure` or `/setup` saves that new-Session default, never changing existing Sessions.
The defaults report includes the saved `permission_mode` (null when absent); the app settings Permissions row between Effort and Notifications shows `run without asking` for bypass and `ask first` for ask.
Enter opens those two choices, and picking publishes through the same preferences writer as the other settings rows.
`rui session configure` creating a Session and each overview start read it at that moment, so a choice made since an overview opened applies.
When saved defaults change, the overview resolves its prospective provider/model through `new_session_selection`, retaining explicit launch selectors; fully explicit launch bindings do not follow unused saved defaults.
`/setup` remains chat-local and has no overview command path or held per-start override.
`/effort LEVEL` in a conversation saves LEVEL the same way once the Session accepts it, because the effort a person picks is the one they want next time; chat info’s Effort field changes only its Session.
These edits never change an existing Session's saved binding or permission mode.
An explicitly edited Store is validated and canonicalized before publication, allowing replacement of a deleted saved Store.
An unchanged saved Store retains syntax validation but its availability is checked only when selected for work.
Independent provider/model inspection or publication does not require an unused Store to exist or fit.
Inspection reports unavailable prospective destinations without selecting an alternate.
HOME and the private preference path must still be valid.
Interactive defaults output escapes dynamic fields without changing stored bytes.
The chat’s `/setup` accepts double-quoted values and escaped quotes, backslashes or spaces without shell expansion; invalid quoting rejects before mutation.

The versioned private file under `$HOME/.config/rui/preferences` contains only these three optional values, the notification choice, the new-Session effort and permission mode, not credentials, Session lists or work status.
Versions 1–3 have no saved permission mode.
A version 1 file reads as notifications on, and Rui writes version 1 while they are on and no effort or permission mode is saved.
Turning them off writes version 2 with a `notifications=off` line, which an older Rui refuses to read; turning them on again, or removing the file, lets it read preferences again.
Without saved permissions, a saved effort writes version 3, which adds a `notifications=on|off` line and a `reasoning_effort=LEVEL` line; clearing it writes version 1 or 2 again.
A saved permission mode writes version 4 with those same lines (an empty `reasoning_effort=` means absent), followed by `permission_mode=ask|bypass`.
Publication always chooses the lowest version that holds the saved values.
Only `codex` is selectable as a provider in this slice.
The CLI owns the bounded file of at most 1,024 bytes, validates private ownership/access and format on read, and serializes updates under a private lock.
Publication writes/syncs a same-directory temporary file before atomic rename and directory sync, including HOME and `.config` parent entries on first creation.
A failed pre-rename save retains the previous complete value; post-rename sync failure reports uncertainty.
Inspection creates neither directory nor file.

### Caller capture and recovery

Non-interactive mutations are prompt-free and independent of TTY.
Their destinations are captured exactly, with explicit Action targets where required.
A direct-core mutation generates a fresh core key and durably captures its complete inputs in one private, enumerable caller record before transmission.
Pre-send recovery notices use stderr; failed announcement prevents original transmission but leaves the capture recoverable.
A fresh client can inspect or recover that original request, or create a fresh record for new intent.
Recovery does not reread changed input files or preferences, reapply request settings or retarget an established result.
New generated and explicit records have a private bounded `.routing` companion containing the canonical Host-directory selector, or the runtime hint for legacy opaque MySQL selection, separately from immutable wire request bytes. The capture owner durably publishes routing before publishing the request marker, under the same lock; orphan routing alone is neither enumerable work nor admission authority. The raw request format is unchanged.
Recover, inspect, wait and read-result share captured routing resolution through the placement owner and compare discovered Store identity with the captured identity before dispatch. They may follow edited saved placement only when that identity still matches; invalid, insecure or unknown-format companions refuse rather than fall back. Missing companions retain old-record lookup behavior. Read-only observation reads the bounded capture identity, not an entire replay body, and closes its reader before waiting. Explicit retry guidance names the selected directory; private record-parent aliases remain supported.
A recovered Message carries the recovering process's environment, never one saved with the record, because the record never holds one.
The explicit-key/record commands remain available.
Records are recovery custody, not a Session directory, job database, dispatch queue or work-status authority.

If the caller exits before delivering its generated handle, enumeration still finds the capture.
Enumeration alone cannot reliably correlate one concurrent invocation when every notice and receipt was lost.
Callers requiring pre-known identity use the existing explicit key/record capability.
Missing or unreadable capture never proves noncommit.
No automatic retry or fresh-key replacement follows from a failed process exit.

### Client transport and observations

Client's typed `Requests` borrows `std.Io` and an optional caller-pinned `Cancellation`; existing top-level `std.Io`/File APIs forward with cancellation absent.
Each invocation owns one socket through return and borrows its inputs, captured reader, sink and reply storage until then; a caller using a worker retains them through return/join before reuse or destruction.
Stop ends only the local exchange with `Cancelled`, never revokes Host import/committed work, deletes captured intent, or turns known acceptance into rejection.
At socket service points, observed stop precedes timeout/error; an already completely framed and delivered response remains complete without a retrospective stop check.

Cancellation-aware connect/write/read waits use nonblocking sockets and at most 100-ms polling quanta, not an end-to-end return bound.
After mutation upload completes, five seconds without response progress expires the local exchange, including the silent first-byte phase.
Timeout leaves an unconfirmed outcome with the original recovery identity; it does not cancel admitted work.
Large uploads and streaming reads retain separate 60-second transfer inactivity.
Only positive byte progress renews inactivity, not polling, `AGAIN` or interruption.
Progressing transfers have no minimum rate or total deadline.
Source-file and synchronous sink work are not preemptible.
Result, inspection and Session-list streaming use existing 4-KiB windows; a synchronous sink consumes or copies each borrowed window before returning.
Partial delivery is not a complete response.
Host discovery keeps its separate absolute deadline.

The direct client owns selected-Message interpretation: a Store/Session/key address needs no local capture, and observation validates the wire envelope, exact key, command kind and Session binding before returning typed admission, Host-derived Message state/outcome, failure code and optional work/Action facts.
The selected terminal outcome takes precedence over Session work; terminal observations omit `work`, never fabricate runnable work.
Non-200, absent, malformed or mismatched observations remain read errors, not saved work failures.
Observation uses [Client's supported fixed-storage facts](admission.md#recovering-a-submission-after-a-lost-reply); returned code slices borrow the observation value until it leaves scope, independently of reply-buffer reuse.
Output renders those facts, not unknown extensions; completed answer bytes keep their streamed read path.
The human frontend owns live observation and transient status based on Message `state`, Session work and Action presence.
The exact Action ID remains the attention target without periodic reminders.
Current inspection and keyed observations are separate coherent snapshots, not a combined transaction or re-selection rule.
No reader substitutes a successor's result for the originally selected Message.

Client also owns Current interpretation: validate exactly the promised offset-zero body before returning explicit unconfigured or fixed owned settings, work, selection, ten recent bindings and execution metadata.
Effective reasoning effort and its nullable override are required fields; null effective effort explicitly leaves the provider effort unspecified.
Every unresolved/resolved Action, rejected call and actionable permission retains its identities, authorization/outcome and complete content-reference metadata through synchronous traversal of the same caller-owned immutable capture; row slices expire at callback return.
No collection cap or resident population results.
Supported semantic JSON discards unknown extensions, scans the capture once for validation and four more times for its grouped attention arrays, trading approximately five input traversals for fixed storage and independence from JSON object field order.
Scratch remains pinned through rendering/return; failure cannot publish a successful partial observation.
Full's existing streaming consumer and inventory remain unchanged.

### Supported model IDs

`model_catalog.shipped` is the single compiled-in catalog of model facts, generated from a models.dev snapshot.
Each exact ID has its listed efforts, optional context window and OpenAI membership; there is no catalog default effort or per-Adapter context cap.
For duplicate IDs, models.dev's OpenAI entry wins, otherwise the first provider's entry wins.
For each Host consumer operation, the Store selects the saved source's generation and facts together; only absence of a saved source selects shipped facts.
A saved generation is authoritative even when empty, or when the requested ID is absent: neither case merges in or resurrects a shipped entry.
Capability and list renderers take the caller's selected facts explicitly; they do not own a mutable catalog or read the Store themselves.
`rui session configure --help` uses shipped facts, needs no Host or credentials, and does not claim to show a Host’s saved facts.
There is no Host help request or fact-discovery extension to the wire.
Help and invalid-model errors render shipped OpenAI IDs in catalog order; help's effort exceptions derive from those same entries.
ChatGPT's Host model list instead renders the selected generation's OpenAI IDs in catalog order.
The model-list source is `catalog` on the wire for a catalog list (saved or shipped), and `catalog_fallback` when a live provider-list fetch fails.
`product_defaults.recommended_model` must name an OpenAI entry; a catalog test checks this.
IDs are exact and case-sensitive, without aliases, prefix matching or inferred providers.
Inclusion claims neither account entitlement nor cross-model continuation qualification.
Session binding and normal provider rejection remain unchanged.

The Host does not check the saved future-Session model default at startup: any pin with valid syntax starts Sessions, and one outside the catalog runs with default limits.
A missing or null catalog window uses the product's unlisted context estimate, while compactAt admission enforces only non-null known windows.
A catalog entry accepts exactly its listed efforts, including `none` where listed; an unlisted model accepts every effort in Rui's grammar and passes it through.
A provider refusal of an effort update follows [effort inside the history](model-io.md#effort-inside-the-history); it is not a configuration rejection or a request error.
Missing or unreadable future defaults do not prevent a Host from serving existing saved work.
A pin with invalid syntax rejects fresh CLI creation before capture rather than falling back to the recommendation.

The Host resolves omitted fresh effort using an applicable saved creation preference, then the product effort `low` if accepted, otherwise the lowest listed effort, otherwise no effort. An explicit effort or reset takes precedence over the saved preference.
ChatGPT sign-in’s default compactAt is the smaller of the provider-keyed product default 244,800 tokens and 90% of the catalog window, using the unlisted context estimate for a missing or null window.
This keeps 244,800 tokens for large windows but uses 115,200 for a 128,000-token window such as `gpt-5.3-codex-spark`, including when resetting compactAt to its default.
Other providers default to 90% of the catalog window, or 115,200 tokens for a missing or null window.
Omitted updates preserve existing settings; explicit default requests use the Host rule. Frozen Operations do not change.

The fetched live lists are a Host's OpenAI key list and its ChatGPT plan list behind [`/v1/model-list`](inspection.md#public-session-activity); the ChatGPT device sign-in uses the selected catalog's OpenAI IDs because its backend publishes no list.
A live list supplies model IDs only: context windows and efforts always come from the selected catalog.
The Host refreshes the models.dev fact catalog and saves it across Host runs.
Host Session configuration admission uses operation-scoped selected facts for effort support and known-window bounds; successful refreshes affect later configuration admissions, not existing Session settings or frozen Operations.
Each new model Operation freezes the selected catalog's effective context window on its own row (D238).
Historical compaction escalation reads only that frozen value, so a refresh between admission, overflow settlement and successor admission cannot change the failed Operation's deeper floor or make the two decisions disagree.
Host admission uses its selected facts for omitted settings and validates explicit choices against them.
There is no model-list command.
Help needs no Host or credentials.
Clients do not read credentials for peer configuration.
Persisted model syntax and transport encoding remain independent of the compiled list, so inspection, original-request recovery and existing Session work preserve exact saved bindings.


## Required evidence

### Interface and owner checks

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| [Mutation presentation](#public-operations) and canonical envelope | `canonical-failure-integration`, modes `producers`, `committed`, `interactive`, `presentMutationReply` tests | Negatives fail at exact assertion, not setup. PTYs use one unrenewed ten-second exit deadline. No macOS, power-loss or aggregate claim |
| [Caller capture and recovery](#caller-capture-and-recovery) | `human_cli_integration.py` | Uncertain Bash effect never replayed |
| Attached CLI creation | `cli_args.zig` parent grammar, `configure_input.zig` parent preference/read dependencies, `client.zig` parent capture through native ingress, `cli.zig` attached start receipt, native `configure parent` Store tests and `attached_creation_cases.py` | Omitted compactAt uses the inherited parent provider and resolved model; no parent preflight read |
| Immutable creation receipts | Configure and creating-Message admission and replay tests; `start_receipt_cases.py` through `human_cli_integration.py start-receipt` | Creation answer and replay retain revision one after a later configure and restart; addressed configure and ordinary sends omit creation configuration. Exercise bounded answer retrieval against large history and verify it does not read a Full report. |
| [Saved defaults](#store-selection-and-defaults) | `'preference edits'`, `human_cli_integration.py` | Not credential, launch, Mac or power-loss |
| [One ChatGPT sign-in, last login wins](#store-selection-and-defaults) | `preferences.zig` `'replaces the other sign-in to its account'` (every saved provider, login and pin) and `'sign-in screen's save keeps the model'`; `cli.zig` `'auth status says each ChatGPT way in'` (every pair of readinesses), `'default receipt'` and `'auth login reads its provider'`; `chatgpt_login_integration.py` | Synthetic issuer only; no live device-code or browser sign-in |
| [One logout ends both ChatGPT logins](#store-selection-and-defaults) (Divyansh chose this on 2026-11-13) | `cli.zig` `'logout says how it left each ChatGPT login'` (every pair of the five local states with the revocation confirmed, and unconfirmed for each state holding a browser sign-in (said on stdout, exit 0), and a credential path Rui cannot resolve on either side alone and on both: stdout, stderr and exit written by hand); `chatgpt_plan_login.zig` `'logout ends the device-code sign-in in each state'` (real files: absent, already signed out, ready, refresh pending and unreadable, beside an absent or unreadable browser record); `codex_credential_policy.zig` `'signing out keeps the account'` (a device-code record signs out and round-trips without a client id); `chatgpt_login_integration.py`: both logins ended, status reads not signed in and a Host serving both routes refuses each, nothing left, only the device-code login, an unconfirmed revocation said on stdout with exit 0, and a relative `RUI_CHATGPT_CREDENTIAL_FILE` or `RUI_CODEX_CREDENTIAL_FILE` still ending the other login and exiting 1. Mutations that must fail: leaving the device-code record usable, exiting 0 when one login could not be ended, and a path failure ending the command before the other login | Synthetic issuer only. The device-code token is removed locally, never revoked remotely. Failed local reads are unit-tested, not driven through the CLI |
| Saved permission defaults and app settings | `preferences.zig` tests `saved permissions` and `new Session permissions`, `Overview.zig` `empty Session creation reads saved permissions even with explicit selectors`, `app_settings.zig` `App settings`, and `human_cli_integration.py` preference edits | Versions 1–3 remain readable; version 4 round trips ask/bypass with and without effort; absent/saved/explicit precedence covers both modes, fully named selectors, parent authority and addressed updates. The settings row renders at both widths and saves both choices through `preferences.update`. |
| Preference publication faults | `preference-policy-integration`, `zig test -lc src/preferences.zig --test-filter 'directory sync'` | Linux and macOS in `check`. No crash or power-loss durability |
| Provider selection, credential status | `'installed local credential status'` | Selection does not prove remote acceptance |
| Login chooser, keys and SIGINT | `'login owner'`, `codex_token_wire` tests, `human_cli_integration.py` | Ordinary terminal line input handles echo, erase and signals before App opens. Exact single-letter choices, EOF, invalid lines and overflow keep their caller outcomes; the chooser changes no termios. Hidden API-key input still restores its modes and wipes secrets. Full synthetic exchange and Mac PTY remain required |
| Masked login signal installation | `login-signal-integration` | Linux only. Unfixed owner must fail |
| [Session listing](#session-listing) | `session_list_integration.py`, `session_list_facts_integration.py`, `client.zig` and `protocol_reply.zig` `'Session list'`, `store/tests/` `'a list row carries its Session's Label, times, first Message, work and peers'` and `'Session list capture and cursor storage stay page bounded'`, `store/sqlite_tests/` `'a list row reads the same steps however long its Session's history'`. `session_list_facts_integration.py` fails a later page and requires a nonzero exit with nothing on stdout. `protocol.SessionRow.budget_bytes` fails the build when a worst-case row exceeds 32 KiB | Interrupted delivery and Mac footprint unqualified |

### CLI refusal and exit contract

The CLI derives exit status from admission certainty and the catalog remedy, not the rejection code alone:

| Exit | Caller action |
| --- | --- |
| 0 | Done. |
| 1 | Failed for a cause not classified above; stderr names it. Treat it as unknown: do not assume the request was or was not sent unless stderr says so. |
| 2 | Invalid fresh invocation; nothing was sent. Fix the invocation. |
| 3 | Rui answered with a saved refusal. Correct the request; a resend needs a new key. |
| 4 | Admission unconfirmed. Run `rui request recover HANDLE` (or the printed explicit-record recovery); never resubmit with a new key. |
| 5 | Retry the same request unchanged later (Host busy or result not ready). |
| 6 | Repair the environment, then retry unchanged (known stopped/unreachable Host, sign-in required or locked Store). |

An error enters 2-6 only once its cause is mapped; every other failure stays exit 1 until it is.

Uncertainty takes precedence over remedy: a busy-looking mutation response without a confirmed admission remains exit 4, not 5.
Multiple outcomes, including `session stop --all`, aggregate in cautious order **4 > 1 > 6 > 5 > 3 > 2 > 0**, never numeric maximum or first failure.
A nonzero exit may follow acceptance; it does not authorize a new identity.

Focused proof: `caller_error.zig` saved-rejection goldens and exhaustive protocol-tag coverage; `caller_exit.zig` certainty/remedy and all-pairs aggregation tests; `cli.zig` saved-reply and uncertainty recovery goldens.
`human_cli_integration.py`, `peer_integration.py` and `admission_integration.sh` assert caller codes and statuses at the process boundary; integration suites require a non-root user.
A fresh unsupported permission mode exits 2 before capture; a wire-created capture or saved replay reaches the Host rejection path and exits 3.
Do not substitute current validators or live accepted sets for saved replay facts.
Neither HTTP statuses nor stdout JSON change.
