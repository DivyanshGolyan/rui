# Candidate B: explicit resources and actions

> **Historical design exploration, published 6 September 2026.** The [normative architecture](../../../ARCHITECTURE.md) and [product contract](../../../PRODUCT.md) own the current design. Earlier signatures, issue ownership, status statements, and unselected alternatives below retain their original context; they are not a second current specification.

Selected interaction model. Inspection amended 5 September 2026 by [ADR-0024](../../adr/0024-capture-run-inspection-before-delivery.md); code and wire details remain to be implemented.

This proposal exposes distinct HTTP operations for OnePage’s domain operations. It borrows OpenCode V2’s typed resource routes, declared errors, and durable admission acknowledgements, without promising OpenCode compatibility. A generated contract describes each route independently. HTTP handlers call distinct native methods; neither a generic command ledger nor a generic native command union is introduced.

## Connection, identity, and authority

`onepage serve --store SELECTOR` acquires the Store’s lifetime lock before opening execution ownership or replacing a stale socket. Clients and server apply one canonical Store-selector algorithm: resolve filesystem aliases, canonicalize the containing directory before creation, and derive a short socket filename from that canonical locator beneath a private per-user runtime directory. The derived path has a checked platform-compatible length; an unavailable or insecure runtime directory is a startup error. Socket existence and PID files confer no ownership. Relocating a Store changes its locator; concurrently selecting aliases must resolve to the same lock and socket.

`GET /v1/host` returns `{wireVersion, storeId, canonicalLocatorDigest, readiness}`. Every subsequent request supplies `OnePage-Store` and `OnePage-Wire-Version`; the handler checks them against its actual Store before accessing targets. The handshake is discovery, not a permanent authorization or readiness grant. The CLI compares the locator digest to its selection before accepting the Store identity. A replaced Store produces an identity mismatch rather than operating on the old target.

Proposed minimal local policy: the socket directory permits only the configured owner, and an OS-verified peer UID maps to one configured Principal. Unsupported peer-credential validation fails startup; an unmapped peer is rejected. This is an explicit single-local-Principal deployment assumption, not a claim that filesystem access grants every domain permission. Request JSON cannot select a Principal. Existing action authority checks still apply to every target and immutable content reference. User Message author identity remains distinct from the connection Principal.

Stop remains local OS signaling to the `serve` process. There is no HTTP shutdown route. Stopping fences dispatch and performs bounded effect-aware cleanup; restarting explicitly recovers unfinished work. Disconnecting a client never cancels a Run.

## Typed operation surface

The following sketches omit established domain fields rather than redefine them. All IDs, revisions, byte offsets, lengths, and unsigned counters are JSON strings. Each named receipt contains only its native committed semantic fact and target identities; an admission response is not completion.

```ts
type Key = string;
type ContentPart = {
  name: string; mediaType: string; byteLength: string; sha256: string;
};
type RunInput = {
  runKey: Key;
  workspace: InvocationWorkspace;
  source: ContentPart;
  arguments: ContentPart;
  // Existing caller-owned semantics inputs, where applicable.
};

POST /v1/runs
  RunInput + source bytes + argument bytes -> RunAdmission
POST /v1/runs/{run}/turns/{turn}/messages
  {messageKey: Key, text: ContentPart} + text bytes -> MessageAdmission
POST /v1/runs/{run}/permissions/{request}/decisions
  {decisionKey: Key, descriptorDigest: string,
   decision: "allow_once" | "deny"} -> PermissionDecisionReceipt
POST /v1/runs/{run}/turns/{turn}/model-operations/{operation}/interruptions
  {interruptionKey: Key} -> ModelInterruptionReceipt
POST /v1/runs/{run}/cancellations
  {cancellationKey: Key} -> RunCancellationReceipt
GET /v1/runs/{run}
  -> RunInspectionStream
GET /v1/runs/{run}/content/{immutableRef}?offset={decimal}&length={decimal}
  -> application/octet-stream
```

The descriptive nouns in action paths do not create independent CRUD resources. There are no list/delete routes for decisions or interruptions. Workflow creation and reattachment share the keyed submission operation; an uncertain create is resolved by repeating that exact submission. No key-lookup journal is needed.

The server binds configured evaluator limits and runtime-owned semantics identity under the established admission contract. They are not newly exposed client knobs. Agent-call admission, including initial User Message and membership creation, remains native-only and callable by the server-owned Workflow Evaluator. No Session-start HTTP shortcut bypasses keyed workflow replay. Session continuation result shape remains dependent on [Choose replay-stable Session continuation from agent results](https://github.com/DivyanshGolyan/onepage/issues/101); the interface carries committed result references without selecting a new envelope.

One authoritative closed wire-type definition generates request validation, response encoding, error declarations, and OpenAPI documentation. Stream item schemas and multipart ordering are included in generated documentation. Generated route descriptions are build artifacts, not a new discovery service.

## Exact ingress and acknowledgement

Small decision/interruption/cancellation requests use bounded `application/json`. Source, arguments, and message text use `multipart/form-data` with this exact part order:

1. `metadata`: one bounded JSON object with the appropriate typed input and declarations for subsequent parts.
2. Declared content parts, in declaration order, with matching part names and media types.
3. Final multipart closing boundary and HTTP message termination; no additional parts or bytes.

For Run admission, the fixed names are `source` and `arguments`; for messages, `text`. The client reads local files and streams their bytes. The server never treats a client pathname as content. Digests and decimal lengths are checked against received bytes. Multipart boundaries and transport headers are excluded from semantic replay binding. Canonical semantic fields and sealed content identities enter the existing native equivalence rules; source bytes remain exact. Arguments retain the existing argument-equivalence rule rather than adopting accidental multipart or JSON formatting equivalence.

The receiver streams into charged private scratch with reusable bounded parsing buffers. It validates all content, seals it, and only then invokes the native mutation. Truncation, digest mismatch, surplus parts, or invalid content before that invocation cannot admit the command. Scratch is reclaimed; there is no public staged-upload identifier. No SQLite transaction remains open during upload. Configured bounds can reject the request without introducing new numerical product limits here.

A first committed admission returns HTTP `201`; identical replay returns `200`, with the same typed semantic receipt, not current mutable Run state. Concurrent identical requests converge on that native fact. Reusing a key with different Principal scope, verb, targets, descriptor, or content yields `409 key_conflict`, according to that operation’s existing key scope. After authenticating and checking access, matching replay resolves the original committed fact before applying current-state admission preconditions. It therefore still succeeds when the Run or Turn has since become terminal; active-target checks apply only to a new admission. No whole-Run revision precondition is added to exact-target actions.

The caller supplies the original key before sending. The CLI retains it through the invocation and echoes it on uncertainty; the caller preserves the exact input needed for replay. No automatic client-side request journal is introduced. Losing or failing to decode the acknowledgement produces `outcome_unknown` with that key. The CLI does not generate another key or retry automatically. Even a server error can follow commit; absence of a complete admission receipt is not evidence of nonapplication.

## Inspection and immutable bytes

`GET /v1/runs/{run}` returns `application/x-ndjson`, with bounded records in this grammar:

```json
{"type":"start","runId":"r1","revision":"42"}
{"type":"run","value":{"status":"running"}}
{"type":"membership","value":{"turnId":"t1","sessionId":"s1"}}
{"type":"permission","value":{"requestId":"p1","descriptorDigest":"...","descriptorRef":"c1"}}
{"type":"result","value":{"contentRef":"c2"}}
{"type":"end","revision":"42","recordCount":"4"}
```

The generated schema defines every actual fact variant, including exact interruptible Model Operation identities and message admission/projection facts. Large text and descriptors are immutable references, never arbitrarily large inline records. The stream covers every membership and actionable permission; it has no public cursor or caller-selected truncation limit.

The Storage Owner captures the revision and complete report facts under one read transaction on its existing connection, using bounded private batches and charged immediately unlinked scratch. Other database admissions and settlements wait during capture. Active statements and the transaction end before report delivery, so later mutation does not invalidate the report and slow clients retain no database resources. Capture failure returns an error before report delivery. A missing `end`, malformed record, mismatched revision/count, or failed transfer makes delivery incomplete; a prefix is never a complete permission inventory. The CLI marks incomplete delivery unsuccessful. The Host reuses one capture workspace serially and reclaims each report's scratch on completion, failure, or abandonment. Issues #68 and #95 own capture work, aggregate scratch, delivery populations, fairness, and memory budgets; numerical batch sizes and collection caps are not selected here.

Content reads authorize the Run and immutable reference against the Principal and existing content-disclosure rules, validate offset and length, then return exactly that byte window with declared length and content identity. An invalid window is a typed client error; missing or unauthorized references follow the domain’s disclosure policy. The same reference cannot later serve different bytes. A truncated body is an incomplete read; the caller can explicitly request the remaining window. The server copies fixed-size windows without materializing the whole content. A successful inspection of a failed Run is still HTTP success and CLI exit zero. [Choose terminal failure semantics for pending User Messages](https://github.com/DivyanshGolyan/onepage/issues/102) continues to own applicability of admitted but unprojected messages on terminal failure.

## Failures and caller flow

Pre-response failures use a closed JSON error object `{code, message, application}` with `application: "not_applied" | "unknown"`. Only a proven pre-admission rejection may claim `not_applied`. HTTP `400` covers invalid shape/framing, `403` authority, `404` permitted absence, `409` identity/version/key/target conflict with distinct codes, `413` configured size rejection, `503` temporary admission capacity or stopping, and `500` infrastructure failure. Post-header inspection failures use its terminal error record. Overload never implies an automatic retry. Client timeout/disconnect reports uncertainty for mutations and incompleteness for reads. CLI protocol, authority, infrastructure, and rendering failures are nonzero; workflow outcomes are data.

A script’s complete flow is:

```text
start serve explicitly; resolve socket; GET /v1/host and verify identity
persist runKey K and source/arguments
POST /v1/runs with K and streamed parts
if reply lost: report unknown; caller repeats exactly K and the same inputs
GET /v1/runs/R; require a valid end record
POST /v1/runs/R/permissions/P/decisions with key D and inspected digest
POST /v1/runs/R/turns/T/messages with key M and streamed text
POST .../model-operations/O/interruptions with key I, if desired
or POST /v1/runs/R/cancellations with key C
inspect; GET /v1/runs/R/content/REF?offset=0&length=N for committed output
stop serve by signal; start serve explicitly; inspect R again
```

## What this hides and costs

Callers do not implement SQLite custody, evaluator replay, dispatch recovery, scratch charging, or internal Attempts. Each route carries a precise domain obligation and independently generated input type. Resource nesting makes target identity visible, while typed conflicts make stale permission or operation choices actionable.

The cost is a larger route vocabulary and repeated path construction. HTTP conventions reduce client invention but cannot hide OnePage’s essential exact-target distinctions. Multipart ingress and complete inspection capture remain the hardest contracts; resource-oriented routing does not simplify those away. The accepted inspection amendment replaces revision invalidation with capture before delivery. Remaining decisions are peer-Principal deployment policy and concrete canonical discovery mechanics, plus the separately owned Session-result and terminal-message semantics.
