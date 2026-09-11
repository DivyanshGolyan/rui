# Codex queued input and steering (source research)

Source: OpenAI Codex checkout `/private/tmp/onepage73-codex`, commit `968835997714baaff199cfed5f89a2c65d8ca77d` (2026-09-10). The links below are immutable GitHub source links at that commit. This is source analysis; no live provider run was used.

## Scope and terminology

Codex has separate queue layers:

| Layer | What it stores | While a turn runs | Boundary / owner |
|---|---|---|---|
| TUI local queue | `ChatWidget` drafts in `queued_user_messages` | A submitted prompt is queued as a follow-up; `maybe_send_next_queued_input` starts one only when idle | `codex-rs/tui/src/chatwidget/input_queue.rs:23-50`, `input_flow.rs:199-231` ([source](https://github.com/openai/codex/blob/968835997714baaff199cfed5f89a2c65d8ca77d/codex-rs/tui/src/chatwidget/input_queue.rs#L23-L50)) |
| TUI pending steer | `pending_steers`: input already sent to core but not yet committed to history | Same-turn steering is held/displayed separately from ordinary queued follow-ups | `input_queue.rs:31-46`, input submission creates it when `render_in_history` is false ([source](https://github.com/openai/codex/blob/968835997714baaff199cfed5f89a2c65d8ca77d/codex-rs/tui/src/chatwidget/input_submission.rs#L361-L384)) |
| Core pending input | `TurnState.pending_input.items` (`TurnInput`) | `get_pending_input` drains it only when the turn accepts mailbox delivery; steering wakes delivery | `codex-rs/core/src/session/input_queue.rs:259-323` ([source](https://github.com/openai/codex/blob/968835997714baaff199cfed5f89a2c65d8ca77d/codex-rs/core/src/session/input_queue.rs#L259-L323)) |
| Durable queue extension | SQLite-backed `QueuedUserSubmissionRecord`, user input only | Does not steer an active turn; dispatch calls `start_turn_if_idle` | `codex-rs/ext/queue/src/service.rs:265-279,367-402` ([source](https://github.com/openai/codex/blob/968835997714baaff199cfed5f89a2c65d8ca77d/codex-rs/ext/queue/src/service.rs#L265-L279)) |

The durable queue rejects empty/non-user input and snapshots local attachments before persistence (`service.rs:493-531`). Its dispatcher reads only the head item, starts it with `turn_trigger: "queue"`, and deletes it only after `Started`; `NotSubmitted` or a core error leaves the item in storage (`service.rs:405-468`).

## Interactive transition table

| Current state | Input / event | Result for B (queued follow-up) | Evidence / prototype rule |
|---|---|---|---|
| Running regular turn | User submits another ordinary prompt | B enters TUI local queue; it is not sent immediately. | `maybe_send_next_queued_input` returns while `is_user_turn_pending_or_running`; it pops/submits exactly one once idle (`input_flow.rs:199-231,299-304`). |
| Running regular turn | User submits steerable same-turn input | Input is a pending steer, sent through core steering, and shown in a separate preview category; it is not a durable queued turn. | TUI stores `pending_steers` separately (`input_queue.rs:31-46,71-103`); core `TurnInputMode::Steer` requires an active turn and expected turn id (tests `turn_input_tests.rs:838-895`). |
| Running `/review` or `/compact` | User tries to steer | Rejected steer is retained for later retry as a fresh user turn; direct protocol `turn/steer` fails with `ActiveTurnNotSteerable`. | Core tests classify Review and Compact as `NotSubmitted::ActiveTurnNotSteerable` (`turn_input_tests.rs:935-993`); app-server maps this error (`turn_processor.rs:1093-1126`). |
| Running any turn | `thread/queue/start` | Request fails as busy and durable B remains queued. | Processor maps `NotIdle`/`PendingTriggerTurn` to “thread already has an active or pending turn” (`thread_queue_processor.rs:181-215`). |
| Turn interrupted / abort | Turn reaches idle with `ThreadIdleCause::Interrupted` | B stays queued; no automatic dispatch. | Lifecycle contract says interruption is distinct (`extension-api/.../thread_lifecycle.rs:57-75`); queue contributor returns immediately for Interrupted (`service.rs:549-553`). App-server test confirms interruption preserves all queue items (`thread_queue.rs:591-606`). |
| Terminal provider/core failure | Turn reaches idle with `ThreadIdleCause::Failed` | B is auto-dispatched as a new turn; the failed turn itself is not retried. | Core derives `Failed` only when no abort reason and `terminal_error` exists (`core/src/tasks/mod.rs:796-805`). Queue test is named and asserts “failed turns drain” (`ext/queue/tests/queue_service.rs:478-513`). |
| Normal completion | Turn reaches idle with `Completed` | B is auto-dispatched FIFO, one at a time; successful start deletes B. | Queue contributor calls `dispatch_if_idle` for non-interrupted causes (`service.rs:549-565`); FIFO test asserts A, B, C and empty queue (`queue_service.rs:516-568`). |
| Queue dispatch cannot start B | Core returns `NotSubmitted` or submission error | B remains durable and the dispatch attempt stops; external watcher retries the wake/check later. | `dispatch_if_idle` returns without deletion on both paths (`service.rs:439-467`); external watcher has independent per-thread dispatch loops and retries failed wake checks (`service.rs:89-96,193-243`; test `queue_service.rs:571-698`). |
| Queue item explicitly started but prompt hook rejects it | `thread/queue/start` did start the turn | Item is consumed, no provider request is made, and following queue items can proceed; this is a policy rejection, not a retry. | Test `rejected_queue_messages_are_consumed_without_retrying_or_blocking_followups` (`queue_service.rs:701-799`). |
| TUI transport disconnect | App-server connection drops while local B exists | Keep B editable/recoverable and suppress queue autosend; do not automatically retry because acceptance is unknown. | Reconnect module says it “never automatically retry[ies] queued submissions”; `pause_for_disconnect` sets `recovered_queue` and `suppress_queue_autosend` (`tui/src/chatwidget/reconnect.rs:1-33,35-64`). |
| Cold thread resume | Durable B exists for an unloaded thread | `thread/resume` loads the thread and dispatches persisted B; metadata reads alone do not resume it. | App-server test asserts `thread/list`/loaded-list do not resume, then `thread/resume` starts B and removes it (`app-server/tests/suite/v2/thread_queue.rs:470-555`). `thread/queue/start` also requires a resumed loaded thread (`thread_queue_processor.rs:186-190`). |

## Answer to the requested failure case

For a provider terminal failure in turn A with B still queued, the production-shaped behavior is:

`A running -> terminal error -> core emits Failed idle cause -> queue contributor starts B -> B is deleted only after start succeeds.`

There is no source evidence that the provider request for A is retried by the queue extension. B is a fresh turn. If A is interrupted/aborted, B remains queued. If the transport disconnects before acceptance is known, the TUI deliberately holds B for manual recovery. If starting B itself fails before `Started`, durable B remains and the watcher can attempt another wake; a successfully started but policy-rejected queued turn is consumed by the separate explicit-start path covered by the test above.

## Boundary recommendation for a Latifa prototype

Model `queued(B)` and `steer(S)` as different pending states. A steer requires an active, steerable turn and an expected-turn-id precondition; it belongs to A’s continuation. B requires idle admission and starts a new turn. At terminal failure, transition `Failed -> dispatch(head(B))`; at interruption, `Interrupted -> retain(B)`; at successful completion, `Completed -> dispatch(head(B))`. Treat transport failure as `UnknownAcceptance -> retain(B), suppress_autosend`, rather than guessing whether A accepted the input.

The durable queue’s source does not define an automatic retry counter or retry of the same provider turn. Any Latifa retry policy would therefore be new behavior and should be specified separately from queue draining.
