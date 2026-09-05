---
status: amended by ADR-0022 and ADR-0023
---

# Use two executable tools and bounded model dispositions

## Accepted ownership amendment — 5 September 2026

[ADR-0020's ownership amendment](0020-version-model-visible-context-sparsely.md#accepted-ownership-amendment--5-september-2026) removes the separate Turn Contract. Current Session settings are selected independently at model request or Action admission, with exact historical inputs/permissions retained there. Permission Mode persists on the Session and may change; existing Authorizations are unchanged. Runtime information and retained resource limits stay with their actual consumers/scopes. Numeric limits remain with their assigned decisions. The older Turn-local settings and permission language below is historical where it conflicts with these amendments.

## Original decision

OnePage v1 exposes only `bash` and `apply_patch`. The Caller selects one immutable Permission Mode
when admitting a Turn: `ask`, the default, creates one immutable Permission Request for every exact
validated tool call; `bypass` creates Authorization for every validated call without creating that
request. The mode is part of the Turn Contract and the Agent Call Key binding and cannot change while
the Turn is active. Turn admission rejects bypass unless the Principal's Authority permits it. A User may be a person or another Agent, but that Conversation role is not
permission Authority. A Permission Decision requires a Principal whose explicit grant covers the exact
operation and descriptor. Bypass changes only how Authorization is obtained; each bypass Authorization
records exact Turn Contract and descriptor provenance. It does not skip descriptor binding, validation,
bounds, durability, patch preimage checks, or effect-recovery rules or become blanket durable Session
authority. OnePage does not classify apparently read-only Bash commands for automatic permission.

The V1 product inventory is closed, but the provider-facing Conversation representation is generic:
the exact model Operation binds a bounded Tool Catalog and a Tool Call selects a stable Tool Key with
exact bounded JSON arguments admitted under the bound Validation Profile. The Host Runtime alone maps an allowed
key to one of these two Actions. This does not
create runtime discovery, a plugin system, or generic execution authority; see ADR-0012.

A valid model response may contain multiple ordered Tool Calls. Each call becomes one child Action
Operation and returns its Result to the next model Operation after every child settles. A complete
non-empty assistant response with no Tool Call becomes the Final Answer only when its settlement
transaction proves that no earlier applicable User Message is pending; otherwise it remains ordinary
assistant text and another model Operation is required.
V1 has no model-created conversational Input Request. Later User Messages are admitted independently and become eligible only when a model Operation requesting the next assistant response freezes its manifest; an internal compaction Operation does not apply them.
Dedicated search, read, verification, finish, and stop actions would duplicate shell or
model-protocol behavior and enlarge the core without adding capability. Approval fatigue in `ask`
mode alone is insufficient reason to add a third workspace tool; actual V1 usage must demonstrate
that need.
