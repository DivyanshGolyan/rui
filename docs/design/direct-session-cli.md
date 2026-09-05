# Direct Session CLI: revised proposal

> **Historical design exploration, published 6 September 2026.** The [normative architecture](../../ARCHITECTURE.md) and [product contract](../../PRODUCT.md) own the current design. Earlier signatures, issue ownership, status statements, and unselected alternatives below retain their original context; they are not a second current specification.

> Subsequent design direction: keep Turns internal to ordinary caller interaction, read Session conversation entries, and use Session-level operations for workflows too. The older Turn-specific read/control examples below are still under revision; see the [Session workflow exploration](session-workflow-interface.md).

Status: proposed interface, revised 5 September 2026 after discussion with the user. No commands or wire types below are implemented. The user selected Session-addressed ordinary messaging, shell-first input, no caller-supplied idempotency keys (including optional keys), and no automatic submission retries. Command spellings, numeric identifiers, observation defaults, and control details remain recommendations. This does not resolve [Choose replay-stable Session continuation from agent results](https://github.com/DivyanshGolyan/onepage/issues/101).

Accepted local-access direction: all clients admitted through the owner's local Unix socket share access to that Store's Sessions and Runs. No per-agent Principal, Session ACL, or delegation system is selected. The Turn's ask/bypass tool policy remains separate. Historical authority language below must be collapsed to the implicit Local Owner during the full interface publication.

Accepted cancellation amendment: direct Session stops affect current work regardless of its submitting client; there is no standalone-only restriction or Run-membership-wide execution fence. Unfinished Run cancellation may repeat its Session stop pass after a crash, and callers coordinate Session reuse. Once Run cancellation completion commits, recovery does not propagate it again. The older exact-control proposal below is historical where it conflicts with this behavior. See the [accepted recovery trace](workflow-cancellation-stop-mapping.md#accepted-simplification).

## Ownership

The runtime supplies reusable Sessions and executes Turns. Workflows and the direct CLI are consumers of that capability. The direct path creates no Workflow Run or JavaScript evaluator. It uses the same admission, permissions, provider/tool execution, recovery, SQLite authority, and bounded resource machinery.

A Session is the conversation the direct caller addresses. A Turn is the episode that processes one initiating message and any later messages admitted while it remains active. A message does not necessarily create a new Turn. Turns remain useful execution and outcome records without being mandatory inputs to ordinary messaging.

## Normal shell flow

```sh
# Create a Session with its first message; return admission metadata immediately.
onepage session create "Review the retry implementation."

# Submit another message to that Session.
onepage session message 42 "Also check timeout handling."

# Pipe or redirect the entire message from stdin.
generate_message | onepage session message 42 -
onepage session message 42 - < message.txt

# Observe current work, or wait for a bounded duration.
onepage session inspect 42
onepage session wait 42 --timeout 30s

# Read the selected Turn's exact answer.
onepage session output 42
```

Input is a positional message; `-` explicitly selects stdin. Omitted text may read redirected stdin; a terminal with no input errors without opening a REPL. No task-file, prompt-file, or input-path flag is necessary. The stdin forms supply the complete message. Combining positional instructions with piped supplemental context is not selected here. Input read failures prevent submission; complete input is validated and sealed through the existing bounded ingress path.

Creation atomically creates the Session, baseline context, first Turn, initiating message, and Conversation entry. This exercise requires an initial message rather than an empty-Session creation phase. Both create and message acknowledge durable admission without waiting for an LLM answer. For example, with JSON rendering explicitly selected:

```json
{"session_id":"42","turn_id":"3","message_id":"8"}
```

These fields are illustrative admission metadata, not a final wire schema. Turn 3 is local to Session 42; no globally unique public Turn identifier or combined `42/3` string is required. The message identity distinguishes multiple messages admitted to the same Turn. Numeric IDs are server-allocated, never reused, and need not be contiguous. The caller captures returned IDs rather than predicting them. Store identity and authority checks still apply.

## Message semantics

`session message 42 ...` means send to Session 42 as it exists at admission:

- If idle, atomically create a new Turn with the message as its initiating input.
- If a Turn is active and can accept input, admit the message to that Turn. It is applied at the next model Operation requesting an assistant response; it does not alter a request already in flight or interrupt it.
- If completion races admission, serialization determines whether the message joins the existing Turn or initiates the next one. The acknowledgement identifies the result.
- If the active Turn is already fenced for cancellation or otherwise cannot accept input, reject explicitly. Do not append to cancelled work, queue a hidden future Turn, or overlap execution while cleanup is still releasing occupancy.

A complete message sent to the current Session deliberately has weaker preconditions than a replay-stable workflow continuation. The direct operation does not require an expected revision or previous Turn ID. Atomic admission still checks access, compatibility, resolved context, and occupancy. Persistent configuration changes independently of messages under the accepted Session rules. There is no temporary Turn-local settings override or separate Turn Contract; exact CLI flag spelling remains outside this historical message exercise.

## Observation and output

All three observation commands accept optional `--turn 3`. That selects Turn 3 inside the named Session, with no compound ID syntax.

Without the flag, inspect reports current Session facts, including its active Turn or most recent Turn. Wait resolves the active Turn, or otherwise the most recent Turn, once when it begins; it then observes that exact Turn until terminal outcome, actionable permission, or deadline. It does not follow new Turns indefinitely. Each result identifies the observed Turn. Passing the Turn from a message acknowledgement avoids selection races when other callers are also submitting.

Output without the flag selects the active Turn or otherwise the most recent Turn at the start of the read. It succeeds only if that selected Turn completed successfully. It must never silently fall back to an older answer when current work has no answer yet. Scripts needing the result of their own submission should name the acknowledged Turn explicitly:

```sh
onepage session wait 42 --turn 3 --timeout 30s
onepage session output 42 --turn 3
```

Wait is a bounded client-side read loop with a fixed polling delay. Timeout and client exit change no execution intent. There is no server waiter registry or retained read transaction between polls. Numeric deadlines and polling limits remain with the existing resource-budget decisions.

Inspection includes exact actionable requests and terminal outcome facts, not all Conversation history on every poll. Complete reports use the accepted capture-before-delivery machinery and detect incomplete transfers. Output reads immutable answer bytes through bounded windows, preserving exact text or user-schema content. Metadata stays outside model output. Structured output and Markdown rendering use the same facts; final field names, exit codes, and report framing belong to the compiled CLI/wire contract.

## Historical exact-control proposal

Ordinary messaging names only the Session. Commands whose intent targets one specific pending action retain that target:

```sh
onepage session permission 42 --request 7 --decision allow_once --descriptor-digest DIGEST
onepage session cancel 42 --turn 3
onepage session interrupt 42 --turn 3 --operation OPERATION_ID
```

Permission targets the exact immutable request and Action descriptor. Cancel targets one Turn; a delayed command cannot cancel a later Turn merely because it shares the Session. Cancellation does not make the Session terminal. Model interruption targets one unresolved model Operation and retains its narrower existing meaning; it is not a synonym for cancelling a Turn.

These controls introduce no caller-supplied request key. Domain uniqueness still applies, such as one Permission Decision per request. Their precise repeat/conflict responses must be specified without confusing those rules with duplicate prevention for message submission.

Standalone cancellation needs a durable Turn-level fence, with the same effect-specific settlement discipline as existing Run cancellation. It cannot claim that external work physically stopped merely because intent committed. The minimal proposal restricts direct cancellation to standalone Turns; workflow Run cancellation keeps its own relational membership fence. Access to another consumer's Session must not silently grant authority over that consumer's Run or Turns. Cross-consumer control policy remains explicit work before implementation.

## Lost responses and replay

There is no direct request key, optional key, caller-selected Turn ID, or automatic mutation retry. Repeating create can create another Session. Repeating message can admit another message, possibly into the active Turn or a later Turn. A lost response is an uncertain outcome; content similarity is not used to deduplicate. Inspection can aid investigation but does not guarantee reconciliation when the original admission identifiers were never received.

Workflow Agent Call Keys remain part of durable workflow replay. Re-evaluation must reattach to its original Turns and use historical continuation facts. The workflow path must not implement replay by repeatedly invoking the weaker Session-current message operation. Both consumers share lower-level atomic primitives while retaining their distinct admission contracts.

## Memory and unresolved work

Dormant Sessions and terminal Turns are durable records, not resident conversation objects or workers. Active effects use the existing capacities, transport windows, and scratch accounting. The CLI streams input/output and retains bounded metadata; a waiting process lives only for its selected deadline. Repeated polling has a real capture/query cost to measure. No numerical footprint claim is made here.

Required follow-through includes direct Session/message admission and authority, Turn-scoped inspection and cancellation, message targeting at completion/cancellation boundaries, failure with acknowledged unconsumed messages, and workflow continuation/result shape. [Choose terminal failure semantics for pending User Messages](https://github.com/DivyanshGolyan/onepage/issues/102) remains open. Ordinary messaging does not by itself settle failure recovery or pending-message applicability.

The main implementation owners remain [Expose durable Runs through the Host Runtime API](https://github.com/DivyanshGolyan/onepage/issues/39), [Replace terminal Sessions and Jobs with relational Sessions, Turns, and Operations](https://github.com/DivyanshGolyan/onepage/issues/52), [Version model-visible Session context and bind exact model requests](https://github.com/DivyanshGolyan/onepage/issues/59), and [Add durable Permission Requests and Decisions](https://github.com/DivyanshGolyan/onepage/issues/38). The product, glossary, architecture, and verification documents need coordinated amendments after interface selection. No issue was closed by this proposal.

Earlier [Turn-first](direct-session-cli-options/a-session-turn-operations.md), [submit-and-wait](direct-session-cli-options/b-submit-and-wait.md), and [Direct Run](direct-session-cli-options/c-direct-run.md) designs are retained as historical alternatives. Their mandatory direct keys and exact-predecessor submission examples are superseded by this discussion, not alternative accepted features.
