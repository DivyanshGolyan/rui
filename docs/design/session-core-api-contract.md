# Session core API contract

Consolidated 2026-09-09 from accepted architecture discussion. Behavioral contract; operation names below are illustrative, not a selected wire schema. No production implementation is claimed. This describes the Session core boundary, not the entire server API or a generic operation interpreter.

## Admission

| Capability | Input | Committed answer |
| --- | --- | --- |
| Configure Session | Request key, caller-provided Session key and configuration; complete baseline for an unknown Session | Original configuration acceptance or saved rejection |
| Send message | Request key, caller-provided Session key and message inputs | Original message admission/work binding or saved rejection |

The caller constructs a Session reference locally, without core interaction or a claim that durable state exists. Session keys are opaque within the Store. Workflow callers scope short names by Run identity, while Session operations accept a full key unchanged for reuse across Runs; key possession does not bypass access checks. Session identity, Run identity and per-call request identity remain distinct. No generated Session ID discovery, dedicated creation operation or Workflow Runtime creation-reference resolver is required.

The first accepted configuration transaction establishes the Session, complete baseline, Workspace and access scope with its request answer. Later requests apply supplied mutable configuration fields in admission order. They do not compare against the original baseline or silently ignore different values; ordinary validation and immutable Workspace/access constraints remain enforced. An incomplete first configuration or a message to an unknown Session rejects without leaving a partial Session. Configuration starts no Turn or model work. Both configuration and message admission acknowledge semantic commit without waiting for provider dispatch; a message's work result may remain pending. See the [accepted initialization decision](session-initialization-proposal.md).

The core atomically saves the key, canonical request binding and admission answer with the corresponding changes. Recover an existing matching binding before reevaluating current admission conditions. A message rejected before a Session existed remains rejected under that request key after later initialization; a fresh submission needs a new key. Matching repeats recover that answer without repeating the mutation. Different inputs under an existing key conflict without replacing its answer. Replaying old configuration must not overwrite newer configuration. Replaying a message must not attach it to a newer Turn. Definite committed rejections remain stable even if conditions change; deliberate fresh submissions need new keys.

Idempotency keys are caller-provided and opaque to the core. Direct callers must retain the key and exact request before sending to recover a lost reply. Workflow adapters derive a namespaced identity from Run identity plus author-supplied call key, not workflow name/content. Encoding remains to be selected. Malformed requests without a usable identity and inability to commit cannot promise a recorded answer. This is admission idempotency, not exactly-once external execution.

## Observation and waiting

Observation by request identity returns not found, its committed rejection, or its original acceptance and the current result of the bound work. Acceptance is immutable; pending work can subsequently complete. Configuration completes at admission; its acknowledgement requires no generated Session ID or historical revision token. A message's final work result may be pending. Return the original bound result once available, not whatever a Session happens to be doing now.

A caller can wait for relevant changes and read again. Disconnecting ends that observation, not execution. Waiting does not occupy external Active Capacity or protected short-control headroom. Wait timeout, change-token encoding and event transport remain implementation details; correctness must not depend on receiving every notification. ETags are an optional unselected optimization, not required admission preconditions.

The workflow records completed results and stable failures, then freezes the visible set before each evaluator generation. Later arrivals wait for a later generation. Progress inspection may briefly lag and does not require a globally atomic cross-Session snapshot. Scalar observations suffice for correctness; a bounded batch API is an optional call-overhead optimization. See the [two-Session walkthrough](two-session-workflow-trace.md).

Workflow Run inspection exposes the exact keys of associated durable Sessions, with enough context for an agent to choose one. The agent may write the selected key directly into a later workflow. No authored-output metadata or previous-Run lookup contract is required. Reuse observes and continues the current Session, not a snapshot at the earlier Run’s end. Workflow Runtime owns this association through its call records; core does not acquire Run membership.

## Permission and stop

Permission decisions target one exact saved permission request and patch/descriptor under existing authority and repeat/conflict rules. Approval may precede execution capacity. A stale approved Edit fails without relocation; any new proposal follows ordinary permission rules.

Session stop applies to current work in the named Session, irrespective of which client submitted it. Acknowledgement and completion are distinct: completion follows the selected work's terminal outcome and effect-owned obligations; idle stops complete immediately. A direct caller and workflow sharing a Session must coordinate use, especially across retried stops. The existing exact model-interruption capability remains separate; this consolidation does not remove it or extend generic idempotency to every control.

## Independent workflow client

The workflow saves each submission identity and exact inputs before calling the core. It saves the returned acceptance or rejection in a separate transaction. After interruption it resubmits unanswered calls with the same identity. No shared transaction, Run-aware core admission or privileged core-table access is required.

Cancellation stops new call creation, resolves saved unanswered calls by resubmission, records their answers, then stops Sessions with accepted message calls. Previously undelivered calls can be admitted during this sequence; their cost and effects before stop are accepted. Reference construction or configuration alone does not add Sessions to the stop set, and configuration effects are not rolled back. Cancellation cannot finish while submissions remain unresolved or required stops remain unfinished. Workflow call records own Run relationships. Separate lifecycle does not require separate processes.

## Evidence and open implementation details

The [SQLite protocol prototype](../../research/session-api-prototype/README.md) exercises lost replies and workflow cancellation using separate databases and fresh processes. It validates a small protocol model, not production guarantees. Its separate-creation example predates the initialization amendment and does not verify first-configuration initialization. Exact wire types, canonical input encoding, key representation, observation notification mechanics and integrated resource evidence remain implementation work.

Owning decisions: [shared identity](shared-request-identity.md), [transactional operations](transactional-operations.md), [tool recovery](unified-tool-recovery.md), [Edit approval](fixed-location-edit-approval.md), and [execution tracking](fixed-execution-tracking.md).

The [bounded TLA+ model](../../research/request-protocol-model/README.md) checks two-call cancellation/retry interleavings with one crash, plus cancellation progress under explicit fairness. Negative controls detect premature completion and uncertain-tool replay. Atomic admission and fixed key/input binding are modeled assumptions, not proofs of database code.
