# Message, Bash read and Edit — complete execution trace

Updated 2026-09-09 to reflect the accepted Session admission, whole-line Edit and shared tool recovery decisions. This replaces the earlier explanation trace's column-based preparation and keyless direct-admission assumptions. It describes the documented design, not implemented or passing production behavior. See [architecture](../architecture/execution.md#host-runtime-execution-and-settlement), [Session API](session-core-api-contract.md), [Edit](fixed-location-edit-approval.md), [transactional operations](transactional-operations.md), and [tool recovery](unified-tool-recovery.md).

## Example

The user asks: “Change the greeting in `app.txt` from hello to goodbye.” The Session already exists and uses permission mode `ask`. Bash reads the existing file, the model proposes a whole-line replacement, the user approves it, Edit runs, and the model reports the result. File creation, if needed, would be a separate model-proposed Bash command; Edit never creates a missing target.

## Who owns what

- The **Session core** owns saved messages, model inputs, tool proposals, permissions, Operation-owned current execution facts and final results. Its control context is the only owner of core SQLite access. Each meaningful change uses its own cohesive transactional function.
- The **execution loop and effect modules** own temporary provider connections, Bash processes, Edit file handles, bounded scratch and cleanup. They return observed evidence to the core; they do not write core SQLite or choose durable conversational meaning.
- The **client** submits requests, presents saved permission proposals and displays saved results. Closing the client does not end Session work.

[ADR-0026](../adr/0026-let-operations-own-current-execution-and-final-results.md) remains authoritative: “Attempt” below names the current execution try, not a durable per-try history. Execution Evidence is transient, and the Operation owns its final Resolution/content.

These are responsibilities, not mandatory separate processes or a resident worker for each Session. A Workflow Run is unnecessary for this example. A workflow would use the same core API and save its own call identities and answers independently.

## Trace

| Step | Owner and action | Saved facts | Crash or lost-reply behavior |
| --- | --- | --- | --- |
| 1. Accept the message | Client retains its request key and inputs; core admits the message. | Key/input binding and original admission answer, message and its binding to work. | A repeat with the same key and inputs returns the original committed answer. No committed admission means a repeat may admit it. Different inputs conflict. |
| 2. Ask the model | Core freezes the request inputs. With capacity available, it commits an Attempt; provider execution starts afterward. | Exact Model Request Manifest and Operation-owned current Attempt facts with consumed allowance. | A committed Attempt with no established result uses the existing bounded model replacement policy and frozen inputs; duplicate provider work or cost is possible. |
| 3. Accept the Bash proposal | Provider captures output to scratch. After completion, core validates the complete response and publishes its tool-call meaning. | Accepted model content/result and exact Bash command with permission facts required by the selected mode. | Partial scratch is not recoverable accepted output. A committed proposal remains discoverable without retaining its provider connection. |
| 4. Approve and run the read | Client presents the Bash request. Core records permission. The loop acquires capacity and commits a Bash Attempt before launching the command. | Exact Authorization and Operation-owned current Attempt facts; after completion, the Operation’s final Resolution and captured content references. | Approval without an Attempt remains eligible. An uncertain admitted Bash Attempt is never automatically rerun, even if the command appears read-only. The model can request a fresh read after receiving uncertainty. |
| 5. Ask the model again | Core makes the saved tool result available in Conversation, then admits the next frozen model request. | Tool Result Conversation entries in original call order and the next request's manifest/Attempt. | The next model request does not depend on a retained subprocess or an in-memory transcript. The existing model retry policy still applies. |
| 6. Accept the Edit proposal | Core validates the submitted shape and saves it for permission. Client displays that proposal. No target read is required here. | Existing-file path, complete list of original-coordinate whole-line ranges, expected/replacement text, and Permission Request. | Waiting resumes from these saved facts. There is no prepared target snapshot, open file handle or Edit worker retained during the permission wait. |
| 7. Approve and execute Edit | Core saves permission. When capacity is available and work is still applicable, it commits an Attempt. Edit then opens the existing target, checks every range and expected slice, and attempts the replacements. | Authorization and Operation-owned Attempt admission precede mutation. | Approval alone is not evidence of execution. Any failed target check rejects the entire call before mutation. If the process loses an admitted attempt without a known result, recovery reports indeterminate and does not replay it or require target inspection. |
| 8. Save the Edit result | Edit returns honest evidence; core imports result content and records the outcome transactionally. | Established applied/not-applied/failure evidence or indeterminate outcome, with complete referenced content. Ordered tool-result publication follows the child-settlement rule below. | A saved result survives restart. A write completed outside SQLite but not recorded before a crash is uncertain. No database rollback can undo filesystem writes. |
| 9. Finish the conversation | Core admits a subsequent model request containing the saved tool result. The model answers. Core settles the Turn under normal message-admission rules. | Accepted final answer and terminal Turn outcome. | Lost client delivery does not erase completion. Clients observe the original bound result. The Session remains reusable. |

The example uses one tool per model response. If a response contains several calls, children resolve independently. After all children resolve, one transaction publishes their Tool Result Conversation entries in original call order; the next model request starts only afterward. Completion order does not reorder Conversation. A newly admitted user message may also require further model work before terminal settlement; the example assumes none arrives.

## The concrete Edit

Suppose Bash returned numbered output equivalent to:

```text
1  title
2  hello
3  footer
```

Numbering is a presentation prefix, not file content. The model proposes range `[2,3)`, expected text `hello\n`, replacement text `goodbye\n`. The exact final newline must come from the actual file, not be inferred from this visual illustration. Numbered output may conceal that distinction; Bash can inspect bytes when necessary. A mismatch fails safely rather than normalizing the file.

The permission display says what is proposed at line 2; it does not assert the file still contains that text. After approval:

- If line 2 is still `hello\n`, the replacement is applicable.
- If line 2 changed, reject without mutation. A new model proposal requires its own permission.
- If `footer` changed but the selected range remains intact, preserve the unrelated execution-input content.
- If the file disappeared, fail without creating it.
- If mutation succeeds but its result is lost, save an indeterminate result on recovery. Even seeing `goodbye` later cannot prove which actor wrote it.

The same check covers multiple replacements: all original ranges must pass before any target mutation. It prevents partial application caused by a later bad range. It does not promise atomic writes, recovery rollback or isolation from external writers.

## Resource lifetime

Provider and Bash bytes go to charged scratch through bounded windows. After the effect reaches its terminal boundary, one shared serial workspace validates and imports the complete output. Waiting for permission retains durable facts, not active execution capacity. Approved work may still wait for capacity before Attempt admission.

An occupied fixed tracking record remains occupied until its execution resources are safely released, even if the result is already saved. On restart, temporary resources and scratch do not supply recovery authority. Core rows distinguish work never attempted, work with a known result, and uncertain attempted tools.

## What this walkthrough resolves and leaves open

The ownership and recovery flow requires no additional durable Edit stage, automatic read retry, target reconciliation or file-creation operation. The permission wait and the capacity wait are different: permission can survive without an execution Attempt; an uncertain admitted tool Attempt is never redispatched.

The [accepted physical mechanism](edit-file-writing-proposal.md) builds complete edited output in bounded chunks into charged unlinked scratch, then copies back through the same opened target handle, sets final length and flushes. All checks precede mutation. Implementing and qualifying partial-I/O handling, target handles, control responsiveness and resource accounting remains work; this trace does not claim those gates pass. Wire schemas, SQL layout and runtime integration also remain implementation work.

Required evidence is owned by [VERIFICATION.md](../../VERIFICATION.md): fresh-process crash boundaries, duplicate submission binding, permission replay, expected-text mismatch before mutation, original-coordinate multi-edit behavior, lost post-write outcomes, no automatic tool redispatch, ordered result publication and resource release. This document is a consistency walkthrough, not a substitute for those tests.
