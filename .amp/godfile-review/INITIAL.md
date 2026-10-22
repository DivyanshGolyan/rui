# God-file review: initial independent judgment (Opus)

Reviewer: Claude Opus 5.5 (`claude-opus-5-5`), Amp cloud orb, thread
https://ampcode.com/threads/T-01a16435-85fa-71ab-90c5-fe449030d56d. Report only.

Audited pin: `origin/main` = `c149d1b3c0722cf4750b2bb6a6332ce38f2f0d86`
(2026-10-22 14:17:38 UTC, "session view: fall back to stdout when a failed
result's stderr is blank").

This file was written and committed **before** reading Sol's report
(`review/modularity-20261022`, `5d480a45`). Its git commit hash and SHA-256
are recorded in `REPORT.md`; it is not edited afterward.

## Measured sizes at the pin

| File | Lines | Bytes | Top-level `test` blocks | Test-block lines | Production decl lines* | Test-helper decl lines* |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `src/store.zig` | 16,428 | 910,397 | 153 | 7,905 | 7,555 | 629 |
| `src/server.zig` | 7,659 | 364,084 | 44 | 3,011 | 4,318 | 124 |
| `src/client.zig` | 5,839 | 329,415 | 69 | 2,306 | 3,216 | 66 |

\* From `scripts/inv.py` (top-level declaration spans, trailing blanks/comments
trimmed); helpers classified by name. Approximate, not a compiler count.

Commit history at the pin covers 2026-09-13 onward (158 / 204 / 92 commits
touching each file). Co-change was measured per commit by mapping `-U0` hunks
onto the declaration regions **of that commit's own version** of the file,
then grouping regions by responsibility (`inventory/*.spec*.json`); test
blocks are excluded. Renamed/removed declarations are unmapped and listed by
the scripts. This is an estimate of independent change, not proof.

Method: declaration inventory, intra-file cross-reference by name
(`scripts/xref.py`), `Host` field usage per region, external callers by
`rg`, reading of the lock/fence owner, report capture, content reader,
compaction decision, execution owner, intake and capture code.

## src/store.zig — keep intact (deep module). No split recommended.

Responsibilities present: connection open/close and SQLite configuration
(`Store.openWithOptions` 1423–1497, `bootstrap` 7042–7298,
`validateExisting` 7300–7333); the lock/fence owner (`Ordinary`, `Access`,
`enter`, `fence` 1268–1400); admission (configure/message/stop/interrupt/
permission 1564–2273 and helpers 6452–6852); public reads (pages, activity,
proposals 2274–3173); Session report/list JSON capture
(`SessionReportCapture` 831–1014, `captureSessionReport`…`appendInlineContent`
3174–4150, ≈1,190 lines); execution admission/settlement/recovery
(4185–5071, 5596–6138); Operation-bound historical view (532–743, 5072–5595);
content import/read (`ContentReader` 1018–1056, 6139–6441, 6853–7040).

Why these are **not** independently changing modules:

1. **One secret: the schema.** Every group embeds SQL against the same tables.
   Co-change with the schema DDL (`bootstrap`) is high and the DDL never
   changes alone: schema touched in 37 commits, **0** solo; execution+schema
   31, admission+schema 22, historical+schema 22, report+schema 12. Moving any
   query family out moves schema knowledge across a file boundary, so a table
   change would propagate to more files, not fewer (Parnas: the hidden
   decision is the representation, and it is currently hidden).
2. **One concurrency owner.** All 42 `pub fn`s go through `enter` →
   `Access.finish*` → `release`; `fence` is the only fence setter (1396).
   These are private decls. Zig has no package-private visibility, so any
   sibling file implementing Store queries would need `Access`, `enter`,
   `prepare`, `bind*`, `readText` etc. made `pub`, which makes them reachable
   from `server.zig`, `model_adapter.zig`, `provider.zig`, `bash.zig` (all
   import `store.zig`). That weakens the canonical-fault-fencing contract
   (AGENTS.md contract table) and breaks its source-level enforcement test,
   which `@embedFile("store.zig")` and counts lock/fence sites in that one
   file (store.zig:9154–9171).
3. **Deep interface.** ~42 public methods plus value types hide ~7.5k
   production lines of SQL, transactions and representation decoding
   (Ousterhout deep module). External callers: `server.zig` (nearly all),
   `model_adapter.zig` (historical view, settle, open content), `provider.zig`
   and `bash.zig` (types). No caller reaches into rows.
4. **Report capture is the most separable part, and still not worth moving.**
   `SessionReportCapture` (831–1014) is a scratch-file JSON writer with no SQL;
   it is the one region with a clean seam. But the ~1,000 lines that drive it
   (`renderSessionReportLocked` 3271–3372, `append*` 3373–4150) are SQL
   projections that must run under one `Access` (one read snapshot) and use
   `readToolOutcomeFacts`, `validateActiveTurnToolCalls`, `readSession`,
   `countPendingMessages` from other groups (xref: report→admission 8,
   report→execution 3, report→content 10). Report co-changed with
   public-reads 15, execution 15, schema 12; solo only 4 of 31. Extracting just
   the 184-line writer is function shuffling with no change-isolation benefit.
5. **Tests are half the file.** 7,905 test-block lines + 629 helper lines. Zig
   tests in another file lose access to private decls (`storage.database`,
   `exec`, `failAtStepForTesting`, `settleCallsForTesting`). Moving them would
   force more `pub` surface. Size here is test density, not design debt.

Things I would *not* call a problem: one 5,688-line `Store` struct; the
257-line `bootstrap` DDL; long SQL constants at 32–105.

Minor observation (not a split): `strict_paths.py` already lists
`src/*schema*` though no such file exists; irrelevant unless a schema file is
created, which I do not recommend.

## src/server.zig — one justified split: separate the execution owner from intake/HTTP.

Production regions (≈4,318 lines): `Faults`/`Host`/`Limits` (34–168);
`Intake` (173–832, 660 lines: sockets, poll loop, two worker stacks,
exchange header/body deadlines, retirement); `serve` (843–1096); the
**execution owner** (1098–3010, ≈1,900 lines: `ExecutionSlot` variants,
`checkSlotCustodyAgreement`, `AuthWorker`, `executionMain`, `NativeTurn`,
Bash/model preparation/launch/completion, retained cleanup,
`shutdownExecution`, `finishCustodyNow`, `fenceDispatch`); test trace/
observation (3011–3428); HTTP routing (`Route`, `prepareReply` 3544–3914,
`HeaderReader`); JSON reply rendering and `Reply` delivery (4076–4719).

Evidence that the execution owner changes independently:

- Co-change (204 commits): execution region touched 93, **40 solo** — the
  largest solo count in any of the three files. Intake 18/9 solo; HTTP route
  34/10; render 15/5. Intake+execution co-changed in only **2** commits;
  execution+http-route 13.
- Disjoint state: by `Host` field use, the execution region reads `custody`
  (32), `retention`, `auth_worker`, `capture_writer`, `provider_endpoint`,
  `authentication`, `bash_*`; intake/HTTP read `intake_capacity`,
  `request_counter`, `instance`, `lease`, `store`, `allocator`. The execution
  region names `intake` once (wakeListener 2997–2999 → `Intake.notify`,
  556–559, a single wake-socket write).
- Different threads and lifetimes: intake has its own poll thread and two
  workers (Worker.run 190–209); execution has its own thread (`executionMain`
  1353) plus auth/capture threads. ARCHITECTURE "Exclusive Store ownership"
  and "Infrastructure shutdown" already name these as two owners that drain
  independently.
- Cross-reference (xref.py): intake→execution uses only `fenceDispatch`,
  `nowNs`; execution→intake only `notify`; execution→http-route only
  `SettlementTrace`.

Concrete proposal (S1):

- New file **`src/server_execution.zig`** (name chosen so `src/server*`
  keeps it on the strict path with no `strict_paths.py` change): move
  `AttemptOwner` … `ExecutionSlot`, `slotToken`, `checkSlotCustodyAgreement`,
  `checkSharedPreparation`, `AdmissionProgress`, `LifecycleMeasurement`,
  `AuthWorker`, `executionMain`, `NativeTurn` and every function from
  `serviceOneCompletion` (1684) through `hasOwnedSlots` (2911), plus
  `AnsweredAttempt`, `settleUnansweredFailure`, `settleFailure`,
  `finishCustodyNow` (2915–2985), with the server tests that drive them
  (≈1,670 test lines by body match: `ExecutionSlot|NativeTurn|custody|…`).
  Public interface: `executionMain(*Host)`, `ExecutionSlot` only if
  `prepareReply`'s host-info needs it (it reads only `host.custody.records.len`).
- Cycle break (required by `tests/ci/import_architecture.py`, which rejects new
  production import cycles): the shared context `Host` (+ `Faults`, `Limits`,
  `TestTransition`, `launchAllowed`/`withEffectLaunch`, `fenceDispatch`,
  `retainDispatchFence`, `nowNs`, and the trace/test-observation helpers
  3011–3428 that both owners call) moves to **`src/server_host.zig`**. `Host`
  currently stores `intake: ?*Intake` only to call `notify`; replace with the
  wake descriptor (`intake_wake: ?posix.fd_t`) so `server_host.zig` does not
  import intake. That is the one non-move edit.
- `server.zig` keeps `serve`, `Intake`, `Route`/`Header`/`HeaderReader`,
  `prepareReply`, rendering and `Reply` (≈2,100 production lines).
- Invariant custody unchanged: the Store→Host launch-gate lock order lives in
  one place (`server_host.zig`), the slot/custody agreement lives with the
  slots, intake never sees `ExecutionSlot`.
- Estimated net: +60 to +120 lines (imports, `pub` on ~15 decls, file
  headers, the wake-fd change). Complexity: unchanged code, smaller per-file
  reasoning set; ≈1,900 production lines that today must be read past for any
  intake/HTTP change become separate. Estimate excludes formatting churn and
  any test-helper duplication I could not see without compiling.
- Strict paths: all three files match `src/server*`; no `strict_paths.py`
  change. **Test selection does change:** `tests/ci/select_tests.py` maps
  the exact path `src/server.zig` (lines 71 and 109) to `check`,
  `admission-debug-integration`, `host-launch-integration`,
  `descriptor-capacity-integration`, `codex-h2-integration` and
  `transport-h2-integration`; an unmapped `src/*.zig` falls back to `check`
  only (lines 229–232). Both new files must be added to those two rows in the
  same change, or the split silently weakens selection. (The same applies to
  `src/client.zig` at lines 55 and 235 for C1.)
- Risk: medium-low. Move-only except the wake fd. Risks are private-decl
  visibility errors (compile-time), test helper placement, and the
  source-pinning tests that `@embedFile` server.zig if any (I found none in
  server.zig; verify with `rg embedFile`).
- Why it simplifies rather than distributes: the moved code is one owner
  with its own thread, state (`slots`, custody) and invariants; the remaining
  file is another owner. The only shared concerns (fence, launch gate,
  trace) become an explicit small context module, which is exactly the
  coupling surface ARCHITECTURE already describes.

Not recommended for server.zig: separating `render*` (≈320 lines) — it is
pure and could move, but it co-changes with routing (7 of 15) and is the
producer side checked against `client.zig` decoders by in-file tests
(4114–4257); low value. Not recommended: separating `Faults` test knobs from
production `Host` — they are referenced at production decision points
(58 uses in the execution region) and moving them changes nothing.

## src/client.zig — keep intact; one optional, low-priority extraction.

Production regions (≈3,216 lines): `Requests` API (18–250, 1609–2015);
page/report/list/observation/mutation decoders (252–620, 929–1608,
1675–2582); durable caller capture records (2583–3161: `CapturedIdentity`,
`CaptureTarget`, `CapturedRecord`, `Capture` 2956–3160, `captureConfigure`/
`captureMessage`/…); transport (3189–3600, 3712–3780: connect, send, response
head parsing, body reads).

Assessment: this is the client half of one wire protocol. Decoders,
requests and transport co-change with each other (requests+transport 10,
mutation-decode+requests 6) and share reply types and `ReplyBuffer`.
`sendSource` takes `Requests` for cancellation/read-failure capture
(3200–3212), so transport is not independent of the request API.

Capture records are the one separately owned concern: a durable on-disk
record format with its own crash-consistency protocol (0700 directory check,
exclusive nonblocking lock file, temporary name, publish, fsync; 2969–2990).
Change data: 22 touches, 6 solo; but co-changed with `inputs` (the typed
inputs being captured) in 10 commits. External users: `cli.zig` and
`SessionSubmission.zig`.

Optional proposal (C1, low priority): move capture records to
`src/request_capture.zig` (CapturedIdentity, CaptureTarget, CapturedRecord,
CapturedText, CapturedConfiguration, Capture, open/inspect/finish,
captureConfigure/Message/SessionStop/ModelInterruption/PermissionDecision,
write*Capture, readCaptured*), ≈600 production lines plus its tests. Break the
would-be cycle by moving `Requests.sendCaptured` (43–51) into the new file as
`send(requests, captured, …)`; callers `cli.zig`, `SessionSubmission.zig`
update. Net ≈ +30 lines. Not strict path; needs the `select_tests.py`
rows for `src/client.zig` (55, 235) extended to the new file. Benefit: hides the record format
and publication protocol from protocol/transport readers. Cost: inputs and
their capture encoding (10 co-change commits) would then span two files. I
judge it marginal; do it only when the next capture-format change lands.

## Summary of initial verdicts

| File | Verdict | Proposed split |
| --- | --- | --- |
| store.zig | Keep intact. Deep, single-secret (schema) and single-owner (lock/fence) module; size is ~52% tests. | None. |
| server.zig | Split justified. | S1: `server_execution.zig` (execution owner) + `server_host.zig` (shared Host context/fence/trace); intake/HTTP stay. |
| client.zig | Keep intact. | Optional C1: `request_capture.zig`, low priority. |
