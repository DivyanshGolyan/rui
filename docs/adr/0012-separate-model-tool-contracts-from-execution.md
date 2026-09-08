---
status: amended by ADR-0020, ADR-0022, and ADR-0023
---

# Separate model-tool data from execution authority

## Accepted native Edit amendment — 6 September 2026

[ADR-0027](0027-use-an-in-process-exact-edit-module.md) replaces Git-backed unified Patch with the in-process exact Edit module behind the Action adapter. The closed executable inventory is `bash` and `edit`. Preserve permissions, exact preimage/postimage intent, uncertainty and recovery; Host authority stays separate from edit mechanics. Git-specific helper/scratch requirements and old Patch names below are historical where superseded. The current [Edit contract](../../ARCHITECTURE.md#native-edit-module) and [verification](../../VERIFICATION.md#native-edit-verification) govern implementation; this is not production certification.


OnePage uses one provider-neutral Conversation and model-tool contract. Conversation contains User text, assistant text, Tool Calls, and Tool Results. One Model Request Manifest binds the provider protocol operation, requested concrete model, Instruction Set, Tool Catalog, totally ordered Model Context source identities, replay format, behavior-affecting protocol options, limits, and output contract for a model Operation. Provider adapters derive their replay input from canonical Completion-owned Model Output Items, lower the request, and convert one complete response into an assistant-only candidate or an optional assistant-text prefix with ordered Tool Calls; failures remain typed. An assistant-only candidate becomes Final Answer only when the settlement transaction proves that no earlier applicable User Message is pending; otherwise it remains ordinary assistant text. Unknown open fields inside known items are retained losslessly. Unknown consequential union variants remain Completion evidence but fail closed as `unsupported_provider_output` and publish no semantic consequence.

One model response may contain multiple Tool Calls. Complete output validation precedes atomic admission. Each call creates one child Action Operation with exact parent and call ordinal. The Tool Catalog grants no execution authority: V1 maps only `bash` and `apply_patch` through a closed Host binding, while permission, Authorization, Attempt admission, Resolution, and recovery remain separate. After every child settles, Tool Result entries append atomically in original call order before the next model Operation begins.

V1 has no model-created conversational Input Request. Later User Messages are independently admitted durable facts and become Conversation Entries only in the transaction that admits a later frozen Model Request Manifest. Model-presented choices remain ordinary assistant text; V1 adds no generic forms, runtime tool registry, plugin system, permission-through-text path, provider-owned Conversation authority, or silent fallback from missing replay material to visible Conversation.

## Accepted amendment — Operation-owned execution and results

[ADR-0026](0026-let-operations-own-current-execution-and-final-results.md) supersedes historical Attempt/Completion authority, separate Resolution identity and Completion-owned final-content bindings in this record. Operations own current execution/retry facts, immutable final Resolution values and required final content by reference. Existing effect-specific uncertainty, request freezing, accepted continuation, public replay and bounded-memory guarantees remain in force. The original text remains historical decision evidence; the current [execution contract](../../ARCHITECTURE.md#host-runtime-execution-and-settlement) and [verification requirements](../../VERIFICATION.md#operations-attempts-and-recovery) govern implementation.
