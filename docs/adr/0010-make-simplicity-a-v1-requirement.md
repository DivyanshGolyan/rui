# Make simplicity a V1 requirement

OnePage treats architectural simplicity as a correctness constraint for V1. Every subsystem must directly support a current product guarantee, an external-effect boundary, or evidence required for the release claim. A hypothetical second consumer does not justify a framework, registry, pool, durable representation, background owner, or extension point.

The project prefers established dependencies for mechanisms while retaining policy and authority inside its existing deep modules. SQLite owns physical database transactions, Git owns patch parsing and application, and a safe transport dependency may own Codex authentication. OnePage does not duplicate those mechanisms unless their contract cannot preserve its authority boundary.

The V1 architecture therefore has one Host Runtime, one Storage Owner and SQLite connection, one Harness lifecycle interface, one Provider capability, two concrete tools, one startup-fixed active-capacity number, and line-oriented terminal projection. It explicitly rejects generalized scheduling, provider and OAuth frameworks, tool registries, terminal frameworks, custom SQLite fault infrastructure, and Host Store maintenance before evidence creates those responsibilities.

A broader surface requires a concrete current use, documented bounds and ownership, deletion or consolidation of overlapping responsibility, and an accepted ADR explaining why an existing role or dependency is insufficient. Review treats an unjustified architectural surface as a standards violation, not optional cleanup.
