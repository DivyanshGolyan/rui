# Workflow cancellation and Session stop results

> **Dated decision trace, published 6 September 2026.** The [normative architecture](../../ARCHITECTURE.md) and [product contract](../../PRODUCT.md) own the current design. Earlier signatures, issue ownership, status statements, and unselected alternatives below retain their original context; they are not a second current specification.

Status: the simpler cancellation recovery contract below was accepted on 5 September 2026. The original per-Session stop-result investigation is preserved afterward as superseded design evidence. No production implementation or crash test is claimed.

## Accepted simplification

Cancel the workflow, stop its Sessions, and retry unfinished cancellation after a crash. Callers coordinate Session reuse.

- Run Cancellation Intent fences further evaluator generations and creation/configuration/message admissions from that Run.
- Derive distinct used Sessions from committed message admissions with bounded disk queries. Creation/configuration/reads alone do not count.
- Apply the ordinary Session stop to each Session's current work. An idle stop completes immediately; otherwise completion follows the selected work's durable terminal outcome and atomic logical occupancy release, with existing tool settlement obligations preserved. Request all required stops promptly through bounded traversal before waiting on completion. Another Run's work can be stopped without cancelling that other Run. Model physical cleanup remains independently owned and charged until safe release; no remote provider acknowledgement is required.
- Before Run cancellation completion is durably recorded, a crash may cause the entire pass to repeat. Previously successful or idle stops may then stop newer work. Overlapping use and early continuation are the caller's responsibility.
- Every required stop in a complete pass must complete under the ordinary Session-stop contract before recording cancellation completion through the existing terminal Run outcome. The completion rule is the same whoever submitted the stopped work; do not add a separate predicate waiting only for the cancelling Run's submitted work. After that commit, recovery does not propagate the cancellation again. A crash after the final stop but before completion commit can repeat the pass.
- Reuse ordinary Session stop and effect-specific settlement/recovery. Add no per-Session propagation receipts, idle-check records, durable traversal cursor, or separate cancellation queue. A temporary query position is disposable.

This expressly drops the earlier promise that each applied Session stop could never affect later work on recovery. The missing distinction in the two histories below no longer needs to be preserved. A Run's completed cancellation still does not repeat, and a Session remains reusable. No direct-client automatic mutation retry is added.

### Required verification

| Boundary | Expected behavior |
| --- | --- |
| Crash before any stop or between stops | Recovery may restart the full pass; all required Session stops must succeed before Run cancellation completes. |
| Idle or successful stop, crash, newer work | While cancellation is unfinished, a repeated pass may stop the newer work. |
| Crash after final stop but before Run completion commit | Recovery may repeat the pass. No per-Session completion facts are required. |
| Run completion committed, acknowledgement lost or server restarted | Return/recover the terminal Run outcome; do not propagate more stops, even after Session continuation. |
| Stop or completion commit fails | Do not report durable cancellation completion; preserve ordinary stopped-work facts and effect-specific recovery. |
| Run message races intent | An earlier committed message contributes its Session; later Run admission is rejected. |
| Large used-Session set | Traverse in bounded disk batches without retaining a Session population or imposing a durable count quota. |

The exact ordinary stop/Run settlement SQL remains implementation work. These are required checks, not passing tests.

## Historical investigation — superseded

The following investigation assumed a stronger no-retarget guarantee that the user subsequently rejected for simplicity. Its per-Session receipt proposal and next-decision prompt are not current requirements.

## Earlier behavior assumed by the investigation

[Issue 101](https://github.com/DivyanshGolyan/onepage/issues/101#issuecomment-5550876667) requires Run cancellation to fence further evaluation/submissions by that Run, then stop current work in every distinct Session reached through its committed message admissions. Creation/configuration alone does not count. Other Runs can share those Sessions and observe the same stopped work without becoming cancelled themselves. Recovery must finish missing stops and never retarget a previously applied stop to later continuation.

The [current design](session-workflow-interface.md#cancellation-mapping-and-verification-obligations) explicitly leaves stop-result storage unresolved. The older [architecture](../../ARCHITECTURE.md) still describes a direct Run-membership fence on Turns; that cannot express another Run's newer work or a one-time idle stop. It must be replaced if this mapping is selected, not layered underneath the new behavior.

## Why current records are insufficient

Consider two histories. Run A previously sent a message to Session X; its old work is complete.

| Step | History 1 | History 2 |
| --- | --- | --- |
| 1 | A's cancellation intent commits | A's cancellation intent commits |
| 2 | Cancellation checks X, which is idle; stop is a no-op | Cancellation has not checked X yet |
| 3 | Server crashes | Server crashes |
| 4 | After restart another client starts X's next Turn | After restart another client starts X's next Turn |
| 5 | Cancellation recovery reaches X | Cancellation recovery reaches X |

Without a durable stop result, all documented canonical facts in the two histories are identical: the same Run intent, message admissions, Session, completed old Turn, and new active Turn. No cancelled outcome or interrupted Operation was created by the idle stop. Yet the accepted result differs: History 1 must preserve new work; History 2 must stop current work when its still-unapplied stop reaches X.

Consequently, an algorithm using only these facts cannot implement both required outcomes. A Turn outcome cannot identify a no-op, and cancellation by another source cannot prove A applied its stop. This is missing semantic information, not a reason to add a resident worker or queue.

## Recommended representation: record the ordinary stop result

Record one immutable result when a Session stop applies. Its essential facts are the Session and the exact selected internal Turn, or an explicit idle result. For workflow propagation it is uniquely associated with `(Run Cancellation Intent, Session)`. This association is internal; it is not a user-supplied CLI idempotency key or a generated string mixed into workflow source keys.

The stop transaction first looks for that same result. If present, it returns the original result without selecting current work. Otherwise it selects current Session work and commits the result atomically. A selected Turn is fenced by that stop fact; an idle result fences no Turn. The existing runtime performs effect-specific cleanup for the selected work. The result records semantic stop application, not physical cleanup completion, provider acknowledgement, or billing termination.

This fact is itself the authority that fixes what was stopped. Do not add a separate processed flag, queue entry, copied Turn cancellation intent, per-Operation stop request, or progress cursor. The exact table name and physical integration with control-result storage remain implementation choices; the semantic identity and idle/target distinction are what the trace requires.

Direct keyless Session stops use the same target-selection operation. A repeated direct CLI request remains a new command and can select newer work; internal workflow recovery reuses its stable cancellation/Session association. No automatic retry promise is added to direct clients.

## Recovery from canonical facts

1. The unique Run Cancellation Intent prevents further evaluation and creation/configuration/message operations by the cancelled Run. Message admission and that fence serialize: a committed earlier message contributes its Session; a later admission fails.
2. Derive distinct used Sessions from committed message admissions. The set is stable after the fence.
3. In bounded queries, select used Sessions with no stop result for this cancellation. Apply the ordinary Session stop transaction to each selected Session. A stale query result is harmless because the transaction first checks the unique association.
4. Derive unfinished physical cleanup from the selected Turns' existing Operation/Attempt facts. Never select current Session work again to perform that cleanup.
5. Propagation is complete when no used Session lacks a stop result. Run terminal cancellation additionally follows the selected cleanup/outcome contract; do not equate an acknowledged stop with completed cleanup or successful settlement of all previously submitted work.

This needs no in-memory Session set. A database index can accelerate the missing-result query; it is not a second source of progress authority. Storage grows by at most one result per distinct Session used by that cancellation. Active-target results refer to existing work; idle results have no fake Turn or Operation.

## Boundary traces for the recommendation

| Boundary | Expected recovery |
| --- | --- |
| Crash after Run intent but before any stop | Every used Session lacks a result and remains eligible for a stop. |
| Stop X commits; crash before Y | X's recorded result prevents retargeting; only Y remains missing. |
| X is idle when stopped; new work starts later | X's explicit idle result protects later work from replay of this cancellation. |
| Stop transaction rolls back | No result or fence exists; a later application selects current work. |
| Acknowledgement is lost after stop commit | The unique cancellation/Session association recovers the original target or idle result. |
| Another Run starts newer work before this Session's stop applies | The stop selects that current work, as required by the accepted sharing contract. |
| Two cancellations stop the same active Turn | Each cause records its own application; both refer to the same work. Outcomes/Resolutions retain their existing uniqueness, without duplicate effects. |
| Another cancellation stopped old work, and new work begins before A reaches X | A's missing result still means A has not applied; another cause does not stand in for it. |
| Stop races model settlement or Attempt admission | Transaction order selects the winner for the exact target. Existing launch suppression and effect-specific cleanup rules then apply. |
| Session is already draining a stop | Select that same nonterminal work; do not attach to a future Turn. Further messages follow existing applicability/occupancy rules. |
| Run used X only through creation/configuration | X is absent from the derived used-Session set. |

These are required scenarios for a later production verification pass, not passing test results.

## Alternative: select all targets atomically

One transaction could select every affected Session's current work at the cancellation boundary, persist the selected targets, and mark the whole selection complete. Idle Sessions could then be inferred from complete selection rather than receiving separate idle results. Physical cleanup would still happen incrementally.

This changes the target-selection time: later work started before an individual cleanup is reached would survive because targets were frozen together. It also performs work proportional to the whole used-Session set in one write transaction. SQLite can stream rows without a large resident collection, but that does not establish an acceptable command delay. It therefore requires an explicit timing choice and bounded-delay evidence, rather than being a free storage simplification.

The ordinary stop-result recommendation preserves the already-selected per-Session composition and short transaction shape. Do not declare that no additional durable fact is needed merely to avoid acknowledging the idle counterexample.

## Next decision

Confirm the Session stop result as the canonical fact: the specific work selected, or idle. Then update the owning cancellation contracts, remove the obsolete Run-membership-wide Turn fence, and execute the boundary fixtures against the production implementation when that work exists.
