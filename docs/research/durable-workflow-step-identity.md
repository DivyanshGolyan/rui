# Durable workflow step identity: industry prior art

Research checked 7 September 2026. This is decision evidence, not an accepted contract amendment or production verification. Scope: whether workflow authors must name durable Session calls, or OnePage can derive their identity automatically.

## Finding

Durable execution requires repeatable identification of an operation occurrence. It does **not** universally require a caller-written key. Temporal, Restate and DBOS demonstrate automatic identity; Inngest and Cloudflare demonstrate explicit names. These choices come with different replay and concurrency contracts.

For OnePage's current disposable evaluator, broad async composition and complete-result snapshots, retaining explicit keys at durable Session calls has a concrete justification: it avoids adding historical promise-delivery replay or constraining concurrent workflow code. This is a conditional design recommendation, not proof that automatic identity is inherently difficult or undesirable. A narrower sequential/fixed-batch workflow language would change the tradeoff.

The key belongs to each durable Session creation, configuration change or message submission. It does not label every JavaScript statement, helper call, loop or pure calculation. A Run Key separately deduplicates submission of the entire workflow. Session identity separately chooses the conversation. These are distinct scopes in [the domain model](../../CONTEXT.md#workflows-and-runs).

## What established systems do

| System | Operation identity and replay | What OnePage would need to account for |
| --- | --- | --- |
| Temporal | TypeScript Activity IDs default to an incremental sequence number. Replay compares generated commands with the corresponding events in ordered history. Callers need not invent an ID for every Activity. [Activity options](https://typescript.temporal.io/api/interfaces/common.ActivityOptions#activityid), [workflow determinism](https://docs.temporal.io/workflow-definition#deterministic-constraints). | The ordering guarantee belongs to the history/replay system. Copying the sequence counter into a snapshot evaluator does not copy that guarantee. |
| Restate | TypeScript `ctx.run` supports an unnamed callback. Operations are journaled; replay compatibility checks detect changed journal operations. Its `RestatePromise` concurrency combinators record completion order. [Durable steps](https://docs.restate.dev/develop/ts/durable-steps), [concurrent tasks](https://docs.restate.dev/develop/ts/concurrent-tasks), [versioning](https://docs.restate.dev/services/versioning). | Automatic matching is accompanied by journal semantics and durable concurrency primitives. It is not simply immediate lookup of all completed outputs. |
| DBOS | A step's `function_id` increases from zero in execution order. TypeScript workflows must initiate steps in deterministic order; docs permit a fixed parallel batch but prohibit interleaving sequential branches, recommending child workflows for that shape. [System tables](https://docs.dbos.dev/explanations/system-tables), [workflow concurrency](https://docs.dbos.dev/typescript/tutorials/workflow-tutorial#running-steps-in-parallel). | This is a direct precedent for simple automatic numbering **with restrictions**. It would require narrowing OnePage's supported composition or introducing isolated branch/child identities. |
| Inngest | `step.run(id, handler)` requires an author-supplied ID used for memoization across function versions. Results are persisted and injected when the function re-enters. The SDK specification also describes completion-stack ordering for memoization; explicit names do not replace every scheduling rule. [Step API](https://www.inngest.com/docs/reference/typescript/v4/functions/step-run), [execution model](https://www.inngest.com/docs/learn/how-functions-are-executed), [SDK specification, section 5.4](https://github.com/inngest/inngest/blob/main/docs/SDK_SPEC.md). | Explicit durable-call names are established prior art, including in a function-reexecution model. Do not infer unrestricted replay safety merely from having names. |
| Cloudflare Workflows | `step.do` requires a deterministic name, which participates in cached state identity. The runtime tracks the occurrence count for repeated names; its restart API disambiguates with name, count and step type. [Rules](https://developers.cloudflare.com/workflows/build/rules-of-workflows/), [Workers API](https://developers.cloudflare.com/workflows/build/workers-api/). | This is a hybrid, not a requirement that every occurrence have a globally unique handwritten name. A per-name counter still needs a stable order among uses of that same name. |

## Why a counter is not a drop-in replacement here

The existing [call-order experiment](../../research/workflow-call-order/README.md) and [native verification](../../research/workflow-call-order/native-verification.md) isolate the problem:

1. Two concurrent branches first request A and B. A blocks its branch.
2. Both results become available before reevaluation.
3. Replay fulfills A immediately, so that branch reaches C before the other branch reaches B.
4. The first evaluation's order is A, B; replay's order is A, C, B.

Ordinal 2 changes meaning from B to C. Complete-input validation would reject the collision; without it, lookup could return the wrong answer. Neither is successful recovery. The historical native fixture intentionally bypassed Host binding validation: it is not evidence that the production Host silently misroutes outputs.

This counterexample uses unchanged source, immutable results, ordinary microtasks and `Promise.all`; it needs neither `race`/`any` nor physical completion-order differences. The parent investigation reran the Node probe on 7 September and reproduced A, B → A, C, B. The native result remains evidence from its recorded existing binary, not a fresh build.

Temporal's event history and Restate's recorded completion order illustrate the alternative: replay more than final answers. DBOS illustrates another alternative: restrict the ordering patterns authors may express. Neither proves that OnePage needs their full architecture; both show what a proposal for automatic numbering must actually specify.

## Alternatives against concrete cases

The following analysis is OnePage-specific inference, not a claim about undocumented internals of the products above.

| Identity proposal | Sequential loops and identical requests | Concurrent helpers and joins | Assessment |
| --- | --- | --- | --- |
| Hash the operation and its inputs | Two intentional identical messages collapse into one operation. An occurrence discriminator is still needed. | Identical parallel requests have the same problem. | Useful for binding validation, insufficient as occurrence identity. |
| Source line, call-site ID or function name | A loop or repeatedly called helper executes the same code location many times. | Multiple branches can share a helper and its call site. | Static code identity alone is insufficient. Source transforms could add dynamic context, but that is a separate design to prove. |
| One global invocation counter | Works if durable-call initiation order is stable. Repeated identical calls remain distinct. | Fails the existing A, B → A, C, B example. | Smallest automatic option only after a suitable language/replay restriction. |
| Static call-site ID plus occurrence counter | Distinguishes sequential repetitions at that site. | Repeated use of the same helper site by concurrent branches can reorder occurrences. | Better than a global counter, but not a general solution without branch context or scheduling rules. |
| Explicit per-occurrence key | Loop index or stable item identity distinguishes repetitions; two intentional identical sends use different keys. | Branch-specific keys keep A, B and C distinct when their encounter order changes. | Fits the existing keyed lookup model. Authors must maintain uniqueness and stable bindings. |
| Historical visibility/promise-delivery replay | Can preserve the original operation initiation sequence. | Must reproduce when earlier promises settle relative to microtasks and branch continuations. | Viable automatic-identity direction, with additional durable replay facts and evaluator behavior to design and bound. |

An explicit key must remain bound to the complete operation input: operation kind, target Session where applicable and supplied content/configuration. Reusing a key with different inputs must fail rather than quietly return an unrelated result. Distinct keys may intentionally carry identical inputs. Keys do not make nondeterministic branching safe or authorize arbitrary external effects during replay.

## Code changes, inputs and effects

Temporal limits edits that alter command sequence and provides versioning/patching; its docs explicitly allow some argument changes without a replay mismatch. Restate lists changed operation inputs and reordered/added/removed SDK operations as journal-compatibility hazards. These systems therefore do not establish a universal rule that every engine verifies every input identically. [Temporal workflow changes](https://docs.temporal.io/workflow-definition#code-changes-can-cause-non-deterministic-behavior), [Restate versioning](https://docs.restate.dev/services/versioning).

OnePage's immutable source/argument binding per Run removes in-place code migration from this choice. It does not remove the promise-order counterexample. A new source or argument set is a different workflow submission under the applicable Run binding rules; the same internal call key should not be used to smuggle changed operation inputs into an existing binding.

Durable lookup identity is also not a guarantee of exactly one physical external effect. A provider/tool can act before its result is committed. That uncertainty needs the existing effect-specific recovery contract; changing caller-written IDs to generated IDs does not solve it. Cloudflare explicitly advises idempotent step effects because steps can be retried. [Workflow rules](https://developers.cloudflare.com/workflows/build/rules-of-workflows/).

## Recommendation for the current decision

Keep one stable explicit key per durable Session call while retaining the current async snapshot evaluator. Agent-authored workflows can provide short literals or deterministic item/branch keys, so the authoring cost appears lower than introducing scheduling history solely to remove an argument. This is a design judgment, not a measured complexity result.

Do not add a general-purpose `step` wrapper around pure JavaScript. Do not add source parsing, compiler transforms or a second automatic-key mode merely for apparent convenience. If callers later need keyless durable calls, compare a deliberately restricted fixed-batch language against bounded historical promise-delivery replay, with the existing counterexample as a required acceptance case.

No normative documents, production source or tracker resolutions are changed by this note. The human decision remains open.
