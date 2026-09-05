# Pending messages after terminal failure or stop

> **Dated decision trace, published 6 September 2026.** The [normative architecture](../../ARCHITECTURE.md) and [product contract](../../PRODUCT.md) own the current design. Earlier signatures, issue ownership, status statements, and unselected alternatives below retain their original context; they are not a second current specification.

Status: accepted pending-message contract, 5 September 2026. The [published resolution](https://github.com/DivyanshGolyan/onepage/issues/102#issuecomment-5550577434) closes the architectural decision and assigns implementation work to its owners. The owning normative documents have been amended locally; they and the research artifacts remain uncommitted. Production implementation and the separate Session-continuation/cancellation-targeting decisions are not completed by this acceptance.

## User-visible behavior

Suppose a Session is reviewing code. A caller sends “Also check security,” then the current work definitively fails or is stopped before that message is projected into model context.

The message remains an inspectable admission with its original content and provenance. It is reported as **not applied**, with the failure or stop that made it inapplicable. Sending another message after the Session becomes available does not silently apply the excluded instruction. The caller may explicitly submit its content again as a new message.

No caller-provided idempotency key or Turn ID is introduced. Existing workflow replay keys still recover the original admission and its historical outcome; replaying failed work does not turn that same key into a new submission.

## Applicability and the terminal boundary

For the covered failure boundaries, the existing failed Turn Outcome is sufficient authority: its insertion makes remaining unprojected messages inapplicable and releases logical Session occupancy atomically. The failure classifier requires a definitive inability to continue and no other unresolved semantic obligations. It may insert that outcome despite pending messages; requiring their prior inapplicability would be circular. Successful settlement retains its stricter pending-input check.

A pre-request `ResourceExceeded` belongs directly in the Turn Outcome's typed failure payload; it needs no fake Model Operation, Attempt, Completion, or manifest. A terminal failure established by an Operation references that Turn's existing accepted Resolution rather than copying provider evidence. Tool errors, retryable results, recoverable overflow, and direct interruption do not automatically fail their Turn.

No separate early failure intent is selected. If other admitted effects can still change meaning, retain their canonical obligations and use existing settlement/reconciliation rules; do not release occupancy by declaring failure prematurely. Cancellation separately retains its committed intent while effects drain. Physical cleanup and credit release retain their effect-specific owners.

The [relational mapping and executable SQL fixture](../../research/session-failure-mapping/README.md) give the causal forms, classifier boundary, derived applicability query, owner changes, and limits. Exact columns and native type spelling remain implementation work under the relational redesign. The earlier model's generic failure fence is not a requirement to add a new durable entity.

## Message admission races

| Commit order | Result |
| --- | --- |
| Message admission precedes the failure/stop decision | It belongs to the old work. If still unprojected at the decision, it becomes inapplicable there. |
| Cancellation intent precedes admission, while old work still occupies the Session | Reject admission; do not append it to a hidden queue for later work. Ordinary failure uses the atomic outcome/release boundary instead. |
| Terminal outcome and occupancy release precede admission | Ordinary Session messaging admits the new message into new work. |

A message already projected before the decision retains that fact. It must not be relabeled unprocessed simply because its request failed.

## Truthful inspection and later context

| Recorded facts | Meaning |
| --- | --- |
| Admission exists, no projection, work still accepts it | Pending application. |
| Admission exists, no projection, terminal failure/stop makes it inapplicable | Not applied, with the causal reason. |
| Projection exists | Applied to Conversation/model context; provider consumption is not implied. |

These are derived descriptions, not a selected wire enum or a new message phase. Inspection must expose admitted-but-unapplied content even though it has no Conversation Entry. Ordinary conversation reads alone cannot serve as its audit surface. Counts, reasons, and bounded access to the exact content should use the existing inspection/read machinery.

Later model requests use the legal existing context plus newly applicable messages. They do not rebuild context by indiscriminately loading all admitted messages for the Session. Previously projected context remains governed by normal provider replay and compaction rules, including uncertainty when transport failed.

## Late completion and crash

Completion acceptance checks the authoritative operation/attempt binding, existing Resolution/Turn Outcome, and applicable cancellation intent in the same transaction that applies its result. A committed failed outcome or winning stop intent prevents later results from modifying outcomes or causing further work. If result acceptance wins first, its committed facts remain valid; a later stop governs remaining work. Physical detachment is not proof that remote execution or billing stopped.

A server crash is neither a failure disposition nor a stop. Admissions, projections, and committed outcomes survive. Server restart alone does not imply renewed provider work. Explicit resumption follows effect-specific recovery; it cannot clear a previously committed terminal failure/stop or revive its excluded input.

## Evidence and remaining integration

The [model and counterexamples](../../research/session-terminal-model/README.md) cover failure/stop with pending messages, continuation, cleanup, late provider success, and crash/restart/resume. Corrected safety and conditional-progress configurations pass 29,144 reachable states. The study remains bounded and does not validate SQL implementation, tool effects, or all provider recovery modes.

The local [mapping](../../research/session-failure-mapping/README.md#contract-changes-prepared-for-owning-issues) now assigns causal failure and applicability changes to Session/Turn storage, context construction, compaction admission, and inspection. Those owner amendments are published, and [Choose terminal failure semantics for pending User Messages](https://github.com/DivyanshGolyan/onepage/issues/102) is closed as a design decision. Its production implementation obligations remain open. Exact cancellation command targeting remains separate from the pending-message rule. The related interface decision remains open as well.
