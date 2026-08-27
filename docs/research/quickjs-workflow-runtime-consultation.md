# Decision

> Historical consultation captured on 2026-08-27. It is decision input, not a normative contract.
> Live GitHub API verification confirmed QuickJS-ng v0.16.2 was released on 2026-08-20. Search
> indexing initially returned the older v0.15.1 release. Implementation must still pin and verify an
> exact source URL and hash rather than depend on a moving `latest` reference.

**Yes: replace system Node with pinned QuickJS-ng as the sole V1 workflow runtime.**

But I would not adopt Option Q exactly as written. I recommend a smaller variant:

> **Run QuickJS in a fresh, short-lived subprocess for each workflow evaluation. Terminate it whenever execution reaches a durable-job barrier, wait in Zig, and replay in a new subprocess after the barrier settles.**

Do **not** retain native Promise resolvers across model waits. Do **not** build a hot-runner memory budget or eviction policy in V1.

Call this **Option Q-e**, for ephemeral QuickJS evaluation:

```text
onepage run workflow.js
  │
  ▼
Zig Host Runtime
  ├── choose a durable-result visibility snapshot
  ├── spawn constrained QuickJS evaluation
  │     ├── execute workflow from the beginning
  │     ├── terminal agent job → resolved/rejected Promise
  │     ├── pending agent job  → unresolved Promise + blocked-job record
  │     ├── pump microtasks to quiescence
  │     └── report completed / blocked / failed / deadlocked, then exit
  │
  ├── if blocked: wait until the blocked job set is terminal
  └── spawn the next fresh evaluation
```

This is simpler than either Node or a retained QuickJS process:

- dormant workflows retain **no JavaScript process or heap**;
- no native Promise capability survives a model wait;
- no late callback can target a stale QuickJS runtime;
- no eviction policy is needed;
- native leaks are reset after every evaluation;
- actual provider completion order can be hidden from JavaScript;
- runner death and intentional quiescent termination use the same replay path.

The spike proves that QuickJS can retain and resolve native Promise capabilities, pump pending jobs, and enforce engine limits. The bridge currently stores native resolvers and keys in a fixed pending array, then resolves them in later waves.    That is good feasibility evidence—but production can delete most of that machinery by never delivering an asynchronous job completion into an old runtime.

The official C API supports a runtime allocation limit, maximum stack size, and interrupt callback, matching the mechanisms exercised by the spike. Those are useful first-line controls, not complete process-level resource enforcement. 

No unresolved unknown prevents this roadmap decision under the assumptions in §14.

---

# The corrected runner model

## One evaluation, one immutable visibility point

At the beginning of every workflow evaluation, the Host chooses:

```text
visible_completion_sequence
workflow_semantics_version
definition_digest
arguments_digest
resource_profile_digest
```

Within that evaluation, `agent()` may observe a terminal result only when that result was durable at or before `visible_completion_sequence`.

A job that completes while JavaScript is executing remains pending from that evaluation’s perspective. It becomes visible only in the next evaluation.

This removes timing from the workflow’s asynchronous input:

```text
real provider completion order
           │
           ╳  not observable
           │
durable snapshot → deterministic workflow evaluation
```

Without this rule, apparently constrained JavaScript is still nondeterministic:

```js
let first;

const a = agent({ key: "a", task: "..." }).then(() => {
  first ??= "a";
});

const b = agent({ key: "b", task: "..." }).then(() => {
  first ??= "b";
});

await Promise.all([a, b]);

// Depends on completion delivery order unless the Host controls visibility.
return first;
```

Removing clocks and randomness is not enough. **Provider completion delivery is itself a source of nondeterminism.**

The smallest implementation is a Host-wide monotonically increasing durable event or completion sequence. An existing terminal job is returned to the runner only when its terminal sequence is at or below the evaluation watermark.

## Quiescence outcomes

After evaluating the default export and draining `JS_ExecutePendingJob`, exactly one outcome should be reported:

```text
Completed(final_value)
Blocked(unique_pending_job_ids)
Failed(stable_error_code, bounded_diagnostics)
Deadlocked
ResourceExceeded(kind)
ProtocolFailed
```

The rules are:

- Root Promise fulfilled and no pending agent jobs: `Completed`.
- Root Promise pending and at least one pending agent job: `Blocked`.
- Root Promise pending and no pending agent jobs: `Deadlocked`.
- Root Promise rejected: `Failed`.
- Root Promise fulfilled while pending agent jobs exist: treat it as `Blocked`, not completed.

That last rule enforces structured concurrency. This workflow is not allowed to detach an unjoined job:

```js
export default async ({ agent }) => {
  agent({ key: "orphan", task: "Do something eventually" });
  return "done";
}
```

The run finishes only after every job requested by the evaluation has settled and replay confirms the final result.

## Wait for the whole blocked set

When an evaluation reports:

```text
Blocked([A, B, C])
```

wait until **A, B, and C are all terminal** before evaluating again.

This produces deterministic barrier semantics without storing a durable DAG. It also prevents one process launch per individual completion for `Promise.all` fan-out.

A 10,000-job `Promise.all` needs approximately:

1. one evaluation to create/rejoin the jobs;
2. one wait for the full barrier;
3. one evaluation to consume their results.

It does not require 10,000 replays.

The trade-off is deliberate: `Promise.race` does not mean “whichever model call physically finishes first.” Real completion timing is not a workflow input. Once all blocked jobs are exposed in the next snapshot, ordinary ECMAScript microtask order determines the result.

---

# Exact product contracts

## Product contract

I would use:

> **OnePage runs resource-bounded, restartable JavaScript agent workflows. Agent jobs and external effects are durable; JavaScript control state is reconstructed from immutable arguments and durable job results after every runner or Host restart.**

A shorter product sentence is:

> **A durable, bounded runtime for restartable coding-agent workflows.**

Avoid the unqualified phrase **“durable JavaScript workflow runtime.”** That commonly implies checkpointed language continuations, arbitrary durable awaits, timers, signals, and exact statement-level resumption.

Owning QuickJS makes OnePage a genuine workflow **execution** runtime. It does not change what is durable.

## Trust contract

I would put this nearly verbatim in the V1 documentation:

> Workflow source runs in a separate, resource-limited QuickJS process. The JavaScript realm has no filesystem, process, network, environment, credential, wall-clock, randomness, timer, or general module-loading capability. A workflow can affect the outside world only through capabilities explicitly supplied by OnePage, and those capabilities remain subject to durable identity, quota, permission, and Workspace rules.
>
> This boundary protects against ordinary accidental or deliberately abusive JavaScript using language-visible APIs. It is not a hostile multi-tenant isolation boundary. A vulnerability in QuickJS, its native bridge, the C runtime, or the operating system could compromise the runner process and act with the local user’s authority.

Do not call arbitrary model-authored workflows simply “safe.” Say:

- **capability-constrained**;
- **resource-limited**;
- **appropriate for a single-user local execution model**;
- **not hardened native-code isolation**.

QuickJS-ng’s own security policy explicitly treats vulnerabilities reachable from untrusted JavaScript in a trusted embedder as relevant to its threat model, which is a positive fit. It also makes clear that untrusted QuickJS bytecode is outside that protection. 

Therefore, V1 must execute **source only**. Never accept, cache, restore, or IPC-transfer QuickJS bytecode. QuickJS’s documentation warns that bytecode is version-bound and not security-checked. 

## Memory contract

The honest contract becomes:

> Durable jobs and transcripts scale on disk. A workflow evaluation has hard JavaScript-heap, native-bridge, stack, protocol, result-visibility, and CPU bounds. No workflow runner remains resident while that workflow waits on durable jobs. Evaluation memory may grow with the bounded number and size of live JavaScript values and visible job results.

This is substantially stronger than the Node design, but still not:

```text
whole-host memory = O(active agent Attempts)
```

During replay, JavaScript may materialize thousands of keys, Promises, arrays, and typed results. QuickJS changes the coefficient and provides a hard engine allocation control; it does not remove that dependence.

---

# Decision register

## 1. Runtime decision

**Decision: adopt QuickJS-ng as the sole V1 workflow runtime.**

The evidence has crossed the threshold needed to reverse the Node recommendation:

- all 39 saved workflows exercised successfully under the compatibility harness;
- the workflows use ordinary JavaScript control flow rather than Node-specific facilities;
- measured fixed and high-fan-out memory are materially lower;
- QuickJS can be built and cross-compiled directly with Zig;
- engine heap, stack, and execution can be bounded;
- the absence of ambient capabilities is an architectural property, not merely a convention.

This is not merely a performance optimization. It aligns the authoring runtime with the product’s authority model.

QuickJS-ng 0.16.2 is the latest release as of August 27, 2026. The release includes several correctness, leak, alignment, and interrupt-check fixes. That indicates active maintenance, while also illustrating why OnePage must have an explicit update process rather than treating the engine as a frozen utility. 

### Important modification

Do not implement production as:

```text
one durable workflow run = one retained QuickJS Runtime
```

Implement:

```text
one workflow evaluation = one disposable QuickJS subprocess
```

The native asynchronous bridge in the spike proves the harder thing is possible, but replay allows V1 to avoid owning it.

---

## 2. Trust claim

**Decision: the proposed claim is justified with the qualification above.**

The language-level boundary is real only when all of the following are true:

- source is sent by the Host, not opened by the runner;
- the child receives no workflow or Workspace path;
- inherited environment is empty or allowlisted;
- inherited file descriptors are closed except protocol and bounded diagnostics;
- no QuickJS `std` or `os` module is linked or initialized;
- no general module loader is installed;
- capabilities are passed as a frozen object, not ambient globals;
- all native capability arguments pass through a strict bounded data-value decoder;
- the parent independently enforces wall-clock and total-process limits;
- provider/job quotas are enforced by the Host.

The spike’s `read_file()` and direct path argument are explicitly non-production behavior.   The Host should read and hash the file once, then send the exact bounded source bytes to the runner.

### What it does not protect against

A model-authored script may still deliberately:

- consume its complete CPU or memory allowance;
- submit jobs until the run quota is reached;
- produce enormous intermediate structures up to the data limit;
- exploit a QuickJS memory-corruption bug;
- exploit a bug in OnePage’s C/Zig value bridge;
- cause expensive but authorized model requests.

Capability confinement removes ambient authority. **It does not replace semantic quotas on `agent()`.**

---

## 3. Product positioning

**Decision: retain the narrower semantic wording.**

Owning the runner changes the packaging and trust boundary, not the durability unit.

Recommended hierarchy:

### Product category

> Resource-bounded agent-workflow runtime

### Precise promise

> Runs restartable JavaScript workflows over durable agent jobs.

### Durability clarification

> Job, Attempt, Completion, permission, and effect state is durable. JavaScript heap and continuation state is reconstructed rather than checkpointed.

I would no longer lead with “agent-job host,” because QuickJS makes workflow authoring and execution a first-class OnePage responsibility. But I would still avoid an unqualified “durable workflow runtime.”

---

## 4. Memory contract

**Decision: yes—hard limits plus published measurements, not an asymptotic claim.**

The following limits should be normative in V1 rather than incidental constants:

| Limit | Why it must be explicit |
|---|---|
| Maximum workflow source bytes | Bounds parsing, diagnostics, and source retention |
| Maximum invocation-arguments bytes, depth, and collection width | Bounds initial value construction |
| Maximum jobs per run | Bounds durable and economic fan-out |
| Maximum new jobs per evaluation | Prevents one evaluation from filling the Host |
| Maximum simultaneously blocked jobs per evaluation | Bounds Promises and wait metadata |
| QuickJS managed-allocation limit | Bounds engine heap |
| Native runner arena/bridge limit | Engine limit does not cover Zig/C bridge allocations |
| Maximum QuickJS stack | Bounds recursion/native stack exposure |
| Parent-enforced runner RSS or address-space limit | Covers code pages, C allocator, stack, and libraries |
| Maximum CPU/wall time per evaluation | Bounds synchronous loops and microtask churn |
| Maximum cumulative evaluations per run | Bounds pathological replay depth |
| Maximum cumulative workflow CPU per run | Bounds quadratic sequential replay |
| Maximum pending QuickJS microtasks/jobs | Bounds Promise-only denial of service |
| Maximum protocol frame and in-flight protocol bytes | Bounds IPC |
| Maximum key, task, input, profile, and schema sizes | Bounds each `agent()` request |
| Maximum typed result bytes per job | Bounds workflow-visible results |
| Maximum aggregate typed-result bytes visible in one evaluation | Bounds fan-in |
| Maximum final result bytes | Bounds completion |
| Maximum diagnostic/log bytes per evaluation and run | Prevents replay log flooding |
| Maximum concurrent workflow evaluations | V1 should be one |

Do not count transcripts against workflow-result memory. A job may have a large durable Conversation while returning a small schema-constrained typed result.

For high fan-out, make this rule explicit:

> A workflow whose results do not fit within one evaluation’s aggregate result budget must introduce bounded intermediate aggregation jobs.

That is hierarchical fan-in. It need not become a special Host primitive.

### Engine limit versus process limit

The spike applies a 16 MiB engine limit, 512 KiB stack limit, and interrupt deadline.  But the fixed `Host.entries` array and each `strdup` allocation sit outside that QuickJS managed limit.  

Production should therefore use:

- a bounded native arena for bridge state;
- no unconstrained `malloc`/`strdup` proportional to requests;
- an OS/process watchdog as the outer limit.

---

## 5. Runner eviction

**Decision: always terminate at quiescence in V1. Do not implement hot retention or eviction.**

This is the largest change I recommend to the proposal.

### Why termination is simpler

A retained runner requires:

- native resolver and reject-function ownership;
- late response routing;
- runner epochs;
- stale-completion rejection;
- cancellation of outstanding native callbacks;
- memory accounting for each retained runtime;
- eviction selection;
- safe teardown while responses race with termination;
- hot-versus-cold diagnostics;
- potential completion-order nondeterminism.

An ephemeral runner requires:

- one bounded evaluation;
- one root Promise;
- a set of pending durable jobs;
- one terminal outcome;
- process teardown.

The replay model is already accepted. Use it structurally rather than retaining an optimization that replay was meant to make unnecessary.

### Replay cost

Replay cost scales with sequential dependency depth.

For a two-stage workflow:

```text
parallel investigation → synthesis
```

there are usually three evaluations:

1. create investigation jobs and block;
2. consume investigations, create synthesis, and block;
3. consume synthesis and complete.

That is negligible next to model latency.

The pathological case is:

```js
for (const item of 10_000_items) {
  await agent(...);
}
```

This creates thousands of evaluations and repeatedly reconstructs prior state. V1 should reject it through cumulative evaluation/CPU limits and recommend batched fan-out or pipelines.

### Evidence that would justify hot retention later

Add it only when real workloads demonstrate all of the following:

- sequential workflow depth is common rather than accidental;
- replay CPU or parse time is a material fraction of non-model execution;
- result reconstruction is a measured latency problem;
- the required memory budget is acceptable;
- a retained-runner lifecycle remains simpler than a durable bulk or pipeline primitive.

Until then, zero dormant runner residency is both simpler and more aligned with OnePage’s architecture.

---

## 6. JavaScript API

**Decision: `agent()` remains the only durable Host-semantic intrinsic.**

Use:

```js
export default async function workflow(
  { agent, parallel, pipeline, phase, log },
  args,
) {
  // ...
}
```

The distinctions are:

| API | Semantics |
|---|---|
| `agent()` | Host capability; durable job creation or reattachment |
| `parallel()` | Ordinary frozen JavaScript helper, likely `Promise.all` over thunks |
| `pipeline()` | Ordinary deterministic JavaScript loop/helper |
| `phase()` | Bounded diagnostic annotation; non-authoritative |
| `log()` | Bounded diagnostic output; non-authoritative and replayable |

`phase()` and `log()` are not literally pure because they emit diagnostics. Their output contract should be:

> Diagnostic events may repeat after replay and must not affect workflow control or durable identity.

Give every diagnostic event:

```text
run_id
evaluation_generation
local_sequence
```

A UI can suppress duplicate presentation if useful, but logs must not become workflow authority.

The representative saved workflow already demonstrates that external JavaScript can own fan-out, labels, schemas, and final joins without a model-visible Agent tool or Host DAG. 

### Keep one `agent()` shape

Do not support both:

```js
agent(prompt, options)
```

and:

```js
agent({ key, task, input, schema, profile })
```

Use only the explicit object form. The key is mandatory. Overloads add conversion and identity ambiguity without product value.

---

## 7. Script form

**Decision: require the standard default-exported async function in normative V1. Do not ship source-rewriting Claude compatibility in the production runner.**

Use:

```js
export default async function workflow(capabilities, args) {
  // ...
}
```

Optionally allow a data-only metadata export:

```js
export const meta = {
  name: "security-review",
};
```

The compatibility spike proves the relevant JavaScript language features work. It does not establish that the transformation is a good product interface.

The mock compatibility runner currently:

- replaces one exact source substring;
- constructs an `AsyncFunction`;
- injects globals positionally;
- executes the transformed file as a function body. 

That is appropriate for corpus testing, not a stable parser or security boundary. A textual rewrite can be confused by comments, strings, alternate export formatting, additional imports, and source-level name collisions.

For production:

1. evaluate the source as an ES module under a fixed virtual module name;
2. install a module loader that rejects every import and dynamic import;
3. obtain the default export;
4. verify it is callable;
5. call it with frozen capabilities and immutable arguments.

Do not expose the `AsyncFunction` constructor as the loader.

The 39 saved scripts can be mechanically converted once for fixtures. A later offline importer may support Claude-shaped files if there is an actual interoperability product, but the runner itself should have one grammar contract.

---

## 8. Determinism boundary

**Decision: the omitted capabilities are necessary but not sufficient.**

The following must also be normative.

### A. Build an allowlisted realm

Do not use an ordinary `JS_NewContext()` and merely avoid `std` and `os`.

QuickJS exposes `JS_NewContextRaw()` and separately installable intrinsics, including Date, eval, Proxy, Promise, WeakRef, performance, and others. That exists specifically to let embedders select the realm’s facilities. 

The production realm should begin raw and add only the features required by the corpus. At minimum, omit:

- Date;
- performance;
- WeakRef and FinalizationRegistry;
- eval;
- Proxy unless a real script requires it;
- SharedArrayBuffer and Atomics;
- dynamic module loading;
- QuickJS standard and OS modules.

`Math.random` is normally part of basic JavaScript facilities rather than `std`/`os`. Replace it with a stable throwing function or otherwise remove access before user code executes.

Do not merely monkey-patch a normal context after exposing it if a raw-context allowlist is available.

### B. Hide completion timing

Use the evaluation visibility watermark described above.

### C. Version the execution semantics

Persist a digest or version covering:

```text
QuickJS-ng version/commit
enabled intrinsic set
OnePage runner ABI
helper-prelude source
canonical value encoding version
agent request canonicalization version
resource-profile semantics
```

Call it:

```text
workflow_semantics_version
```

A run resumed under a different version should fail closed by default:

```text
WorkflowRuntimeVersionConflict
```

An engine upgrade can change:

- Promise or microtask behavior;
- sort or Proxy behavior;
- error propagation;
- interrupt coverage;
- parser semantics;
- memory use near a configured limit.

The current v0.16.2 release itself contains observable ECMAScript and interrupt-behavior corrections. 

Because OnePage is unreleased, you need not support old versions indefinitely. But silently resuming an existing run under changed interpreter semantics is unsafe.

### D. Define the capability data domain

Only allow:

```text
null
boolean
finite number
valid-Unicode string
bounded array
bounded plain object with string keys
```

Reject:

- `undefined`;
- symbols;
- functions;
- BigInt unless explicitly added later;
- NaN and infinities;
- accessors;
- Proxy objects;
- custom/exotic objects;
- Map/Set as capability arguments;
- typed arrays;
- cyclic structures;
- sparse arrays;
- excessively deep or broad structures;
- lone UTF-16 surrogates.

Decide whether `-0` is normalized to `0` or preserved in the canonical encoding.

Do not use attacker-controlled `JSON.stringify()` as the semantic definition of a job request. It invokes getters and `toJSON`, silently drops some values, and maps non-finite numbers in surprising ways.

Implement one strict bounded JSON-like extractor in the bridge:

- reject Proxy before enumeration;
- inspect own property descriptors;
- reject getters and setters without invoking them;
- require the expected plain-object or array prototype;
- canonicalize object keys;
- enforce size/depth limits while traversing;
- use the same canonical encoding for the job-spec digest.

Results entering JavaScript should be created from that encoding and deep-frozen.

### E. Fix process-global influences

The runner should use:

- an empty or fixed environment;
- a fixed locale;
- a fixed timezone even though Date is absent;
- a fixed virtual filename;
- stable Host error codes rather than platform error strings.

Diagnostics such as native stack text may vary. They must never be an input to workflow control or job identity.

### F. Scope the portability promise

V1 should promise deterministic replay under:

```text
same source
same arguments
same durable results
same workflow_semantics_version
same resource profile
same supported platform/architecture class
```

Do not promise bit-identical behavior across arbitrary architectures, libc implementations, or QuickJS versions—particularly for floating-point transcendental functions and resource-limit boundary cases.

---

## 9. Dependency acceptance

**Decision: accept the pinned QuickJS-ng dependency, subject to a production-runner gate.**

A URL plus content hash is sufficient for build integrity, provided the release metadata also records:

```text
upstream repository
release tag
commit SHA
archive SHA-256
Zig dependency hash
license
local patches, if any
```

Do not commit the amalgamation merely to avoid a dependency fetch. Committing 90,000 generated C lines would make provenance and upgrades less clear, not more.

QuickJS-ng is explicitly a small embeddable JavaScript engine and is MIT-licensed. 

### Required release gates

#### Provenance and builds

- Pin the exact release and commit.
- Verify the downloaded archive before compilation.
- Generate an SBOM or equivalent dependency manifest.
- Preserve the MIT and Unicode-related license notices.
- Build from a clean dependency cache in CI.
- Reproduce the release binary from the same lock data.
- Test every supported target triple.

#### Source-only execution

- Do not expose `JS_ReadObject` bytecode loading.
- Do not use `qjsc` output as a model-authored input.
- Do not cache bytecode between versions.
- Do not accept QuickJS bytecode over the protocol.

The upstream security policy explicitly excludes hostile bytecode, while covering relevant untrusted-source bugs. 

#### Sanitizer coverage

Run the runner and bridge under:

- AddressSanitizer;
- UndefinedBehaviorSanitizer;
- leak detection where supported.

Exercise:

- the 39-script corpus;
- malformed source;
- malformed capability values;
- deep and cyclic objects;
- Proxy/accessor attacks;
- interrupt and stack exhaustion;
- repeated runner creation/destruction;
- child kill at every protocol boundary.

#### Fuzzing

Fuzz at least four boundaries independently:

```text
private protocol decoder
canonical JS-value extractor
canonical result-to-JS decoder
workflow source + capability call sequences
```

The most valuable downstream fuzz target is not generic ECMAScript parsing alone. It is the interaction between arbitrary JavaScript objects and OnePage’s native `agent()` conversion logic.

#### OOM and ownership fault injection

QuickJS uses explicit reference counting and requires the embedder to check exceptions and correctly duplicate or free every retained `JSValue`. The official embedding guide calls out these ownership and exception rules. 

Inject allocation failure at every bridge allocation and C API call that can fail. Verify:

- no use-after-free;
- no double free;
- no resolver leak;
- no partial Host request;
- stable `WorkflowMemoryExceeded`;
- child exit never corrupts Host state.

#### Outer watchdog

The parent must kill the child when it exceeds:

- per-evaluation wall time;
- total CPU;
- total memory;
- protocol inactivity deadline.

`JS_SetInterruptHandler()` is regularly polled by the engine, but should not be treated as an independent hard real-time guarantee. The fact that v0.16.2 added interrupt checks to additional Array methods illustrates that interrupt coverage can evolve. 

#### Update policy

A credible minimum policy is:

- monitor upstream releases and security reports;
- review every release for untrusted-source, memory-safety, interrupt, parser, Promise, and embedding changes;
- critical applicable fixes block new releases;
- if an applicable high-impact issue cannot be patched promptly, disable workflow execution while keeping the single-agent client available;
- rerun the complete corpus, sanitizer, fuzz-smoke, memory, and replay suite before each engine bump.

Do not auto-upgrade QuickJS in an existing durable run.

---

## 10. Node or ScriptC fallback

**Decision: omit both from V1.**

Two runtimes would create two products:

```text
QuickJS workflow
  constrained capabilities
  bounded realm
  reconstructive replay contract

Node workflow
  ambient user authority
  packages and native add-ons
  different nondeterminism
  different memory and process behavior
```

An `--unsafe-node` switch sounds small but would immediately blur:

- which workflows are replay-safe;
- whether direct filesystem effects are durable;
- whether environment changes participate in identity;
- whether the Tool permission model applies;
- how support reproduces failures;
- what “OnePage workflow” means.

### Evidence that would justify Node later

Add a trusted Node client only when real workflows repeatedly need one or more of:

- existing npm packages that cannot reasonably be replaced;
- repository-specific TypeScript libraries;
- native package bindings;
- a caller integration already resident inside Node;
- orchestration-side computation that is inappropriate to move behind an agent/tool capability.

Even then, prefer a separately named trusted external client over making Node a second built-in runner:

```text
onepage-node-client
```

It should call the same job service and carry an explicit ambient-authority warning.

### Evidence that would justify ScriptC later

Consider compilation only when profiles show that:

- QuickJS parsing/execution or replay is a material share of end-to-end non-model time;
- actual workflows are predominantly statically compilable;
- unsupported dynamic islands are rare;
- compilation caching and toolchain installation are simpler than the measured cost being removed;
- no automatic QuickJS fallback is needed.

Given that model calls dominate workflow latency, ScriptC is unlikely to earn its V1 complexity.

---

## 11. Roadmap revision

**Decision: yes, with a small QuickJS runner-kernel gate.**

The current long-lived Harness still retains a Host lease, Session, buffers, pending ingress, and locks.  Model Attempt admission still closes Core and then invokes the Provider synchronously in the same lifecycle path.  

QuickJS does not alter the need to remove that architecture first.

## Gate Q0: production runner kernel

Before claiming constrained model-authored execution, prove a minimal runner independent of SQLite:

- raw allowlisted QuickJS context;
- standard default-export module;
- imports rejected;
- parent-supplied source and arguments;
- strict data-value bridge;
- root Promise tracking;
- `Completed`, `Blocked`, `Failed`, and `Deadlocked`;
- engine and parent resource enforcement;
- no retained asynchronous native resolver;
- sanitized process inheritance;
- repeated clean teardown under sanitizers.

This gate can proceed alongside Milestone 1. It need not delay the asynchronous Session rewrite.

## Milestone 1: asynchronous Session host

- replace retained Harness ownership with short Session activations;
- add durable readiness;
- commit-and-return admitted Attempts;
- bounded model executor;
- fixture Provider;
- OS Host lock.

## Milestone 2: durable run and job identity

- workflow run identity;
- `(run_id, key)` job mapping;
- canonical immutable job-spec digest;
- terminal typed results;
- explicit resume;
- single-agent CLI through the same job service.

## Milestone 3: ephemeral QuickJS evaluation and replay

- private bounded child protocol;
- workflow visibility watermark;
- standard script contract;
- blocked-set barrier;
- source/argument/semantics digests;
- deterministic fixture workflows;
- kill-and-replay tests;
- cumulative evaluation and CPU limits.

## Milestone 4: live Codex

Unchanged:

- OAuth/credential decision gate;
- bounded Responses transport;
- semantic Conversation conversion;
- provider-specific continuation evidence;
- failure and rate-limit classification.

## Milestone 5: Workspace effects

Unchanged:

- process executor;
- per-Workspace consequential-effect fence;
- permissioned Bash and patch;
- Workspace version validation;
- one mutation and verification path.

## Milestone 6: fault and density proof

Add QuickJS-specific evidence:

- dormant workflow has no runner process;
- source replay does not duplicate completed jobs;
- completion timing does not change topology;
- runner crash after durable job creation is idempotent;
- engine OOM is distinguished from script rejection;
- native bridge memory remains bounded outside the QuickJS heap;
- sequential-depth limits prevent pathological replay.

---

## 12. Which first-review findings change

Most of the earlier review remains intact.

### Material changes

#### Workflow runtime

Before:

```text
system Node is the first workflow client
```

Now:

```text
OnePage owns and ships the one normative JavaScript runtime
```

#### Trust

Before:

```text
workflow.js is fully trusted ambient local code
```

Now:

```text
workflow.js is capability-constrained at the language/API level
```

#### Memory

Before:

```text
one blocked workflow retains a roughly 36–50 MiB Node process
```

Now, under the recommended ephemeral design:

```text
one blocked workflow retains no JavaScript process
```

The Host may still retain bounded wait metadata, and durable job/result state remains on disk.

#### Capacity

Add one resource axis:

```text
workflow_evaluation_capacity
```

V1 should set it structurally to one because one foreground Host owns one workflow run. It is separate from:

- Core activation capacity;
- model dispatch capacity;
- process dispatch capacity.

#### Replay determinism

Add:

- workflow visibility snapshots;
- wait-set barriers;
- workflow semantics versioning;
- strict JavaScript data-value canonicalization.

#### Public JavaScript contract

The standard default-export function and frozen capability object now become a OnePage-owned public contract rather than a thin convenience over system Node.

#### Process lifecycle

The runner becomes an expendable evaluation worker rather than a long-lived orchestration owner.

### Findings that remain unchanged

- each `agent()` job is one Session;
- stable keys plus immutable digests fail closed;
- no Host-owned DAG;
- no durable JavaScript continuation;
- no public stable IPC protocol in V1;
- `agent()` is the only durable workflow intrinsic;
- no model-visible Agent tool;
- no generic durable human input;
- no daemon;
- separate activation/model/process/Workspace bounds;
- durable indexed readiness;
- immutable Attempt-before-dispatch;
- powerless provider adapters;
- provider-neutral semantic Conversation;
- Codex support and credential gates;
- one consequential effect per Workspace;
- fixture-first, Codex-second, mutation-third vertical slices;
- explicit external-effect uncertainty.

---

## 13. Blindspot pass

## A. Normal QuickJS contexts contain more capability than “no std/os”

The production runner must use `JS_NewContextRaw()` and an intrinsic allowlist. Otherwise Date, dynamic evaluation, randomness, WeakRefs, or other facilities may remain.

## B. Completion timing leaks nondeterminism

A hot runner resolving Promises as providers finish makes completion order observable. Snapshot visibility plus ephemeral replay eliminates this.

## C. JavaScript-to-native conversion is an attack surface

This may be the most important untested boundary.

Naively reading:

```js
agent({
  get key() {
    agent(otherJob);
    throw new Error("surprise");
  },
});
```

can re-enter the bridge while native state is half-mutated.

Likewise, Proxy traps can run arbitrary JavaScript during enumeration.

The native extractor must reject Proxy and accessor properties without invoking them, and it must be reentrancy-safe even on every error path.

## D. Engine limits do not cover native allocations

The QuickJS allocation ceiling does not account for:

- bridge request tables;
- copied keys;
- protocol buffers;
- source bytes outside the runtime;
- C stack;
- executable/library pages;
- libc allocations;
- diagnostics.

Use a bounded native arena and an outer process limit.

## E. Interrupt handlers are cooperative engine checks

A bug or long-running native helper can avoid timely interrupt checks. Every native intrinsic must be nonblocking and bounded. The parent watchdog remains authority.

## F. Infinite microtask chains

This contains no ordinary synchronous `while` loop:

```js
function again() {
  Promise.resolve().then(again);
}

again();
await new Promise(() => {});
```

Draining pending jobs can run forever. CPU and microtask-count limits must cover the job pump itself.

## G. Root Promise and unhandled rejection semantics

Do not infer success from “pending-job queue is empty.”

Track:

- root Promise state;
- pending Host jobs;
- currently unhandled Promise rejections.

At a quiescent checkpoint:

- a later-handled rejection must not be reported too early;
- a truly unhandled rejection must fail the evaluation;
- a caught rejection must behave normally.

## H. Detached work

A workflow can create a Promise and discard it. Structured concurrency rules must prevent the run from finishing while an agent job requested during that evaluation remains pending.

## I. Job creation versus child failure

The critical sequence is:

```text
runner sends ensure_job
Host durably creates job
runner dies before receiving response
```

Replay must see the same key and digest and reattach. This is exactly the same idempotency property as a lost response to the caller.

## J. Final result commit versus child output

The inverse sequence is:

```text
runner sends Completed(result)
Host durably finishes run
CLI dies before printing result
```

Resume must return the stored final result and never reevaluate into a different final digest.

## K. Runtime upgrades during open runs

Without `workflow_semantics_version`, a QuickJS upgrade can silently alter replay control flow. Fail closed across incompatible versions.

## L. Quota abuse through a legitimate capability

The JavaScript process can be perfectly confined while still requesting the maximum allowed number of expensive model jobs. Run-level job, token, request, result, and possibly cost ceilings remain necessary.

## M. Error determinism

Do not expose arbitrary native error text as a branchable semantic value.

Use stable codes such as:

```text
AgentJobFailed
AgentJobCancelled
AgentJobIndeterminate
WorkflowMemoryExceeded
WorkflowCpuExceeded
WorkflowDeadlock
WorkflowRuntimeVersionConflict
WorkflowProtocolViolation
```

A bounded human-readable message may accompany the code for diagnostics.

## N. Replay logs

Every source-level log before a blocking point repeats. Logs are at-least-once diagnostics. They need evaluation identifiers and byte limits.

## O. Built-in and prototype mutation

The script may mutate `Array.prototype`, `Promise`, `Object.prototype`, or helper functions.

At minimum:

- freeze the capability object;
- freeze helper functions and their containing object;
- capture the engine primordials used by the bridge before executing user source;
- never invoke user-replaceable methods for native conversion;
- deep-freeze Host result values.

A full SES-style lockdown is unnecessary for V1, but native code must never trust mutable JavaScript prototypes.

## P. Unicode and numeric canonicalization

JavaScript strings are UTF-16 and may contain lone surrogates. Zig and durable encodings are likely UTF-8. Define rejection or canonical encoding explicitly.

Likewise define:

- NaN;
- infinity;
- negative zero;
- integers above `2^53 - 1`;
- property key ordering.

Otherwise a value can display similarly while hashing differently—or hash similarly after a lossy conversion.

## Q. Resource-limit replay differences

A script close to its memory ceiling might succeed under one engine release and fail under another due to allocator changes. Resource profile and interpreter version are part of run semantics.

## R. File descriptor and environment inheritance

Even without JS APIs, do not hand the child:

- Host Store descriptors;
- Workspace directory descriptors;
- credential files;
- listening sockets;
- environment secrets;
- inherited process-control handles.

Set close-on-exec everywhere and construct the child descriptor table deliberately.

## S. Core dumps

Disable core dumps for the runner. A crash dump could contain prompts, results, and credentials accidentally copied into diagnostics.

## T. Source and argument TOCTOU

The Host must read, bound, hash, and retain the exact source and argument bytes used to create the run. Do not reread `workflow.js` by path during later evaluations.

A file edit should create:

```text
WorkflowDefinitionConflict
```

unless the user explicitly creates a new run.

## U. Runner crash classification

A signal or abnormal exit may represent:

- memory limit;
- CPU limit;
- parent cancellation;
- engine crash;
- protocol violation;
- operating-system kill.

Preserve the distinction where observable. Do not automatically retry an apparent engine crash forever; repeated crash on identical inputs should fail the run and retain diagnostics.

## V. Cancellation while blocked

Define:

- cancelling the CLI does not implicitly cancel the durable run unless requested;
- explicit run cancellation marks member jobs cancelled where still cancellable;
- a late terminal job result cannot revive a cancelled run;
- a subsequent resume reports cancellation rather than starting another evaluation.

---

## 14. Assumptions and conditional answers

My recommendation assumes:

1. V1 has one foreground Host owner and one workflow run at a time.
2. The runner does not need to survive after the foreground Host exits.
3. Workflows are model-authored but not hostile remote-tenant uploads.
4. The security goal is to remove ambient authority and contain ordinary resource abuse—not to resist a determined native-engine exploit.
5. Workflow source requires no Node/npm ecosystem.
6. Actual workflows have modest sequential dependency depth.
7. High fan-out is mostly expressed through barriers such as `Promise.all`.
8. Typed agent results are bounded and much smaller than full Conversations.
9. Initial supported platforms can provide a parent watchdog and basic process limits.
10. Runs may fail closed across OnePage/QuickJS upgrades rather than carrying indefinite interpreter compatibility.
11. Only source, never QuickJS bytecode, is accepted.
12. The Host reads workflow source and supplies it to the child over the private protocol.
13. Completion order is not intended to be a user-visible workflow input.

### If multiple workflows must run concurrently

Add:

```text
workflow_evaluation_capacity
```

and a bounded evaluation queue. Do not immediately add retained runners. Each evaluation can remain disposable.

A persistent daemon may then become justified, but that remains a separate product decision.

### If workflows must continue after the foreground command exits

The foreground-only topology is no longer sufficient. A daemon or supervisor must own:

- Host Store lock;
- executor lanes;
- waiting runs;
- workflow reevaluation;
- notifications.

QuickJS remains appropriate, but the Host topology changes.

### If thousands of sequential `await agent()` calls are a real workload

Ephemeral replay may become too expensive. The alternatives, in preferred order, are:

1. rewrite as bounded fan-out or pipeline stages;
2. add a Host-supported bulk-map helper only if repeated workloads justify it;
3. retain a runner between barriers under a strict budget;
4. introduce more durable orchestration state only as a last resort.

Do not jump directly to continuation serialization.

### If hostile multi-tenant scripts become a requirement

QuickJS plus a subprocess is insufficient.

Require at least one of:

- dedicated OS user;
- Linux namespaces plus seccomp/Landlock;
- hardened container;
- microVM;
- equivalent platform sandbox.

The engine process should have no access to the user’s Workspace or credentials even after native compromise.

### If Windows is a V1 platform

The same architecture applies, but process containment needs Windows-specific gates:

- Job Objects;
- handle inheritance allowlist;
- memory/CPU limits;
- restricted token or AppContainer if stronger isolation is claimed.

### If real workflows require npm packages

Add a separately named **trusted external Node client**, not a second transparent `onepage run` semantic mode. Make ambient authority explicit.

---

# Final architecture recommendation

Adopt QuickJS-ng, but make it mirror the same principle as the Zig Core:

```text
Core:
  restore compact state
  execute one bounded semantic quantum
  commit
  scrub and release slot

Workflow runner:
  restore control flow by replay
  execute one bounded JavaScript evaluation
  report terminal or blocked state
  destroy process and heap
```

That symmetry is the real product advantage.

The V1 execution path should be:

```text
workflow source + immutable args
        │
        ▼
fresh constrained QuickJS evaluation
        │
        ├── terminal durable results are visible
        ├── missing/pending jobs are durably ensured
        └── no live provider/tool completion enters this runtime
        │
        ▼
completed / blocked / failed / deadlocked
        │
        ▼
destroy runner
        │
        ├── completed → durably finish run
        └── blocked   → Zig waits with no JS residency, then replays
```

This gives OnePage a stronger and simpler V1 than the Node design:

- no external JavaScript installation;
- no npm dependency graph;
- no ambient workflow authority;
- low and explicitly bounded active-evaluation memory;
- structurally zero dormant-runner memory;
- no durable JS heap;
- no native asynchronous callback lifetime across model waits;
- deterministic exposure of durable results;
- one runtime and one workflow contract.

The QuickJS-specific production gate is necessary, especially around the allowlisted realm, strict value bridge, parent watchdog, and engine-version identity. It does not outweigh the evidence in favor of the pivot.
