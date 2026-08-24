# Cursor Origin WAL lessons for OnePage

Research date: 2026-08-24
Primary source: Cursor, [“Git at any scale”](https://cursor.com/blog/git-at-any-scale)

## What Cursor’s design establishes

Cursor’s Continuity stores each push as a write-ahead-log entry in object storage and does not acknowledge the push until that entry is fully persisted. Persistence alone does not publish the push: it becomes visible only after the reference transaction is prepared against a local repository and the WAL index is atomically advanced. The reusable invariant is **persist before publish** ([source](https://cursor.com/blog/git-at-any-scale#continuity)).

The normal Git repository on local NVMe is a materialized execution cache, not durable truth. A missing repository can be rebuilt from the WAL, and reads verify freshness against the WAL index before being served. That separation lets placement and replica topology change without changing correctness ([source](https://cursor.com/blog/git-at-any-scale#consensus), [source](https://cursor.com/blog/git-at-any-scale#replication)).

Because every acknowledged push and repack is represented in the WAL, Cursor can inspect repository states, attribute how they arose, rewind or advance replicas, and diagnose corruption or races. This is operation provenance, not merely a backup of the latest tree ([source](https://cursor.com/blog/git-at-any-scale#wal-as-truth)).

The WAL must still be compacted: replay cost grows with every entry. Cursor compacts once at the primary, records the result for both the repository and WAL, and has replicas download the compacted packs rather than repeat the CPU-heavy repack ([source](https://cursor.com/blog/git-at-any-scale#compaction)).

## OnePage inference

These lessons do **not** justify a third history in OnePage v1.

The user-owned worktree remains external truth. OnePage cannot assume that every mutation to it passed through the harness, so it cannot reconstruct that worktree from an internal baseline plus semantic mutation history. Instead, each mutation operation record should carry the provenance and concurrency guards needed for safe application and diagnosis:

- target and stable operation identity;
- expected preimage identity or digest;
- intended mutation;
- observed postimage identity or digest;
- disposition, including explicit uncertainty when the effect cannot be proven.

This keeps the persist-before-effect / publish-after-result ordering in the existing operation log. Adding a separate mutation log would duplicate ordering authority and create reconciliation problems without making the externally mutable worktree reconstructable.

Baseline-plus-semantic-mutation reconstruction becomes sound only in a future mode where the harness owns an isolated workspace and closes every mutation path. In that topology, the baseline and WAL can be authoritative while the checked-out repository is merely a disposable materialization. Until then, OnePage should use guarded mutation records to prove what it attempted and what it observed, while treating the actual user worktree as truth.

Finally, repository/WAL compaction and conversation compaction are different operations. Repository/WAL compaction changes the physical representation of authoritative mutation history while preserving exact repository semantics and provenance. Conversation compaction produces a bounded model-facing projection and may intentionally discard conversational detail. They need separate invariants, formats, and triggers even if both reduce replay cost.
