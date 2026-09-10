# Run inspection field-to-fact trace

## Subsequent decision — 10 September 2026

The later [independent observation and reuse contract](../design/two-session-workflow-trace.md#observation-and-permission) removes globally atomic cross-Session capture. Run-state inspection also exposes exact associated Session keys for agent-authored reuse. This earlier field/source trace retains its original evidence scope.

Publication note, 8 September 2026: subsequent [inspection ownership resolution](../adr/0024-capture-run-inspection-before-delivery.md#v1-ownership-resolution--8-september-2026) retained the single Storage Owner and complete capture without an elapsed-time abort. Questions below describe the research stage; measurements remain synthetic evidence, not production qualification.

Research, 7 September 2026. This is an input to the SQLite command-work investigation, not a selected schema, replacement wire format, or production implementation claim. It reads the current local normative documents and live discussions linked below. No normative document or tracker item was changed.

## Authority and scope

The current owners are [Run interface](../architecture/workflows.md#run-interface), [canonical relational authority](../../ARCHITECTURE.md#canonical-relational-authority), [Conversation and Turns](../../ARCHITECTURE.md#conversation-and-turns), [Workflow Runs](../architecture/workflows.md#workflow-runs), [domain definitions](../../CONTEXT.md), and [ADR-0024](../adr/0024-capture-run-inspection-before-delivery.md). [ADR-0026](../adr/0026-let-operations-own-current-execution-and-final-results.md) removes historical Attempt/Completion/Resolution entities as execution authority: each Operation owns current execution/retry facts and its optional immutable final Resolution.

[Choose the Host Runtime Run API and serialized-exchange envelopes](https://github.com/DivyanshGolyan/onepage/issues/86#issuecomment-5524720218) selected uncapped logical collections and removed obsolete handwritten schemas. Its resource-free pull language predates ADR-0024 and does not override capture-before-delivery. [Expose durable Runs through the Host Runtime API](https://github.com/DivyanshGolyan/onepage/issues/39) is superseded planning, not completed implementation. Its [selected interface comment](https://github.com/DivyanshGolyan/onepage/issues/39#issuecomment-5549471085) supports exact actionable identities and descriptor digests; its older revision-invalidation rule was subsequently superseded. [Finalize Session configuration and local client contracts](https://github.com/DivyanshGolyan/onepage/issues/101#issuecomment-5550876667) confirms shared work, original keyed results, and fresh Session observations. Exact SQL mapping and remaining wire fields are not selected by these records.

## Semantic field families and their inputs

“Field” below means a semantic fact family, not a proposed JSON property. The compiled public types and golden fixtures will own spelling, tags, omissions, nesting and integer representation.

| Required semantic family | Canonical facts to read | Work that is not inherently needed |
|---|---|---|
| Run identity and immutable binding | Run key/identity and references to its bound source, arguments, Workspace, semantics and evaluator limits | Loading source/arguments or re-evaluating the workflow |
| Captured revision | Revision read in the same transaction as report facts | Historical revision service or revision-replay scan |
| Run cancellation and terminal facts | Existing cancellation intent and terminal Run outcome, with result/failure references | Re-running cancellation, recounting all historical effects to rediscover a committed terminal outcome |
| Every Run–Turn membership summary | Exact Run-local admission/work relation; bound Turn, its Session and current classification inputs | Session's latest Turn lookup, rebinding an old admission to newer work, loading full Conversation |
| Membership terminal category and result/failure | Turn Outcome and exact output/failure references; failure provenance as defined by the Turn contract | Model-output bodies, historical physical tries or reconstructing a committed outcome |
| Membership in-flight condition | Existence of an unresolved Operation with current admitted-execution or current retry-eligibility facts | Every resolved historical Operation, historical attempt counts, Physical Custody population |
| Every actionable Permission Request | Exact request identity, Action Operation/descriptor and binding; absence of decision; unresolved Operation and applicable nonterminal/Session-stop facts | Current Permission Mode, all old decided permissions, checking whether an unrelated old Run was cancelled |
| Waiting-for-permission condition | Actionable permission plus the absence of remaining progress according to the ordinary classifier | Equating “there is a request” with “the Turn cannot progress” |
| Content references | Immutable identifiers and relevant exact binding/type facts needed by the API | Content body decoding/copying in the summary capture |
| Message application/not-applied facts | User Message's unique Conversation projection; relevant failed outcome or applicable stop/cancellation authority for unprojected messages | Replaying all Conversation/history on every poll or a new stored message phase |

The Run-interface contract expressly requires complete membership summaries and actionable permissions. The older interface planning also enumerates Run bindings, outputs, failures and content references. The precise set of message-application records included in ordinary inspection versus separate bounded reads remains a public-boundary choice; preserve separate access to unapplied content/reasons without assuming every historical admission belongs in each poll. Creation/configuration replay records are durable workflow facts, but their complete wire placement is likewise not fixed here.

## Classification is ordered

For each membership, using facts from the single read view:

1. A committed Turn Outcome gives `completed`, `failed`, or `cancelled` immediately. Terminal meaning wins even if physical cleanup remains live.
2. Otherwise, an unresolved Operation with current admitted-execution facts or current retry eligibility gives `in_flight`. An old retained attempt ordinal alone is insufficient; a final Resolution fences execution/retry even if provenance retains earlier identifiers.
3. Otherwise, an actionable Permission Request gives `waiting_for_permission` only when no other progress remains.
4. Otherwise, the nonterminal Turn is `runnable`.

These are the exact category precedence in [ARCHITECTURE.md](../architecture/workflows.md#run-interface) and [CONTEXT.md](../../CONTEXT.md). Future retry waiting is `in_flight` despite owning no live effect or Active Credit. A future retry can become due during a long report; the fixture must not silently invent a different category by treating a stored retry time solely as `retry_at > wall_clock_now`. The accepted wording distinguishes retry eligibility from admitted uncertainty; precise eligibility/time interpretation must remain consistent with admission and the shared classifier.

An actionable request needs more than `decision IS NULL`. Its Operation must remain unresolved and ordinary stop/terminal facts must permit a decision. A later change to Session Permission Mode cannot retrospectively answer an existing request or revoke an admitted Authorization. A Run Cancellation Intent fences that Run and initiates ordinary Session stops; intent alone does not invalidate all permissions through historical membership.

“No remaining progress” is the main semantic risk in a cheap fixture. An authorized, unstarted sibling Action can provide progress while another sibling waits for permission. Resolved Actions awaiting required ordered Tool Result publication can require semantic advancement. Pending User Messages alone do not prove that the next model may run: earlier tools and Tool Results must satisfy ordering and settlement rules first. Do not substitute a stored `has_progress` bit, `pending_message EXISTS`, or blanket “any unresolved Operation” test for the production classifier. A fixture may isolate explicitly named safe cases and state that it does not cover the whole classifier.

Active Capacity exhaustion does not create a seventh membership category; runnable work may wait for capacity. The driver contract separately says such work is not immediate runnable work for busy-loop scheduling. Do not collapse classification, ready-to-dispatch-now, and Run-wide progress into one boolean without checking their contracts.

## Shared Turns and repeated admissions

The accepted Session decision removes unique Run ownership of a Turn. Distinct keys from one Run can join the same Turn; different Runs can share that Turn too. Every keyed admission retains its own input and original result binding. Replaying an earlier key never follows the Session to a newer Turn.

Consequently, at least three cardinalities matter: keyed message admissions, distinct bound Turns, and returned membership records. The exact relational mapping and whether the eventual summary coalesces repeated same-Run/same-Turn bindings remain implementation/public-shape work; a unique `(run, turn)` relation cannot replace the keyed admission records. Any benchmark must explicitly say which cardinality its “members” parameter means. Joining all raw admissions to permissions can accidentally multiply the same actionable request. The eventual collection identity/deduplication must preserve all distinct admissions and all required actionable targets, rather than rely on a broad `DISTINCT` to hide an underspecified join.

## Candidate access shape to test

This is a query decomposition, not a selected schema:

1. Point-read the Run header and captured revision under the report transaction.
2. Traverse the required Run-scoped membership/admission relation in deterministic private keyset order through an index matching Run identity and position. Join its exact bound Turn by identity; never substitute Session-current occupancy.
3. For nonterminal members, make indexed existence probes into current unresolved Operation facts and actionable permissions. Candidate indexes should lead with Turn identity and discriminate unresolved/current facts so growing resolved history does not make each probe a scan. Partial indexes are one possible implementation, not semantic authority or a selected migration.
4. Apply the shared classification precedence. If a probe's candidate row requires an additional stop/applicability check, measure rejected candidates too: an index does not automatically bound work when most indexed candidates fail a later predicate.
5. Enumerate actionable request details through exact membership/work parentage. Keep all targets; prevent multiplicative joins where several keyed messages share work. Use a separate traversal if that better preserves cardinality.
6. Stream only required summary/reference bytes into scratch. Read variable content separately. End all statements and the transaction before delivery.

A full report has unavoidable work proportional to the members/permissions and bytes actually returned. That does not imply a full scan of all historical Operations or all unrelated Runs. A cheap probe selecting one active Operation per Turn proves only that one predicate, not complete report construction. Do not add materialized lifecycle counters/phases: conditions remain derived and rebuildable indexes must not become authority.

## Run headline versus complete inventory

A terminal Run outcome is already durable. Reading its terminal headline and output reference need not rediscover completion by scanning its entire membership inventory. The existing complete report nevertheless promises every membership summary; a terminal Run is not permission to omit them. A nonterminal Run-wide `permission_required` condition requires an actionable request and no member that can progress; it is not equivalent to finding one waiting Turn, nor to SQL `all(category = waiting_for_permission)` when completed members coexist.

Thus “finished Run status can be a small point read” is a useful possible observation shape, not a replacement for the accepted complete inspection API. Selecting a separate headline response, changing default polling, or changing collection completeness requires an explicit product/API decision. The immediate investigation can measure header and inventory costs separately without selecting that change.

## Minimum falsifying fixture cases

- One terminal Turn with retained current-try provenance and delayed physical cleanup still gets its terminal category.
- An unresolved admitted Operation and a retry-waiting Operation both yield `in_flight`; a never-admitted Operation does not automatically do so.
- One unresolved unanswered actionable permission with no other progress yields `waiting_for_permission`.
- An unanswered request plus an authorized unstarted sibling yields `runnable`; with an admitted sibling the precedence gives `in_flight`.
- Decision, final Operation Resolution, applicable Session stop, and terminal Turn each independently remove actionability when applicable. Permission-mode changes alone do not.
- Run cancellation intent before its ordinary Session stop does not falsely fence an old membership's Operation.
- Repeated same-Run keys and cross-Run keys share a Turn without losing admission identities, retargeting results, or multiplying permission rows unintentionally.
- Grow resolved Operation/content history and unrelated Runs with the emitted logical facts fixed; contrast growing emitted members with history per member fixed.
- Terminal headline work stays separate from full terminal inventory work; incomplete fixtures do not claim complete Run state or production certification.

See [Run inspection cost review](run-inspection-cost-review.md) for external query/measurement prior art. This trace establishes what must be preserved in a scratch experiment and which areas such an experiment cannot settle.
