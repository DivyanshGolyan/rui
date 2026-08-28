# Use two executable tools and bounded model dispositions

OnePage v1 exposes only `bash` and `apply_patch`. The Caller selects one permission mode for each
advancing invocation: `ask`, the default, creates one immutable permission Interaction Request for every exact
validated tool call; `bypass` admits every validated call without creating that request. A User may be
a person or another Agent, but that Conversation role is not permission Authority. A response requires
a Principal whose explicit grant covers the exact operation and descriptor. Bypass changes only how
Authorization is obtained; it does not skip descriptor binding, validation, bounds, durability, patch
preimage checks, or effect-recovery rules or become blanket durable Session authority. OnePage does not
classify apparently read-only Bash commands for automatic permission.

The V1 product inventory is closed, but the provider-facing Conversation representation is generic:
the exact model Operation binds a bounded Tool Catalog and a Tool Call selects a stable Tool Key with
exact bounded JSON arguments admitted under the bound Validation Profile. Harness alone maps an allowed
key to one of these two Actions. This does not
create runtime discovery, a plugin system, or generic execution authority; see ADR-0012.

A valid tool call, including one whose external effect is indeterminate, returns its Result to the
next model turn, while a complete non-empty assistant response with no tool call is the Final Answer.
The only other V1 model disposition is a bounded non-effecting `input_request`; it creates an immutable
Interaction Request and no executable Action.
Dedicated search, read, verification, finish, and stop actions would duplicate shell or
model-protocol behavior and enlarge the core without adding capability. Approval fatigue in `ask`
mode alone is insufficient reason to add a third workspace tool; actual V1 usage must demonstrate
that need.
