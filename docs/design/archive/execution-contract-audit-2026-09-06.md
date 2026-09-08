> Historical decision evidence from 6 September 2026. [ADR-0026](../../adr/0026-let-operations-own-current-execution-and-final-results.md) records the later execution selection; [current execution rules](../../architecture/execution.md) govern implementation. Unresolved wording below describes the earlier comparison stage, not current readiness.

# Execution contract audit — 6 September 2026

Read-only subagent audit of the documented design at `d76c7350a3661da48e9d107258e3dd699f9b0aa7`, before the ADR-0025 amendment. Findings below are historical observations and comparison inputs, not selected implementations or production evidence.

The audit asked whether each component can enforce its own lifecycle contract, whether durable facts have a concrete recovery or product consumer, and which external uncertainties cannot be removed by a local interface. It read the normative documents, accepted ADRs, and live execution, Host-ownership and retry-budget issues.

## 1. Historical Completion replay has no identified producer consumer

The original [settlement contract](https://github.com/DivyanshGolyan/onepage/blob/d76c7350a3661da48e9d107258e3dd699f9b0aa7/ARCHITECTURE.md#L193-L207) promises exact historical result replay/conflict discrimination despite one terminal owner, nonrecoverable scratch, no Completion Inbox, and explicit disposal of late output. After failed try A and replacement B, a duplicate A callback needs to be suppressed; no identified live producer needs to compare A's bytes with a permanent old result. Clients do not submit provider results, and a dead process cannot replay its scratch.

An at-most-once adapter/effect-owner handoff and live identity checks can enforce delivery correctness. Durable current execution facts, retry accounting/eligibility, accepted results and stop authority still matter. [ADR-0025](../../adr/0025-enforce-execution-contracts-without-historical-replay.md) accepts removing the historical replay promise; it does not select storage representation.

## 2. Retry eligibility need not automatically imply complete failed-try history

The original [retry settlement matrix](https://github.com/DivyanshGolyan/onepage/blob/d76c7350a3661da48e9d107258e3dd699f9b0aa7/VERIFICATION.md#L74-L81) retains immutable retryable Completions and future eligibility, including superseded eligibility that queries exclude through resolved Operation state.

During a retry delay, a real consumer needs the next eligible time, policy-relevant classification, consumed allowance and any retained deadline. It has no identified need for every superseded failure body or due time after success. Compare the existing model with atomic updates to current eligibility and cumulative accounting, while moving other details to diagnostics. Mutable updates can introduce hidden transition complexity; fewer rows do not select the alternative. Numeric limits and budget scope remain owned by [Choose provider retry and external-effect budgets](https://github.com/DivyanshGolyan/onepage/issues/91).

This is a representation-comparison candidate. Until that choice is made, do not remove historical facts the baseline still uses as authority.

## 3. Permanently retaining rejected unsupported output needs a consumer

The original [provider output contract](https://github.com/DivyanshGolyan/onepage/blob/d76c7350a3661da48e9d107258e3dd699f9b0aa7/ARCHITECTURE.md#L170-L172) and [ADR-0023](https://github.com/DivyanshGolyan/onepage/blob/d76c7350a3661da48e9d107258e3dd699f9b0aa7/docs/adr/0023-preserve-provider-replay-without-silent-degradation.md#L15) retain unknown consequential output as Completion evidence while forbidding semantic, continuation and effect consequences.

Compare permanent full rejected payloads with a bounded typed rejection and minimal producing-request/causal provenance, leaving raw detail in optional diagnostics. The latter loses guaranteed forensic access; no current feature permits later reinterpretation into success. This remains an explicit evidence-retention question. It does not authorize discarding unknown fields inside accepted replayable output, changing provider wire facts, or removing canonical references.

## Boundaries the audit did not justify removing

- Bash and Patch effects can survive Host death; local delivery contracts cannot prove external state.
- Accepted continuation and compaction bytes have real future-request consumers, regardless of which record owns them.
- Disposable evaluators really replay keyed operations; their original bindings and results remain authoritative.
- Admission before dispatch and custody through cleanup protect real crash/race boundaries.

## Adjacent documentation conflict

[ADR-0014](https://github.com/DivyanshGolyan/onepage/blob/d76c7350a3661da48e9d107258e3dd699f9b0aa7/docs/adr/0014-use-ephemeral-quickjs-for-workflow-evaluation.md#L5) still maps Agent Call Keys directly to Turns, while the current [workflow binding contract](https://github.com/DivyanshGolyan/onepage/blob/d76c7350a3661da48e9d107258e3dd699f9b0aa7/ARCHITECTURE.md#L249) has distinct keyed Session operations that may share a Turn outcome. This needs an amendment pointer during documentation reconciliation; it is not evidence for a different execution model.

## Follow-through

[Choose the required durable execution and recovery guarantees](https://github.com/DivyanshGolyan/onepage/issues/104) owns the accepted behavior change. [Compare complete execution models against crash and race scenarios](https://github.com/DivyanshGolyan/onepage/issues/105) owns comparison of the retry and evidence alternatives; [Choose the execution model and its verification contract](https://github.com/DivyanshGolyan/onepage/issues/106) owns the eventual representation decision. No production code was audited as an implementation of these proposed contracts.
