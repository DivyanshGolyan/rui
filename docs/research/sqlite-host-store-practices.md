# SQLite Host Store practices

This note records mature storage patterns considered for the V1 Host Store. Issue #95 owns the
still-unsettled SQLite settings and command-work limits; concrete numeric values below, including
4 KiB pages, are evidence to evaluate rather than adopted V1 policy. The normative contract remains
in `ARCHITECTURE.md` and `VERIFICATION.md`.

## Candidate practices

- Identify the file twice: SQLite's `application_id` marks an application file format in the database
  header, while OnePage's transactional identity row carries the independent schema version
  ([SQLite PRAGMA documentation](https://www.sqlite.org/pragma.html#pragma_application_id)).
- Read back settings that are contractual. In particular, opening an existing populated database and
  issuing `PRAGMA page_size=4096` does not convert it, so the Storage Owner rejects any value other
  than 4 KiB. It also enables `cell_size_check` so malformed b-tree cells fail earlier
  ([SQLite PRAGMA documentation](https://www.sqlite.org/pragma.html#pragma_page_size),
  [cell-size checking](https://www.sqlite.org/pragma.html#pragma_cell_size_check)).
- After `FULL`, `IOERR`, or `NOMEM`, do not infer transaction state from the error. SQLite documents
  that these failures may roll back a whole transaction automatically; issue an explicit rollback and
  inspect autocommit state before reusing the connection
  ([transaction error handling](https://www.sqlite.org/lang_transaction.html#response_to_errors_within_a_transaction),
  [`sqlite3_get_autocommit`](https://www.sqlite.org/c3ref/get_autocommit.html)).
- Use SQLite's Online Backup API instead of copying live database files. The Storage Owner advances a
  backup by a caller-supplied page quantum and owns both handles until `sqlite3_backup_finish`, keeping
  each foreground turn bounded
  ([Online Backup API](https://www.sqlite.org/c3ref/backup_finish.html)).
- Keep page cache, lookaside, statement memory, and total SQLite heap visible separately. A negative
  `cache_size` is a suggested kibibyte ceiling, not a preallocated or total-memory guarantee
  ([cache-size semantics](https://www.sqlite.org/pragma.html#pragma_cache_size)).

## Adopt in the verification workstream

SQLite tests allocation failures, I/O failures, crashes, malformed files, and boundary values by
running the real engine above faulting allocators and VFS implementations, then checking both atomic
old-or-new state and `integrity_check`. OnePage should follow that shape in issue #12: keep the current
semantic commit-boundary hooks for precise Harness assertions, then add a test-only VFS and fresh
process sweep rather than depending on SQLite's unstable `sqlite3_test_control` interface
([How SQLite Is Tested](https://www.sqlite.org/testing.html),
[`sqlite3_test_control` stability warning](https://www.sqlite.org/c3ref/test_control.html)).

TigerBeetle reinforces the reusable parts of this approach: deterministic replay, fixed startup
capacity, bounded batches, and seeded storage-fault simulation. Its replicated checksum-and-repair
model is deliberately not adopted by OnePage's single-host V1; SQLite's documented storage assumptions
remain part of OnePage's fault model
([TigerBeetle architecture](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/ARCHITECTURE.md)).
