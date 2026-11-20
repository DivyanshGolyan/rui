# Session stops and outcomes

[Architecture](../../ARCHITECTURE.md) owns shared guarantees, terminology, and the source map.
[Verification](../../VERIFICATION.md) owns global evidence rules and gates.

## Accepted contract

### Session provenance

A Session's nullable `creator` identifies the Session supplied by validated creation `parent` input.
Without parent input, the authenticated Session sender of the Session's first admitted Message is its creator, whether that Message created the Session (`rui session start` from an agent's Bash) or followed an empty creation (Divyansh, 2026-11-20); a first Message from a person leaves it null, and later Messages never set it.
The Store saves it once as `session.creator_ref`, at creation from parent input or with that first Message's admission, for both attached and detached Sessions; a sender creator brings no lifecycle parent.
A non-null creator is another existing Session's canonical six-character reference.
Subsequent configuration and command replay preserve the original creator.

Creator records provenance; `session.parent_ref` records lifecycle attachment.
An attached child has both facts, while a detached child retains its creator without a lifecycle parent.
Only lifecycle attachment controls parent-caused stops, child-ending Messages, and ancestor Activity forwarding.
A creator alone grants none of those effects.
[Agent identity and peer composition](model-io.md#agent-identity-and-peer-composition) owns those lifecycle rules.

[Store format and upgrades](store.md#store-format-and-upgrades) owns migration of historical provenance.
Existing parent links provide a known creator, and format 88 applies the first-Message sender rule to Sessions saved before it.
Labels, shared Workspaces and peer Messages after the first never establish a creator.
[Session listing](cli.md#session-listing) and [public Session activity](inspection.md#public-session-activity) expose this saved fact.

### Stops and terminal outcomes

#### Stopping selected work

A **Session stop** selects current work once.
Its saved selection prevents that work from advancing; it does not close the reusable Session.
The transaction binds the core idempotency key, Session reference, active Turn (if any), queued admission cutoff, Action cutoff and admission answer with stop authority.
The saved fact excludes unselected input through that cutoff, including between failure and successor admission.
Input after the cutoff is not selected by this stop.
Earlier committed results remain unchanged.

Acknowledgment confirms that Rui saved the stop intent and selection, not that the selected work has finished.
Completion requires the selected Turn's terminal outcome and atomic occupancy release, when a Turn was selected, and every selected Action's terminal outcome through the saved Action cutoff.
With no selected Turn or Action, the queued-input exclusion commit completes the stop.
An accepted background receipt remains the original Tool Result; stop waits for the sole Action Resolution without replacing that receipt.

Stop completion follows no future work and proves neither remote provider termination nor the end of billing.
Model transport may still retain custody for local cleanup.
Stop completion and safe resource release are different facts.

Matching retries recover the original selection/answer, including idle stops; observation follows that selection.
A fresh stop needs a fresh key.
Callers retain key and exact inputs before sending, without managing Turn identity or coordinating Session reuse for retries.
Concurrent Session use remains outside the expected usage.
`rui session stop --all` reads the Session listing and sends one ordinary Session stop, with its own generated key, for each Session the overview's Ctrl-X could stop; it adds no cross-Session stop authority, and a Session that starts work after its listing page is read is not stopped.

#### Pinning a Session

Pinning is shared organization for one Store, independent of configuration, work, and model Messages.
`POST /v1/control/session-pin` accepts `session`, `key`, and an explicit desired `pinned` boolean.
The existing serialized Store transition owns admission, replay classification, and fault fencing.
Repeating pin with a fresh key is an accepted no-op that preserves the first pin order; repeating unpin is harmless.
Unpin followed by pin gives the Session the newest pin order.
An unknown Session rejects either desired value.
Pinning an archiving or archived Session rejects; unpinning an existing archived Session is accepted.
Replay classifies the saved key and semantic digest before inspecting current state.
It returns the historical answer without applying an old pin after unpin or archive; reusing a key for another target or desired value conflicts.

`/pin` and `/unpin` in chat use the overview's existing request ledger, worker effects, captured requests, and recovery outcomes.
They appear in shared slash completion and admit no Message or Configure.
The shell exposes `rui session pin --session ID` and `rui session unpin --session ID` through the same captured-command protocol.
Right-click or Option/Alt-left-click on an actual Session row toggles the desired value captured in the drawn frame.
The generic List hit test and GroupedList frame retain its Session identity and desired value; the overview does not re-hit-test coordinates or reread selection.
The gesture neither opens the row nor changes the active conversation, focus, selection, or draft.
Release does not repeat it, and alternate gestures on New Session, Settings, or other non-Session controls never fall through to normal activation.
A normal left-click still opens the Session.
There is no pin marker or menu.

Pinned rows appear once, below the fixed New Session control, newest pin first.
Activity changes never reorder pins.
`overview_view.visible` and `arrange` produce the one visible and navigation order in `State.order`; unpinned rows retain their existing comparator exactly.
Pinned empty Sessions remain visible after leaving the conversation, subject to the ordinary archive filter.
Admission of archive intent clears the pin in that same transaction, including while its stop is pending.
Restore and Message-unarchive never resurrect it, and ordinary stop never clears it.
Parents and children have independent organization.
No optimistic durable pin state, second list, or second comparator exists in the client.

#### Archiving a Session

Archive organization is independent of the derived work state.
`archive_state` is `active`, `archiving`, or `archived`.
`active` means unarchived, not necessarily running.
The archive intent points to an ordinary durable Session stop.
An incomplete stop derives `archiving`; a completed stop derives `archived`.
There is no separate archive worker or recovery queue.

`POST /v1/control/session-archive` accepts `session`, `key`, and the `archived` boolean.
An archive request atomically saves its intent, clears its current pin, and selects the current work for stop.
Acknowledgment reports `pending` until that stop completes, then `completed`.
The Session stays in the unarchived view while its stop is pending.
Stop completion has the existing semantic guarantee, not proof of remote termination or complete local transport disposal.
Host restart retains the intent and the selected stop.

A new Message during `archiving` rejects as `session_archiving`.
A new Message to an `archived` Session clears the archive intent in the same admission transaction.
An explicit restore sends `archived:false`, changes organization only, and never starts work.
Restore during `archiving` rejects as `archive_pending`.
An original command replay reports its original answer and completion without restoring an old archive intent.
Archive preserves settings, Conversation, results, files, and child organization.
The underlying stop retains its ordinary child-stop semantics.
Archive freezes suppression of undelivered child endings, and child closures retain suppression while the parent is archived.
A stop records whether it discharged a parent-caused obligation, even when an ordinary caller chose its key.
These durable facts keep old child results from waking a restored parent, without dropping their forwarded history.
Genuinely fresh work after restore can still notify the parent.

The CLI exposes `rui session archive --session ID` and `rui session unarchive --session ID`.
Both use the ordinary captured-command recovery protocol.

#### Interrupting one model operation

An exact **Model Interruption** targets one unresolved model Operation, validates owner, parentage and applicability, and commits an `Interrupted` Resolution with exact target/provenance.
It does not stop the Session or decide its next Operation.
Continue only for independently admitted applicable messages; otherwise derive cancelled Turn outcome.
Actions have no independent interruption command.
Session stop instead interrupts unresolved model work with causal stop provenance.
Neither path accepts partial/late continuation or retries interrupted work.

Persist an accepted Session stop as its command key, Session, optional selected Turn and admission cutoff; derive excluded messages from those facts.
Persist every exact-interruption target, including rejected targets, as Session, Turn and Operation under its core command.
An interrupted model Operation carries the causing command key if and only if its Resolution is `Interrupted`.
Do not add a selected Operation or completion flag to a stop, a stop identifier, a second Turn-outcome identity, per-message stop flags or a uniqueness constraint that would prevent independent stops from selecting the same Turn.

Stop resolves unattempted Actions without execution.
Active Bash receives best-effort process-group interruption.
Edit can stop without changes before mutation; afterward retain custody for safe execution, observation and cleanup, without rollback promises.
Lost custody yields indeterminate result.
Every accepted Tool Call still has one terminal outcome from which core derives its call-ordered result.
Pending messages/permissions selected by stop/cancellation become inapplicable through those facts, not per-item lifecycle flags.

#### Failing and continuing a Turn

A definitive inability to continue fails a Turn only after no unresolved Operation/effect, actionable permission or missing terminal outcome can change its meaning.
Unselected queued messages do not prevent failure and do not inherit its outcome.
Atomically save the unique typed outcome for the Turn's selected messages and release Session occupancy.
No earlier failure-intent stage is needed.
Every selected message has already been projected with a model Operation; an Operation-caused failure references that resolved Operation rather than copying evidence.
Tool errors, retryable failures, recoverable overflow and direct interruption do not automatically fail the Turn.

After occupancy release, the [queue invariant](conversation.md#conversation-entries-and-pending-messages) drives a successor from any eligible pending input in admission order.
No additional submission or public resume call is required.
The failed Turn and its selected messages keep their recorded outcomes; untouched queued messages receive the outcome of the Turn that later takes them for processing.
With no eligible pending input, failure starts no more work.
New input after failure enters the same queue.
Continuation retains saved conversation without reprojecting earlier messages or automatically replaying failed or uncertain effects.

Required missing/corrupt/incompatible continuation must still be repaired before work can proceed; new input cannot bypass validation.

#### Reading message applicability

Inspection derives message `applied` from projection; `not applied` from absent projection plus applicable stop/cancellation authority; otherwise `pending` while unselected.
Application means entry into model context, not provider consumption.
Keep unapplied content and reason inspectable.
Established processing bindings and exclusions are final; untouched admissions remain pending under their original identities across another Turn's failure.
A command fixed to the old Turn rejects.
Crash alone is neither failure nor cancellation.

#### Example: pending input after failure or stop

Suppose message A is being processed and B is admitted while its model request runs:

| What happens next? | What happens to B and its caller? |
| --- | --- |
| A's Turn fails before B is selected. | B remains queued and drives the next resumable Turn automatically. Its caller waits for that processing Turn's result. No C is needed. |
| B arrives after A's Turn fails. | B becomes runnable under the same queue rule. No extra wake is needed; B receives its processing Turn's result. |
| The next input boundary selects and projects B into a model Operation before the Turn fails. | B receives that Turn's failure and is not automatically queued again. |
| A stop or cancellation excludes B before selection. | B's caller receives cancellation; B remains readable as not applied and does not revive. |

If C arrives while B still waits, preserve admission order; if B already started a successor, C waits for its next input boundary.
Retrying B's original idempotency key never adds another B.
A crash reopens committed queue/selection facts without inventing a terminal outcome.


## Required evidence


### Provenance reads

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| [Creator provenance](#session-provenance) on listing and Activity | `protocol_reply.zig`: `Session list facts own complete rows and render semantic output after scratch reuse` and `Session list facts reject malformed metadata and consequential ambiguity`; `activity_golden_tests.zig`: `activity golden every kind`; `clients/ts/test/unit.test.ts`: `session summaries preserve independent creator and parent references and nulls`. | These check public creator values and decoding, not creation, lifecycle effects, migration, or native restart. Creator persistence and backfill need separate Store evidence. `creator_tests.zig` `session creator names the Session that sent a creatorless Session's first Message` covers sender start, configure then peer send, person first, and a parent other than the sender, with replay; `sqlite_tests/migration.zig` `schema 88 creator migration names the Session that sent each Session's first Message` covers the format 88 backfill. |

### Durable controls

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| [Control replay and conflicts](admission.md#recovering-a-submission-after-a-lost-reply) | `'exact model interruption'`, `'idle Session stop'`, `'controls remove scheduled retries'`, `'allow once survives'`, `'model revisions'` | Reopen is not crash recovery |
| Native control replay | `control_integration.py` `prove_idle_stop_wire_recovery`, `prove_retry_wait_control`, `check_schema`, `bash_integration.py`, `admission_integration.sh` | None |

### Control races and acknowledgement

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| Gated race ordering: sealed holds, four incomplete terminal inputs, dispatch stall witness, silent-sibling expiry, exhausted-recovery admission | `control_integration.py`, `human_cli_integration.py` `incomplete_input_case`, `dispatch_integration.py` | Exhausted recovery permits one real call before an opt-in nonblocking hold. The fixture requires its native receipt and owned empty FIFO before checking due/new launches, then releases recovery and checks drainage. A first-call full-drain mutant must fail the unresolved-sentinel assertion. Incomplete inputs run serially against one Host. Pasted typeahead before readiness must not approve an Action. The stall witness owns one inactivity failure; exhaustion and progressing cases own theirs |
| First committed control wins; [hint grants no authority](inspection.md#live-control-notification) | `prove_pre_handoff_stop`, `prove_sealed_interruption_and_cleanup`, `'without a control hint'` | Not remote termination. Omitting only the superseded branch's `finishCustodyNow` must fail the zero-custody deadline; no automated mutation located |
| Release within eight seconds | `HostDiagnostics.wait_model_cleanup`, `wait_for_execution_release`, `claim_inspection`, `host_process_test.py` | Not an idle-population census; no native macOS coverage |
| Control case disposal | `stop_control_case`, `prove_control_disposal_oracle` | Incoming assertion stays primary; cleanup failure still fails |
| [Stop excludes selected prefix](#stopping-selected-work) | `'Session stop freezes'` | Successor-selection race: none located |
