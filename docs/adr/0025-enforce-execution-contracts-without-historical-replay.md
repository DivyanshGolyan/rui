---
status: accepted
---

# Enforce execution contracts without historical result replay

The single Host and its adapters own live execution, so internal result delivery must be at most once and cease after delivery or detachment. Permanent failed-try diagnostics and exact historical Completion replay/conflict discrimination are not V1 guarantees: persist facts needed for recovery or a concrete product promise, and keep other failure detail as optional diagnostics. This trades complete failed-try investigation for a smaller required contract while preserving external-effect uncertainty, consumed retry allowances, exact authorization, accepted output/continuation and public command replay.

This amends ADR-0021's historical Completion replay promise. The [behavior matrix](../architecture/execution.md#required-execution-and-recovery-guarantees) and [verification requirements](../verification/execution.md#operations-attempts-and-recovery) define the scope; the existing per-try representation remains the baseline until the execution-model comparison and selection resolve. No table deletion, output-ownership change or retention mechanism is selected here.

Decision: [Choose the required durable execution and recovery guarantees](https://github.com/DivyanshGolyan/onepage/issues/104).

## Accepted amendment — bounded local diagnostics

The [execution-model comparison discussion](https://github.com/DivyanshGolyan/onepage/issues/105) accepts local diagnostic summaries on by default, bounded retention across ordinary restarts, explicit bounded detailed capture and user-controlled diagnostic export. Optional diagnostics means optional to recovery, not disabled by default. Diagnostic loss can reduce investigability but cannot change execution or accepted meaning. Full rejected provider payloads need not remain canonical when typed rejection and necessary producing-request/causal facts preserve the failure meaning; accepted continuation and all other canonical consumers remain protected. Reproduction with detailed capture may be necessary when raw rejected bytes are absent.

The [local diagnostic contract](../../ARCHITECTURE.md#local-diagnostics-and-application-state) and [verification requirements](../../VERIFICATION.md#local-diagnostics) own this amendment. It selects no execution representation, storage layout or numeric budget. Application-state retention remains deferred.

## Accepted amendment — Operation-owned execution and results

[ADR-0026](0026-let-operations-own-current-execution-and-final-results.md) supersedes this record’s per-try authority and final-content ownership. Use the current [execution contract](../architecture/execution.md) and [verification](../verification/execution.md); retain the original wording as history.