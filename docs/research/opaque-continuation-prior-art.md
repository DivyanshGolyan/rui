# Opaque continuation versus canonical history: non-agent prior art

> Decision status: ADR-0023 adopts the no-degradation result but not this note's duplicate-object terminology. Attempt Completion owns canonical continuation fields, and an accepted compaction Resolution may serve as a derived Compaction Base. OnePage has no Provider Replay Receipt, Compaction Checkpoint relation, or semantic-handoff fallback.

Research date: 2026-09-03

## The tension

A long-lived system sometimes needs state that is both valuable for fast, high-fidelity
continuation and deliberately unavailable to the application.  The application still needs a
durable, inspectable account of what happened and a way to rebuild or hand work off.  These goals
conflict when the fast state is provider-specific, cryptographically bound to its original
environment, or non-portable by design.

This is not principally an “agent harness” problem.  The recurring solution in mature systems is
to separate three roles instead of calling them alternate forms of one record:

```text
canonical history / authoritative state
    -> derived, readable serving checkpoint (portable rebuild or handoff)
    -> opaque, revocable acceleration capability (same compatible endpoint only)
```

The last item cannot become historical authority merely because it is the best continuation path.
Conversely, the readable checkpoint must not be claimed to preserve the capability's hidden state.

## 1. TLS 1.3 session tickets: opaque state is a capability, not a session record

TLS's `NewSessionTicket` creates an association between a ticket and a secret PSK derived from the
original handshake.  A later client presents the ticket to attempt resumption.  The protocol calls
the ticket an **opaque label**: it may be a server-database key or a self-encrypted,
self-authenticated value.  It is bound to the current handshake with a binder, is constrained by
the original KDF and server name/certificate, and the server may decline resumption and perform a
full handshake instead ([RFC 8446, sections 4.2.11 and 4.6.1](https://www.rfc-editor.org/rfc/rfc8446.html#section-4.6.1)).

**Transfer.** An OpenAI compaction payload should have TLS-ticket semantics: a sealed,
provider-owned capability carried by OnePage, with exact compatibility and expiry rules enforced at
the provider edge.  It is neither readable conversation history nor a portable checkpoint.  Its
loss means “perform the explicit alternative continuation procedure,” not “decode, edit, or
silently pretend the old continuation was retained.”

## 2. PostgreSQL base backup plus WAL: every replay accelerator needs a source range and suffix

PostgreSQL recovers by restoring a base backup and replaying a continuous WAL sequence from the
backup's start.  Its backup history identifies the required WAL range; recovery can stop at a
chosen point, and a branch creates a new timeline rather than overwriting the old one.  The docs
also distinguish a logical dump from the physical material needed for WAL replay: a `pg_dump` is
not enough for that recovery path ([PostgreSQL continuous archiving and PITR](https://www.postgresql.org/docs/current/continuous-archiving.html)).

**Transfer.** A OnePage model-context cut needs an immutable covered conversation range, parent
lineage, and an exact suffix boundary.  The canonical Conversation survives.  A context artifact
is usable only with the suffix and contract for which it was made; branches or rewinds require an
explicit new lineage, not reuse by proximity.

## 3. LevelDB/RocksDB manifests: publish one derived serving view atomically

LevelDB's `MANIFEST` is a log of changes to the *serving* table set, while `CURRENT` points to the
latest manifest; recovery reads `CURRENT` then replays that manifest.  RocksDB rolls a MANIFEST by
starting the new file with a snapshot, appending later edits, and only purges the old redundant
manifest after `CURRENT` has been synced ([LevelDB implementation notes](https://github.com/google/leveldb/blob/main/doc/impl.md#manifest), [RocksDB MANIFEST design](https://github.com/facebook/rocksdb/wiki/MANIFEST)).

**Transfer.** Normal, readable compaction is a derived serving projection.  It should be prepared,
validated, durably published, and selected as *the* active model-context materialization.  A failed
new projection leaves the prior one active.  This supports the user's discomfort with putting two
co-equal payloads in one checkpoint: only one materialization should be active for a request.

## 4. Kubernetes continue tokens: opaque cursor validity has an explicit failure mode

For paginated list operations Kubernetes returns a continue token that encodes the established
`resourceVersion` and position.  It preserves a consistent listing snapshot only while that
resource version remains available.  If it has been compacted away, the API returns `410 Gone`; the
client must recover by retrying from a newer version or by a fresh list, rather than fabricating the
missing continuation ([Kubernetes API concepts](https://kubernetes.io/docs/reference/using-api/api-concepts/#resource-versions)).

**Transfer.** “This provider replay is no longer valid” is a first-class outcome, not a hidden
fallback branch.  OnePage should return either `continuation preserved` or `continuation unavailable`.
The latter is resolved only by the session's declared policy: refuse/defer an incompatible change,
or deliberately start a fresh provider context from an approved handoff.

## Recommendation for OnePage

Do not define a semantic checkpoint and an OpenAI opaque compaction value as two representations of
the same checkpoint.  Model them by role:

```text
Conversation                         one durable semantic authority
Model Context Cut                    one selected derived projection for a request
Provider Continuation Capability     optional opaque input to that cut's provider adapter
```

The **Model Context Cut** correlates to the Conversation by its source interval, lineage, suffix
boundary, and creating operation.  It selects exactly one usable continuation route for each
request:

1. an OpenAI capability plus the suffix, when its provider/model/prompt-tool contract is compatible;
2. otherwise a newly made semantic handoff projection, but only when the session explicitly permits
   handoff;
3. otherwise an explicit `continuation unavailable` outcome.

The Core should not parse provider capability bytes or treat them as a domain entry.  The provider
adapter owns compatibility validation and request grammar.  This preserves a single durable
authority and avoids the dangerous behaviour at the heart of the question: degrading an
already-working, thoughtful session into a fresh one without making that quality boundary explicit.
