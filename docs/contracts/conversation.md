# Conversation, settings, and skills

[Architecture](../../ARCHITECTURE.md) owns shared guarantees, terminology, and the source map.
[Verification](../../VERIFICATION.md) owns global evidence rules and gates.

## Accepted contract

### Conversation and current settings

#### Conversation entries and pending messages

**Conversation** is the immutable ordered history of User text, assistant text, Tool Calls, Tool Results and System Instructions.
Each entry records its exact causal source and applicable Turn, except immediately appended catalog-origin System Instructions, which have no Turn.
No edit, deletion or compaction rewrites history.
An admitted User Message and its Conversation entry are distinct: **projection** means appending the admitted message to this history.
Admission can precede projection, as the pending-message rules below specify.

Messages are immutable admissions ordered within their Session.
A background Action’s final input uses this same queue, with Host-recorded Action provenance and a reference to its sole Resolution.
Session stop wins over its selected background Actions: their final stopped Resolutions remain recorded exactly once, but are not admitted as input and start no Turn. A final input admitted before the stop remains admitted; ordinary stop exclusion governs any unselected input.
An unsettled owed stop from an attached parent already has stop authority, before the child’s `session_stop` row is recorded. The same stopped predicate governs Action eligibility, final input admission, pending input selection and binding, and Tool Call continuation. It excludes person, peer and Action input at that boundary without changing an in-flight request.
Host death ends an unresolved background Action with an ordinary final Resolution, delivered exactly once through this queue unless a saved stop suppresses its source. Execution is never resumed or retried.
An admission waiting for processing has no result-producing Turn binding.
When no Turn is active, core takes the queued admission-order prefix to begin a Turn; admission of new input may perform that transition in the same transaction.
The oldest selected message initiates the Turn.
During active work, later admissions wait for its next input boundary without changing Conversation or a frozen model request.

At an input boundary, core selects all eligible pending messages through the observed admission cutoff.
One transaction:

1. Rechecks eligibility, stop authority and the parent Turn.
2. Binds the selected prefix to that Turn and appends its Conversation entries.
3. Admits the next assistant-response model Operation and its manifest.

Late selection cannot overwrite a saved stop.
Rollback commits none of these changes; input beyond the cutoff stays queued.
Each selected message receives that Turn's final text, schema-validated value or typed failure.
Its binding is final, with no automatic requeue.
Stop or cancellation may instead exclude unselected input and supply cancellation through the controlling fact, without inventing a Turn.

**Queue invariant:** eligible queued input or a completely settled Tool Call group awaiting continuation makes a resumable Session runnable.
No additional message is needed.
Eligible input is admitted, unselected and not excluded by stop or cancellation.
Ordinary continuation and effect-settlement preconditions still apply.

Core discovers work from committed facts after admission, input boundaries, terminal settlement, prerequisite changes and restart.
Lost notifications cannot lose work.
Eligible candidates receive eventual admission under sustained competition according to [capacity and selection progress](resources.md#capacity-and-selection-progress).
A finite workload drains when prerequisites become satisfied and admitted lifecycles finish and release capacity.
There is no public cross-Session winner order or individual wall-clock wait bound.

Unavailable capacity retains work without execution resources or spinning.
A blocked prerequisite leaves input queued.
An admitted Operation failure settles selected input through its Turn; a required canonical failure follows the shutdown boundary.
Runnable state is derived, not stored as a Session phase, wake receipt or per-Session worker.

Compaction uses already-applied context and leaves pending messages alone.
No model-created conversational Input Request exists; permission decisions are separate control facts, not messages.
Successful settlement requires no pending applicable message, actionable permission, unresolved Operation or admitted effect, and atomically releases occupancy.

#### Selecting current settings

A **Session Context Revision** records persistent configuration from sparse caller updates.
Its storage representation is private.
It includes provider/model binding, instructions, Tool Catalog, context policy, reasoning defaults, optional output schema, Permission Mode, default output limits and the Session Label.

The revision does not give every setting the same application boundary:

| Setting | Selection boundary |
| --- | --- |
| Model inputs | Model Operation admission. |
| Permission Mode | Child Action admission, when core authorizes the action. |
| Resource limits | The owning execution or resource scope. |
| Host settings | Host startup, outside Session configuration. |
| Label | Presentation only. It takes effect at commit and no Operation freezes it. |

No separate settings store or applied-state machinery is required.
Session identity, Workspace/access scope and provider binding are fixed under [configuration admission](admission.md#naming-and-configuring-a-session); other supported settings are mutable.
Core validates updates atomically.
The adapter must establish continuation compatibility for the exact frozen Operation without changing Conversation membership.
Revisions do not add provider capabilities.

Defaults apply only when establishing a Session:

| Field | Initially omitted | Explicit value | Later omitted |
| --- | --- | --- | --- |
| Instructions | Empty text | `instructions: ""` selects empty text | Preserve existing value |
| Tools | Bash only | `tools: []` offers no tools | Preserve existing value |
| Permission Mode | `bypass` | `ask` or `bypass` | Preserve existing value |
| Output Schema | Text answers | `outputSchema: null` clears the schema | Preserve existing value |
| Label | No Label | `label: null` clears the Label | Preserve existing value |

Omission never clears a field.
Settings are plain data captured at each configure invocation, before later caller mutation.
Each Session evolves independently; sharing a settings object creates no shared configuration entity.

Tool names remain exactly as supplied by MCP servers, without an inferred server namespace (D120).
At Host startup, an unreachable server keeps its saved tool copies; a configured server with no records contributes no tools (D147).
When a create or update spec names a tool absent from the catalog, admission refuses it as `mcp_server_unavailable` if any configured MCP server contributes no tools, otherwise `unknown_tool`.
The refusal's advisory `message` names the first unknown tool in canonical tool-name order for either code (D241).
This is deliberately not an ownership claim: when servers are empty, it lists every empty server that may provide the tool.
The same catalog decision applies to a creating Message and `start_agent`; the latter returns a failed tool result naming `spec.tools`, without starting a Session.
Known tools, including saved copies of an unreachable server's tools, remain admissible subject to the existing provider and child-narrowing rules.
Only the rejection code is durable; direct replies derive the advisory message from the current Host's catalog and launch configuration, including on replay, with no extra Store read or format change.
Other request refusals have a null advisory message.
An admitted MCP call that cannot reach its server continues to return `mcp_server_unavailable` as a tool result (A-D116).

The CLI spells a Label `--label TEXT` (the Session's name or title, shown in lists and chat info) on `session start` and `session configure`, and clears it with `--label ""`: the empty string is the one spelling that can never be a Label.
A Session can label itself from Bash with `--store "$RUI_STORE" --session "$RUI_ADDRESS"`, and its collaboration context names that command so a model asked to rename its Session finds it.
Every Label change is a revision like any other configuration change.
A Label-only revision adds no Conversation entry and changes no model input.
Configuration carries no sender, so any client that can reach the Store may relabel any Session, as it may already reconfigure it.

Codex **Reasoning Effort** is an explicitly stated, nullable persistent Session setting (D111).
Its closed grammar is `none`, `low`, `medium`, `high`, `xhigh` and `max`.
For a catalog-listed model, configuration accepts an explicit value only when its exact entry advertises it; an unlisted model passes any value in Rui's closed grammar through (D229).
Unsupported values reject the whole update.
`none` is a literal effort, not a reset; like every effort word, it is accepted when the catalog lists it or the model is unlisted.
Catalog-only values such as `ultra` do not expand Rui's grammar or trigger a fallback.
Catalog support is source metadata, not account entitlement or live backend qualification.

The CLI and TUI choose a supported saved effort, otherwise `low` when supported, otherwise the model's lowest listed effort, otherwise explicit null; the Host never fills effort from the catalog.
The catalog has no default effort.
For an unlisted exact binding, the client uses its saved effort or product default, and Rui passes any explicit effort in its closed grammar through (D229).
An explicit null effort tells Rui to omit `reasoning` and leave the provider's effective effort unspecified.
This preserves exact-model syntax without guessing capabilities from model families.

A listed model with effort levels takes one of those values; explicit `null` is accepted only for an unlisted model or a catalog entry with no effort levels.
On an existing Session, omission preserves the saved effort and an accepted explicit `null` leaves provider effort unspecified, without a catalog fallback.
Configuration validates the effective requested-or-retained effort against the effective requested-or-current model, including null effort on a model revision.
The pinned `openai-responses/2` codec cannot encode a boundary back to unspecified effort, so clearing an assigned value rejects atomically as `unsupported_reasoning_effort`; a client reset sends a concrete supported effort instead (D165).
The CLI resolves `--reasoning-effort default` on the client to the client's product effort choice or explicit null; `--reasoning-effort VALUE` selects a value for `session configure` and initial `session start`; chat info’s Effort field submits the equivalent typed edit.
Current inspection reports the effective `reasoning_effort` and saved nullable `reasoning_effort_override`; an explicit saved value wins.
For an admitted pre-D111 Session with null settings, the configuration owner carries forward its latest Operation's frozen effort, so continuation never clears that historical value; it does not infer a catalog or product default.
Fresh explicit-null specs have no earlier concrete effort and remain unspecified.
Each model Operation, including compaction and continuation, freezes the resolved effort, its immutable configured-choice source, its previous same-model admitted effective effort and nullable override, and whether its own pinned request actually emits an effort update at admission.
Replacement Attempts and reopened historical views emit that stored value without consulting later Session settings or catalog policy.
Persisted values outside the closed grammar are corruption.
There is no per-Message override, automatic effort downgrade or model substitution.

New requests select one committed revision and resolve settings at or before it.
No Turn-wide configuration copy, temporary override layer, cross-call lock or historical revision precondition exists.
Configuration and subsequent messages can interleave with other clients; later message failure does not roll back configuration.

Queued messages do not capture model settings at message admission.
At the next assistant-response input boundary, selected messages use the effective model context selected for that request.
For example, while a request is active, admit “review this code,” then configure “focus on security”: if that configuration commits before the next request's selection boundary, the queued review uses it.
A configuration committed after that boundary affects later requests; it cannot alter the admitted Operation or its replacement Attempts.
Instruction updates remain ordered canonical Conversation facts under the rule below.
This model-input boundary does not define when action permission policy changes take effect; authorization follows its own contract.

#### Skills

A **Skill Catalog** is a Session's sorted list of skill names, descriptions and absolute `SKILL.md` paths.
The shared Host capture owner discovers only `<repository>/.agents/skills` and the Host user's `~/.agents/skills` before creating a Session, including direct API, initial Message and `start_agent` creation.
The repository is the nearest ancestor with a `.git` directory or worktree `.git` file; outside a repository, the Session Workspace is the repository root for discovery.
Only direct child directories containing a valid `SKILL.md` are candidates, including symlinks; broken paths and missing roots are absent, while other root/file I/O failures fail the whole capture.
A valid repository skill wins a same-name home skill.
Within each root, the lexically smallest valid candidate directory name in bytewise order wins a repeated declared name.
No `.claude` roots, marketplace discovery, installation or package machinery participates.

Pinned LibYAML validates the complete frontmatter document, including quoted, literal and folded scalars.
Required `name` and nonempty Unicode `description` follow the Agent Skills format, except that overlong descriptions remain discoverable.
The declared name, not the directory or symlink spelling, is the catalog and invocation identity.
Catalog descriptions longer than 1,024 Unicode code points are shortened to the first 1,023 followed by `…`, keeping discovery useful without unbounded model metadata.
This changes only catalog metadata; the source file and full invocation content remain unchanged.
Unknown optional/vendor fields are ignored, including `disable-model-invocation` even when true and tool/permission metadata.
Discovery reads no sibling resources and runs no script.
The initial nonempty Catalog appends an immutable catalog-origin System Instruction before any model Operation; an empty Catalog is still captured durably but adds no instruction.
It does not change authored instructions, their content identity, the revision-one baseline or the caller's explicit tool selection.
Normal defaults offer/load `skill` even with no skills; an explicit restricted tool set remains authoritative, and routing hints are conditional on availability.

The model `skill` tool accepts `invoke` with a name or `reload` without one.
A Message invokes skills by naming them in its text: each `/name` word at a word boundary that names a skill in the recipient Session's catalog binds it, once, at its first use, in the order the text names them; any other `/word`, such as `/tmp/x` or `/month`, stays prose.
Every Message door binds the same way, through one Host step (`session_skills.bind`) before its one Store transaction: a client's `message` request, a peer Session's, `message_agent`, `start_agent` (against the new Session's initial catalog) and an attached child's ending answer.
There is no `skills` wire field, `--skill` option or `/skill` command.
The Message keeps its text once, exactly as typed, and each bound skill is saved after it (`message_skill`) with its complete current raw `SKILL.md` read at send, its content shared with equal bytes.
The Turn that takes the Message projects each skill as its own Conversation entry (kind `skill`) right after the Message's entry, and the model reads it as its own user message there; Ctrl-P recall and Activity read the typed text.
A bound skill that cannot be read refuses a client's or peer's Message (`skill_file_unavailable`, `skill_file_too_large`, `skill_text_invalid`; together a Message's skills hold at most 1 MiB of raw files), fails a `message_agent` or `start_agent` call with nothing sent or started, and leaves an owed child ending, which cannot be refused, delivered with no skills.
Skill entries are host inputs: compaction keeps them verbatim like the Message, a history floor (D217) drops each with its Message's drop unit and counts its bytes there, and their frozen bytes keep later requests' prefixes stable.
Catalog suggestions (`skill_suggestions`) are bounded metadata-only reads with copied query scope, not a frontend filesystem reader or persistent active-skill registry.
Invocation reads the selected advertised absolute path anew, returning the complete raw UTF-8 `SKILL.md`, including frontmatter and trailing bytes, with its absolute path.
The result is ordinary immutable conversation content, with no added authority, tools or permissions.
Sibling resources remain accessible through the Session's existing tools and permission rules.
An invocation result is not an active skill, retained body registry or protected instruction.

User `/reload-skills` and native `session configure --reload-skills` rescan both roots without admitting a Message, changing the configuration revision or starting model work.
The model tool's reload settles its ordinary Tool Result in the existing Turn.
Both compare the captured candidate against the latest durable Session Catalog inside the settlement transaction, updating metadata and appending only added, removed and changed catalog entries as one new ordinary System Instruction.
Name, description and winning absolute path determine a change; body-only edits are a no-op reload but a later fresh invocation reads their new bytes.
No-change reload acknowledges without a catalog instruction.
Failed scans preserve the previous Catalog, never fabricate removals, and typed native failures retain their diagnostic as an ordinary keyed command outcome.
`request read-result` can read this captured refusal or reload acknowledgement without reopening files.

File capture happens outside the Store writer; captured invocation/result bytes, catalog metadata and any delta instruction commit atomically with their originating command or bound tool settlement.
Matching keyed replay returns its saved outcome before filesystem capture; already-admitted model Operations and replacement Attempts use their frozen history, never a rescan.
Catalog instructions have the same immutable chronology, retry and compaction rules as other System Instructions.
There is no active-skill state, body pinning, retention exception, reinjection or baseline rewriting.

Bounds fail explicitly rather than truncating semantic input: `SKILL.md` is at most 1 MiB, YAML frontmatter 64 KiB, each root 4096 direct children, the winning Catalog 4096 entries and encoded metadata 64 MiB.
Malformed metadata is not a valid candidate, but I/O, UTF-8 path and resource-limit failures abort discovery.
Per-candidate raw/parser scratch is reclaimed independently of request/result metadata; shadowed home bodies do not accumulate in the capture arena.
Canonical metadata must be public and each nonzero snapshot must have its exact same-position ordinary System Instruction; missing, mismatched or private required provenance fences rather than repairing history.
Only the legitimate empty initial snapshot uses position zero without an instruction.

#### Recording and rendering instruction updates

Every successfully admitted explicit instruction update appends an immutable System Instruction to the canonical Conversation, including intermediate reversals and fresh equal values: A→B→A records B and the second A; A→A is an update.
Matching request replay adds nothing; omitting instructions creates no update.
Identical bytes may share content storage without collapsing distinct entries.

At model Operation admission, core freezes the canonical historical boundary and effective instructions selected for that Operation.
The provider adapter owns provider- and model-specific projection of those immutable facts.
It may append one wire block per entry, coalesce or lower entries, or use another supported representation, provided the resulting request preserves effective instruction authority and canonical history remains unchanged.
No universal wire-block count or placement is a core guarantee.

Commit each configuration revision and its explicit instruction entry atomically.
Rollback appends neither.
Operation admission and replay derive from canonical originating-update references and the initial baseline, including compaction-covered entries, not text equality or a separate queue/applied flag/receipt.
Already-admitted Operations and replacement Attempts retain their frozen historical view; later configuration cannot rewrite it.

With unchanged adapter rules, reconstruction produces equivalent provider input.
A deliberate adapter-rule change may alter provider rendering from the same canonical facts without changing their authority, the Operation boundary or Conversation.
Adapters should preserve stable provider prefixes where supported, but provider cache layout does not redefine canonical history.

Model-visible time/date/timezone/Workspace binds the adapter's immutable instruction rendering for the admitted Operation; tool observations belong to results.
No automatic polling/clock refresh or Turn-environment reconstruction on retry.

#### Text and structured answers

An optional persistent **Output Schema** selects a model-generated structured Final Answer; absence selects text.
The producing request freezes it.
The adapter translates to a supported provider mechanism and validates response/schema in the bounded validation path; callers receive that value without a second interpretation.
Unsupported schemas, refusal, incomplete generation and invalid output fail explicitly.
No prose conversion, repair call, per-caller schema or reinterpretation under later settings is permitted.


## Required evidence


### Skills

`skills-integration` uses an isolated Workspace and HOME and a deterministic loopback model endpoint which records incoming bytes before replying.
It exercises Host-owned Configure and initial-Message creation, default and explicitly restricted tools, full raw invocation/path, idle no-op and metadata reload, keyed replay after file deletion and process restart, bound model invocation and child `start_agent` discovery.
The fixture uses native public readers and actual provider inputs, not direct Store edits or terminal excerpts.
Mismatched repository symlinks and HOME directory aliases retain their declared names through creation, invocation, reload and replay.

`zig build yaml-linux-compile` compiles all pinned libyaml sources as strict C99 against Linux glibc headers for x86-64 and ARM64 without linking or executing a Host.
It reuses `configureYaml`, whose POSIX feature exposure is scoped to the dependency's C sources; removing it must fail at libyaml's `strdup` declaration, not witness setup.
The ordinary Linux CI builds retain the same dependency compile boundary; this focused target does not add work to an ordinary build.

Focused `skills ` tests cover real YAML scalars/ignored nested metadata, repository-over-home precedence, worktree and non-git roots, symlinks, unreadability, explicit caps, malformed UTF-8 and metadata-only deltas.
Directory-alias regressions cover lowercase, mixed-case, underscore, long and Unicode spellings in both roots, malformed declared-name fallback and bytewise collision winners under reversed creation orders.
External symlink aliases retain canonical paths, deduplicate the same target and produce no catalog delta after an alias-only rename.
Description regressions cover unchanged short and exact-limit ASCII and multibyte scalars, visible Unicode-safe truncation above 1,024 code points, catalog round trips and full unchanged invocation content.
Catalog JSON requires actual string tokens for name, description and path, rejecting numeric/byte-array coercions while preserving escaped Unicode.
A full 4096-entry ordering regression covers the constant-stack heap sorts used by discovery, encoding, decoding and deltas.
The Linux `stack-frames` gate measures the real catalog decode and Configure/creating-Message import paths.
Configure and creating Messages keep their temporary facts at one address in the Store's existing scratch; reload-only scratch stays in its own same-transaction branch.
No skill stack exception or larger scratch allocation is permitted.
A result-arena plus independently reclaiming scratch high-water regression exercises many near-limit project and shadowed home bodies; unsupported native invalid-byte filenames skip only on filesystems that reject their creation.
The actual Ingress tests cover text-free skill custody transfer, fragmented input and invalid text-plus-skill cleanup alongside the existing ordinary text-capture tests.

The Store tests exercise six distinct content imports in child creation, `content_import` and `before_commit` rollback with reopen/retry, same-position/public catalog provenance, empty initial position zero and authenticated peer refusal causality/replay.
Reload fault tests preserve catalog, instruction, position and command-result atomicity through both failure points, then verify same-key replay and no-op behavior after reopen.
Populated format-56/wire-9 and format-58/wire-10 SQLite fixtures upgrade through the production Store and preserve ordinary content; corresponding MySQL migrations run when a live test server is configured.
Archive composition tests retain archive intent on skill refusal and idle reload, unarchive only a fresh admitted invocation, and preserve archive state on keyed replay.
Creation refusal tests cover both Configure and initial Message: a missing Workspace remains `invalid_workspace`, a valid Workspace with inaccessible skills roots remains `skills_unavailable`, and each keyed refusal replays unchanged after repair without allocating a Session or model work.
The adapter lifecycle test checks complete >10,000-byte CRLF/Unicode skill results in saved ordinary content and actual sealed provider input, metadata-only body edits, revision-one/authored-baseline preservation, idle nullable-Turn reports, frozen admitted Operations, serialized history prefixes, memo/cold reconstruction and real reopen after source deletion.
Negative controls revert each boundary fix and must fail its owner assertion or actual Host custody boundary, not fixture setup.
These are synthetic local evidence, not live provider, remote filesystem or power-loss qualification.

#### Parent creation (D178)

Focused `configure parent` Store tests cover inherited Workspace/provider, no task,
child reporting and ending delivery, every widening field, missing/archived parents,
update refusal and idempotent replay. The Host test covers inherited in-memory Bash
environment and replay/refusal isolation. The create path retains the ordinary
four-round budget, including selected catalog facts; run these and the unchanged `start_agent`, Store entry-point
round-budget and Current report dependency-depth tests on SQLite and live MySQL.
Mutating the shared tool narrowing refusal must fail both creation and start_agent.
`MCP parent creation narrows configured intent and saves no derived offer at either door` crosses native creation and `start_agent` with full/subset loaded intent, a reduced parent offer and changed Host tool identities.
It checks unavailable-name refusal independently of the intent ceiling, removal/return through reopen, unchanged parent/child intent and revision snapshots, excluded names staying excluded, and frozen old Operation offers.
Replacing the shared parent intent source with the latest frozen Operation offer fails native creation and the existing unloaded-MCP `start_agent` test.
`openapi` focused tests cover generated examples, including the create-only relation.
