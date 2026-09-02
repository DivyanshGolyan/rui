# OpenCode SQLite and V2 lessons for OnePage

Research date: 2026-08-25

> **Historical research record.** References below to a transition Ledger, Completion Inbox,
> recovery cursor, or cached semantic projections describe the superseded design. ADR-0019 and
> ADR-0021, published through issues #66 and #69, make normalized SQLite rows the sole recoverable
> semantic authority and use no generic ledger or inbox protocol.

Primary source: `anomalyco/opencode`

Current development revision: [`69aaa22793bcbe0b016ad9cfad22616906766df0`](https://github.com/anomalyco/opencode/tree/69aaa22793bcbe0b016ad9cfad22616906766df0) (`dev`)

V2 revision: [`bcd1769521a0b89fc32db67ed2717668f326bc43`](https://github.com/anomalyco/opencode/tree/bcd1769521a0b89fc32db67ed2717668f326bc43) (`v2`)

## Decision

OpenCode is useful evidence for OnePage's proposed SQLite direction, but not a configuration template.

The parts worth carrying across are:

1. keep application identities and semantic sequencing above SQLite;
2. commit the semantic event, sequence head, read-model changes, and inbox state in one transaction;
3. treat in-memory wakes as hints and recover from persisted cursors;
4. keep pending input distinct from model-visible history;
5. retain explicit write-ahead execution and uncertain-effect semantics above the database;
6. use a relational envelope around typed opaque payloads, normalizing only fields that enforce invariants or support real queries.

OpenCode's `WAL`, `synchronous=NORMAL`, five-second busy wait, roughly 64 MiB SQLite cache, time-sortable text IDs, optional event-payload persistence, and upgrade machinery answer different product constraints. Its shared database and single serialized connection did help expose the better OnePage topology: one host-wide Host Store behind a singleton Storage Owner amortizes SQLite memory across every Session. OnePage pairs that choice with a host lifetime lock, `DELETE`, `EXTRA`, `busy_timeout=0`, bounded memory, immutable consumed Completion evidence, and an always-authoritative semantic transition ledger.

## What “V2” means

OpenCode V2 is a product/runtime rewrite, not “SQLite version 2.” The `v2` branch builds a typed Core in which Protocol owns HTTP operations, Schema owns public types and durable events, and Core owns execution and persistence. Its Session contract specifies durable prompt admission, process-local execution, write-ahead execution claims, tool-call publication before side effects, compaction, replay, and crash recovery ([V2 specification index](https://github.com/anomalyco/opencode/blob/bcd1769521a0b89fc32db67ed2717668f326bc43/specs/v2/README.md#L1-L25), [Session contract](https://github.com/anomalyco/opencode/blob/bcd1769521a0b89fc32db67ed2717668f326bc43/specs/v2/session.md#L1-L48)). The branch exposes an `opencode2` binary, which is further evidence that this is a parallel major implementation rather than a database-format label ([CLI package](https://github.com/anomalyco/opencode/blob/bcd1769521a0b89fc32db67ed2717668f326bc43/packages/cli/package.json#L1-L10)).

The `dev` revision is already partway through that transition: its SQLite schema contains legacy `message`/`part` rows alongside the newer sequenced `session_message`, input, context, and durable-event structures ([current Session schema](https://github.com/anomalyco/opencode/blob/69aaa22793bcbe0b016ad9cfad22616906766df0/packages/core/src/session/sql.ts#L22-L166)). Therefore “OpenCode uses SQLite” and “OpenCode V2 is event sourced” are both true, but describe different layers and a moving migration boundary.

## Physical SQLite design

Both pinned branches open one installation-wide database through Bun's SQLite binding and Drizzle/Effect adapters. The V2 CLI chooses `opencode.db` for normal channels, a channel-specific filename otherwise, and permits `OPENCODE_DB` to override it ([database path selection](https://github.com/anomalyco/opencode/blob/bcd1769521a0b89fc32db67ed2717668f326bc43/packages/cli/src/server-process.ts#L76-L92)). This is not a per-Session database design.

For filesystem SQLite, V2 explicitly applies:

- `journal_mode=WAL`;
- `synchronous=NORMAL`;
- `busy_timeout=5000`;
- `cache_size=-64000`;
- `foreign_keys=ON`;
- one passive WAL checkpoint at startup.

The exact initialization is visible in the database layer ([database configuration](https://github.com/anomalyco/opencode/blob/bcd1769521a0b89fc32db67ed2717668f326bc43/packages/core/src/database/database.ts#L26-L40)). The Bun adapter opens a single native connection and serializes acquisition through a one-permit semaphore ([Bun adapter](https://github.com/anomalyco/opencode/blob/bcd1769521a0b89fc32db67ed2717668f326bc43/packages/core/src/database/sqlite.bun.ts#L17-L102)). V2 also supports an injected Cloudflare Durable Object SQLite client and skips filesystem-only pragmas there, so these settings are explicitly runtime-specific rather than domain invariants ([database abstraction](https://github.com/anomalyco/opencode/blob/bcd1769521a0b89fc32db67ed2717668f326bc43/packages/core/src/database/database.ts#L31-L62), [workerd profile](https://github.com/anomalyco/opencode/blob/bcd1769521a0b89fc32db67ed2717668f326bc43/packages/server/src/workerd.ts#L19-L76)).

This topology explains its choices: multiple Sessions share a service database, readers and writers coexist, and temporary contention is expected. OnePage also shares one database, but only one Host Runtime and one Storage Owner may access it in V1. That stricter topology does not need concurrent-reader WAL behavior or a five-second hidden wait. OpenCode's 64 MiB cache setting remains inapplicable because OnePage derives one explicit SQLite allowance from the total host budget and measures smaller cache profiles independently of the 64 KiB Activation Slot.

No storage checksum, application CRC, or periodic `integrity_check` path was found at either pin. OpenCode schema-encodes values before persistence and decodes them when rebuilding typed state, but it does not claim end-to-end detection of arbitrary bit flips. That supports stating a bounded OnePage fault model instead of retaining a custom WAL merely for its CRC.

## Schema: indexed envelopes around typed JSON

V2 uses relational columns for ownership, ordering, lifecycle, and query keys while retaining structured application payloads as JSON text:

- `event_sequence` holds one aggregate's current sequence and optional replay owner;
- `event` holds an application event ID, aggregate ID, sequence, creation time, versioned type, and JSON data, with uniqueness on `(aggregate_id, seq)`;
- `session_v2` holds Session identity, parent/fork relations, location, counters, lifecycle timestamps, execution-claim state, and resume attempts;
- `session_message` holds an application message ID, Session ID, type, aggregate sequence, timestamps, and JSON message data;
- `session_inbox` holds pending user, synthetic, compaction, and move inputs with delivery mode and enqueue sequence;
- instruction values are content-addressed by SHA-256 in `instruction_blob`, while `instruction_state` stores current and epoch-initial hash maps.

See the [event tables](https://github.com/anomalyco/opencode/blob/bcd1769521a0b89fc32db67ed2717668f326bc43/packages/core/src/event/sql.ts#L4-L25), [Session, message, and inbox tables](https://github.com/anomalyco/opencode/blob/bcd1769521a0b89fc32db67ed2717668f326bc43/packages/core/src/session/sql.ts#L22-L145), and [instruction tables](https://github.com/anomalyco/opencode/blob/bcd1769521a0b89fc32db67ed2717668f326bc43/packages/core/src/session/sql.ts#L147-L176).

This is close to OnePage's proposed relational transition envelope plus canonical payload. It is evidence that SQLite does not force every semantic fact into columns. OnePage can keep a canonical encoded transition in one BLOB and expose only sequence, version, kind, and any proven query/invariant keys relationally.

OpenCode's identities remain application-generated text, not SQLite row IDs. Session IDs sort descending by embedded time; message and event IDs sort ascending and combine time/counter bits with random characters ([identifier algorithm](https://github.com/anomalyco/opencode/blob/bcd1769521a0b89fc32db67ed2717668f326bc43/packages/schema/src/identifier.ts#L1-L29), [message ID](https://github.com/anomalyco/opencode/blob/bcd1769521a0b89fc32db67ed2717668f326bc43/packages/schema/src/session-message.ts#L22-L29)). The transferable point is that domain identity remains independent of SQLite. It does not argue against OnePage's compact random `u64` identities stored as eight-byte BLOBs.

Large tool output is not a general SQLite BLOB facility in OpenCode. Output beyond 2,000 lines or 50 KiB is written under a managed filesystem directory, while bounded content plus the path is retained; those files are eligible for cleanup after seven days ([tool-output policy](https://github.com/anomalyco/opencode/blob/bcd1769521a0b89fc32db67ed2717668f326bc43/packages/core/src/tool-output.ts#L13-L16), [externalization](https://github.com/anomalyco/opencode/blob/bcd1769521a0b89fc32db67ed2717668f326bc43/packages/core/src/tool-output.ts#L65-L129)). This supports separating large content from hot Session rows, but its write path shows no explicit durable-before-reference barrier and its retention policy makes the full output non-authoritative. OnePage should keep its stronger immutable-blob ordering rule.

## Semantic publication and concurrency

The strongest reusable design is OpenCode's publication boundary. For one aggregate, the event bus:

1. takes a keyed in-process mutex;
2. begins an `IMMEDIATE` SQLite transaction;
3. reads the aggregate sequence head;
4. validates replay ownership, exact next-sequence order, and event-ID reuse;
5. runs registered projectors and any operation-specific commit hook;
6. advances the aggregate sequence;
7. optionally inserts the durable event payload;
8. commits before waking subscribers.

The single-event path is implemented [here](https://github.com/anomalyco/opencode/blob/bcd1769521a0b89fc32db67ed2717668f326bc43/packages/core/src/bus.ts#L218-L380); the multi-event path requires one aggregate and assigns a contiguous sequence range in the same `IMMEDIATE` transaction ([batched publication](https://github.com/anomalyco/opencode/blob/bcd1769521a0b89fc32db67ed2717668f326bc43/packages/core/src/bus.ts#L470-L603)). Database uniqueness remains the last line of defence across processes; the keyed mutex reduces contention only inside one process.

The in-memory notification carries no truth. A following consumer subscribes before capturing the current persisted sequence, pages SQLite through that watermark, emits a synchronization marker, and then re-queries SQLite after coalesced capacity-one wakes ([replay-and-tail implementation](https://github.com/anomalyco/opencode/blob/bcd1769521a0b89fc32db67ed2717668f326bc43/packages/core/src/bus.ts#L701-L812)). OnePage should copy this principle directly: a wake says “look again”; only the persisted cursor and rows determine what happened.

There is one important caveat. V2's bus defaults `persist` to `false`, in which case projections and the aggregate sequence advance but event payload rows are not retained ([bus option](https://github.com/anomalyco/opencode/blob/bcd1769521a0b89fc32db67ed2717668f326bc43/packages/core/src/bus.ts#L180-L195), [conditional event insert](https://github.com/anomalyco/opencode/blob/bcd1769521a0b89fc32db67ed2717668f326bc43/packages/core/src/bus.ts#L333-L367)). The Durable Object profile forces persistence because eviction recovery needs the log ([workerd configuration](https://github.com/anomalyco/opencode/blob/bcd1769521a0b89fc32db67ed2717668f326bc43/packages/server/src/workerd.ts#L60-L76)). OnePage's transition ledger is semantic authority, so event/transition persistence must not be optional.

## Inbox, history, and recovery

OpenCode V2 does not make “message saved” and “input accepted” synonyms. Prompt admission publishes a durable `session.inbox.enqueued` fact whose projection creates a pending inbox row; delivery later removes that row and creates the model-visible message atomically. Queued input, steering input, compaction, and movement share the durable inbox but have explicit delivery semantics ([Session admission contract](https://github.com/anomalyco/opencode/blob/bcd1769521a0b89fc32db67ed2717668f326bc43/specs/v2/session.md#L5-L25), [inbox admission and idempotency](https://github.com/anomalyco/opencode/blob/bcd1769521a0b89fc32db67ed2717668f326bc43/packages/core/src/session/inbox.ts#L100-L176), [inbox projection](https://github.com/anomalyco/opencode/blob/bcd1769521a0b89fc32db67ed2717668f326bc43/packages/core/src/session/inbox.ts#L206-L272)). Reusing an input ID either reconciles the exact existing lifecycle or fails as a conflict.

That is strong support for OnePage's separate Completion Inbox and explicit admission/delivery states. The exact OpenCode taxonomy is product-specific; the invariant to copy is that pending work cannot become visible history through a partially completed multi-write sequence.

OpenCode also keeps external-effect uncertainty above SQLite. It commits an execution claim before a process-local busy period, preserves the claim on crash, and releases it on ordinary terminal outcomes. Startup recovery resumes claimed top-level Sessions with bounded attempts, but the contract explicitly disclaims exactly-once provider requests and tool effects ([execution and recovery contract](https://github.com/anomalyco/opencode/blob/bcd1769521a0b89fc32db67ed2717668f326bc43/specs/v2/session.md#L27-L48), [recovery boundary](https://github.com/anomalyco/opencode/blob/bcd1769521a0b89fc32db67ed2717668f326bc43/specs/v2/session.md#L86-L90), [claim fields and operations](https://github.com/anomalyco/opencode/blob/bcd1769521a0b89fc32db67ed2717668f326bc43/packages/core/src/session/store.ts#L20-L45)). SQLite supplies atomic local publication; it cannot determine whether a remote side effect occurred. OnePage must retain Attempt admission, dispatch certainty, reconciliation, and fail-closed rules.

## Migration strategy and its cautionary evidence

Fresh V2 databases install the generated current schema and seed every migration ID in one transaction. Existing databases run each TypeScript migration and record its completion ID in the same transaction; the code also bridges the older Drizzle migration journal ([migration runner](https://github.com/anomalyco/opencode/blob/bcd1769521a0b89fc32db67ed2717668f326bc43/packages/core/src/database/migration.ts#L21-L119)). This is sound: completion state is data, not an inference from the database file's existence.

The V1-to-V2 data migration is resumable. It stores a phase/cursor in the database, transforms one Session per transaction, writes the V2 Session and ordered message projection, and sets the event watermark atomically; completion is a separate recorded phase ([migration state and per-Session transaction](https://github.com/anomalyco/opencode/blob/bcd1769521a0b89fc32db67ed2717668f326bc43/packages/core/src/database/v1-migration.bun.ts#L482-L692)). A prior preview database is opened read-only and imported one Session transaction at a time ([preview import](https://github.com/anomalyco/opencode/blob/bcd1769521a0b89fc32db67ed2717668f326bc43/packages/core/src/database/v1-migration.bun.ts#L694-L824)).

OpenCode's earlier JSON-to-SQLite cutover is the cautionary half of the lesson. The original migration used a database-file-existence gate rather than a dedicated completion record; [issue #13654](https://github.com/anomalyco/opencode/issues/13654) reports incremental upgrades where an already-existing database caused legacy JSON Sessions to be skipped, and [issue #16885](https://github.com/anomalyco/opencode/issues/16885) reports the inverse problem on channel-specific databases, where import could rerun. More recent reports describe old and new binaries sharing a database while expecting incompatible schemas ([issue #42260](https://github.com/anomalyco/opencode/issues/42260)) and a V1-to-V2 importer assuming columns absent from older preview schemas ([issue #43139](https://github.com/anomalyco/opencode/issues/43139)). These are user reports in the official tracker, not independently reproduced findings, but they expose the right failure classes: ambiguous completion markers, channel/path drift, downgrade compatibility, and source-schema assumptions.

OnePage is unreleased. The right lesson is not to reproduce OpenCode's elaborate compatibility machinery; it is to settle the schema before V1, keep migration identity transactional from day one, and test reopening every schema version that OnePage actually promises to support.

## Concrete consequences for OnePage

Adopt:

- one host-wide SQLite Host Store accessed only through a singleton Storage Owner;
- one monotonically sequenced semantic ledger per Session;
- an indexed relational envelope with canonical encoded payload bytes;
- one short transaction that commits transition payload, sequence head, Core checkpoint/watermark, and Inbox changes together;
- unique constraints for sequence and stable identity, with conflicting reuse treated as divergence;
- cursor-based reads and coalesced advisory wakes;
- separate pending Inbox and model-visible conversation projection;
- write-ahead execution claims plus explicit uncertain-effect recovery;
- transactional schema-version records and idempotent, resumable migration steps if migrations ever become necessary.

Do not adopt without a new argument:

- direct SQLite access outside the Storage Owner or multiple same-database writer connections;
- a shared database without an explicit host lock, global failure policy, disk limit, and bounded maintenance story;
- `WAL`, `NORMAL`, five-second busy waits, or a 64 MiB cache;
- optional persistence of semantic event payloads;
- time-sortable text IDs instead of OnePage's compact identities;
- a large normalized message/event taxonomy before queries require it;
- expiring external output files as authoritative content;
- migration and downgrade complexity for a product that has not shipped.

The main validation is architectural: SQLite can own page layout, locking, atomic commit, and crash recovery while OnePage continues to own semantic ordering, bounded replay, admission, effect uncertainty, and payload validation. OpenCode's best ideas live above the pager, which is precisely the boundary OnePage needs.
