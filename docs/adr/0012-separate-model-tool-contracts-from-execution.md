# Separate model-tool data from execution authority

OnePage uses one provider-neutral Conversation and model-tool data contract. Conversation distinguishes
user text, assistant text, tool calls, tool results, and context checkpoints. A bounded immutable Tool
Catalog gives each model-visible Tool Definition a stable Tool Key, provider-facing metadata, bounded
input JSON Schema, and result-content contract. The exact Model Contract additionally declares one
provider-neutral, non-effecting `input_request` disposition. Provider adapters translate this semantic
request at the edge and durably capture one bounded candidate assistant text, generic tool call,
input request, or typed failure. Captured bytes remain non-authoritative until the Host validates them
once and commits their provider-neutral Result meaning through the Session Ledger.

The exact catalog, model contract, instructions, Model Context, and semantic request digest are bound
to a model Operation. Replacement Attempts under that Operation dispatch identical semantic request
bytes. Changing the catalog creates a new Operation rather than changing a retry.

This generic data shape grants no execution authority. V1 Harness admission maps allowed Tool Keys
through a closed switch to the `bash` and `apply_patch` Actions. Their validation, permissions,
Authorization, Attempt admission, recovery, and adapters remain distinct. Unknown or unbound keys fail
closed. An `input_request` instead atomically commits assistant prompt text and one durable Interaction
Request; it creates no Action, Attempt, Authorization, or external effect. OnePage does not add runtime tool registration, MCP execution, plugins, or a generic effect
executor before a concrete product use requires them.

Tool Calls retain the exact bounded JSON argument bytes admitted under a versioned strict-validation
profile and the Operation's bound Tool Catalog. Exact-byte identity, not semantic-equivalence identity,
is the V1 replay contract. Canonical key ordering and number or string spelling are not repeatedly
proved by Conversation readers. Built-in tools derive one durable typed effect descriptor from the
admitted call before their external-effect boundary; execution never interprets generic JSON for the
first time after Attempt admission.

Issue #38 owns that atomic Conversation and Interaction Request transition. Before that layer is
available, the lifecycle validates and isolates a complete `input_request`, creates no Action or
Conversation entry, and commits a terminal Core phase reported as `InteractionRequestLayerRequired`.
It preserves the admitted response metadata but must not expose an awaiting-input state that has no
durable request or response path.

The split is necessary now because both the deterministic fixture and Codex Provider must
consume the same request without understanding tool-specific durable encodings. It preserves a small
provider seam while retaining ADR-0005's closed V1 product surface and ADR-0010's simplicity rule.
