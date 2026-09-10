# Direct transactional operations

Accepted in architecture discussion on 2026-09-08; documentation only, not implementation evidence.

One meaningful durable operation owns one cohesive function and transaction. Examples are accepting validated model output, saving an Edit proposal and permission request, recording permission, admitting execution, and saving a tool result. Helpers may own parsing, queries and row mechanics. A mandatory pure classifier plus mutation interpreter is removed; shared logic earns extraction through concrete reuse rather than a required architecture layer.

Content validation precedes the transaction. Checks depending on saved state remain inside it. Edit proposal shape validation precedes the function saving its exact patch and permission request, without requiring a target read. File-dependent checks happen after authorization and before mutation. Permission and execution admission remain distinct because execution requires capacity. External work starts after commit, and required work remains discoverable from durable facts rather than only a callback. Saved authorization without an Attempt remains eligible subject to applicability; an admitted uncertain tool Attempt follows the no-replay policy. Model replacement attempts retain their separate policy.

Sequential validation remains the baseline, with bounded memory and scratch ownership. A worker or scheduler continuation requires measured evidence. This does not make transactions span provider execution, tool execution or Edit preparation.

The [research note](../research/transactional-operation-prior-art.md) provides supporting prior art and post-commit caveats. The [architecture](../architecture/execution.md#host-runtime-execution-and-settlement), [domain language](../../CONTEXT.md) and [verification](../../VERIFICATION.md#transactional-operation-boundaries) own the amended contract. Earlier architecture alternatives remain unselected historical proposals.
