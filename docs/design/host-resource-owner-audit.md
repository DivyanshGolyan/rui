> Current status: [ADR-0027](../adr/0027-use-an-in-process-exact-edit-module.md) supersedes the Git helper design below with native in-process Edit. The earlier audit and probes remain historical evidence. The [Host closeout](https://github.com/DivyanshGolyan/onepage/issues/68#issuecomment-5578368447) settles search policy and target eligibility; the [historical matrix](host-resource-matrix.md) retains earlier derivations subject to the subsequent amendment below. No four-Edit cap is accepted.

# Host resource owner audit

## Superseded Edit derivations — 10 September 2026

The [whole-line Edit decision](fixed-location-edit-approval.md) and [physical writing mechanism](edit-file-writing-proposal.md) supersede the literal-search policy, 16 KiB decoded-search cap, pre-authorization target preparation and three-scratch-role accounting below. The retained 16 KiB copy window is a different implementation workspace; it is not a limit on expected text, a line, a replacement or a file. Current execution streams exact approved ranges, builds complete output in charged unlinked scratch and copies back through the same opened target. It requires neither a full source snapshot nor post-crash target reconciliation.

The old scan/search formulas, three-role descriptor totals and associated memory examples remain evidence for their tested historical representation, not current admission formulas or production proof. Re-derive simultaneous scratch/descriptor and bounded input/comparison costs for the selected representation, count each owned resource once and retain the shared resource/cleanup guarantees. Current [resource requirements](../architecture/resources.md) and [verification](../../VERIFICATION.md) govern implementation. No new numeric expected-text cap or worker pool follows from these amendments.

6 September 2026. Design audit for [Set Host Runtime admission controls and budgets](https://github.com/DivyanshGolyan/onepage/issues/68), following acceptance of the [policy package](host-final-recommendations.md). This is not production certification.

## Population and release accounting

| Existing owner | Population and overlap to account for | Release and remaining proof |
| --- | --- | --- |
| External execution | At most Active Capacity live custodians; outbound request and captured output can coexist through completion. Model/Bash/Patch share the population. | All I/O, settlement and cleanup obligations must finish before reuse. Derive fixed file/handle multipliers from the selected adapter; no file per output item. |
| Bash supervision | At most the Bash subset of active custodians; process supervision, stdout/stderr pipes and retained output count. | Close after safe process/pipe cleanup and evidence consumption. One indexed capture file or two stream files are both finite; publish the chosen multiplier before matrix approval. Model-selected command memory is separate, supervisor memory is not. |
| Serial validation/import | One shared owner plus the sealed output it is consuming; growing range metadata goes to scratch. | Release metadata on commit or failed settlement. Use a bounded container count, not a file per parsed item; exact selected count belongs in the finite matrix. |
| Ordinary client | At most 120 ordinary exchanges by default, within 128 total connections. Account for ingress, complete report or diagnostic export and any transition overlap. | One exchange then close; delivery, failure and abandonment release owned scratch safely. No detached report backlog or file per report row. Shared capture work is serialized. |
| Diagnostic writer | One writer, one record window of at most 4 KiB, at most 16 files including active. | Rotation removes closed files before new growth. Failed deletion prevents growth; no separate archive backlog. |
| Diagnostic export | Within the ordinary-client population; charged destination plus a source handle during a copy turn. | Close source handles before yielding, including errors. Destination lives until delivery/abandonment; slow download cannot retain source handles. |
| Patch helper | Within active Patch custody, but named temporary trees and helper-created replacement files require explicit bounds. | **Unresolved:** enforce growth reservations for helper writes and retain ownership/accounting across failed cleanup and restart. Active population alone does not bound abandoned trees. |
| SQLite and evaluator | Existing Storage Owner and disposable evaluator; their costs remain in the total. | Internal numeric policy belongs to their existing Wayfinder tickets. Do not guess additional pools here. |

Byte quotas do not bound empty files. File/descriptor counts must be derived from the selected finite containers and concurrent owners, including transient overlap, library sockets, helper pipes and fixed Store/listener descriptors. Startup checks compare this requirement with actual platform availability; a second descriptor admission pool is not selected. ABI sizes and actual library/helper costs require implementation evidence, not synthetic worker stacks.

## Concrete Patch gap

The existing [prepareSnapshot](../../src/patch_tool.zig) creates a named `/private/tmp/onepage-patch-*` directory (lines 410–426), ignores `deleteTree` failure (430–434), and lets Git modify the private tree (446–452). Checking the resulting file size afterward (455–457) does not reserve growth beforehand. Ignoring deletion failure also allows named leftovers to survive physical-custody release and restart.

This is evidence from the historical implementation, not a claim that the new scratch policy is implemented incorrectly. The intended policy forbids bypass growth and returning a charge while retained files still require ownership. Resolve the helper-write bound and named-file failure/restart lifecycle before closing this ticket or approving the finite matrix. Do not silently exempt Patch, add an unbounded orphan cleanup queue, or infer that source constants are accepted V1 defaults.

Other source checks reinforce the implementation distinction: `src/host_runtime.zig:8–14` still uses default capacity 1 / maximum 100; `src/bash_tool.zig:277–295,355–361` captures output in RAM; `src/session.zig:1588–1599` owns a Harness scratch file. These are not passing evidence for the accepted 1,000-operation disk-first design.

## Completion status

All user-facing choices in the final policy package are accepted and published in the owning local documents. The owner audit is complete as an investigation, with the Patch gap and finite-container derivations above explicitly outstanding. No additional user preference is currently needed to investigate them. Production qualification, supported dependency selection, real helper costs and mixed-load measurements remain later evidence obligations; they are not replaced by this audit.

## Focused prototype follow-up

The [prototype evidence](https://github.com/DivyanshGolyan/onepage/issues/68) is captured
on local branch `codex/patch-scratch-probe`, commit `7867015`, at
`/tmp/onepage-patch-scratch-probe/research/patch-scratch-probe/README.md`.
Both installed Git builds passed upfront-reservation/file-limit cases and real
Host-death/inherited-scratch-lock checks. Closing the unnecessary old scratch
handle before Git halved retained file bytes in the roughly 1 MiB fixture.
One Host scratch lock replaces a need for per-directory lock tracking. The
mechanism needs only a reservation value per Patch, but real Git memory was
about 11.5–12.6 MiB for the many-short-lines fixture and remains in OnePage's
budget. These are individual observations, not concurrent qualification.

The prototype supports the mechanism, not an arbitrary Git byte bound:
single-file invocation, conversions/attributes, file-count proof and actual
Host lock inheritance must be reconciled before the ticket closes. See the
report for exact cases and limitations. No production code or policy acceptance
is implied by this investigation.

## Accepted mechanism after follow-up

The user authorized proceeding with the checked mechanism. ARCHITECTURE.md now
owns [Patch helper scratch ownership](archive/git-patch-scratch-before-native-edit-2026-09-06.md),
and VERIFICATION.md owns its production proof. The controlled-invocation
follow-up is local commit `71d89a7` on `codex/patch-scratch-probe`; all 16 cases
preserved literal output across the two installed Git builds.

The design gap above is resolved: reserve S+P for the one-file snapshot/application
region, close the old snapshot handle before replacement, enforce the file
maximum in the child, and retain one inherited scratch-area lock through
surviving helpers. Live failed cleanup retains custody/charge; restart acquires
exclusive ownership and removes stale trees before admitting a fresh population.
Earlier unresolved notes above preserve the audit's discovery and are superseded
by this accepted contract. Production integration is still required.

Host matrix completion still needs the final finite container/descriptor
derivations and intended helper-resource assumptions reconciled with the
evaluator, effect and SQLite owners. The measured Git memory cost must remain
in that accounting; this mechanism does not lower it or certify 1,000 concurrent
Git helpers under the 256 MiB target.
