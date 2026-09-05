# System Instruction first inclusion and recovery

> **Dated decision trace, published 6 September 2026.** The [normative architecture](../../ARCHITECTURE.md) and [product contract](../../PRODUCT.md) own the current design. Earlier signatures, issue ownership, status statements, and unselected alternatives below retain their original context; they are not a second current specification.

Status: selected mapping for appended System Instructions, 5 September 2026. This elaborates the accepted Session history and request-construction decisions in [issue 101](https://github.com/DivyanshGolyan/onepage/issues/101#issuecomment-5550876667). It is a design trace against the documented transaction contracts, not a production implementation, executed SQLite test, provider probe, or formal model-checking result.

## Durable ownership

Session Context Revisions own immutable configuration changes. Conversation System Instruction entries record instructions actually selected into model context, with source configuration/content references and causal request provenance. Model Request Manifests select those entries in their exact replay order. Reuse existing immutable instruction content and store any behavior-affecting rendering inputs needed for stable replay; do not copy whole system prompts or serialized request bodies.

The initial instruction prefix remains fixed once bound. The latest applicable System Instruction, or that initial baseline when none exists, establishes the previously applied instruction value. Derive this from canonical history and its references, including history covered by compaction; a new revision number alone does not imply changed model-visible instructions. No pending-instruction row, applied flag, Session cursor, activation queue, or separate application receipt is needed. Exact SQL columns, index definitions, and wire tags are implementation details.

## One transaction for first inclusion

Configuration commits independently and starts no model work. At the next assistant-response request admission:

1. Read current committed Session configuration and canonical execution facts under the existing semantic transaction. An already-admitted request takes its existing recovery/retry path; it is not prepared again as fresh work.
2. Require every preceding child tool action to have settled and its Tool Result to have been projected in call order. Apply eligible pending User Messages using their existing admission order.
3. Compare the selected instruction content/semantics with the last applied value. If different, prepare a new System Instruction at the next legal position after those inputs. It identifies the change as an instruction replacement/update rather than silently rewriting the initial prefix. Other settings alone do not create this entry.
4. Validate the complete prospective replay recipe, including provider placement, preserved continuation, and resource requirements. If compatible compaction is needed first, do not commit these prospective projections.
5. Commit the new System Instruction, applicable User Message projections, new model Operation, and exact Model Request Manifest atomically. The manifest contains the new entry reference. All become visible together or none do.

Any already-projected inputs from earlier transactions remain intact on rollback, including the initiating User Message and settled Tool Results. First inclusion means committed selection into model context; it is not proof that a provider received or consumed the request. No I/O occurs inside this semantic transaction.

Unchanged instruction content emits nothing. A -> B -> C before preparation emits C relative to the last applied A. A -> B -> A before preparation emits nothing. If B was already included in a request, returning to A emits another entry even when its content reference can be reused. Therefore uniqueness must not be imposed globally on a configuration revision or instruction digest.

## Boundary traces

| Scenario | Durable result and recovery |
| --- | --- |
| Configuration C commits; process exits before request preparation | C is current configuration; no System Instruction was appended. Explicit resumed work prepares from current state. |
| Preparation fails or rolls back before commit | No new instruction, pending-message projection, Operation, or manifest becomes authoritative. Independently committed configuration and earlier Conversation entries remain. |
| Request and instruction commit; acknowledgement is lost before dispatch | Recover the admitted Operation and manifest. Reuse its entry; do not append again or select later settings. |
| Attempt may have reached the provider before a crash | Existing effect-specific model recovery decides retry/uncertainty. Any replacement Attempt retains the same request and instruction position. No exactly-once billing claim follows. |
| Configuration changes after manifest commit but before dispatch | The admitted request keeps its old instruction selection. The change is eligible for the next fresh assistant-response request. |
| Configuration changes while a tool call awaits permission or completion | Record configuration only. Complete tool results first; no instruction splits a tool call/result pair. Existing permission facts are unchanged. |
| A -> B -> C before any fresh request | Only the net selected C change enters model history; B stays in configuration history. |
| Only effort, output schema, or Permission Mode changes | Do not fabricate an instruction message solely because the revision advanced. Existing provider control and Action-admission contracts govern those fields. |
| Work fails after the instruction was admitted | Keep the System Instruction as historical input. Later explicit continuation compares against that applied value; it does not erase or append it again merely because the work failed. |
| A configuration update races request preparation | SQLite commit order selects one complete view. No historical caller guard or cross-call lock is introduced. |

Failures before request admission retain the selected configuration revision and input-frontier provenance under the existing pre-request failure contract, without creating a fake model Operation or claiming that the prospective instruction was applied.

## Compaction follows existing input applicability

Before admission, predicted context pressure can cause compaction of already-applied Model Context. Unapplied instruction changes are not appended by that compaction, just as pending User Messages are not projected there. Compaction controls are frozen for that compaction Operation, but they do not make fresh conversation instructions applied. After compaction settles, the next assistant-response admission selects current Session configuration and appends its net instruction change. If configuration changed again while compaction ran, that next admission selects the latest value.

After an admitted request is rejected for overflow, its System Instruction and other projected inputs are already canonical. Compaction then includes that committed context. The following assistant-response request is a new Operation using the accepted base and complete suffix. It does not reappend an unchanged instruction. A genuinely later configuration change still produces a new entry.

Compaction never deletes Conversation entries or changes what was applied. Derive the last applied instruction from canonical source history even when the replay recipe now starts at a Compaction Base. The adapter must demonstrate that the selected base and suffix preserve the effective instruction contract; a base that loses that meaning is incompatible. Do not repair it by silently moving old instructions, rewriting the prefix, selecting an older base, dropping reasoning, or adding a duplicate instruction. If a provider requires an explicit re-establishment control after compaction, that must be a demonstrated adapter replay rule with frozen provenance, not a second application of the configuration operation.

Provider-specific tool additions and effort-update items still need their own wire/compaction compatibility fixtures. This mapping does not adopt them merely because the provider supports an appended system-text message.

## Resource and verification implications

Use bounded queries over indexed configuration and Conversation facts, immutable content references, and the existing request materialization/import workspaces. Retain no JavaScript Session object, full history buffer, or per-Session worker. Instruction count grows only when different instruction content is actually applied; canonical disk history and provider token costs remain distinct resources.

Production verification must execute every trace above against the real storage and advancement path, with fresh-process reopen, both commit orders, injected transaction failure, and provider fixtures for legal placement and compaction. Also cover A -> B -> A with and without a request under B, permission-only revision changes, a compaction-covered last instruction, configuration during compaction, and failures both before and after request admission. Document checks establish consistency only.
