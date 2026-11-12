# OpenCode v2 permission prior art

Research pin: `anomalyco/opencode` commit
[`c5aa7d7e34a19af7b94f5937f905ab2bac58e4a7`](https://github.com/anomalyco/opencode/commit/c5aa7d7e34a19af7b94f5937f905ab2bac58e4a7), checked out as branch `v2` in
`/tmp/opencode-src.FyoefB` on 2026-09-13. The commit is the September 12
“sync release versions for v2.0.3” pin. This is current stable v2 source
evidence; the earlier `2.0` exploratory branch was the wrong research target.
This note makes no Rui product decision.

## Authority owner and tool boundary

Stable v2's core permission service owns evaluation, pending requests, replies,
and saved approvals. Its service interface exposes `ask`, `assert`, `reply`,
`get`, session filtering, and list operations. [core/src/permission.ts:87-112](https://github.com/anomalyco/opencode/blob/c5aa7d7e34a19af7b94f5937f905ab2bac58e4a7/packages/core/src/permission.ts#L87-L112)

Rules are `{action, resource, effect}` with last matching rule winning; no match
means `ask`. The service first evaluates configured agent plus session rules,
then saved project approvals. A configured deny is checked before saved rules,
so a deny remains authoritative over a saved allow. [permission.ts:143-183](https://github.com/anomalyco/opencode/blob/c5aa7d7e34a19af7b94f5937f905ab2bac58e4a7/packages/core/src/permission.ts#L143-L183)

The model-facing registry only filters wholly disabled tools when building a
snapshot. It does not own execution authorization. [tool.ts:217-240, 278-281](https://github.com/anomalyco/opencode/blob/c5aa7d7e34a19af7b94f5937f905ab2bac58e4a7/packages/core/src/tool.ts#L217-L240)
[tools spec:123-125](https://github.com/anomalyco/opencode/blob/c5aa7d7e34a19af7b94f5937f905ab2bac58e4a7/specs/v2/tools.md#L123-L125)

Trusted built-in and Location-plugin tools capture `Permission.Service` and
formulate requests themselves. The v2 tools contract shows a grep tool calling
`permission.assert` before filesystem work; the registry injects no generic
assertion helper. [tools spec:84-123](https://github.com/anomalyco/opencode/blob/c5aa7d7e34a19af7b94f5937f905ab2bac58e4a7/specs/v2/tools.md#L84-L123)

Concrete shell ordering is explicit: parse the command, resolve directories,
request external-directory authorization, then assert shell action/resources,
then validate the workdir immediately before spawning. The comment records that
approval may outlive the directory, so the final target is revalidated. [shell.ts:114-150](https://github.com/anomalyco/opencode/blob/c5aa7d7e34a19af7b94f5937f905ab2bac58e4a7/packages/core/src/tool/plugin/shell.ts#L114-L150)

Tool calls have durable Session, assistant message and call IDs in their
runner-supplied context; the registry captures the effective registration for
the model request and executes that captured tool. [tools spec:29-47, 127-146](https://github.com/anomalyco/opencode/blob/c5aa7d7e34a19af7b94f5937f905ab2bac58e4a7/specs/v2/tools.md#L29-L47)
[tools spec:127-146](https://github.com/anomalyco/opencode/blob/c5aa7d7e34a19af7b94f5937f905ab2bac58e4a7/specs/v2/tools.md#L127-L146)

## Approval and enforcement trace

`assert` evaluates policy. For deny it returns a typed `BlockedError`; for allow
it returns immediately; for ask it creates a request, publishes
`permission.asked`, and awaits a deferred. The decline path intentionally tunnels
through a defect until `SessionModelRequest.executeTool` converts it into a
tool/step outcome, preventing a tool from swallowing a user's “no”. [permission.ts:221-248](https://github.com/anomalyco/opencode/blob/c5aa7d7e34a19af7b94f5937f905ab2bac58e4a7/packages/core/src/permission.ts#L221-L248)
[model-request.ts:332-347](https://github.com/anomalyco/opencode/blob/c5aa7d7e34a19af7b94f5937f905ab2bac58e4a7/packages/core/src/session/model-request.ts#L332-L347)

The pending map stores the full request, optional agent identity, and deferred.
Creation is uninterruptible and rejects duplicate IDs; event-publish failure
removes the map entry. [permission.ts:114-141, 186-219](https://github.com/anomalyco/opencode/blob/c5aa7d7e34a19af7b94f5937f905ab2bac58e4a7/packages/core/src/permission.ts#L114-L141)
[permission.ts:186-219](https://github.com/anomalyco/opencode/blob/c5aa7d7e34a19af7b94f5937f905ab2bac58e4a7/packages/core/src/permission.ts#L186-L219)

The HTTP handler lists pending requests, creates an external permission request,
gets/replies by Session plus request ID, updates session rules, lists saved
approvals, and removes a saved approval. It checks that a request belongs to the
addressed Session before replying. [handlers/permission.ts:17-115](https://github.com/anomalyco/opencode/blob/c5aa7d7e34a19af7b94f5937f905ab2bac58e4a7/packages/server/src/handlers/permission.ts#L17-L115)

The web app's permission dock shows the action's localized description and every
resource, with Deny, Allow always, and Allow once buttons. [session-permission-dock.tsx:8-72](https://github.com/anomalyco/opencode/blob/c5aa7d7e34a19af7b94f5937f905ab2bac58e4a7/packages/app/src/session/requests/session-permission-dock.tsx#L8-L72)

## Grant scopes and policy changes

Replies are `once`, `always`, or `reject`. Reject fails the selected deferred,
then rejects every other pending request in that Session. `always` persists only
when the request includes non-empty `save` resources; it inserts project-scoped
action/resource rows, succeeds the current wait, and reevaluates other pending
requests. Unlike reject's same-Session fanout, the `always` reevaluation loop
walks every pending request owned by the current Location, retaining each
request's original optional agent. [permission.ts:254-310](https://github.com/anomalyco/opencode/blob/c5aa7d7e34a19af7b94f5937f905ab2bac58e4a7/packages/core/src/permission.ts#L254-L310)

Saved approvals are durable SQLite rows with independent IDs, project ID,
action, resource, timestamps, and a project/action/resource uniqueness index.
They can be listed, added, and removed. [permission/sql.ts:7-20](https://github.com/anomalyco/opencode/blob/c5aa7d7e34a19af7b94f5937f905ab2bac58e4a7/packages/core/src/permission/sql.ts#L7-L20)
[permission/saved.ts:17-80](https://github.com/anomalyco/opencode/blob/c5aa7d7e34a19af7b94f5937f905ab2bac58e4a7/packages/core/src/permission/saved.ts#L17-L80)

Saved rules are loaded for the current Location's project on every evaluation,
not copied into the pending map. Thus an `always` grant survives server restart
and applies across Sessions in that project, subject to configured deny
precedence. The permission tests assert saved bash approval allows a matching
request, while a configured deny still wins. [permission.ts:143-183](https://github.com/anomalyco/opencode/blob/c5aa7d7e34a19af7b94f5937f905ab2bac58e4a7/packages/core/src/permission.ts#L143-L183)
[permission.test.ts:255-273](https://github.com/anomalyco/opencode/blob/c5aa7d7e34a19af7b94f5937f905ab2bac58e4a7/packages/core/test/permission.test.ts#L255-L273)

Session policy is a separate durable ruleset. `Session.setPermissions` emits a
policy event and the projector writes it to the Session row. [session.ts:76-82](https://github.com/anomalyco/opencode/blob/c5aa7d7e34a19af7b94f5937f905ab2bac58e4a7/packages/core/src/session/session.ts#L76-L82)
[projector.ts:576-582](https://github.com/anomalyco/opencode/blob/c5aa7d7e34a19af7b94f5937f905ab2bac58e4a7/packages/core/src/session/projector.ts#L576-L582)

Policy is read at each `ask`/`assert`, so changes affect subsequent checks.
Tests change agent/session rules between calls and verify allow, deny, or ask;
they also verify that a saved approval does not bypass a later configured deny.
[permission.test.ts:100-148, 227-273](https://github.com/anomalyco/opencode/blob/c5aa7d7e34a19af7b94f5937f905ab2bac58e4a7/packages/core/test/permission.test.ts#L100-L148)
[permission.test.ts:227-273](https://github.com/anomalyco/opencode/blob/c5aa7d7e34a19af7b94f5937f905ab2bac58e4a7/packages/core/test/permission.test.ts#L227-L273)

When an `always` save releases other pending requests, each is reevaluated with
its original optional agent. A configured deny or missing Session prevents that
pending request from being auto-released. [permission.ts:295-307](https://github.com/anomalyco/opencode/blob/c5aa7d7e34a19af7b94f5937f905ab2bac58e4a7/packages/core/src/permission.ts#L295-L307)
[permission.test.ts:339-373](https://github.com/anomalyco/opencode/blob/c5aa7d7e34a19af7b94f5937f905ab2bac58e4a7/packages/core/test/permission.test.ts#L339-L373)

## Disconnect, restart, unattended operation

The pending request and deferred are process-local. The permission service finalizer
fails all pending waits with `DeclinedError` and clears the map. A server restart
therefore does not recover an in-flight approval, although saved project grants
and Session policy reload from SQLite. [permission.ts:120-141](https://github.com/anomalyco/opencode/blob/c5aa7d7e34a19af7b94f5937f905ab2bac58e4a7/packages/core/src/permission.ts#L120-L141)

The web app's auto-approver is client-local and setting-driven. It listens for
asked events, sweeps pending requests after each connection, retries failed
replies twice, and replies `once`; it explicitly notes that event streams do not
replay asks from a disconnected interval. Its sweep covers active and locally
known Sessions, with one documented gap for a detached request on a never-loaded
Session. [auto-approve.ts:11-44, 46-71](https://github.com/anomalyco/opencode/blob/c5aa7d7e34a19af7b94f5937f905ab2bac58e4a7/packages/app/src/session/requests/auto-approve.ts#L11-L71)
[auto-approve.ts:74-127](https://github.com/anomalyco/opencode/blob/c5aa7d7e34a19af7b94f5937f905ab2bac58e4a7/packages/app/src/session/requests/auto-approve.ts#L74-L127)

The app-level auto-approve setting applies to every Session, tab, and server in
that client, but the actual reply is a one-time grant. This is an unattended
mode with bounded retries and incomplete inventory coverage, not a durable
server-side bypass. [auto-approve.ts:11-16, 112-135](https://github.com/anomalyco/opencode/blob/c5aa7d7e34a19af7b94f5937f905ab2bac58e4a7/packages/app/src/session/requests/auto-approve.ts#L11-L16)

Stable v2's execution spec says execution is process-local by Session ID,
shutdown interruption preserves recovery claims, and startup resumes claimed
top-level Sessions. It also says orphan running/streaming tool calls are failed
without replaying ambiguous side effects. These are execution recovery rules;
they do not make an approval wait durable. [session spec:53-80](https://github.com/anomalyco/opencode/blob/c5aa7d7e34a19af7b94f5937f905ab2bac58e4a7/specs/v2/session.md#L53-L80)

## Tests and limits

Stable v2 has a focused `packages/core/test/permission.test.ts`. It covers
evaluation-only `ask`, explicit agent selection, allow/deny without prompts,
saved approval and deny precedence, one-time resolution, rejection, persistence
and removal of saved resources, and preservation of pending requests blocked by
new denies or a missing Session. [permission.test.ts:100-373](https://github.com/anomalyco/opencode/blob/c5aa7d7e34a19af7b94f5937f905ab2bac58e4a7/packages/core/test/permission.test.ts#L100-L373)

The tests were inspected, not run. Their assertions cover service semantics,
not full power-loss or network disconnect qualification. They do not prove that a pending approval survives
process death; source finalization indicates the opposite. The saved-grant
scope is project/action/resource, while Session rules are per Session. Tool
offering is a filtered snapshot; execution authority remains in trusted tool
code calling `Permission.assert`. UI behavior is app evidence, not core
authorization.
