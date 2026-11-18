# Diagnostic records and stderr

[Architecture](../../ARCHITECTURE.md) owns shared guarantees, terminology, and the source map.
[Verification](../../VERIFICATION.md) owns global evidence rules and gates.

## Accepted contract

### Diagnostics

#### Shared optional stderr

All Host warnings and opt-in traces share process-local, try-only custody of stderr.
One process-wide atomic byte owns custody and records whether optional borrowing remains enabled.
Contention drops the diagnostic without waiting for a logging mutex or a queue.
Warning formatting uses one bounded 1,024-byte buffer; the mechanism adds no heap allocation, worker or queue.
Traces retain their existing fixed `ResponseBuffer`, per-Host sequence and sticky atomic loss fact, with no blocking trace mutex.
A dropped, partial or failed trace marks loss; later success never clears it.

The narrow OS boundary reads stderr flags and, when needed, temporarily enables `NONBLOCK` for one bounded write.
It does not wait for output credit or retry a partial write.
Already-nonblocking stderr needs no flag toggles.
Every attempted enable is followed by an attempt to restore the saved flags, even when enabling reports OS failure.
Failed restoration disables further optional borrowing process-wide.
It neither claims that the flags were restored nor fences canonical work.
This mechanism adds no SIGPIPE owner.

Required stdout readiness is outside optional diagnostics.
Startup acquires exclusion immediately after the Store lease, before continuing startup diagnostics or execution writers, and retains it through readiness delivery or failed unwind, including when fd 1 and fd 2 alias the same open file description.
Execution writers can run during readiness but drop optional output rather than borrow flags.
A startup diagnostic-file failure retains its error for a best-effort notice after successful readiness.
Optional stderr loss cannot change canonical settlement, fence authority, wake service or retained cleanup ownership.

Custody coordinates Rui's process-local writers, not external aliases of the borrowed open file description.
External aliases can observe temporary flags; borrowing assumes no uncoordinated external flag mutation.
Restoration is not guaranteed after an OS restore failure or abrupt process death.
`NONBLOCK` avoids waiting for pipe or socket credit, but does not universally bound filesystem or device syscall latency or descheduling latency.

The persistent diagnostic-file writer remains a separate owner under [diagnostic records and export](#diagnostic-records-and-export).
The single conversation frontend retains its [formatting and restoration contract](session-ui.md#staged-persistent-input); optional notices use this same narrow stderr boundary rather than a second frontend mechanism.
This correction is neither acceptance nor attribution of historical Activity failures.

Native integration checks can opt into a private inherited observation pipe, separate from optional stderr.
The fixture owns its reader before readiness and through Host reap.
The Host owns its nonblocking write descriptor through connection, execution and capture-writer joins, and excludes it from effect exec.
Each selected owner boundary attempts one atomic record of at most 512 bytes.
There is no retry, writer lock, queue or reader acknowledgment.
Backpressure, closed output or encoding failure invalidates evidence rather than delaying classification, settlement or cleanup.
This adds no public Host operation or signal owner.
With observation disabled, normal descriptor, synchronization and clock behavior is unchanged.

Observations retain native awake-clock timestamps, exact subject identities and handler-local control times.
Native phase and subject select evidence before optional trace construction or decoding.
Unselected diagnostics do not enter observation custody or mutate sequence/loss state.
A scope-local handle retains selected publication custody through construction, decoding, encoding, reservation and the single write attempt.
Failed construction marks sticky loss; native custody retires before optional stderr is attempted.
Atomic sequence reservation is independent of arrival order.
The fixture exposes only complete selected prefixes and rejects loss, duplicate sequences, malformed records and population overflow.
One fixed, fixture-owned unlinked shared mapping retains final sequence, sticky loss and active-publication count through reap, including SIGKILL.
Host closes its backing descriptor during initialization and unmaps after writer joins.
No final pipe write or graceful-shutdown substitution is required.

Ordinary fixture disposal atomically seals publication admission in that mapping, then drains existing publication custody within its original disposal budget before SIGKILL.
A selected attempt increments custody before checking the seal.
A late attempt marks sticky loss before retiring its count and cannot publish.
Interruption before that loss leaves active custody visible.
Successful sealed disposal establishes no outstanding publication handle and no capability to admit a successful new publication.
It does not prove runtime-owner quiescence or replace the fixture's independently complete required endpoint populations.
Intentional crash tests remain unsealed.
After reap, both paths validate exact count, zero loss, process/run identity and zero active publication custody; sealed disposal also requires the seal to remain set.
Required owner populations still need every specified endpoint within their original budgets, including before publication custody begins.
A missing final endpoint cannot be inferred from sequence continuity or sealed admission.
Disabled observation adds no normal behavior.
The finite plans and storage bounds belong to [Verification](#native-owner-observations), not to a persistent runtime registry.

#### Diagnostic records and export

Use one bounded append writer for newline-delimited diagnostic records with identity, timing, classification and available versions.
Rotate oldest closed files before growth; framing/active file count.
Preserve mandatory fields, mark optional-text omission, or omit a record that cannot fit.
Reject a cap unable to fit one record per file.
No age-based expiry, compression or separate diagnostic DB.
Restart preserves records, drops incomplete tail, and prunes reduced caps before growth.
Per-record fsync is unnecessary.
Failed write/deletion stops or drops diagnostic writes with bounded notice, never semantic failure, false reclaimed space or a RAM backlog.
After readiness the Host keeps this writer open, because a detached Host's stderr is discarded.
The call that moves dispatch to `fenced` or `stopping` appends one record classified by that phase, naming the failing phase and error, under the lock that orders the transition; repeated fences and fences before readiness add none.

Raw provider bytes of failed model Attempts are kept as separate private **failed-response records**, not as chunks in these files.
Before it settles a failure and disposes the capture, the execution owner copies the same capture it classified into `diagnostics/failed-responses/` (directory `0700`, files `0600`).
This covers an HTTP error body, a rejected 2xx body (parse, completeness, schema or envelope rejection) and the bytes received before a transport or local capture failure.
It never re-requests.
Each record is an exact body file and a JSON metadata file named `response-<sequence>-<Operation>-<Attempt>`.
Metadata holds the Turn, Operation and Attempt, the saved failure code and bounded diagnostic (typed reason, stage and byte offset), HTTP status, provider request ID, captured and retained byte counts, the retained bytes' SHA-256, how the transfer ended and a status.
`complete` requires a complete transfer with every byte retained.
A body cut to its first 16 MiB, or an interrupted or failed capture, is `partial`.
An unreadable or unwritable body is `omitted`, with its reason and no body file.
Successes and transfers that received no bytes add no record.
Before growth the writer deletes its interrupted temporary files, then deletes oldest records until the new body plus an 8 KiB metadata reservation fit 64 MiB and 256 records.
It deletes only canonically named record files in that directory; an entry it cannot delete fails that retention rather than claim the space.
Retention is best effort: a fault leaves at most an optional stderr notice and never changes settlement, retries, custody or cleanup.
Records never authorize recovery or continuation, contain no request, header or credential bytes and are never exported automatically.
Bodies can contain private prompts, code, tool arguments and continuation.

`rui session inspect --store PATH --session REF --operation ID --attempt N --failed-response body|metadata` exports one retained failed-response stream through the existing protected Host connection.
The Store authenticates the Session, Operation and admitted Attempt before reading diagnostics.
The command excludes `--profile` and writes only exact stored bytes to stdout, with no body decoding, metadata formatting or added newline.
Partial bodies export their retained prefix.
Omitted bodies fail explicitly while their metadata remains readable.
Missing, evicted, ambiguous or invalid records fail before payload delivery, with stderr diagnostics and nonzero exit.
Body capture verifies the stored length and SHA-256.
Each invocation is independent and makes no provider request or change to canonical records, retention or write timestamps.
Ordinary filesystem access-time behavior is unchanged.

Failed-response export captures bounded windows into ordinary charged report scratch before successful delivery.
Source handles close between windows so slow delivery cannot pin deleted records.
Source or metadata failure releases capture ownership without fencing canonical state.
Scratch failure is explicit.
As with ordinary Session reports, an unconfirmed scratch unlink fences dispatch and stops the Host rather than accumulate uncharged names.
Startup owns their cleanup.
These failures never change the saved model failure.
A delivery failure can leave a partial destination.
Diagnostics cannot authorize effects or replace accepted/private continuation; absent detail may require reproduction.
No automatic upload exists.

General diagnostic-log export remains unimplemented.
Export recent complete records in bounded turns into charged scratch, recording cutoff/rotation gaps.
Close source handles between turns so slow export cannot pin deleted logs.
Scratch failure is explicit.

The append writer alone mutates diagnostic files.
Partial writes leave incomplete records for tail repair/chunk-completeness handling.
Export capture/delivery uses ordinary client capacity and report-scratch ownership, including failure release after pending I/O.
Derive source-handle population from the writer and current bounded export reads, including rotation overlap.


## Required evidence


### Diagnostics

#### Native owner observations

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| Bounded channel, ordering, loss, startup credit, final state | `host_process_test.py`, `'private owner observations'` | Discover via `src/tests.zig`. Startup credit covers one inspection cohort, not a whole plan |
| Cleanup custody retires before publication | `'cleanup publication follows'` | Reversed retirement must fail. Not lease release |
| Receipt versus publication retirement | `prove_intentional_crash_retirement`, `prove_observation_disposal` | Crash paths stay unsealed; ordinary teardown seals |
| No-launch crash cut | `bash_integration.py` `prepared-before-handoff`, `prove_gate_broadcast` | Released gate must fail. Marker absence and publication retirement are not evidence |
| Required stop receipts | `prove_required_receipts`, `transport_h2_integration.py` held cases, `terminal_restoration_integration.py stop-receipt` | Single cases are partial |
| Descriptor witness and refusal | `descriptor-capacity-integration`, `prove_capacity_refusal_oracle` | `BrokenPipeError` is not refusal. FD snapshots cannot replace endpoints |
| Readiness drains PTY and notification pipe | `host-launch-integration` (`check_action_ready`) | Keep withheld-credit tests distinct |
| Failure retention: 16 roots, 128 files, 1 MiB/file, 16 MiB, 3 days | `tests/ci/test_failure_artifacts.py` | Cumulative. Failure keeps original error and teardown |

#### Shared optional stderr

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| [Shared optional stderr](#shared-optional-stderr) | `terminal-restoration-integration` (`check_forwarding`), `'required Bash observations publish'` | No universal latency or restoration claim |
| Canonical work unaffected by diagnostic failure | `host_diagnostic_cases` | Wake fallback: none located |

#### Diagnostic records and export

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| [Records](#diagnostic-records-and-export): 128 MiB, 16 files, 4 KiB | `'startup diagnostics rotate'` | Reduced cap only |
| [Fence records](#diagnostic-records-and-export): one record per dispatch transition after readiness | `'SH-53 a dispatch fence records'` | In-process Host; detached launch is not exercised |
| [Failed-response records](#diagnostic-records-and-export): exact bytes, association, status, 16 MiB, 64 MiB, 256 records, private modes | `'failed response'` tests; `dispatch-integration` invalid-output, transient HTTP, stall and concurrent-retention cases | Truncation, eviction and omitted bodies use reduced caps or an unreadable capture in unit tests. The integration fault is an undeletable record entry, not disk exhaustion |
| Failed-response export through authenticated `session inspect`: exact body and stored metadata, Session/Operation/Attempt binding, read-only snapshots, binary windows, partial and omitted bodies, missing/ambiguous/corrupt records, symlink rejection, clean stdout and fd256 caller. Mandatory scratch unlink failure fences dispatch, preserves the original failure and recovers on startup | `dispatch_integration.py failed-response-export` in `dispatch-integration` | Real fixture-produced `IncompleteProviderOutput` and binary HTTP 400 survive Host restart. Partial/omitted export negatives perturb that real record; retention creation has separate owner tests. Canonical values and retained bytes/write timestamps are compared, not filesystem atime or WAL housekeeping. No live provider or automatic upload |
| General bounded rotated-log export | none located | Unimplemented |
