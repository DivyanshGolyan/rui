# Option B: submit and observe through a compact shell interface

> **Historical design exploration, published 6 September 2026.** The [normative architecture](../../../ARCHITECTURE.md) and [product contract](../../../PRODUCT.md) own the current design. Earlier signatures, issue ownership, status statements, and unselected alternatives below retain their original context; they are not a second current specification.

> Historical alternative: subsequent user decisions removed all direct-call idempotency keys and chose Session-addressed ordinary messaging. See the [revised proposal](../direct-session-cli.md). These examples are not the current recommendation.

Proposal only. This makes the common shell invocation short while preserving the separation between durable admission and later execution. It does not select failure semantics for pending User Messages in issue 102.

## Interface shape

```text
onepage submit --key KEY --request REQUEST.json [--wait SECONDS]
onepage inspect --turn TURN_ID [--wait SECONDS]
onepage content --ref CONTENT_ID [--offset N --limit N]
```

`submit` starts one new Turn, either in a new Session or at an exact existing Session frontier. It never steers an active Turn or implicitly queues work. Permissions and cancellation retain their own explicitly typed commands; the three commands above are the common conversation path, not a claim that the whole runtime has only three verbs.

A request omitting `session` atomically creates the Session, baseline context, initiating User Message, and first Turn:

```json
{
  "workspace": "/work/project",
  "task": "Review the retry implementation.",
  "context": {"model": "configured-model", "instructions": "Be concise."},
  "permission_mode": "ask"
}
```

A continuation request supplies the exact durable Session reference, not a mutable 'latest session' alias:

```json
{
  "session": {
    "id": "ses_17",
    "expected_conversation_revision": "42",
    "expected_context_revision": "1"
  },
  "task": "Implement the second recommendation.",
  "permission_mode": "ask"
}
```

These are illustrative spellings, not an adopted wire schema. Existing task/input/schema and Turn override semantics should be reused rather than replaced by a second prompt language.

`submit --wait` is a CLI convenience over two distinct native operations: durable Turn admission, then read-only bounded observation. It is not a server command that holds a write transaction while the model runs. HTTP admission returns its immutable semantic receipt immediately; the CLI may subsequently make the bounded observation call. No generic command ledger or native command union is needed.

## Response shape: immutable admission plus optional observation

A successful submission yields metadata separately from model output:

```json
{
  "admission": {
    "key": "review-2026-09-05",
    "session_id": "ses_17",
    "turn_id": "turn_51"
  },
  "observation": {
    "condition": "completed",
    "outcome": {
      "kind": "completed",
      "answer": {"content_ref": "content_63", "format": "text"},
      "session": {
        "id": "ses_17",
        "expected_conversation_revision": "42",
        "expected_context_revision": "1"
      }
    }
  }
}
```

The admission block means exactly that the accepted request committed. It is identical on same-key replay; it is not an execution outcome. Observation may be absent, nonterminal, or terminal and may differ between successive reads. Do not persist the combined envelope as a receipt or promise replay of its whole byte representation.

An accepted submission whose optional observation fails still returns its admission block and a typed `observation_error`; it must not downgrade known admission to `outcome_unknown`. If admission itself never arrives intact, the CLI reports `outcome_unknown` with the original key. Process death before any envelope reaches the caller is handled by the same explicit-key recovery below.

`inspect` returns the same observation type with Session and Turn identities, but it does not invent an admission field. This small asymmetry honestly distinguishes a mutation receipt from a read.

Final Answer bytes stay in content storage. `content` can deliver them exactly, preserving a schema-constrained JSON value without inserting metadata inside it. The inspection envelope carries only bounded metadata and content references. Inlining a preview would be optional convenience, never the authoritative answer.

## Two messages across separate invocations

```sh
# Save the exact request before invoking the mutation.
onepage submit --key review-2026-09-05 --request first.json --wait 20 > first-receipt.json

# A nonterminal response is ordinary data; the process need not stay alive.
onepage inspect --turn turn_51 --wait 20

# Read the answer when completed.
onepage content --ref content_63

# second.json contains the Session reference from Turn 51's completed outcome.
onepage submit --key implement-2026-09-05 --request second.json --wait 20
```

The external agent decides whether to send the second message. A shell loop can issue bounded inspections without spending a model call on each poll. A waiting observation returns early on terminal outcome or actionable permission, and otherwise at its deadline. Timeout means the wait ended; it does not cancel or fail the Turn. Client disconnect has the same property.

## Response lost before either generated ID is returned

The caller already has a stable, caller-chosen key and exact request file:

```sh
onepage submit --key review-2026-09-05 --request first.json
# Response lost: neither ses_17 nor turn_51 is known to the caller.

# Deliberate recovery by the caller, with exactly the same key and inputs:
onepage submit --key review-2026-09-05 --request first.json
```

The server returns the original Session and Turn IDs if the first request committed. If it did not commit, this request may atomically create them. The CLI never retries mutations automatically, generates a replacement key, or resumes unfinished work merely because a read timed out.

Same-key equality is checked after access checks and before current-state new-admission preconditions. Thus retrying the original request after its Turn finishes, or after its Session advances further, still returns the same admission. Changed inputs under that key conflict. Session revisions are admission preconditions for a new key, not preconditions for retrieving an already committed admission.

For direct calls, use a native direct-admission key namespace scoped by Host Store and Principal: `(principal, direct_turn_key)`. The row that identifies the admitted Turn stores its exact binding and key; no dummy workflow and no generic request receipt table are necessary. An aborted atomic create leaves neither a Session nor an admission binding. This namespace is distinct from workflow `(run_id, agent_call_key)` identity. Both wrappers call the same Turn admission mechanism with their proper authority and provenance.

The immutable binding covers the Principal scope, target or explicit new-Session descriptor, prompt/input content, supplied schema, permission mode, context edits and Turn-local overrides. Initial context resolution must be replay-stable: repeat admission returns the originally resolved contract, not a fresh resolution against changed ambient configuration. New-admission configuration selection must be defined explicitly; do not accidentally bind only a mutable profile name.

## Revision and concurrency rules

At most one nonterminal Turn exists per Session. A different key attempting to start another Turn while one is active gets a typed active-Turn conflict; there is no implicit queue and no reinterpretation as steering. Once idle, an outdated expected Conversation or Context Revision gets a typed stale-reference conflict.

A successful Turn exposes the Session frontier at that Turn's completion, even if a different caller later advances the Session. It must not return the Session's live head as though it were the historical continuation reference for this result. This is essential for deterministic workflow replay as well as correct shell use. Failure and cancellation return durable Turn identities and typed outcomes; whether either additionally carries a safely reusable Session reference depends on unresolved issue 102 and should not be silently assumed here.

## Shared runtime and memory

The direct consumer creates real Sessions and Turns with direct admission provenance. A workflow remains an orchestration layer that admits the same kind of Turns with Run membership and its own cancellation fence. Avoid inventing a one-node workflow for every shell submission.

No resident chat session, retained conversation array, or per-Session worker is required. Idle Session state is in the Host Store. The CLI keeps a bounded request/receipt and streams content. Bounded wait must also be budgeted: it may use a capped population of temporary waiters or the existing bounded polling mechanism, and it must never hold a database transaction or an evaluator alive. A shell caller is free to exit and inspect later.

Reusing inspection capture-before-delivery is appropriate, but a single Turn report should stay a bounded metadata view. Do not pull full Conversation history into every receipt. Provider request construction still consumes existing bounded runtime resources; shell-first does not imply zero execution memory.

## Uniform response states versus explicit resources

A single `state` union such as `accepted | waiting | done | failed` is tempting because callers switch on one field. It conflates three independent facts: mutation admission, current Turn condition, and observation failure. For example, 'failed' can mean rejected submission, failed Turn, or failed read after successful submission. Repairing this with more states creates a combinatorial response contract.

This proposal instead uses one short submission command with two named blocks. It hides the routine submit-then-observe dance while keeping the important facts explicit. It is smaller at the shell surface than separate create-Session/start-Turn/wait commands, but slightly more complex than an admission-only command because the composite response has partial-success cases.

The native and HTTP interfaces should retain explicit resources and methods. Reducing CLI verbs does not justify a generic server dispatcher or mode-dependent `submit` that sometimes starts, steers, resumes, authorizes, and cancels.

## Main tradeoffs and open questions

- Atomic create-and-first-Turn eliminates an otherwise orphan-prone round trip and makes lost-response recovery straightforward.
- Optional waiting improves the common shell experience, but requires a precise partial-success envelope and bounded waiter policy. If this machinery is unnecessary, keep submit admission-only and make wait an explicit read command; that would be structurally simpler.
- Content references preserve exact output and bound response memory, at the cost of an extra read. Avoid presenting the metadata envelope as the model's schema value.
- Direct request identity is new public domain behavior even though it reuses existing storage mechanics. Its scope must be documented alongside Run and Agent Call keys.
- Direct Turn cancellation needs a durable Turn-targeted intent or equivalent explicit authority mechanism. Existing Run cancellation cannot be copied without changing ownership semantics. Direct callers must not acquire arbitrary authority to cancel workflow-member Turns.
- Permission decisions and interruption must operate on exact targets independently of a fake Run. Existing access checks and Run-membership cancellation fences remain relevant for workflow-owned Turns.
- No decision is made here about pending User Messages when a Turn fails or is cancelled, nor whether/how such a Session becomes continuable. The CLI reports those outcomes faithfully until that contract is settled.

CLI exit status should preserve the existing distinction: terminal Turn failure/cancellation is outcome data, not a transport failure. Validation, authority, infrastructure, unknown admission, or failed optional observation are command errors with nonzero exit; a nonzero response that includes a valid admission block still proves acceptance. Consumers must preserve/parse that block before retry decisions. A reached wait deadline with a valid nonterminal observation is a successful read and does not need an exceptional exit status.
