# Future architecture options for OnePage

Research date: 2026-08-26

This note asks which current decisions help four plausible futures without making V1 carry their machinery. It is research, not a normative specification. Current product and architecture documents win where they differ.

Primary implementations reviewed:

- DeepSeek Harness [`b150a551b8d465e31e418e1b2eaf5e79bbb7d28e`](https://github.com/deepseek-ai/deepseek-harness/tree/b150a551b8d465e31e418e1b2eaf5e79bbb7d28e);
- OpenCode V2's current Cloudflare profile and Cloudflare's platform documentation;
- Ghostty's merged memory work in [PR #13264](https://github.com/ghostty-org/ghostty/pull/13264) and [PR #14017](https://github.com/ghostty-org/ghostty/pull/14017);
- the RLM authors' implementation [`854e688fbba9d8f8989e3da9989812e4b6dfe270`](https://github.com/alexzhang13/rlm/tree/854e688fbba9d8f8989e3da9989812e4b6dfe270) and [paper](https://arxiv.org/abs/2512.24601).

## Decision summary

1. Reserve the actual compile-time slot size, remove storage without a production user, enforce a 32 KiB V1 ceiling, and report actual and high-water use.
2. Do not make tools plugins in V1. Use a generic model-visible Tool Definition/Call shape now so providers share one protocol, while keeping execution closed to the typed `bash` and `apply_patch` Actions. If external execution becomes a real requirement, design its admission and lifecycle then.
3. Do not make Cloudflare Durable Objects a V1 target. Keep Core, storage semantics, and effects separated well enough that a later Workerd profile can substitute implementations without changing Session meaning.
4. Treat RLM support as a strong post-V1 direction. OnePage's durable out-of-core state and suspendable effects fit RLM execution unusually well, but recursive calls and a code environment are real new product capabilities.
5. Revisit the name separately. Removing the one-page-sized slot removes the name's literal technical explanation; that is a naming fact, not enough evidence by itself to choose a replacement.

## 1. Exact bounded memory, not a 64 KiB artefact

The native slot now reserves its exact 24,704-byte production type rather than a 65,536-byte page ([current layout](../../src/core_image.zig)). A later audit found that its 4 KiB parser scratch and 4 KiB transition scratch have no production reader or writer, so naming those fields does not make them necessary. Wasm no longer ships or supplies a V1 conformance oracle, and neither a historical headline nor possible future use justifies resident reserve.

Ghostty's recent memory work supports removing it. Ghostty did not preserve allocations for a memorable headline. It separated authoritative terminal state from reconstructable working sets, made residency explicit, then discarded or compressed resources only when reconstruction was safe. It also distinguished virtual address reservation from physical residency: cold history can retain address space while releasing physical pages, and hidden surfaces can release a GPU swap chain while preserving terminal state ([history compression](https://github.com/ghostty-org/ghostty/pull/13264), [discard implementation](https://github.com/ghostty-org/ghostty/commit/0fb89f4ffebabd7ea868f75a93f14a41ff65764a), [hidden-surface release](https://github.com/ghostty-org/ghostty/pull/14017)).

The corresponding OnePage rule is:

- reserve `@sizeOf(ActivationSlot) * active_capacity`, without filler or fields lacking a production consumer;
- fail the build when `@sizeOf(ActivationSlot) > 32 * 1024` in V1;
- preserve fixed-capacity scratch and allocator-free Core activation;
- report slot size, occupied high-water bytes, pool reservation, SQLite memory, adapter buffers, subprocesses, and RSS separately;
- measure active, waiting, restored, and dormant states rather than presenting one number as total agent memory.

A 32 KiB ceiling is a guardrail, not a target allocation. The unused parser and transition reserves should be removed now; future scratch should arrive with the production path that consumes it. The remaining response storage should shrink only when a simpler ownership or incremental-parsing design proves that Core no longer needs the complete bounded response. Conversely, exceeding 32 KiB should require an explicit architectural decision rather than hidden heap fallback.

Ghostty's virtual-memory technique is not needed for this change. A host-owned reserved mapping with discard/recommit is worth investigating only if a measured large configured pool retains unwanted physical pages after slot release. Virtual size, RSS, physical footprint, and compressed memory must remain distinct evidence.

## 2. Tools should be capabilities before they are plugins

DeepSeek Harness is intentionally a plugin system. Cordis plugins contribute services, typed events, and reversible effects; even the model adapter, tool registry, session log, and agent loop are replaceable plugins composed into a tree at boot ([architecture](https://github.com/deepseek-ai/deepseek-harness/blob/b150a551b8d465e31e418e1b2eaf5e79bbb7d28e/docs/architecture.md#L9-L27)). This serves dynamic composition and scoped replacement, not merely tool dispatch.

Its narrower tool contract is useful prior art. A tool registers schema and executor separately. The registry validates arguments and results, assigns an immutable execution token, and runs calls through explicit policy, guard, execution, post-processing, finalization, and observation stages. Tool visibility is explicitly not an authority boundary ([tool registry](https://github.com/deepseek-ai/deepseek-harness/blob/b150a551b8d465e31e418e1b2eaf5e79bbb7d28e/packages/core/tools/README.md#L1-L31), [typed execution](https://github.com/deepseek-ai/deepseek-harness/blob/b150a551b8d465e31e418e1b2eaf5e79bbb7d28e/packages/core/tools/README.md#L41-L59)). DeepSeek also keeps durable `tool/call` and `tool/result` events separate from live interception events ([event domains](https://github.com/deepseek-ai/deepseek-harness/blob/b150a551b8d465e31e418e1b2eaf5e79bbb7d28e/docs/architecture.md#L53-L96)).

OnePage should copy the separation, not the meta-framework:

- Conversation and Provider requests use generic Tool Keys, definitions, calls, and results rather than tool-specific protocol tags.
- The exact bounded Tool Catalog is immutable for one model Operation and is not an executable registry.
- Harness maps only admitted Tool Keys through a closed switch to typed V1 Actions.
- Harness continues to own descriptor validation, Authorization, Attempt admission, durable ordering, and recovery.
- A leaf tool adapter receives only an immutable admitted Attempt and returns typed evidence.
- Tool selection or visibility never grants authority.
- Arguments and results are validated at the adapter boundary and durably bound to the Attempt.

V1 has two tools and no external extension author. A dynamic registry, discovery format, unload lifecycle, dependency injection graph, event waterfall, configuration overlay, or per-agent shadowing would add failure modes without a second consumer. Calling the current adapters “plugins” would also imply packaging and lifecycle promises that do not exist.

If post-V1 demand establishes independently distributed tools, the model-visible Tool Definition already exists. The new work would be a host-resolved execution binding with capability requirements and one executor. Approval and durable recovery stay outside executors. Package discovery, compatibility, isolation, and unload should be designed only when their actual deployment model is known.

## 3. Cloudflare Durable Objects are a possible port, not an easy deployment

OpenCode V2 demonstrates a deliberate Workerd profile rather than transparent portability. Its `@opencode-ai/sdk/workerd` package uses a Durable Object's SQLite storage, persists events for eviction recovery, holds one host for the object instance lifetime, replaces unavailable filesystem and process services, and bundles plugins with the Worker. It initializes under `blockConcurrencyWhile` and does not rely on `close()` because eviction may skip cleanup ([OpenCode Cloudflare profile](https://opencode.ai/v2/docs/build/sdk/cloudflare/)). The documentation currently installs an `@dev` package, so this is valuable pre-release prior art rather than a stable compatibility commitment.

The platform differs materially from OnePage's native host:

- each Durable Object is single-threaded, globally addressable, and owns private strongly consistent storage; horizontal scale comes from multiple objects, not threads inside one object ([Durable Object model](https://developers.cloudflare.com/durable-objects/concepts/what-are-durable-objects/), [scaling limits](https://developers.cloudflare.com/durable-objects/reference/faq/));
- an object may hibernate or be evicted, its constructor runs again, and no reliable shutdown hook is provided, so all important state must already be durable ([lifecycle](https://developers.cloudflare.com/durable-objects/concepts/durable-object-lifecycle/));
- SQLite is available through `ctx.storage.sql`, not a database file or `sqlite3*`; `BEGIN` and `SAVEPOINT` are unavailable through SQL and transactions use the storage callback API ([SQLite API](https://developers.cloudflare.com/durable-objects/api/sqlite-storage-api/));
- one SQLite-backed object is limited to 10 GB, a row or BLOB to 2 MB, and a query to 100 bound parameters; default active CPU is 30 seconds and may be configured to five minutes ([Durable Object limits](https://developers.cloudflare.com/durable-objects/platform/limits/));
- a Worker isolate has 128 MB for JavaScript and Wasm together and may handle many concurrent requests ([Workers limits](https://developers.cloudflare.com/workers/platform/limits/));
- JavaScript and bundled Wasm run, but `node:child_process` is a non-functional compatibility stub, so local Bash and native process ownership do not carry across ([Node compatibility](https://developers.cloudflare.com/workers/runtime-apis/nodejs/)).

Therefore the current native Zig executable cannot be uploaded to a Durable Object. A direct port would need a Workerd shell, likely a Zig-to-Wasm Core, a storage implementation over `ctx.storage.sql`, and replacement tool capabilities. The linked SQLite C library cannot open a Durable Object's private database. Reintroducing Wasm for an actual shipping target would be reasonable; restoring it now as a V1 conformance target would not.

The architecture can preserve a low-cost route without implementing that port:

- keep Core deterministic, allocation-free, pointer-free in durable state, and driven by canonical bytes;
- keep SQLite handles, pragmas, file paths, and transaction syntax behind the Storage Owner rather than in Session semantics;
- define Host Runtime in terms of transactional storage, provider/network, clock/entropy, and effect capabilities, with native implementations in V1;
- never require cleanup for correctness;
- keep stable Host and Session identities and require no cross-Host atomic transaction;
- make active capacity host-local so a cloud deployment may shard hosts while dormant Sessions remain durable.

One Durable Object per OnePage Host matches the current “one store, many Sessions” topology better than one object per Session. It does not preserve the 10,000-active-agent example inside one object: even the current approximately 24 KiB slots alone exceed the 128 MB isolate limit. A Cloudflare deployment would shard Host Runtimes across objects and size each active pool below measured isolate headroom.

A post-V1 Cloudflare spike should prove canonical Core execution in Wasm, semantic transactions over Durable Object SQL, forced-eviction restoration, substituted non-process tools, and bundle/startup/memory limits. It should not weaken the native V1 to gain an unshipped target.

## 4. OnePage is a promising RLM substrate

Recursive Language Models treat a long prompt as data in an external environment. The root model programmatically examines and decomposes that data and may invoke smaller model calls over selected pieces rather than placing the whole input in one context ([paper](https://arxiv.org/abs/2512.24601), [authors' overview](https://github.com/alexzhang13/rlm/blob/854e688fbba9d8f8989e3da9989812e4b6dfe270/README.md#L30-L40)). The authors' default implementation exposes the context through a Python REPL, and supports local, container, and remote sandbox environments ([execution environments](https://github.com/alexzhang13/rlm/blob/854e688fbba9d8f8989e3da9989812e4b6dfe270/docs/api/rlm.md#L119-L166)).

An RLM is not merely unbounded recursion. The reference API bounds recursion depth, iterations, cost, elapsed time, tokens, and errors. Child RLM calls receive their own environments, while an optional persistent mode reuses variables across completions ([bounds](https://github.com/alexzhang13/rlm/blob/854e688fbba9d8f8989e3da9989812e4b6dfe270/docs/api/rlm.md#L171-L244), [persistent state](https://github.com/alexzhang13/rlm/blob/854e688fbba9d8f8989e3da9989812e4b6dfe270/docs/api/rlm.md#L334-L388)). The paper reports strong long-context results and comparable median cost, but also a long cost tail; RLM execution therefore needs explicit budgets and observable trajectories rather than a recursion slogan ([paper results](https://arxiv.org/abs/2512.24601)).

OnePage already has the right underlying posture:

- long context and outputs live outside the resident Core in immutable content;
- a bounded activation reads only the window needed for the next transition;
- model and tool work is suspendable and identified by durable Operations and Attempts;
- a dormant logical computation does not require a thread, stack, process, or materialized object graph;
- crash recovery can reconstruct orchestration from durable facts instead of a live recursive call stack.

That is a strong fit for a durable RLM runtime. Each sub-call could eventually be an ordinary identified Operation or child Session with its own bounded activation. Context slices could be immutable blob ranges. Budgets, parentage, selected ranges, code, results, and final synthesis could be durable facts. Arbitrary recursion would consume host credits and durable storage, not resident ancestor stacks.

The missing pieces are substantial and post-V1:

- a confined code-execution capability rather than unrestricted local Python state;
- bounded range/search access over external context;
- child-call identity, budget accounting, cancellation, and result aggregation;
- a policy for which REPL state is authoritative, checkpointed, or disposable;
- scheduling across many ready child calls without making topology resident;
- model-facing protocol and evaluation evidence.

Persistent REPL variables must not silently become Session authority. Either the environment is ephemeral and reconstructable from durable context and code, or its checkpoint is an explicit external-effect Result with compatibility and size limits. OnePage should also retain a depth-independent durable topology even if a product policy caps depth for cost or quality.

V1 adds caller-directed keyed agent Jobs for workflows, but not model-directed delegation, a REPL, or an RLM API. It should otherwise avoid closing the path: keep immutable content range-addressable, retain typed provider/tool Attempts, keep Core independent of a resident call stack, and let future capacities be host-owned.

## 5. Naming consequence

“OnePage” historically had a literal explanation: one active Core occupied one 64 KiB page-sized slot. The exact bounded activation workspace is a better engineering contract but no longer gives the name that literal page size. The name may still work as a metaphor for a small working set, but the architecture must not preserve unused storage to justify it.

Whether to rename depends on product positioning, discoverability, and audience, none of which these implementation sources answer. Decide it after the memory contract is rewritten, and independently of the Cloudflare and RLM options.

## V1 versus post-V1

| Area | V1 | Post-V1 only after demand |
| --- | --- | --- |
| Activation memory | Exact actual slot, no filler, 32 KiB ceiling, measured high-water | Virtual reservation/discard after physical-memory evidence |
| Tools | Closed `bash` and `apply_patch` variants; typed adapter evidence | Definition registry, distribution, isolation, lifecycle |
| Cloudflare | Portable semantic boundaries; native runtime only | Workerd shell, Wasm Core, Durable Object storage adapter, sharded hosts |
| RLM | Do not block external context or suspendable calls | Code environment, recursive child calls, budgets, topology, evaluation |
| Name | Stop tying correctness to one 64 KiB page | Separate naming decision |

The common rule is simple: preserve semantic seams that already carry authority; do not add runtime, plugin, cloud, or recursive machinery until a product slice needs it.
