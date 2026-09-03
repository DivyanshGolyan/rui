# Host Runtime industry prior art

Date: 2026-09-02

Status: research comparison, not a normative contract. Primary sources only.

> Current decision: ADR-0021 no longer retains the serial Patch lane described and measured below. Bash and Patch share a typed Action lifecycle, may execute concurrently under Active Capacity, and use temporary execution custody observed by the common I/O Reactor. The earlier topology remains historical evidence.

## Verdict

The proposed OnePage Host Runtime follows mature physical-runtime patterns and
is deliberately simpler than mainstream durable workflow engines.

The strongest precedents are:

- libcurl, NGINX, HAProxy, and `kqueue`: one readiness owner can supervise many
  mostly idle connections using small per-connection control records;
- NGINX: bounded memory windows may spill larger bodies to temporary files;
- SQLite, Temporal, and Oban: durable storage can own backlog and retry timing while
  no worker, timer, or payload remains resident during a delay; and
- Google ADK and LangGraph: partial transport events need not become semantic
  history, while independently completed parallel work may be persisted before
  a later ordered boundary.

OnePage's important departure is that it does **not** replay a durable workflow
event history, checkpoint a resident graph, or persist generic lifecycle state.
Normalized SQLite facts are the only recoverable authority and bounded queries
derive what happens next. That is an appropriate simplification for a local,
linear Session/Turn harness.

The architecture is not yet fully proved. The disposable prototype validates
the physical topology, not real provider behavior or relational semantics. The
largest live simplification question is the globally serial Patch lane: keeping
blocking Patch work away from SQLite and I/O is justified, but industry prior
art does not establish that unrelated Patch effects must all serialize.

## OnePage baseline used for comparison

The current proposal has three internal ownership contexts: foreground SQLite
Storage Owner, one provider/Bash I/O Reactor, and one serial Patch lane
(`docs/research/host-runtime-integrated-capacity-proof.md:11-27`). One population
of Active Credits and 128-byte content-free Physical Custody records bounds live
effects; payloads, parser arenas, and resident Turn graphs are excluded
(`:29-38`, `:114-118`).

After Attempt commit, the Storage Owner materializes request bytes from SQLite
to immediately unlinked scratch through bounded windows (`:44-63`). The reactor
writes borrowed provider and Bash byte windows directly to scratch without
holding a SQLite transaction (`:65-74`). After terminal physical evidence, one
shared workspace validates and imports the sealed artifact, and SQLite normally
commits Completion, Resolution, and consequence together (`:76-96`).

The prototype measured a capacity-100 parent-process active footprint of 11.59
MiB, 9.12 MiB above idle lanes; extending a mixed stream from 10 to 60 seconds
grew disk custody without a measurable process-memory slope (`:104-137`). It
tested several physical failures, but deliberately left retry, cancellation
winners, sibling projection, idempotency, and recovery for real issue #52
commands (`:139-145`). The remaining physical gates are listed at `:162-179`
and in [issue #67](https://github.com/DivyanshGolyan/onepage/issues/67).

The complete semantic decisions are in the [issue #66
matrix](https://github.com/DivyanshGolyan/onepage/issues/66#issuecomment-5506066370)
and [resolution](https://github.com/DivyanshGolyan/onepage/issues/66#issuecomment-5506547697).

## Comparison matrix

| Prior art | Durable authority and resident state | Streaming, concurrency, and recovery | Lesson for OnePage |
| --- | --- | --- | --- |
| [OpenAI Agents SDK](https://openai.github.io/openai-agents-python/running_agents/) | Core `Runner` is an in-process async loop. [Sessions](https://openai.github.io/openai-agents-python/sessions/) persist conversation items, but core durable restart recovery is delegated to integrations such as Temporal, Dapr, Restate, or DBOS. | [Streaming](https://openai.github.io/openai-agents-python/streaming/) exposes raw deltas and complete run-item events; a streamed run is not complete until the iterator drains and post-processing settles. [Model retries](https://openai.github.io/openai-agents-python/models/) are runtime policy and explicitly replay-aware. | Supports concurrent tools, model-visible tool errors, and terminalization after the last visible token. Do not copy resident Run state or runtime-only retry custody. OnePage's relational Attempt/Completion/Resolution authority is stronger. |
| [Codex](https://github.com/openai/codex/blob/main/codex-rs/core/src/session/session.rs) | Keeps a rich resident Session; canonical history is an append-only [rollout JSONL](https://github.com/openai/codex/blob/main/codex-rs/rollout/src/recorder.rs). | [Parallel tool execution](https://github.com/openai/codex/blob/main/codex-rs/core/src/tools/parallel.rs) uses runtime synchronization and cancellation tokens. Ordinary tool failures become model-visible responses. | Useful behavioral precedent, not a memory or relational-authority template. Its capability gate is not evidence for a Workspace-wide fence. |
| [Google ADK](https://adk.dev/runtime/event-loop/) | Runner commits Events and state deltas through Session/Artifact/Memory services, then resumes execution. Session state is mutable and may be resident. | Partial streamed events are forwarded but not committed; only final non-partial events update Session state. [Cancellation](https://adk.dev/runtime/cancel/) preserves committed history and propagates to model/tools; [resume](https://adk.dev/runtime/resume/) is explicit. | Closest agent precedent for “transport fragments are not semantic history.” With no streaming UI, OnePage has even less reason to construct or retain partial semantic events. Do not copy mutable Session scratch state. |
| [LangGraph](https://docs.langchain.com/oss/python/langgraph/persistence) | Persists full graph checkpoints at superstep boundaries plus per-task pending writes. Workflow code replays from checkpoints. | Parallel task results can survive one sibling's failure. [Durable execution](https://docs.langchain.com/oss/python/langgraph/functional-api) requires serializable task results, deterministic orchestration, and idempotent effects. | Validates durable independent sibling settlement followed by a later boundary. Do not import checkpoint snapshots, reducers, positional replay, or graph/version compatibility into a linear Turn model. |
| [Temporal](https://docs.temporal.io/workflow-execution) | Service persists Event History; workers may cache Workflow state, but eviction is repaired by replay. External effects are Activities. | Commands are batched at Workflow Task boundaries. [Retry timing](https://docs.temporal.io/encyclopedia/retry-policies) is durable service state; a worker need not remain resident. Activities may re-execute and should be idempotent. | Validates durable retry facts and no transaction/worker across external I/O. OnePage should not copy Event History replay, workflow caches, heartbeats, versioning, or distributed Task Queues. |
| [Oban](https://oban.hexdocs.pm/job_lifecycle.html) | SQL rows are the queue and record scheduled, available, executing, retryable, and terminal states. | A bounded queue claims available work. [The stager](https://oban.hexdocs.pm/Oban.html) promotes scheduled/retryable rows on a one-second default interval; notifications improve latency but polling remains fallback. [Orphans](https://oban.hexdocs.pm/troubleshooting.html) remain durable after process loss. | Strong precedent for `eligible_at` plus one bounded poll and no resident retry timer. Do not copy the persisted lifecycle enum or automatic retry of arbitrary tools; OnePage derives condition from normalized facts and distinguishes evidence from accepted meaning. |
| [libcurl multi](https://curl.se/libcurl/c/libcurl-multi.html) | One multi handle owns per-transfer easy handles and shared transport caches; no semantic durability. | One thread can drive thousands of simultaneous transfers and wait on application FDs too. The [write callback](https://curl.se/libcurl/c/CURLOPT_WRITEFUNCTION.html) receives borrowed chunks of unpredictable size. [`curl_multi_wakeup`](https://curl.se/libcurl/c/curl_multi_wakeup.html) is explicitly coalescing, not a counted event queue. | Directly supports one model/Bash reactor, borrowed-window writes, and advisory “wake then rescan” semantics. It also warns that DNS may block without the appropriate resolver backend and that multi-handle failure makes all transfer state uncertain. |
| [NGINX](https://nginx.org/en/docs/dev/development_guide.html) | Workers precreate a bounded connection table and refuse new connections when exhausted. Event loops own readiness; blocking work may be offloaded rather than placed on the I/O loop. | [Proxy buffering](https://nginx.org/en/docs/http/ngx_http_proxy_module.html#proxy_buffering) uses fixed memory buffers and spills excess response bytes to bounded temporary files; [request bodies](https://nginx.org/en/docs/http/ngx_http_core_module.html#client_body_buffer_size) similarly spill beyond a small buffer. | Strong physical precedent for bounded control records plus disk-backed bodies and for keeping Patch/SQLite blocking work off the reactor. NGINX relays bytes and has no OnePage semantic authority, so its per-request buffer counts are not targets. |
| [HAProxy](https://github.com/haproxy/haproxy/blob/master/doc/intro.txt#L400-L430) | Event-driven engine with capacity derived from file descriptors, TLS, buffer size, and memory. It is intentionally stateless for failover. | [`maxconn`](https://github.com/haproxy/haproxy/blob/master/doc/configuration.txt#L3912-L3978) stops admission at process capacity. [`tune.buffers.limit`](https://github.com/haproxy/haproxy/blob/master/doc/configuration.txt#L4148-L4183) hard-limits buffers and makes tasks wait, but the manual warns sustained shortage can freeze tasks until timeout. | Validates aggregate capacity and measuring TLS/kernel terms separately. Its buffer-wait warning supports OnePage's choice not to pause a provider or Bash pipe indefinitely while waiting for semantic workspace. HAProxy is not a disk-spooling or durable-workflow precedent. |
| [SQLite](https://www.sqlite.org/wal.html) | WAL provides atomic commits and concurrent readers with one writer; the WAL, SHM, and database are one storage unit. Only one write transaction exists at a time. | [`BEGIN IMMEDIATE`](https://www.sqlite.org/lang_transaction.html) acquires write authority up front. Incremental [BLOB I/O](https://www.sqlite.org/c3ref/blob_open.html) supports fixed-size, windowed access, but an open BLOB is an unfinished statement and therefore prolongs its transaction. [`cache_size`](https://www.sqlite.org/pragma.html#pragma_cache_size) bounds the suggested pager cache. | Strong support for one short-write owner, bounded import windows, and no read/BLOB handle across external I/O. Checkpointing, long readers, cache, and the storage unit still require explicit production tests and budgets. |
| [macOS `kqueue`](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/kqueue.2.html) and [POSIX `kill`](https://pubs.opengroup.org/onlinepubs/009604499/functions/kill.html) | Kernel readiness records identify descriptors/processes; they do not own application semantics. | `EVFILT_READ` reports readable sockets/pipes, `EVFILT_PROC` reports exit, and one-shot/clear flags require explicit rearming. A signal requests action; `kill(0)` cannot reliably prove child termination, which requires `waitpid`. | Supports one readiness owner for sockets, pipes, and child exit. It also supports OnePage's separation of committed cancellation intent, physical interruption, and terminal evidence after transport relinquishment or child reap. |

## Mechanism-by-mechanism assessment

### Where OnePage follows mature patterns

1. **Durable backlog, volatile execution custody.** Temporal and Oban keep due
   work durable while workers are replaceable. OnePage's SQL eligibility fact
   and fixed poll are the smallest local form of that pattern.
2. **Readiness rather than one worker per connection.** libcurl, NGINX, HAProxy,
   and `kqueue` all support one owner for many mostly idle FDs. The measured 89
   KiB/credit slope is library/kernel state, not justification for a Turn worker.
3. **Disk-backed payload, small resident window.** NGINX spills bodies beyond
   bounded buffers. OnePage goes further by making pre-settlement scratch
   unlinked and non-recoverable, because SQLite alone owns recoverable content.
4. **A blocking-work boundary outside the reactor.** NGINX explicitly offloads
   operations that would block its event loop. Keeping SQLite and Patch off the
   reactor follows this rule.
5. **Cancellation is a request, not proof.** Agents SDK/ADK drain or finalize
   after cancellation; POSIX separates signaling from reaping. OnePage's effect
   owner terminalizes evidence before settlement.
6. **Parallel physical completion need not choose semantic order.** LangGraph's
   task-level pending writes show that sibling results can persist independently
   before a later superstep. OnePage's separate child settlements followed by
   an atomic call-ordinal Tool Result projection is a simpler linear equivalent.

### Deliberate deviations and tradeoffs

- **No workflow replay or checkpoint snapshots.** This removes a large class of
  graph state, deterministic replay, code-version, and cache machinery. The
  tradeoff is that every legal next action must be derivable from bounded
  relational queries and tested as such.
- **Completion and Resolution are separate facts.** Generic job systems usually
  collapse observed execution and accepted state transition into one lifecycle
  update. OnePage needs the distinction for duplicate provider work, lost Bash
  custody, and Patch attribution uncertainty. This is extra schema, but it
  deletes generic contradictory-evidence selection and keeps meaning explicit.
- **Physical preparation occurs after Attempt commit.** Proxies prefer reserving
  critical resources before accepting work. OnePage reserves only its bounded
  credit/record, then records descriptor, scratch, serialization, DNS, TLS, or
  spawn failure as Attempt evidence. This simplifies reservation and preserves
  auditability, at the cost of admitting Attempts that may fail locally.
- **No automatic Bash/Patch retry.** Temporal and Oban default toward retryable
  work; OnePage instead returns a call-correlated Tool Result and lets the model
  choose. This avoids replaying non-idempotent workspace effects.
- **One SQLite connection and owner.** This is simpler than distributed queues
  and avoids multi-writer races. It serializes semantic commands and may expose
  import/checkpoint tails; add read connections or another writer only after a
  measured need.
- **Unlinked transient scratch is not a durable spool.** NGINX/Postfix-style
  named spools can be recovered. OnePage deliberately discards incomplete raw
  evidence on Host loss and reconstructs meaning from unresolved Attempts.
- **Global serial Patch execution has weak precedent.** A separate blocking-work
  boundary is well supported; serialization of unrelated workspace mutations is
  only a V1 memory/simplicity choice. Its throughput and fairness cost must be
  measured before it becomes a permanent invariant.

## Ranked simplification opportunities

1. **Keep one durable scheduler: SQL eligibility plus one fixed poll.** Do not
   add notification correctness, a timer wheel, resident retry records, sleeping
   workers, or a second ready queue. Oban demonstrates that a one-second staging
   poll is a normal baseline; #68 may change only the number.
2. **Commit no transport chunks.** With no streaming UI, raw provider events
   should go straight to scratch. Parse and validate the sealed response once.
   Do not add an online semantic detector or per-token Host messages.
3. **Keep Host Runtime as one deep module.** Storage Owner, reactor, Patch lane,
   custody records, and wakes are private ownership details—not new domain
   entities, public services, or separately configurable subsystems.
4. **Challenge global Patch serialization.** Keep blocking Patch work off the
   reactor and SQLite owner, but phrase the single lane as an initial measured
   implementation. If concurrent Patch demand matters, first test it; do not add
   Workspace locks, per-workspace schedulers, or automatic replay.
5. **Keep one SQLite connection for V1.** WAL already gives future read
   concurrency, but more connections add busy/checkpoint and version-safety
   cases. Add them only for measured observer latency.
6. **Keep allocator pressure relief outside semantics.** It is an optional
   zero-credit memory optimization owned by #68, not a lifecycle phase or a
   condition for correctness.
7. **Do not generalize the retry classifier.** Attempt admission, model retry
   settlement, tool failure, and Host fail-stop have different owners. A global
   workflow failure engine would add invalid combinations without deleting code.

## Coverage: must test versus defer

Issue #52 and the Host Runtime evidence have different completion bars. The
relational cutover must prove semantic authority in production Zig/SQLite code;
the physical-runtime work must prove bounded custody and real I/O. The
disposable C artifact is evidence only for the latter.

### Must prove in production issues #52, #34, and #43

| Owner | Semantic test | Why current evidence is insufficient |
| --- | --- | --- |
| #34 | Crash matrix around Attempt commit, physical launch, retry eligibility, cancellation, effect settlement, and Physical Custody release | The disposable C explicitly removed these Host Runtime oracles. |
| #34 and #43 | Duplicate or stale physical publication, Host restart with an unresolved Attempt, exact retry manifest, retry horizon, clock movement, and cancellation during delay | SQL uniqueness is designed but not yet integrated with the production Host and provider. Temporal and Oban demonstrate why durable retry and orphan recovery are separate from transport success. |
| #52 | Two or more sibling tools finishing out of order, process death between individual settlements, then atomic call-ordinal Tool Result projection | The design is sound and has LangGraph precedent, but no current test proves OnePage's bounded query and projection command. |
| #34 | Cancellation before dispatch, during Physical Custody, after seal, during settlement, and racing with valid terminal evidence | Bash terminalization is physically tested, but cancellation authority and effect-owner settlement are not. |
| #34 and #43 | Effect-specific recovery and error feedback: safe model retry, indeterminate Bash, Patch reconciliation, and ordinary typed Tool Results that let the model continue | The current prototype does not exercise the production classifiers, provider boundary, or model-visible consequence. |
| #52 | Schema constraints and bounded Decision Snapshot queries for Session occupancy, parentage, ordinals, one Completion per Attempt, one Resolution per Operation, exact replay, and conflicting replay | These are the core claim that normalized SQLite rows replace the old Ledger/Core authority. |

### Must prove in issues #67 and #68 before publishing capacity

| Physical or budget test | Why current evidence is insufficient |
| --- | --- |
| Real provider request upload, authentication, DNS, TLS, HTTP version, fragmentation, terminal event, timeout, disconnect after provider acceptance, and cancellation | The prototype used a synthetic local TLS/SSE server. Agents SDK's replay-safety rules show that partial output materially changes retry safety. |
| Production-shaped request construction from SQLite to scratch/upload without whole-request allocation | The post-commit input path is specified but not exercised. Current V1 provider items, tool descriptors, and opaque continuation material may have different shapes; future provider-specific preserved-thinking and compaction semantics remain separate research. |
| WAL + `synchronous=FULL` under the production schema: 100 sealed imports, checkpoint crossing, a long reader, `SQLITE_BUSY`, `SQLITE_FULL`, `SQLITE_IOERR`, restart recovery, and fail-stop | Memory-bounded windows do not bound transaction duration or checkpoint latency. OnePage pins SQLite 3.53.4; the remaining question is production behavior, not dependency selection. |
| Homogeneous worst cases: 100 model streams; 100 Bash stdout/stderr floods; Patch burst/throughput; asymmetric hot producer; simultaneous terminal burst | The main measured shape was 74 model + 25 Bash + 1 Patch. It does not establish fairness, Patch capacity, or per-effect worst-case slope. |
| Whole-machine accounting: child RSS, socket/pipe buffers, page cache/writeback, scratch logical/physical bytes, SQLite cache, FDs, and thread stacks | Parent physical footprint alone cannot set #68 budgets. |
| Shutdown for a real provider, live import, and real Patch mutation/reconciliation | Bash escalation/drain/reap is tested; the other terminalization paths are not. |
| Aggregate quota and overload admission under retry storms and terminal backpressure | Individual disk/full/output failures were tested, but the system-wide atomic overload result and fairness budget remain #68 work. |

The following should be deferred unless a measured product need appears:

- distributed workers, leases, heartbeats, cross-host recovery, and worker
  versioning;
- generic workflow graphs, reducers, replay, time travel, or checkpoint forks;
- durable partial-token/provider-event history or a streaming-UI event bus;
- provider-specific server-side compaction and encrypted-reasoning semantics
  beyond preserving an extensible opaque/canonical seam for #59 research;
- multiple SQLite writers, read replicas, and notification-based retry wakeups;
- dynamic Patch pools, Workspace locks, per-workspace schedulers, and automatic
  Bash/Patch retry; and
- adaptive allocator/cache tuning before #68 establishes a stable budget.

## Machinery to explicitly avoid

- resident Session/Turn graphs, workflow interpreters, checkpoint snapshots, or
  event-history replay alongside relational authority;
- one thread, task object, response buffer, candidate arena, or timer per active
  Turn/Attempt;
- a durable Completion inbox, consumption watermark, generic effect journal, or
  replay scan of transient scratch;
- separate semantic and physical queues representing the same runnable work;
- provider callback events as Host work items, or a counted wake protocol when
  a coalesced wake followed by bounded scan is sufficient;
- holding SQLite transactions, read cursors, or incremental BLOB handles across
  provider, Bash, Patch, or retry waits;
- treating cancellation signal delivery as Completion evidence;
- blocking socket/Bash drainage while waiting for parser space or SQLite; and
- Workspace-wide exclusion presented as correctness when external processes can
  still mutate the same files.

## Conclusion

OnePage has selected a conventional, defensible physical shape and a deliberately
small semantic engine. There is no missing industry-standard scheduler, worker
pool, durable event bus, or replay subsystem that should be added. The principal
risk is evidence coverage: real provider I/O, production SQLite boundaries,
ordered sibling projection, retry/cancellation races, whole-machine pressure,
and Patch throughput remain unproved.

The next design step should therefore be deletion- and test-oriented: keep the
current topology, make the Patch lane conditional, finish #67's real physical
gates, set #68's budgets, publish #69, and prove semantics only in the actual
#52 commands.
