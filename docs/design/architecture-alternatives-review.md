# Architecture alternatives — discussion sketches

Decision: [Compare complete architecture designs for OnePage](https://github.com/DivyanshGolyan/onepage/issues/119).

Status: historical, unselected alternatives. Later accepted simplifications are consolidated in [the current candidate](consolidated-architecture.md); the earlier sketches below retain their original assumptions for comparison. These are illustrative native interfaces and scenario traces, not compilable scaffolding, measured implementations, or passing recovery evidence. The accepted root-checkout amendments and the consumer/platform resolutions define behavior. Historical source is not a constraint on the new module graph.

## Common behavior

Direct clients use reusable Sessions. Workflows compose keyed Session operations and original results. OnePage owns exact permissions, immutable request inputs/results, effect-specific recovery and bounded execution. SQLite remains canonical; dormant populations retain no resident Session graph. Logical cancellation can precede physical cleanup. Uncertain Bash is not automatically replayed; Edit reconciles exact pre/postimages; provider replacement retains frozen continuation and records possible duplicate cost.

Local clients retain the explicitly started server, Store-relative identity, ordinary observation and lost-acknowledgement rules. Linux/macOS mechanisms follow the accepted platform decision. Native embedding and Durable Objects test coupling; neither requires a delivered adapter. No alternative below intentionally changes a product promise.

## A. Integrated runtime with private implementation modules

One Runtime is the primary reusable capability. It owns SQLite access, scheduling, providers, tools, workflow evaluation and physical cleanup. Internally it delegates parsing, Edit mechanics and transport, but callers receive the assembled runtime.

```text
CLI / local HTTP / deterministic fixture
                  |
                Runtime
          /        |
     SQLite    provider     tools/evaluator
```

Illustrative interface (pseudocode, not an API commitment):

```zig
runtime = Runtime.open(store_location, platform_services, limits);
receipt = runtime.submit(session_command);
view = runtime.inspect(query, output_sink);
runtime.service_ready_events(); // called by OnePage's local driver
runtime.shutdown();
```

The caller knows runtime lifetime, Store selection, input/observation and permission controls. It does not understand admissions, SQL or effect dispatch. The native local driver supplies event readiness; ordinary CLI clients never drive this loop. Runtime borrows output sinks for bounded reads and owns active handles until cleanup finishes.

Storage mechanics can remain deep inside Runtime. Tests substitute actual varying platform effects at private interfaces. A future Durable Object port must adapt storage, driving and tool mechanics inside this module; its public interface alone does not establish portability.

Strength: minimal public composition and one obvious owner of invariants. Risk: platform assumptions can spread through its implementation unless private responsibilities remain disciplined. Independent lower-level reuse is possible only where a real implementation module already earns that interface.

## B. Transactional core with execution adapters

A Core owns the meaning and durable transition of Sessions, Operations and Runs. A Driver owns temporary execution resources and advances the Core through bounded service turns. Storage access is an explicit dependency of Core, while provider/tool/evaluator adapters implement physical work. The assembled Runtime still gives ordinary callers one small interface.

```text
CLI / HTTP / workflow result consumer
                  |
             Runtime facade
              /
     Transactional Core  Driver
              |          |
       Storage access   provider tools/evaluator
```

Illustrative interfaces:

```zig
receipt = core.submit(command); // validates and commits semantic admission
reservation = driver.reserve_capacity();
work = core.admit_next(reservation); // bounded descriptor, commit before dispatch
// No work / rollback returns the reservation; no durable slot table.
driver.start(work);
core.accept_evidence(work.attempt_id, evidence_reader);
driver.release_after_cleanup(work.attempt_id);
```

The facade hides this choreography from application consumers. The implementation contract must make commit success precede start, reject stale identities, and keep reservation ownership explicit on every error path. Core can invoke provider-specific request interpretation/validation as needed; a generic storage adapter must not absorb Session policy.

Core hides SQL transitions, exact binding checks, retries, cancellation applicability and immutable outcomes. Driver hides event-loop mechanics, bounded custody and cancellation/reaping. Adapters hide protocol or OS mechanics, not policy. Provider interpretation preserves exact replay material; model-visible context selection remains OnePage policy.

Storage access must expose the transactions and bounded queries the core actually needs. Do not reduce it to unrelated get/put calls or build a universal database framework. Large content crosses borrowed readers/sinks or immutable references, not returned whole-object graphs.

Strength: explicitly separates durable meaning from temporary execution and platform services. A future native or Durable Object assembly has clear replacement points. Risk: admission/reservation/commit/dispatch ordering becomes a cross-module contract. Too many tiny calls would force Driver to understand the whole domain; that would defeat the design.

## C. Pure decision engine with an imperative host

A Decision Engine receives a bounded snapshot of facts and a triggering event, then returns a plan. A Host performs transactional validation/writes and physical effects. The engine performs no I/O.

```text
clients / native events
           |
          Host ---- SQLite / physical adapters
           |
     Decision Engine
       facts -> plan
```

Illustrative interfaces:

```zig
facts = host.read_bounded_facts(trigger);
plan = engine.decide(facts, trigger);
committed = host.commit_if_current(plan);
if (committed) host.dispatch_admitted_effects(plan);
```

Plans are bounded, transient and tied to exact preconditions. They are neither a durable event ledger nor a second recovery authority. Host discards/recomputes stale plans. Output references do not become valid until publication commits. Physical capacity must be reserved before admitting work, with error paths returning unused reservations.

The engine hides policy decisions and can run without OS dependencies. Host must understand the plan vocabulary, transactional application, retries after conflicts, content ownership, capacity and physical work. It therefore carries a larger correctness contract than either ordinary callers or adapters in B.

Strength: pure policy testing and an easy conceptual compilation target for Wasm. Risk: facts and plans duplicate the representation of durable transitions, or pull SQL-dependent invariants out of their strongest enforcement point. Keeping snapshots bounded can require many planning rounds and a substantial interpreter in Host. SQLite remains authority, so replaying pure decisions is not a substitute for database/effect recovery tests.

## Same scenarios through all three

| Scenario | A: integrated | B: transactional core | C: pure engine |
| --- | --- | --- | --- |
| Direct message and permissioned effect | Runtime commits message, advances model, commits exact permission request, and dispatches only authorized work. | Core owns message/permission/authorization commits; Driver executes only Core-admitted descriptors. | Engine proposes the admission; Host validates current facts and atomically commits exact authorization before execution. |
| Workflow fan-out/fan-in and sequential reuse | Runtime evaluates a bounded generation and admits keyed operations using original results. | Workflow evaluation adapter reports requests; Core validates/adopts them and owns saved original results; Driver owns evaluator lifetime. | Engine plans keyed admissions and dependencies from the bounded generation report; Host applies independent admissions and atomic generation publication. No plan batches away accepted partial-prefix semantics. |
| Crash before/after dispatch | Runtime distinguishes committed admission from volatile delivery on reopen. | Core finds an admitted unfinished Operation without live Driver custody and applies effect-specific recovery. | Host reconstructs canonical facts; Engine proposes recovery. A prior emitted plan proves neither commit nor effect execution. |
| Lost Bash evidence | Runtime resolves uncertainty without replay. | Driver disappearance provides no completion proof; Core records the accepted indeterminate meaning. | Engine sees admitted uncertain Bash; Host commits indeterminate. A plan is not a command receipt. |
| Exact Edit recovery | Runtime reconciles durable intent with current target through Edit mechanics. | Core owns intent/authorization/results; Edit adapter compares exact target evidence; Driver owns temporary resources. | Engine chooses reconciliation; Host obtains target evidence through Edit adapter and revalidates before committing the resulting decision. |
| Provider continuation | Runtime freezes manifests and preserves private provider bytes. | Core owns lineage and manifests; provider interpretation/transport adapters preserve exact bytes using bounded storage access. | Host supplies immutable references and bounded interpreted facts; engine chooses policy without copying opaque continuation into plan state. |
| Cancellation before cleanup | Runtime settles logical meaning but retains charged handles. | Core settles; Driver retains custody until physical obligations end. | Host atomically applies cancellation plan but retains its physical resource record after semantic settlement. |
| Storage failure | Runtime must not dispatch uncommitted work or report partial success. | Core commit failure prevents Driver start; post-effect commit failure retains/reconciles uncertainty. | Host cannot execute a plan whose admission failed; plan creation has no semantic authority. |
| Dormant versus active population | SQLite-only dormant state; bounded active records inside Runtime. | SQLite-only dormant state; startup-sized Driver custody; bounded Core queries. | SQLite-only dormant state; bounded snapshots/plans plus Host custody. Snapshot/plan duplication consumes an additional measured workspace, not per-dormant-Session storage. |
| Client detachment and server restart | Explicit server driver continues independently; reopen recovers committed facts. | Same facade behavior; driver lifetime is server-owned, core state is durable. | Host owns server lifetime; engine execution is transient. Restart derives facts from SQLite. |

All three require actual transaction/effect tests eventually. The table states how they would satisfy the contract, not evidence that they do. None promises to stop remote billing, contain detached subprocesses, or automatically replay uncertain mutations.

## Platform and resource placement

A places platform knowledge in private Runtime implementation modules. B places it in Storage access and physical adapters driven by Driver. C places it in Host and its adapters. All retain pinned bundled libcurl/OpenSSL with selected trust, selected credential persistence, local Store locks/pathname sockets, disk-backed scratch, host Bash, exact Edit and disposable bounded QuickJS.

OS-specific process limits, core-dump protection and metrics belong to those physical owners, not Session vocabulary. Runtime checks occur on the available Mac; Linux compatibility uses the agreed evidence/compilation policy without pretending those are Linux execution tests. Platform integration can differ without changing semantic guarantees.

Process layout is independent of module layout: all three can use one native Host process, one disposable evaluator process at a time, and Bash child processes. No candidate needs a storage service, daemon manager, RPC bus or per-Session process. Edit remains in-process. A conceptual box does not create a process.

## Initial assessment for discussion

B is the most promising starting direction because OnePage's accepted durable authority versus physical custody distinction already provides a concrete reason for the separation. Keep the Runtime facade deep so ordinary consumers do not inherit admission/dispatch choreography. A is competitive if its private modules achieve the same separation without additional public contracts. C earns its extra facts/plan protocol only if a focused experiment shows simpler overall reasoning or testing; pure functions and Wasm portability alone do not establish that.

The first decision is whether B's explicit durable-core/temporary-driver division makes the responsibility split clearer to the user. Exact storage interface, provider interpretation placement, workflow implementation, SQL layout and method spellings remain later interface decisions. A request to change a retained product promise must be surfaced separately before selection.
