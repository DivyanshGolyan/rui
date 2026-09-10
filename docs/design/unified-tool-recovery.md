# Unified tool recovery

Accepted in architecture discussion on 2026-09-08. This is a documented design amendment, not an implementation or runtime-verification claim.

## Decision

OnePage never automatically replays a tool action that may have started. If its outcome cannot be established, OnePage saves an indeterminate Tool Result and lets the Agent investigate. Bash and Edit share this policy. Known failures and successes retain their precise evidence; uncertainty is not fabricated failure or success.

Restart recovery does not inspect the Edit target or compare it with the saved preimage or expected postimage as a required recovery step. The Agent may inspect current external state through ordinary tools and propose a fresh action under ordinary permission rules. Current bytes cannot prove what the interrupted action did. Uncertainty alone does not force User intervention or terminate the Turn.

Exact intended changes, permission binding and target revalidation before mutation remain required. This decision does not remove preparation data needed for those obligations, permit retargeting old authorization, or weaken safe execution and cleanup while the process retains custody. Model requests retain their separate bounded replacement-attempt policy.

## Reason

Automatic Edit reconciliation supplied richer observations but still could not establish who produced the observed file state. Letting the Agent choose the investigation removes a mandatory tool-specific restart path while retaining honest outcomes and the prohibition on automatic repeated effects.

## Authority and evidence

[Architecture](../architecture/execution.md#effect-specific-recovery), [product guarantees](../../PRODUCT.md#product-guarantees) and [verification](../../VERIFICATION.md) own the current contract. This amends the post-crash inspection requirements in ADR-0003, ADR-0004 and ADR-0021; their original text remains historical evidence. Older architecture candidates and research are not selected contracts.

Required evidence includes fresh-process reopen of uncertain Bash and Edit attempts, no redispatch, no required Edit target access, an indeterminate Tool Result, and continuation through a model-selected investigation. Exercise unchanged, expected-result, divergent, missing and unreadable targets. Retain before-mutation authorization and identity checks. Documentation checks do not establish these production guarantees.
