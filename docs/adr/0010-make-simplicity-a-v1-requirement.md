---
status: amended by ADR-0021
---

# Make simplicity a V1 requirement

OnePage treats architectural simplicity as a correctness constraint for V1. Every subsystem must directly support a current product guarantee, an external-effect boundary, or evidence required for the release claim. A hypothetical second consumer does not justify a framework, registry, pool, durable representation, background owner, or extension point.

The project prefers established dependencies for mechanisms while retaining policy and authority inside its existing deep modules. SQLite owns physical database transactions, Git owns patch parsing and application, and narrow HTTP, TLS, browser, and OS credential-store dependencies may supply mechanisms for the provider-specific Codex authorization path. OnePage does not duplicate those mechanisms unless their contract cannot preserve its authority boundary.

Canonical relational rows are the sole semantic authority. Deep command-specific modules prepare exact relational changes and content closure for one SQLite commit; no caller supplies a reducer image, continuation blob, cached phase, or parallel fact stream. This replaces parallel Core/fact authority with direct constraints and typed transactions.

Resource simplicity follows the same rule. Fixed resident structures contain only storage used by the shipped path; variable content is streamed or spooled rather than copied through multiple complete buffers; and consumed owners are destroyed rather than retained as process-lifetime tombstones. ADR-0013 defines the separate accounting boundary for model-requested workload memory.

The V1 architecture therefore has one native Host Runtime that owns Workflow Runs and is the sole agent runtime, one Storage Owner and SQLite connection, one protocol-independent Run Service, one provider-neutral model data contract, two concrete admitted tools, one startup-fixed Active Capacity, and one Host-managed disposable QuickJS evaluator. ADR-0021 keeps the physical execution topology private within that Host Runtime. The CLI only composes Run Service operations and renders one normative JSON Run Snapshot or its deterministic Markdown view. `agent()` is the evaluator's only durable intrinsic; ordinary JavaScript owns fan-out and joins without a second agent runtime or durable Host DAG. The architecture explicitly rejects generalized scheduling, retained workflow VMs, provider and OAuth frameworks, runtime tool registries, generic effect execution, terminal frameworks, daemons, event streams, industry protocol adapters, custom SQLite fault infrastructure, and Host Store maintenance before evidence creates those responsibilities.

A broader surface requires a concrete current use, documented bounds and ownership, deletion or consolidation of overlapping responsibility, and an accepted ADR explaining why an existing role or dependency is insufficient. Review treats an unjustified architectural surface as a standards violation, not optional cleanup.
