# Pi permission prior art

This is source evidence for Latifa's open choice about permission ownership and
disconnected clients. It is not a proposed Latifa contract or production
qualification. Sources were read from Pi commit
`71dca871bc80b6bc97be37f0ca3189399d651fff` (`main`, 2026-09-13), with the
released `v0.85.1` tag checked separately. The permission paths below are
materially the same in the tag and main; the main changes touching them are
documentation URL changes, extension-loader schema checking, tool-schema
sampling, and RPC source annotations. No permission-policy redesign appears in
the tag-to-main diff.

## Policy ownership and authority

Pi has two distinct mechanisms:

* Project trust is startup input-loading policy. It decides whether project
  `.pi` settings/resources, project skills and extensions are loaded. The
  security contract explicitly says it does not restrict what the model can ask
  tools to do. Pi runs built-in tools and extensions with the OS permissions of
  the Pi process and has no built-in sandbox. [security.md#L3-L7](https://github.com/earendil-works/pi/blob/71dca871bc80b6bc97be37f0ca3189399d651fff/packages/coding-agent/docs/security.md#L3-L7), [security.md#L31-L37](https://github.com/earendil-works/pi/blob/71dca871bc80b6bc97be37f0ca3189399d651fff/packages/coding-agent/docs/security.md#L31-L37)
* Tool execution authority is an extension hook. `tool_call` runs after the
  assistant tool-use message is settled and before execution; a handler can
  mutate arguments or return `{block, reason, terminate}`. The agent core turns
  a block into an error tool result and does not execute the tool. [extensions.md#L778-L794](https://github.com/earendil-works/pi/blob/71dca871bc80b6bc97be37f0ca3189399d651fff/packages/coding-agent/docs/extensions.md#L778-L794), [agent-loop.ts#L626-L660](https://github.com/earendil-works/pi/blob/71dca871bc80b6bc97be37f0ca3189399d651fff/packages/agent/src/agent-loop.ts#L626-L660)

The `tool_call` event is a closed typed union for built-ins (`bash`, read,
write, edit, etc.) and custom tools, carrying the tool-call ID and validated
arguments. Arguments are mutable and later handlers see earlier mutations, but
Pi does not revalidate after mutation. [types.ts#L889-L954](https://github.com/earendil-works/pi/blob/71dca871bc80b6bc97be37f0ca3189399d651fff/packages/coding-agent/src/core/extensions/types.ts#L889-L954)
The runner invokes handlers in extension order and returns immediately on the
first blocking result. [runner.ts#L982-L1003](https://github.com/earendil-works/pi/blob/71dca871bc80b6bc97be37f0ca3189399d651fff/packages/coding-agent/src/core/extensions/runner.ts#L982-L1003)

The stock package deliberately has no permission popups, background bash,
MCP, or plan mode. A permission gate is an optional extension/package. [usage.md#L303-L311](https://github.com/earendil-works/pi/blob/71dca871bc80b6bc97be37f0ca3189399d651fff/packages/coding-agent/docs/usage.md#L303-L311)

## Approval and UI behavior

The documented extension example gates `rm -rf` by calling `ctx.ui.confirm` in
`tool_call`; false returns a blocking error. [extensions.md#L64-L75](https://github.com/earendil-works/pi/blob/71dca871bc80b6bc97be37f0ca3189399d651fff/packages/coding-agent/docs/extensions.md#L64-L75)
Prompt lifecycle events expose “waiting for user” status, but are notification
only and best effort. [extensions.md#L583-L599](https://github.com/earendil-works/pi/blob/71dca871bc80b6bc97be37f0ca3189399d651fff/packages/coding-agent/docs/extensions.md#L583-L599)
Dialogs can have a timeout or AbortSignal; timeout resolves select/input/editor
to undefined and confirm to false. [extensions.md#L2535-L2580](https://github.com/earendil-works/pi/blob/71dca871bc80b6bc97be37f0ca3189399d651fff/packages/coding-agent/docs/extensions.md#L2535-L2580)

In RPC, dialog approval is a request/response exchange. The server emits a
request with a random ID and blocks the extension until the matching response;
fire-and-forget notifications do not block. Timeouts resolve agent-side, so a
client need not implement timeout tracking. [rpc.md#L1184-L1200](https://github.com/earendil-works/pi/blob/71dca871bc80b6bc97be37f0ca3189399d651fff/packages/coding-agent/docs/rpc.md#L1184-L1200), [rpc-mode.ts#L79-L130](https://github.com/earendil-works/pi/blob/71dca871bc80b6bc97be37f0ca3189399d651fff/packages/coding-agent/src/modes/rpc/rpc-mode.ts#L79-L130)
The client answers by matching the ID; cancellation/unknown IDs do not grant
authority. [rpc-mode.ts#L768-L781](https://github.com/earendil-works/pi/blob/71dca871bc80b6bc97be37f0ca3189399d651fff/packages/coding-agent/src/modes/rpc/rpc-mode.ts#L768-L781)

## Grant scope and persistence

Project trust has explicit “Trust”, “Trust parent folder”, “Trust this session
only”, “Do not trust”, and session-only deny choices. Saved decisions are
canonical-directory booleans in `~/.pi/agent/trust.json`; nearest current or
ancestor path wins. The session-only choices have no store updates. [trust-manager.ts#L44-L95](https://github.com/earendil-works/pi/blob/71dca871bc80b6bc97be37f0ca3189399d651fff/packages/coding-agent/src/core/trust-manager.ts#L44-L95)
The store is synchronously locked and writes sorted JSON, with no expiry or
tool/action identity. [trust-manager.ts#L125-L175](https://github.com/earendil-works/pi/blob/71dca871bc80b6bc97be37f0ca3189399d651fff/packages/coding-agent/src/core/trust-manager.ts#L125-L175)

Resolution order is: explicit CLI override, no protected resources, extension
`project_trust` decision (which may remember), saved nearest path, global
`always`/`never`, then interactive selection. No UI under `ask` resolves false.
[project-trust.ts#L14-L95](https://github.com/earendil-works/pi/blob/71dca871bc80b6bc97be37f0ca3189399d651fff/packages/coding-agent/src/core/project-trust.ts#L14-L95)
Non-interactive print/JSON/RPC modes never show the trust prompt: `ask` and
`never` ignore unapproved project resources; `always` trusts them; CLI flags
override for one run. [security.md#L18-L29](https://github.com/earendil-works/pi/blob/71dca871bc80b6bc97be37f0ca3189399d651fff/packages/coding-agent/docs/security.md#L18-L29)

This durable trust grant is input-loading scope, not a durable “allow this
pending action” grant. The per-tool approval example has no remembered grant;
each matching call reaches the extension and its UI prompt again unless the
extension author adds its own state.

## Pending actions, disconnects and restart

RPC keeps pending UI requests in an in-memory `Map<id, resolver>` containing
only resolver/reject functions. The request payload is emitted to the client;
it is not persisted as an approval record. [rpc-mode.ts#L79-L130](https://github.com/earendil-works/pi/blob/71dca871bc80b6bc97be37f0ca3189399d651fff/packages/coding-agent/src/modes/rpc/rpc-mode.ts#L79-L130)
Closing stdin calls shutdown, which disposes the runtime and exits; there is no
reconnect or recovery path for a pending dialog in this RPC mode. [rpc-mode.ts#L722-L745](https://github.com/earendil-works/pi/blob/71dca871bc80b6bc97be37f0ca3189399d651fff/packages/coding-agent/src/modes/rpc/rpc-mode.ts#L722-L745), [rpc-mode.ts#L804-L807](https://github.com/earendil-works/pi/blob/71dca871bc80b6bc97be37f0ca3189399d651fff/packages/coding-agent/src/modes/rpc/rpc-mode.ts#L804-L807)
Thus a client disconnect cannot leave Pi waiting for approval and later resume;
the process terminates and any already-running work is governed by shutdown.
The regular session JSONL stores conversation/session entries, but the cited
permission implementation stores neither pending UI payloads nor per-action
approval decisions. Restart reloads project trust only if it was saved.

For unattended work, Pi's own guidance is to put the whole process or its tool
execution in an OS/container/VM/policy-controlled sandbox, with minimum files,
credentials and network. [security.md#L39-L53](https://github.com/earendil-works/pi/blob/71dca871bc80b6bc97be37f0ca3189399d651fff/packages/coding-agent/docs/security.md#L39-L53)

## Tests and limits

The release tests prove extension blocking prevents execution and produces an
error tool result, including `terminate` stopping the run after a blocked call.
[agent-session-model-extension.test.ts#L237-L265](https://github.com/earendil-works/pi/blob/v0.85.1/packages/coding-agent/test/suite/agent-session-model-extension.test.ts#L237-L265), [5998-blocked-tool-terminate.test.ts#L16-L52](https://github.com/earendil-works/pi/blob/v0.85.1/packages/coding-agent/test/suite/regressions/5998-blocked-tool-terminate.test.ts#L16-L52)

They do not test durable action grants, policy change races, pending approval
recovery, client reconnect, or server restart. Those behaviors should not be
inferred from Pi. The release tag `v0.85.1` and main commit above are the
separate source pins used here.
