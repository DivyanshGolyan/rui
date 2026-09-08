> Historical decision evidence from 6 September 2026. [ADR-0026](../../adr/0026-let-operations-own-current-execution-and-final-results.md) records the later execution selection; [current execution rules](../../architecture/execution.md) govern implementation. Unresolved wording below describes the earlier comparison stage, not current readiness.

# Execution-model comparison

Status: comparison accepted with the user on 6 September 2026; carry candidate B to final selection while preserving the memory contract. This is a contract trace, not executed production, crash-test or formal-verification evidence. Final execution representation and schema remain unselected.

Owner: [Compare complete execution models against crash and race scenarios](https://github.com/DivyanshGolyan/onepage/issues/105). The following [Choose the execution model and its verification contract](https://github.com/DivyanshGolyan/onepage/issues/106) owns final selection and reconciliation.

## Candidates

**A — immutable per-try facts.** An Operation binds exact work; every admitted Attempt is immutable and may own one Completion. One immutable Resolution selects semantic meaning, including outcomes without physical execution. Accepted output belongs to the selected Completion. Retryable Completions retain immutable eligibility; queries exclude superseded or resolved work. This is the documented baseline with the accepted diagnostic amendments.

**B — current execution facts plus immutable final meaning.** An Operation still binds exact work and causal identity. It owns the current admitted execution identity, the recovery-relevant condition of that execution, and current retry eligibility. Policy accounting lives at its actual scope, including the Turn if the budget decision retains that scope. Admission and retry settlement atomically update these facts. Once settled, final meaning, required final evidence, producing identity and accepted output become immutable and independently referenceable for the Operation's lifetime. Failed-try details may live in bounded diagnostics. This describes ownership, not selected SQL columns or whether final meaning is inline or a separate relation.

B cannot be a generic mutable latest-response field: later model requests, Conversation, Tool Results and workflow replay require stable accepted results and provenance. Nor can it erase admitted tool uncertainty or reset allowance when current execution changes. Its mutable fields replace recovery facts; they must not introduce a second cached lifecycle representation beside them.

## Common owners and atomic boundaries

SQLite admission commits exact work/authorization, fresh execution identity and consumed allowance before launch. Only the committing invocation receives a volatile one-shot Dispatch Permit. Physical Custody owns live handles and the atomic launch/suppression race; cleanup retains capacity until resources are safe to release. No execution representation reconstructs that permit after a crash.

Normal settlement commits accepted content, immutable final meaning and semantic consequences together. No lost response can replace committed meaning. Model retryable settlement instead commits the policy-relevant failure facts and future eligibility without resolving the Operation. New dispatch admission revalidates unresolved state, eligibility, identity and allowance atomically. No diagnostics are consulted by these decisions.

## Scenario comparison

| Scenario | A: immutable per-try facts | B: current execution facts | Next permitted action / unchanged guarantee |
| --- | --- | --- | --- |
| Crash before dispatch admission commits | No new Attempt survives. | No new current execution or allowance update survives. | No dispatch from the rolled-back invocation. Fresh admission may proceed under current applicability and policy. |
| Crash after admission, before launch | Attempt survives without Completion. | Current admitted identity and consumed allowance survive. | Conservatively recover uncertainty; do not recreate the old permit even if launch never happened. |
| Crash during execution or after scratch seal, before settlement | Unresolved Attempt survives; scratch does not. | Unresolved current execution survives; scratch does not. | Same effect-specific recovery; received but uncommitted bytes are not accepted output. |
| Retryable A, then B, then crash | Retain A's Completion/eligibility and B's Attempt; recovery excludes superseded eligibility. | A's failure updates current eligibility/accounting; B atomically replaces identity and waiting eligibility while preserving consumed policy facts. | Recover B as uncertain. Only a fresh policy-authorized model try may launch, using the same frozen manifest. No reset of A+B spending. |
| Stale or conflicting A callback after B | Live identity rejects it; no historical payload comparison is required. | Same exact identity fencing; identities cannot be reused so an old callback matches newer custody. | Neither callback may touch B's handles or accepted meaning. Adapter enforces at-most-once delivery and suppression after detachment. |
| Interruption before model launch | Insert Interrupted Resolution without inventing Completion; Attempt remains. | Commit immutable interruption meaning/provenance and invalidate dispatch/retry applicability while retaining consumed facts. | Physical launch race suppresses the permit or detaches transport; no semantic retry. |
| Interruption during model execution or retry delay | Resolution excludes the old eligibility and blocks output acceptance. | Terminal meaning makes current eligibility inapplicable; any previously selected due work revalidates at admission. | Stop provenance survives. Physical cleanup is bounded and does not prove remote billing stopped. |
| Bash admission followed by loss of custody/result | Exact authorized descriptor and Attempt prove admitted uncertainty. | Same descriptor and current admission fact prove uncertainty. | Resolve indeterminate once; never automatically replay Bash. Typed Tool Result lets the Agent inspect external state. |
| Patch admission followed by loss of custody/result | Exact authorized Patch Intent, Attempt and reconciliation observation support Resolution. | Same intent/current admission; immutable final meaning retains the observation. | Observe preimage/postimage/divergence/invalid target. Under ADR-0004, even matching postimage after custody loss does not prove this try produced it: retain indeterminate meaning, do not silently reapply or report successful execution. |
| Accepted model result; acknowledgement lost | Completion owns items and Resolution selects them; projections commit atomically. | Immutable final result owns or references those same canonical items with producing request/execution provenance; projections commit atomically. | Reads recover committed meaning without another effect. Public Run/workflow keys replay original bindings/results; keyless direct resubmission may create new work. |
| Compaction accepted, then later requests/restart | Accepted Resolution and source manifest define lineage/coverage; selected Completion owns replacement output. | Same stable final-result identity, source manifest and immutable replacement content remain referenceable independently of current retry fields. | A failed compaction cannot displace the accepted base. Missing/incompatible selected continuation fails explicitly. Compaction changes the manifest and requires a new Operation, not an equal-input retry. |
| Unsupported rejected provider output | Typed rejection and request/causal evidence can settle the original Completion/Resolution shape without mandatory full rejected payloads. | Immutable failed meaning preserves the same typed rejection and provenance. | No Conversation, continuation or effects. Raw detail is explicit bounded diagnostic capture; accepted unknown fields remain canonical. |
| Client disconnect versus server stop | Client loss changes no execution intent; server stop loses volatile custody after bounded cleanup. | Same. | A running server continues work after client loss. Explicit server restart recovers unfinished work with remaining policy allowance; infrastructure stop does not manufacture semantic cancellation. |
| Shared-Session Run cancellation interrupted by crash | Run intent fences that evaluator; ordinary Session stop/Resolution facts govern selected work. | Same Run intent and stop facts; current execution cannot override them. | Bounded full pass may repeat stops, including idle/already stopped Sessions and newer work. No per-Session receipts or permanent fence. Only committed terminal Run cancellation completion prevents further propagation; failure before that commit leaves it unfinished. |

Permission denial and cancellation before any Action admission can produce immutable final meaning without fabricating an execution. Sibling Tool Calls retain independent Operations and results; projection remains in call order under both candidates. Stop-versus-settlement and new-message-versus-final-answer races remain ordered by the owning SQLite transaction, not diagnostics or notification arrival.

## Total complexity

A obtains local append-only identities and easy historical joins. It retains more authoritative relationships, historical eligibility that must be excluded, and Completion/Resolution combinations whose meaning queries must reconstruct. Its history is useful for investigation but complete failed-try history is not a recovery requirement demonstrated by these traces.

B removes superseded failure history from recovery authority. It pays for exact guarded updates, non-reused execution identity, atomic conserved accounting and eligibility replacement. It must explicitly preserve immutable final meaning, final evidence and stable references; it cannot hide these obligations inside an unrestricted mutable state blob. Both candidates need the same admission fence, custody lifecycle, effect-specific recovery, canonical content and public replay contracts. Diagnostic storage is bounded under either candidate, so moving details to logs is not a claim of zero retained bytes.

The traces have found no requirement for the complete immutable sequence of failed tries. This supports carrying B to final selection, not a measured claim that B has fewer implementation cases or uses less memory. A remains viable.

## Memory implications and required evidence

Current execution state means canonical facts in SQLite, not a resident object for every Operation. Both candidates preserve disk-first authority, bounded Decision Snapshots, one startup-sized content-free Physical Custody table, shared serial validation/import and fixed borrowed content windows. Dormant Sessions, terminal Turns and waiting retries gain no resident driver, timer, history cache or payload buffer. B does not inherently require a larger RAM topology than A; fewer authoritative historical records are a storage simplification, not a measured RSS improvement.

Default diagnostic encoding, detailed capture, rotation and export must also use bounded memory. A diagnostic disk quota never authorizes allocating that many bytes in RAM. Keep variable payloads on disk, avoid an unbounded event queue or full-log export buffer, and preserve explicit accounting for any fixed logger workspace. Diagnostic growth or high event rates must not create memory growth with the number of historical tries.

Verification must separate memory from disk and I/O. Measure the existing dormant-population and Active Capacity axes, repeated failed-try/retry churn at fixed concurrency, diagnostic retention approaching its quota and rotation, detailed large-payload capture, and diagnostic export. Include whole-process RSS, SQLite heap/cache/spill, filesystem-cache/writeback pressure, diagnostic disk usage and command/settlement latency. Updating current rows can still cause journal writes and page-cache activity; no CPU, I/O or memory improvement is claimed without measurements. Numeric targets remain owned by the approved resource matrix.

## Remaining facts and decisions

- [Choose provider retry and external-effect budgets](https://github.com/DivyanshGolyan/onepage/issues/91) has not selected exact policy. A counter alone is not established as sufficient. B must retain the bounded policy facts selected there, including current classification, future eligibility, consumed allowance and any retained deadline; Turn-wide accounting must span model and compaction Operations if retained.
- Accepted provider continuation and wire facts remain owned by [Establish provider reasoning and server-side compaction wire contracts](https://github.com/DivyanshGolyan/onepage/issues/73). This comparison preserves them rather than introducing another wire assumption.
- The user has accepted the [local diagnostic separation](../../../ARCHITECTURE.md#local-diagnostics-and-application-state). It does not select A or B. Physical diagnostic storage, numeric quota and exact capture/export interface are not chosen here.
- The user accepted carrying B forward and emphasized memory efficiency. Final execution ownership, terminology, constraints and required fixtures belong to the following selection ticket. Preserve the memory requirements below. No additional prototype or outside research is needed to complete this contract comparison; integrated measurements remain required implementation evidence.

## Sources

- [Required execution guarantees and Host settlement](../../../ARCHITECTURE.md#required-execution-and-recovery-guarantees)
- [Operations and recovery evidence](../../../VERIFICATION.md#operations-attempts-and-recovery)
- [Effect-specific uncertainty](../../adr/0004-reconcile-uncertain-effect-attempts.md)
- [Provider continuation](../../adr/0023-preserve-provider-replay-without-silent-degradation.md)
- [Accepted delivery and diagnostic amendments](../../adr/0025-enforce-execution-contracts-without-historical-replay.md)
- [Accepted shared-Session cancellation](https://github.com/DivyanshGolyan/onepage/issues/101#issuecomment-5550876667)
- [Accepted Host ownership](https://github.com/DivyanshGolyan/onepage/issues/100#issuecomment-5549173568)

## Subsequent selection

The user subsequently accepted direct Operation ownership of its final result in [Choose the execution model and its verification contract](https://github.com/DivyanshGolyan/onepage/issues/106). [ADR-0026](../../adr/0026-let-operations-own-current-execution-and-final-results.md) and the owning normative documents publish that selection. The candidate descriptions and comparison above preserve the earlier comparison-stage evidence; they do not establish production implementation or measured resource improvement.
