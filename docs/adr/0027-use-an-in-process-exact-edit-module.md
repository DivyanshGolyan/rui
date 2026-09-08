---
status: accepted
---

# Use an in-process exact Edit module

Accepted 6 September 2026 during [Set Host Runtime admission controls and budgets](https://github.com/DivyanshGolyan/onepage/issues/68).

## Decision

Replace Git-backed unified Patch with one exact existing-file Edit tool. The executable tool inventory remains closed: `bash` and `edit`. Edit takes a target, nonempty exact search text and replacement text; exactly one match is required. Preserve surrounding bytes and reject missing, ambiguous (including overlapping), empty-search and no-op input. There is no fuzzy matching, replace-all, multi-edit batch, normalization or new file-management capability.

Place the trusted native Edit implementation in its own module, inside the Host process behind the existing Action adapter. The Host owns permissions, execution admission, durable intent/content, semantic outcomes and recovery coordination. Edit owns matching, expected-postimage construction, live mutation mechanics and reconciliation observations. It has no SQLite or provider-credential access and does not receive the entire Host as its interface. Co-location saves process overhead but provides no independent native-crash or security isolation. Bounded execution turns must keep controls responsive; do not hide a whole-file synchronous call in the control loop.

Reuse one 16 KiB I/O window across matching/copying where ownership permits, stream source and replacement content, and retain only required search/overlap state. Do not create full-file strings, line objects, unrestricted diffs, per-edit processes, dedicated thread stacks or a permanent worker pool. Decoded search text is limited to 16,384 bytes; reject larger input before Authorization or target mutation using bounded decoding. Source-file and replacement size are not constrained by this search limit. Pre-authorization preparation occupies the same shared Active Capacity as execution. Persist exact intent and required inputs, release temporary resources and custody before waiting for permission, then reacquire capacity and revalidate the authorized intent before application. No separate preparation pool is introduced. Full workspace and descriptor accounting remains part of Host readiness. The existing 1,000 shared default and 256 MiB target remain qualification requirements, not proven outcomes. No four-Edit concurrency cap is accepted.

Preserve exact intent before Authorization, preimage/expected-postimage references, target identity, permission provenance, effect-aware cancellation and uncertain-effect reconciliation. Preparing the replacement does not authorize applying it. Loss of custody still makes a matching postimage an observation rather than proof OnePage performed the mutation. This does not add atomic filesystem compare-and-swap or change inode semantics through an implicit rename.

The [Native Edit module](../../ARCHITECTURE.md#native-edit-module), [product behavior](../../PRODUCT.md#exact-file-edits), [Edit Intent](../../CONTEXT.md) and [verification](../../VERIFICATION.md#native-edit-verification) own the detailed contracts.

## Why

Real Git used approximately 11.5–12.6 MiB process footprint on the roughly 1 MiB many-short-lines fixture. Pi, OpenCode V2 and Codex CLI demonstrate editing without delegating application to Git, but their whole-file/string/line structures are not bounded-memory implementations to copy. A native literal scan-and-copy probe avoids both a helper process and per-line state. It measured about 0.78 MiB as a standalone executable; a same-library empty-hash baseline already accounted for approximately that footprint. Neither number is an integrated per-edit Host allocation.

The buffer comparison passed 36 correctness cases and 45 measured cases. Reusing 16 KiB removed the second copy window without meaningful observed slowdown; 4 KiB was 37–45% slower on the larger fixtures. This justifies ordinary buffer reuse, not further allocator tuning or a claim of certified concurrent Host memory.

Anthropic's [brain/hands design](https://www.anthropic.com/engineering/managed-agents) motivates separating durable authority, orchestration and action implementations. Their physical separation also supplies failure/security and deployment properties. OnePage selects module separation with shared-process native execution for now; it does not claim those physical-isolation properties or introduce a generic remote-tool service.

## Superseded work and implementation obligations

- Replace current `apply_patch` execution bindings, unified-patch descriptors and model instructions with the exact `edit` contract. Keep provider-neutral Tool Call data and exact public replay/authorization identity separate from execution inventory; create no runtime alias/compatibility layer by default.
- Replace Git-based postimage preparation/application and its process/line-memory cost. Remove named Git scratch trees, helper-only S+P reservation, child file-size-limit handling and inherited scratch-area locks if they have no other actual consumer. Ordinary Store ownership locking and scratch accounting remain.
- Preserve the [superseded helper design](../design/archive/git-patch-scratch-before-native-edit-2026-09-06.md) and all experiments as history, not new implementation requirements.
- Preserve target eligibility until its owning effect contract is reconciled. The historical source's Git-based tracked-file check is a separate obligation: do not silently broaden eligible files or claim all Git overhead is gone while such a check remains.
- Retain and adapt permission/recovery fixtures, including divergence and partial mutation. The prototype covers sealed-snapshot preparation only; live mutation, production argument decoding, bounded service turns, source validation and integrated resource/failure qualification remain required.

This amends the Git/Patch-specific portions of ADR-0003, ADR-0004, ADR-0005, ADR-0010, ADR-0012, ADR-0013 and ADR-0021. Their non-conflicting authority, uncertainty and resource rules continue to apply. Source remains the historical implementation; accepting this decision does not complete V1 readiness or authorize a parallel implementation track.

## Evidence

- [Tool prior art](../research/pi-opencode-edit-tools.md), with pinned Pi/OpenCode V2/Codex CLI sources.
- [Lower-memory research](../research/lower-edit-memory.md).
- Local `codex/exact-edit-probe`: `7c72bdb` preparation, `ff24807` baseline attribution, `63581a1` buffer comparison; `/tmp/onepage-exact-edit-probe/research/exact-edit-probe/README.md`.
- The [buffer evidence](https://github.com/DivyanshGolyan/onepage/issues/68#issuecomment-5559639242) and preceding issue discussion preserve measurement limitations.

## Accepted file-access amendment — 7 September 2026

The user selected ordinary filesystem access for tools: no Git tracking/ignore/repository-membership check, Workspace-containment restriction or OnePage path allowlist. Workspace is the base directory for relative paths, not a sandbox; absolute paths can address accessible files elsewhere. Edit retains its existing-file exact replacement behavior and its exact target/preimage, authorization and recovery obligations. Bash retains ordinary command behavior and the same permission flow.

This resolves and supersedes the earlier instruction to preserve historical target eligibility pending reconciliation. Remove the Git tracked-file check instead of retaining a helper solely for eligibility. Normal path resolution does not permit unnoticed retargeting of authorized work. The owning product, architecture, terminology and verification sections are updated locally; production source remains historical.

## Accepted execution-time policy amendment — 7 September 2026

The user selected no separate Edit execution or reconciliation timeout. Bounded service turns and existing cancellation/recovery obligations govern progress. Cancellation may stop before mutation; after mutation begins, safe completion and reconciliation precede settlement. Bash execution and provider-inactivity timers do not apply to Edit. This is an accepted design requirement, not a production latency or filesystem-completion guarantee. ARCHITECTURE.md and VERIFICATION.md own the contract and required evidence.
