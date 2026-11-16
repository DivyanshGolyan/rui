---
name: verify-mysql-ownership
description: Model-check who may write a MySQL Store and what a Host concludes after losing its connection around a COMMIT (fence, reconnect, lock reclaim, rerun). Use when a change touches mysql_open.zig open/reclaim, Mysql.zig's fence, lost/settleLostCommit/recover/reconnect, Store.zig's recoverRerun/fence, or the store_owner epoch and commit_seq rules in docs/contracts/host.md.
---

# Verify MySQL Store ownership

A TLA+ model in `tests/formal/mysql_ownership/` checks every interleaving, within small bounds, of two Hosts opening one MySQL database, a write batch's message running on the server after its client lost the connection, the server ending sessions, and the Host's reconnect deciding whether the batch landed. Tests cannot reach these orders; the model can.

## The rules

Each is an invariant in `MysqlOwnership.tla`. The harm is what a user would see if it broke.

| Invariant | Rule | Harm if broken |
| --- | --- | --- |
| `SavedOnce` | A batch is saved at most once, however often it runs. | Duplicated Turns, messages or Actions. |
| `SavedMeansSaved` | A Host that reports a batch saved is right. | Lost work reported as done. |
| `NotSavedMeansNotSaved` | A Host that reports nothing saved stays right. | A caller retries and duplicates work. |
| `RerunOnlyUnsaved` | A batch runs again only while nothing of it is saved. | Spurious fence, or a duplicate if the fence were weaker. |
| `OnlyLatestOwnerWrites` | Once another Host opens the Store, nothing the earlier one sent commits. | Two Hosts writing one Store. |

## Run it

```sh
python3 tests/formal/check.py --trace
```

It needs Java 11 or later and downloads TLC 1.7.4 once (SHA-256 pinned, cached in `~/.cache/rui`; set `TLA2TOOLS` to a local jar offline). It takes about ten seconds. CI runs the same check in the policy job (`tests/ci/test_formal_models.py`) whenever `tests/formal/` changes.

It checks two configs. `ExactLock.cfg` assumes `GET_LOCK` excludes every other live session, as on one MySQL server; all five rules must hold. `AdvisoryLock.cfg` lets the lock stop excluding a live session (a proxy or cluster route that reaches a server without it), because the contract says `GET_LOCK` "only refuses early" and the epoch fence owns the Store; there `SavedOnce`, `SavedMeansSaved` and `OnlyLatestOwnerWrites` must still hold, and `RerunOnlyUnsaved` is a known finding (below). Three mutation switches (`BreakFenceEpoch`, `BreakLockWait`, `BreakSettleEpoch`) each remove one guard the code has and must make a named rule fail, so the rules are known to be able to fail.

Read every result, passing or failing, with the pstack `/statechart` skill: give it the spec, one of the configs and `tests/formal/mysql_ownership/view.mjs` as the view. It prints each broken rule's shortest path in plain words and, when the model is small enough, draws the chart.

## Does my change touch it?

The model describes these, at the sync commit below:

| Model action | Code |
| --- | --- |
| `HostOpens`, `HostRefused` | `src/store/engine/mysql_open.zig` `open`: `GET_LOCK(db,0)`, then one transaction raising `store_owner.epoch` and reading `commit_seq` |
| `HostSendsBatch`, `ServerRuns` | `src/store/engine/Mysql.zig` `appendControls` (fence `UPDATE ... WHERE epoch=? AND commit_seq=?` plus guard) and `appendCommit` |
| `HostCommitted`, `HostFenceFailed` | `Mysql.zig` `committed`, the `fence and changed != 1` check in `sendPass` |
| `HostLosesConnection` | `Mysql.zig` `lost` (`committing` picks CommitOutcomeUnknown, `armed` picks rerunnable), `Store.zig` `armRerun`, `recoverRerun`, `fence` |
| `HostReclaimReads`, `HostReclaimsLock`, `HostLockTimesOut`, `HostLosesReclaim` | `Mysql.zig` `reconnect`, `settleLostCommit`, `recover`; `mysql_open.zig` `reclaim` (IS_USED_LOCK and epoch, KILL, `GET_LOCK(db,10)`, epoch and commit_seq) |
| `ServerEndsSession`, `ServerForgetsLock` | The MySQL server: a session outlives its client until KILL or a timeout; user locks free when the session ends |
| `HostCloses` | `Mysql.zig` close via `mysql_open.releaseLock` |

Sync commit: `bc45dd3` (main, 2026-11-16).

Run `git diff bc45dd3 -- src/store/engine/Mysql.zig src/store/engine/mysql_open.zig src/store/Store.zig` and look for changes to the functions above. A change that leaves what each action does and what it treats as one step unchanged needs no model edit. Otherwise change the model first, run the check, then the code.

Modelling choices to keep in mind: one batch is one message (fence, writes, COMMIT), so a loss before COMMIT has no server effect; a message the server holds runs whole or stops at the fence's guard; reconnect retries are folded into `MaxLosses`; reads after COMMIT, ids and the dispatch survey are left out. Bounds: two Hosts, three batches, at most two connection losses and six server sessions.

## A violation: bug or modelling error?

Turn the path into the code's steps, one action per step, and replay it against the real code: a `src/store/mysql_testing.zig` test with `testing_drop` and a second connection on the MySQL fixture, or by reading the functions in the table. If the code cannot take a step the model took, the model is wrong: fix the model. If it can, it is a bug: report the path and the harm; do not weaken a rule or a bound to make it pass, and do not change product code unless asked.

## Changing the model on purpose

Keep each action pointing at code a reviewer can open, and one indivisible step per action. A new guard gets a `Break...` switch and a row in `MUTATIONS` in `tests/formal/check.py`. When a known finding is fixed, the check fails asking you to move that rule into the config's holding list. Move the sync commit forward only after confirming the table above describes the code at the new commit.

## Known finding

Under `AdvisoryLock.cfg`, `RerunOnlyUnsaved` breaks: a Host loses its connection while COMMIT is in flight; on reconnect `IS_USED_LOCK` shows no holder, so it skips KILL, takes `GET_LOCK` at once and reads `commit_seq` unchanged; it reruns the batch; then the old session's message commits. The rerun's fence then matches no row, so the Host fences and exits instead of duplicating, and the batch is in fact saved. `reclaim` reads `commit_seq` as final once it holds the lock, so its "nothing landed" leans on the lock, which the contract calls advisory. No data is lost or duplicated; the cost is a fenced Host and an unknown outcome. It matters only where `GET_LOCK` is not one server's lock (for example Group Replication multi-primary).
