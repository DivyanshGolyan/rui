# Drift on Rui: the line, client tools, the pi-durable interface and the importer

Candidate 1. Against Rui `research/pi-durable-surface` at d93049f7d (main 7ce8af39), Store format 89, wire version 24.
Evidence marks: **read** (seen in source, contract or issue), **inferred** (reasoned from what was read), **unverified**.
Nothing here was built or run.

## Problem

Drift runs its agents on pi-durable and must move to Rui without losing behavior.
Four connected pieces are missing, and Rui's existing shape makes each one non-obvious:

1. **A held connection.** Every Host connection is one exchange (`inspection.md:532`, read), the contract forbids held connections for waits (`inspection.md:424`, read), and the Store's commit wake has exactly one subscriber, the execution thread (`Store.zig:456`, read).
   Three consumers need one mechanism: the TS client, the pi-durable interface and a future native `rui app-server` (#2064).
2. **Client tools.** #2039 decided the route: an app tool is an ordinary Action that the app runs.
   But the Runner is a closed enum derived in three places with Bash as the silent default (`tool_record.zig:391`, `action.zig:159`, `:865`, read), every live Attempt holds process-local custody (`resources.md:14`, read), and there is no second Attempt (`attempt.zig:3`, read), so "rerun if safe" is new Store behavior.
3. **The pi-durable interface** must keep pi-durable 1.6.0's names over Rui's core, be versioned, and add no behavior of its own.
4. **The importer.** The contract forbids history transfer (`admission.md:75`, read). Entry kinds are closed and every entry's provenance is foreign-keyed to a real Admission, Operation or Action (`schema.zig:1723`, read).

Also in scope: hooks as watched events, one named storage-failure error, and reset (`history_floor` is legal only on compaction Operations and never drops the first Message, `schema.zig:1684`, `historical.zig:1120`, read).

Constraints the design honors: no new Host thread; the Store is the only memory that counts; about 8 KB per waiting agent; every format change ships SQLite and MySQL steps; wire changes bump `wire_version.zig`; nothing is sent twice except tools declared safe to rerun; the #1666 cores (one inbound-input writer `sourced_input.queue`, one long-running-call lifecycle) and #1652 (relist changes only the Host-wide set) stay the owners of what they own.

## Usage (caller's view)

### A TypeScript app (`ruicode`)

```ts
import { Rui, appTool, RuiStoreFailedError } from "ruicode";

// Drift runs several processes against one detached MySQL Host; each attaches to it.
const rui = await Rui.attach("/srv/drift/rui");          // single-process apps keep Rui.connect(settings)

const runSql = appTool({
  name: "run_sql",
  description: "Run a read-only SQL query against the warehouse",
  inputSchema: { type: "object", properties: { sql: { type: "string" } }, required: ["sql"] },
  replay: "safe",            // after a crash Rui sends it again, at most restartLimit times
  restartLimit: 5,
  waitMs: 10 * 60_000,       // nobody answers within 10 minutes: the call fails
  async run(args, call) {
    call.progress("scanning partitions");                    // shown live, never saved
    const rows = await warehouse.query(args.sql, { signal: call.signal }); // aborted on stop
    return { content: JSON.stringify(rows) };                  // or { error: "..." }
  },
});

const root = await rui.sessions.create(
  { workspace: "/srv/drift", model: "gpt-6-sol", appTools: [runSql] },  // declaring is a Session setting
  { idempotencyKey: "root:drift" },
);
const serving = rui.tools.serve(root, [runSql]);   // this process claims and runs calls for root and its helpers

for await (const event of root.watch({ after: savedCursor })) {
  switch (event.type) {
    case "entry":    render(event.entry); savedCursor = event.entry.cursor; break; // a saved feed row
    case "work":     setBusy(event.work.state !== "idle"); break;                  // the served work snapshot
    case "progress": showProgress(event.action, event.text); break;               // live only
  }
}

await root.reset({ handoff: "We were fixing the flaky login test. Continue.", idempotencyKey: "reset:42" });
await root.update({ appTools: [runSql, newTool] });  // re-declare at any time; the next model request sees it
await serving.stop();
```

Every pending call on a `Rui` (a `watch`, a `send`, a claim) rejects with one error when the Store fails:

```ts
try { await root.send(text, { idempotencyKey }); }
catch (error) { if (error instanceof RuiStoreFailedError) reopenLater(); }
```

### Drift through the pi-durable interface (`ruicode/pi-durable`)

Drift changes its import path and its storage argument; its calls keep pi-durable 1.6.0's names:

```ts
import { Harness, createRegistry, defineExtension, defineTool, ruiStorage, SessionFailed } from "ruicode/pi-durable";

const harness = await Harness.open(
  ruiStorage({ attach: "/srv/drift/rui", legacy: driftMysqlStorage }),  // legacy: lazy import on first open
  { registry, settings: { restartLimit: 5 }, onReport },
  context,
);
const root = await harness.root(context, { agent: { model: { provider: "openai", modelId: "gpt-6-sol" } } });
const submission = await root.submit({ type: "input", content: "Summarize ticket 812", requestId: "t812" }, context);
const settled = await submission.wait(context);
const watch = await root.watch(context);             // value now, then each change
watch.start(async (call) => { if (call.kind === "value") render(call.value); });
await root.reset(undefined, context);
```

Names Rui does not support (`fork`, `defineDoc`, `defineTask`, `hook(GenerationTask, { beforeRequest })`, `whenBusy: "steer"`) are not exported or not in the types, so Drift's compiler lists them.

### Moving Drift's data

```ts
import { importConversation, importAll } from "ruicode/pi-durable/import";
await importAll(rui, driftMysqlStorage, { namespace: "drift", spec, context });   // eager, one command
// or nothing: ruiStorage({ legacy }) imports a conversation the first time harness.conversation(id) opens it
```

`npx ruicode-pi-durable-import --attach /srv/drift/rui --storage ./drift-storage.js` runs `importAll`.

### The model

An app tool looks like any tool. A crash during an unsafe app tool gives the same "may have run, not repeated" result as Bash. A call that waits past its limit fails with a sentence that names the limit. A long call goes to the background after 30 s like every other Action.

### A native `rui app-server` (codex protocol)

It holds one line and turns `changed` into `thread/*` and `item/*` notifications by reading the feed, and `calls` into `item/tool/call` requests by claiming:

```text
GET /v1/line  (Upgrade: rui-line/1)          ← 101, then length-prefixed JSON frames both ways
← {"t":"hello","line":"9:2","instance":"…"}
→ {"t":"watch","sessions":["a1b2c3"]}   → {"t":"serve","lanes":["a1b2c3"]}
← {"t":"changed","session":"a1b2c3"}    (read /v1/activity-page from your cursor)
← {"t":"calls","lane":"a1b2c3"}         (POST /v1/app-call-claim)
← {"t":"cancel","action":"41","attempt":1}
← {"t":"failed","code":"store_failed"}  (then the Host closes the line)
```

## Shape

### The load-bearing decision: durable facts are read, transient facts are pushed

The push line carries **nudges** for everything that is saved, and **payload** only for what is never saved (tool progress, cancels to a runner, the failure notice, and later live text deltas).
A nudge names a Session (`changed`) or a tool lane (`calls`). The app then reads saved facts through the existing doors: the activity feed from its own cursor, or a claim.

Why, against the current recommendation of numbered events:

- **pi-durable's `watch()` is not a numbered stream.** Read in the 1.6.0 README: a watch sends the view at attachment, then each commit's operations, and "a client that joins late or reconnects starts from the current view; nothing is replayed". Only transcript entries resume, by entry id, through `ConversationTranscript.resume`. Rui's feed cursor already gives exactly that, so the interface needs no numbered stream.
- **One reader of saved facts.** Rui's feed projection (`reads.activityPage`) already owns ordering, the `(position, ordinal)` cursor, the `work` and `queued` snapshot, D219's late `model_call` rows, the `since`/`not_modified` short cut and 16 KiB content windows. Numbered events would make the line a second delivery of that projection, with its own windows, backpressure, resume and gap rules (split ownership).
- **Reconnect needs no protocol.** After a dropped line, the client reads from its cursors: the same code as a cold start. This is the contract's existing rule, "Reconnection obtains a fresh complete observation" (`inspection.md:569`, read), and CODING_STANDARDS' "Notifications are hints; committed facts are authority" (read).
- **The Host keeps no per-Session state and no queue.** A line's pending output is a dirty set that coalesces, never a growing queue, so a slow app cannot make the Host buffer. A line can watch `all` Sessions at no per-Session cost; numbered events need one cursor per watched Session in Host memory.
- **Same Store load.** With numbered events the Host runs one feed read per line per change; with nudges the app runs it. Several Drift processes cost the same reads either way. The price of nudges is one extra local round trip (about 0.1 ms on a Unix socket, inferred).

### Data structures

| Record | Owns | New or changed |
| --- | --- | --- |
| **Line** (Host memory, intake) | One held connection: its token, watched Sessions (≤256 or `all`), served lanes (≤16), a dirty set, an 8 KiB transient out-buffer, a 16 KiB frame-in buffer | New. Fixed pool of 64 lines, outside `intake_capacity`. About 27 KiB per open line, 0 per Session |
| **LineSlots** (Host memory, shared) | Which line tokens are live: 64 atomic `u64` | New, 512 bytes. Written by intake, read by workers and execution |
| **LinePost** (Host memory) | Transient posts from execution to intake (cancel to a claimant line) | New. Fixed 256-entry ring, 16 KiB. Full means drop: a cancel is a hint, the durable stop is authority |
| Change ring entry | `(generation, session, workspace)` | Gains `facet: feed | app_calls`. A commit that changes an app call touches its lane's Session with facet `app_calls`. +4 KiB fixed |
| `tool_record.owner` | `rui | provider | mcp` | Gains `app` (and `imported`, unit U9). An app record also carries `replay`, `restart_limit`, `wait_ms`, all in its digest |
| `session.app_tool_set_id`, `session.app_lane` | The Session's declared app records; the Session whose declaration this one runs on (itself for a root, inherited by children) | New columns. `app_lane` is fixed at creation |
| `app_call` | One row per app-runner Action: `lane`, `ready_at`, `wait_until`, `claims`, `claim_line`, `change_seq` | New table |
| `message_admission.source_kind` | 1 person, 2 peer, 3 action_final, 4 action_value, 5 server_event | Gains 6 `reset` and 7 `imported` |
| `conversation_entry.entry_kind` | 1 Message, 2 instruction, 3 output item, 4 skill | Gains 5 **context head**: a marker with `head_position` (≤ its own) and optional text |
| `history_import` | One import: source id, transcript version, item count, digest, `sealed` | New table |
| `turn.import_id`, `model_operation.purpose`, `action_operation.resolution_code` | | Imported Turns: `purpose = 2 imported`, `resolution_code = imported` |

Runner stays derived, never stored (`execution.md:122`): `owner = app` derives `Runner.app`.
Unit U0 first replaces the three hand-written runner derivations with one Zig table that also generates the SQL `CASE`, so a new runner can no longer fall through to Bash in SQL (fixes the class behind gotcha 1, per one-owner-per-rule).

### The line (wire)

`GET /v1/line` with `Upgrade: rui-line/1`, the usual `X-Rui-Host-Instance`, `X-Rui-Wire-Version` and `X-Rui-Store` headers. The Host answers `101` and the socket carries frames both ways: a 4-byte big-endian length, then JSON, the same framing as the launch frame (`host_start.zig:581`, read). Frames are at most 16 KiB.

- App → Host frames change only the line's own process-local state: `watch {sessions | "all"}`, `serve {lanes}`, `progress {session, action, attempt, text}`. They need no Store and run inline on intake.
- Host → app frames: `hello`, `changed`, `calls`, `resync` (the ring wrapped, so read everything), `progress`, `cancel`, `failed`, `ping` every 20 s.
- Durable mutations never ride the line. Claim and result are ordinary keyed exchanges (`/v1/app-call-claim`, `/v1/app-call-result`), so they reuse the request parser, idempotency keys, worker routing and reply-loss recovery. There is one way to send a mutation.

**How a nudge is made** (inferred from the existing intake shape): the Store's commit wake gains a second fixed subscriber that writes one byte to the existing `intake_wake` pipe, only while a line is open and the pipe is not already armed. On wake, intake walks the change ring from its last generation and sets dirty bits on the lines watching each touched Session or serving each touched lane. When a line's socket is writable, intake drains its dirty set into frames. No Store read happens on intake, and no worker job is needed for a nudge.

On fence, `fenceDispatch` already wakes intake (`server_host.zig:647`, read). Intake then writes `failed {code: "store_failed"}` to every line and closes them. On drain it writes `failed {code: "host_stopping"}`.

The contract changes are: `inspection.md:532` gains "except the line: one held, notification-only connection per client, from a fixed pool"; `:424` gains that a line holds no waiter and carries no saved fact.

### Client tools: one Action, one more runner

A call to an app tool is classified, authorized (ask mode applies, because the runner is not core), recorded and settled by the existing code. Only the runner differs.

```text
writeCalls ─▶ Action + app_call(ready_at = now when authorized, else at allow_once)
             wait_until = ready_at + record.wait_ms        lane = session.app_lane
offered:  resolution NULL ∧ authorized ∧ claim_line NULL ∧ now < wait_until
   │  ClaimNext(lane, line, served digests)  — worker 0, one transaction, first claim wins
   ▼
claimed:  claim_line = token, claims += 1, attempt_ordinal = 1, attempt_at = now
   │  Result(action, attempt, line) ─▶ tool_settle.deliver(.app) ─▶ SettleAttempt (unchanged)
   │  line closes / Host restarts ─▶ cutOff(replay, claims, restart_limit)
   │        unsafe            ─▶ indeterminate  ("may have run; not repeated")
   │        safe, claims < limit ─▶ re-offer (claim_line NULL)        ← the only rerun in Rui
   │        safe, claims ≥ limit ─▶ error result `restart_limit`
   │  now ≥ wait_until ─▶ unclaimed: failed (never ran); claimed: indeterminate
   │  stop ─▶ cancelled Resolution now, `cancel` posted to the claimant line
   └─ ready_at + 30 s ─▶ background receipt; the final result arrives as source_kind 3 input
```

Load-bearing decisions:

- **Claim is a pop, not a race over a list.** `ClaimNext(lane, line, tools)` picks the oldest offered call in the lane whose frozen record digest is one the caller serves, and writes the claim in the same transaction. Several Drift processes nudged together each call it once; one gets the call and the rest get `null`. Filtering by digest makes rolling deploys safe: an old process never runs a call made against a newer declaration of the same name.
- **The claim is saved before the app is told** (the claim reply is the telling), and the app's answer carries `(action, attempt, line)`. A repeated or late answer finds `claims` moved on, the claim cut off or the Action settled, and is answered `ignored` with no effect. This is exactly-once delivery by Store guard, not by custody, so `tool_settle` gains a `.app` delivery whose at-most-once comes from that guard. Settlement itself is the shared `SettleAttempt` (fulfillment, retention, background final, stop substitution).
- **An app call holds no custody and no Active Capacity credit**, like #1666's server-held task: the work lives in the app. A waiting or running app call costs 0 Host bytes; its row is its state. Liveness of a claim is "its line token is in LineSlots".
- **Cut-off has one owner.** `app_call.cutOff` is a pure decision over `(replay, claims, restart_limit)`, used by the execution loop's sweep (after a line closes, or after a commit with facet `app_calls`, which also closes the race where a claim commits just after its line closed) and by start-up recovery (every claim is dead after a restart). `RecoverUncertain` keeps Bash, MCP and read_image; app calls never reach it.
- **Deadlines are rows.** The execution loop computes the earliest of `wait_until` and the background due time with one indexed `MIN` query after commits with facet `app_calls`, and sleeps until then. With no app calls it sends no query, which keeps the idle-Host rule (`resources.md:32`, read).
- **Declaring is a Session setting**, in `create` and `update` (`appTools`), stored as content-addressed records like MCP's and read by `tool_offer.zig`, the single projection owner (#2039 build note, read). In the projection, `owner = app` resolves by name against the lane Session's current app set, exactly as `owner = mcp` resolves against the Host set today (`tool_offer.zig:9`, read). A re-declare changes the next Operation's offer; a frozen offer keeps the records, and so the replay policy, it was made with.
- **Helper agents.** A child's lane is its parent's lane. Its app intent is the app names its `tools` lists, or all of the lane's app tools when it lists none, narrowed by the existing parent check (`configuration_defaults.zig:141`, read). Calls from any Session in the lane go to whoever serves the lane, so the app needs no child ids.
- **Progress** goes app → line → Host → every line watching that Session, inline on intake. It is never saved and never wakes the model. A late joiner sees the next update.
- **MCP stays.** An app picks per tool: `appTools` or an MCP server.

### Reset: the context head

A reset is Session input through `sourced_input.queue(.reset)`, the single writer of `message_admission`, with an optional handoff text. It never starts a Turn by itself.
When the next Turn binds input, `AdmitModel` places each queued reset first: it projects a kind-5 **context head** entry at a fresh position, with `head_position` = its own position and the handoff as its text. Queued Messages behind it are projected after it, so they land in the new context.
The request view becomes `Recipe{head, frontier, floor}`:

- the model sees the head's text as the first user message, then entries with position ≥ `head`;
- a compaction base whose anchor is below `head` is not selected;
- the first-Message pin becomes the first Message at or after `head`;
- the memo key gains `head`.

The same entry represents an imported pi-durable compaction summary: `head_position` points at the first kept entry and the text is the summary. This matches pi-durable's own model ("the model sees the entries from the newest reset onward", and a compaction "heads the first entry it keeps", README, read), so the importer maps pi head markers one to one.

### Import: hub, spokes, and imported Turns

- **Hub: Transcript v1** (`transcript/1`), a Rui wire document. Items are `user`, `assistant` (provider family, model, items of text, reasoning with an opaque bag, tool calls), `tool_result`, `instructions` and `head` (by item ordinal, not by foreign id, so the Host holds no id map). The version is in the document. A new hub version adds a reader on the Host side; old spokes keep working.
- **Spokes**, one per foreign format version, in TS because the source is a TS `Storage`: `pi-durable-storage@1` reads only through pi-durable's `Storage` methods (`scanConversations`, `scanEntries`, `findLatestHeadMarker`). It skips entries the model never saw (custom kinds, which Drift drops) and reports their count, never silently.
- **One importer**, in the Host, into the current Store: `ImportBegin` (creates the Session from a spec, marked `importing`, refused to every other input), `ImportAppend` (one transaction per chunk of at most 8 MiB, keyed by item ordinal, so a rerun skips what landed), and `ImportSeal`. A crash mid-import resumes under the same key.
- **The Store contract for history Rui did not run:** an imported conversation becomes ordinary Turns, Operations, output items, tool calls, Actions and Resolutions, so every reader (history replay, feed, `read_transcript`, search, reports) works unchanged. Provenance is explicit at the root: `turn.import_id`, Operation `purpose = imported` (resolved, no provider attempt, nullable provider bag), Action `resolution_code = imported`, tool records `owner = imported` (`Runner.imported`, never runs). Imports fill only a fresh Session's prefix, which keeps positions append-only. Each assistant item must round-trip through the Session provider's pinned codec at import time; a reasoning bag from another provider family is dropped and counted in the import report. `admission.md:75` changes from "no history transfer" to "history transfer only by sealed import into a fresh Session".

### Store failure: one named error

The Host already fences on storage failure. Three paths reach a waiting caller today with three different errors (500 `canonical_store_failure`, 503 `dispatch_fenced`, `RuiUnavailableError` after exit; how.md §8, read). The line adds a fourth, `failed`.
In TS, all four go through one function, `Rui.#fail(cause)`, which maps every store cause to `RuiStoreFailedError` and rejects every pending call. The client keeps reading the Host's stdout after readiness so the `store_fenced` line is no longer lost (`client.ts:372`, read). The pi-durable layer maps it to `SessionFailed`. `inspection.md` names `store_failed` as the stable signal.

### Hooks as events

What Drift's hooks observe is saved, so it is a feed row, and the line nudges it: `model_call` (request and usage, for `afterResponse` logging), `compacted` (now also written when a compaction fails), `call` and `tool_result` (for `afterTool`; the row carries the resolution code, so `indeterminate` and `restart_limit` are visible). `onReport` is derived in the interface from those rows plus the line's `failed` frame; Rui adds no report log. Hooks that change the loop stay out (Drift drops them, mapping table, read).

### The pi-durable interface

- `ruicode/pi-durable/core/` is the shared translator. It owns the version-independent mapping: Rui feed rows to pi `EntryRecord`s, work snapshots to `pi.live`, `ToolRegistration` to `appTool`, the root by fixed key, prompt sections to `instructions`, report derivation, and `RuiStoreFailedError` to `SessionFailed`. It calls only `ruicode`'s public API.
- `ruicode/pi-durable/v1.6/` is a thin layer that exports 1.6.0's names and shapes over the core. `ruicode/pi-durable` re-exports the newest layer. A second pi-durable version adds a sibling folder.
- Anything that needs logic Rui lacks (steer, `maxTurns`, custom compaction instructions #1650) goes into Rui's core first and then appears in every layer.
- Coverage: pi-durable's own test files run with `@earendil-works/pi-durable` aliased to `ruicode/pi-durable/v1.6`, against a scripted provider from the test kit (#1655). A file that fails to compile counts as unsupported.

### Module map

| Path (sketch) | Owns |
| --- | --- |
| `src/line.zig` | Line pool, frames, LineSlots, LinePost, the second commit waker (intake) |
| `src/change_ring.zig` | The `facet` on ring entries |
| `src/tool_record.zig` | `Owner.app`, `Owner.imported`, `AppPolicy`, `Runner.app`, `Runner.imported`, the single runner derivation |
| `src/store/domain/app_call.zig` | Phase, cut-off and expiry decisions, Ready, ClaimNext, Result guard, Sweep, deadlines, cancel post |
| `src/store/domain/context_head.zig` | Reset placement, entry kind 5, `Recipe.head` |
| `src/transcript.zig`, `src/store/domain/history_import.zig` | The hub and the one importer |
| `src/store/schema_steps.zig`, `src/protocol_additions.zig` | Format steps, wire shapes and version bumps |
| `clients/ts/src/{line,watch,tools,transcript,client-additions}.ts` | The client end: line, watch, app tools, import framing, attach, the one failure error |
| `clients/ts/pi-durable/core/translator.ts` | The shared translator |
| `clients/ts/pi-durable/v1.6/index.ts` | The 1.6.0 layer |
| `clients/ts/pi-durable/import/pi-durable-storage-v1.ts` | The pi-durable `Storage` reader spoke, lazy and eager import |

A trace for one app call reads `tool_record.zig` → `app_call.zig` → `tools.ts`: three files.

### Interface depth

| Surface | What it hides |
| --- | --- |
| Line: 3 app frames, 8 Host frames | Commit wake fan-out, change ring walking, coalescing, fence and drain notice, liveness of claims |
| `ClaimNext`, `Result` (2 routes) | First-claim-wins, digest matching across deploys, the at-most-once guard, cut-off and rerun policy, deadlines, backgrounding, stop |
| `appTool({...})`, `rui.tools.serve(lane, tools)` | Declaration records, nudges, claiming, progress, cancel, reconnect, retries of lost claim and result replies |
| `session.watch()` | The line, feed paging, the `since` short cut, content windows, reconnect, store failure |
| `session.reset()` | Placement at the next Turn, the head marker, the request recipe |
| `Import*` (3 Store doors), `importConversation` | Chunking, resumable keys, codec round-trip, provenance |

### What it deliberately does not do

- No event log, no global event order, no per-Session subscription state in the Host.
- No custody for app calls, and no grace period after a line drops: a dropped claimant line is a cut-off.
- No partial tool output saved, unlike pi-durable (see open questions).
- No reset that interrupts a running Turn: a queued reset waits for the Turn to end, like any queued input.
- No history import into a Session Rui has already run.

## Build order

Each unit lands on its own. Format numbers are relative (`schema_number.py` renumbers at landing). Each format unit ships SQLite and MySQL steps.

| # | Unit | Store format | Wire |
| --- | --- | --- | --- |
| U0 | One runner derivation: a Zig table generates `Runner.of` and the SQL `CASE` used by selection and recovery; a test checks them over every owner and built-in | none | none |
| U1 | `RuiStoreFailedError` in TS; keep reading stdout after readiness; `store_failed` named in `inspection.md` | none | none |
| U2 | `Rui.attach(hostDir)` in TS for a detached Host (several Drift processes) | none | none |
| U3 | The line: upgrade route, frames `hello/changed/resync/failed/ping` and `watch`, second commit-wake subscriber, change-ring `facet`, contract amendments | none | 25 |
| U4 | `session.watch()` on the line; delete the polling backoff in `feed.ts` and the local `WriteWatch` (`notifications.ts`), so there is one way to follow | none | none |
| U5 | Reset: `source_kind 6`, entry kind 5, `Recipe.head`, feed row `reset`, `POST /v1/reset`, `session.reset()` | 90 | 26 |
| U6 | App tool declaration: `owner app` with policy fields, `session.app_tool_set_id`, `app_lane`, the projection, child narrowing, `appTools` in configure, the `app_call` table, deadlines. Until U7 every app call fails at its wait limit, which is correct behavior with no runner | 91 | 27 |
| U7 | Claim and answer: `/v1/app-call-claim`, `/v1/app-call-result`, `serve` and `calls` frames, `tool_settle.deliver(.app)`, line-close sweep, stop and `cancel`, background, progress frames; TS `rui.tools.serve`. Formal background model gains the app-held state (verify-background-delivery) | none | 28 |
| U8 | Safe rerun: `cutOff` re-offers safe calls up to `restart_limit`; start-up recovery for app calls | none | none |
| U9 | Hook facts: failed-compaction `compacted` row, resolution code on `tool_result` rows | none | 29 |
| U10 | Import door: `history_import`, imported provenance, `transcript/1`, `Import{Begin,Append,Seal}`, `admission.md:75` change | 92 | 30 |
| U11 | TS Transcript hub types, `rui.import(...)`, the `pi-durable-storage@1` reader, lazy and eager import | none | none |
| U12 | `ruicode/pi-durable` core plus the v1.6 layer, and the coverage run over pi-durable's tests (needs #1655) | none | none |

U0, U1, U2 and U3 are independent. U4 needs U3. U5 needs only U0 to be safe. U6 needs U0. U7 needs U3 and U6. U10 needs U5 (head entries). U12 needs U4, U7 and U11.
#1650 (custom compaction instructions) slots in after U5 as one more Session setting that the compaction request reads; the interface's `compact(instructions)` then translates to it.

## Tradeoffs accepted

- We accept one extra local round trip per change (nudge, then read) in exchange for one reader of saved facts, no resume protocol and no per-Session Host state.
- We accept that a dropped claimant line (including a Host restart while the app survives) ends an unsafe call as "may have run", in exchange for zero Host memory per app call and one liveness rule. pi-durable behaves the same when its process dies mid-call.
- We accept that several app processes all wake on every `calls` nudge and that all but one get `null` from `ClaimNext`, in exchange for no Host-side scheduling and the decided "first to claim" rule.
- We accept that progress is lost on a crash (pi-durable saves it every second) in exchange for no fsync per tick, per #2039.
- We accept a queued reset waiting for the running Turn to end, unlike pi-durable, which ends the run at the next tool round, in exchange for keeping one queue rule (no steer exists in Rui).
- We accept new provenance columns on Turn, Operation and Action, in exchange for every history reader working on imported history unchanged.
- We accept that U6 ships app tools that always time out, in exchange for small units.

## Alternatives considered

- **Numbered events on the line** (each saved feed row pushed with its cursor; the app resumes by sending cursors). It hides the follow loop from clients, but it duplicates the feed projection's paging, snapshot and D219 rules into a stream, needs Host-side cursors per watched Session and backpressure, and still needs unnumbered frames for progress. Rejected for split ownership of "what's new in a Session".
- **A bidirectional line that also carries mutations** (claim, result, message as frames). It saves exchanges, but it creates a second request path beside the HTTP routes, with its own parsing, keys and reply-loss rules. Rejected as two ways to do one task.
- **The Host assigns each call to one line** (push "run this" to a chosen app). No claim herd, but a claim saved before a push that never arrives turns an unsent call into "may have run", and the app cannot decline by capability or deploy version. It also contradicts "first to claim".
- **App calls as core calls that park** (like `stop_action`). Core calls skip approval in both modes and have no result budget (gotcha 5), so this breaks "tools are just tools".
- **App calls in Host custody** (credit and custody record while the app runs). It would reuse custody's backgrounding as is, but it would pin Active Capacity for minutes per call and still lose every claim on restart.
- **Import as quoted text in a fresh Session** (#2038 fallback, or #838's pointer). No format change, but the model sees its own past turns as quotes and the interface cannot rebuild pi entries from them. Kept as the fallback if the owner rejects faithful import.
- **A separate imported provenance on each entry** instead of imported Turns. Every reader would gain an `import` branch, a hand-synced list.
- **Reset as a floor on a normal Operation.** The floor drops whole units below a position but keeps the first Message, and floors follow compaction bases; a reset needs a context start that also moves the first-Message pin and carries handoff text. One head marker serves reset and imported compaction.

## Open questions and risks

1. **Push line: will the owner take nudges for saved facts** (this design) over numbered events? The premise "pi-durable's `watch()` works that way" does not hold for its documents, only for transcript entries.
2. **Should imported history be the Session's own history** (this design), given that #838 (2026-11-03) chose a new empty Session with a pointer and dropped "start a Session with existing history"?
3. **Drift's topology:** are Drift's processes on one machine, sharing one detached Host over its Unix socket? If they span machines, the line and the claim routes need a TCP listener, which is out of this design.
4. Is a queued reset waiting for the running Turn acceptable for Drift, or does it need pi-durable's "ends the run at the next tool round"?
5. Does Drift rely on saved partial tool output after a crash (mapping table "Check")?
6. Does a child that names only built-in tools get no app tools or all of them? This design gives all, reading "names none" as "names no app tool".
7. Drift pins pi-durable 1.4.0, and its MySQL storage implements 1.4.0's `Storage`. Does the reader spoke target 1.4, or does Drift move to 1.6 first?
8. Risk: the formal background-delivery model must gain the app-held state before U7 lands, or "final delivered once" is unproven for app calls.
9. Risk: imported assistant items from a provider family Rui does not serve lose their reasoning bags; the measured loss on Drift's data is unknown until U11 runs on a copy.
10. Risk: the second commit-wake subscriber adds one atomic load per commit while no line is open, and one pipe write per commit burst while one is. This is unmeasured.

## Synthesis decision

Not applicable: this is a candidate. Arena fills this section.

## Next implementation step

U0: write the single runner table in `tool_record.zig` that generates both `Runner.of` and the SQL runner `CASE`, and replace `nonBashCallSql` and `attemptRunnerSql` with it under a whole-domain agreement test.
