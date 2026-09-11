# DeepSeek queued-input behavior

Research date: 2026-09-11 (Asia/Kolkata). Sources were restricted to first-party DeepSeek documentation and the official `deepseek-ai/deepseek-harness` repository. Local checkout inspected: commit [`b2e3b2a`](https://github.com/deepseek-ai/deepseek-harness/tree/b2e3b2a0125854567a4a5fcba75782e42fe84901), committed 2026-09-09 (UTC+8). Its manifests identify `@deepseek-ai/dsh-agent` and `@deepseek-ai/dsh-agent-loop` as `0.1.5-alpha.2`. DeepSeek labels Harness a developer preview, so these findings are version-sensitive.

## Product boundary

There are two different products:

1. **DeepSeek Chat/API.** The official API docs describe each call as a request containing `messages` (Chat Completions) or `input` (Responses API), with a streamed response ending in `response.completed`, `response.incomplete`, or `response.failed`. They do not document a per-conversation user-input queue, accepting a second prompt while a response is running, or automatic replay after a failed request. The API rate-limit page says a request that has not started inference after 10 minutes is closed; this is a connection/request behavior, not a queued-message guarantee.
2. **DeepSeek Harness, the official coding/agent runtime.** This is the relevant first-party source for an agent with an inbox and ongoing work. Its public contract explicitly defines queued follow-ups, steering, cancellation, claim boundaries, and recovery.

Sources: [DeepSeek API first call](https://api-docs.deepseek.com/) (request shape and Harness developer-preview status); [Responses API](https://api-docs.deepseek.com/guides/responses_api/) (stream lifecycle); [rate limits and keep-alive](https://api-docs.deepseek.com/quick_start/rate_limit/) (10-minute pre-inference connection close); [agent package manifest at inspected commit](https://github.com/deepseek-ai/deepseek-harness/blob/b2e3b2a0125854567a4a5fcba75782e42fe84901/packages/core/agent/package.json); [agent-loop manifest at inspected commit](https://github.com/deepseek-ai/deepseek-harness/blob/b2e3b2a0125854567a4a5fcba75782e42fe84901/packages/core/agent-loop/package.json).

## Known Harness transitions

### User message arrives during ongoing work

`followup(message)` inserts an ordinary `next-turn` message and wakes the driver. The message is FIFO and becomes the sole ordinary message of its own later turn. `steer(message)` inserts waking `next-step` input; a running driver claims it at its next step boundary. The official subagent contract summarizes this as: the inbox is the only queue, follow-ups become FIFO turns, and a running activation enqueues into the same activation.

At a step boundary, the loop claims the proposed batch through durable deletion splices. A message inserted after that claim remains pending for a later boundary. The public API returns no per-message completion handle: a `MessageId` proves insertion/claim/discard lifecycle facts, not a later assistant output or `turn/end`.

Sources: [agent README, driving and admission](https://github.com/deepseek-ai/deepseek-harness/blob/b2e3b2a0125854567a4a5fcba75782e42fe84901/packages/core/agent/README.md#drive-an-agents-conversation); [subagent continuation contract](https://github.com/deepseek-ai/deepseek-harness/blob/b2e3b2a0125854567a4a5fcba75782e42fe84901/.agents/notes/implemented/feature/2026-07-28-continuable-subagent-conversations.md#one-inbox-and-follow-up-delivery); [runtime type contract](https://github.com/deepseek-ai/deepseek-harness/blob/b2e3b2a0125854567a4a5fcba75782e42fe84901/packages/core/agent/src/runtime-types.ts); [agent-loop README](https://github.com/deepseek-ai/deepseek-harness/blob/b2e3b2a0125854567a4a5fcba75782e42fe84901/packages/core/agent-loop/README.md).

### Failure before queued input is consumed

The loop may claim a message before assembling the request and running `agent/pre-step`. Cancellation during those asynchronous phases commits neither the system prompt nor user batch. Once a batch has been claimed, however, it is removed from the inbox. If `agent/pre-step` rejects, the claimed message is not restored; the turn closes without a model step. A message arriving after the claim remains pending.

For a model request that fails, the loop emits `agent/request-error`; optional retry middleware may return a retry action, otherwise the failure is terminal. The official contract records a failed/stopped/rejected turn that had claimed input as consumed work, while separately distinguishing accepted work canceled out of the inbox before it ran. Therefore “accepted into the queue” and “claimed by a turn” are different durable states.

Sources: [agent README, step admission and consumed work](https://github.com/deepseek-ai/deepseek-harness/blob/b2e3b2a0125854567a4a5fcba75782e42fe84901/packages/core/agent/README.md#step-admission); [agent-loop README, recovery and claim behavior](https://github.com/deepseek-ai/deepseek-harness/blob/b2e3b2a0125854567a4a5fcba75782e42fe84901/packages/core/agent-loop/README.md); [core docs, `agent/inbox/claimed` and request errors](https://github.com/deepseek-ai/deepseek-harness/blob/b2e3b2a0125854567a4a5fcba75782e42fe84901/docs/subsystems/core.md).

### Pending messages after failure/cancellation: auto-resume?

**Harness answer: terminal provider failure does not auto-resume an unclaimed queued message; cancellation has separate, conditional wake behavior.**

The decisive driver path is in the inspected `agent-loop` source: `kick()` runs `while (await this.turn()) {}` but catches a terminal turn error, then its `finally` transitions to `idle`. The terminal error path in `turn()` throws after writing `turn/end`; it therefore exits the driver before the ordinary `hasPending` continuation check. An unclaimed `next-turn` message remains in the inbox and needs a later waking delivery. This is distinct from `agent/request-error` returning `{ kind: 'retry' }`, which retries the same model step, and from cancellation, which has its own wake latch.

- A pending `next-turn` item is retained when cancellation uses `cancel(cause, { keepInbox: true })`. The official cancellation test parks it after the active turn aborts; a later waking `followup` causes the parked item to run FIFO before the new follow-up. This is preservation plus a later wake, not unconditional automatic replay.
- A wake submitted after active cancellation but before the driver reaches idle is latched and replayed at the driver's convergence boundary, so that newly submitted wake runs without another send. This is a narrow cancellation-convergence rule.
- Ordinary `cancel()` clears pending inbox work. Disposal also leaves later waking input parked/discarded according to the disposal contract; it is not a resume path.
- The continuation manager’s routing table says `running` enqueues in the same activation, `waiting` wakes the same activation, and no activation cold-resumes a new activation. That is Harness runtime behavior and should not be projected onto the standalone DeepSeek API.

Sources: [official cancellation tests](https://github.com/deepseek-ai/deepseek-harness/blob/b2e3b2a0125854567a4a5fcba75782e42fe84901/packages/core/agent-loop/tests/cancel.spec.ts#L2191-L2197) (especially the `parks queued work after an active turn aborts` case); [runtime types, cancel and send docs](https://github.com/deepseek-ai/deepseek-harness/blob/b2e3b2a0125854567a4a5fcba75782e42fe84901/packages/core/agent/src/runtime-types.ts#L1307-L1374); [continuation routing](https://github.com/deepseek-ai/deepseek-harness/blob/b2e3b2a0125854567a4a5fcba75782e42fe84901/.agents/notes/implemented/feature/2026-07-28-continuable-subagent-conversations.md#one-inbox-and-follow-up-delivery).

The terminal-failure trace is [the inspected `agent-loop` implementation](https://github.com/deepseek-ai/deepseek-harness/blob/b2e3b2a0125854567a4a5fcba75782e42fe84901/packages/core/agent-loop/src/agent.ts) (`kick()` catch/finally and `turn()` error path). The retry distinction is covered by the [official request-error tests](https://github.com/deepseek-ai/deepseek-harness/blob/b2e3b2a0125854567a4a5fcba75782e42fe84901/packages/core/agent-loop/tests/request-error.spec.ts).

## Unknown / do not claim

- No official DeepSeek Chat web-app documentation located in this pass promises that typing/submitting a second user message during generation queues it, preserves it across a failed request, or auto-resumes it.
- No standalone DeepSeek API parameter or protocol was found for queue admission, cancellation with queue retention, or post-failure replay. An API client could implement these above the API by storing messages and retrying, but that would be client behavior.
- Harness’s documented queue behavior belongs to the developer-preview runtime and its `Agent`/`AgentLoop` APIs. It is evidence for a coding-agent comparison, not evidence about DeepSeek model capability or the hosted Chat product.
- The docs distinguish “pending in inbox,” “claimed by a turn,” and “entered a model step.” A failed request after claim can consume the message even if no assistant answer is committed; do not collapse these into one `started` or `completed` state.

## Compact comparison transitions

| Situation | DeepSeek Chat/API | DeepSeek Harness |
|---|---|---|
| New user input while model work runs | Undocumented; API request is caller-owned | `followup` queues FIFO `next-turn`; `steer` targets next step |
| Failure before claim/admission | No queue contract | If cancellation occurs during admission, no batch commit; pending item remains if not claimed |
| Failure after claim, before model step | No queue contract | Claimed message is removed; rejection closes turn without step and does not restore it |
| Terminal provider failure with B still unclaimed | No queue contract | Turn ends with error; driver returns to idle and leaves B pending; no automatic resume |
| Active turn canceled with pending input | No queue contract | `keepInbox:true` preserves pending input; ordinary cancel clears it |
| Does pending input run automatically afterward? | Unknown / client-defined | Terminal failure: no. `keepInbox` cancellation: later wake required, except a narrow cancellation-convergence latch |
| Cold process/session recovery | No API guarantee found | Continuation layer documents cold-resume when no activation, but this is Harness behavior and version-sensitive |
