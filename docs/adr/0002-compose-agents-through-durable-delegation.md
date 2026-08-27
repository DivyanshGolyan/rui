# Compose agents through durable delegation

> Post-V1 direction. V1 includes caller-directed keyed Jobs through the workflow evaluator, but
> model-directed recursive delegation is excluded and imposes no V1 implementation, schema,
> capacity, or verification requirement. Reconsider this decision against measured product demand
> before implementation.

If a post-V1 product requires delegation, OnePage may model it as an asynchronous Operation that creates a child Agent, Session, and Task through the same Harness used for a root Agent. After the parent-child link and Operation are durable, the parent could release its Activation Slot and later receive the child's Outcome as a typed Result; no recursive call stack or resident ancestry would be retained.

That future design would require activation, suspension, resume, admission, and completion routing for one selected agent to remain bounded independently of ancestor depth, descendant count, and sibling count. It would address durable records directly rather than traverse or hydrate a delegation tree. None of these prospective topology rules constrains V1.
