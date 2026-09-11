# pi-mono queued-input and failure semantics

Inspected the local upstream snapshot at commit [`3d959a71272c45bd8b543d9b2198fbf0349e990d`](https://github.com/badlogic/pi-mono/tree/3d959a71272c45bd8b543d9b2198fbf0349e990d) (the checked-out directory is `pi-agent-kotlin/reference/upstream/pi-mono/def47ec`; commit timestamp 2026-05-01). Source/docs are first-party pi-mono. No production code was changed.

## Observed contract

| State / event | Transition and evidence |
|---|---|
| Active run; steering submitted | `steer` queues the user message. The core loop polls steering after a completed assistant turn/tool batch and injects it before the next LLM call. See [`agent-session.ts:L1168-L1187`](https://github.com/badlogic/pi-mono/blob/3d959a71272c45bd8b543d9b2198fbf0349e990d/packages/coding-agent/src/core/agent-session.ts#L1168-L1187) and [`agent-loop.ts:L200-L218`](https://github.com/badlogic/pi-mono/blob/3d959a71272c45bd8b543d9b2198fbf0349e990d/packages/agent/src/agent-loop.ts#L200-L218). |
| Active run; follow-up submitted | `followUp` queues the message. After the loop has no more tool calls/steering, it polls follow-ups, makes them pending, and continues. See [`agent-session.ts:L1189-L1207`](https://github.com/badlogic/pi-mono/blob/3d959a71272c45bd8b543d9b2198fbf0349e990d/packages/coding-agent/src/core/agent-session.ts#L1189-L1207) and [`agent-loop.ts:L221-L233`](https://github.com/badlogic/pi-mono/blob/3d959a71272c45bd8b543d9b2198fbf0349e990d/packages/agent/src/agent-loop.ts#L221-L233). |
| Queue policy | `all` drains all queued messages; `one-at-a-time` drains one per completed turn/agent completion (documented in RPC settings). Docs: [`rpc.md:L317-L347`](https://github.com/badlogic/pi-mono/blob/3d959a71272c45bd8b543d9b2198fbf0349e990d/packages/coding-agent/docs/rpc.md#L317-L347). |
| Normal completion | Follow-ups are automatically consumed within the same low-level run; a queued steering message is consumed at the next turn boundary. The interactive docs summarize Enter/Alt+Enter behavior: [`usage.md:L58-L69`](https://github.com/badlogic/pi-mono/blob/3d959a71272c45bd8b543d9b2198fbf0349e990d/packages/coding-agent/docs/usage.md#L58-L69). |
| Model/provider error | Low-level `agent-loop` emits `turn_end`, then `agent_end`, and returns immediately on `stopReason === "error"` or `"aborted"`; it does not itself poll queues after that branch. See [`agent-loop.ts:L190-L198`](https://github.com/badlogic/pi-mono/blob/3d959a71272c45bd8b543d9b2198fbf0349e990d/packages/agent/src/agent-loop.ts#L190-L198). |
| Session-level transient error | Coding-agent recognizes provider/network/429/5xx-like errors (excluding context overflow), removes the failed assistant from active state while retaining it in session history, waits exponential backoff, then schedules `agent.continue()`. See [`agent-session.ts:L2426-L2522`](https://github.com/badlogic/pi-mono/blob/3d959a71272c45bd8b543d9b2198fbf0349e990d/packages/coding-agent/src/core/agent-session.ts#L2426-L2522). Thus queued input remains pending while retry runs and is eligible after the retry succeeds. |
| Retry exhausted/disabled | `_handleRetryableError` emits final `auto_retry_end` and resolves the retry wait without scheduling `continue`; the failed run then settles. See [`agent-session.ts:L2448-L2476`](https://github.com/badlogic/pi-mono/blob/3d959a71272c45bd8b543d9b2198fbf0349e990d/packages/coding-agent/src/core/agent-session.ts#L2448-L2476). Whether queued input is then resumed depends on the caller/UI initiating another `continue`/prompt; this snapshot has no generic post-error queue-drain branch in the low-level loop. |
| Explicit abort | `abort()` aborts retry/compaction and calls `agent.abort()`, then waits for idle: [`agent-session.ts:L1380-L1390`](https://github.com/badlogic/pi-mono/blob/3d959a71272c45bd8b543d9b2198fbf0349e990d/packages/coding-agent/src/core/agent-session.ts#L1380-L1390). The core abort only signals the active run and does not clear queues; queues can be explicitly cleared with `clearAllQueues()`: [`agent.ts:L261-L290`](https://github.com/badlogic/pi-mono/blob/3d959a71272c45bd8b543d9b2198fbf0349e990d/packages/agent/src/agent.ts#L261-L290). Interactive Escape is documented as abort + restore queued text to the editor, so UI behavior includes queue restoration: [`usage.md:L62-L65`](https://github.com/badlogic/pi-mono/blob/3d959a71272c45bd8b543d9b2198fbf0349e990d/packages/coding-agent/docs/usage.md#L62-L65). |

## Failure/recovery boundary

The source clearly distinguishes a low-level run completion (`agent_end`) from session retry handling. `agent_end` is emitted before coding-agent's asynchronous event processor performs retry/compaction handling ([`agent-session.ts:L568-L581`](https://github.com/badlogic/pi-mono/blob/3d959a71272c45bd8b543d9b2198fbf0349e990d/packages/coding-agent/src/core/agent-session.ts#L568-L581)). A transient error is automatically retried; an exhausted or non-retryable error has no source-level evidence here that arbitrary queued messages automatically resume. Normal successful completion does automatically drain follow-ups. The old snapshot documents no `agent_settled` event; newer `main` docs add that event and define it as the point after retry/compaction/queued continuation, so do not project that newer event onto this pin without checking the newer source.

## Compact transition form

```text
ACTIVE + steer      -> turn boundary -> inject steer -> next LLM turn
ACTIVE + follow_up  -> no tool/steer work -> inject follow_up -> next LLM turn
ACTIVE + transient error + retry budget -> agent_end -> backoff -> continue -> retry
ACTIVE + error with no retry budget -> agent_end -> terminal session wait; queued input not proven auto-resumed
ACTIVE + abort      -> aborted agent_end -> caller/UI clears/restores queue; abort itself does not clear queue
NORMAL completion   -> follow-up queue drained automatically before final agent_end
```

## Uncertainty

The local pin is older than the current GitHub `main` pages surfaced by web search. The current docs now describe `agent_settled` and the newer session implementation has a post-run continuation path; claims above intentionally bind to the locally pinned `3d959a…` source. Validate any final Latifa contract against the exact upstream revision it chooses.

### Newer upstream comparison (fetched 2026-09-11)

I fetched current upstream `main` at [`713bdf38d58e407db91c8d9747ea25546862b5c5`](https://github.com/badlogic/pi-mono/tree/713bdf38d58e407db91c8d9747ea25546862b5c5). Its coding-agent session now wraps the run in a post-run loop: after `agent.prompt()`, it repeatedly calls `_handlePostAgentRun()` and, while that returns true, `agent.continue()` ([`agent-session.ts:L1098-L1108`](https://github.com/badlogic/pi-mono/blob/713bdf38d58e407db91c8d9747ea25546862b5c5/packages/coding-agent/src/core/agent-session.ts#L1098-L1108), [`L1116-L1143`](https://github.com/badlogic/pi-mono/blob/713bdf38d58e407db91c8d9747ea25546862b5c5/packages/coding-agent/src/core/agent-session.ts#L1116-L1143)). Therefore on this newer revision, after a non-retryable or exhausted error, `_handlePostAgentRun()` can return `agent.hasQueuedMessages()` and automatically resume queued steering/follow-up messages. This is a material behavior change from the May pin. The newer RPC docs explicitly define `agent_end` as a low-level completion that may be followed by retry/compaction/queued continuation and `agent_settled` as the point where none remains ([`rpc.md:L893-L910`](https://github.com/badlogic/pi-mono/blob/713bdf38d58e407db91c8d9747ea25546862b5c5/packages/coding-agent/docs/rpc.md#L893-L910)).

The two `/private/tmp/onepage-*/pi-mono` paths contain only empty directory skeletons in this environment (zero regular files), so they supplied no inspectable newer pin or manifest. The fetched 713b commit is the inspectable current comparison.
