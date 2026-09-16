# Domain Docs

Rui uses a single domain context. Engineering skills consume the accepted contract in `ARCHITECTURE.md` directly; `CONTEXT.md` and ADRs supplement rather than duplicate it.

## Before exploring

- Read `ARCHITECTURE.md` sections owning the affected behavior and terminology.
- Read `CONTEXT.md` when it exists.
- Read relevant ADRs under `docs/adr/` when they exist.

If `CONTEXT.md` or `docs/adr/` does not exist, proceed silently. Domain-modeling skills create them lazily only when a glossary term or durable decision needs a home outside the accepted contract.

## Vocabulary and authority

Use terms as defined in `ARCHITECTURE.md` and any later `CONTEXT.md`. Do not introduce synonyms for established domain concepts. Each requirement keeps one owning home under the repository rules in `AGENTS.md`.

If a proposed decision contradicts the accepted contract or an ADR, identify the conflict explicitly rather than silently overriding it.
