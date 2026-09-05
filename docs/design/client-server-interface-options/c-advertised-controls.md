# Candidate C: inspect, then use typed advertised controls

> **Historical design exploration, published 6 September 2026.** The [normative architecture](../../../ARCHITECTURE.md) and [product contract](../../../PRODUCT.md) own the current design. Earlier signatures, issue ownership, status statements, and unselected alternatives below retain their original context; they are not a second current specification.

This design optimizes the agent’s decision loop: inspect a Run, select a typed control returned beside the relevant fact, fill only its caller-owned fields, and invoke it. The HTTP paths are ordinary resource paths, but callers do not construct them. The server supplies exact targets and descriptor digests. These controls are data, never executable instructions or bearer capabilities.

## Interface shape

The generated wire schema defines a closed family of controls and separate domain methods:

```ts
type U64 = string;
type ControlBase = { method: "POST"; href: string };
type CreateControl = ControlBase & { kind: "create_run" };
type MessageControl = ControlBase & {
  kind: "send_message"; run: RunId; turn: TurnId;
};
type PermissionControl = ControlBase & {
  kind: "decide_permission"; run: RunId;
  request: PermissionRequestId; descriptorDigest: Digest;
};
type InterruptControl = ControlBase & {
  kind: "interrupt_model"; run: RunId; turn: TurnId;
  operation: ModelOperationId;
};
type CancelControl = ControlBase & { kind: "cancel_run"; run: RunId };
// Controls are returned in the matching typed inspection record.
// Each control has its own generated request/response types.
```

A control is an immutable suggestion for an exact target, not a guarantee that the operation remains applicable. It has no nonce, expiry, signature, or durable backing record. `href` must be an origin-relative path, used only on the selected Unix socket. Its `kind` selects a generated typed encoder, not a general form interpreter.

The concrete route allocation is:

- `GET /v1` → authenticated discovery: Store identity, wire version, readiness, and `CreateControl`.
- `POST /v1/runs` → keyed create/reattach, returning Run identity, inspection link and cancellation control.
- `GET /v1/runs/{run}` → complete streamed inspection, including relevant controls.
- `POST /v1/runs/{run}/turns/{turn}/messages` → keyed message admission.
- `POST /v1/runs/{run}/permissions/{request}/decision` → keyed decision with descriptor digest and `allow_once | deny`.
- `POST /v1/runs/{run}/turns/{turn}/models/{operation}/interrupt` → keyed exact-operation interruption.
- `POST /v1/runs/{run}/cancel` → keyed durable Run cancellation.
- `GET /v1/runs/{run}/content/{ref}?offset={u64}&length={u64}` → immutable bytes scoped to the authenticated Principal.

Creation carries source, arguments, invocation Workspace and existing semantic bindings. Evaluator limits and semantics identity come from the established invocation contract; their presence in durable bindings does not create new user configuration knobs. Message admission binds immutable text. Admission acknowledges a committed semantic fact, not execution or model consumption. The evaluator’s keyed `agent()` admission, membership creation and initial User Message remain native-only. There is no HTTP route that bypasses workflow replay.

## Startup, discovery and authority

`onepage serve --store …` explicitly starts the owner. Clients canonicalize the same Store selector and derive the same socket path; ordinary commands need no endpoint argument. A proposed common resolver uses the real parent directory and final Store name, resolving an existing Store symlink before hashing the canonical path into a short, owner-only runtime-directory socket name. This requires explicit alias rules: hard-link Store aliases are rejected rather than treated as supported selectors. The Store lifetime lock remains authoritative; stale-socket cleanup occurs only after acquiring ownership. Socket presence and PID files never authorize recovery.

A client sends the canonical Store selector and supported wire version on every request. The server verifies these against its selected Store; after discovery, the client also supplies the returned persistent Store identity. A client with an already known Store identity checks it on first contact. Every response repeats identity/version. Discovery is an authenticated check, not a substitute for request authorization. Unsupported version or wrong Store fails before mutation.

Minimal proposed authentication policy: local OS peer credentials map the server owner UID to a configured Principal; other UIDs are denied unless explicitly configured. This is a new deployment-policy proposal, not an inferred domain rule. Socket permissions provide another gate. Neither caller-supplied Principal nor possession of a control grants authority. Every operation uses the existing Principal/User checks.

Stopping remains OS-signal administration, with prompt dispatch fencing and bounded effect-aware cleanup. No public stop route is added. Disconnect never cancels; restart recovers unfinished work under existing durable budgets. No auto-start or auto-retry occurs in the CLI.

## Exact ingress and admission

Use a bounded binary envelope for creation and messages, avoiding an upload resource:

```text
Content-Type: application/vnd.onepage.command-stream
<one bounded UTF-8 JSON header followed by LF>
<sourceBytes raw bytes, exactly N>
<argumentBytes raw bytes, exactly M>
<end of HTTP body>
```

For creation the header names `key`, bindings, and two ordered parts with decimal-string length and SHA-256 digest. For a message it names `key`, exact Run/Turn and one `text` part. The operation-specific schema determines part order; there is no generic arbitrary-part protocol. Digests are checked over actual raw bytes. The server streams into charged scratch, checks lengths, digests, encoding and domain validation, then seals before invoking the distinct native mutation. Unknown fields, missing/extra bytes and malformed arguments reject the request. Scratch admission can fail explicitly under current limits; no numeric cap is proposed here. No SQLite transaction remains open during transfer.

This custom framing is an admitted complexity cost of this candidate, not an accepted existing format. A standard multipart alternative could replace it without changing the affordance model.

Small decision/interrupt/cancel bodies use bounded JSON containing caller key and required exact bindings. Route/body target disagreement is invalid. The replay identity binds authenticated Principal, scope, semantic verb, targets and immutable content using the existing domain equivalence rule; wire formatting is not an extra semantic binding.

Each successful mutation returns its operation-specific receipt containing the original key, exact target and committed outcome. Concurrent identical submissions converge through existing native admission; conflicting bindings reject. There is no extra receipt journal. Losing a response after commit is possible: the CLI retains the caller-supplied key through the invocation and reports it on uncertainty; the caller preserves exact replay material without an automatic client request journal and reports `outcome_unknown`. An advertised control may disappear from later inspection, but its unchanged invocation remains replayable for the original key. The caller does not have to rediscover it to recover a lost acknowledgement.

## Inspection, content and stale controls

Inspection is newline-delimited JSON with this exact record discipline:

```json
{"type":"start","run":"…","revision":"…"}
{"type":"run","facts":{},"cancel":{"kind":"cancel_run","method":"POST","href":"…","run":"…"}}
{"type":"member","facts":{},"message":null,"interrupt":null}
{"type":"permission","facts":{},"decision":{"kind":"decide_permission","method":"POST","href":"…","run":"…","request":"…","descriptorDigest":"…"}}
{"type":"content","ref":"…","bytes":"…","digest":"…","read":{"href":"…"}}
{"type":"end","revision":"…","complete":true}
```

`facts` above abbreviates generated typed domain records, not free-form JSON. Large text appears only through immutable content references. The real stream includes every membership and actionable permission, without public pagination or caller-selected caps. The server privately scans bounded batches under the native revision guard, retaining neither a transaction nor a historical snapshot.

If invalidated, the last record is `{"type":"error","code":"inspection_changed","complete":false}` and no `end` follows. A truncation, invalid record, or missing valid end likewise means incomplete inspection. Clients must not describe the observed prefix as a complete current view. They may retain immutable references and facts as observations, but require explicit fresh inspection before relying on completeness. There is no automatic retry or hidden scheduler pause. A constantly changing Run can repeatedly prevent a complete scan; that liveness limitation is genuine.

Returned controls bind only exact semantic preconditions: permission descriptor digest, message Turn, or Model Operation. They never attach a whole-Run revision requirement. A stale message target can be rejected; an already-decided permission or finished operation fails the new-admission precondition unless the request is an exact replay of its existing key. A previously committed key is replayed before testing present applicability where the native contract requires that ordering. Controls cannot eliminate races.

Content reads first authorize the exact Run and immutable reference under existing Principal and disclosure rules, then return `application/octet-stream` with immutable reference, offset, total length and returned byte count in headers, with all integers represented as decimal strings. Out-of-range or unauthorized references fail before response bytes. A truncated body is detectable from declared byte count. The server streams fixed windows; the caller explicitly requests another range if needed. Content text cannot supply controls.

## Errors and a complete caller flow

Before streaming starts, failures use a closed JSON error type. Invalid input is HTTP 400; authentication/authority failures 401/403; absent accessible targets 404; binding conflict or inapplicable target 409; rejected content size 413; admission pressure or stopping 503. Responses identify the operation’s typed cause rather than promising every failure is unapplied. Post-header inspection errors use the stream error record. Broken or failed mutation replies remain uncertain unless a valid typed response establishes their disposition. CLI invocation failures exit nonzero; successful inspection of a failed Run exits zero.

```ts
const host = await discover(selectedStore); // explicit server already running
const create = encodeCreate(host.create, savedKey, localSource, localArgs, workspace);
// Save key and replay material before transmitting.
try { receipt = await send(create); }
catch { reportUnknown(savedKey); /* caller elects send(create) again */ }
const view = await inspectComplete(receipt.inspect); // one attempt, may invalidate
await decide(view.permissions[0].decision, decisionKey, "allow_once");
await message(view.members[0].message, messageKey, localText);
// Inspect again when selecting a currently active exact model target.
await interrupt(nextView.members[0].interrupt, interruptKey);
// Alternatively, durably withdraw the entire Run's intent:
await cancel(receipt.cancel, cancelKey);
const resultView = await inspectComplete(receipt.inspect);
await readRange(resultView.result.ref, "0", requestedBytes);
// Operator stops and explicitly restarts serve; clients reconnect explicitly.
// Cancelled work stays cancelled; unfinished work follows recovery rules.
```

Absent controls are represented explicitly; the caller cannot assume a message or interrupt is currently available. Result references remain opaque pending Session-continuation [Choose replay-stable Session continuation from agent results](https://github.com/DivyanshGolyan/onepage/issues/101). Terminal inspection preserves admitted/projected facts without claiming pending messages were consumed; terminal failure applicability remains [Choose terminal failure semantics for pending User Messages](https://github.com/DivyanshGolyan/onepage/issues/102).

## What this hides and the trade-off

The design hides path construction, target discovery, digest copying, workflow evaluation, recovery, storage and dispatch behind inspection plus typed operations. It adds no durable affordance state and changes none of the accepted lifecycle/retry constraints. New proposals are the peer mapping, selector alias policy and ingress encoding; they require selection, not silent adoption.

Its advantage is correct target selection for LLM callers: the permission record carries precisely the control that addresses it. Its weakness is that every response becomes larger, clients still need a closed set of typed encoders, and inspection becomes a perceived prerequisite even when a caller already knows an exact target. The control never guarantees freshness, so it can create false confidence unless the distinction is prominent. A thin CLI already hides most route construction. For OnePage, the strongest element may therefore be returning exact actionable identities and digests; advertising method/path templates everywhere may provide less value than its conceptual cost.
