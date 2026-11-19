# Admission and Session configuration

[Architecture](../../ARCHITECTURE.md) owns shared guarantees, terminology, and the source map.
[Verification](../../VERIFICATION.md) owns global evidence rules and gates.

## Accepted contract

### Admission and public requests

#### Names, references, IDs and idempotency keys

| Term | Meaning |
| --- | --- |
| Name | Caller-chosen stable text within a documented scope. A name is not a freely editable display label: changing a name can select different work. |
| Reference | Complete value used to address an object. A Session reference is its exact six-character ID, such as `k7m2qx`, not a live handle or lookup operation. |
| ID | Host-assigned identity of a durable object, such as an Operation ID. Representation and allocation belong to the object's owner. |
| Idempotency key | Identifies a submission across retries so its original committed answer can be recovered. Callers supply a core idempotency key. This does not promise exactly-once external effects. |
| Label | Non-identifying descriptive text. A Session has one optional Label, set through configuration: one non-blank line of 1–100 UTF-8 bytes, validated like a saved Bash description. It is freely editable, never an address, never model input and selects no work. It is distinct from a Name. |

Use these qualified terms consistently; do not use a tracing request ID as an idempotency key or confuse a name with its full reference.

#### Naming and configuring a Session

The Store allocates a Session ID when a valid creation configuration commits.
An ID is exactly six random lowercase characters from `0123456789abcdefghjkmnpqrstvwxyz`, giving 30 bits of entropy.
Allocation uses platform cryptographically secure randomness and an atomic unique insertion inside the configuration transaction, retrying actual collisions.
There is no caller-named creation, prefix, abbreviation, checksum or alias.
The ID is the address and the TUI peer label.
A Session's optional Label is display text only: commands never accept it where an ID is expected, and two Sessions may share one.
Possessing or guessing an ID grants no access.
The Store records each Session's creation time (`created_at`, Host Unix seconds) in the creating configuration transaction.

An omitted CLI `--session` captures creation intent with an empty Session field.
Accepted creation returns the allocated ID; matching idempotent replay returns that same ID without allocation.
A supplied `--session ID` selects only an existing canonical ID.
Unknown IDs reject as `unknown_session`, presented as `no session k7m2qx in this Store`, without creating a Session or admitting Message work.
Noncanonical references, including old UUID and NUL-bearing references, reject rather than normalize.

Configure, creating Messages, `start_agent` and connect-time presets use one plain camelCase agent spec: `workspace`, `provider`, `model`, `instructions`, `tools`, `loadedTools`, `permissionMode`, `outputSchema`, `compactAt`, `outputReservation`, `effort` and `label`.
An absent member keeps the current value or creation default; `null` clears a nullable setting; a direct value sets it.
Token policies are JSON integers and tool lists normalize into byte order with no duplicate names.
`instructions` is a text string; `outputSchema` is a JSON object or `null`, as in the shipped `start_agent` and presets.
Ingress streams instructions and schema objects to sealed content files rather than retaining their bodies in metadata; schemas have the content bound, not the smaller metadata bound.
Every schema object is a schema, including an object with keys such as `state`, `value`, `bytes` or `sha256`; no object is interpreted as a content reference.
Only the parser's internal metadata uses an empty array as the out-of-band schema-custody marker; an array is not a schema object and is refused on the wire.
The CLI refuses a malformed schema file before capture publication, since malformed JSON cannot be an object in the plain spec.
Schema bytes are compact JSON with normalized string escapes, preserving member order and number spelling as the shipped object serializer did; configuration identity hashes these parsed bytes, not the request's whitespace or spelling of string escapes.
A creation configuration requires an exact nonempty model, explicit effort, a token-count `compactAt`, a tools list and Permission Mode (D104, D111, D113).
A missing required field is a missing-field request error; an empty tools list means no tools and has no Host default.
The agent spec also accepts instructions, output schema and label; provider defaults to the Host's single served provider, and a Host serving several has no default, so a creation must name one (D133, D221).
Workspace is required when tools includes Bash and is unused for execution otherwise.
A supplied Workspace is checked like any other, and a spec without Bash that omits it saves `/`, because the Store's Workspace column is never empty.
Enabling Bash later runs it in the saved Workspace, which a later configure cannot change.
Creation atomically establishes Session, baseline, Workspace bookkeeping, access scope and request answer.
The CLI and TUI send their own explicit creation defaults: Bash and web search, `bypass`, a supported saved effort or the product's effort choice, and the provider's compactAt default as described under [Supported model IDs](cli.md#supported-model-ids).
Addressed configure preserves every omitted setting; provider and Workspace remain immutable, while the model may change within the provider (D192).
A creating spec may also name `parent`, a Session ID relation, never a revisioned setting (D178).
The child inherits that Session's Workspace and provider and may only narrow its configured tool names and Permission Mode, through the same admission owner as `start_agent` (D122, D140).
Naming provider or Workspace, even equal values, is refused, as is a wider tool set or bypass under an asking parent; refusals name the field and never silently intersect the spec.
Missing parents and parents with an archive intent are refused as `unknown_session`; an update naming `parent` is refused as `parent_on_update`.
A native configure creation admits no task Message. Child approval forwarding and ending Messages use the saved parent relation as for attached agents.
`parent` participates in the creation request digest only when present, retaining every earlier configuration digest and the existing Store format.


A creation-only `preset` seeds configure from a connect-time spec: supplied values or nulls override it, omissions inherit it, and resolved answers bind the resolved configuration for idempotent replay (D22).
Preset lookup/update rejections instead bind the original request, including the preset name, and replay that saved rejection even if the Host can later resolve the preset.

Later configurations preserve omitted provider/model values and accept explicit equal values.
A different provider rejects the whole update, without a revision or partial changes; unknown providers reject without fallback.
A model change is an ordinary revision and writes a `session_changed` row for `model`, before, during or after work.
The Session ID and attached children carry on.
Validate retained or supplied effort against the new model only when the catalog lists it; an unlisted model passes any supported effort word through (D229/D137).
The retained or supplied compactAt must fit the new model's known window.

To use another provider, create a new Session.
V1 has no fork, history transfer or cross-provider handoff.
Operations still resolve their frozen settings revisions, and output retains its producing Operation's provenance.

Other supplied mutable fields apply in admission order; omitted fields remain unchanged.
Enforce immutable Workspace/access constraints and supported Core values.
An accepted fresh configuration records a revision even for equal values; matching command replay records none.
Adapter-owned continuation compatibility is evaluated for the frozen model Operation, independently of the binding admission rule.

Incomplete initialization and messages to unknown Session references reject without partial Sessions.
Message admission validates the command and immutable content without provider I/O; acceptance guarantees valid canonical Conversation input if the message is later selected.
Configuration enqueues no message; any previously queued input remains governed by the queue invariant when changed settings make it resumable.

No separate creation, reservation, attachment or must-be-new operation is selected.

#### Recovering a submission after a lost reply

A **core idempotency key** is a caller-provided value binding one state-changing caller command to core, complete inputs and original committed admission answer: acceptance or definite rejection.
Message acceptance identifies one immutable admission to the Session queue; it need not identify a Turn yet.
The [processing boundary](conversation.md#conversation-entries-and-pending-messages) establishes the message's result binding once.
Distinct messages processed in one Turn share its result.

Every state-changing caller command to core requires a stable core idempotency key: configuration, message submission, Session stop, Session archive, Permission Decision and exact Model Interruption.
Once committed, its inputs, admission-time selection and original admission answer never change; retries recover that decision rather than select new work.
This gives callers one lost-reply recovery rule across intervening work and crashes.
Reads and waits observe current facts without retained command identities.
Internal driving and effect evidence retain their existing Operation/Attempt authority; this rule does not authorize replay of uncertain effects.

All callers share one Store-wide core idempotency-key domain.
Atomically bind the key, target, operation kind, complete canonical inputs and original acceptance/definite rejection with the mutation.
Target and kind are bound inputs, not lookup scope; changing either or the inputs conflicts.
Recovery requires authorization; a key grants no access.

Core requires an exact UTF-8 string of at most 128 bytes and does not interpret or validate UUID syntax.
An empty supplied string remains an identity, not a request to generate one.
Client helpers default to lowercase, hyphenated UUIDv4 text (36 ASCII bytes), generated with platform cryptographically secure randomness.
Core enforces bindings rather than assuming tokens are unique; separate clients choosing the same string share one identity.

Recover matching admission answers before checking current conditions; changed inputs conflict without replacement.
Every new command needs a fresh key, even with equal inputs.
V1 accepts securely generated UUIDv4’s probabilistic uniqueness: core detects mismatched reuse but cannot distinguish a retry from a new command with the same key and inputs.

Retrying old configuration cannot revert later settings; retrying a message recovers the same admission, without enqueueing it again, changing an established result binding or reviving excluded input.
An unbound admission remains the same queued work until core takes it for processing.
A rejection before Session initialization remains rejected afterward.

Typed results distinguish committed acceptance/rejection, proven key conflict, and failure to establish a trustworthy answer.
Conflict preserves the original binding.
Invocation/storage failure, malformed envelopes without usable identity and failed commits cannot claim a saved rejection or answer.

Acknowledgment follows durable commit, without provider dispatch or final-answer delay.
Configuration completes at admission.
Message acceptance completes queue admission; processing and the final result may remain pending.

Observation by core idempotency key returns one of these results:

| Result | Meaning |
| --- | --- |
| Absent | No authoritative answer is recorded. |
| Original rejection | The committed rejection, even if current conditions now permit the command. |
| Original acceptance | The committed acceptance plus current progress for that command. Messages expose Host-derived `state`, admission time, their `binding`/result or exclusion, pending work and optional recovery; stops follow their saved selection. |

Progress never rewrites the admission answer.
Scalar observations suffice; batching is optional, and reads or waits cannot require every notification.

Before transmission, direct clients durably retain the destination Store, operation, exact key and captured inputs.
Immutable retained content references may replace inline payloads; mutable paths or digests alone cannot.
Retry helpers reuse that record, not a new token.
Recovery refuses a record from another wire version before returning a transmissible captured owner, names the incompatibility, and leaves the original record and key available to a compatible build.
In-memory retention supports recovery only while the client survives.
Recover an uncertain reply by identity, not by guessing from content.

Direct caller capture enforces the decoded per-value content boundary while streaming, before publication or transmission.
For an ordered Message, capture reads each local image from one acquired regular-file descriptor, validates it, and seals its bytes with the ordered text parts. The published record contains the exact serialized request, not mutable image paths; recovery reconstructs its identity from those saved bytes. A text-only Message retains the scalar text wire representation.
A stable OS-held lock per record owns capture, recovery and no-overwrite publication.
Revisiting that record removes its prior incomplete temporary under the lock; killing a writer releases the lock.
The empty lock file remains to preserve one lock inode across openers.
This does not reclaim captures at abandoned distinct record paths or legacy PID-named temporaries.
A complete published record survives a subsequent directory-sync failure and remains available for recovery, but that uncertain publication returns no transmissible captured owner and cannot automatically send.

The client owns command-specific configuration, Message and Permission Decision capture with a closed choice between a caller-selected generated-record directory and an explicit record/key (including an empty key).
Capture pins a read-only reader of its temporary inode before publication, retains that reader across the final flush/rename/directory sync, and transfers its owned record handle only after durable publication; it never reselects the public pathname during that handoff.
The CLI announces the saved identity before transmitting the original streamed record bytes; announcement failure leaves the record recoverable without sending.
Send failure retains the handle's bounded identity for the caller.
Fresh generated recovery opens one record, validates its complete syntax and consumed binding fields, then transmits that same reader's original bytes, never current preferences or mutable source files.
This binding reader is not the Host's ordered ingress grammar or domain validator: configuration content stays opaque to Client, and Store still decides admission.
An explicit repeat send starts at byte zero even after a lost reply.
Closing the handle releases its descriptor, not its saved name; callers close before later observation/waiting.
This is one reader per active capture/recovery, fixed content windows and bounded metadata, not a payload tree or request registry.
Generated recovery decodes only configuration, Message and Permission Decision records; Session stop and Model Interruption keep their explicit record/retry routes.

Client also owns typed decoding of these six mutation replies before callers interpret admission.
One fixed-storage parse validates the complete bounded envelope, consumed-field duplicates, operation/status/replay semantics, echoed Session and control target, and Message decoded length/domain-separated digest and queue admission against the pinned capture. For compound input the reply identifies the ordered canonical parts manifest by its encoded length and domain-separated digest, including validated image metadata. An accepted parts input also names its Message admission as owner; a rejected submission has no owner and returns only its submitted-input identity.
Invalid or mismatched replies are unconfirmed invocations, not durable rejection or proof of noncommit; retain the original recovery key.
A canonical invocation failure retains its independent Host-fence authority.
Typed facts, original request identity/target and bounded invocation status/type/code are owned values that survive capture closure and response-buffer reuse.
CLI renders human and semantic JSON output from this one result, never the raw Host mutation envelope; malformed or mismatched responses expose the typed diagnostic and original request context, not an unvalidated claimed outcome.
Outer member order, whitespace, equivalent escapes and unknown fields are not output authority.
The receive buffer remains necessary for validation; this is no payload copy/cache or memory-savings claim.
Exact domain content and Action argument strings remain unchanged.
CLI owns display and workflow, including its existing recoverable-error behavior and fatal canonical-error terminal cleanup.
A later worker must delegate to this same operation decoder when integrated, retaining its own custody/lifecycle.
Listing/following local handles uses a metadata-only identity projection that cannot authorize transmission and does not scan historical payloads.

Client owns keyed observation and result decoding for checking **one submitted request**, independently of local capture availability.
Its owned facts validate the queried key and expose the original operation kind and Session; selected Message callers additionally check these against their saved address.
The original admission remains `accepted` even when later work fails or is cancelled.
The Host derives the Message's required `state`; clients retain it rather than derive another lifecycle from metadata.
A terminal Message result takes precedence over Session work; failed/completed work must carry its Turn/Operation/Attempt `binding`, while stop-excluded input has `state:"cancelled"` and a cancelled result without an invented Turn.
The binding remains present after bound work ends; its presence is not a running-state signal.
Supported metadata for CLI consumers is:

| Observation | Supported facts |
| --- | --- |
| Common | Key; absent, accepted or rejected admission; kind, original Session and rejection code when present; CLI `request inspect` adds top-level `as_of`, its Unix seconds at render as a canonical decimal string |
| Configure | Accepted revision and created flag |
| Message | Required Host-derived `state`; accepted input content value and `queue` admission and `admitted_at`; optional `binding` Turn/Operation/Attempt; nonterminal `work` with Session work `state` and nullable `first_action`; optional retained `recovery`; terminal result status/code or answer text reference. Rejected observations carry no input or queue. |
| Session stop | Original selected nullable Turn, admission cutoff and pending/completed semantic completion |
| Model Interruption / Permission Decision | Original Session/Turn/Operation or Action/decision, including retained rejected targets |

**Unchanged observations.**
`observe-command`, `activity-page`, and the Current profile of `inspect-session` accept an optional `since` hint, `<32-hex instance>.<generation>.<6-character Session>`.
Malformed token strings return 400 `invalid_since`.
Every full observation has `delta:"full"` and `since` beside `observation`; `since` is null for absent keys or non-Session targets.
A repeat read can instead return only the version, type, key, `delta:"not_modified"` and its token.
Store owns both unchanged tiers: the opening identity and unchanged commit-generation atomics answer without a holder; otherwise, under the Store holder and before read access, the existing change ring walks backward only through entries after the token.
If that covered history names no change to its Session, the token advances to the current generation without SQLite.
Otherwise the full observation carries the generation captured before its reads.
Foreign, future, uncovered or pre-restart tokens get a full observation.
Tokens are hints, not revisions or durable state, and the token's Session scopes the check; editing one can mislead only its caller.
The shared change-ring recorder expands each written Session through saved `parent_ref` before publishing the generation and commit wakeup.
This includes newly saved attachments, but never a standalone agent's starter.
One bounded indexed read walks at most four upward edges from the at-most-four touched Sessions; a fifth distinct Session uses the ring's existing conservative all-changed fallback.
Each ancestor keeps its own Workspace key. Failed expansion forgets coverage and applies ordinary Store fencing, never an unchanged answer.
Activity, command observations and incremental Session listings consume this same record; Current remains uncached.
Nothing is retained per reader and no Host thread is added.
Each reply reserves its own shape's bound, not the global observation maximum.
A retry becoming past due commits nothing: readers apply `WorkState.asOf`, as Session listing does.
`request inspect` always asks for full facts; it exposes neither a `--since` flag nor the token in its output.
An exhausted, unpinned forward activity page grants the same Session token; the TypeScript follow loop sends it only after consuming all matching items through that page's `end`.
An unchanged activity reply contains only version, type, `delta:"not_modified"`, and `since`; the follower keeps its end cursor and footer and sleeps on its existing schedule.
Unread, pinned, and backward pages grant no token.
Activity pages in `retrying` or `pending` grant no token: a retry deadline can change the footer without a commit, including when the wall clock steps backward.
Current is excluded from unchanged replies: its Host-global execution custody and scratch counters can change without a commit to the inspected Session, and its work also applies the retry clock.
Current validates `since` but always returns `delta:"full",since:null`; the human frontend therefore continues its existing Current reads instead of caching stale execution facts.

One bounded parse validates the entire keyed envelope, consumed duplicates, string-only named statuses/kinds, canonical decimal IDs, content-reference syntax and operation applicability.
An omitted field is distinct from invalid present null; only fields declared nullable, such as selection Turn and `work.first_action`, accept null.
Unknown extensions are syntax-validated and discarded, not retained as a DOM or emitted through ordinary output.
Strings belong to fixed-storage facts; returned string slices borrow that value until it leaves scope, independently of receive-buffer reuse.
Human and semantic JSON render these same facts.
Read failures retain bounded HTTP status/type/code and the queried key; unavailable/failed observation never undoes an earlier admission or proves noncommit.
Successful answer and Action-content reads still stream exact domain bytes through fixed windows; partial read failure cannot claim a complete answer.
Full's closed inventory remains a separate streamed report.
Current and attention snapshot consolidation remain subsequent Client work; [Session-list facts](cli.md#public-operations) preserve real Store snapshot cursors, and explicit unconfigured behavior remains unchanged.
New supported metadata requires an intentional typed contract, not automatic unknown-field passthrough.

Within the mutation envelope, omittable consequential fields accept a typed value when present, never explicit JSON null: null is not absence and cannot bypass invocation/answer exclusivity or operation applicability.
Session-stop `selection.turn` is the exception: it is required but nullable to represent no selected Turn; omission is malformed.
Unknown extension values remain syntax-validated without becoming outcome authority.

Global `request list` enumerates filename-valid generated handles even when their record is unreadable or unsupported.
Session-local `/requests` filters readable supported identities by recorded Store and Session.
Neither listing transmits requests or establishes Host work status.

This provides recoverable admission, not exactly-once effects.
Controls use the same saved-key protocol; their owners retain command-specific validation, target selection and completion semantics.
An original acceptance is immutable even while its completion progresses.
A fresh key requests a fresh decision against current state; it does not override an already-settled target.

Retain authoritative intents, retry bindings and content required for original-answer recovery without independent expiration in V1, including after terminal completion.
Storage exhaustion cannot silently discard recovery history.
This recovery contract assumes committed authoritative history survives; independent database rollback, Store replacement or loss of one owner's history is not ordinary crash recovery.
Detectable missing/corrupt authoritative state must not be treated as fresh work.

#### Example: acceptance and answer arrive separately

A caller submits “Investigate the failing test” with core idempotency key `message-1`.
Core commits acceptance, but the connection closes before the reply arrives.
Resending the same identity and inputs recovers that acceptance and its original work; it does not submit another message.
The final answer may still be pending.
Even after the Session has done newer work, `message-1` remains bound to its original result.
A deliberate second submission uses a new identity.


## Required evidence


### Authority, Session identity and admission

#### Capture, configuration and command identity

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| [Capture, recovery and descriptor bound](cli.md#caller-capture-and-recovery) | `'capture retransmits'`, `'capture publication'`, `'saved request wire mismatch'`, `human_cli_integration.py`, `saved_request_resources.py BASELINE CANDIDATE` | The `fsync` cut is Linux-only and not power loss. The resource fixture needs `/proc` and samples descriptors without asserting the bound |
| Configuration revisions, Message admission and selection | `'start_agent and configure parse the same plain agent spec'`, `'initial Message ingress streams the plain spec'`, `'model revisions'`, `'model switch'`, `'message admissions remain'`, `'runnable discovery'`, `dispatch_integration.py`, `canonical_failure_integration.py` | The shared plain spec covers all table fields, nullable/omitted states, object schemas with canonical digest parity, schema objects larger than metadata, and three streamed creating-Message contents. Sizes are qualification workloads, not request quotas |
| [Loaded tools](execution.md#authorizing-exact-actions) | `store/tests/` `'loaded tools configure'`; loaded-set history and call rejection regressions in `store/sqlite_tests/`; schema 53-to-54 forward migration | Strict subsets require a future `find_tools` catalog entry; visibility tests seed stored subsets |
| [MCP missing tool admission](conversation.md#selecting-current-settings) | `'MCP missing tools'`, `'start_agent narrows configured tool names'`, `'replies the Host renders'`, `'openapi requests parse'`, TypeScript request-error tests; `stack-frames -Dcpu=baseline` | All empty-server combinations, one/multiple empty servers, no servers and all servers with records; saved-copy admission across create/update/creating Message/start_agent; same-key refusal replay, maximum advisory size, and a mutation removing the server check. Native Store cases cover SQLite; live MySQL requires its configured fixture |
| Core key domain, including empty keys | `'core preserves empty keys'` | 128-byte accept and 129-byte reject bounds, recovery-binding retention: none located |


### Submission recovery

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| [Same-key caller recovery](cli.md#caller-capture-and-recovery) | `human_cli_integration.py`, `control_integration.py` | Direct clients only |

| [Label](#naming-and-configuring-a-session) | `store/tests/` `'a Label is configured, replayed, cleared and validated like any setting'`, `cli.zig` `'a Label argument sets, clears or refuses before capture'`. `peer_integration.py`: A labels itself with `session configure --session "$RUI_ADDRESS"` and starts B with `--label`; listing shows both, and B's model requests never carry its Label. `human_cli_integration.py`: chat info’s title shows the Label set by `/rename` | Same idempotency and conflict rules as other settings |
| Creating Message `require_model` | `store/tests/` `'a creating Message with require_model creates nothing without a model'`, `protocol.zig` `'only a creating Message carries require_model, and it binds the digest'` | Low-level `session start` without the condition stays available |
