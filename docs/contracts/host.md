# Host ownership and lifetime

[Architecture](../../ARCHITECTURE.md) owns shared guarantees, terminology, and the source map.
[Verification](../../VERIFICATION.md) owns global evidence rules and gates.

## Accepted contract

### Platforms and server lifetime

#### Platform capabilities

Support Linux x86-64 and macOS Apple Silicon through capabilities, not distribution allowlists.
Minimum OS/kernel/libc follows build/API requirements; incompatibility rejects.
Platform-sensitive changes require affected native checks on both supported systems before merge.
Optional cross-compilation of Linux ARM64 and Intel macOS is experimental and does not extend support.
Keep platform memory metrics and unavailable counters distinct.

| Owner | Selected mechanism |
| --- | --- |
| Transport | Rui's own HTTP/2 client on pinned nghttp2 and OpenSSL, with name lookup on short-lived threads and addresses raced by family (Happy Eyeballs, RFC 8305: families alternate, the next attempt starts after 250 ms or as soon as one fails, and with two in flight the oldest gives way). `https://` origins tunnel through the `http://` proxy that `https_proxy`/`HTTPS_PROXY` names (a set lowercase name decides, even empty), read once when the transport starts, with `Proxy-Authorization: Basic` from the proxy URL's credentials; loopback and `no_proxy`/`NO_PROXY` hosts (`*`, names with their subdomains, IP addresses, CIDR ranges; no ports) connect directly; a proxy's 407 and 403 are distinct causes; an `https://` or other proxy scheme fails a provider-serving Host's startup before readiness, and only disables models.dev discovery on a provider-free Host; HTTP/1.1 and HTTP/3/QUIC are absent. Use Apple SecTrust on macOS; on Linux, OpenSSL's `SSL_CERT_FILE` / `SSL_CERT_DIR` when set (an unloadable path fails, never falls back), else the host's hashed certificate directory (`/etc/ssl/certs`, then `/etc/pki/tls/certs`) when it holds a readable subject-hash entry, else the host's CA bundle; a directory's roots are read only when a peer's chain names one, so a Host parses the few roots it uses rather than the whole bundle (about 0.7 MB on Linux), and a damaged root fails the first connection that needs it as `untrusted_peer` rather than startup, while a missing store still fails startup (Divyansh, 2026-11-12); and explicit CA-file configuration (`--set network.caFile=PATH`), which takes precedence, where needed. Missing trust/capabilities fail; never disable verification. Transport owns initialization, resolver lifetime and cleanup. |
| Storage | Bundle pinned thread-safe SQLite with single-owner access and native VFS. Use local filesystems; network/shared-mounted Stores are unsupported. Enable macOS fullfsync. |
| Credentials | One Rui-owned file on Linux and macOS. Check ownership/access, preserve account binding and atomically persist refresh; do not fall back to Codex CLI state or another backend. The file is readable by same-user programs, including authorized Bash; credentials never enter semantic data, logs or child environments. |
| Files/processes | Configurable disk-backed scratch and installed Bash with optional executable path. Report known memory-backed scratch as incompatible with disk-first guarantees; unknown backing is a deployment assumption. A target-header C shim supplies non-consuming child observation and queued-pipe-byte counts; lifecycle policy remains in Zig. Process-group cleanup promises neither detached-descendant containment nor rollback. |

#### Exclusive Store ownership

On SQLite, `rui host serve` acquires an exclusive OS-held Store lock before recovery, stale-endpoint reclamation or dispatch, retaining ownership until no dispatch or semantic writes remain possible.
Locking and pathname Unix-socket discovery share one bounded canonical Store selector: equivalent supported paths cannot create two owners.
The canonical selector is at most **492 bytes**, so its 504-byte `/rui.sqlite3` database path plus SQLite's eight-byte journal suffix fits the pinned Unix VFS 512-byte pathname bound.
A longer raw CLI alias remains supported when the OS resolves it to a selector within that canonical bound; canonical overflow rejects before the Store lock, SQLite database or socket has an owner.
Do not use Linux abstract sockets.
Close-on-exec prevents descendants inheriting ownership.
PID metadata, socket existence, timeout and absent results prove neither ownership nor effect termination.

Protect socket/parent directory; validate Store identity/wire version before mutation.
Reclaim only the expected stale socket after ownership.
Unavailable/inaccessible/competing owners reject.
Clients never auto-start or access SQLite; disconnects/timeouts do not cancel work.

A MySQL Host starts from saved `DIR/host.json` settings with `rui --store DIR` or `rui host start --store DIR`, or from a foreground settings document with `rui host serve --settings -` or `--settings FILE`.
The
document's `store.mysql.url` is `mysql://USER:PASSWORD@HOST[:PORT]/DATABASE`; TCP verifies
TLS with system trust unless its sole query option is `ssl-ca=<path>`, a nonempty absolute PEM CA-bundle path (percent escapes allowed, at most `PATH_MAX - 1` decoded bytes) trusted exclusively; unknown or repeated keys, fragments, relative or empty paths, `ssl-ca` on a Unix socket and any verification-disabling option are refused (D224).
A Unix socket is an absolute path in place of HOST,
usually percent-encoded (`%2Fvar%2Frun%2Fmysqld.sock`).
User, password and
database components accept percent escapes.
An explicit private `interface.dir` selects `interface.dir/rui.sock` (D211).
Without it, MySQL uses a short private per-user interface directory derived from the canonical Host directory, so long Host directory names do not lengthen the socket path.
Host admission, the starter and directory-based clients share that placement derivation; clients read saved sources without resolving the MySQL login.
Unsaved Store/interface placement on a detached start is refused when it differs from the saved placement; save it with `rui host set` so subsequent clients can find it.
The URL travels as a literal only in stdin; a document file names a secret source for it (an environment variable or a private file), and it never appears in argv or
refusal messages.
Parsing wipes all JSON allocations, including failed
parses; the connection handshake wipes its authentication buffer as soon as
login finishes or fails.
The Store keeps its own copy of the login in Host memory for the Host's life, wiped when the Store closes, so it can reconnect.
The connection loads TLS trust at open and retains it across reconnects without borrowing or reloading the CA path; an unloadable `ssl-ca` file refuses startup with `mysql_unreachable` and a static message that never names the path.

On MySQL the `store_owner` row owns the Store: open raises its `epoch`, and every write transaction first advances `commit_seq` only where both match what this Host last saw, so a Host that lost the Store fails its next write.
`GET_LOCK` only refuses early a second Host on the same database.
One MySQL server is the one writer: multi-primary topologies, where `GET_LOCK` is local to one member, are not supported. Reclaim after a lost COMMIT reads `commit_seq` as final once it holds the lock, so on such a topology it may rerun a batch an old session still commits; the fence then stops the duplicate and the Host fences.
Every message the Host sends starts with its session settings, so no message relies on settings an earlier one left on the server connection.
There is no `host.lock`: the runtime's
`rui.lock` reserves only its socket, preventing two different Stores from
reclaiming each other's endpoint.
Scratch and diagnostics live in
`runtimeDir`.
Requests use the persistent `store_meta.store_id` (32 lowercase
hex characters), never the URL or runtime path. This durable id survives a
restore to a differently named database, but canonical identity is validated
separately: MySQL requires a saved `store_selector` to match the selector passed
at admission (the database name for a launched Host). A mismatch or malformed
saved id refuses startup before any write. A missing selector is repaired
atomically with ownership acquisition without changing an existing durable id.
Restoring under another database name therefore requires explicitly updating
the saved selector to that name; the durable id remains unchanged. SQLite still
validates its saved id and canonical directory selector.
An initial MySQL
`host_info` probe may send an empty `store` to discover that id; every other
request must match it.
Bash gets `RUI_STORE` as the selected Host directory when its saved placement
reaches this endpoint. CLI peers resolve that local route separately from the
wire Store identity used in sender Addresses and captures. Saved placement is
read again by later clients; pause the Host before changing Store or interface
placement. An unsaved foreground placement retains its legacy Store-identity
route and, for MySQL, the non-secret `RUI_RUNTIME_DIR` socket hint. An opaque id
alone cannot launch a replacement Host; a saved Host directory can.
SQLite's database layout and wire identity remain unchanged.

MySQL readiness and `host_status` also report `innodb_doublewrite`, including
`OFF` (D200).
Admission refusals use a single stdout
`{"rui_start_error":{"code":"...","message":"..."}}` line and exit 1:
`store_locked`, `store_schema_missing`, `store_schema_behind`, or a MySQL
start refusal (D222). The existing `store_schema_behind` code has distinct,
bounded static messages for older, newer or malformed numeric format metadata,
a wire-version mismatch, an unexpected metadata key, a catalog mismatch and
invalid identity metadata or connection target. These refusals precede metadata
repair, ownership changes and sender cleanup, and expose no saved values or
connection secrets. They add no public code or Store-format change; MySQL DDL,
backup and forward migration application remain operator-owned:

- `mysql_version`: the server is older than MySQL 8.4, or its version cannot be parsed.
- `mariadb`: the version or version comment identifies MariaDB, separately from an old MySQL version.
- `read_only_replica`: `read_only` or `super_read_only` is ON.
- `durability_innodb_flush_log_at_trx_commit`: `innodb_flush_log_at_trx_commit` is not 1.
- `durability_sync_binlog`: binlogging is enabled and `sync_binlog` is not 1.
- `binlog_statement`: `binlog_format` is STATEMENT.
- `mysql_unreachable`: connection failed, including DNS, TCP or socket connection, TLS trust loading (including the `ssl-ca` file), handshake or certificate verification, or a timeout before login.
- `mysql_login`: the server refused the credentials, authentication method or database access (including server errors 1045 and 1044).

Exactly one admission cause is reported: version/MariaDB first (MariaDB wins
when either version field identifies it), then read-only, then
`innodb_flush_log_at_trx_commit`, then `sync_binlog`, then binlog format.
Thus when both durability variables are unsafe, the flush-log refusal comes first.
Each durability message names only its variable and the required value 1.
Messages are bounded static text, never server diagnostics, host names, users or URLs.
Connection messages describe the failed driver step using Rui's own static text.
A running MySQL Store that fences writes the same envelope with
`store_fenced` before draining and exits 1 (D211).
When the connection is lost around a COMMIT, the Store first reconnects, up to three times a second apart: it ends the old server session with `KILL`, takes `GET_LOCK` again once that session is gone, and reads `store_owner.commit_seq`.
Every write transaction advances it by exactly one, so the value says whether the COMMIT landed.
Landed is success and the Store carries on.
Not landed means nothing was saved: the Store keeps the new connection, gives back the ids the batch took, and runs the batch's writes again once, in order, so its writers never see the loss.
A second loss in that rerun fences, as does a lost read, which may already have streamed part of its answer.
Only when no reconnect succeeds does the outcome stay unknown (`CommitOutcomeUnknown`).
COMMIT is a statement of its message, and reads may follow it in that message; every message sets `autocommit=1`, so they run outside any transaction.
The transaction is saved once COMMIT's own OK arrives: a connection lost before that OK is settled as above, with the reads sent again on the new connection when the transaction landed, and one lost after it, while the reads stream, keeps the commit and fences, and the batch never runs again.
A write that is alone in its batch sends its last writes and its COMMIT as one message.
The fence, and each write whose row count the statement itself does not fix, is followed by a statement that fails unless the count is the expected one; the server runs nothing of a message after a failed statement, so COMMIT never saves past a wrong count.
The batch is then saved and takes no more writes: a write that queued meanwhile opens the next batch.
A batch that runs again commits at its end.
That message also carries the dispatch survey the Host asks for after every commit, as reads after COMMIT: the Store keeps the answer until the Host asks, once, and drops it when anything else commits first.
The write sends that message, and the survey is in it whole or not at all: reads that do not fit after COMMIT are left out, and the Host then asks as usual, as it does when the survey's checks need a second round.
A survey read that fails after COMMIT fences, as it does when the Host asks; the commit stands.

Host information is a read-only, bounded `/v1/host-info` exchange for the canonical selected Store.
A client first probes the existing `host.lock` with a nonblocking shared lock, without creating a Store or lock: no owner means unavailable even if a stale socket exists; an exclusive owner permits a protected socket request.
One absolute probe deadline covers connect, write, first byte, header and full body; ordinary commands retain their separate processing and transfer waits.
The shared response parser accepts only valid bounded HTTP/1.1 headers with one decimal Content-Length, supported Content-Type and wire version; it rejects malformed field names/values, duplicates of consequential fields and unsupported transfer or content encodings rather than interpreting ambiguous framing.
A complete compatible reply from that owner means ready and reports the canonical Store selector, wire version, actual allocated Active Capacity, slots in use, the Host's start time, whether it holds new Turns (`paused`), its Bash capability and each built-in provider's route (`unserved`, `endpoint`, `chatgpt_device`, `key_file` or `chatgpt_plan`). **Slots in use** (`custody_occupied`) counts held custody records, including detached cleanup; it is the value Current reports as `execution.custody_occupied`.
Only the historical wire-13 Host-info profile accepts an absent `chatgpt` route as `unserved`, covering v0.69.1 alongside v0.69.2's complete provider facts. Current wire-18 facts require the provider; the wire-17 and wire-16 profiles preserve the same complete provider facts, and the wire-15 and wire-14 profiles freeze v0.71.0’s and v0.70.0’s complete provider facts; historical normalization serves upgrade/restart discovery and exact-instance activation, never ordinary status or client readiness.
Codex, OpenAI and the existing required identity/control fields remain required; unknown, duplicate and malformed fields still fail decoding.
The start time (`started_at`) is the Host Unix second read once before execution starts; every reply of one Host reports the same value, and like every Host time it orders nothing across clock changes.
Both are read from Host memory, so the reply still never touches SQLite.
Missing credentials do not change readiness.
An owned Store without a usable listener/reply, or with a valid bounded 503 capacity/fencing error, is **owned but unavailable** (possibly starting, busy or draining; not a finer diagnosis); a complete malformed or unknown 503 reply is incompatible, distinct from an access failure.
Lease and socket observations may race replacement, so they are not a durable ownership certificate and must not authorize effects.
After listener closure, only the lease can still establish ownership; without it, completion remains unconfirmed.
No status registry, separate listener, client SQLite, credential access or stale-owner reclamation is involved.

`rui host status [--store PATH]` displays these categories as observations.
Explicit Store selection bypasses private preferences; otherwise it uses the same saved Store or HOME fallback as other destination-bearing commands.
Ready output includes the canonical Store, compatible wire, actual capacity, slots in use, Host start time, capabilities and opaque instance.
Unavailable and owned-but-unavailable never claim that outstanding effects have finished.

`rui host start [--store PATH]` attaches to a ready Host without changing it.
Otherwise it creates only a candidate private Store directory, resolves the canonical selector and launches this executable's `host serve --store DIR` with generic settings assignments in a separate session; the Host reads saved settings and owns automatic provider selection.
Bare `rui`, `host start` and `host serve` all use the product default Active Capacity of 100 unless settings override it; `host start --set execution.activeCapacity=N` overrides it for the Host it launches, and `host serve --set execution.activeCapacity=N` overrides it with caller-owned lifetime.
The Host setting `execution.backgroundAfterMs` defaults to 30,000 milliseconds and applies to every live Host-run Action. It is available in the settings document, generic `--set execution.backgroundAfterMs=N` assignments, and the generated TypeScript Host settings. The TUI uses those Host startup settings; its Session settings do not reconfigure a running Host.
A running Host keeps the capacity it started with, including across Rui upgrades, until it stops and a new Host starts.
When `host start` finds or loses a launch race to a ready Host, it still reports that Host and exits zero; settings apply only to a new Host, never reconfigure the running one, and when the command gave `--settings` or `--set`, stderr says so.
Startup raises only its own soft descriptor limit, up to the hard limit, to fit that capacity.
It never reduces Active Capacity to fit: when even minimum intake cannot fit, startup fails before the Store lease and names the limit to raise.
From macOS's default soft limit of 256, the default Host starts with full intake when the hard limit and OS per-process ceiling cover its full requirement.
Between the minimum and full requirement it starts with reduced intake and unchanged Active Capacity; below the minimum it refuses.

| Platform | Detached launch |
| --- | --- |
| Linux | Double fork with `closefrom`. |
| Darwin | Same-executable helper spawned with `POSIX_SPAWN_CLOEXEC_DEFAULT`, `/dev/null` stdin/stdout, startup stderr and an exec-error channel; the helper creates the detached grandchild. Isolation includes handles above a lowered soft FD limit and does not scan a potentially unlimited hard limit. |

Before final exec, the grandchild changes to `/` to release the launcher's cwd.
Bash still uses its configured Session Workspace.
A close-on-exec pipe reports exec or cwd failure; abnormal helper exit is failure.
A launcher error can occur after the Host executes, so the CLI leaves execution and readiness unconfirmed and prints an exact Store-specific status command.
The launcher normally reaps its helper and restores inherited SIGCHLD disposition, including when SIGCHLD was ignored.
A disconnected readiness pipe records startup failure instead of terminating on SIGPIPE; only the writing thread masks that signal.

Host startup establishes default SIGCHLD handling with `SA_NOCLDWAIT` cleared before Store ownership or child launch, including for direct `host serve`.
This preserves waitable child identities until their signaling owners retire.
It also catches SIGINT, SIGTERM and SIGHUP before Store ownership: each one is the same asked stop as `host-stop`, applied on the intake loop, which the handler only wakes; a second one while stopping changes nothing. Bash children start with every signal at its default.
Host startup then owns lease acquisition, recovery and readiness.
Competing launchers may create candidates, but one holds the lease.
All probe the winning Host for up to ten seconds from readiness-check start, without killing an unconfirmed owner.
A Host that migrates its Store announces the migration's start and end on its startup channel, and the launcher that started it runs no deadline between the two, because the backup takes time proportional to the Store's size; ten seconds follow the end (`HostStartupWait`).
The interactive launcher shows the start announcement as it arrives.
A launcher that still has no readiness reports `host_starting`, a wait, never an internal fault.
Each Host-info probe uses the lesser of remaining readiness time and its one-second response deadline, including connection.
These readiness deadlines are separate from [ordinary transport inactivity](cli.md#client-transport-and-observations).
Credentials are not required for managed readiness.
Timeout reports uncertainty, not effect failure or cleanup.

The CLI owns the complete terminated managed-launch argv; the native adapter borrows it through final exec/error handoff, including the Darwin early helper.
Both platforms inherit the caller's environment without filtering or replacing it; ordinary macOS Host allocator defaults still apply at `host serve` startup.
The adapter prepares only helper framing before spawn/fork, not Store/provider/preference policy.
It closes unrelated descriptors only in the detached child and preserves the caller's descriptor flags.
Exec-channel closure establishes only successful exec, never Host readiness or Store ownership.
A separate startup stderr pipe carries early errors and their exit status to the parent, including failures before diagnostics exist.
The parent retains at most 8 KiB until readiness or failure; it reports channel closure without readiness explicitly.
Lease losers continue probing the winning Host.
After attachment the reader closes and later detached stderr remains optional.
Unsupported Store errors name the Store, observed and supported schema versions, and compatible-build or backup/fresh-Store options; refusal never migrates or deletes work.

After the lease, the serving Host writes allowlisted startup phase records under its private `diagnostics/` directory, closing the writer before normal service.
This startup-only append writer uses 4 KiB maximum records and up to 16 private files of at most 8 MiB each (128 MiB total), deleting the oldest before growth and repairing an incomplete tail on restart.
Diagnostics never authorize recovery or contain request/credential bytes.
A failed diagnostic write disables further diagnostic writes without affecting service; failure before the lease or writer initialization may leave no record.
Successful automatic Host start/attachment is silent; explicit `host start` retains readiness/diagnostic receipts.
Startup uncertainty points to the diagnostic location, if present.
Direct `host serve` requires the caller to supply open stdout at launch; Rui does not establish whether fd 1 was open before process initialization.
If the readiness write fails, the Host records failed startup rather than claiming ready.
Managed launch supplies `/dev/null` stdout and observes readiness through the protected Host-info exchange.
This is not the later general diagnostic export/history owner.

Each serving Host generates a random 128-bit opaque instance identity before advertising readiness.
It changes on replacement and has no PID or recovery authority.
The Host accepts an optional canonical lowercase-hex `X-Rui-Host-Instance` header on protected exchanges; after reading and validating the bounded request, the receiving Host compares it with its own identity **before** dispatch and returns `host_instance_changed` without mutation on mismatch.
Omission preserves existing clients, except for Host stop.
A caller retaining this identity must still use the ordinary Store selector, wire checks and command idempotency/recovery rules.

On shutdown, listener closure prevents new exchanges and the intake owner retires requests not yet handed to local work, including incomplete headers and uploads.
It retains handed-off work, report/content delivery and failed reclamation until their owners retire.
The execution owner independently drains every process, transport and retained-cleanup owner.
Only after both populations drain may the Store connection close and the OS-held lease release.
These owners are the release proof; there is no parallel shutdown registry.
Optional retained output has no independent lease authority after producer aliases and execution custody retire: ordinary retention cleanup runs while the Host lives, and any named leftovers are handled by the startup policy below.

#### Infrastructure shutdown

Infrastructure shutdown promptly prevents new effect launches, interrupts supported effects and safely collects evidence while retaining resources until cleanup is safe.
This is a dispatch fence followed by cleanup, not a promise to let admitted model work finish.
It neither awaits model completion nor invents user stops.

The existing execution owner first initiates shutdown across its occupied slots: suppress unlaunched work, cancel provider streams and request launched Bash termination.
It then incrementally services Bash retirement and due retained cleanup in shared passes.
A cancelled provider stream releases its custody at once, so a peer that still holds its response cannot delay shutdown.
A failed reclamation retains its resources and custody; it cannot prevent the execution owner from requesting another effect's termination or servicing independent cleanup, regardless of admission order.
Transfer storage remains pointer-stable while its stream is held by the Client.
Provider cancellation releases local custody without ordinary model settlement; launched Bash keeps its existing infrastructure-shutdown evidence and settlement policy.
No second scheduler, shutdown registry or generic effect interface owns these transitions.

If the operating system cannot establish physical effect retirement or resource reclamation, shutdown has no completion deadline.
The Host remains in a low-frequency blocked drain with its Store lease, execution storage and custody intact.
Forced process termination instead loses custody without confirming cleanup.
Restart then uses committed uncertainty and owned-leftover cleanup; it preserves recovery allowance.
Remote effects and duplicate model cost remain possible.
Orphan tools may retain each bounded unlinked stdin file until exit; replacement Hosts cannot reclaim it, and no aggregate scratch bound spans dead-Host generations.

A Host whose settings give `interface.lifetime` as `stdin` (the TypeScript client's default with `rui host serve --settings -`) is the exception: its shutdown is bounded.
The program that starts it writes one frame to its stdin, a 4-byte big-endian length and then UTF-8 JSON naming `v` (1), the Store directory, the OpenAI key provider `{kind: "openai_key", baseUrl, key, caFile?}`, the `runtimeDir` that holds its socket `rui.sock`, and optionally `activeCapacity`.
The settings frame overlays defaults and saved settings; later `--set` assignments override its leaves.
The optional `network.caFile` names a PEM file trusted exclusively for provider transport, on macOS as on Linux; omitted or null uses system trust.
A supplied `caFile` must be a nonempty UTF-8 path without NUL bytes and shorter than the platform's path limit; a relative path is relative to the Host's working directory (a Host started by bare `rui`, `rui host start` or upgrade runs in `/`, so those starts take a path typed relative on their command line from the caller's directory and refuse any other relative path), and an unloadable file or failed verification never falls back to system trust.
The optional `presets` object maps at most 64 names (1–64 bytes of `[a-z0-9_-]`) to complete agent specs, checked by the shared agent-spec parser and held only in Host memory (D22, D112).
A `start_agent` call may name a preset and override its fields, but still refuses provider or Workspace fields, including those supplied by the preset (D221).
The key stays in memory only, never on disk, in argv or in the environment.
With `interface.lifetime` `stdin`, stdin then stays open and carries nothing; when it closes, the Host stops as `host-stop` does, and an alarm ends the process 10 seconds later if the drain has not finished, which is a forced termination as above.
A refusal at open is one stdout line `{"rui_start_error":{"code","message"}}` with code `settings_invalid`, `invalid_preset` or `store_locked`, then a nonzero exit status set by the cause, 2 for `settings_invalid`.

`rui host pause [--store PATH]` observes the ready Host once, then sends a bounded protected `POST /v1/control/host-stop`.
It requires the observed `X-Rui-Host-Instance`, validated before fencing.
A lost reply prints an exact retry command retaining that instance.
Matching in-flight retries may receive the same acknowledgement; a replacement returns `host_instance_changed` without action.

Pause affects all work in the selected Store; it records no Session stop, so a later Host resumes that work from committed facts.
Acknowledgement means a fence was requested, not that effects retired, connections drained or the lease released.
So after acknowledgement pause probes only the lease (never the Host) for up to `product_defaults.host_shutdown_seconds` (10): a free lease reports `"retirement":"confirmed"`; a lease still held then reports `"unconfirmed"` and stderr says a new Host can start once `rui host status` reports unavailable.
Confirmed retirement means the old Host let go of the Store; it reports nothing about cleanup progress.
A missing/disconnected listener or timeout leaves completion unconfirmed.
Host pause adds no PID signal, force escalation, Session stop or separate shutdown authority.

Holding new Turns is a different control, answered from Host memory like `host_info`: `POST /v1/control/host-pause` takes `kind:"host_pause"`, `store` and `paused`, sets whether this Host holds every new Turn, and replies `host_pause_reply` with the state now in force; repeating it changes nothing (D193).
While held, Messages are still admitted and queue, running Turns go on through their tool continuations, retries and Messages that join them at an input boundary, and no waiting Message starts a Turn: model admission selects only a Session whose open Turn takes input at its next model call.
Clearing it lets them start in the usual order at the next admission pass, which reads the flag beside the commit generation, so a resume needs no commit.
The flag is not saved: a Host starts with it clear, and a later launch option can start one held.

Peer collaboration has no Rui-owned group lifecycle.
Operators compose ordinary Session stops over known addresses or stop the entire selected Host, including unrelated work there.
Session stop leaves the address reusable; a later peer Message can start new work.
Iterating Session stops is not an atomic group fence.
Host shutdown preserves saved Sessions, history and pending input without inventing Session stops.
Explicit Host restart performs ordinary recovery and may resume saved eligible work.
No swarm registry, paused-Session phase, mandatory Host per collaboration or cross-Host containment is added.
A Session's starter (`first_message.sender`) and its latest Message from a person or script are read from that Session's own rows.
A lead checks its delegates with ordinary Session listing and inspection.


## Required evidence

### Interface and owner checks

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| [Store ownership](#exclusive-store-ownership) through listener failure | `admission_integration.sh` (`InjectedListenerFailure`) | A fixed sleep is not ownership evidence |
