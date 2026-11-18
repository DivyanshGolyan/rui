# Resources and selection progress

[Architecture](../../ARCHITECTURE.md) owns shared guarantees, terminology, and the source map.
[Verification](../../VERIFICATION.md) owns global evidence rules and gates.

## Accepted contract

### Resources, storage and diagnostics

#### Capacity and selection progress

##### Capacity ownership

**Active Capacity** is one startup-fixed array of content-free custody records.
Neutral entries are no-ops.
Initially scan the full array without free/active lists; this is an algorithm selection, not a prohibition on bounded indexes.
Custody is process-local, never durable slots.
One occupied record is one Active Credit from reservation through execution and safe cleanup, not a second pool.
No per-waiter execution resources or permanent Edit lane.
Permission waits retain only durable facts; Edit validation/build/copyback acquires shared capacity after authorization.

Without capacity, eligible work stays in SQLite with no Attempt, consumed allowance, materialized request or wait flag.
Each resource owner rediscovers eligible facts and chooses a legal candidate.
Exact cross-Session winner order is not public.
Approval, retry and restart preserve identity, authorization, deadlines and allowance, not scheduling rank.

The execution loop filters blocked permissions and future retries, then revalidates at Attempt admission.
It handles events, saves results, releases resources safely, advances Session input under the queue invariant and fills available capacity before waiting for OS activity.
Ready controls and due cleanup receive service between settlements, socket events and transfer completions, outside callbacks.
Settlement and inspection must also progress.

Discovery uses bounded storage queries, not per-Session resident tasks.
The writer rechecks after writes; accepted live-effect controls publish their required process-local signal.
No SQLite watcher is required.
The retry scans use a due-time index that excludes future deadlines, and run at most once per second.
A scan that found nothing runs again only after a commit, a relevant slot or ordinary-custody availability change, or the earliest scheduled retry falling due by the wall clock, the clock the Store admits by; the admission scan reads that due time in its own round, and an idle Host sends the Store no query.
After a commit, one read round says which kinds of dispatch work the Store holds (core and MCP Actions, Bash, waiting Messages, tool continuations), and only those kinds' scans run; the answer is a hint, since each admission reads its own facts again, and a kind it wrongly names costs one empty round.
That round also reads whether any open Turn's Attempt is unresolved with a retry state; while none is, neither retry scan runs, since a commit is the only thing that makes one.
The work-version owner separately reads the next retry deadline and publishes crossings to the bounded Session change ring, independent of execution capacity or provider availability. It repeats that read on a work-version change or a crossed deadline; an unchanged idle Host performs no repeated query.
Missed ticks do not queue.
Full capacity or an empty array must not cause spinning.

For Session work, keep one fixed preference order of four kinds: authorized Bash, due model retry, message-driven model admission and tool-only model continuation.
Try kinds in order at legal admission opportunities, using existing eligibility and resource gates and oldest-eligible identity order within each kind.
After successful committed Attempt admission, move only the winning kind to the back.
Skipped, unavailable, no-work and rolled-back kinds retain their relative position.
A circular pointer that forgets skipped kinds does not satisfy this policy.

An eligible Session-work candidate receives eventual admission despite sustained competition under a healthy, continuing Host, satisfied prerequisites, recurring matching admission capacity and safely retiring finite effects.
A candidate may wait behind its finite older-identity prefix.
Blocked permission, future retries, retained custody and unavailable preparation are not eligibility.
The guarantee is not equal time or token shares, preemption, a completion deadline or model success.
Preferences may reset on restart; indefinitely repeated failures or restarts do not meet the stable-service assumptions.

The four-kind order adds fixed-size discovery policy, not per-Session workers, timers, a resident ready queue, durable scheduling phases or another credit pool.
Control, completion, preparation and cleanup service continues between bounded admission steps.
Replace discovery algorithms only for a demonstrated need while preserving canonical authority, one-shot dispatch, safe custody reuse, eligibility and these progress guarantees.
Lost or stale hints and restart cannot lose work or grant launch authority.
Any index or hint needs an owner, population bound, failure behavior and release point.

#### Memory ownership and configured bounds

##### Resident-memory invariant

At fixed configured capacity and live-exchange population, retained orchestration memory and open-handle populations do not grow with durable history or payload item count.
Large values travel through bounded windows, owned scratch/content stages or a read-only map of their capture's page cache, never a payload-sized copy.
Dormant Sessions and terminal Turns retain no resident graph, worker, socket or credit.
The Session change ring is fixed-size (4,096 entries, 90,136 bytes) and independent of Session count.
So is the Session environment register: it holds at most 4,096 Sessions and 128 distinct environments of at most 1 MiB in total.
An open overview holds the Store's rows in the client process, not the Host.

This is not a whole-process ban on allocation after startup.
Library and transport allocations remain separately bounded.

A failed named-scratch unlink transfers its open aliases, retryable name and exact charge into one owner under custody.
Reclamation treats an absent name as success, retains every resource on any other removal failure and releases handles/accounting exactly once before custody becomes reusable.
The Host lease supplies the scratch directory throughout service and shutdown and outlives execution cleanup and join, so each execution slot needs no duplicate Store path.

Measure allocator-live, retained allocations and physical footprint separately; release need not lower RSS immediately.
[Verification owns the Host qualification targets](#resources-and-accepted-host-qualification-targets) and the additional [aggregate peer qualification](model-io.md#per-call-accounting-and-100-agent-acceptance).
The Host boundary includes in-process transport, TLS and network libraries; the peer boundary also charges live CLI/helpers and routing shells.
Workload subprocesses and kernel resources remain separately reported.
Counters that overlap or measure different quantities are not additive.

On macOS, `rui host serve` supplies `MallocMaxMagazines=1` and `MallocSpaceEfficient=1` only when each variable is absent.
If either is added, it replaces its process image with the same executable and arguments before opening the Store; libmalloc reads the resulting environment before `main`.
This reduces allocator-retained pages after repeated work without changing live-data ownership.
Explicit values, including empty values, take precedence.
`RUI_HOST_MALLOC_DEFAULTS=0` disables both defaults without removing caller-supplied settings.
Linux and non-Host CLI commands add nothing.
Path resolution or replacement failure aborts startup before Store effects.
These Apple implementation settings are not a public compatibility guarantee: correctness must not depend on their effect, and resource qualification must record the OS and overrides.
The measured macOS 15.7.7 tradeoff does not qualify other releases or Linux; retain the opt-out rather than adding an allocator replacement or periodic trimming.

On Linux with glibc, the execution loop calls `malloc_trim(0)` once each time it has done work and then waits with every execution slot free, returning the free pages every thread's arena keeps after a burst; steady work never trims, and an idle Host trims once.

| Boundary | Selected value and scope |
| --- | --- |
| Active Capacity | Startup default 100 shared model/Bash/MCP/Edit executions and cleanup, the product default for every start path; adjustable with `--set execution.activeCapacity=N`, no independent hard maximum. A running Host keeps its startup value. MCP also retains its separate 16-call limit and 4 MiB answer-buffer bound per call. |
| Shared scratch | Startup default 8 GiB logical owned bytes, including pending growth and overlapping copies; no allowance-sized allocation/reservation. |
| History memo | At most 1 GiB of [memo](model-io.md#history-memo) file bytes in the scratch directory, additional to shared scratch; one fixed-size index entry per unit of Active Capacity. |
| Session list page | Eight rows. The worst-case row is derived at compile time from its field bounds and must fit 32 KiB; the derived page bound covers the capture. |
| Session change ring | 4,096 (Session, Workspace key, commit counter) entries, 90,136 bytes, mapped at Store open and faulted in as entries are recorded, so an idle Host keeps none of it resident. Its size is a guess until #557 measures the commit rate. Overflow degrades `since` to `full`. |
| Session environment register | 4,096 (Session, environment, rank, last use) entries of 24 bytes, mapped at Host start and faulted in as entries fill, so an idle Host keeps none of it resident. At most 128 distinct [environments](execution.md#bash-environment), shared by equal value, of at most 1 MiB in total, each at most 64 KiB. When a new environment needs room, the register drops the environments the fewest Sessions share, least recently used first, and replaces only the Sessions naming them; when it needs only an entry, it replaces the least recently used Session. A replaced Session falls back to the system `PATH` as after a restart. Each offer and copy is linear in the register's size, under its own mutex. |
| Clients | [Demand-scaled intake and control progress](inspection.md#connection-capacity-and-control-headroom), independent of execution capacity. |
| Exchange bounds | Request line+headers 16 KiB. Each in-flight Message exchange also holds its environment, at most 64 KiB, from its header until admission; that one allocation becomes the register's copy or is freed right after admission, so intake memory grows by at most 64 KiB per open Message exchange; derive short-control request, acknowledgment and error bounds separately from supported fields and their maximum encoded sizes. Reject oversized requests before mutation. |
| Client deadlines | [Transport inactivity](cli.md#client-transport-and-observations) and [absolute discovery/header deadlines](inspection.md#connection-capacity-and-control-headroom). |
| Model retries | Startup default 3 after initial try; 2/4/8 s backoff or later valid Retry-After, then positive jitter up to one quarter of backoff; conserved per Operation. |
| Provider inactivity | Startup default 5 min awaiting first body and between chunks; body/heartbeats reset it, no progressing-stream total deadline. |
| Bash | Startup default 5 min from process start, output does not reset it; per-call positive finite representable override, no policy maximum. |
| Tool excerpt | Startup default 20,000 UTF-8 bytes across the entire Bash Tool Result, no line quota; fitting Bash streams are complete, truncated streams use one half of their allowance for the head and the rest for the tail; omission/path metadata additional. |
| Edit copy window | Reusable 16 KiB; not an expected-text/line/replacement/file limit. |
| Diagnostics | Startup default 128 MiB, at most 16 files, each floor(cap/16), 4 KiB encoded record; exports consume scratch. [Failed-response records](diagnostics.md#diagnostic-records-and-export) are separate: first 16 MiB per capture, 64 MiB and 256 records per Store, oldest first. |
| Qualification acceptance targets | [Verification’s Host qualification targets](#resources-and-accepted-host-qualification-targets) define workload-specific acceptance targets. They are not runtime admission limits or per-module quotas. |

Qualification procedure, fixture pacing, CPU brackets and control sampling live in [Verification’s qualification workload](../verification/qualification.md#qualification-workload-and-measurement-boundary).
Recorded results remain in [current qualification](../../tests/qualification/README.md), with their original targets and conditions.

#### Scratch, tool output and accounting

##### Shared scratch ownership

One shared temporary owner covers request/response/metadata, ingress, reports, exports, Edit output and retained spillover.
Canonical SQLite and persistent diagnostics are separate; temporary copies count.
Model request/response files may overlap; Bash has separate stdout/stderr files and optional unlinked stdin; client ingress/outgoing roles may overlap.
These derive accounting, not file quotas.
Ownership transfer preserves charges.
Protect current work/publication/delivery/I/O.
Release files with no later consumer; optional **Spillover Output** becomes disposable after its excerpt/result is saved and execution releases it.
Evict oldest eligible retained files to satisfy byte reservations or retained-file capacity, not LRU, a background expiry service or per-tool pool.

Serialized provider validation keeps the immutable raw capture for failure evidence and assembles decoded SSE data into one additional private unlinked file through a 4 KiB window.
Metadata ranges and accepted Store imports address that decoded source; rejection offsets remain in the raw capture.
Decoded bytes never exceed raw capture bytes, but the complete decoded payload overlaps raw capture and metadata and consumes the unchanged shared scratch allowance.
This is one validation file/descriptor across all execution slots, including capacity 100, not one per receiving Attempt.
Validation owns three file descriptors, briefly four with its acquisition directory, after transport has released the request and its stream; the existing execution descriptor allowance remains sufficient.
Random metadata reads and terminal-item agreement outlive individual events, so a one-event buffer cannot replace this source.
The caller closes it after settlement or rejection.
It reuses the already-unlinked response name; acquisition unlink failure retains the existing named-scratch owner and fences dispatch until reclamation.
No durable encoding changes.

Before admission, startup classifies scratch entries by canonical typed name.
Owned names are exactly the implemented request, provider-request, response, response-metadata, Bash input/output and report prefixes followed by their canonical numeric components and `.tmp`; request/report number zero is allowed only where those producers use it, while other components are positive canonical decimals.
Input names exist only before preparation unlinks them.
Regular files with those names are removed, and another filesystem type refuses startup.
Malformed components, prefix/suffix lookalikes, unrelated files, canonical Store files and diagnostics are preserved.
The expected endpoint path is removed only when it is a Unix socket; another type refuses startup.
Temporary content never reconstructs semantic state, a dispatch permit or a saved result.

Reserve growth before I/O with checked arithmetic and serialized owner accounting.
Charge sparse gaps and simultaneous copies; overwrites need no new charge.
Return a provably unused reservation after short/error writes; an unknown partial write retains its submitted increment until safe cleanup.
Ingress charges decoded file growth, not HTTP framing or escaping, and transfers each charge with its sealed file.
Failed removal retains that file’s charge until its owner successfully reclaims it or startup cleanup removes it.
After the owner closes its final descriptor, an already-absent private name establishes reclamation; otherwise private scratch charge survives unlink and pending I/O, releasing only after successful shrink or safe final closure.
No writable alias may bypass accounting; no per-write heap allocation, directory scan, SQLite transaction or global lock across disk I/O.
Logical bytes do not model block rounding/cache/compression or reserve real disk space.

##### Retained output and its queue

Published spillover is an ordinary absolute path, never reused by Rui for different output.
Charge Rui-produced bytes while its name is retained.
External additions/links and bytes held by external readers after retained-name removal are outside that allowance.
Removal or an already-absent name plus closure of Rui handles establishes reclamation and releases retention charge; other removal failures retain the queue entry and charge.
Unknown external readers neither pin FIFO eligibility nor require a registry.
Optional retained files retain neither execution credits nor open per-file handles.

Retain optional full output in a bounded in-memory FIFO owned by the temporary owner.
Each entry holds a generated file identifier and charged length; derive the fixed retained-file capacity at startup from the queue's allocated orchestration memory and actual complete entry cost.
Include container overhead in the memory derivation.
The concrete allocation and resulting capacity are implementation choices requiring whole-Host qualification, not a second user-facing setting or an allocation proportional to the scratch allowance.
Count each retained physical file, including empty files and separate stdout/stderr files.
Active/protected files remain bounded by their existing owners and are additional to this capacity.

Evict oldest eligible output when either the shared scratch-byte allowance or retained-file capacity requires it.
Earlier eviction despite spare scratch bytes is accepted because full output is optional; saved Tool Results, excerpts, permission/Edit evidence and provider continuation remain unchanged.
This policy removes disk-index growth and reclamation requirements; no disk retention index is required.

Reserve a queue entry before execution releases a file to retention; only saved-and-released output becomes eligible.
Failed handoff leaves the file with its execution cleanup owner.
Failed deletion retains both its queue entry and byte charge; never overwrite an occupied entry or move failures into unbounded tracking.
If reclamation cannot make room, leave ownership with the current owner and handle exhaustion explicitly without oversubscription or spinning.
Active scratch ownership charges bytes as they are produced; the retained queue records the transferred charge at handoff and updates its tracking on handoff/removal, not on each streamed output write.
Restart may discard the queue and its owned spillover, but startup cleanup failures must prevent unsafe admission under the shared cleanup rule.
Measure filesystem metadata and cleanup latency separately from logical bytes and queue memory.

##### Tool excerpts and full output

Bash output has no per-call total capture cap.
Short output is complete; larger output saves status, head-and-tail excerpts, exact omitted-byte counts and the path of each truncated stream, preserving combined-stream allowance and valid UTF-8 boundaries before provider JSON framing.
Failed full capture cannot masquerade as successful preservation.
Full output is read through ordinary Bash permissions/timeouts/excerpts, not a new Read tool or whole-file context injection.
FIFO or Host exit/crash may remove it; unavailability leaves saved results unchanged.
Canonical permission, Edit intent and outcome evidence are not disposable spillover.

A Bash result names only what carries information: the unchanged outcome line and warnings, a `stdout:` section only when stdout is nonempty and a `stderr:` section only when stderr is nonempty.
A fitting stream is complete. A truncated stream shows its head, a separate `[N bytes left out]` line (the exact number of source bytes not shown, without thousands separators), then its tail. The head receives one half of that stream's existing allowance and the tail the rest, both cut on valid UTF-8 boundaries. If a newline lies within the last 256 source bytes of the head, the head ends just after the last such newline; if one lies within the first 256 source bytes of the tail and the tail does not already start a line (the source byte before it is not a newline), the tail starts just after the first such newline. A cut that already falls on a line boundary therefore stays where it is at either end. Bytes removed by either adjustment count as left out.
After the stream sections, `Full stdout: PATH` or `Full stderr: PATH` names each truncated stream, or `Full output was not retained.` reports unavailable retention. There is no separate `[earlier output omitted]` line. An untruncated stream names no file.
After a cleanup failure fences dispatch, the original Bash owner retains custody and retries reclamation. Once that owner successfully reclaims an untruncated stream, its capture file has been removed or was already absent, and its charge is released. If the Tool Result was saved before cleanup failed, it already contains the complete stream, so reading the result and continuing the model after restart do not require that file.
Saved results from older Hosts retain their `stdout tail:` / `stderr tail:` sections and `[earlier output omitted]` notice; readers accept both shapes without rewriting stored results.

MCP answers are bounded by the existing 4 MiB per-call answer buffer.
Their resolution keeps the first 10,000 rendered text bytes, including image diagnostics, cut at a UTF-8 boundary, and the omitted-byte suffix; fitting text-only answers keep their complete existing bytes. A fitting result creates no retained file.
When bytes are omitted and the Operation's frozen offer includes Bash, stream the whole rendered answer once to optional scratch and append `Full output: PATH`, or `Full output was not retained.` if retention is unavailable.
Without Bash in that frozen offer, keep the omitted-byte suffix but retain no full answer and append no path or retention hint (D242); later Session settings do not change this choice.
MCP uses the Host's same retained-output queue, scratch budget, file capacity, eviction and cleanup as Bash, with no fsync or durable retention index.
Complete image-bearing MCP results keep valid images as image parts and do not send image base64 as pseudo-text to model input; the same text budget applies across text runs and image diagnostics. Oversized or truncated answers retain their raw JSON prefix as text, which may contain base64. When text is omitted, the optional full output is rendered text with image placeholders and in-place diagnostics; it never contains image base64. Retention and its hint respect the 1,500-part limit. Under scratch pressure, optional spill yields before required capture is refused. Confirmed deletion releases its charge; an unconfirmed deletion retains the charge and can leave insufficient quota, so required capture may settle `storage_failed`.
Scratch loss never changes the call's outcome; partial failed captures are not advertised and keep their charge until confirmed removal.
The Store saves exactly this model-facing resolution, not the full scratch answer; saved results and history rendering are never rewritten when scratch disappears.

##### Exhaustion and cleanup

If safe reclamation cannot provide space before admission, wait without Attempt.
Exhaustion after admission stops the affected execution safely and returns explicit storage failure: no RAM fallback, silent truncation, indefinite quota-holding wait or redispatch.
Retain custody/evidence through settlement.
Real volume exhaustion is independent of the configured cap.
Small controls need no execution credit or content scratch, but still need canonical writes.

A read handoff does not duplicate charges; a physical copy does, including temporary import copies and request overlapping response.
Reserve each actual growth increment, not the possible maximum output.
A short successful I/O may advance by its actual count and continue; premature EOF, zero progress where bytes are required or a terminal error cannot certify completion.
On write failure retain every submitted byte not proven unwritten, including the complete increment when the API reports no reliable partial count, and stop the affected producer before releasing its resources.

File and descriptor populations follow their concrete owners: occupied execution records, ordinary client exchanges, the single validation workspace and bounded diagnostic/export work.
Their temporary-file counts likewise stay independent of payload item count and durable history; metadata grows in charged sequential storage.
Include overlapping preparation/capture, partially constructed resources, spawn duplicates and delayed cleanup in startup derivation.
Reserve required tracking before creating/opening resources; failure unwinds the resources already obtained.
Retained spillover is the only temporary population that outlives these active owners and follows its retention rule above.
This requires a cost derivation for each selected implementation, not a new generic handle registry or descriptor-credit pool.

Failed shrink/removal/closure cannot be recorded as reclaimed capacity.
Keep unresolved resources charged and owned; service other work without spinning or repeatedly allocating replacements.
If cleanup cannot establish safe callback/handle release, keep custody unavailable and use effect-aware shutdown when continued ownership cannot be maintained.
Do not rewrite an already-saved outcome to claim cleanup success.
Startup under exclusive Store ownership may remove identifiable leftover temporary artifacts before admitting new work; failures must remain accounted for or prevent startup.
Canonical files, diagnostics and unrelated files are not temporary cleanup targets.


## Required evidence


### Execution tracking and waiting

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| [Fixed custody population](#capacity-ownership) | `'execution slots agree with custody across the complete population'`, `'no-work admission restores only its temporary custody reservation'` | Full scan, no free list; never a durable slot registry |
| Attempt admission rollback | `dispatch-integration` | Sample custody after `releaseUnused` in the same owner turn; suppressing it must fail |
| [Selection progress](#capacity-and-selection-progress) and waits | `test-logic`, `'kind-specific admission'`, `'production turn preserves skipped continuation'`, `'each transition that lets a Turn continue without input makes it selectable'`, `'a Turn whose continuation was never recorded fences the Store'`, `'tool continuation selection never visits a Turn waiting for its tool results'`, `'tool continuation selection leaves a ready Turn with queued input to message selection'`, `'runnable discovery measures eligible ineligible and history populations independently'` | Not native transport or cross-platform qualification |
| Resumable model preparation | `test-logic -Dtest-filter='request encoding'`, `'request preparation'`, `dispatch-integration` | Service gaps are observational, not turn-ordering proof |
| Discovery-hint replacement | none | Only when a replacement is introduced |


### Resources and accepted Host qualification targets

Targets (Host-only; CLI/helpers separate):

- ≤25,000,000 bytes macOS lifetime-peak physical footprint at Active Capacity 1/8/16/100 and cold/retained idle: `measure-model-output`, `measure-call-classification`
- ≤256 MiB physical footprint, eventual 1,000-operation model/Bash/Edit/mixed load: none located
- Idle CPU <1% of one core: `measure-model-retry`, `measure-model-dispatch`
- Retry discovery ≤2 s after due at free capacity/light load: `measure-model-retry`
- ≤2 cores observed model-fixture CPU and ≤120 CPU s complete work, two same-Host rounds: `measure-model-output`
- p95 durable control acknowledgement ≤1 s with 100 live streams and 100 occupied custody records: `measure-model-control`
- 0/100/1,000/10,000 Dormant Sessions at fixed capacity: `measure-admission`
- Session environment register: at most 4,096 Sessions and 128 values of at most 1 MiB in total, least recently used replaced, each value freed when no entry names it: `'the table holds at most its Sessions and value bytes'`, `'the table holds at most its values'`, `'a value is freed exactly when no entry names it'`
- Behavior failure vs invalid measurement vs target miss: `measurement-check`

#### Descriptor startup capacity

Required: minimum ten-client intake; budget covers wake pair, 100 ordinary exchanges, two controls, one discovery, not as runtime quotas; managed auth adds 8 (Linux) or 10 (macOS).

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| Startup limit fit or refusal | `'descriptor'`, `descriptor-capacity-integration`, `codex-h2-integration` | Native Linux and macOS; cross-compilation is not equivalent. Auth allowances are not a physical peak |
| Accept pressure (EMFILE at 512 FDs) | `descriptor-capacity-integration` | Restored fatal accept branch must fail. ENFILE/ENOBUFS/ENOMEM injected, not system-wide exhaustion |

#### Transport

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| Shared H2, peer-held streams and an isolated write failure | `transport-h2-integration` | Opt-in; needs Python `h2==4.3.0`, OpenSSL CLI. Not footprint |
| Repeat-work footprint | `transport_h2_integration.py zig-out/bin/rui --observed-shape-churn` | macOS ReleaseSmall, opt-in; fails above 25,000,000 bytes. Not the Go repeat-work profile |
| Original result and release deadlines: one deadline per population, forwarded through reads and global release | `transport_h2_integration_test.py`, `host_process_test.py` | A clean reply at or after the deadline fails. Held cleanup must refuse through the deadline |
| Transfer finalization | `'HTTP error capture retires before execution custody'`, `'a completed Transfer finds its own slot and nothing else'` | None |
| Address racing (RFC 8305): families alternate, the next attempt starts on a failure or after 250 ms, at most two sockets | `'the next address starts on a failure or after the delay, the oldest of two giving way'`, `'families alternate, the first answer's family leading, and both fit'`, `'https by name: an address that never answers does not keep the next from connecting'`, `'https by name: two addresses that never answer do not keep the third from its turn'` (`test-h2`) | A never-answering address is a loopback listener with a full accept queue. Name resolution itself is not raced (RFC 8305 section 3) |
| Proxy tunnel (CONNECT over an `http://` proxy): credentials, NO_PROXY and loopback bypass, 407/403/other refusals, interim 1xx answers, nothing after the answer, unusable proxy URLs | `proxy.zig` tests, `'the HTTP/2 client's proxy logic stays within the core boundary'` (`test-logic`), `'any 2xx opens the tunnel; 407 and 403 are their own causes'`, `'exchange: https through a proxy's CONNECT tunnel, with its credentials'`, `'exchange: a proxy's 407, 403 or other refusal ends the setup before any request byte'`, `'exchange: bytes after the proxy's answer fail the tunnel'`, `'exchange: loopback and NO_PROXY hosts connect directly'`, `'exchange: a proxy URL Rui cannot use fails Client init'` (`test-h2`) | The proxy is an in-process test proxy. No `https://` proxy, no proxy auto-configuration or system proxy settings |

#### Scratch and cleanup

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| [8 GiB scratch accounting](#shared-scratch-ownership) | `'concurrent scratch reservations share one ceiling'`, `'ingress charges decoded growth and transfers file charge through cleanup'`, `dispatch-integration` | Real disk-full: none located |
| Startup leftovers | `'startup cleanup removes owned files and preserves lookalikes'`, `'startup reclaims only a stale Unix socket'` | None |

#### Host startup availability

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| Migration-aware launch wait and adapter progress | `HostStartupWait.zig` policy tests; `cli.zig` 'Host launch owner returns one result' covers split migration announcements, a migration longer than ten seconds, the fixed post-migration deadline, same-read start/end, EOF and final readiness drain across owner, screen and terminal adapters; a later pause observes the terminal notice before launch returns and the final transcript contains it once. `Host launch activation preserves refusal timeout warnings and an unserved selection for reporting` exercises the activation boundary and shared terminal/screen reporter. | Injected native effects, no wall-clock migration-duration claim |
| [New-Host provider selection](model-io.md#codex-wire-binding) | `host_start.zig` 'Host start explicit providers replace automatic defaults' uses independent provider choices. `host_launch_integration.py provider-policy` in `host-launch-integration` checks literal `host_info` route maps for omission, empty and exact sets across foreground serve, detached start, settings file, framed stdin and saved `host.json` show and start, with missing, invalid, browser-only, key-only and both local credentials. The existing bare-terminal overview case checks the same route map with only a device-code credential. | Synthetic local credentials only. Both proxy-variable casing forms pin HTTPS to a loopback CONNECT-refusing server, both bypass lists are empty, and usable-credential cases wait for recorded CONNECT refusal before cleanup. The proxy forwards nothing and checks target and authorization-header custody. A signed-out Codex route is not authenticated availability or a successful model call. Exact selection uses a usable browser credential; missing or invalid explicit credentials remain credential-owner cases. Upgrade selection preservation belongs to the separate Upgrade checks below. |
| Provider request and independent discovery endpoint capacity | `provider.zig` 'Reactor registers every provider and independent listing subset' crosses all eight provider subsets with all eight independent listing subsets, using six distinct loopback origins. The provider owner checks its derived endpoint requirement against H2 capacity at compile time. `test-h2` 'six independent endpoint URLs' checks six distinct registrations and refusal of a seventh. The existing 'catalog endpoint setup failure' test retains optional catalog setup-error semantics. | Registration and cleanup only, with no DNS or requests. `stack-frames` retains the existing frame budget after the bounded endpoint arrays grow. |
| Limit and schema refusal under 5 s | `host-launch-integration` | 256/256 and minimum-1 refuse; exact minimum serves ten clients. Linux and Apple Silicon macOS |
| Moved SQLite Store refuses foreground, detached and interactive startup with both escaped canonical folders, `store_identity_mismatch` and exit 6; old-path symlink still refuses, identity stays unchanged, restoration serves | `host_launch_integration.py store-identity` in `host-launch-integration` | Private stopped fixture Store only |
| [Installed upgrade](store.md#store-format-and-upgrades) | `previous-release-upgrade.yml`, `previous_release_upgrade.py` | Running v0.69.1 → rendered candidate release installer: exit 0, named restart, candidate serving image/version and new instance, exact saved work/configuration without replay. Also stopped-Store supported startup migration/backup and unsupported-format refusal; no reset policy |
| Source and release installer publication | `installer-integration` | All installer boundary cases use an explicitly supplied compiled production Rui for native publication and PATH facts; planning and template policy tests require no compiler |
| [Standalone stable Upgrade](store.md#store-format-and-upgrades) | `upgrade-integration`, Installation, release, Host lifecycle, PATH and panel value tests | Offline metadata and a same-source synthetic release identity; real native Hosts and the PTY screens prove exact-instance activation and lease retirement, failure reporting and retained drafts without replay. Historical external installers are outside the guarantee |
| [Inline Upgrade relaunch](store.md#store-format-and-upgrades) | `Overview.zig` 'relaunch departure matrix preserves every screen and all unsent drafts' covers real joined receipts through retention and departure, outcome × screen × guidance × drafts (including protocol-incompatible with only the old-client hold); `HostLifecycle.zig` 'relaunch activation reading' binds either wire to the pinned launch; `client.zig` checks same-peer protocol rejection separately from activation failures; `session_upgrade.zig` checks the pure departure decision; `upgrade_status.zig` checks the new-client ending; `cli.zig` checks every explicit selector subset and injected replacement failure; `upgrade.zig` checks all activation receipt obligations; `Root.zig` stops ticks after departure; `relaunch_handoff.zig` pins v1 bytes, validates and round-trips snapshots (including legacy nonempty overview snapshots), and ignores missing/malformed handoffs; `Overview.zig` owns the empty compatibility overview projection on departure and ignores legacy overview bytes on restore while preserving per-Session chat drafts | Offline `upgrade-integration` starts Upgrade through Settings → Version and observes the selected image at the original PID, terminal restore/reentry, both screens and per-Session Unicode drafts/carets; its `startup` table crosses overview/resumed Session × readable defaults/unreadable preferences/absent provider credentials × explicit Store/changed implicit default, retaining original Store, screen and per-Session drafts in all twelve rows; unchanged, cancellation-report and PATH-guided runs do not relaunch. Real released cross-wire transitions are not exercised; scroll position intentionally resets |

#### Canonical reads, retained output and SQLite

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| [Bounded content reads](store.md#canonical-content-reads-and-retention) | `'content reader owns the bounded result-delivery window'`, `'content readers hold no decode window'`, `'public content SQLite step failure fences after successful preparation'`, `'retained readers allow checkpoints between committed windows'`, `'historical preparation yields covered group populations under small allowances'`, `'yielded Bash preparation leaves checkpoints free while retaining its descriptor'`, `server_delivery_integration.py` held Reply reads beside committed configurations | Checkpoint/reuse is not a hard WAL file-size quota |
| [Startup MCP offer projection](model-io.md#tools-inside-the-history) | `test` 'MCP offer projection covers identity changes removals additions and name narrowing', 'MCP intent removal return crosses explicit equal and changed tools and loaded tools', 'MCP find_tools expands loaded intent without losing or inventing unavailable names', 'MCP projected offers preserve request prefixes and memo rebuilds', 'Host startup projects MCP offers after a changed listing and restart', 'each Store entry point takes its round budget'; schema 65 SQLite and live MySQL backfill tests; existing `find_tools` tests | Session sets are intent only; Host tool set changes neither modify them nor create revisions. Explicit equal/changed tools and loaded-tools updates survive removal, return and reopen without resurrecting excluded names. `find_tools` preserves unavailable loaded intent without inventing it. Admission alone freezes effective offers, rolls back atomically, preserves old requests and cache prefixes, and rejects removed calls; K1 child narrowing remains a ceiling. Migration independently checks old full/subset Operation offers and unchanged Session intent. Live MySQL requires its configured server; the restart witness uses real loopback listing and Store close/reopen, not a process crash |
| [MCP resolution certainty](model-io.md#operations-and-frozen-requests) | `test-logic` `'result_text classification covers every ending and certainty boundary'`; `test` `'Running oversized JSON and SSE answers'`, `'Running resolves socket replies'`, `'Host MCP Session stop after send'`, `'MCP attempts serialize Sessions'` | One owner table spans every terminal ending, both send sides of stop/deadline, and complete/cut parity across result types, content shapes, explicit/default flags and RPC errors, crossed with 4xx/5xx, JSON/non-JSON media and matching/nonmatching envelopes. Missing defaults and unfinished values remain unknown until established. Native JSON/SSE overflow retains status, media and prefix, including malformed/unsupported results and definite 4xx refusals; Host/Store stop tests check durable indeterminate after send, cancelled before send, no retry and unchanged Bash cancellation. Completed MCP answers survive a settlement/stop race. Over-limit replies retain only the marked prefix, not the unread suffix |
| [Retention FIFO](#retained-output-and-its-queue) | `'retention entry capacity derives from fixed orchestration memory'`, `'already absent retained files release their entries and scratch charge'` | None |
| Retention failure keeps result | `bash-owner-integration` | Host is not fenced |
| [MCP excerpts and optional full output](#tool-excerpts-and-full-output) | `tool_result.zig` 'fitting result creates no retained file', 'fitting mixed result does not retain output', 'required image capture reclaims optional spill', 'image capture yields optional spill and finishes under contention', 'result retained path names complete sanitized output', 'final reservation yields spill before choosing footer'; `output_retention.zig` 'spill handoff waits for close and keep in either order', 'spill yields its live charge for required capture', 'spill failed removal preserves charge for retry and quota failure yields'; `ScratchBudget.zig` 'concurrent scratch reservations share one ceiling', 'only allocation may reclaim and partial allocation preserves charged progress'; `server_mcp.zig` 'MCP Result renders and retains text across outcomes and frozen offers', 'MCP Result reports retention refusal without changing success', 'MCP retained response follows the actual delivery outcome'; `server_execution.zig` 'Bash releases both spills after lost custody or fenced settlement'; `bash-integration` spill delivery outcomes; `server_mcp_tests.zig` 'Host MCP retains sanitized full image output only when Bash is offered', 'Host MCP releases a retained result when settlement fails' | Cover text-only parity, fitting output without a retained file, diagnostics within the one text budget, sanitized retention, hint and part boundaries, spill yielding, active scratch charges and queue handoff/removal accounting. The result-level tests cover both insufficient quota and successful capture after yielding. Direct stops release unreferenced spills; Session-stop retention follows the settled value. No OS-crash or power-loss qualification. |
| [20,000-byte Bash head-and-tail excerpt](#tool-excerpts-and-full-output) | `'UTF-8 excerpt keeps the newest source and reports replacement expansion'`, `'Bash excerpts'` (head/tail table, every multibyte cut, replacement expansion and 256-byte newline windows, including cuts already on a line boundary) | No line/total-capture quota or rerun for truncation |
| [Result sections](#tool-excerpts-and-full-output): no empty stream header, full path only for a truncated stream, no confirmed-retirement note | `'Bash excerpts preserve heads tails UTF-8 boundaries and newline cuts'`, `'cleanup deadline cuts off'`, `bash_integration.py`, `bash_owner_integration.py`, `bash_lifecycle_integration.py` natural exit, `human_cli_integration.py` permission case | Natural exit asserts the exact saved and model result on both systems, including macOS group-signal `EPERM`; injected signal failure remains in saved/model results and opened tool rows or full raw export, not normal tool headings |
| [Settings and faults](store.md#sqlite-and-representation) | `'production Store applies finite durable SQLite settings'`, `'an outside SQLite writer cannot take the open Store's lock'`, `'real SQLite full during import publishes no canonical prefix'`, `'measurement Store can force a smaller SQLite cache without changing production defaults'` | None |
| [Store durability](store.md#store-durability) | `'Store WAL lifecycle at the maximum path: sidecars, lock ownership, crash copy, checkpoint and restore'`, `'fresh Store uses current schema and rejects the prior version'`, process-crash recovery in `bash-recovery-integration` and `admission-debug-integration` | The crash copy is a file snapshot of an open Store, not an OS crash; no power-loss test |


### Memory explanation evidence

For allocation, buffer, thread or resource-lifetime changes, record build and workload, allocation origin and owner, population multiplier, lifetime and attribution gaps.
Distinguish live allocations, allocation volume, physical footprint and virtual reservation; overlapping counters are not additive.
The [small Host memory trial](../../research/memory-trial/README.md) is a collection example, not a quota or a substitute for simultaneous-workload qualification.
