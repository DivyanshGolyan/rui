# Synthesis: Drift on Rui (arena result, awaiting Divyansh's answers)

Two candidates: candidate-1 (Opus, medium effort) and candidate-2 (Fable). Phase A grounding is in grounding/how.md.

**Cross-judge skipped.** The judge must come from a non-Claude family. The only one configured is rui-terra-high (OpenAI), and the OpenAI budget is out until about 24 Nov (project CURRENT MODE). I picked the base alone, scoring against the rubric below.

## Rubric

1. **One owner per fact.** No second projection of saved facts. The runner is derived once.
2. **Zero resident cost per waiting agent and per waiting tool call.** Fixed, stated cost per open line.
3. **Never-repeat holds.** Reruns happen only for declared tools, and they are counted.
4. **Interface depth.** The app learns little, and the Host hides claiming, resume, deadlines and failure.
5. **Drift fit.** Drift's pi-durable use maps one to one, its several processes work, and its data moves by code.
6. **Small landable units.**

## Where the candidates agree (shipped as consensus)

- **U0 first:** one runner derivation, generated for Zig and SQL, so a new runner can't silently fall through to Bash.
- **Calls wait as rows.** A client tool call is an ordinary Action with a new runner. While waiting it is a row, with no custody, no Active Capacity credit and 0 Host bytes. Settlement goes through the unchanged `tool_settle` / `SettleAttempt`.
- **Claim and answer are ordinary keyed requests.** The first claim wins and is saved. The answer carries (action, attempt, claimant). A repeat or late answer is ignored.
- **A closed claimant line, or a Host restart, counts as a crashed runner.**
  - An unsafe call settles as `indeterminate`.
  - A safe call is offered again while its claim count is under its limit, then fails with `restart_limit`. This needs the `attempt_ordinal` CHECK relaxed.
  - A claimed call that times out is final even for a safe tool, because the app may still be running it.
- **Declaring tools is a Session setting.** `tool_offer` stays the single projection owner. A child gets its parent's set, narrowed by `start_agent`'s names.
- **Deadlines are one indexed query** (`due`), so a Host with no client calls sends no query.
- **Progress, cancel and the failure notice ride the line as payload** and are never saved.
- **Reset happens at the next Turn boundary**, without touching `history_floor`. The view starts at the reset point.
- **One TS error, `RuiStoreFailedError`, is latched for the whole client.** The client keeps reading stdout after readiness. The pi-durable layer maps the error to `SessionFailed`.
- **Hooks are feed rows.** `model_call`, `compacted` (now also on failure) and `tool_result` with its resolution code.
- **`ruicode/pi-durable` has two layers.** A version-neutral translator, plus one thin layer per version. Unsupported names are absent.
- **The importer is hub and spokes.** A versioned Transcript, a TS spoke reading pi-durable `Storage`, and three resumable Host doors (begin, append, seal) into a fresh Session only.

## Base: candidate-1

Why it wins on the rubric:
- **(1) One owner.** The feed stays the only reader of saved facts. The line carries nudges, so it never re-projects them.
- **(2) Zero cost.** The Host does no Store reads for pushing and keeps no slots.
- **(5) Drift fit.** It caught two Drift-fit facts that candidate-2 missed:
  - **Several processes need one shared Host.** `Rui.connect` starts a Host per process, and a second Host on the same MySQL Store is refused with `store_locked`. Candidate-1 adds `Rui.attach` for this.
  - **My push premise was wrong.** pi-durable's `watch()` does not replay on reconnect: its README says "nothing is replayed". It sends the current view, and only transcript entries resume, by entry id. Rui's feed cursor already does that.

## Grafts from candidate-2

- **A call can't exist without its result** in the Transcript hub type: `assistant.calls[].result` is required.
- **pi-durable 1.6 types are checked by `satisfies` against the published `.d.ts`.** Coverage is a checked-in expectation file that may only shrink.
- **Hook handlers return `void`** in the version layer, so a handler that tries to change the loop doesn't compile.
- **Unit 4's check:** confirm that `turn_ended` names the admissions it answered, so `Submission.wait()` is a filter, not logic.
- **Open line count is fixed and stated:** about 24 to 27 KiB per line, with a fixed pool (candidate-1 has 64, candidate-2 has 16).

## Forks for Divyansh (one question at a time)

1. **DECIDED 2026-11-23 16:17 IST: nudges.** Push line: nudges or numbered events? The base says nudges for saved facts, with payload only for what is never saved. Candidate-2 says numbered events, because the line already carries some payload and it would spare each consumer the read loop. My earlier recommendation of numbered events rested on the wrong `watch()` premise. I now recommend nudges.
2. **DECIDED 16:25 IST: real Turns (base), one import record plus a Turn link, no per-record flags.** Imported history: real Turns or a new entry kind?
   - **Real Turns** (base): imported history becomes real Turns, Operations and Actions marked imported. Every reader works unchanged, and each item must round-trip through the pinned codec at import time.
   - **New entry kind** (candidate-2): a fifth entry kind with no Turns, so nothing forged. This means no usage and no `read_action` targets, and the feed and codec need a branch for it.
   - The risk on real Turns: one malformed foreign record could fence the Store. The base's guard against that is checking every item at import time.
3. **DECIDED 16:26 IST: one process, two during rollover; U2 dropped, rollover is a lock handoff.** Drift topology: do Drift's processes run on one machine, sharing one Host over a Unix socket? If they span machines, the line and the claim routes need TCP.
4. **DECIDED 16:30 IST: Drift drops reset; Rui builds no reset (U5 removed).** Reset during a run: the base waits for the running Turn to end. pi-durable ends the run at the next tool round. Does Drift need the latter?
5. **DECIDED 17:04 IST: one limit from ready, generous default, error names the stage.** Wait limit: one clock from "ready", or separate clocks for "no app claimed it" and "app has not answered"?
6. **DECIDED (no new exposure; any socket client already reads every Session): a line watches named Sessions or all, no workspace scoping.** Line scope: may two apps on one Host see each other's events, or should scope be per workspace?

## Build order (base, with grafts)

| # | Unit | Store | Wire |
| --- | --- | --- | --- |
| U0 | One runner derivation (Zig plus generated SQL) | none | none |
| U1 | `RuiStoreFailedError`; keep reading stdout after readiness | none | none |
| U2 | `Rui.attach(hostDir)` for a shared, detached Host | none | none |
| U3 | The line: upgrade route, nudges, second commit-wake listener, ring facet | none | +1 |
| U4 | `session.watch()` on the line; delete feed polling and the local write watch | none | none |
| U5 | Reset (context head) | +1 | +1 |
| U6 | Client tool declaration and the `app_call` row, deadlines | +1 | +1 |
| U7 | Claim, result, cancel, background, progress | none | +1 |
| U8 | Safe rerun with restart limit | +1 (CHECK) | none |
| U9 | Hook facts on feed rows | none | +1 |
| U10 | Import doors, Transcript v1 (shape depends on fork 2) | +1 | +1 |
| U11 | TS hub types and the pi-durable `Storage` reader, lazy and eager | none | none |
| U12 | `ruicode/pi-durable` core plus v1.6 layer, coverage run (needs #1655) | none | none |

U0 to U3 are independent. U6 needs U0. U7 needs U3 and U6. U10 needs U5. U12 needs U4, U7 and U11. #1650 slots in after U5.

## Verification

This is still a design; nothing has been built. A later check is still owed: the background-delivery formal model must gain the state where the app holds the call, before U7 lands.
