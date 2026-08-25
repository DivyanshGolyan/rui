# Durable Session ownership and resume

> Historical evidence. The ownership and exact-resume results remain useful, but ADR-0007 supersedes the separate Conversation-log and operation-journal authority model. Immutable Conversation content advances only through the single ordered Session WAL, which also owns effect and lifecycle facts.

## Question

Can OnePage create and resume an exact durable Session without retaining conversation history or ownership state in a resident catalogue?

## Deep seam

`session.Session` owns four related rules:

- distinct Session, Agent, Task, and main-branch identities;
- an advisory operating-system lock held for the Session lifetime;
- a durable ownership epoch published before reconstruction;
- an append-only conversation log whose active leaf advances only after its new entry is synced.

Creation draws a fresh, nonzero, pairwise-distinct Session, Agent, Task, and main-branch identity set with a fixed retry bound. It opens the exact path it records, validates the Git worktree, stores the pinned model and task, appends and syncs the initial user entry, and only then publishes the first manifest. An interrupted creation therefore cannot resume as a rootless Session. Repeating task text has no resume semantics: a different Session identity creates a separate directory and identity set. `formatId` renders the stable 16-character identifier that the terminal command will print.

Exact resume opens only the named Session directory. It fails nonblockingly while another owner holds the lock, validates that the recorded workspace still exists as a Git worktree, increments and syncs the ownership epoch, and only then reconstructs conversation state. The returned manifest restores the original workspace, model, task, Agent, Task, branch, and active leaf. A compact level projection regenerates the Session, Task, leaf, and ownership epoch for the caller. Credentials are not part of the manifest.

## Conversation shape

The conversation is a sequence of canonical, checksummed 80-byte records. Every entry has immutable Session, Task, entry, parent, content-reference, kind, and sequence fields. V1 appends to `main`, while the codec already permits a later entry to name any earlier parent so future forks do not require a format migration. The active root-to-leaf path requires no resident object graph.

The manifest is a rebuildable leaf projection over the authoritative conversation log. Append performs this order:

```text
validate current owner token
-> append and sync immutable conversation entry
-> atomically replace and sync manifest with the new leaf
```

A crash can therefore leave the log exactly one entry ahead. Resume validates that entry's identity and parent and advances the manifest. A manifest ahead of the log, a gap larger than one record, a broken parent, or corrupt bytes fails closed.

## Ownership fencing

Every owner receives a `(session_id, ownership_epoch)` token. Authorization rereads the durable manifest and rejects a mismatched token. Completion and operation-journal records carry the attempt's dispatch epoch. The Session fence proves current-owner authority before every drive. The durable transition adapter rejects future epochs, while permitting the current owner to reconcile an older completion only when the journal contains its exact accepted attempt.

The operation journal format is now version 3 and 80 bytes so accepted intent also names a stable Attempt, recovery class, and immutable descriptor digest. The 40-byte Completion keeps full 64-bit Agent, Operation, epoch, and result values plus both 32-bit generations. A one-bit-per-slot completion map distinguishes that full record from the other ingress encodings. The adapter rereads accepted metadata when persisting a completion, trading bounded disk work for zero extra resident control fields.

## Bounds and tests

The Session object retains directory and lock handles plus fixed identity and leaf metadata. Manifest encoding uses a fixed 2,048-byte caller or stack buffer. Conversation access reads one 80-byte record at a time. No collection grows with Session count or conversation length.

Deterministic tests prove:

1. create and exact resume preserve all identities and configuration;
2. a second concurrent owner receives `SessionBusy`;
3. ownership epoch advances before reconstruction;
4. an old owner token is stale after resume;
5. repeating task text creates a different Session;
6. conversation entries are immutable and parent-linked;
7. resume reconciles a synced entry ahead of the manifest;
8. non-Git workspaces, aliased identities, and corrupt manifests fail before use;
9. a resumed owner applies a prior-epoch journal completion to a lagging restored slot without appending it again;
10. a future epoch cannot append to the operation journal or mutate the slot.

The full owner-crash run reports exactly 1,536 bytes for `Harness`, its Session fence, `durable_transition.Adapter`, and the restored-slot bridge. This remains native control metadata outside the 64 KiB WebAssembly page and does not vary with the number of durable Sessions.
