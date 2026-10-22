# Whole-codebase modularity review of Rui

## Verdict: preserve the main owners; remove four smaller sources of coupling

Rui is not a collection of arbitrary layers around a database. Its strongest modules hide consequential mechanisms: Store transactions and fault fencing, provider callback/capture lifetime, Bash retirement, credential publication, and frontend submission recovery. Their size is not evidence that their responsibilities should be distributed. The most useful changes found here remove a forwarding function and a false storage dependency, then concentrate two pieces of duplicated or misplaced knowledge in existing owners. **Four changes are substantiated; the fifth slot is explicitly exploratory.** No correctness, security, performance or release-readiness guarantee follows from this structural review.

| Rank | Judgment / severity | Structural change | Expected benefit |
| --- | --- | --- | --- |
| R1 | **Act-on / low maintainability** | Remove the selection-to-Codex forwarding dependency; reuse Codex's model syntax rule in preferences. | Break the only cycle outside test bodies and stop spelling the same model rule in three places. |
| R2 | **Act-on / low maintainability** | Import the existing `attempt` owner directly in provider transport. | Remove a Store dependency that supplies only a re-exported value type. |
| R3 | **Consider / medium change-propagation risk** | Put scratch-name formatting and recognition together in existing `named_scratch`. | Producers and startup reclamation change one vocabulary, not seven modules independently. |
| R4 | **Consider / low-to-medium responsibility mismatch** | Move descriptor inspection and rejection wording out of provider-envelope interpretation, using existing `tools` and `output_format`. | Make the implementation's responsibilities match its already-correct admission phases. |
| R5 | **Noted / exploratory** | Investigate whether request encoding can lose its test-partition method without weakening exact-read checks. | Potentially reduce the production source interface; no demonstrated net simplification yet. |

“Act-on” means a concrete, low-cost structural correction worth making when this area is edited, not a newly imposed landing gate. “Consider” means the debt is real but the behavior-preservation cost could outweigh immediate benefit. There is no high-severity structural blocker established here.

## 1. Pin, method and coverage

- Repository: `DivyanshGolyan/rui`.
- Audited tree: **[068b1d0ce521b7a65fba118739fc985860cdd80f](https://github.com/DivyanshGolyan/rui/commit/068b1d0ce521b7a65fba118739fc985860cdd80f)**, fetched from `origin/main` at review start; pin recorded **2026-10-22T14:06:41Z**. All source locations below refer to that tree, not a moving branch. Later main changes are outside this audit.
- Reviewer: one fresh **GPT-6.1 Sol** reviewer, not an implementation author. No nested agents, oracle or second model. There is no agreement/consensus map because there is only one independent judgment. The interrogating rubric, code-quality lens and lead-judgment filtering informed the classifications above.
- Intent: assess separation of concerns, cohesion and coupling, Parnas information hiding, and Ousterhout module depth through actual callers and ownership. The unit of judgment is an interface and its obligations, not file length.
- Contract basis: `README.md`, `ARCHITECTURE.md`, root `AGENTS.md`, engineering/review/evidence sections of `CODING_STANDARDS.md`, and canonical gates in `VERIFICATION.md`. Intended layers below come from these contracts, not filename casing.
- Inventory is exhaustive for **every tracked file recursively under `src/`**, including native C, headers, include fragments, scripts and patches. This pin has no nested `src/` files. Header/declaration and dependency inspection covers that inventory; detailed call-chain reading concentrates on Store admission/content/reporting, provider materialization/interpretation, scratch reclamation, credentials, terminal input/consent, and frontend borrower ownership. This is **not** a line-by-line correctness proof of 70,517 lines or an exhaustive audit of every file outside `src/`.
- No application was run, no Host/account/Store was accessed, and no expensive qualification was launched. Only audit-tool compilation/execution and artifact checks were performed. Product, test, workflow and configuration files remain unchanged.

### Reproduce the measurements

From a checkout containing this report and the pinned `src/` and selector files, with Python 3.11+ and stock Zig 0.17.0:

```sh
python3 .amp/modularity/audit.py
python3 .amp/modularity/validate.py
git diff --check
```

`audit.py` enumerates `git ls-tree -r --name-only PIN src/`, reads each blob with `git show`, and checks both its bytes and the current recursive source inventory against the pin. Line counts are **newline-byte counts**, including comments, blank lines, embedded data and tests; bytes are raw blob length. `inventory.json` records per-file SHA-256, bytes, lines, extension, test declarations and lexical test-body lines. It does not call non-test lines “production LOC”: helpers outside test declarations still count there.

`tokenize.zig` parses each Zig file with the stock compiler AST parser, rejects syntax errors, then emits tokenizer tags and byte offsets. `audit.py` recognizes the actual `@import` builtin followed by a literal string, not substrings in comments, ordinary strings or multiline strings. It tracks enclosing test bodies and explicit `comptime {}` blocks. Negative controls exercise those distinctions and cyclic/acyclic graph examples. Import names with escapes fail closed; nonliteral names are marked dynamic rather than guessed. There are none in this pin.

Evidence files:

| Artifact | Contents |
| --- | --- |
| [inventory.json](inventory.json) | Every source file and exact size/hash/test-body measurements. |
| [edges.json](edges.json) | All 425 import occurrences, file/line, literal name, local/package/std/builtin/root kind, and lexical context. |
| [graph.json](graph.json) | Counts, unique-edge fan-in/out and strongly connected components for both graphs. |
| [imports.dot](imports.dot) | Complete local import graph, solid outside test bodies and dashed inside them; edge labels are source lines. |
| [selection.json](selection.json) | Actual pinned selector output for each proposed path set, including exact strict paths. |
| [reproduction.sha256](reproduction.sha256) | Matching hashes of the five regenerated graph/inventory/selection artifacts across two consecutive audit runs. |
| [audit.py](audit.py), [tokenize.zig](tokenize.zig), [validate.py](validate.py) | Reproduction, extraction controls and artifact consistency checks. |

## 2. Exhaustive source-module map

**Reconciliation:** 85 files = 69 Zig + 4 C + 4 shell + 3 patches + 3 headers + 2 include fragments. Total **70,517 lines / 3,603,116 bytes**. By role: 62 production/private-runtime Zig files + 9 native runtime/header/include files + 7 test-only Zig files + 7 build/patch inputs = 85. “Production/private runtime” includes code exercised only by private evaluator integration, not a claim that public Workflow support exists. Inline unit tests remain with their production owner. No committed generated source files occur in this inventory; generated bindings and patched dependency trees are described in section 3.

### 2.1 Production and private-runtime Zig: 62 files

Each row gives one responsibility and the owned data/invariants/effects. A pure/value row has no native I/O authority; a presentation row may write to a caller-supplied sink without owning the TTY.

| File | Lines | Responsibility; owned data, invariant and effects |
| --- | ---: | --- |
| `src/AnswerRenderer.zig` | 1063 | Incrementally render answer text with bounded fenced-block handling; owns streaming formatting state and safe text emission, not conversation or terminal custody. |
| `src/BashLifecycle.zig` | 583 | Decide process/pipe/stop/retirement transitions from supplied facts; owns lifecycle values and release predicates, with no syscalls or clock reads. |
| `src/ChoiceLine.zig` | 70 | Keep a typed Action-choice line isolated through its Enter; owns choice-line lifecycle, borrowing editor bytes and never granting permission itself. |
| `src/ClientTask.zig` | 95 | Own one joined Client borrower; owns worker context/status and ensures UI consumption follows join, with task/thread lifecycle effects. |
| `src/ConversationViewport.zig` | 900 | Retain bounded display text/styles and locate logical rows; owns display positions and Unicode layout calculations, not canonical history or TTY I/O. |
| `src/HostDiagnostics.zig` | 180 | Maintain bounded private startup diagnostics; owns rotating files and failure-disable state, with optional diagnostic effects and no semantic authority. |
| `src/ResponseTiming.zig` | 43 | Calculate response deadline renewal from supplied time/progress; owns timing values, preserving the original deadline across retries without reading a clock. |
| `src/ScratchBudget.zig` | 163 | Account shared and narrowed scratch reservations; owns atomic charge/release operations over borrowed counters, never files or semantic results. |
| `src/SessionFrontend.zig` | 1791 | Orchestrate one interactive Session invocation; owns drafts, terminal custody and joined read/submission borrowers while keeping workers off UI state and output. |
| `src/SessionInput.zig` | 193 | Hold one invocation's drafts and editor storage; owns stable-address input bytes and paste-related editing state, with no Host mutation authority. |
| `src/SessionScreen.zig` | 1442 | Prepare logical views, cells and delivered-presentation facts; owns bounded display/choice state and caller-writer rendering, not TTY reads or worker joins. |
| `src/SessionSubmission.zig` | 588 | Preserve original submission intent through uncertain Admission and retry; owns request identity/publication state and borrower lifetime, not canonical acceptance. |
| `src/SessionTerminal.zig` | 297 | Own persistent TTY custody for the frontend; owns modes, descriptor flags, alternate screen, bounded reads/draws and restoration obligations. |
| `src/TerminalEditor.zig` | 1063 | Edit decoded keys/text and read a fresh one-shot choice; owns draft cursor/edit validation plus choice-mode termios/redraw/restore effects, not Session submission. |
| `src/TerminalFrame.zig` | 271 | Allocate alternate-screen rows and decide which Action rows a frame delivers; owns layout values without terminal, file or clock custody. |
| `src/TerminalInput.zig` | 499 | Decode an invocation's byte stream and pending-input expiry; owns sequence/paste provenance and borrowed decoded text, with readers supplying bytes/time. |
| `src/TerminalText.zig` | 168 | Sanitize streamed terminal text and quote shell recovery commands; owns UTF-8/control filtering state and optional diagnostic emission, not UI lifecycle. |
| `src/TestObservation.zig` | 515 | Publish bounded opt-in native integration observations; owns record framing and publication-retirement counters over fixture handles, never semantic scheduling/recovery. |
| `src/attempt.zig` | 36 | Define immutable model/Action attempt bindings and consumable launch permits; owns one-shot permit availability as values without storage or effect handles. |
| `src/bash.zig` | 1768 | Prepare and run an admitted Bash Action and retain its cleanup/output custody; owns command buffers, process/pipe handles and captures while delegating lifecycle decisions. |
| `src/bounded.zig` | 24 | Store fixed-capacity UTF-8 values by value; owns bytes/length and UTF-8/capacity checks, with no I/O. |
| `src/cli.zig` | 2528 | Implement installed command orchestration and human/JSON presentation; owns argv/env-derived invocation state, Client/auth/defaults calls and output, not SQLite. |
| `src/cli_args.zig` | 565 | Define command grammar shared by help and pre-effect syntax validation; owns command/flag values without resolving canonical Session semantics. |
| `src/client.zig` | 5839 | Capture/recover caller mutation intent and exchange typed protected requests/replies; owns caller scratch/records, Unix-socket I/O and response validation, not Store tables. |
| `src/codex_auth.zig` | 186 | Orchestrate Codex device login, refresh and credential acquisition; owns curl exchanges and supplied cancellation/clock use, delegating record policy and private publication. |
| `src/codex_credential_policy.zig` | 601 | Interpret credential records and choose refresh/launch/local-readiness outcomes; owns record formats, bounded token values and pure policy, not files or network. |
| `src/codex_credentials.zig` | 490 | Securely lease, inspect and replace Rui credential records; owns locks, generations and atomic private-file publication, not provider/model selection. |
| `src/codex_token_wire.zig` | 450 | Build and interpret device-login/token messages; owns bounded request/response values and routing/account checks, with callers supplying network and time. |
| `src/deadline.zig` | 16 | Construct/compare awake deadlines from caller-supplied timestamps; owns value arithmetic, not a clock or timer. |
| `src/descriptor_capacity.zig` | 228 | Derive descriptor requirements and intake fit from actual owner populations; owns checked capacity values/refusals, not process limits or handle allocation. |
| `src/descriptor_limit.zig` | 110 | Observe/raise native descriptor limits and normalize OS results; owns limit observation values and native query/update effects. |
| `src/evaluator.zig` | 238 | Own the private evaluator invocation and charged output; owns anonymous scratch, cancellation/diagnostics and parent-bridge lifetime, not public Workflow admission. |
| `src/execution.zig` | 1035 | Represent execution decisions and bounded custody/dispatch state; owns slot generations, attempt bindings and release conditions as values, not SQLite or native processes. |
| `src/execution_turn.zig` | 590 | Order bounded execution/control/cleanup service turns; owns service-state/deadline decisions over a supplied context whose shell performs effects. |
| `src/json_ascii.zig` | 139 | Re-spell valid JSON as terminal-safe ASCII without changing its value; owns streaming Unicode escape projection to a supplied writer. |
| `src/model_adapter.zig` | 2604 | Lower frozen historical inputs into Codex requests and coordinate interpretation/auth handoff; owns bounded preparation cursors/request scratch and adapter grammar, borrowing Store readers. |
| `src/model_capability.zig` | 62 | Describe local Codex model syntax and compaction capability; owns exact known-model metadata and pure capability values, not entitlement/network discovery. |
| `src/named_scratch.zig` | 234 | Retain named scratch cleanup custody and release charges only after safe reclamation; owns file/read aliases/removal policy and evaluator-name format/recognition. |
| `src/new_session_selection.zig` | 189 | Resolve prospective new-Session choices from one local snapshot; owns copied preferences/defaults/readiness inputs and pure selection, never existing Session rebinding. |
| `src/output_format.zig` | 255 | Encode/decode shared output metadata and delimited-string projections; owns metadata records, charged writer/seal/read handles and bounded scalar decoding, not Store/provider policy. |
| `src/output_retention.zig` | 579 | Retain optional full Bash output in a bounded FIFO; owns reservation/eligibility/eviction state and deletion/charge release, not canonical results. |
| `src/platform.zig` | 757 | Resolve private Store paths and own exclusive serving preparation; owns lease/runtime-directory/socket/scratch cleanup effects without canonical SQL decisions. |
| `src/preference_values.zig` | 24 | Hold prospective default choices and derive HOME-relative default paths; owns bounded copied values and path calculation, not file publication. |
| `src/preferences.zig` | 524 | Load and atomically apply explicit preference edits; owns private-file validation, locking/rename/sync and saved-pin semantics, separate from credentials and Store configuration. |
| `src/product_defaults.zig` | 43 | Supply accepted omitted-value defaults to all entry surfaces; owns shared constants and their assertions, not rewrites of saved/running state. |
| `src/protocol.zig` | 2575 | Define protected public request/value contracts and streaming ingress content capture; owns closed syntax, limits, hashing/sealed source custody and charged scratch, not canonical transactions. |
| `src/provider.zig` | 1207 | Drive shared provider transport and sealed response capture; owns curl handles/callbacks, progress/deadline facts, headers and capture drainage, not retry/permission decisions. |
| `src/provider_output.zig` | 2452 | Authenticate provider envelopes/replay projections and inspect certified calls; owns streaming parser/evidence/range state and metadata output, plus the misplaced tool bridge discussed in R4. |
| `src/provider_selection.zig` | 111 | Choose a prospective provider/model from supplied capabilities and pins; owns readiness/selection values and no-fallback policy, plus the redundant Codex forwarding function in R1. |
| `src/request_encoding.zig` | 1259 | Stream/measure provider JSON encodings over immutable positional sources; owns bounded cursor/escape state and exact-read requirements, not source files or Store queries. |
| `src/retry_policy.zig` | 122 | Calculate retry limits/waits and provider delay constraints from supplied facts; owns schedule/arithmetic policy reused by Store SQL constraints, not retry execution. |
| `src/server.zig` | 7659 | Own a serving Host's intake, canonical handoff and effect service shell; owns listener/exchange/capture/slot resources and startup/shutdown sequencing while Store owns durable authority. |
| `src/session_consent.zig` | 268 | Derive permission eligibility from completed presentation and input observations; owns consent state transitions without editors, workers, terminal effects or canonical authorization. |
| `src/session_departure.zig` | 126 | Decide frontend departure obligations from completed-effect facts; owns pure cancellation/join/restoration decisions, never claiming effects it did not observe. |
| `src/session_history.zig` | 454 | Prepare one bounded Conversation page atomically before rendering; owns page summaries/content scratch protocol and export presentation without retaining the population. |
| `src/session_reads.zig` | 993 | Run frontend read/inspection jobs over frozen borrower inputs; owns job results, bounded reconciliation/planning facts and Client reads, without importing or mutating the frontend. |
| `src/session_view.zig` | 1389 | Present Activity/history/tool facts in one bounded forward pass; owns text/collapse/projection state and caller-sink emission, not retry or permission authority. |
| `src/stderr.zig` | 54 | Serialize optional stderr borrowing and permanent disable-on-failure; owns atomic writer custody and diagnostic writes, never canonical success. |
| `src/store.zig` | 16428 | Own canonical SQLite identity, provenance, admission, content, settlement and recovery transactions; owns the connection/lock/fence/readers and atomic consequences, with report-scratch capture before delivery. |
| `src/tools.zig` | 443 | Define tool descriptors and pure frozen-catalog classification; owns Bash schema/parser/argument facts and admission decisions, with no SQL, process launch or permission grant. |
| `src/transport_policy.zig` | 386 | Classify transport completion/capture/deadline facts; owns pure evidence decisions, leaving curl/callback/clock/capture resources to provider. |
| `src/turn_policy.zig` | 145 | Decide Turn completion/continuation/compaction over transactional facts; owns pure outcome policy without a second copy of canonical state. |

### 2.2 Native runtime/private evaluator: 9 files

| File | Lines | Responsibility; owned data, invariant and effects |
| --- | ---: | --- |
| `src/bash_platform.c` | 173 | Adapt POSIX/Darwin Bash spawn, process observation/reap and queued-pipe inspection; owns native syscall translation while Zig retains lifecycle/custody policy. |
| `src/host_launch.c` | 249 | Implement native detached Host exec/readiness/error handoff and descriptor-limit raising; owns helper framing/signals/child descriptors, not readiness or Store policy. |
| `src/evaluator_child.c` | 413 | Run the disposable private QuickJS child and stream strict-data output; owns engine/input/encoding state and framed stdio effects without JS filesystem/network/process capabilities. |
| `src/evaluator_parent.c` | 358 | Spawn/watch/reap one evaluator child and forward bounded output; owns pipe/pthread/watchdog/native process resources through completed cleanup. |
| `src/evaluator_parent.h` | 27 | Declare the private parent/append/cancellation bridge; owns C interface types and return meanings, not implementation or public Workflow authority. |
| `src/evaluator_policy.h` | 11 | Declare compiled-module policy inspection; owns the private QuickJS validation interface without executing author code. |
| `src/evaluator_policy.inc` | 25 | Inspect pinned QuickJS compiled-module policy markers; owns engine-layout-dependent acceptance checks inside the generated translation unit. |
| `src/evaluator_string_reader.h` | 41 | Declare bounded engine-string sizing/streaming callbacks and diagnostics; owns private bridge types rather than exposing QuickJS representation to callers. |
| `src/evaluator_string_reader.inc` | 151 | Stream/safely size QuickJS strings through that private bridge; owns pinned string-layout access, bounded allocation and callback failure propagation. |

### 2.3 Test-only Zig roots, oracles and helpers: 7 files

These roles explain why “outside a test body” is not identical to “production reachable.”

| File | Lines | Responsibility; owned data, invariant and effects |
| --- | ---: | --- |
| `src/tests.zig` | 41 | Aggregate native module tests; owns test imports only, with effects performed by imported tests. |
| `src/logic_tests.zig` | 60 | Aggregate portable value-owner tests and core-boundary checks; owns the maintained core list and source-verification invocation. |
| `src/core_boundary.zig` | 341 | Token-check functional-core dependency/effect restrictions; owns allowlists and source inspection as test enforcement, not runtime dispatch. |
| `src/socket_fixture.zig` | 213 | Own private real pathname sockets for tests; owns temporary directories/paths and cleanup and compile-rejects non-test use. |
| `src/session_sequence_model_test.zig` | 645 | Compare bounded frontend transition sequences with an independent oracle; owns test model/fixture state and injected native handles, not product state. |
| `src/terminal_input_equivalence_test.zig` | 537 | Check independently expected key/paste/editor outcomes across fragmented encodings; owns test vectors/oracles and no installed entry point. |
| `src/terminal_notice_test.zig` | 64 | Exercise production terminal input/notice/restoration as a native actor; owns test process/stdio handling without Host or Store access. |

### 2.4 Build recipes and dependency patches: 7 files

| File | Lines | Responsibility; owned data, invariant and effects |
| --- | ---: | --- |
| `src/build_evaluator.sh` | 8 | Generate the evaluator-only patched QuickJS translation unit; owns generated output assembly while preserving pinned dependency inputs. |
| `src/build_transport.sh` | 147 | Build pinned TLS/H2/curl archives for selected targets; owns toolchain/configure/build outputs, not runtime connection policy. |
| `src/fetch_dependencies.sh` | 70 | Fetch/verify the manifest's native dependency graph into the selected package directory; owns download/extraction preparation with network/disk build effects. |
| `src/prepare_vaxis.sh` | 11 | Copy and patch the exact Vaxis dependency into a build-owned tree; owns generated source output without mutating shared packages. |
| `src/curl-post-retry.patch` | 43 | Disable hidden POST replay in pinned curl retry paths; owns build-time transport-policy edits, whose runtime effect preserves Rui retry authority. |
| `src/evaluator_policy.patch` | 91 | Add the private evaluator's compiled-module/parser policy markers to pinned QuickJS; owns build-time engine edits, not a second Workflow runtime. |
| `src/vaxis-parser.patch` | 689 | Correct pinned Vaxis key/parser/width behavior used by Rui; owns build-time dependency edits with terminal decoding/layout effects. |

## 3. Dependency graph and intended layering

### Measured graph, not a reachability simulation

There are **425 actual `@import` occurrences**: **306 local**, **70 `std`**, **22 `builtin`**, and **27 package/generated**. There are **zero `root`, unresolved-local or dynamic imports** in the pin. Duplicate occurrences reduce to **278 unique local directed edges**. Excluding imports lexically inside `test` declarations leaves **215 unique edges**. Explicit enclosing `comptime {}` blocks contain no imports in this pin.

Every Zig import is compile-time module resolution; “comptime block” here only identifies syntax context, not a supposed runtime import. The extractor does not evaluate `builtin.is_test`, target branches, Zig lazy declaration resolution, generic instantiations or per-executable build roots. Thus the second graph is named **outside-test-bodies**, not “the production graph.” Test-only roots/helpers and conditional declarations remain in it. C `#include`/link calls, shell execution and patches are not Zig imports; their ownership/build relations were inspected separately, not silently included in SCC calculations. Package internals are outside this first-party graph, so this is not a claim about cycles in all transitive dependencies.

The package/generated occurrences resolve through `build.zig`:

| Import name | Occurrences | Resolution |
| --- | ---: | --- |
| `posix` | 12 | Generated translate-C bindings from selected native headers (`build.zig:1097–1118`). |
| `curl` | 2 | Generated curl/time bindings and pinned transport libraries (`build.zig:951–985`). |
| `sqlite` | 1 | Generated sqlite bindings and pinned amalgamation (`build.zig:989–1004`). |
| `evaluator_native` | 1 | Generated private parent-header bindings (`build.zig:86–94`). |
| `transport_options` | 1 | Build-generated enabled flag (`build.zig:958–961`). |
| `vaxis` | 6 | Build-owned patched Vaxis module, retaining upstream imports (`build.zig:1042–1080`). |
| `terminal_unicode`, `terminal_width` | 2 each | Value-only Unicode/width roots in that same patched dependency, with `uucode` (`build.zig:1066–1079`). |

### Four all-lexical SCCs, only one survives test-body exclusion

| SCC | Evidence and judgment |
| --- | --- |
| `codex_auth ↔ codex_credentials` | Credentials' reverse edge is a test import at `src/codex_credentials.zig:335`; not evidence of a production auth/file cycle. |
| `model_adapter → provider → store → model_adapter` | Store's adapter imports at `src/store.zig:10297,10354` are tests; the production-facing provider-to-Store edge is nevertheless unnecessary (R2). |
| **`model_capability ↔ provider_selection`** | `src/model_capability.zig:3` needs selection values; `src/provider_selection.zig:23` forwards back into the concrete adapter's capability. Both are outside test bodies (R1). |
| `named_scratch ↔ protocol` | Scratch's reverse imports are tests at `src/named_scratch.zig:112,157,194`; not a production scratch/protocol cycle. |

The remaining SCC is a **module knowledge cycle**, not an observed runtime recursion or compiler failure. Deleting `provider_selection.codex` removes the policy's need to know its concrete capability provider; test-specific adapter imports may remain in tests.

### Intended roles explain most fan-in and fan-out

Conceptual dependency summary, with arrows meaning “uses,” not thread/message flow:

```text
CLI / frontend ────────→ Client ────────→ protocol / content custody
                             (protected transport, not SQLite)
Host server ───────────→ Store ─────────→ transactional value policies
     │                    │
     └─→ effect owners    └─→ certified projections / immutable readers
             │
             └─→ shared scratch, attempt values and native adapters
```

The Host shell legitimately joins durable facts with native resource facts. Effect owners receive frozen bindings/readers and return evidence; they must not choose permission/retry authority or issue SQL. Selection is policy over supplied capabilities, so its reverse dependency on the Codex capability is misplaced. Shared path preparation legitimately owns filesystem/lease operations but should not independently encode every producer's scratch vocabulary (R3).

Outside-test-body fan-in leaders, counting unique importing files: `protocol` **23**, `named_scratch` **10**, `client` **9**, `TerminalText` **8**, `TerminalEditor`, `TerminalInput`, `platform`, `product_defaults` **7 each**, `tools` **6**, `ScratchBudget`, `session_view`, `stderr` **5 each**. Fan-out leaders: `cli` **22**, `server` **20**, `SessionFrontend` **17**, **test root `logic_tests` 16**, `model_adapter` **13**, `store` **11**, `session_reads` **10**, `bash` **8**. Full ranked arrays for both graphs are in `graph.json`.

Those counts identify where to inspect propagation, not what to split. `protocol` holds widely consumed representation contracts; the CLI/frontend/Host are expected composition owners. Neither CLI nor Client directly imports Store or opens SQLite. `provider → store` has no SQL use but is a removable dependency on a re-export. Bash's Store reader and resolution types require separate reasoning and are not the same alias-only case.

## 4. Findings with ownership traces and counterarguments

### R1 — Act-on: remove the capability back-edge and duplicate model syntax

**Evidence.** [`src/provider_selection.zig:22–24`](https://github.com/DivyanshGolyan/rui/blob/068b1d0ce521b7a65fba118739fc985860cdd80f/src/provider_selection.zig#L22-L24) is a pass-through to `model_capability.capability`. That concrete capability imports selection's `Readiness`/`Capability` at [`src/model_capability.zig:3,47–49`](https://github.com/DivyanshGolyan/rui/blob/068b1d0ce521b7a65fba118739fc985860cdd80f/src/model_capability.zig#L41-L49). Real callers are `src/new_session_selection.zig:72`, `src/cli.zig:269,336`, and `src/preferences.zig:105,138`.

`model_capability.validModel` owns the 1–256 printable non-space ASCII rule (`src/model_capability.zig:41–44`). Preferences repeats its byte rule in [`src/preferences.zig:33–35,135–140`](https://github.com/DivyanshGolyan/rui/blob/068b1d0ce521b7a65fba118739fc985860cdd80f/src/preferences.zig#L129-L140), then resolves through the capability, which validates it again. The saved-value path already has bounded length and permits empty as “no pin”; that exception is intentional, not a contradictory model grammar.

**Consequence and smallest correction.** Selection's generic policy depends on the concrete capability it is meant to consume. Adding/changing local model syntax requires synchronizing independent preferences checks. Call `model_capability.capability` directly from composition callers, delete the forwarding function, and reuse `validModel` for nonempty saved pins and explicit edits, preserving preference-specific errors and validation before file effects. Keep capability types/selection in their existing owner; add no registry or module.

**Contract classification.** `ARCHITECTURE.md:908` explicitly says Codex owns local identifier syntax; duplicated enforcement is an implementation-locality defect, not changed accepted behavior or proven documentation drift. The generic selection policy remains useful: it expresses explicit/saved/sole-usable precedence, no fallback, and recommendation semantics; deleting that policy would push real complexity into callers. Printable-byte checks elsewhere in credential/header validation are different security contracts, not copies of the model rule.

### R2 — Act-on: remove transport's alias-only dependency on Store

**Evidence.** [`src/provider.zig:6`](https://github.com/DivyanshGolyan/rui/blob/068b1d0ce521b7a65fba118739fc985860cdd80f/src/provider.zig#L1-L9) imports Store. Its only `store.` uses are `AttemptBinding` at **438, 538 and 545**. Store's definition at `src/store.zig:396` is already an alias of the actual value owner, [`src/attempt.zig:21–25`](https://github.com/DivyanshGolyan/rui/blob/068b1d0ce521b7a65fba118739fc985860cdd80f/src/attempt.zig#L21-L25). Transport needs the immutable admitted identity, not any Store behavior.

**Consequence and smallest correction.** Import `attempt.zig` directly and name `attempt.AttemptBinding`. This removes storage knowledge from a transport module with no adapter, new interface or changed data layout. It is an information-hiding improvement; no compile-time or runtime speedup was measured.

**Analogue search and limit.** `src/bash.zig:925,1572` consumes the concrete opaque `store.ContentReader` and `:511,750,837` uses canonical resolution codes. `model_adapter` similarly consumes a historical view, as required by `ARCHITECTURE.md:570`. Neither is an alias-only dependency, and neither inspection established a caller-issued SQL leak. Replacing those readers with a generic effect interface would introduce machinery that the contract expressly does not require. The policy says effects own no SQLite (`ARCHITECTURE.md:564`); the current provider import does not mean provider actually accesses SQLite.

### R3 — Consider: producers and reclamation duplicate the scratch-name schema

**Evidence.** Startup spells six numeric name families and their zero exceptions in [`src/platform.zig:253–280`](https://github.com/DivyanshGolyan/rui/blob/068b1d0ce521b7a65fba118739fc985860cdd80f/src/platform.zig#L253-L280). Producers independently format request names at `src/protocol.zig:1534,1544` and `src/model_adapter.zig:540`; responses at `src/provider.zig:449`; response metadata at `src/server.zig:2727`; Bash output through the prefixes at `src/bash.zig:945–946` and formatter at `:996`; reports at `src/store.zig:847`. `model_adapter.zig:2064` repeats a request name in a test. The existing positive analogue is [`src/named_scratch.zig:5–25`](https://github.com/DivyanshGolyan/rui/blob/068b1d0ce521b7a65fba118739fc985860cdd80f/src/named_scratch.zig#L5-L25): `EvaluatorName` owns both formatting and recognition, and evaluator/startup consume it.

**Consequence and smallest correction.** A new or renamed producer must remember a distant startup recognizer; omission strands owned files, while an overbroad recognizer risks unrelated files. These are change-propagation hazards, **not observed current misclassification**. Extend existing `named_scratch` with closed numeric name kinds and their formatter/recognizer, and use them at all producer sites. Delete platform's private prefix vocabulary. Keep creation, deletion, locking, charging and cleanup custody in their current owners. Do not add a filesystem service, name registry, new persisted format or compatibility reader.

**Contract classification.** The exact name/zero/lookalike rules are intentional accepted behavior (`ARCHITECTURE.md:1253`), and current code implements that documented vocabulary. This is duplicated implementation knowledge, not a contract violation. Preserve byte-for-byte existing names, positive-u64 rules, request/report zero exceptions, evaluator naming, file-type refusal, and removal-failure startup refusal. Centralization pays because formatter and recognizer genuinely vary together across existing consumers; a new module just to relocate strings would not.

### R4 — Consider: provider-envelope interpretation contains core tool policy glue

**Evidence.** [`src/provider_output.zig:42–102`](https://github.com/DivyanshGolyan/rui/blob/068b1d0ce521b7a65fba118739fc985860cdd80f/src/provider_output.zig#L42-L102) imports `tools`, recognizes `bash`/`edit`, runs Bash descriptor inspection and formats canonical rejection prose. The actual invocation is **inside Store admission**: [`src/store.zig:5998–6008`](https://github.com/DivyanshGolyan/rui/blob/068b1d0ce521b7a65fba118739fc985860cdd80f/src/store.zig#L5998-L6008) calls that inspector, `tools.classifyCall` against frozen tools, and the provider module's rejection formatter before importing the result. `tools.zig:19–28,44–46` already owns tool-name/classification/descriptor facts. `output_format.zig:18–29,213–255` already owns metadata records and the encoded-string reader.

**Consequence and smallest correction.** A tool descriptor/rejection change currently modifies a provider-envelope parser even though the provider envelope need not change. Move decoded-string cursor mechanics beside `EncodedStringReader`; move tool-name/descriptor/rejection policy beside `tools`, operating on supplied sources/bounded name facts. Store continues to sequence authentication, inspection, frozen-catalog classification and atomic import. Delete the provider-specific bridge rather than add another forwarding module. Keep `tools` free of concrete file ownership/native I/O; do not move opaque provider grammar into it.

**Contract classification and counterargument.** `ARCHITECTURE.md:571` says provider interpretation cannot validate executable descriptors; `:528` and `:462` put tool classification inside canonical admission. The **physical module responsibility is blurred**, but the traced phase ordering/authority is correct: these helpers run under Store, not as transport authorization. This is not a demonstrated unauthorized Action or documentation behavior drift. A short bridge can be reasonable at a seam; move it only if the result reduces knowledge spread without making Store learn provider syntax. Store's other `provider_output` uses (`src/store.zig:571,3151`) authenticate replay/proposal projections and must not be removed just to lower fan-out.

### R5 — Noted: test partitioning is visible in the production encoding interface

[`src/request_encoding.zig:6–14,33–37,40–66`](https://github.com/DivyanshGolyan/rui/blob/068b1d0ce521b7a65fba118739fc985860cdd80f/src/request_encoding.zig#L6-L66) requires every source to provide `maxWindow`; the comment explicitly distinguishes native from test partitioning. The native HistoricalSource method at [`src/model_adapter.zig:398–402`](https://github.com/DivyanshGolyan/rui/blob/068b1d0ce521b7a65fba118739fc985860cdd80f/src/model_adapter.zig#L384-L402) returns its input unchanged, while four cursor refill sites consult it (`request_encoding.zig:178,249,505,565`). This is a real test-induced interface obligation.

However, it deliberately tests partition boundaries **without treating a short canonical read as success**. Merely deleting the method or accepting arbitrary short reads would weaken an important invariant. No simpler replacement has been demonstrated here. A bounded prototype could ask whether cursor-owned test input construction can exercise the same boundaries with fewer source obligations; reject it if it introduces source-type introspection, conditional production branches or a second encoding implementation. This is **not a fifth substantiated refactoring recommendation**.

## 5. Deep/cohesive modules to keep, and rejected accusations

### Store's actual size does not establish a god-module defect

**Store is exactly 16,428 lines and 910,397 bytes**, with **153 test declarations occupying 7,905 lexical lines**. The other **8,523 lines still include fixture helpers**; they are not an asserted production-line count. It is the largest source file by a wide margin, but its core decisions are coupled by the canonical transaction, not accidentally colocated.

[`src/store.zig:1255–1400`](https://github.com/DivyanshGolyan/rui/blob/068b1d0ce521b7a65fba118739fc985860cdd80f/src/store.zig#L1255-L1400) centralizes mutex entry, ordinary-error declarations, rollback and fence behavior. Tool import at `:5940–6045` must publish content/provenance/call classification/Action consequences atomically. Splitting these into table repositories or a generic transaction bus would make callers learn ordering and partial-failure rules currently hidden by Store. Report capture at `:825–880` writes private scratch before delivery; the exception is explicit in `ARCHITECTURE.md:564,886`. Moving that capture to CLI would expose SQL/read-snapshot policy, not deepen the module.

This is a large cohesive canonical owner with some inspectable local responsibility debt (R4), **not proof that every declaration is optimally placed**. Retain its transaction interface. If future independently changing responsibilities emerge, separate those with evidence rather than split by table or line threshold. Its many domain operations make the interface broad, but they preserve semantic operations rather than force callers to assemble row mutations.

| Candidate accusation | Judgment / severity | Evidence and reason |
| --- | --- | --- |
| “Server is 7,659 lines, so split it into services.” | **Dismissed / size-only** | 3,011 lines are lexical test bodies. Host startup/intake/resource retirement and the execution shell must coordinate real handles; the pure `execution_turn`/`execution` decisions already have separate owners. No independently justified new service/interface was found. |
| “Client is 5,839 lines and leaks storage into CLI.” | **Dismissed / unsupported** | 2,306 lines are lexical test bodies. Typed protected replies and local caller request capture are distinct from canonical Store SQL. CLI/Client import inspection found no Store import; Client's local record I/O is its documented recovery obligation. |
| “Protocol is an arbitrary utility bucket.” | **Dismissed / not established** | Its closed grammar, bounded values, content hashing and sealed-ingress custody support the public operation boundary. High fan-in is expected; consumer-derived SQLite representability bounds are not SQL-query access. Native ingress effects mean it is not a pure core; `src/logic_tests.zig:8–24,27–45` distinguishes the restricted core list from other test-logic imports. |
| “Credential wrappers should be merged into one module.” | **Dismissed / loses a useful seam** | `codex_auth` performs exchanges, `codex_credentials` publishes/leases files, and `codex_credential_policy`/`codex_token_wire` return values. `codex_auth.zig:36–47,135–186` contains orchestration, not just forwarding. Credential Bounded/Required differ from `bounded.zig` in validation/error/nonempty contracts; merging those storage types is not a free deletion. |
| “Bash duplicates a state machine across files.” | **Dismissed / intentional separation** | `BashLifecycle` has no OS effects; Bash owns processes/pipes/capture and supplies observations. Cleanup requires several independent physical facts, not a single done flag. Combining the two would hide testable policy inside native effects. |
| “Provider transport should be a thin curl wrapper.” | **Dismissed / removes depth** | `src/provider.zig:430–570` owns capture/transfer handles and binding; `transport_policy` decides supplied evidence. Callback/capture retirement can outlive a terminal result. Exposing those phases to every caller would expand their interface obligations. R2 removes only the unnecessary type dependency. |
| “Frontend modules are shallow pass-through layers.” | **Dismissed / generally false** | `SessionSubmission` retains original identity and uncertain publication; `session_reads` isolates workers from frontend state; `session_consent` distinguishes presentation from permission. These modules hide independent changing obligations rather than merely rename one call. |
| “TerminalEditor's native choice reader is dead now SessionTerminal exists.” | **Dismissed / actual caller exists** | `src/cli.zig:891` uses the one-shot reader for the provider chooser; `src/TerminalEditor.zig:82–110` owns fresh-choice mode restoration while SessionTerminal owns persistent conversation custody. No obsolete replacement path was established. |
| “TestObservation is a second production scheduler.” | **Dismissed / authority not traced** | `src/TestObservation.zig:11–26,109–163` provides opt-in receipt publication/retirement, not canonical permission or dispatch. Required observation loss fails evidence; it does not authorize semantic work. Test-only holds are guarded with `builtin.is_test`. |
| “Store's historical fixture is a runtime mutation backdoor.” | **Dismissed / compile-time excluded** | `src/store.zig:1408–1409` compile-errors outside tests; `:1262` elides testing counters in production. The fixture is not a public operation. |
| “Bash result labels and view parsing are duplicate authority.” | **Noted / low presentation coupling** | `src/bash.zig:750–832` emits canonical result prose; `src/session_view.zig:1165–1220` recognizes tails/retention lines for presentation, not execution. `ARCHITECTURE.md:1269` intentionally specifies that text. A new persisted result format would be a separate contract change, not a justified structural fix here. |
| Two duplicate constructor pass-throughs. | **Noted / low directness debt** | `src/provider.zig:50–60` and `src/model_adapter.zig:325–335` each repeat `retainedNamedScratch`, forwarding every argument unchanged to existing `named_scratch.Owner.init`; six real error branches call them. `protocol.zig:1594` and `output_format.zig:58` already call that owner directly. Deleting both wrappers is safe-looking local simplification (about 22 lines), not grounds for another architectural layer or a major fifth finding. |
| Host test knobs exist in installed code. | **Noted / intentional opt-in instrumentation** | Unlike Store's compile-excluded fixture, `src/cli.zig:1095–1168` maps explicit fault/test flags into `src/server.zig:48–109`; `:3295–3324` can hold a transition at a FIFO. These are real test interventions, not all compile-elided passive receipts. Removing them would need replacement native crash/fault evidence; no simpler behavior-preserving seam was established. |
| Unused duplicate scratch default in transport. | **Noted / low** | `src/provider.zig:14` repeats the Host's 8-GiB constant at `src/server.zig:26` but has no other references. Remove the unused declaration when touching transport; it does not currently create a second enforced budget or justify another defaults module. |
| “Unused server TerminalText import proves bad layering.” | **Noted / trivial** | `src/server.zig:4` has no other `TerminalText` identifier use. This is a removable lexical edge, not a structural finding worth a top-five slot. |

These dismissals do not assert universal correctness. They record why plausible size, dependency and test-hook accusations did not survive caller/authority tracing.

## 6. Ranked change plans, estimated cost and exact policy mapping

**No changes below were implemented or qualified.** All LOC deltas are rough **net whole-source estimates**, not measurements or promised savings. They come from counting the identified forwarding/duplicated/helper blocks, allowing replacement call-site/import code, and excluding speculative test growth. Relocation is not counted as deletion. The estimates intentionally allow positive growth where locality, not fewer lines, is the benefit.

| Rank | Concrete move and affected owner/callers | Estimated net LOC and basis | Risk and preserved behavior |
| --- | --- | --- | --- |
| R1 | Delete `provider_selection.codex`; composition callers in CLI, new-session selection and preferences call existing capability owner; preferences reuse `validModel` with empty-pin handling/error mapping. | **−5 to −15**: remove four-line shim plus duplicate explicit-edit byte/length checks, offset by direct imports/empty-pin/error mapping. Existing tests may use test-scoped imports. | Low; preserve explicit/saved/default precedence, unsupported saved-provider behavior, readiness snapshot, empty saved pin, 256-byte boundary, invalid-edit error classes and no file effects before validation. |
| R2 | Replace provider's Store import/three binding references with the existing `attempt` owner. | **About 0**: import/type substitution, no implementation moved. | Very low; exact same aliased type, binding/permit/capture lifetime unchanged. |
| R3 | Add closed numeric naming alongside `EvaluatorName` in `named_scratch`; switch all six producer families and platform recognition; remove platform's independent grammar. | **−10 to +35**: relocate roughly 30 recognizer lines, replace seven production formatting/prefix sites, allow typed formatting/zero rules and buffer-size adjustments. | Medium; cleanup eligibility is destructive. Preserve exact names, zero/overflow/lookalike rejection, foreign-file preservation, file-type refusal and retry-safe charging/retirement. No format version or compatibility machinery. |
| R4 | Place generic decoded-string cursor beside existing output codec; put tool inspection/rejection policy in tools; update Store's atomic-import calls and remove provider bridge. | **−15 to +15**: about 60 helper lines move rather than disappear; range depends on bounded name-fact plumbing and reused string-reader operations. | Medium; preserve byte-for-byte rejection results, decoded-name digest/truncation, escaped arguments, frozen tool precedence, authenticated ranges and all-or-none import. Keep replay authentication in its current parser owner. |
| R5 exploratory | Only prototype removing `maxWindow` from production source obligations in request encoding and HistoricalSource; do not remove fragmentation tests or relax exact reads. | **No substantiated net delta**. At most the identified pass-throughs disappear; replacement test machinery is unknown and may cost more. | Medium if attempted; missing/short canonical bytes must still fail at the original boundary. Keep current design unless a demonstrably smaller alternative preserves that property. |

### Selector-derived checks, not invented qualification requirements

`selection.json` is generated by the pinned **actual** `tests/ci/select_tests.py.select(paths, "review", available)` and `strict_paths.strict(paths)`, using the target names from pinned `build.zig`. These are proposed source path sets, **not** the report-only branch's runtime changes. New regression files or additional owner edits must be added to the selection when implementation exists. “Mac” below is the selector's `native_targets`; it does not mean native tests ran.

| Rank | Exact proposed strict paths | Linux minimum (`zig build TARGET`) | Mac mapped targets |
| --- | --- | --- | --- |
| R1 | None | `admission-debug-integration`, `check`, `codex-h2-integration`, `test-logic`, `transport-h2-integration` | Same as Linux. |
| R2 | None | `dispatch-integration`, `test`, `transport-h2-integration` | Same as Linux. |
| R3 | `src/server.zig`, `src/store.zig` | `admission-debug-integration`, `check`, `codex-h2-integration`, `dispatch-debug-integration`, `transport-h2-integration` | Same as Linux. |
| R4 | `src/store.zig` | `check`, `dispatch-debug-integration`, `test-logic`, `transport-h2-integration` | Same as Linux. |
| R5 exploratory | None | `dispatch-integration`, `test`, `test-logic`, `transport-h2-integration` | `dispatch-integration`, `test`, `transport-h2-integration`. |

The complete path sets/reasons and retry policy are machine-readable. R3's composed `check` subsumes the separately mapped Bash targets; R4's `test-logic` comes from `tools`. R1 includes startup/H2 consequences of editing CLI, not just portable selection tests. `src/bash.zig` itself is **not** a strict path; `tests/integration/bash*` is. `src/execution*` is strict, but no proposed plan here edits it. None requires changing build/CI policy. Strict-path counterexamples need the before-fix/mutation evidence in `CODING_STANDARDS.md`; main accepts exact-tip Linux Selected, and stable separately requires exact-SHA Mac/upgrade qualification under `AGENTS.md`. This report grants no compatibility, migration, implementation or landing authority.

For an eventual implementation, keep focused behavior regressions in the existing owner suites: R1 selection/preferences error boundaries, R2 existing binding/transport cases, R3 formatter/recognizer agreement plus startup lookalike/type/removal controls, R4 unknown/edit/invalid-Bash/sibling rejection and late import rollback, R5 partition-boundary and premature-EOF controls. A structural refactor should make existing owner tests pass unchanged wherever their observable contract is unchanged. No resource speedup or memory reduction is claimed, so an unrelated resource campaign would not prove this audit.

## 7. Artifact validation and limitations

The kept audit scripts verify actual pinned bytes/inventory, reject invalid Zig, exercise extractor negative controls, recompute graph counts/SCCs and compare each map row/line count with inventory. `validate.py` checks pinned file/line references, resolves report artifact links, checks package totals, independently checks SCC membership by mutual reachability, and verifies selector/source identity. Two audit-tool compile attempts during development failed on obsolete helper/API usage (`dupeZ` and an AST parse option); both were corrected before the recorded successful runs. The first report-validator run incorrectly treated root `build.zig` references as `src/build.zig`; after correcting path resolution, source-anchor checking caught an off-by-one citation to the capability forwarding import, now corrected to line 23. These are audit-tool/report development failures, not product qualification failures or hidden retries of a product gate.

Recorded successful validation on the Linux x86-64 orb, 2026-10-22, Python **3.11.6**, Zig **0.17.0**:

| Command | Observed result |
| --- | --- |
| `python3 .amp/modularity/audit.py` (two consecutive final reproductions) | PASS extraction controls, all 69 Zig files parsed, 85 files / 70,517 lines / 3,603,116 bytes; 278 all-lexical and 215 outside-test-body edges. |
| `python3 .amp/modularity/validate.py` | `PASS: 85/85 map rows, pinned sizes/hashes, 425 import anchors, both SCC/fan graphs, selectors, references and decisive source anchors`. |
| `sha256sum -c .amp/modularity/reproduction.sha256` | All five generated artifacts `OK` after regeneration. |
| `zig fmt --check .amp/modularity/tokenize.zig` | Exit 0, no formatting changes. |
| `git diff --cached --check` | Exit 0 on the staged report/evidence files before the report commit. |

No native application, install, upgrade, physical terminal, live provider, performance or crash-recovery suite was run. Those would be needed to qualify a future runtime change, not a read-only source audit. This report establishes structural evidence and bounded recommendations on the pinned tree. Its strongest remaining limit is judgment coverage: exhaustive inventory/import extraction with targeted deep ownership reading by **one model**, not exhaustive execution or independent multi-model corroboration.
