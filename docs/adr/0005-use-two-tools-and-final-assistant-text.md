# Use two tools and final assistant text

OnePage v1 exposes only `bash` and `apply_patch`. The user selects one permission mode for each
invocation: `ask`, the default, prompts to allow or deny every exact tool call; `bypass` admits every
validated call without a prompt. Bypass skips only interactive permission. It does not skip
descriptor binding, validation, bounds, durability, patch preimage checks, or effect-recovery rules,
and it must be selected again on resume rather than becoming durable Session authority. OnePage does
not classify apparently read-only Bash commands for automatic permission.

A valid tool call executes and returns its Result to the next model turn, while a complete non-empty
assistant response with no tool call is the Final Answer. Dedicated search, read, verification,
finish, and stop actions would duplicate shell or model-protocol behavior and enlarge the core
without adding capability. Approval fatigue in `ask` mode alone is insufficient reason to add a
third workspace tool; actual V1 usage must demonstrate that need.
