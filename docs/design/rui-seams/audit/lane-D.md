# Lane D: Store (MySQL series): design audit, 2026-11-05

Scope: landed #862 5e-2b, #863 5e-3, #870 6a, #871 6b, #873 6c, #885 6d, #914 7a, #918 7b, #924 8a, #929 8b, #933 8c, #951 8d, #950 K2b (its "no runtime DELETE" part), #940 and #961 (Store side); open #963 PR 9 (head 1e770265b). Measured against ledger D82-D93, D114, D136, D155-D158, D173, D175, D183, D200-D204, D211, D215 and the approved Store design (rui-db-adapters/final/rationale.md). Line numbers are origin/main (98d5acd97) unless marked "PR 9".

## Findings

1. **Start error codes differ from the ledger's list.** PR 9 `src/launch_frame.zig:24-33` and `:399-410` (PR 9); D136, D156, D86.
   - Code: `mysql_version_unsupported` (MariaDB folded in), `mysql_read_only`, `mysql_durability_unsafe` (one code for both variables), `mysql_binlog_unsafe`.
   - Intended: D136 lists one code per refusal: `mysql_version`, `mariadb`, `read_only_replica`, `durability_<variable>`, `binlog_statement`. D156 repeats `durability_<variable>`, and D86 asks for one message naming what to fix. The durability message names both variables, even when only one failed.
   - Severity: **blocks Drift**. This is the code list Drift's operators and the TS client match on.
   - Fix: rename the codes to D136's names. Split `MysqlDurabilityTooWeak` into `durability_innodb_flush_log_at_trx_commit` and `durability_sync_binlog`, and split MariaDB out of `mysql_version` (`src/store/engine/mysql_refusal.zig:15-25`). If the new names are preferred instead, log them as a D-line that replaces D136.

2. **The DB team has no way to get a MySQL migration file.** PR 9 `src/cli.zig:248` and `ARCHITECTURE.md:1293` (PR 9); D203, D204.
   - Code: `rui store schema --engine mysql` prints only the full DDL. Forward steps exist only as the comptime `schema.mysqlMigration(from)`, which nothing outside CI calls.
   - Intended: D204 says that on MySQL the DB team applies the from-to file. D173 says every merge ships a release, so the next format bump after Drift installs will need that file.
   - Severity: **blocks Drift** at its first upgrade.
   - Fix: add `rui store schema --engine mysql --from N`, which prints `mysqlMigration(N)` and every later step, and refuses when N is below `migration_baseline`.

3. **TCP to MySQL accepts only system-trusted TLS.** PR 9 `src/mysql_url.zig:86` and `ARCHITECTURE.md` "TCP verifies TLS with system trust".
   - Code: there is no CA option and no TLS setting in the URL. Query strings are refused.
   - The ledger records no TLS decision. D200 names RDS and Aurora as likely hosts, and their certificates chain to the Amazon RDS CA, which is not in system trust stores.
   - A failed TLS check or login maps to no start error code (`mysqlRefusal` returns null), so Drift sees a bare `RuiUnavailableError`.
   - Severity: **blocks Drift** if Drift's MySQL is RDS or Aurora; design debt otherwise.
   - Fix: add an optional `storeCaFile` to the launch frame, mirroring `--provider-ca-file`, and log it as a D-line. Give connect, TLS and login failures a start code such as `store_unreachable` or `store_login_refused`.

4. **Losing the connection exits the Host instead of reconnecting.** `src/store/engine/Mysql.zig:87`, PR 9 `src/server.zig:633` and `ARCHITECTURE.md:3345` (PR 9). Rationale "Decided 2026-10-31: reconnect and carry on".
   - Code: every MySQL fault, connection loss included, fences the Host, which writes `store_fenced` and exits. The TS client restarts it.
   - The design's settled call is to reconnect, retake the lock, check the epoch and settle by `commit_seq`. The 8e unit in impl/pr8-design.md defers that work, but no ledger or build-plan line records the deferral. After a crash the restart can hit `store_locked` until MySQL drops the dead session's GET_LOCK, which can take up to lockWaitMs (D183).
   - Severity: design debt (unlogged decision).
   - Fix: log "PR 8e reconnect is deferred; until it lands a network fault exits with `store_fenced`" as a D-line, and add 8e to the build plan.

5. **The ledger still says "PR 7 Store thread".** `src/store/queue.zig:1-7`; D91, D94, D215, build-plan "PR 7 Store thread".
   - Code: 7a and 7b built a combining queue. A free Store runs on its caller, a busy one queues, and the holder drains the queue, so no thread is added. This meets D94's "no new Host threads", and the 11-04 measurement (+78% CPU per model call for a thread hop) backs it.
   - Intended: the ledger and build plan still describe a Store thread. There is no Store thread in the code, so the brief's "Store thread approved as the one new Host thread" no longer holds.
   - Severity: design debt (ledger).
   - Fix: add a D-line that replaces D91's "PR 7 Store thread" with "Store queue: run on the caller, the holder drains queued writes, one COMMIT".

6. **Ids still come from `max()+1` on MySQL.** `src/store/Store.zig:1698-1701` (`Identity`, "maximum plus one"); rationale "never max+1".
   - Divyansh's 11-05 00:47Z "keep it simple" call keeps `max()+1` until several Hosts share a Store. That call is in team memory only, not in the ledger.
   - Severity: design debt (unlogged).
   - Fix: add a D-line recording it, with "per-Host ranges arrive with multi-Host" as its trigger.

7. **Replica refusal checks only `read_only` and `super_read_only`.** `src/store/engine/mysql_refusal.zig:23`; D86.
   - A replica without `read_only` set opens. This was knowingly narrowed while the REPLICATION CLIENT grant is pending, but the narrowing is unlogged.
   - Severity: design debt.
   - Fix: log the narrowing, or after the grant check `performance_schema.replication_connection_status` in the same facts SELECT (`mysql_open.zig:45`).

8. **"Which engine?" is answered four different ways outside the Store.** PR 9 `src/server.zig:633`, `:1408` (`host.store.engine == .mysql`), `src/platform.zig:146` and `src/client.zig:522` (`paths.database.len == 0`), and `src/platform.zig:209-219`, `src/bash.zig:314` and `src/cli.zig:562` (`isOpaqueStoreId`: 32 hex characters, plus `RUI_RUNTIME_DIR`).
   - The Host reads the Store's engine union field directly (leaked abstraction), and the CLI guesses the engine from the shape of a string.
   - Severity: design debt.
   - Fix: decide the engine once. The Host knows it from the frame (`Frame.Store` tag), and `Paths` can carry an explicit `kind`. `Store` exposes `isNetwork()` or a `kind()` instead of its `engine` field.

9. **`RUI_RUNTIME_DIR` and the empty-store probe are new and unlogged.** PR 9 `src/environment.zig` (`runtime_dir`), `src/platform.zig:217`, `src/server.zig:1408`; D114, G10.
   - Code: Bash and the CLI route an opaque id through a new environment variable, and `host_info` accepts `store:""` on MySQL so a client can discover the id.
   - D114 names only `RUI_STORE`. With #961, `--store <other MySQL id>` resolves to the sender's own runtime directory and is refused with `wrong_store_identity`, so a cross-Store send works only on SQLite.
   - Severity: design debt (unlogged new env var, a wire special case, and a cross-PR mismatch).
   - Fix: log both. Either route by an id-to-runtime-directory map, or state in #961's docs that a cross-Store send by id is SQLite only.

10. **The Store's identity is stored three times on MySQL.** `src/store/engine/mysql_open.zig:52` (`DATABASE()` must equal the URL's database), `:85-86` (`store_selector` row = database name), `:88-89` (`store_id`), plus the GET_LOCK name (`:45`); D158.
    - A dump restored under another database name (D88) refuses with `WrongStoreIdentity`, which has no start code (`mysqlRefusal` returns null).
    - On SQLite, 8b writes a `store_id` (`schema.zig:1646`) that nothing reads, because D158 keeps the path selector there.
    - Severity: design debt.
    - Fix: on MySQL, let `store_id` be the identity and drop the `store_selector` row and its check. Either use or drop SQLite's `store_id`.

11. **Two engine bootstraps spell the `store_meta` seed separately.** `src/store/schema.zig:1646` (SQLite `randomblob`) and `src/store/engine/mysql_open.zig:105-121` (MySQL: Zig hex plus `insertMeta`, written at first open).
    - The meta keys, the id format and the `store_owner` seed live in two places.
    - Severity: nit.
    - Fix: one `schema.metaSeed(dialect)` that renders both.

12. **`store_schema_behind` covers four different cases.** PR 9 `src/launch_frame.zig:403`; `mysql_open.zig:78-91`; D203.
    - It also covers a Store ahead of the build (`found > schema_version`, for example after rolling back Rui following a migration), a wire-version mismatch and an unknown meta key. The message "does not match" hides which one happened.
    - Severity: nit.
    - Fix: add `store_schema_ahead`, logged, or give each case its own static message.

13. **The content chunk layout is computed in two places.** `src/store/access.zig:436-448` (`if engine == .mysql`, literal `128 * 1024`, `insert_chunk`) and `src/store/engine/Mysql.zig:407-415` (`writePayload`, `content.chunk_bytes`).
    - The rationale says the engine owns the bytes, and `Engine.writePayload` already exists for every engine, but Access chunks for MySQL itself.
    - Severity: design debt (same fact in two places, behind the wrong side of the 8a seam).
    - Fix: Access always queues a payload entry, and each engine's adapter splits it.

14. **Other engine branches above the seam.** `src/store/access.zig:327`, `:339`, `:560` (pass and borrow checks by engine), `src/store/Store.zig:872` (`revokeActionSender`: `.single` on SQLite, a write Access on MySQL), `src/store/Store.zig:1816` (identity loading), and PR 9's `mysqlStoreId`, `mysqlDoublewrite`, `mysqlDiagnostic` and `sqliteDiagnostic` on `Store`.
    - The 8a seam is real: it has two adapters, `engine/Sqlite.zig` and `engine/Mysql.zig`. But "binds in place" against "batches" is asked at each call site.
    - PR 9's `mysqlStoreId` (`Store.zig:246`) reads `engine.mysql` without checking which engine is open.
    - Severity: design debt.
    - Fix: one engine query, `e.batches()`, inside Access. Make `.single` fence on a network engine inside Access. Give the Store engine-neutral accessors `storeId()` and `diagnostic()`.

15. **Two open paths where the design had one.** PR 9 `src/store/Store.zig:174-207` and `:211-240`; rationale "Startup gains a target".
    - `openWithOptions` and `openMysql` repeat the ring, ids, queue, identity load and catalog steps, and the server picks between them (`server.zig` `openStoreForHost`).
    - Severity: design debt.
    - Fix: `open(io, target: union{sqlite, mysql}, selector, options)` with the shared tail written once.

16. **Two full `host_info` reply shapes for one optional field.** PR 9 `src/protocol.zig:2904` and the `openapi.json` `HostInfoReply` `anyOf`; D200.
    - Severity: nit.
    - Fix: one shape with an optional `innodb_doublewrite` hole, as `HostInfo` already declares it optional.

17. **The D202 gate covers only rsql.** `src/store/rsql.zig:550` refuses a typed DELETE outside tests, and the rsql grammar admits no DDL, which is correct.
    - The hand-written SQL in `engine/mysql_open.zig:121` and `engine/mysql_content.zig:77` is outside the gate. It is all INSERT, UPDATE and SELECT today.
    - Severity: nit.
    - Fix: run those literals through the same statement-kind check at comptime.

18. **On MySQL, #940's "confirmed" retirement watches the wrong lock.** #940 `StoreLease.observe` together with PR 9 `src/platform.zig` (`rui.lock`).
    - On MySQL, "confirmed" means the runtime socket lock is free, not that GET_LOCK is. PR 9's own fixture has to wait for GET_LOCK separately.
    - Severity: nit.
    - Fix: document it as socket-only, or have the MySQL Host drop `rui.lock` only after the connection closes.

19. **A MySQL drain limit is written into a domain statement.** PR 9 `src/store/domain/report.zig:2138` (`.take = 2`, with a comment on MySQL's drain).
    - Severity: nit.
    - Fix: acceptable. Note it in the round-budget table so the SQLite round count change is expected.

## Match the design cleanly
- #862 5e-2b and #863 5e-3: typed statements only, and the legacy layer is gone.
- #870 6a and #871 6b: a conformance harness on both engines, and MySQL rendering at comptime.
- #873 6c: live MySQL dialect check.
- #885 6d (D204): per-engine forward steps, enforced at comptime and checked in CI against schema 51.
- #918 7b: group commit.
- #924 8a: the engine seam now has two real adapters (see 13 and 14 for the leaks).
- #929 8b: store id and catalog digest. #933 8c and #951 8d hold apart from the points above.
- Correct: `commit_seq` fence (D87, `engine/Mysql.zig:180`), GET_LOCK named after the database (D158), refusal after the lock and before any write, no DDL on MySQL (D203), and `store_schema_missing` from error 1146.
- #950 K2b: no runtime DELETE (D202), enforced by rsql.
- #961 has no Store-side change (see 9). PR 9's `Frame.Store` union with `mysql_url`, the URL only on stdin, and `runtimeDir/rui.sock` (D175, D211). `store_fenced` is written before exit (D157), and doublewrite is shown, not refused (D200).
