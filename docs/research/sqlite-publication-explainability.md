# SQLite publication and explainability

## Subsequent decision — 10 September 2026

The published [Operation-owned execution decision](../adr/0026-let-operations-own-current-execution-and-final-results.md) supersedes historical durable Completion ownership; [direct transactional functions](../design/transactional-operations.md) replace mandatory classifiers. SQLite atomicity and post-commit failure evidence below remain useful within those owners.

Research note, 2026-09-08. This investigates one question: how much of “save related facts before releasing their consequences” SQLite already provides. It selects no architecture and changes no accepted requirement.

## Evidence and boundary

The root checkout's working-tree `docs/architecture/execution.md` was read on this date, especially “Admission and dispatch,” “Evidence and settlement,” and “Effect-specific recovery.” It is accepted design evidence, including unpublished amendments, not proof of production behavior. It requires one Storage Owner, atomic result/content/semantic publication, post-commit consequence release, and a mandatory bounded snapshot/pure classifier/fixed mutation sequence.

**Verified SQLite facts:** a transaction makes its database changes atomic, including crash recovery subject to configured durability and functioning storage. SQLite owns the journal/pager mechanism; application code need not invent another partial-publication recovery log. This does not make workspace file changes or provider requests transactional with the database. [Atomic commit](https://www.sqlite.org/atomiccommit.html)

`BEGIN IMMEDIATE` starts a write transaction and can fail with `SQLITE_BUSY`; only one writer operates at once. A failed `COMMIT` does **not** universally mean rollback: `SQLITE_BUSY` can leave the transaction active for retry. Other errors may undo one statement or the transaction; inspect transaction state and explicitly clean up. An open incremental BLOB counts as an unfinished statement; pending writes can prevent commit. [Transaction control and errors](https://www.sqlite.org/lang_transaction.html)

Durability depends on settings: for example, WAL with `synchronous=NORMAL` can lose committed transactions after power loss while retaining consistency. A claim about surviving process termination must not silently become a claim about every power-loss configuration. [Synchronous settings](https://www.sqlite.org/pragma.html#pragma_synchronous)

## Annotated Edit-result publication trace

This is an interpretation of the accepted OnePage contract, not a new schema or implementation prescription. Exact Edit intent and admission already committed before this trace begins.

| Moment | Responsibility and crash meaning |
| --- | --- |
| Edit finishes, or recovery observes the target | The effect owner supplies typed evidence. File mutation already happened outside SQLite; rollback cannot undo it. Observed matching bytes after lost custody are not proof of successful execution. |
| Validate sealed evidence/content | Prepare and validate with bounded windows before the publication transaction where possible. Private scratch is disposable, never a second authority. |
| Begin publication transaction | Revalidate the exact Operation/Attempt, absence of a final result, and the applicable settlement rules. Preserve the original authorization; a later permission-mode change does not retroactively revoke it. SQLite serializes database changes; OnePage determines their meaning. |
| Import required content and write its semantic references | Fill content completely, verify bindings, then install the immutable Operation Resolution and required Conversation facts in the same transaction. No semantic reference may expose partial bytes. |
| Commit successfully | Content and semantic result become one accepted database state. Only now release the resulting continuation or acknowledgement. |
| Crash after commit, before delivery | Recover the saved result and ordinary pending work. Do not repeat the Edit because a notification was lost. |
| Import or commit fails | Release no consequence. Close handles and settle the transaction's actual error state. Do not convert a database failure into permission to repeat the external Edit. |

## Large content: bounded buffers are not bounded transaction time

SQLite supports preallocating a `zeroblob` without a payload-sized application allocation, then copying fixed windows with incremental BLOB I/O. Each write changes a range within the existing size; it cannot grow the BLOB. [Binding zeroblobs](https://www.sqlite.org/c3ref/bind_blob.html), [incremental writes](https://www.sqlite.org/c3ref/blob_write.html)

The schema must support this API: it operates on rowid tables, and writable BLOB columns have indexing/constraint restrictions. Updating the same row can expire its BLOB handle without undoing earlier writes. Close and check handles before publication commit. In explicit transactions, closing a handle is not a substitute for the transaction commit; the documented close-triggered commit applies to autocommit circumstances. [Opening BLOBs](https://www.sqlite.org/c3ref/blob_open.html), [closing BLOBs](https://www.sqlite.org/c3ref/blob_close.html)

**Inference:** fixed windows bound application copy buffers, not total SQLite memory, journal growth, write-transaction duration, or control latency. Large atomic imports still perform work proportional to imported bytes. Measure the integrated import path before claiming responsiveness. Splitting publication into independently committed stages would introduce new recovery/retention obligations and is not justified by this research alone.

## Explainability hypothesis to test next

SQLite supplies the atomic database boundary. It does not supply applicability checks, exact permission bindings, effect uncertainty policy, resource custody, or post-commit launch fencing.

The accepted mandatory classifier pipeline may make these rules clearer, or may require a second representation that repeats the same command's meaning. That is a hypothesis, not a selected removal. Compare one concrete Edit-result command expressed through the current pipeline with the same command expressed as a cohesive transactional operation. Count the concepts, duplicated rules, caller obligations, and failure cases needed to explain each. Retain whichever separation demonstrably reduces total explanation while preserving inspection/advancement consistency and bounded work.

No production code or runtime tests were used; official documentation establishes API contracts, not OnePage integration performance or correctness.
