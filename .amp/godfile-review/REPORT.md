# God-file review of store.zig, server.zig, client.zig (Opus, cross-model comparison with Sol)

**Audited SHA:** `origin/main` = [`c149d1b3c0722cf4750b2bb6a6332ce38f2f0d86`](https://github.com/DivyanshGolyan/rui/commit/c149d1b3c0722cf4750b2bb6a6332ce38f2f0d86), pinned at review start (commit time 2026-10-22 14:17:38 UTC).
**Reviewer:** Claude Opus 5.5 (`claude-opus-5-5`) in an Amp cloud orb (not a Mac), thread [T-01a16435-85fa-71ab-90c5-fe449030d56d](https://ampcode.com/threads/T-01a16435-85fa-71ab-90c5-fe449030d56d). One reviewer. No nested agents, oracle or second model.
**Scope:** This is a report only. It does not change product, test, workflow or configuration files. It does not authorize implementation.

## Verdict

| File | Lines (test-block lines) | Verdict | Proposed split |
| --- | --- | --- | --- |
| `src/store.zig` | 16,428 (7,905) | **Keep it intact.** It is a deep module with one secret (the schema) and one concurrency owner (`enter`/`Access`/`fence`). | None |
| `src/server.zig` | 7,659 (3,011) | **Split justified.** The execution owner changes independently of intake and HTTP. | **S1**: `src/server_execution.zig` + `src/server_host.zig` |
| `src/client.zig` | 5,839 (2,306) | **Keep it intact.** It is the client half of one wire protocol. | Optional **C1** (`src/request_capture.zig`), low priority |

Order of work: S1 only, if the user approves it. C1 is optional. Nothing is proposed for the Store.

## 1. Independence and provenance

1. I wrote [`INITIAL.md`](INITIAL.md) **before** I opened Sol's report and committed it alone on this branch as `0c7301213a0601631096b6941d971701bd86ee63` (SHA-256 of the file: `7b1fe81cb5b58552c5f0c8fa60f94445600eec29d20485c3b2ed9d86f5a506e6`). I did not edit it afterward. You can check this with `git show 0c730121 --stat` and `sha256sum`.
2. Only after that commit did I read Sol's §5 at `review/modularity-20261022` [`5d480a45`](https://github.com/DivyanshGolyan/rui/commit/5d480a4525100fabc6b0456bfbf5bd8ed2e7e820). I read its verdict table and §1 for pin and coverage. I did not read its R1–R5 findings in detail beyond the summary rows, because they cover other files.
3. **Version difference:** Sol audited `068b1d0c` (pinned 14:06:41Z). I audited `c149d1b3`. `git diff --stat 068b1d0c c149d1b3 -- src/store.zig src/server.zig src/client.zig ARCHITECTURE.md` is empty. The only intervening commit touches the session view. Line numbers in the two reports therefore refer to identical file contents.
4. **Coverage difference:** Sol reviewed all of `src/` at declaration and dependency level, plus selected call chains. I reviewed only these three files, and in more depth: declaration inventory, co-change history per declaration region, cross-references between regions, and `Host` field usage by region. This is a cross-model comparison made one after the other, not two simultaneous independent reviews.

## 2. Method (reproducible)

All scripts and outputs are under `.amp/godfile-review/`. Check out the pin first (`git worktree add --detach /tmp/pin c149d1b3`).

| Step | Command | Output |
| --- | --- | --- |
| Sizes | `git show c149d1b3:src/X.zig \| wc -l -c` | table in `INITIAL.md` |
| Declaration inventory | `python3 -I scripts/inv.py /tmp/pin/src/X.zig` | `inventory/*.inv`, `inventory/store_members.txt` (`Store` members via `scripts/members.py src/store.zig 1255 6942 4`) |
| Co-change | `python3 -I scripts/cochange.py /tmp/pin src/X.zig c149d1b3 out.json` | `cochange/*.cochange.json` (one record per commit, regions touched in **that commit's** version of the file, test blocks excluded) |
| Grouping | `python3 -I scripts/groups.py cochange/X.cochange.json /tmp/pin/src/X.zig inventory/X.spec.json` (`store.spec2.json` for the Store) | `cochange/*.groups.txt` |
| Region cross-reference | `python3 -I scripts/xref.py /tmp/pin/src/X.zig inventory/X.spec.json` | `cochange/*.xref.txt` |

**Limits of the method.** Region boundaries are my own responsibility labels (the `spec` files). Co-change is matched on declaration names, so renamed or removed declarations are unmapped; the scripts list them. History begins on 2026-09-13 (158, 204 and 92 commits). Cross-references match names, not types. These are estimates, not compiler facts. I did not compile or run anything; this needed no native or live-provider qualification.

## 3. src/store.zig — keep it intact

**I agree with Sol** (§5, "Store's actual size does not establish a god-module defect").

Evidence (details in `INITIAL.md`):

- **Schema knowledge is the hidden secret.** The DDL region (`bootstrap` 7042–7298, `validateExisting` 7300–7333) changed in 37 commits and **never alone**. It co-changed with execution in 31 commits, admission in 22, the historical view in 22 and reports in 12 (`cochange/store.groups.txt`). Every query family reads the same tables, so splitting by family would spread schema knowledge across more files.
- **One lock and fence owner.** `Ordinary`, `Access`, `enter`, `lockAdmin` and `fence` (1268–1400) are private. Sibling files would need them, plus `prepare`/`bind*`/`readText` (7416–7605), to be `pub`. They would then be reachable from every importer (`server.zig`, `model_adapter.zig`, `provider.zig`, `bash.zig`). That weakens the canonical-fault-fencing contract in the AGENTS.md contract table. It would also break that contract's source-level check, which embeds `store.zig` and counts lock and fence sites in that one file (store.zig:9154–9171).
- **Interface depth.** 42 `pub fn`s (`inventory/store_pub.txt`) hide about 7,555 production declaration lines.
- **The best seam is still not worth cutting.** `SessionReportCapture` (831–1014) is a scratch-backed JSON writer with no SQL. The roughly 1,000 lines that drive it (3174–4150) are SQL projections that run under one `Access` read snapshot. They call `readSession`, `countPendingMessages`, `readToolOutcomeFacts` and `validateActiveTurnToolCalls` from other groups. The report region changed alone in only 4 of its 31 commits.

**About Sol's specific Store arguments:**
- *"1255–1400 centralizes mutex entry, ordinary-error declarations, rollback and fence"*: **Agree, verified.** `finishTransaction` at 1349–1356 rolls back before it classifies errors. `fence` (1396) is the only setter.
- *"Tool import at :5940–6045 must publish content/provenance/call classification/Action consequences atomically"*: **Agree.** It sits inside `settleModelSuccessLocked` (5851–6138). The `model_output_item` insert at 5939–5950 shares one transaction with the content import helpers (6168–6320).
- *"Report capture at :825–880 writes private scratch before delivery; moving it to CLI would expose SQL"*: **Agree, with one addition.** The writer actually starts at 831. The same objection applies to moving it into *any* sibling file, not only the CLI. I found no Store-internal split that hides more than it exposes.
- Sol says the Store is "not proof that every declaration is optimally placed". **Agree.** I add one fact: about 52% of the file is test blocks plus helpers (7,905 + 629 lines). Zig tests outside the file cannot reach the private declarations those tests use (`storage.database`, `exec`, `failAtStepForTesting`), so moving the tests is not free.

## 4. src/server.zig — split justified (S1). I rebut Sol here.

Sol's §5 row: *"'Server is 7,659 lines, so split it into services.' Dismissed / size-only … Host startup/intake/resource retirement and the execution shell must coordinate real handles; the pure execution_turn/execution decisions already have separate owners. No independently justified new service/interface was found."*

That row dismisses a **size-only** accusation with a **services** remedy. I agree with that dismissal. My finding is different: a file split along an ownership boundary that already exists, with no new service, interface layer or runtime structure. The evidence:

| Claim | Evidence at `c149d1b3` |
| --- | --- |
| The execution owner changes independently | Execution region (1098–3010) touched by 93 of 204 commits, **40 of them alone**, the largest solo count in all three files. Intake (173–832): 18 touched, 9 alone. Intake and execution changed together in only **2** commits (`cochange/server.groups.txt`). |
| No handles cross between intake and execution | Intake→execution references: `fenceDispatch`, `nowNs`. Execution→intake: `notify` only (`wakeListener` 2997–2999 → `Intake.notify` 556–559, one `write` to the wake socket). Execution→HTTP: the `SettlementTrace` type only (`cochange/server.xref.txt`). |
| The state each side uses is disjoint | `Host` fields used by the execution region: `custody` (32 uses), `retention` (11), `auth_worker`, `capture_writer`, `provider_endpoint`, `authentication`, `bash_*`. Intake/serve use `intake_capacity`, the `intake` pointer, `allocator`, and `lease` for listening. Both sides share only `store`, `faults`, the launch gate (`launch_mutex` with `effect_shutdown`/`dispatch_fenced`/`execution_shutdown`: 608–613, 773–776, 808–809, 1056–1058, 2987–3006) and the shared scratch budget (`retention.sharedBudget()` 448, `scratch_used` 318). |
| Separate threads and lifetimes | Intake: a poll thread plus two workers (`Worker.run` 190–209, `poll` 711). Execution: its own thread (`executionMain` 1353) plus auth and capture threads (1355–1389). ARCHITECTURE "Exclusive Store ownership" (shutdown paragraph) already describes an intake owner and an execution owner that drain independently, with the Store closing only after both. |

**Response to "must coordinate real handles":** the coordination is real, but it goes **only** through the Host context: the launch gate, the fence and shutdown flags, the shared scratch budget, the Store pointer and the wake descriptor. S1 keeps all of that in one module and moves no handle across the boundary. **Response to "pure decisions already have separate owners":** true (`execution.zig`, `execution_turn.zig`, `BashLifecycle.zig`). But the imperative execution *shell* (slots, custody agreement, preparation, launch, completion, retained cleanup, shutdown drain; about 1,900 production lines) still sits in the same file as the HTTP intake. Every intake or route change must be read past it. Sol's own module-map row for `server.zig` (its REPORT.md line 114) lists "intake, canonical handoff and effect service shell" as one owner. The history above shows those parts change separately.

### S1 concrete plan (move-only, then one small edit)

```diagram
before                              after
┌───────────────────────────┐       ┌──────────────────────────────┐
│ server.zig                │       │ server_host.zig              │
│  Host, Faults, Limits     │       │  Host, Faults, Limits,       │
│  Intake + serve           │       │  TestTransition, launch gate,│
│  execution owner (≈1.9k)  │──────▶│  fenceDispatch, trace helpers│
│  trace/test observation   │       └──────▲───────────────▲───────┘
│  Route/prepareReply/render│              │               │
└───────────────────────────┘       ┌──────┴───────┐ ┌─────┴─────────────┐
                                    │ server.zig   │ │ server_execution  │
                                    │ serve,Intake,│─▶ .zig: slots,      │
                                    │ Route,render,│ │ NativeTurn, Bash/ │
                                    │ Reply        │ │ model, cleanup    │
                                    └──────────────┘ └───────────────────┘
```

- **`src/server_execution.zig`** receives `AttemptOwner`…`ExecutionSlot` (1098–1157), `slotToken`/`checkSlotCustodyAgreement`/`checkSharedPreparation` (1167–1254), `AdmissionProgress`, `LifecycleMeasurement`, `AuthWorker`, `executionMain`, `NativeTurn` (1256–1675), everything from `serviceOneCompletion` (1684) through `hasOwnedSlots` (2911), and `AnsweredAttempt` through `finishCustodyNow` (2915–2985). It also receives the in-file tests that drive slots and custody: about 1,670 of the 3,011 test lines, estimated by matching test bodies against slot and custody names. Its public interface is `executionMain(*Host)` plus whatever `serve` needs for startup.
- **`src/server_host.zig`** receives `Host` with `launchAllowed`/`withEffectLaunch` (118–168), `Faults` (48–109), `Limits` (34–45), `TestTransition`, the constants at 24–31, `fenceDispatch`/`retainDispatchFence`/`wakeListener`/`nowNs` (2987–3010), and the trace/test-observation helpers both owners call (3011–3428).
- **`src/server.zig`** keeps `serve`, `Intake`, `Route`/`Header`/`HeaderReader`, `prepareReply`, the `render*` functions and `Reply` (about 2,100 production lines), plus their tests.
- **The one non-move edit, needed to avoid an import cycle.** `tests/ci/import_architecture.py` rejects new production cycles. `Host.intake: ?*Intake` exists only so `wakeListener` can call `notify`. Replace it with the wake descriptor (`intake_wake: ?std.posix.fd_t`, written exactly as `Intake.notify` does at 556–559). The other reader, line 397 (`self.host.intake.?.exchanges`), runs inside `Intake.Exchange`. Give `Exchange` an `owner: *Intake` field (as `Worker` already has at 184) so it no longer reaches the Intake through `Host`. Do this as a separate commit after the moves, per the planned move-only-first sequence.
- **Invariants and who holds them:** the Store→Host launch-gate lock order is documented and enforced in one place (`server_host.zig`). Slot/custody agreement stays beside the slots. Intake never sees `ExecutionSlot`. No new runtime structure, thread, queue or interface type is added.
- **Approximate net change:** +60 to +120 lines (imports, `pub` on about 15 declarations, file headers, the wake-descriptor change). Code complexity is unchanged; each file's reasoning set gets smaller. The estimate does not cover test helpers that both sides may need, which I cannot confirm without compiling.
- **Strict paths and gates:** all three files match `src/server*`, so `strict_paths.py` is unchanged. **`tests/ci/select_tests.py` must change in the same commit.** It maps the exact path `src/server.zig` at rows 71 and 109 (to `check`, `admission-debug-integration`, `host-launch-integration`, `descriptor-capacity-integration`, `codex-h2-integration`, `transport-h2-integration`). Unmapped `src/` files fall back to `check` only (229–232). Use `src/server*` patterns or list both new files there; otherwise selection silently gets weaker. That is a CI-selection edit and needs to be part of the approved scope.
- **Risk:** medium-low. Failures from moving code are mostly compile-time (private declarations). I found no `@embedFile("server.zig")` pin. One runtime-relevant edit: the wake descriptor. It must keep the existing coalescing behavior (a full nonblocking socket is already readable) and the shutdown wake, and should be covered by the existing intake shutdown tests (6869, 7009).
- **Why this simplifies rather than spreads one concern:** each resulting file holds one owner with its own thread, state and invariants. The shared part becomes an explicit small context module that matches what ARCHITECTURE already describes. Splitting the execution shell further, for example Bash versus model, *would* spread one atomic concern, because both share slots, custody and the shutdown drain. I do not recommend it.

**Not recommended in server.zig:**
- Separating the `render*` functions (about 320 lines). They are pure, but they changed with routing in 7 of their 15 commits, and the in-file tests at 4114–4257 cross-check them against `client.zig` decoders.
- Removing `Faults` from production `Host`. **I agree with Sol** ("Host test knobs … intentional opt-in instrumentation"). The execution region uses it 58 times at production decision points.

## 5. src/client.zig — keep it intact

**I agree with Sol** that the "leaks storage into CLI" accusation is unsupported. CLI and Client import no Store module (`rg '@import\("store.zig"\)'` finds only `model_adapter`, `provider`, `bash` and `server`).

My own evidence: the requests API, decoders and transport changed together (requests+transport 10 commits, mutation-decode+requests 6) and share reply types and `ReplyBuffer`. `sendSource` (3200–3212) takes `Requests` for cancellation and read-failure capture, so transport is not independent. Extracting transport would be function shuffling.

**Optional C1 (my addition; Sol did not consider it).** Durable caller capture records (2583–3161) have their own on-disk format and crash-consistency protocol: a 0700 directory check, an exclusive nonblocking lock, a temporary name, publish, then fsync (`Capture` 2956–3160). Move them to `src/request_capture.zig` (about 600 production lines plus tests). To avoid a cycle, move `Requests.sendCaptured` (43–51) into the new file; `cli.zig` and `SessionSubmission.zig` update their calls. Net about +30 lines. This is not a strict path, but the `select_tests.py` rows for `src/client.zig` (55, 235) must cover the new file. The value is marginal: capture changed alone in 6 of 22 commits, but changed with the typed inputs it captures in 10, and those inputs would then sit in a different file. Do it only alongside the next capture-format change, or not at all.

## 6. Where this report agrees and disagrees with Sol (§5)

| Sol §5 argument | Agree / rebut | Evidence |
| --- | --- | --- |
| Store size is not a defect; transaction/fence centralization | Agree | §3; store.zig:1268–1400, 9154–9171; schema co-change 37 commits, 0 alone |
| Tool import must be atomic | Agree | store.zig:5851–6138 |
| Moving report capture would expose SQL/snapshot policy | Agree, and it applies to any file, not only the CLI | store.zig:831–1014, 3174–4150 |
| Server: "size-only", "must coordinate real handles", "no independently justified new service/interface" | **Rebut** for the file boundary; agree for "services" | §4 table: execution changed alone in 40 of 204 commits; intake+execution together in 2; disjoint `Host` fields; cross-thread coordination only through the launch gate and fence |
| Client: no Store leak; local record I/O is a documented obligation | Agree | No Store import; C1 is optional and separate from that accusation |
| Host test knobs are intentional | Agree | server.zig:48–109 |

## 7. Limits

- History is about 6 weeks (from 2026-09-13). Co-change is a heuristic, and labelling regions is a judgment call. Different boundaries could shift the counts, though not the 40-solo versus 2-joint contrast, which survives any reasonable labelling of 1098–3010 versus 173–832.
- Nothing was compiled or run. The S1 LOC estimate and the absence of other `pub` needs are unverified until someone attempts the move.
- This is a single Opus view compared afterward to a single Sol view, at pins with identical content for these files.
- This report gives no implementation or landing authority. If S1 is approved, the planned sequence applies: move-only commits first, the wake-descriptor and `select_tests.py` edits separately, then strict gates.
