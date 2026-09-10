# Session identity before durable creation: actor prior art

Research, 2026-09-10. These are comparisons and design questions, not an accepted OnePage API. No production implementation was changed.

## What the examples establish

An address can exist before executing work or saving application state. Orleans and Cloudflare Durable Objects demonstrate this separation. Neither implies that OnePage needs virtual actors, remote proxies, or an empty durable Session. Neither supplies OnePage's first-message admission and replay contract automatically.

Keep three events distinct:

1. **Naming:** obtain an identity that callers can refer to.
2. **Activation:** allocate temporary machinery to handle a call.
3. **Business initialization:** accept configuration and establish durable application facts.

For OnePage, a configured JavaScript declaration could also be ordinary data without selecting a durable identity. That is a fourth possibility, separate from the actor-address pattern.

## Orleans: logical identity precedes execution and persistence

`GetGrain<T>(key)` returns a proxy containing grain type and key. Multiple references can name the same grain; a reference survives changes in placement and restarts. The virtual actor model treats the logical actor as always addressable, while the runtime instantiates it when needed and removes unused instances from memory. [Grain references](https://learn.microsoft.com/en-us/dotnet/orleans/grains/grain-references), [Orleans overview](https://learn.microsoft.com/en-us/dotnet/orleans/overview#the-actor-model).

Persistence is separate. State loads during activation, but application code explicitly calls `WriteStateAsync` to save modifications. A failure reading initial state fails activation and faults the initiating call. Obtaining a reference therefore establishes neither successful activation nor a successful business operation. [Grain persistence](https://learn.microsoft.com/en-us/dotnet/orleans/grains/grain-persistence/).

By default, one request runs through completion before another starts on the activation; reentrancy changes this. This supplies a place to serialize an application's initialization check, but doesn't decide what two callers with different initial configurations should mean. [Request scheduling](https://learn.microsoft.com/en-us/dotnet/orleans/grains/request-scheduling).

This is particularly weak prior art for durable request replay: Orleans documents that retries may deliver a message multiple times and that it does not durably remember delivered messages to suppress duplicates. OnePage's keyed original-answer recovery must remain its own contract. [Messaging delivery guarantees](https://learn.microsoft.com/en-us/dotnet/orleans/implementation/messaging-delivery-guarantees).

## Cloudflare: constructing a stub has no remote effect

`getByName("reviewer")` returns a client stub immediately. Cloudflare explicitly says constructing the stub sends no request and does not instantiate the Durable Object. Invoking a method starts the lifecycle; an inactive object's constructor runs before the invoked method. [Namespace API](https://developers.cloudflare.com/durable-objects/api/namespace/), [Lifecycle](https://developers.cloudflare.com/durable-objects/concepts/durable-object-lifecycle/).

This is a concrete precedent for declaring something callable before doing work. It is not evidence that merely starting an object commits a chat record: persistent application data uses the separate storage API, and in-memory state can disappear on restart. [Storage](https://developers.cloudflare.com/durable-objects/best-practices/access-durable-objects-storage/).

Initialization still has explicit concurrency machinery. `blockConcurrencyWhile` can hold incoming events until asynchronous constructor initialization finishes. An uncaught callback failure resets the object. That mechanism protects initialization execution; it does not itself specify application-level configuration conflicts or atomic message admission. [State API](https://developers.cloudflare.com/durable-objects/api/state/#blockconcurrencywhile).

Calls through the same stub have delivery ordering. Different stubs have no ordering guarantee between them, and a stub exception causes its outstanding and later calls to fail; continuing requires a new stub. Copying its surface would therefore import more than ordinary Promise composition. [Stub API](https://developers.cloudflare.com/durable-objects/api/stub/).

## Apply the guidance through concrete cases

These are OnePage inferences, not guarantees supplied by the researched systems.

| Case | Smallest question to settle |
| --- | --- |
| Declare a reviewer but never use it | Does a caller need a durable artifact? If no, keep the declaration as ordinary data. |
| Start a review, then ask a follow-up | Can the first submission return the real Session ID with its answer, allowing ordinary Promise sequencing? If yes, an actor-style address is unnecessary. |
| Two branches must target the same Session before either submission resolves | This requires an identity available before either answer, or an explicit dependency establishing the ID first. A shared config object alone doesn't resolve it. |
| First submission commits, reply disappears | Retry the same request identity and recover the original Session ID and admission. An address alone doesn't prevent duplicate messages. |
| Two first submissions supply different configuration for one identity | Decide whether the second conflicts, uses existing configuration, or is an explicit update. Lazy activation does not answer this. |
| First message is rejected | Decide whether no Session exists, a rejected request record exists without a Session, or an empty Session remains. Those are product and transaction choices. |
| A caller wants to save/share a configured conversation before sending | This is a concrete reason for durable empty creation if the product actually promises it. |

For the currently discussed sequential workflow, first try **ordinary Session declaration data plus one start-with-message operation that returns a real ID**. JavaScript can compose later calls from that result, accepting an additional evaluation where required. This removes the separate empty creation operation without needing a special reference that the Workflow Runtime resolves.

Consider a preassigned address only when a demonstrated caller needs to name the same future Session independently before the first response. If selected, make that one core identity rule usable by every caller; specify its scope, conflicts and retry behavior. Do not hide it as a special DAG-writer dependency protocol.

Combining Session initialization and first-message admission into one transaction may be appropriate, but it needs direct OnePage evidence: concurrent first calls, rejected admission, conflicting configuration, and crash after commit before reply. The actor examples motivate separating naming from effects; they do not prove that transaction.
