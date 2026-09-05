# Candidate A: three HTTP entry points, closed command and read variants

> **Historical design exploration, published 6 September 2026.** The [normative architecture](../../../ARCHITECTURE.md) and [product contract](../../../PRODUCT.md) own the current design. Earlier signatures, issue ownership, status statements, and unselected alternatives below retain their original context; they are not a second current specification.

This proposal optimizes the number of entry points. It does **not** reduce the number of domain operations. The external adapter dispatches a closed wire variant to an existing distinct native method; there is no native `execute(Command)` interface, JSON-RPC envelope, generic interaction, or new receipt journal. This is an exploration, not an approved contract.

## Signature and ownership

```ts
// All IDs, keys, digests, revisions, lengths, offsets and counts are strings.
GET  /v1/host
POST /v1/command
POST /v1/read

type Command =
  | { kind: 'run.submit'; key: Key; workspace: Workspace;
      source: Part; arguments: Part; /* existing public invocation options */ }
  | { kind: 'message.admit'; key: Key; run: RunId; turn: TurnId; text: Part }
  | { kind: 'permission.decide'; key: Key; run: RunId;
      request: PermissionRequestId; descriptorDigest: Digest;
      decision: 'allow_once' | 'deny' }
  | { kind: 'model.interrupt'; key: Key; run: RunId;
      turn: TurnId; operation: ModelOperationId }
  | { kind: 'run.cancel'; key: Key; run: RunId };

type Read =
  | { kind: 'run.inspect'; run: RunId }
  | { kind: 'content.read'; run: RunId; ref: ContentRef;
      offset: Decimal; length: Decimal };

type Part = { name: string; length: Decimal; sha256: Digest;
              mediaType: string; schema?: SchemaIdentity };
```

`run.submit` creates or reattaches the Run. Existing public invocation inputs select the semantics identity and evaluator limits under the current configuration contract; the wire specification must enumerate those existing inputs without exposing additional stored settings as knobs. Admission binds the resolved contract durably. Reattachment uses that binding, not freshly interpreted runtime defaults. Source and arguments are uploaded bytes, never server-opened client file paths. Workspace is the existing invocation Workspace identity/path with its existing access validation; this is not a general file-read capability.

The server-owned Workflow Evaluator alone invokes native agent-call admission, including keyed membership, initial User Message, Session continuation and revisions. There is deliberately no HTTP “start agent” route bypassing workflow replay. Attempt and Completion machinery remain internal.

## Startup, discovery and authority

`onepage serve --store PATH` starts the owner explicitly. The CLI and server canonicalize the selected Store directory using the same filesystem rule before deriving a Unix socket filename from its full SHA-256 selector digest. Use a fixed, private, per-OS user runtime directory, not whichever working directory or temporary directory a caller happens to inherit. Validate directory ownership and restrictive permissions and reject platforms/configurations whose resulting socket path exceeds the platform limit. Resolve directory symlinks consistently; diagnose an unavailable/unresolvable selector rather than guessing another Store. This proposal requires an existing selected directory; a missing parent is an explicit startup error, not an assumed setup API.

The exclusive lifetime Store lock determines ownership. Only its holder may replace a stale socket at the derived location. A contender reports `owner_exists` without unlinking anything. A missing socket reports `server_unavailable` and never starts a process. Canonical path replacement or Store movement is not transparent identity continuity.

`GET /v1/host` returns bounded `{wireVersion, storeId, selectorDigest, principalId, readiness}`. The CLI validates the selected selector, supported wire version and Store identity. Every subsequent request includes `OnePage-Store` and `OnePage-Wire-Version`; the server validates these for the actual request, not just the initial probe. Reconnecting repeats discovery. A caller that already knows a Store ID rejects replacement rather than silently binding its existing Run keys to another Store.

Minimal **new policy proposal**: the configured local owner's OS peer UID maps to one configured Principal. Other UIDs are rejected. Filesystem access is a connection gate, not authority; the mapped Principal still needs each existing Run/action grant. Request bodies cannot nominate a Principal, and User Message role does not supply authority. Independent authority for multiple agents sharing one OS account is not delivered by this mapping and would require a separate decision. Health is authenticated too.

Administration remains OS signals to the explicitly launched process: no stop route. Shutdown fences dispatch and performs bounded effect-aware interruption/cleanup without recording Run cancellation. Restart recovers unfinished work using remaining durable budgets. Socket disconnect is merely detachment.

## Exact ingress and binding

Every command uses `multipart/form-data`, including commands with no payload parts. The **first** part is `meta`, `Content-Type: application/json`, containing exactly one closed `Command` variant. Following parts contain exactly the named payloads, in declared order, with matching media types; no filenames carry authority. For example:

```text
--BOUNDARY\r\n
Content-Disposition: form-data; name="meta"\r\n
Content-Type: application/json\r\n\r\n
{"kind":"message.admit","key":"m7","run":"r1","turn":"t4","text":{"name":"text","length":"5","sha256":"<digest>","mediaType":"text/plain"}}\r\n
--BOUNDARY\r\n
Content-Disposition: form-data; name="text"\r\n
Content-Type: text/plain\r\n\r\n
hello\r\n
--BOUNDARY--\r\n
```

The parser streams payloads into charged scratch, computes lengths/digests, and rejects missing, additional, reordered, malformed or mismatched parts. Metadata and framing use the separately decided command-work limits; no product cap is invented here. Payloads are validated and sealed before the native mutation; no SQLite transaction spans upload. Truncation, budget exhaustion or disconnect before sealing imports no semantic mutation and releases scratch. A client unable to prove that admission was never reached still reports uncertainty.

Semantic binding includes authenticated Principal, existing key scope, verb, exact targets, decision fields, and validated content identity/bytes under the existing contract. Multipart boundary, JSON property order, transport headers and connection identity are not semantic inputs. The closed schema owns normalization; it cannot silently normalize source or message bytes. Concurrent identical submissions serialize through existing domain uniqueness/transactions and receive the same committed fact. Authenticate and resolve the existing key binding before applying new-admission current-state preconditions: exact replay still recovers its committed receipt after the Run or Turn becomes terminal. Changed binding conflicts. There is no global cross-verb key namespace unless already required by the native method.

Success is HTTP 200 with a bounded operation-specific receipt:

```ts
{ kind:'run.submitted', key, run, invocationContractRef }
{ kind:'message.admitted', key, run, turn, message }
{ kind:'permission.decided', key, run, request, decisionId, decision }
{ kind:'model.interruption_recorded', key, run, turn, operation }
{ kind:'run.cancellation_recorded', key, run }
```

These acknowledge committed facts, not workflow completion or message consumption. Identical replay returns the same semantic receipt; no “replay count” or new execution is implied. Losing a create receipt is recovered by explicitly repeating the same keyed submission; no command lookup ledger is added. CLI preserves its key before sending, prints it on uncertainty, and never retries automatically.

## Exact reads and scan completeness

`POST /v1/read` takes bounded JSON. `run.inspect` returns `application/x-ndjson`. Each line is one bounded object; variable text or recursive values are immutable content references. A complete stream has this grammar:

```text
{"type":"start","run":"r1","revision":"29","schema":"run-scan-v1"}
{"type":"item","seq":"0","kind":"run","value":{...bounded run facts...}}
{"type":"item","seq":"1","kind":"membership","value":{...exact membership/turn/session identities...}}
{"type":"item","seq":"2","kind":"permission","value":{...request,descriptorDigest,operation,content refs...}}
{"type":"item","seq":"3","kind":"message","value":{...committed admission/projection facts...}}
{"type":"end","revision":"29","items":"4"}
```

The closed item variants cover the complete native current-state model, including every membership, all actionable permissions, exact model-operation targets, terminal facts and result refs. They do not introduce public Attempt controls. A scan invalidated while transmitting ends instead with:

```text
{"type":"error","code":"scan_invalidated","complete":false}
```

There is **exactly one** terminal `end` or `error`; EOF without it is incomplete. The server performs a final revision check before `end`. Each native next-item query is short, using a private bounded continuation; no public cursor, retained snapshot transaction or scheduler pause. Clients accept completeness only after `end`, and must not act on provisional items as a complete observation. A concurrent mutation can invalidate immediately after a completed scan; exact action-target checks remain necessary.

The CLI can spool JSON records to bounded-memory disk before rendering a complete result. It reports invalidation and lets the caller retry explicitly. Busy Runs can repeatedly invalidate scans: this is a real liveness limitation, not hidden by an infinite retry loop.

`content.read` authorizes the Run and immutable ref against the Principal and the existing content-disclosure rules and returns binary bytes with `Content-Length`, `OnePage-Content-Ref`, `OnePage-Offset`, and `OnePage-Total-Length`. The returned window is the requested range clipped at EOF. Offset beyond EOF is a typed 416 rejection; an empty EOF window is valid. Reads stream fixed internal windows, independently of requested length. A short/truncated body fails; the client may explicitly request another immutable range. No public content publication or collection pagination is added.

## Errors and caller flow

Pre-stream errors use `{error:{code,detail}, disposition:'not_applied'}` only where the server knows no mutation committed: 400 malformed, 401/403 identity/authority, 404 unavailable target/content under disclosure policy, 409 changed binding/stale exact target/wrong Store, 413 admission budget exceeded, 426 wire mismatch, and 503 capacity rejection. Errors after commit must never claim `not_applied`. A timeout, broken connection, malformed reply or unclassified 5xx yields CLI `outcome_unknown` plus original key for mutations. Read failures yield incomplete/failed inspection, not mutation uncertainty. A valid inspection reporting a failed Workflow exits successfully; protocol, infrastructure, authority and rendering failures exit nonzero. Midstream errors use the terminal scan error record because HTTP status is already sent.

Typical caller pseudocode:

```text
serve(selectedStore)                       // independently supervised by caller
host = authenticateAndCheck(discover(selectedStore))
command(run.submit(key="r-key", source, args))
// Lost reply: retain r-key, choose to resend exact input explicitly.
run = command(sameSubmission).run
scan = read(run.inspect(run)); requireComplete(scan)
command(permission.decide(key="p1", exact request + digest, allow_once))
command(message.admit(key="m1", run, exact active turn, text))
command(model.interrupt(key="i1", run, exact turn + model operation))
// Or choose durable abandonment:
command(run.cancel(key="c1", run))
read(content.read(run, committedResultRef, offset="0", length=desiredLength))
// After process stop/crash: explicitly serve again; inspect the same run.
```

The CLI hides multipart framing, discovery and validation; ordinary HTTP libraries can implement the same flow. It never interprets model/tool text as authority.

## Depth and trade-offs

Three entry points conceal ownership, content import, native scans and domain transaction machinery. One generated closed wire schema can drive decoding, documentation and CLI bindings. However, this design concentrates a substantial tagged vocabulary behind two POST routes. Route count understates learning cost, HTTP logs need decoded variant names, and read POSTs sacrifice conventional GET ergonomics. Uniform multipart commands are predictable but awkward for hand-written curl commands without payloads. The external dispatcher is the explicit tension with the preference for distinct typed methods; keeping it only in the adapter is essential.

Unowned gaps are the proposed peer-UID mapping and platform discovery details. Session continuation result shape remains [Choose replay-stable Session continuation from agent results](https://github.com/DivyanshGolyan/onepage/issues/101); committed result refs remain opaque here. Pending-message applicability on terminal failure remains [Choose terminal failure semantics for pending User Messages](https://github.com/DivyanshGolyan/onepage/issues/102); receipts and scans must not invent consumption or a new lifecycle. This design adds no resolution to either decision.
