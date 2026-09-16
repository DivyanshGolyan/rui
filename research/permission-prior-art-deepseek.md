# DeepSeek Harness permission prior art

This is an evidence report for Rui, based on the freshly pulled
`deepseek-ai/deepseek-harness` tree at revision
`c291e7961a515f6d7af9304e7fd1d257929aef26` (the checkout has no published
GitHub release to cite). Links below are pinned to that revision.

## Where policy and authority live

The ordinary permission surface has two independent knobs: sandbox mode and
approval policy. `PermissionPresetService` composes them into presets, but
execution still reads the individual folds. A preset switch logs
`permission/preset`, then writes changed knobs through `setSandboxMode` and
`setApprovalPolicy`; the session projection is a read surface and `/permission`
is the write surface ([permission-presets/src/index.ts#L376-L398](https://github.com/deepseek-ai/deepseek-harness/blob/c291e7961a515f6d7af9304e7fd1d257929aef26/packages/interaction/permission-presets/src/index.ts#L376-L398)).

The durable approval policy is the last `approval/policy` event for that
session, falling back to the service default ([user-approval/src/index.ts#L229-L251](https://github.com/deepseek-ai/deepseek-harness/blob/c291e7961a515f6d7af9304e7fd1d257929aef26/packages/interaction/user-approval/src/index.ts#L229-L251)).
`ask` dispatches answerers; `never` is checked inside `ApprovalService.request`
before the waterfall, so listener order cannot bypass it
([user-approval/src/index.ts#L260-L285](https://github.com/deepseek-ai/deepseek-harness/blob/c291e7961a515f6d7af9304e7fd1d257929aef26/packages/interaction/user-approval/src/index.ts#L260-L285);
tests [approval.spec.ts#L409-L442](https://github.com/deepseek-ai/deepseek-harness/blob/c291e7961a515f6d7af9304e7fd1d257929aef26/packages/interaction/user-approval/tests/approval.spec.ts#L409-L442)).

Tool offering is separate from authority. Bash advertises
`sandbox_permissions` only when a confining executor is present, describes it
as a one-shot retry, validates the field/justification pair, and then calls
`approveEscalation` before execution ([tool-bash/src/index.ts#L197-L231](https://github.com/deepseek-ai/deepseek-harness/blob/c291e7961a515f6d7af9304e7fd1d257929aef26/packages/shell/tool-bash/src/index.ts#L197-L231),
[tool-bash/src/index.ts#L241-L268](https://github.com/deepseek-ai/deepseek-harness/blob/c291e7961a515f6d7af9304e7fd1d257929aef26/packages/shell/tool-bash/src/index.ts#L241-L268),
[tool-bash/src/index.ts#L329-L347](https://github.com/deepseek-ai/deepseek-harness/blob/c291e7961a515f6d7af9304e7fd1d257929aef26/packages/shell/tool-bash/src/index.ts#L329-L347)).
Tests explicitly inject an unadvertised escalation and expect execution to
reject, and check that non-widening requests do not prompt
([tool-bash tests#L622-L649](https://github.com/deepseek-ai/deepseek-harness/blob/c291e7961a515f6d7af9304e7fd1d257929aef26/packages/shell/tool-bash/tests/tools.spec.ts#L622-L649)).

An approval is a closed, one-shot outcome: only `allowed-once` grants; reject,
cancel and unavailable fail closed. Every request gets a fresh ID and an
`approval/asked` + `approval/decided` audit pair, but the request deliberately
contains tool identity/call ID/reason rather than duplicated arguments
([user-approval/src/types.ts#L14-L70](https://github.com/deepseek-ai/deepseek-harness/blob/c291e7961a515f6d7af9304e7fd1d257929aef26/packages/interaction/user-approval/src/types.ts#L14-L70),
[user-approval/src/index.ts#L208-L227](https://github.com/deepseek-ai/deepseek-harness/blob/c291e7961a515f6d7af9304e7fd1d257929aef26/packages/interaction/user-approval/src/index.ts#L208-L227)).
The service requires an open turn before appending the pair. An absent or
throwing answerer becomes `unavailable`; an abort wins a race and discards a
late answer ([approval.spec.ts#L47-L75](https://github.com/deepseek-ai/deepseek-harness/blob/c291e7961a515f6d7af9304e7fd1d257929aef26/packages/interaction/user-approval/tests/approval.spec.ts#L47-L75),
[approval.spec.ts#L272-L321](https://github.com/deepseek-ai/deepseek-harness/blob/c291e7961a515f6d7af9304e7fd1d257929aef26/packages/interaction/user-approval/tests/approval.spec.ts#L272-L321)).

## UI and process-local pending state

The browser approval consumer turns the remote waterfall request into a
`PendingApproval` object, registers it with the session UI, and waits for the
object's result. The UI returns `allowed-once` or `rejected`; scope release,
transport abort, or plugin disposal settles the resident object and removes it
([ui-approval/client/index.ts#L35-L68](https://github.com/deepseek-ai/deepseek-harness/blob/c291e7961a515f6d7af9304e7fd1d257929aef26/packages/client/ui-approval/src/client/index.ts#L35-L68),
[ui-approval/client/slots.ts#L68-L159](https://github.com/deepseek-ai/deepseek-harness/blob/c291e7961a515f6d7af9304e7fd1d257929aef26/packages/client/ui-approval/src/client/contract/slots.ts#L68-L159)).
The UI correlates by `callId` and does not duplicate tool arguments. Its
`PendingApproval` is resident Client state; the tests establish
cancellation/removal, not a durable pending-request store
([ui-approval.client.spec.tsx#L120-L190](https://github.com/deepseek-ai/deepseek-harness/blob/c291e7961a515f6d7af9304e7fd1d257929aef26/packages/client/ui-approval/tests/ui-approval.client.spec.tsx#L120-L190)).

The richer Cordis activation path makes the split explicit. The Host registry
holds a process-local `pendingRequests` map containing resolver metadata and
Plugin/package/run identities; claim is first-answer-wins
([registry.ts#L140-L147](https://github.com/deepseek-ai/deepseek-harness/blob/c291e7961a515f6d7af9304e7fd1d257929aef26/packages/extensions/cordis-host-runner/src/registry.ts#L140-L147),
[registry.ts#L228-L275](https://github.com/deepseek-ai/deepseek-harness/blob/c291e7961a515f6d7af9304e7fd1d257929aef26/packages/extensions/cordis-host-runner/src/registry.ts#L228-L275)).
The same registry stores per-plugin grants: approved package IDs and a boolean
for future versions ([registry.ts#L50-L69](https://github.com/deepseek-ai/deepseek-harness/blob/c291e7961a515f6d7af9304e7fd1d257929aef26/packages/extensions/cordis-host-runner/src/registry.ts#L50-L69)).

The exact Cordis flow is: a Client-bearing package requires approval unless its
package ID is in the grant set or the Plugin-wide flag is set; the attempt is
marked `awaiting-approval`, and the request is broadcast
([cordis-host-runner/src/index.ts#L264-L311](https://github.com/deepseek-ai/deepseek-harness/blob/c291e7961a515f6d7af9304e7fd1d257929aef26/packages/extensions/cordis-host-runner/src/index.ts#L264-L311)).
The UI offers approve once, approve this Plugin's future versions, or decline
([CordisPanel.tsx#L270-L307](https://github.com/deepseek-ai/deepseek-harness/blob/c291e7961a515f6d7af9304e7fd1d257929aef26/packages/extensions/ui-cordis/src/client/CordisPanel.tsx#L270-L307)).
Host validation binds the request ID to the exact Plugin/package/mode/run; an
approval adds the current package and optionally the future-version grant
([cordis-host-runner/src/index.ts#L324-L365](https://github.com/deepseek-ai/deepseek-harness/blob/c291e7961a515f6d7af9304e7fd1d257929aef26/packages/extensions/cordis-host-runner/src/index.ts#L324-L365)).
After activation commits, the attempt's approval fields are deleted
([cordis-host-runner/src/index.ts#L981-L991](https://github.com/deepseek-ai/deepseek-harness/blob/c291e7961a515f6d7af9304e7fd1d257929aef26/packages/extensions/cordis-host-runner/src/index.ts#L981-L991)).

## Reuse, change, reconnect, unattended operation

Session reuse is durable for the ordinary permission knobs: new sessions are
seeded from the current settings, while an existing/seeded session retains its
own logged values ([permission-presets/src/index.ts#L400-L430](https://github.com/deepseek-ai/deepseek-harness/blob/c291e7961a515f6d7af9304e7fd1d257929aef26/packages/interaction/permission-presets/src/index.ts#L400-L430),
[permission-presets.spec.ts#L216-L260](https://github.com/deepseek-ai/deepseek-harness/blob/c291e7961a515f6d7af9304e7fd1d257929aef26/packages/interaction/permission-presets/tests/permission-presets.spec.ts#L216-L260)).
That evidence does not establish persistence of pending approvals or Cordis
grants: those are fields in a process-local registry, not session events.

`setPolicy` appends the new policy and injects a user-visible change notice for
the next model step; setting the same value is a no-op. The source/tests do not
claim that a policy change revokes an already pending or already granted
action ([user-approval/src/index.ts#L170-L188](https://github.com/deepseek-ai/deepseek-harness/blob/c291e7961a515f6d7af9304e7fd1d257929aef26/packages/interaction/user-approval/src/index.ts#L170-L188),
[approval.spec.ts#L444-L476](https://github.com/deepseek-ai/deepseek-harness/blob/c291e7961a515f6d7af9304e7fd1d257929aef26/packages/interaction/user-approval/tests/approval.spec.ts#L444-L476)).

## Ordinary Bash approval across a browser reconnect

The ordinary Bash approval follows the same scoped Remote Event waterfall. The
Gateway keeps each pending invocation in `pendingRemoteEvents`; opening a new
Client stream immediately re-delivers every still-pending invocation
([gateway/src/index.ts#L404-L426](https://github.com/deepseek-ai/deepseek-harness/blob/c291e7961a515f6d7af9304e7fd1d257929aef26/packages/api/gateway/src/index.ts#L404-L426)).
When a browser's physical generation ends, the Client aborts its active listener
work and sends no late result ([gateway/client/remote-events.ts#L167-L182](https://github.com/deepseek-ai/deepseek-harness/blob/c291e7961a515f6d7af9304e7fd1d257929aef26/packages/api/gateway/src/client/remote-events.ts#L167-L182)).
The Host removes only that disconnected Client's delivery; the pending
invocation remains available for the replacement Client, whose new generation
creates a fresh UI pending object ([gateway/src/index.ts#L522-L552](https://github.com/deepseek-ai/deepseek-harness/blob/c291e7961a515f6d7af9304e7fd1d257929aef26/packages/api/gateway/src/index.ts#L522-L552)).

Concrete Bash trace: the sandboxed `bash` tool calls `ctx.approval.request`
with the tool call's signal; the Host emits `approval/request`; the browser
shows `PendingApproval`; a transient WebSocket loss aborts that browser-side
object, but the Host's pending Remote Event is re-delivered after reconnect.
The user can answer the new object and the Host still appends the one matching
`approval/decided` outcome. This is transport recovery, not replay from the
session log: the pending UI payload and resolver are rebuilt from live Host
state, while `approval/asked` is appended before waiting and the matching
`approval/decided` is appended when the Host request settles ([user-approval/src/index.ts#L208-L227](https://github.com/deepseek-ai/deepseek-harness/blob/c291e7961a515f6d7af9304e7fd1d257929aef26/packages/interaction/user-approval/src/index.ts#L208-L227)).

There is no approval-specific expiration window in the inspected source. The
connection has a per-generation readiness hard deadline (15 seconds by
default), then retries with jittered backoff (caps 500 ms through 10 seconds)
while the browser reports network availability; these govern generation setup,
not the lifetime of a pending approval
([client/connection/README.md#L46-L50](https://github.com/deepseek-ai/deepseek-harness/blob/c291e7961a515f6d7af9304e7fd1d257929aef26/packages/client/connection/README.md#L46-L50)).
If the forwarded-event source is removed or ends unexpectedly, Gateway calls
`closeRemoteEvents` and rejects all pending approvals, which is an actual
withdrawal/Host failure rather than a transient Client disconnect
([gateway/src/index.ts#L430-L445](https://github.com/deepseek-ai/deepseek-harness/blob/c291e7961a515f6d7af9304e7fd1d257929aef26/packages/api/gateway/src/index.ts#L430-L445),
[gateway/src/index.ts#L554-L583](https://github.com/deepseek-ai/deepseek-harness/blob/c291e7961a515f6d7af9304e7fd1d257929aef26/packages/api/gateway/src/index.ts#L554-L583)).

For Cordis, browser reconnect is handled by an authoritative Host inventory:
the Client rebuilds pending approvals from `latestRun` states
`awaiting-approval`, `starting-host`, and `client-pending`, dropping stale local
requests ([cordis-client-runner/orchestrator.ts#L178-L242](https://github.com/deepseek-ai/deepseek-harness/blob/c291e7961a515f6d7af9304e7fd1d257929aef26/packages/extensions/cordis-client-runner/src/client/orchestrator.ts#L178-L242)).
This is a reconnect/missed-event mechanism, not process-restart recovery: the
Host service constructs `new DynamicCordisRegistry()` and no serialization or
restore path appears in the inspected source ([cordis-host-runner/src/index.ts#L123-L144](https://github.com/deepseek-ai/deepseek-harness/blob/c291e7961a515f6d7af9304e7fd1d257929aef26/packages/extensions/cordis-host-runner/src/index.ts#L123-L144)).

Unattended behavior is explicit for ordinary approvals: `never` rejects before
prompting, and the shipped dangerous preset combines `danger-full-access` with
`never` ([permission-presets/src/index.ts#L163-L180](https://github.com/deepseek-ai/deepseek-harness/blob/c291e7961a515f6d7af9304e7fd1d257929aef26/packages/interaction/permission-presets/src/index.ts#L163-L180)).
The inspected Cordis UI flow is interactive; this report found no unattended
Cordis approval policy or durable pending payload mechanism. The evidence
supports a small design boundary: durable session policy/settings can survive
session reuse, while pending request payloads and per-process grants need an
explicit owner and recovery policy if Rui wants them to survive restart.
