# Client-server interface: three designs

> **Historical design exploration, published 6 September 2026.** The [normative architecture](../../../ARCHITECTURE.md) and [product contract](../../../PRODUCT.md) own the current design. Earlier signatures, issue ownership, status statements, and unselected alternatives below retain their original context; they are not a second current specification.

Status: interaction model selected by the user, 5 September 2026. Candidate B
with the proposed simplifications below is selected: explicit resource operations
and exact actionable facts in inspection, without advertised action templates.
Inspection was subsequently accepted as capture on the existing connection, followed by delivery; see [ADR-0024](../../adr/0024-capture-run-inspection-before-delivery.md). Candidate A and C files preserve the original alternatives.
No interface is implemented. Signatures and examples remain design notation, not a compiled schema.
The exact wire contract must ultimately come from compiled public types and
golden fixtures.

This comparison covers the full local client-server seam: server lifecycle and
discovery, identity and authority, every public admission, large input transfer,
acknowledgements and replay, current-state inspection, immutable content reads,
errors, overload, and CLI behavior. It excludes provider OAuth/transport internals
and the server-internal evaluator bridge.

## Requirements held constant

The callers are coding agents using the CLI or scripts. They submit workflows,
observe committed facts, and exercise exact controls. The server owns execution
and recovery even when no client is connected. See the accepted
[ownership contract](https://github.com/DivyanshGolyan/onepage/issues/100#issuecomment-5549173568)
and the owning
[Run interface work](https://github.com/DivyanshGolyan/onepage/issues/39).

Every candidate preserves explicit `serve`, a Store-derived Unix socket, one
Store owner, no client auto-start, no automatic mutation retry, prompt server
stop, existing effect-specific recovery and durable budgets. Run cancellation
and exact-Operation interruption stay distinct. HTTP does not expose `advance`,
Attempt settlement, or evaluator admission.

All public IDs, revisions and byte quantities use strings. Variable content is
streamed or referenced, never multiplied into resident per-client objects. All
inspection collections are complete or explicitly incomplete: no public cursor,
silent truncation, or implicit change to execution intent. Database work waits
during the accepted capture operation, then resumes before delivery. Controls validate the current
exact target; inspection itself cannot guarantee that a target remains current.

## A — a compact command port

[Complete Candidate A](a-command-port.md)

```text
GET  /v1/host
POST /v1/command  Command -> committed typed receipt
POST /v1/read     Read -> inspection records or immutable bytes

Command = submitRun | admitMessage | decidePermission
        | interruptModel | cancelRun
Read    = inspectRun | readContent
```

A caller learns three entry points and a closed vocabulary of commands. All
commands use multipart, with a small typed metadata part followed by any content
parts. The HTTP adapter selects a distinct native method; there is no generic
native dispatcher or new request ledger.

```text
command(submitRun(key=K, source, arguments, workspace)) -> run R
read(inspectRun(R)) -> complete inspection
command(decidePermission(key=D, run=R, request=P, digest=H, allow_once))
```

It hides route construction and consolidates framing. It still exposes every
semantic distinction through tagged values. Reading logs or generating clients
requires understanding those values; ordinary reads become POSTs, and a small
cancellation still needs multipart. It concentrates complexity rather than
removing it.

## B — explicit resource operations

[Complete Candidate B](b-resource-operations.md)

```text
GET  /v1/host
POST /v1/runs
GET  /v1/runs/{run}
POST /v1/runs/{run}/turns/{turn}/messages
POST /v1/runs/{run}/permissions/{request}/decisions
POST /v1/runs/{run}/turns/{turn}/model-operations/{operation}/interruptions
POST /v1/runs/{run}/cancellations
GET  /v1/runs/{run}/content/{ref}?offset=…&length=…
```

Each operation has its own closed input and output type. Commands with source,
arguments or message text use multipart; small controls use JSON. The plural
action nouns do not introduce collection CRUD or independent lifecycle objects.

```text
POST /v1/runs + key K, source, arguments, workspace -> run R
GET  /v1/runs/R -> complete inspection
POST /v1/runs/R/permissions/P/decisions
     { decisionKey: D, descriptorDigest: H, decision: allow_once }
```

This design hides storage, dispatch, workflow replay and recovery behind precise
operations. Route construction remains visible to direct scripts, but the CLI
can hide it. The protocol can describe each operation without a general command
interpreter. It follows selected OpenCode conventions while preserving OnePage's
own resources and semantics.

## C — inspect and use advertised controls

[Complete Candidate C](c-advertised-controls.md)

```ts
type PermissionControl = {
  kind: "decide_permission";
  method: "POST";
  href: string; // relative path on the selected Unix socket only
  run: RunId;
  request: PermissionRequestId;
  descriptorDigest: Digest;
};

discover() -> creation control
inspect(run) -> facts with typed message/permission/interrupt/cancel controls
decide(control, callerKey, "allow_once" | "deny") -> committed receipt
```

The topology remains resource-based, but the caller's interaction is different:
select a returned control and supply only the caller-owned fields. It need not
construct the target path or copy a digest into a separately chosen target.

```text
view = inspectComplete(R)
control = view.permissions[P].decision
decide(control, key=D, allow_once)
```

It hides target assembly and can reduce mistakes in direct agent-written scripts.
Controls are neither authority nor executable instructions. They are generated
from committed facts, may become stale immediately, and still require the same
server checks. No nonce, capability store, expiry state or generic form system
is added. The cost is repeated method/path metadata and typed control-handling
code; the CLI already hides much of that work.

Candidate C also explores a custom length-delimited content envelope. That is
an independent framing proposal, not necessary to its interaction model.

## Comparison

**Interface simplicity.** A has the fewest entry points, but the caller must
still learn five mutations, two reads and their exact bindings. B names those
distinctions directly. C reduces target assembly but adds another kind of object
to understand. Counting endpoints alone favors A incorrectly; counting the
facts a caller must supply favors B or C.

**Flexibility and focus.** B composes naturally for both fixed scripts and the
CLI: a caller that already knows a target need not inspect first. C is strongest
when an unfamiliar agent repeatedly discovers what it can do next. A provides
a uniform dispatch surface but does not earn an open-ended command vocabulary:
the schema remains closed in every version. None should acquire unrelated
features just because its shape could accommodate them.

**Implementation efficiency.** All three permit bounded streaming and short
SQLite transactions. A's uniform multipart shape adds parsing even to small
controls. B can use a small JSON path for those controls. C adds bounded metadata
per inspection item; it must not materialize the full inventory. Its custom
framing creates additional parsing obligations without changing ownership.
These are consequences of interface shape, not estimates of developer effort.

**Depth.** The main depth comes from OnePage hiding execution ownership, keyed
admission, storage, crash recovery, content handling and workflow evaluation.
All candidates offer that. C adds real depth only if supplying controls saves
callers recurring work; otherwise it is an extra representation of routes and
targets that were already known. A's low route count does not itself create
depth.

**Correct use and misuse.** B exposes scope in its route and exact input type.
C helps pair a permission request with the correct digest, but a returned control
can misleadingly look like permission or a freshness guarantee. A allows the
same exact checks but makes the variant encoder responsible for them. In all
three, exact replay resolves a committed command before new-admission terminal
or applicability checks; otherwise lost acknowledgements become unrecoverable
after the target advances.

## Proposed synthesis

Recommend B, with complete exact target facts in inspection. Use C's useful
property—permission identity beside its digest, exact Turn/Operation identities
beside their status—without adding advertised HTTP controls or an action DSL.
Those identities are already needed for truthful inspection.

Use standard multipart for commands carrying large content, and small JSON for
permission, interruption and cancellation. The multipart convention has a
standard part/boundary grammar; OnePage still defines its small fixed part order
and semantic validation. See [RFC 7578](https://www.rfc-editor.org/rfc/rfc7578.html).
Do not adopt C's custom binary envelope merely to save one existing framing
mechanism.

The following refinements would simplify the selected B design further. They
are proposals, not a frozen protocol:

- Use one consistently named caller `key` field within each operation's existing
  scope. The operation-specific type still distinguishes Run, message and
  control keys. Never introduce a global cross-verb key namespace.
- Return HTTP 200 for both first admission and exact replay with the same stable
  semantic receipt. Distinguishing 201 from 200 adds a caller branch with no
  necessary behavior here. This differs from B's original status-code sketch.
- Use the `/v1` path as the protocol version; a duplicate version header need
  not become another independently negotiable setting. Retain intended-Store
  validation on every request and validate the response's selected wire shape.
- Keep the caller responsible for its original key and replay inputs. The CLI
  retains and reports that supplied key; it needs no automatic local request
  journal. A changed source file on retry must conflict rather than silently
  change an existing Run.
- Receipts describe recorded intent or admission. A cancellation receipt must
  not claim all subprocesses have already stopped; a message receipt must not
  claim the model has consumed it. Do not expose Completion/Resolution handles
  solely to manufacture a receipt.

Illustrative operation-specific receipts:

```ts
RunAdmission = { key, runId }
MessageAdmission = { key, runId, turnId, userMessageId }
PermissionDecisionReceipt = { key, runId, requestId, decision }
ModelInterruptionReceipt = { key, runId, turnId, operationId, recorded: true }
RunCancellationReceipt = { key, runId, intent: "recorded" }
```

They are views of existing immutable semantic facts. No second receipt table is
required, and exact replay does not substitute current mutable status.

## Cross-cutting contracts that must survive selection

**Lifecycle and discovery.** Each candidate supplies a proposed canonical Store
selector and a short socket path beneath a private per-user runtime root. The
CLI and server must use the same rule. Existing-file aliases and creation paths
must converge, or unsupported cases must be rejected explicitly. Lifetime Store
ownership precedes stale-socket cleanup. Startup should report the actual socket
location for direct scripts; no additional HTTP discovery service is necessary.
An authenticated host inspection returns Store identity and readiness. A known
Store identity must survive reconnection checks; new readiness does not grant
authority to mutate. Stop stays with OS signals to the explicit `serve` process.

**Authority.** All designs propose OS-verified peer identity mapped to a configured
local Principal; socket access alone grants no semantic authority. This is still
a deployment-policy proposal. It does not distinguish two agents sharing one OS
account as independent Principals. Selecting an interface must not silently
promise that isolation. Client-supplied Principal identifiers cannot be trusted.

**Ingress.** Fixed multipart metadata and declared content parts are streamed to
charged scratch, validated and sealed before native admission. The candidate
manifests include byte lengths and digests so mismatched content fails before
mutation. A final design must specify whether those values are caller-required
or server-derived; do not introduce a second content representation to support
them. Client filenames are read by the client; server-side arbitrary file opens
are not an upload protocol. An incomplete request creates no semantic reference.

**Replay and unknown outcomes.** Authenticate and check access, then use the
existing key and canonical binding. Exact prior admission remains replayable
after target terminality; new admission uses present preconditions. A transport
failure after possible submission is unknown, not rejected or cancelled.
Structured proven pre-admission rejection can say it was not applied. No blanket
5xx/timeout classification may claim that. Neither the CLI nor a generated
client should silently retry mutations.

**Inspection.** The accepted report uses finite typed NDJSON records: start,
bounded facts, then end. A valid end is mandatory; EOF alone is not success.
The Storage Owner captures the revision and complete facts under one read
transaction on its existing connection, through bounded private batches into
charged unlinked scratch. Other database work waits during capture. Active
statements and the transaction end before delivery; subsequent execution cannot
invalidate the captured report. Large values remain immutable references.
Capture failures are returned before report delivery; a truncated or failed
transfer remains incomplete. No prefix is a complete inventory. One capture
workspace is reused serially; completed reports for slow clients have separate
scratch and delivery budgets. Resource exhaustion, cleanup, fairness, and actual
whole-Host command delay remain explicit implementation checks under #68/#95.
This adds no second reader, WAL requirement, public cursor, or collection cap.

**Content.** Reads retain both Run and Principal scope and the existing disclosure
rules, including provider-private content exclusions. They return immutable byte
windows with declared returned length so truncation is detectable. The candidates
differ on clipping at EOF versus rejecting an overlong range; pick one documented
rule, not client-dependent behavior. This does not introduce paginated inspection.

**Errors and resources.** Keep machine codes for invalid request, wrong Store,
unsupported wire version, unauthorized target, absent target, key conflict,
inapplicable target, admission pressure, incomplete inspection and infrastructure
uncertainty. Exact numeric HTTP/CLI codes are part of the final generated contract;
the candidate sketches are alternatives. A failed Workflow is successful data
retrieval, not a CLI invocation failure. Connection admission, buffers, staging,
timeouts and overload behavior remain with the existing
[Host budget decision](https://github.com/DivyanshGolyan/onepage/issues/68).

## Selection and remaining boundaries

The complete candidate documents give signatures, usage, hidden implementation
and tradeoffs for every listed contract. The review has not compiled schemas,
implemented endpoints, run interoperability tests or changed GitHub decisions.
Candidate-specific headers, URI spelling, framing, error codes and auth policies
are deliberately distinguishable from previously accepted lifecycle semantics.

Two existing domain decisions remain outside this selection:

- [Choose replay-stable Session continuation from agent results](https://github.com/DivyanshGolyan/onepage/issues/101): the result reference/envelope cannot be invented by an HTTP adapter.
- [Choose terminal failure semantics for pending User Messages](https://github.com/DivyanshGolyan/onepage/issues/102): admission and projection facts must remain truthful while the applicability rule is settled.

OpenCode contributes concrete examples of typed operations, generated OpenAPI,
admission acknowledgements and replay checks. Its exact Session interruption,
scheduling controls and client compatibility are not inherited. See the
[pinned source comparison](../../research/opencode-v2-client-contract.md).

The user selected explicit operations, retaining exact actionable facts and
omitting another control-description layer. Candidates A and C remain comparison
evidence. This selection does not freeze all URI spellings, error codes, ingress
metadata requirements, range-edge behavior, discovery mechanics, or the proposed
peer-to-Principal policy; those details remain visibly separate from the selected
interaction model and the previously accepted lifecycle contract.
