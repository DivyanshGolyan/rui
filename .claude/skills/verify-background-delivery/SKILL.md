---
name: verify-background-delivery
description: Model-check how a background Action's final Resolution becomes Session input (exactly once, stop wins including an attached parent's owed stop, promotion keeps its credit, waits bounded by deadlines). Use when a change touches action_control.choose, sourced_input Final.admit, SettleAttempt/RecoverUncertain/DecidePermission admission, actionStoppedSql or eligibleSql, session_stop or session_stop_owed, or model_admission input selection.
---

# Verify background final delivery

A TLA+ model in `tests/formal/background_delivery/` checks every order of: a Turn dispatching a call, promotion to background, the call settling or timing out, Host death and indeterminate recovery, a user stop, an attached parent's stop arriving first as an owed stop and settling later, input boundaries and Turn starts, and a second foreground call waiting for a credit.

## The rules

| Rule | Plain words | Harm if broken |
| --- | --- | --- |
| `DeliveredAtMostOnce` | A background result reaches the Session at most once. | The model acts on one result twice. |
| `ResolvedOnce` | An Action resolves once, even across Host death. | Two contradictory results. |
| `StopWins` | No Turn takes a result that finished after the Session or its attached parent was asked to stop. | Model work after the person pressed stop. |
| `CreditsHeld` | Backgrounding keeps the call's own credit; never more credits held than exist. | Overcommitted Host. |
| `WaiterEventuallyRuns` | A foreground call waiting while background calls hold every credit eventually runs. | A stuck Session. Holds only because deadlines end every call. |

Delivery when due needs no rule of its own: in the code and the model, a background Resolution not stopped admits its input in the same transaction.

## Run it

`python3 tests/formal/check.py --trace` (Java 11+, TLC pinned and cached; see the `verify-mysql-ownership` skill for the runner). `Pr1550.cfg` and `OwedStopChecked.cfg` both require `StopWins`. `AdmitChecksOwed=TRUE` matches the shared `action.stoppedSql` predicate, used by final admission facts and model input selection/binding. Read results with the pstack `/statechart` skill.

## Model steps and code

Sync: #1550 with the shared saved/owed-stop predicate and its `background owed stop` regression tests.

| Model action | Code |
| --- | --- |
| `Dispatch`, `WaiterRuns` | `store/domain/action.zig` `next_action_attempt` / `next_mcp_action` with `capacity.hasCredit()` |
| `Promote` | `action_control.zig` `choose` (no capacity input) and `store/domain/action_control.zig` |
| `Settle`, `Recover` | `action.zig` `SettleAttempt` (`settle_facts`), `RecoverUncertain` (`uncertain_facts`), then `sourced_input.Final.admit`; `command.zig` permission `deny` takes the same path |
| `UserStops`, `OwedStopSettles` | `command.zig` `StopSession`: `insert_stop` with `admission_cutoff` and `action_cutoff`; owed settlement |
| `ParentStops` | `turn.zig` inserts `session_stop_owed` (settled=0) for attached children |
| `StartTurn`, `InputBoundary` | `model_admission.zig` `queuedInputSql`, `bind_messages` |

Every Store write is one serialized transaction, so each model action is one transaction. Left out: several Sessions, MCP/Bash differences, core tools (never Actions), the auto-background threshold (it calls the same promotion owner), and content.

## A violation

Replay it as a `src/store/tests/action.zig` test, one transaction per step. If the code cannot take a step, fix the model; otherwise report it with the path. Never weaken a rule to pass.
