# Write-ahead logs and related storage ideas

Research date: 2026-08-29

> Decision status: ADR-0019 and the current architecture supersede this note's Session Ledger/Core authority. Issue #95 owns the still-unsettled SQLite journal, synchronous, page, cache, and command-work choices. The concrete SQLite settings and “current” claims below are historical research conclusions, not adopted V1 policy.

## Decision for OnePage

OnePage should keep two layers conceptually separate:

1. **SQLite owns physical atomicity and crash recovery.** V1 deliberately uses one serialized SQLite
   connection with 4 KiB pages, rollback-journal `DELETE`, and `synchronous=EXTRA`; it does not use
   SQLite WAL mode and does not implement ARIES. These are current architectural choices, not gaps to
   fill ([OnePage architecture](../../ARCHITECTURE.md#session-storage),
   [ADR-0009](../adr/0009-use-one-host-store-with-session-ledgers.md)).
2. **OnePage owns semantic authority.** Each Session has an ordered append-only Session Ledger inside
   SQLite. One SQLite transaction commits the canonical semantic transaction, its Session sequence,
   Core State, and derived rows together. Immutable external content becomes durable before a ledger
   transaction may refer to it, and recovery reduces committed ledger transactions through the same
   semantic reducer used by the live path ([OnePage architecture](../../ARCHITECTURE.md#durable-authority),
   [ADR-0009](../adr/0009-use-one-host-store-with-session-ledgers.md)).

The old design called the per-Session authority a “Session WAL,” but ADR-0007 is superseded. Its
durable-before-reference and complete-transition ideas remain; its separate physical WAL and checkpoint
files do not ([ADR-0007](../adr/0007-use-one-session-wal-as-semantic-authority.md),
[ADR-0009](../adr/0009-use-one-host-store-with-session-ledgers.md)).

The practical conclusion is: **do not add a second physical log merely because the Session Ledger is
append-only or because WAL is a respected database technique.** A second physical log would need a new
failure or performance requirement that SQLite's transaction and journal contract cannot meet. The
research below is most useful for sharpening OnePage's ordering, acknowledgement, recovery, and fault
model—not for copying another storage engine into the application.

## The overloaded word “log”

| Mechanism | What is appended or journaled | Its authority | What recovery does | OnePage relevance |
| --- | --- | --- | --- | --- |
| Database WAL | Redo information before changed home pages may reach stable storage | Physical database state | Replays committed changes not yet present in home pages | SQLite can provide this in WAL mode, but V1 does not select that mode |
| Rollback journal | Before-images before database pages are overwritten | Physical database state | Restores the old transaction state after an incomplete commit | This is OnePage V1's selected SQLite mechanism |
| ARIES | Physiological log records, transaction state, and compensation records | A complete DB recovery protocol built on WAL | Analysis, redo by repeating history, then undo of losers | Foundational theory; not an application-layer implementation template |
| Filesystem journal | Filesystem metadata, and optionally file data, grouped into journal transactions | Filesystem consistency | Replays complete filesystem journal transactions | A lower layer; it does not commit OnePage semantic transactions |
| Log-structured file system (LFS) | The filesystem's data, metadata, and indexes | The primary on-disk filesystem layout | Starts from a checkpoint and rolls the log forward | The attached Rosenblum/Ousterhout paper; not a side journal or DB WAL |
| LSM tree | Buffered index updates merged through memory and disk components | An indexing/storage data structure | Uses separate logging/checkpoint rules to recover buffered state | Adjacent write-optimization idea, not a durability protocol by itself |
| Event-sourced log / semantic ledger | Domain facts in application order | Application history and reconstructable state | Reapplies domain facts, often from a snapshot | Closest analogue to the OnePage Session Ledger, though OnePage uses typed transactions rather than adopting a generic event platform |

This distinction is visible in the original sources. PostgreSQL defines WAL by the ordering constraint
that redo records reach permanent storage before the data-file changes they describe
([PostgreSQL WAL introduction](https://www.postgresql.org/docs/current/wal-intro.html)). SQLite's
rollback journal instead stores old page contents and uses the presence of the journal to decide whether
to restore the old state, whereas SQLite WAL preserves the old database file, appends new page images,
and commits by appending a commit record
([SQLite WAL: how it works](https://www.sqlite.org/wal.html#how_wal_works),
[SQLite atomic commit](https://www.sqlite.org/atomiccommit.html#_deleting_the_rollback_journal)).
Both mechanisms can implement atomic transactions; “WAL” is not a synonym for “the only safe commit
scheme.”

## 1. The WAL invariant before the algorithms

The durable ordering rule is simpler than any named recovery algorithm:

> A changed data page must not replace its durable old version until the log needed to recover that
> change is itself durable.

The ARIES paper states this protocol directly and records a log sequence number (LSN) on each page so
the buffer manager can tell how far the log must be forced before writing that page
([Mohan et al., *ARIES*, pp. 97–98](https://www.cs.cmu.edu/~15849g/readings/mohan92.pdf)). PostgreSQL
expresses the same rule operationally: once redo records are durable, commit need not force every dirty
table or index page because crash recovery can roll those changes forward
([PostgreSQL WAL introduction](https://www.postgresql.org/docs/current/wal-intro.html)).

Two consequences matter more to OnePage than the physical page algorithm:

- **Acknowledgement must follow the durability boundary.** OnePage's live `offer` custody is not an
  acknowledgement; the caller can rely on a transition only after its Host Store transaction commits
  ([OnePage product contract](../../PRODUCT.md#product-guarantees)).
- **Referents must precede references.** A transaction cannot be recoverable if it commits a pointer to
  content whose bytes may still disappear. OnePage therefore synchronizes immutable content before
  committing the ledger reference ([OnePage architecture](../../ARCHITECTURE.md#durable-authority)).

Those are semantic analogies to write-ahead ordering. They do not mean the Session Ledger should become
a second pager log.

## 2. ARIES: the canonical full recovery protocol

ARIES is a particular industrial recovery method, not the definition of WAL. It combines WAL with page
LSNs, fuzzy checkpoints, transaction and dirty-page tables, compensation log records (CLRs), and a
restart sequence of analysis, redo, and undo. Redo “repeats history,” including updates from transactions
that had not committed at the crash; undo then rolls back those loser transactions. Undo actions are
themselves logged as CLRs so another crash during recovery does not cause unbounded repeated undo
([IBM publication record](https://research.ibm.com/publications/aries-a-transaction-recovery-method-supporting-fine-granularity-locking-and-partial-rollbacks-using-write-ahead-logging),
[Mohan et al., *ARIES*, abstract and restart algorithm](https://www.cs.cmu.edu/~15849g/readings/mohan92.pdf)).

ARIES is worth reading because it cleanly separates:

- log order from page state through LSNs;
- a fuzzy checkpoint's recovery starting information from authoritative history;
- redo idempotence from transaction outcome;
- crash recovery from media recovery; and
- forward actions from explicit compensation.

OnePage should borrow that discipline at the semantic layer—stable Session sequence, replayable typed
facts, checkpoints or projections that may lag authority, and explicit recovery dispositions—but should
not reproduce ARIES's page and transaction machinery. SQLite already owns OnePage's pages, transaction
rollback, journal recovery, and locking ([ADR-0009](../adr/0009-use-one-host-store-with-session-ledgers.md)).

## 3. SQLite rollback journal versus SQLite WAL

SQLite documents these as alternative journal modes for the same atomic-transaction responsibility.
A database uses a rollback journal or a WAL, not both at once
([SQLite database file format](https://www.sqlite.org/fileformat.html#hot_journals)).

### Rollback journal: OnePage V1's choice

In rollback mode, SQLite writes complete before-images to the journal and flushes them before modifying
the database file. After the changed database pages are also flushed, deleting the journal is the commit
point. If a crash leaves a hot journal, SQLite restores the before-images; observers therefore see the
old complete transaction or the new complete transaction rather than enclosed partial writes
([SQLite atomic commit, sections 3–4](https://www.sqlite.org/atomiccommit.html)).

`journal_mode=DELETE` makes deletion the commit action. `synchronous=EXTRA` adds a sync of the containing
directory after the rollback journal is unlinked; SQLite recommends it when rollback-mode durability
across power loss is required
([SQLite journal mode](https://www.sqlite.org/pragma.html#pragma_journal_mode),
[SQLite synchronous mode](https://www.sqlite.org/pragma.html#pragma_synchronous)). This is the precise
physical contract selected by OnePage, subject to SQLite's stated VFS, filesystem, and hardware
assumptions.

### WAL mode: comparative reading, not a recommendation

In SQLite WAL mode, revised database pages are appended as frames. A frame with a non-zero database-size
field is a commit frame; readers pin the last valid commit as an end mark and resolve each page from the
latest applicable WAL frame or the main database. A checkpoint later copies committed frames back to the
main file
([SQLite WAL overview](https://www.sqlite.org/wal.html#how_wal_works),
[SQLite WAL file format](https://www.sqlite.org/fileformat.html#walformat)).

WAL mode is attractive when concurrent readers and a writer matter: readers can retain independent
snapshots while one writer appends, although SQLite still permits only one writer at a time. It also adds
a WAL file, a shared-memory index, and checkpoint scheduling; a long reader can stop checkpoint progress
([SQLite WAL concurrency](https://www.sqlite.org/wal.html#concurrency),
[SQLite WAL performance considerations](https://www.sqlite.org/wal.html#performance_considerations)).
Those benefits do not answer a current OnePage need: V1 has a process lifetime lock, one connection, one
serialized Storage Owner, and one writer, and explicitly chooses rollback mode
([OnePage architecture](../../ARCHITECTURE.md#session-storage)).

Switching SQLite journal modes would therefore be a measured storage-topology decision, not a semantic
ledger decision. The Session Ledger remains OnePage's semantic authority in either mode.

SQLite's current WAL documentation also records a concurrency-specific WAL-reset bug fixed in 3.51.3
and backported to 3.44.6 and 3.50.7. It required two or more connections plus a narrow concurrent
write/checkpoint race, so it does not apply to OnePage's present rollback-journal, singleton-connection
topology. A future WAL-mode evaluation should nevertheless verify that its pinned SQLite includes the
fix rather than treating “SQLite WAL” as a timeless abstract contract
([SQLite WAL-reset bug](https://www.sqlite.org/wal.html#the_wal_reset_bug)).

## 4. Complete commits, valid prefixes, and corrupt tails

A useful log must distinguish a complete committed prefix from an incomplete or corrupt suffix. The
format needs more than “append bytes”:

- transaction boundaries or commit markers;
- record lengths and versions;
- ordering identities;
- integrity checks over the intended coverage; and
- a recovery rule for stopping or failing.

SQLite WAL gives a concrete physical example. Each frame copies generation salts from the WAL header and
contains cumulative checksums over the header and every frame through the current one. Recovery scans
from the beginning, stops at end-of-file or the first invalid checksum, and exposes only through the last
valid commit frame
([SQLite WAL file format](https://www.sqlite.org/fileformat.html#walformat),
[SQLite WAL recovery](https://www.sqlite.org/walformat.html#recovery)). ext4's JBD2 journal uses an
analogous transaction boundary: a complete transaction ends in a commit block, and replay discards a
transaction with no commit record or mismatched checksums
([Linux kernel JBD2 journal format](https://www.kernel.org/doc/html/latest/filesystems/ext4/journal.html#layout)).

For OnePage, the analogous semantic unit is already one canonical ledger row containing one complete
typed transaction and occupying one Session sequence inside a SQLite transaction. Recovery should
reject a sequence gap, duplicate, invalid payload, or missing durable referent rather than invent a
semantic prefix inside a partially decoded transaction
([OnePage architecture](../../ARCHITECTURE.md#durable-authority)). SQLite's physical rollback-journal
recovery happens below that layer; OnePage should not parse a SQLite journal or attempt to recover half
of one SQLite commit.

## 5. Checksums, torn writes, and the storage contract

These solve related but different problems:

- **Atomic transaction framing** decides which complete transaction is visible after interruption.
- **A checksum** detects some changed or malformed bytes; it does not make the bytes durable, repair
  them, or prove that the storage device honoured a flush.
- **Torn-write protection** handles a logical page whose sectors were only partly written.
- **A sync/barrier contract** orders writes and asks the storage stack to make them persistent.

PostgreSQL illustrates the separation. An 8 KiB database page can span sectors and be partly written on
power loss, so PostgreSQL logs a full-page image before the page's first post-checkpoint change and can
restore the page during recovery. PostgreSQL separately protects each WAL record with CRC-32C and uses
data-page checksums, while warning that the administrator still depends on storage caches and devices
honouring flush requests
([PostgreSQL reliability](https://www.postgresql.org/docs/current/wal-reliability.html)).

SQLite's atomic-commit document is equally explicit about its assumptions: sector behaviour, atomic file
deletion, filesystem ordering, and the expectation that underlying hardware and the operating system
handle bit errors. SQLite does not add general redundancy to the main database file to correct arbitrary
corruption
([SQLite atomic commit assumptions](https://www.sqlite.org/atomiccommit.html#_assumptions_about_the_underlying_hardware)).
OnePage's current contract correctly relies on the pinned SQLite engine and supported platform for pager
atomicity and journal recovery and does not claim protection from arbitrary faulty hardware
([OnePage architecture](../../ARCHITECTURE.md#failure-and-compatibility)).

If OnePage ever hand-rolls an external manifest or log, `write`, `close`, or `rename` alone would not
establish the same durability claim. On Linux, `fsync()` requests persistence of a file's data and
metadata but does not necessarily persist the directory entry; the containing directory needs its own
sync
([Linux `fsync(2)`](https://man7.org/linux/man-pages/man2/fsync.2.html)). This is another reason to
prefer SQLite's established pager contract for the Host Store.

## 6. Group commit

Group commit amortizes one durable WAL flush across multiple transactions that become ready together.
PostgreSQL can delay a flush briefly so more commit records join it; that can improve throughput when
commit rate and sync latency are bottlenecks, but it adds latency and can reduce throughput when the
delay is too large. PostgreSQL can also form groups without an explicit delay when transactions arrive
while another flush is already in progress
([PostgreSQL WAL configuration](https://www.postgresql.org/docs/current/wal-configuration.html),
[`commit_delay`](https://www.postgresql.org/docs/current/runtime-config-wal.html#GUC-COMMIT-DELAY)).

This is a throughput policy, not part of the WAL correctness invariant. OnePage V1 serializes and commits
one complete Storage Owner request at a time and explicitly has no group commit. It should stay that way
until measurements show commit-sync throughput is a product bottleneck and there is enough concurrent
work to batch without violating per-request acknowledgement or bounded-latency contracts
([OnePage architecture](../../ARCHITECTURE.md#capacity-and-density)).

## 7. Filesystem journaling is another layer

The ext4 journal is a filesystem recovery structure. In the default ordered mode, ext4 journals
metadata while ordering associated file data before the metadata commit; other modes change whether
file data itself is journaled. JBD2 records a transaction as descriptor/data or revocation blocks ending
in a commit block, and discards incomplete or checksum-invalid transactions during replay
([Linux kernel ext4 journal documentation](https://www.kernel.org/doc/html/latest/filesystems/ext4/journal.html)).

That can restore filesystem structural consistency and make filesystem recovery faster, but it cannot
decide that a OnePage Attempt, Result, Conversation advance, and Core State belong to one semantic
transition. PostgreSQL's documentation makes the layering explicit: database WAL is sufficient for its
database-file recovery contract, while filesystem journaling is a separate mechanism that may improve
filesystem recovery time and add overhead
([PostgreSQL WAL introduction](https://www.postgresql.org/docs/current/wal-intro.html)).

The empirical journaling literature is useful if OnePage ever investigates platform-specific write
ordering rather than relying on SQLite's supported VFS contract. Prabhakaran, Arpaci-Dusseau, and
Arpaci-Dusseau traced ext3, ReiserFS, JFS, and NTFS at the block layer and showed that real journaling
policies differ materially in ordering, grouping, and performance
([*Analysis and Evolution of Journaling File Systems*](https://www.usenix.org/conference/2005-usenix-annual-technical-conference/analysis-and-evolution-journaling-file-systems)).

## 8. The attached paper: a log-structured file system is not a WAL

Rosenblum and Ousterhout's Sprite LFS makes the log the filesystem's primary on-disk structure: file
data, metadata, and indexes are written sequentially, and the indexes locate the newest versions in the
log. It divides the log into segments and reclaims space by cleaning fragmented segments—copying live
data out and freeing whole segments
([Rosenblum and Ousterhout, *The Design and Implementation of a Log-Structured File System*](https://web.stanford.edu/~ouster/cgi-bin/papers/lfs.pdf)).

Sprite LFS recovery reads the newest complete checkpoint and rolls forward through later log segments.
The paper explicitly contrasts this design with database WAL: a database keeps a separate home area and
can reclaim log space after changes reach it; Sprite LFS keeps the log as the final home of data and must
clean segments to reclaim space
([Rosenblum and Ousterhout, sections 4 and 6](https://web.stanford.edu/~ouster/cgi-bin/papers/lfs.pdf)).

The transferable OnePage lesson is not “store the Host Store as an LFS.” It is that append-only primary
storage moves complexity into indexing, checkpointing, retention, cleaning, and write amplification.
SQLite already owns those physical storage trade-offs for OnePage.

## 9. Event sourcing and LSM trees: adjacent, not interchangeable

Fowler defines event sourcing as storing every application-state change as an ordered domain event so
state can be rebuilt or queried historically. The event log may be the system of record while current
state is a derived snapshot or cache
([Martin Fowler, *Event Sourcing*](https://martinfowler.com/eaaDev/EventSourcing.html)). That is much
closer to the OnePage Session Ledger than a pager WAL is: the ledger stores typed semantic lifecycle
facts and reconstructs resident Session state. Still, OnePage need not adopt generic event-sourcing
terminology or infrastructure; its authoritative unit is a bounded typed semantic transaction that may
contain several ordered facts and commits derived indexes atomically.

An LSM tree is different again. The original paper describes an indexing structure that buffers updates
in memory and incrementally merges them into one or more disk components to reduce random write cost;
it still assumes logging and checkpointing to recover updates not yet migrated to disk
([O'Neil et al., *The Log-Structured Merge-Tree*](https://www.cs.umb.edu/~poneil/lsmtree.pdf)). It is an
index/write-path design, not a transaction commit protocol and not a reason to replace SQLite in V1.

Distributed replicated logs such as Raft or Kafka answer yet another problem—ordering and retaining
records across machines. OnePage V1 is deliberately single-host, so that branch is not prerequisite
reading for its current durability design.

## Consequences for OnePage

### Keep

- one SQLite Host Store, one connection, and one Storage Owner;
- rollback-journal `DELETE` plus `synchronous=EXTRA` until evidence justifies a journal-mode change;
- one append-only semantic ledger per Session inside SQLite;
- one complete canonical semantic transaction per Session sequence;
- durable content before a committed reference to that content;
- acknowledgement only after the Host Store commit;
- rebuildable projections and resident state that may lag semantic authority;
- explicit effect uncertainty and reconciliation above SQLite; and
- a bounded, stated storage fault model rather than an implied arbitrary-corruption guarantee.

### Do not add without new evidence

- a second physical Session WAL or separate checkpoint files;
- ARIES page/transaction recovery logic in application code;
- SQLite WAL mode merely for sequential-write aesthetics;
- group commit before measured sync throughput and concurrency demand exist;
- custom checksums as a substitute for SQLite atomicity or storage flushes;
- LFS/LSM compaction machinery; or
- a generic event-stream or distributed-log platform.

### Questions that would justify reopening the physical choice

- Do concurrent readers need to proceed during a long SQLite writer transaction?
- Is durable commit-sync rate a measured throughput bottleneck under a representative workload?
- Does a supported deployment topology require multiple connections or processes against one store?
- Is the rollback journal's directory churn a measured platform problem?
- Is a new backup, replication, or point-in-time-recovery promise being added?

Any “yes” should trigger a measured SQLite-level design review first. It should not silently turn the
semantic Session Ledger into a hand-built storage engine.

## Recommended reading order

1. **Start with the invariant:** [PostgreSQL WAL introduction](https://www.postgresql.org/docs/current/wal-intro.html)
   (about five minutes). Read only until the difference between log flush and dirty-page flush is clear.
2. **Anchor in OnePage's actual physical mechanism:**
   [SQLite atomic commit](https://www.sqlite.org/atomiccommit.html) and
   [SQLite `synchronous`](https://www.sqlite.org/pragma.html#pragma_synchronous). Focus on ordered
   journal writes, the commit point, storage assumptions, and why `EXTRA` matters in `DELETE` mode.
3. **Compare rather than adopt:** [SQLite WAL](https://www.sqlite.org/wal.html), then the
   [WAL file format](https://www.sqlite.org/fileformat.html#walformat) and
   [recovery scan](https://www.sqlite.org/walformat.html#recovery). This is the clearest concrete study
   of commit frames, snapshots, checksummed prefixes, and checkpointing.
4. **Read the full theory:** the [IBM ARIES publication record](https://research.ibm.com/publications/aries-a-transaction-recovery-method-supporting-fine-granularity-locking-and-partial-rollbacks-using-write-ahead-logging)
   and [paper](https://www.cs.cmu.edu/~15849g/readings/mohan92.pdf). Prioritize the abstract, WAL
   protocol, restart overview, and conclusion before the detailed algorithms.
5. **Separate the filesystem layer:** [ext4/JBD2 journal format](https://www.kernel.org/doc/html/latest/filesystems/ext4/journal.html),
   especially transaction layout and commit blocks.
6. **Read the attached LFS paper side by side with WAL:**
   [Rosenblum and Ousterhout](https://web.stanford.edu/~ouster/cgi-bin/papers/lfs.pdf), especially
   sections 3 (cleaning), 4 (recovery), and 6 (the explicit comparison with database WAL).
7. **Only for adjacent design vocabulary:** [Fowler on Event Sourcing](https://martinfowler.com/eaaDev/EventSourcing.html)
   for semantic-history terminology, and the [original LSM-tree paper](https://www.cs.umb.edu/~poneil/lsmtree.pdf)
   for batched indexing. Neither is required to implement OnePage V1 durability.
