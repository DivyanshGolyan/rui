# Drift on Rui: the line, client tools, the pi-durable interface and the importer (candidate 2)

Evidence: everything below is designed from the Phase A grounding (`grounding/how.md`, cited as "how §n" or "constraint n") and from source I read in `/home/user/rui` at `d93049f7d` (`src/tool_settle.zig`, `src/tool_record.zig:100-400`, `src/change_ring.zig`, `src/store/access.zig:10-34,526,546`, `src/store/schema.zig:1236-1885`, `src/store/Store.zig:1080-1100`, `clients/ts/src/sessions.ts`, `docs/contracts/inspection.md:192-229,405-426`, `CODING_STANDARDS.md` Engineering) and pi-durable 1.6.0 `dist/*.d.ts`. Nothing was built or run. Where a claim is inferred rather than read, it says so.

## Problem

Drift runs on pi-durable and must move to Rui with the same or better behavior. Rui today answers one request per connection and every observer polls (`inspection.md:532`, `:424`), has no way for an app to run a tool in its own process, never reruns a cut-off call (`execution.md:390`), cannot hold history it did not run (`admission.md:75`), cuts context only by compaction, and reports a Store fence to a TS caller as an anonymous `RuiUnavailableError`.

The shape is not obvious because Rui's rules pull against the obvious push design:

- **The Store is the only memory that counts** and a dormant Session keeps nothing resident (`resources.md:63-71`). A subscription table per Session, or a buffer per waiting tool call, breaks the headline number.
- **One execution thread, no new Host thread.** The intake loop is a `poll()` loop with two blocking workers; Store reads may not run on the intake thread (constraint 4), and commits wake exactly one subscriber (constraint 5).
- **One tool path.** `Runner` is derived from the tool record, never stored, and it is derived in three places that must agree, with bash as the fallthrough in two of them (constraint 11). Settlement has one route (`tool_settle`).
- **Positions are per Session** (constraint 6), one feed projection owns what an observer sees (`reads.activityPage`), and `model_call` rows may appear behind a cursor (D219).
- **History is provenance-checked.** Every entry kind is tied by CHECK and foreign key to a real admission, Operation, output item or Action (constraints 20, 21, 24).

## Usage (caller's view)

### 1. A TS app on `ruicode`

```ts
import { Rui, clientTool, RuiStoreFailedError } from "ruicode";

const rui = await Rui.connect(settings);

// One object declares the tools and runs them. `app` names who may run them.
const tools = rui.clientTools("drift", [
  clientTool({
    name: "lookup_ticket",
    description: "Read one ticket.",
    parameters: { type: "object", properties: { id: { type: "string" } }, required: ["id"] },
    wait: "2m",                    // how long a call may wait for an app, and for its answer
    rerun: { limit: 5 },           // omit: never rerun a cut-off call
    async run(args, call) {        // runs in this process
      call.progress("reading…");   // shown live, never saved
      return { text: JSON.stringify(await tickets.get(args.id)) };
    },
  }),
]);

const session = await rui.sessions.create(
  { model: "gpt-5.2", instructions, clientTools: tools },
  { idempotencyKey: "ticket-42" },
);

const { messageId } = await session.send("Summarise ticket 42", { idempotencyKey: "m1" });
const outcome = await session.settled(messageId);          // resolves on the pushed `turn_ended`

// Every event in the Store, pushed. No polling anywhere in the client.
for await (const event of rui.events({ signal })) {
  switch (event.type) {
    case "entry": log(event.session, event.entry.kind, event.entry.cursor); break;  // numbered
    case "state": render(event.session, event.status); break;      // work snapshot at the Session's end
    case "toolProgress": spinner(event.action, event.text); break; // live only
    case "report": metrics.report(event); break;                   // pi-durable onReport
    case "gap": await resync(event.since); break;                  // rare: see Shape
  }
}

await session.reset({ handoff: "Continue from the plan above.", idempotencyKey: "r1" });
tools.replace([...newDefinitions]);        // re-declare at any time
await session.update({ clientTools: tools });

try { await session.status(); } catch (e) {
  if (e instanceof RuiStoreFailedError) restartWorker();   // the same error reaches every waiter
}
```

`session.listActivity({ follow: true })` keeps its signature and is now a filter over the same line: it reads pages up to the end, then yields pushed entries. The 250 ms to 2 s backoff, `WriteWatch` and `notifications.ts` are deleted.

### 2. Drift, through `ruicode/pi-durable`

```ts
// Before: import { Harness, createRegistry, defineTool, hook, GenerationTask, SessionFailed } from "pi-durable";
import { Harness, createRegistry, defineTool, hook, GenerationTask, CompactionTask, SessionFailed,
         DEFAULT_RESTART_LIMIT, ruiStorage } from "ruicode/pi-durable";      // latest = 1.6

const registry = createRegistry();
registry.add(defineExtension({
  name: "drift.files",
  tools: [defineTool({ name: "read_file", parameters: ReadParams, replay: "safe",
                       execute: async (args, api, ctx) => { api.output("…"); return { content }; } })],
  hooks: [
    hook(GenerationTask, { afterResponse: (message, api) => modelRequests.log(message) }),
    hook(CompactionTask, { beforeCompact: () => { state.reset(); } }),   // observe-only: runs when the compaction is recorded
    // hook(GenerationTask, { beforeRequest }) does not compile: the key is not in this version's HooksOf.
    // Returning { decline } or { summary } from beforeCompact does not compile either: hooks here observe, they do not steer.
  ],
}));

const harness = await Harness.open(
  ruiStorage({ store: process.env.RUI_STORE_URL, app: "drift", importFrom: legacyMysqlStorage }),
  { models, registry, settings: { restartLimit: DEFAULT_RESTART_LIMIT }, onReport },
  context,
);
const root = await harness.root(context);                       // fixed idempotency key
const submission = await root.submit({ type: "input", content: "hi", requestId: "r-1" }, context);
const settled = await submission.wait(context);                 // rejects with SessionFailed on a Store fence
const watch = await root.watch(context);                        // revisions advance on pushed events
await root.reset("carry this forward", context);
const old = await harness.conversation(legacyId, context);      // first open imports it, then it is a Session
```

Drift deletes `mysql-storage.ts`, its request-timeout wrapper and its two pi-ai patches. `importFrom` is the only line that knows the old storage exists; remove it when the eager import has run.

### 3. Moving the data

```sh
# Eager: every conversation, resumable, safe to run twice.
npx ruicode import pi-durable --storage ./dist/mysql-storage.js --store "$RUI_STORE_URL" --app drift
# Any other source: write hub units, hand them to the same door.
rui session import --format rui.transcript/1 --key acme:conv-9 < conv-9.ndjson
```

### 4. A native consumer (`rui app-server`, #2044/#2064)

```zig
var line = try client.Line.open(io, link, .{ .sessions = .all, .runs_app = "codex" });
defer line.close();
while (try line.next(&frame_arena)) |frame| switch (frame) {
    .event => |e| try rpc.notify(codexItem(e.session, e.row)),          // item/started, item/completed, turn/completed
    .tool_call => |c| if (try link.claimToolCall(line.token, c.action, c.attempt)) try rpc.request("item/tool/call", c),
    .tool_progress => |p| try rpc.notify(codexDelta(p)),
    .state => |s| try rpc.notify(codexThreadStatus(s)),
    .lagged => try resync(&line),
    .closed => |why| return closeFor(why),
    .open, .mark, .ping, .report => {},
};
```

The three consumers read the same frames. Nothing in the TS client decides what an event is.

## Shape

### The one idea

**The line is a follower of the change ring that reads the existing feed projection.** A pushed event is a feed row, with the position and ordinal it already has. A pushed tool call is an unresolved client Action row. The Host stores no event log, no subscription and no per-Session cursor; everything pushed is re-derivable from canonical rows, so a reconnect or a Host restart loses nothing durable and the app de-duplicates by an identity the Store already owns (`notifications are hints; committed facts are authority`).

**Push-line decision: numbered events, not nudges.** Each durable frame carries `session`, `position`, `ordinal`. Three reasons. (1) The line must carry frames that no read can return (tool progress, reports, later model deltas for the codex protocol), so "nudge then read" would still need an event path beside it: two ways to do one task. (2) The Host already knows which Session changed and where its new rows start, so a nudge would discard that and make each of three consumers re-implement the catch-up join. (3) pi-durable's `watch()` is revisioned and the interface must be a pure translator. The nudge survives only as the internal mechanism (the ring) and as one honest frame, `lagged`, for the case where the ring cannot say what changed.

### Data structures

```
change_ring.Entry      { session: [6]u8, workspace: u64, first: u64, revealed: u64 }   // +16 B × 4096 = +65,536 B, fixed
                         first    = session.next_position before this commit's takes (access.zig:526 has the head)
                         revealed = admission position of a model_call this commit resolved (D219), else 0

line.Line (one per held connection, heap, fixed size ≈ 24 KiB; at most 16 per Host)
  token: [32]u8 hex            // minted at open; the credential for claims and results
  scope: all | [≤64]SessionId
  runs_app: ?[≤64]u8           // which client-tool owner this line may run
  seen: u64                    // commit generation consumed from the ring
  slots: [256]Slot             // Sessions with undelivered rows: {session, position, ordinal, kinds, since_generation}
  out: [16 KiB] frame buffer   // filled by a worker job, drained by the intake poll loop
  heartbeat_due, pump: idle|queued|running

tool_record            owner gains `client`; `server` holds the app name; three new columns, all part of the record's identity:
                       wait_ms, rerun_limit (0 = never rerun), both NULL unless owner='client'
session                +client_tool_set_id (interned tool_set of client records; NULL = none)
action_operation       attempt_ordinal CHECK relaxed from IN (0,1) to >=0. No new column:
                         unclaimed   = owner client, authorized, unresolved, sender_handle IS NULL
                         claimed     = sender_handle = the claiming line's token, attempt_at, attempt_timeout_ms = wait_ms
                         cut-offs    = attempt_ordinal (each claim increments it)
session_reset          (session_ref, position, at)                    // a reset is a fact at a position
turn                   +context_start (nullable position)             // frozen when the Turn opens
session_import         (session_ref PK, source, source_key UNIQUE, format, next_index, context_from, finished_at)
imported_unit          (session_ref, position, kind, …content ids)    // conversation entry kind 5; provenance is the import row
```

Access patterns, traced:

- *Commit to pushed event.* `Access.finish` records `(generation, session, first, revealed)` and, when at least one line is open, writes one byte to the intake wake pipe (a second fixed listener beside the execution event; an atomic flag coalesces it). Intake wakes, sees `generation > line.seen`, queues one **pump job** for that line on worker 0. The job enters the Store once, turns ring entries in `(seen, now]` that pass `scope` into slots (`position = first - 1`; a `revealed` entry adds a `model_call`-only slot), drains up to 16 rows through `reads.activityPage`, appends frames to `out`, and returns. Intake writes `out` non-blocking. No per-Session memory exists before or after: a slot lives only while a Session has undelivered rows.
- *Reconnect.* The app sends the last `mark` it received. If the ring still covers it and the Host instance is the same, the line resumes there with one number. Otherwise the app sends `catch_up: [{session, after}]` for the Sessions it holds cursors for (at most 64 per open, drained through the same slots) and receives `lagged` for the rest.
- *Model calls a client tool.* The response import writes `model_tool_call` + `action_operation` as for any tool (how §5); the commit touches the Session; the pump job for every line whose `runs_app` matches the record's `server` reads `client_call.offers(session)` in the same Store entry and emits `tool_call`. The row is committed before the frame can exist, by construction.
- *App answers.* `POST /v1/tool-result {action, attempt, token, result}` runs `tool_settle.deliver(.client, binding, …)` on a worker, which calls the same `settleActionAttempt` as bash and MCP. The Store's `WHERE action_id=? AND attempt_ordinal=? AND sender_handle=? AND resolution_code IS NULL` makes it at most once; a repeat answers `already_settled` and changes nothing.
- *Nobody answers.* `client_call.due(now)` is one bounded query modelled on `publishRetryCrossings` (`Store.zig:1082`): it expires calls past their limit, promotes calls past the background threshold, cancels calls a stop superseded, and returns the next deadline. The execution loop keeps that one `?u64`. A Host with no pending client call sends no query.

### Load-bearing decisions

1. **The line is one-way, and it is the only held connection.** `POST /v1/line` answers `200` with `Content-Type: application/x-ndjson`, no `Content-Length`, `Connection: close`; each line of the body is one JSON frame. Everything the app sends (claim, result, progress, declare) is an ordinary one-exchange request. `Exchange.State` gains one state, `streaming`, and `Reply.body` one arm, `line`. `Transfer-Encoding` stays rejected. A `ping` frame every 15 s keeps the existing 60 s "positive byte progress" rule true without an exemption, and tells the app the Host is alive.
2. **Scope is the Store by default.** Because slots are created from ring entries, following every Session costs the same resident memory as following one. Drift's hooks, child Sessions the model started, and the app-server's thread list need no subscribe call. `sessions: [≤64]` exists only so a single-Session viewer is not sent the whole Store.
3. **Frames** (`protocol.LineFrame`, rendered into `openapi.json` so `wire.ts` types them): `open{line, token, instance, mark}`, `event{session, position, ordinal, row}` where `row` is exactly the Activity page's row schema, `state{session, work, queued}` (the page's snapshot, sent when a slot reaches the Session's end), `tool_call{session, action, attempt, name, arguments, call:{position, ordinal}, wait_ms}`, `tool_progress{session, action, text}`, `report{code, text, session?}`, `mark{mark}`, `lagged{since}`, `ping{}`, `closed{reason}`. `event` rows are the 15 existing kinds plus `reset`; hooks are not a second vocabulary (`model_call` is GenerationTask.afterResponse, `tool_result` is ToolTask.afterTool, `compacted` is CompactionTask's one hook, `report` is `onReport`). Hooks therefore observe after the fact: the version layer types every supported handler's return as `void`, so a handler that tries to replace a result or decline a compaction does not compile.
4. **A client tool is a tool record whose owner is `client`.** `Runner.of` returns `.client` for it. The three derivations of the runner (`Runner.of`, `nonBashCallSql`, `attemptRunnerSql`) are first replaced by one comptime owner, `tool_record.runnerSql`, generated from the `Runner` enum, so a fifth runner cannot fall through to bash (unit 1; `encode-lessons-in-structure`). Approvals, the `call` and `tool_result` feed rows, stop substitution, `Final.admit`, result budgeting (`resultProfile(.client)` equals MCP's) and Turn continuation are untouched, because the call enters and leaves through the paths every Attempt uses.
5. **A waiting client call is a row, not custody.** It holds no Active Capacity credit and no Host memory, like a parked `stop_action` (how §5), because the work runs in the app. Background promotion and stop are found by `client_call.due`, and call the same Store transitions custody calls. This is the row-parked form of #1666's "long-running call" core; the sketch names it `client_call` and keeps policy (`client_call_policy.step`) pure so #1666 can lift it.
6. **The claim is the line's token.** `POST /v1/tool-claim {action, attempt, token}` sets `sender_handle = token`, `attempt_ordinal = attempt_ordinal + 1`, `attempt_at`, `attempt_timeout_ms` only `WHERE` the call is unclaimed, so the first claim wins and is saved. The token is minted per line and never reused.
7. **A closed line is a crashed runner.** On a Unix socket a line closes only when the app process ends or closes it. When intake retires a line it queues `client_call.release(token)`; Host start runs `release(all)` in place of `RecoverUncertain` for client Actions. `client_call_policy.onCutOff` decides per call: `rerun_limit = 0` settles `indeterminate` ("the app stopped before answering; the call may have run and was not repeated"); otherwise if `attempt_ordinal < rerun_limit` the call becomes unclaimed again with the same `action` and call id, else it settles `failed` with `restart_limit`. The app sees the same rule from its side: when its line closes, its claims are void, and the TS runner aborts the handlers' `AbortSignal`.
8. **Declaration rides the existing configure command.** `Configuration.client_tools` (name, description, input schema, `wait_ms`, `rerun_limit`, app) is validated, interned as tool records and a `tool_set`, and stored as `session.client_tool_set_id` in a new Session revision. `tool_offer.Freeze` stays the single projection owner and now resolves the Session's intent against the Host set plus this set. Re-declaring is another configure; the next Operation freezes the new offer. A child's set is its parent's, narrowed by the names `start_agent` passes, by extending the existing rule at `configuration_defaults.zig:141`. A client tool may not take the name of a built-in or of an offered MCP tool.
9. **A named storage failure.** On fence, intake (which `fenceDispatch` already wakes) writes `closed{reason:"store_failed"}` to every line before closing it. The contract names `store_failed` as the stable signal and maps `canonical_store_failure` and `dispatch_fenced` to it. The TS client latches the first sighting: every pending exchange, every event iterator, every `settled()` and every later call on that `Rui` rejects with `RuiStoreFailedError`.
10. **Reset is a fact at a position, applied at the next Turn boundary.** `Reset` (keyed command) takes one position, inserts `session_reset`, and, with a handoff, queues the handoff through `sourced_input.queue` as a person Message in the same transaction. `AdmitModel`, when it opens a Turn and finds a reset newer than the previous Turn's `context_start`, freezes `turn.context_start` at the Session head. `replay_recipe.Recipe` becomes `{frontier, floor, start}`: the view keeps entries above `max(floor, start)`, a Compaction Base anchored below `start` is ignored, and "the first Message survives" means the first Message above `start`. `history_floor` and its `purpose=1` CHECK are not touched. The feed gains a `reset` row; nothing is deleted.
11. **Imported history is a fifth entry kind, not forged provenance.** A hub `Transcript` is a header plus ordered **units**: `user`, `assistant{text, calls:[{id, name, arguments, result}]}`, `summary`, `note`. A call cannot exist without its result because the type has no place for one. The Store door is three keyed, idempotent commands: `import_begin(source_key)` creates a Session that refuses Messages and returns `next_index`; `import_append(first_index, units)` is compare-and-append on `next_index`; `import_finish` records `context_from` as the Session's first `session_reset` and opens the Session. An `imported_unit` renders through the pinned codec as plain input items (user message, assistant message, `function_call` with `function_call_output`, summary as a marked user message). It has no Turn, Operation, Action, usage or provider bag, and the feed projects it as `user` / `assistant` / `call` / `tool_result` rows with `origin: "import"`.
12. **The pi-durable interface is two layers.** `pi-durable/translate.ts` maps between `ruicode` domain values and a version-neutral model (tool definition, entry, view, failure reason). `pi-durable/v1_6/index.ts` only names exports with pi-durable 1.6.0's exact types, checked by `satisfies` against the published `.d.ts` (a dev dependency). `package.json` exports `./pi-durable` (latest) and `./pi-durable/1.6`. A name Rui does not support is absent, and a hook key Rui does not support is absent from that version's `HooksOf`. Coverage is pi-durable's own test suite run with `pi-durable` aliased to the layer, against a checked-in expectation file that may only shrink.

### Invariants in types

- A `tool_call` frame and a claim carry `(action, attempt)`; a result carries `(action, attempt, token)`. A stale answer cannot name a current attempt.
- `Runner` exhaustive switches plus the generated SQL fragment: adding a runner fails the build until every site handles it.
- `Transcript.Unit.assistant.calls[].result` is not optional.
- `line.Slot` is the only cursor the Host holds, and the table is a fixed array.
- `clientTool()` returns a branded `ClientTool`; `clientTools:` accepts only a `ClientToolSet`, which cannot exist without handlers, so a Session cannot declare a tool this process cannot run.

### Interface depth

The caller learns `rui.events()`, `clientTool`, `rui.clientTools`, `session.settled`, `session.reset`, `sessions.import` and one error class. Hidden behind them: ring following, slot backpressure, mark and cursor resume, de-duplication, the D219 reveal, claim races between processes, cut-off policy, deadlines, heartbeat, fence latching, chunked resumable import. No wire type is exported: `RuiEvent.entry` is the existing `FeedEntry`, and `LineFrame` stays inside `line.ts`.

### What it deliberately does not do

- No bidirectional socket, WebSocket or SSE; no stored event log; no per-Session subscription.
- No saved tool progress. pi-durable saves partial output about once a second; Rui shows it live only (decided, #2039).
- No `steer`, `continue`, `maxTurns`, `fork`, `write`, docs or loop-changing hooks (mapping table: Check or Drift drops).
- No forged Turns for imported history, so imported units carry no usage and cannot be `read_action` targets.

### Cost

| Thing | Resident | Durable |
| --- | --- | --- |
| Waiting agent (dormant Session) | 0 B added | +8 B (`client_tool_set_id`), +0 otherwise |
| Waiting client tool call | 0 B (a row) | no new column |
| Change ring | +65,536 B once | none |
| Open line | ≈ 24 KiB (6 KiB slots, 16 KiB out buffer, header), at most 16 lines | none |
| Watched Session with nothing undelivered | 0 B | none |

### Contract edits this design requires

`inspection.md:532` (one exchange: except the line), `:424` and `:565` (the line is the one held connection; waits stay client-side filters over it), `:192` (kind `reset`, `origin`), `execution.md:122` and `:390` (runner `client`; rerun only when declared), `model-io.md:483-497` (Session client set), `admission.md:75` (import door), `conversation.md:14` (reset does not rewrite), `store.md:82` (new closed values), `resources.md:101-106` (line and ring bounds), `host.md` (second commit listener).

### How #1650 and #1655 fit

Custom compaction instructions are one more Session setting read when a compaction Operation is admitted; `compacted` already reaches hooks through the line. The test kit is `ruicode/testing`: the scripted provider from the rehearsal plus a `Rui` whose line is real, so `pi-durable/testing`'s names can be a version layer over it.

## Build order

Each unit is one PR, lands green on its own, and leaves `main` coherent. Store format numbers are assigned at landing (current 89); "wire +1" means bump `src/wire_version.zig`, regenerate `openapi.json` and `wire.ts`, bump `WIRE_VERSION`.

| # | Unit | Store format | Wire |
| --- | --- | --- | --- |
| 1 | One owner for the runner derivation: `tool_record.runnerSql` generated from `Runner`; `nonBashCallSql` and `attemptRunnerSql` call it. Behavior unchanged, proven by existing selection and recovery tests. | none | none |
| 2 | The line, events only: ring `first`, second commit listener, `/v1/line`, `Exchange.State.streaming`, frames `open/event/state/mark/lagged/ping/closed`, `line.zig` core in `logic_tests`. TS `rui.events()`, `session.settled()`, `listActivity({follow})` on the line; delete `notifications.ts` and the backoff. Zig `client.Line`; `request wait` and the adapter waits move to it (#1626). Contract edits for `inspection.md`. | none | +1 |
| 3 | Named storage failure: `closed{store_failed}`, contract sentence, `RuiStoreFailedError` latch. | none | +1 |
| 4 | Hooks as events: ring `revealed` for `model_call`, `report` frame from Host diagnostics, `turn_ended.answered` (admission range) if not already served. | none | +1 |
| 5 | Client tool records and declaration: owner `client`, `wait_ms`, `rerun_limit`, `session.client_tool_set_id`, `Configuration.client_tools`, offer projection, child narrowing, `Runner.client`, `client_call.due` expiry. A declared tool is offered and its calls fail `timed_out` at the limit ("no app connected"), which is the decided behavior with no app. | +1 (SQLite and MySQL steps) | +1 |
| 6 | Run client tools: `tool_call` frame, `/v1/tool-claim`, `/v1/tool-result`, `tool_settle.Delivery.client`, background promotion and stop through `due`, cut-off settles `indeterminate`. TS `clientTool`, `ClientToolSet` runner. | none | +1 |
| 7 | Safe reruns: relax `attempt_ordinal` CHECK, `client_call.release`, `onCutOff` with `rerun_limit`, Host-start release. `execution.md:390` edit. | +1 | none (the frame already carries `attempt`) |
| 8 | Progress: `/v1/tool-progress`, `tool_progress` frame, `call.progress`. | none | +1 |
| 9 | Reset: `session_reset`, `turn.context_start`, `Recipe.start`, pressure estimate from the new start, feed kind `reset`, `/v1/control/reset`, `session.reset`. | +1 | +1 |
| 10 | Import door: `session_import`, `imported_unit`, entry kind 5, codec rendering, feed `origin`, `src/transcript.zig` hub, three commands, `rui session import`. Needs 9. | +1 | +1 |
| 11 | pi-durable reader and importer: `ruicode/import` (`transcript.ts`, `pi-durable-1.ts`), `sessions.import`, `npx ruicode import pi-durable`. | none | none |
| 12 | `ruicode/pi-durable`: `translate.ts`, `v1_6/`, export map, coverage run and expectation file. Can start after 2 with conversations and hooks, and grows as 5 to 10 land; lazy import arrives with 11. | none | none |

Units 2 to 4, 5 to 8, and 9 to 10 are three independent chains; 11 and 12 are TS only.

## Synthesis decision

Left for arena.

## Tradeoffs accepted

- We accept that the line is Store-wide and lossless only while the ring covers the app's mark, in exchange for zero resident memory per watched Session. A commit touching more than four Sessions sets `Touched.everything` today and would produce `lagged`; the app then resyncs by cursor for the Sessions it tracks.
- We accept a separate request for claim, result and progress in exchange for leaving the Host's request parser and its `Transfer-Encoding` rejection alone.
- We accept one extra round trip (offer, then claim) in exchange for knowing that an unclaimed call never ran, so it can be re-offered freely without any rerun rule.
- We accept "line closed means runner crashed" in exchange for no claim leases, no claimant table and no heartbeats from the app. A deliberate reconnect therefore cuts off that process's running calls.
- We accept that pump jobs share worker 0 with ordinary routes, bounded at 16 rows per job, in exchange for no new thread.
- We accept that imported history has no usage, no Actions and no provider reasoning, in exchange for not teaching every provenance CHECK to accept rows Rui did not produce.
- We accept re-declaring per Session (one configure per Session) because #2039 decided Session scope; the interface re-declares lazily before a Session's next input.
- We accept that a claimed call that times out is terminal even when the tool is safe to rerun, because the app may still be running it.

## Alternatives considered

1. **Nudge line plus feed reads.** The Host pushes "Session X changed"; the app reads the Activity page. Smallest Host change and no slots, but it cannot carry progress, reports or tool calls, so an event path appears beside it anyway, and three consumers each own the join. It hides nothing the feed did not already hide. Rejected.
2. **A durable event log** (an `event` table with a Store-wide sequence, the line tails it). Gives one resume number that survives a restart, but adds a write to every commit, a second projection that must agree with the feed forever, and retention policy. Split ownership of "what an observer sees". Rejected.
3. **Explicit per-Session subscriptions with Host-held cursors.** Familiar, and exact after ring overrun, but resident memory grows with what is watched, children the model starts need a discovery rule, and every consumer must manage a watch set. A larger interface hiding less. Rejected.
4. **Client tools as an in-process MCP server the TS client hosts.** No Store change, but MCP calls are stateless one-socket exchanges with no claim, no rerun rule and no progress; several Drift processes could not share a call; and #2039 decided against it as the only route. MCP stays as the per-tool alternative.
5. **Client tool as a parked core call.** Reuses `stop_action` parking, but core calls skip `ask` and have no result budget (how gotcha 5), so approvals and budgeting would need a second path. Rejected for "one tool path".
6. **Host assigns the call to one line instead of apps claiming.** Saves a round trip, but a line that dies between assignment and delivery leaves a call that never ran marked outcome-unknown. Rejected.
7. **Reset as a forced compaction with an empty summary, or as a history floor.** Compaction keeps every user Message (constraint 30) and the floor is fenced to `purpose=1` with readers that assume it (constraint 28). Both overload a mechanism whose invariants differ. Rejected.
8. **Reset as a new Session linked to the old one.** No Store change, but the Session id, parent links, queued input and the app's handle all change, and "keep the history" becomes a client-side stitch. Rejected.
9. **Import by synthesizing Turns, Operations, output items and Actions.** The feed and `read_action` would need no change, but replay verifies digests and provider bags and fences on mismatch (constraint 24), so one malformed foreign record could fence a Store. Rejected.
10. **One `ruicode/pi-durable` module with version conditionals.** Less code now; every later version edits the shared file and no compiler says what a version lacks. Rejected for the two-layer split.

## Open questions and risks

1. Does a tool's wait limit run once from "ready", or separately for "no app claimed it" and "the app has not answered"? The sketch restarts the clock at each claim. And should a safe tool whose claim timed out be re-offered rather than failed?
2. Is Store-wide scope acceptable when two different apps share one Host (each sees the other's Session events on the local socket)? If not, scope by `workspace`, which the ring entry already carries.
3. How often does a commit touch more than four Sessions (`Touched.max`)? If often, should `max` rise, or should the ring record a workspace-level entry instead of `everything`?
4. Is a fifth entry kind for imported history acceptable to the owner of `conversation.md`, given replay must render it for every codec Rui pins? What should an imported image part or encrypted reasoning become?
5. Should import carry pi-durable's subagent ownership as Rui parent links, or flatten every conversation to a root Session as sketched? Unsettled pi submissions are re-sent as ordinary Messages under their `requestId`; is that right for inputs queued behind a failed run?
6. Does Drift rely on pi-durable's saved partial tool output after a crash (mapping table Check)? If so, live-only progress is weaker and the decision needs revisiting.
7. Is `turn_ended` able to name the admissions it answered today? I did not verify; if not, unit 4 adds it so `settled()` and `Submission.wait()` are filters, not logic.
8. Does the first Turn after a reset need a reset-aware pressure estimate to avoid one needless compaction? Inferred yes from `turn_policy.nextPurpose` using prior usage; unverified.
9. Result size: the sketch bounds a client tool result by the mutation body limit and MCP's excerpt profile. Does any Drift tool return more?
10. pi-durable 1.6.0's only compaction hook is `beforeCompact`, which runs before summarizing and may decline or supply the summary. The interface can only call it after Rui recorded the compaction, as an observer. Is "after, observe-only" enough for Drift's state reset, or does Drift decline or replace summaries (then #1650 must grow)? The same question applies to `afterTool` replacing a result.
11. Unverified in source: that the existing background-promotion Store transition can be called without a custody record; that worker 0 may run a job on behalf of a `streaming` exchange without changes to the quota code at `server.zig:368`.

## Next implementation step

Unit 1: generate the runner SQL fragment from `tool_record.Runner` and move `nonBashCallSql` and `attemptRunnerSql` onto it, then start unit 2 with `src/line.zig` as a pure core and its table tests in `src/logic_tests.zig`.
