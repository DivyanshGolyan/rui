# Two-Session workflow — execution and recovery trace

Recorded 2026-09-10 from accepted architecture discussion. This is a design consistency walkthrough, not production evidence. The observation rule was accepted on 2026-09-09: progress can briefly lag; each evaluator receives a fixed set of recorded results. No globally atomic cross-Session report or batch API is required for correctness.

## Example

A workflow asks one Session to summarize the implementation and another to identify test gaps, then returns both answers in a structured report. It uses separate Sessions and does not rely on their relative completion time. The example follows the [accepted initialization decision](session-initialization-proposal.md): reference construction is local, and configuration is durable core work. Waiting for successful configuration is an ordinary JavaScript dependency, not identity discovery.

```javascript
// Illustrative names and return shapes, not a selected public wire schema.
const implementation = session("implementation");
const tests = session("tests");
await Promise.all([
  configureSession(implementation, config, { key: "configure-implementation" }),
  configureSession(tests, config, { key: "configure-tests" }),
]);
const results = await Promise.allSettled([
  sendMessage(implementation, "Summarize the implementation", { key: "implementation" }),
  sendMessage(tests, "Identify test gaps", { key: "tests" }),
]);
return { implementation: results[0], tests: results[1] };
```

The successful configuration path is assumed here. A configuration rejection makes the ordinary Promise.all reject, so JavaScript does not describe either message in this example. Independent branches can instead await their own configuration and send inside separate async functions. Stable rejections are not retried into success under the same key. `allSettled` lets the report contain a failure in either message result without leaving the other result unaccounted for. This example combines values in JavaScript; a model-written synthesis would be another explicit message call with its own key.

## Ownership

| Workflow coordinator saves | Session core saves |
| --- | --- |
| Run source/arguments and evaluator generations | Sessions and configuration |
| Each call's Run-local key, exact inputs and submission identity before sending | Each opaque request identity, input binding and first committed admission answer |
| Caller-scoped Session keys, admission answers, completed results and stable failures | Original message/work binding, permissions, Operation-owned current execution facts and final results |
| Fixed result visibility for each evaluator and its complete blocked set | Ongoing model/tool execution and its recovery |
| Run cancellation intent and final Run outcome | Ordinary Session-stop outcomes |

The two owners communicate through the core API. They do not share a transaction or read each other's tables. Module separation does not require two processes or two database files. Workflow copies of returned results are durable client observations used for replay, not an alternate authority over Session execution.

## Execution

1. **Create the Run and evaluate.** The evaluator constructs both Session references locally and runs until it needs configuration answers. The coordinator saves the two configuration intents before submitting either request. Full Session keys and per-call request keys are derived unambiguously in their separate namespaces from this Run's identity and author-supplied keys.
2. **Configure Sessions.** Each first-configuration transaction commits the Session, complete baseline and request answer together. The coordinator records the acceptance independently. A Session exists without a message or model work; acknowledgement requires no generated ID or provider dispatch.
3. **Replay to the messages.** A later evaluator starts from source with the recorded configuration results. References are reconstructed locally and configuration calls return their original acceptances without reapplying updates. The two message calls produce saved intents and are submitted through the same protocol.
4. **Run both Sessions.** Each core admission binds the message to its original work. The core schedules each Session normally under shared Active Capacity. Two admitted messages may execute concurrently if capacity permits; JavaScript does not retain provider connections or execute the work itself.
5. **Wait without a JavaScript heap.** The evaluator exits with its complete blocked set. The coordinator observes the accepted message requests through the core API. Notifications are hints; a missed notification cannot lose the work or its result.
6. **Record answers.** Suppose the implementation result arrives first. The coordinator records it. The test-gap result may arrive later. These observations do not need to come from one cross-Session database instant. A newly available unresolved result permits another evaluation even if the join still lacks another input; only JavaScript decides whether any branch can progress.
7. **Evaluate the join.** Before starting an evaluator, freeze which recorded results and stable failures it can see. Later arrivals are available only to a subsequent generation. Replay reconstructs the same references and returns original configuration acceptances and message results, then computes the combined report. Physical completion order does not select array positions or a winner.
8. **Save completion.** The coordinator records the final Workflow Output and terminal Run outcome together. A lost client reply does not erase the result. The Sessions remain independently reusable.

## Crash points

| Interruption | Resume behavior |
| --- | --- |
| Intent saved but never submitted | Submit the saved identity and inputs. |
| Core committed, coordinator lost the reply | Repeat the same request. Core returns its original answer, including the original Session/work binding. |
| Message accepted but no final answer yet | Observe the original bound work; do not submit a new message with a new key. |
| Core finished, coordinator did not save the result | Read that original result again and save it. A newer Turn in the Session cannot replace it. |
| Evaluator loses its heap | Abandon the interrupted evaluation and start a fresh generation from source with currently available original keyed results. Already recorded calls return their answers; unfinished submission intents are recovered separately. |
| Evaluator produced output but Run completion did not commit | Re-evaluate from recorded facts and commit the result; producing a value in memory is not saved completion. |
| Tool effect happened but its result was lost | The core applies the existing indeterminate/no-replay policy. Workflow submission retry does not replay the tool. |

No claim of exactly-once external execution follows from idempotent admission. Model replacement may incur duplicate cost; uncertain Bash/Edit effects remain uncertain.

## Cancellation

Save Run cancellation intent first and stop new evaluations and call creation. Resolve every already-saved unanswered submission by resubmitting its original identity and inputs, then record the answers. This can newly deliver work that never reached the core; its brief execution before stop is an accepted tradeoff.

Collect distinct Sessions from accepted message admissions and request ordinary Session stops. A Session configured without an accepted message is not added merely because this Run initialized or updated it. Configuration changes are not undone. Request the required stops without waiting for the first Session to finish before requesting the second. Record cancellation completion only after all saved submissions are resolved and all required stops have completed.

After a crash, an unfinished stop pass may repeat and stop newer work in a shared Session. Caller coordination remains required. Once terminal cancellation completion is saved, do not repeat the pass. A lagging progress display never establishes cancellation completion.

## Observation and permission

A progress report can observe the implementation Session before it finishes and the test Session afterward. It may therefore show a briefly outdated combination. That display is descriptive, not the input to replay or proof of cancellation completion. Permission indicators likewise reflect collected observations; an actual decision validates its exact saved request at the core.

The coordinator freezes evaluator visibility from its own recorded completed results, not live progress queries. This is why ordinary scalar observations suffice for correctness. A bounded batch API may reduce call overhead, but is an optional optimization, not a distributed snapshot mechanism.

## Continue selected Sessions in a later workflow

After this Run, an agent requests its state. The report identifies both associated Sessions and their full keys alongside context such as their local names and admitted calls. The agent chooses the testing conversation and writes its exact key into the next workflow:

```javascript
// Illustrative: paste the full Session key shown by the earlier Run’s inspection.
return await sendMessage("<exact-tests-session-key>", "Investigate the remaining gaps", {
  key: "follow-up",
});
```

Workflow Runtime uses that Session key unchanged and scopes only the new request key to the new Run. The earlier workflow need not return keys in its output, and the later workflow needs no `previousRun` argument or lookup code. This continues the Session’s current conversation and configuration, including any intervening work; it does not restore an earlier snapshot. Configuring a Session alone also makes that durable association inspectable, while unused local references do not create Sessions. The broader inspection association does not expand the message-only cancellation stop set.

## Remaining implementation evidence

Map fixed evaluator visibility to durable generation inputs without a growing resident result map; encode returned content through bounded immutable sources; test request-key recovery and dependency readiness through the real boundaries. Cover inspection followed by exact-key reuse in a fresh Run, Run-local name separation and replay stability, configuration-only associations versus message-only cancellation, both completion orders, one stable failure, late arrivals during evaluation, lost admission/result replies, no wakeup loss, cancellation with an unanswered message, and crash during the stop pass. Existing protocol prototypes cover narrower admission/cancellation models, not this complete evaluator integration.

Owning contracts: [Session API](session-core-api-contract.md), [shared identity](shared-request-identity.md), [architecture](../architecture/workflows.md#workflow-runs), [verification](../../VERIFICATION.md), and [consolidated architecture](consolidated-architecture.md).
