# Provider output, validation and Session settlement

Reviewed 2026-09-10 using Gary Bernhardt's supplied *Boundaries* talk. Read-only design review and proposed interface clarification; no production or normative changes. This examines the accepted design, not the historical implementation's completeness.

## Conclusion

Keep three responsibilities with two private handoffs:

```text
Provider execution
  -> sealed response source + terminal execution facts
Complete validation
  -> prepared response description or classified failure
Session settlement
  -> committed Operation result/retry facts and consequences
```

The useful computation is interpreting fixed response bytes under frozen request facts. Keep it independently testable inside the provider/validation implementation. It cannot decide current Session applicability, permission mode, retry allowance or Turn completion. Settlement remains one cohesive transactional operation; no pure database classifier or generic mutation interpreter is proposed.

## Contract precedence

The [live V1 map](https://github.com/DivyanshGolyan/onepage/issues/2) points to the accepted [Operation-owned execution decision](https://github.com/DivyanshGolyan/onepage/issues/106#issuecomment-5556976932), published through PR #127 and ADR-0026. It supersedes the historical durable Attempt/Completion chain: Execution Evidence is a transient terminal delivery; required current retry facts or final Resolution/content belong to the Operation. A Resolution has no separate identity. Full rejected provider payloads are not permanently required; retain bounded rejection/provenance and use the separate diagnostic contract for additional detail.

Combine that published decision with the subsequent [direct transactional operations](transactional-operations.md), [shared Session request identity](shared-request-identity.md), [tool recovery](unified-tool-recovery.md) and [Workflow Runtime](evaluator-coordinator-boundary.md) decisions. The owning contracts incorporate those accepted amendments. Historical mandatory-classifier and tool-reconciliation wording does not supersede them. The private handoff recommendations in this review remain proposed implementation guidance.

Exact Codex terminal grammar, continuation fields, output-to-input transformation and compaction remain evidence work under [provider contract #73](https://github.com/DivyanshGolyan/onepage/issues/73). The interfaces below do not invent those wire facts.

## Concrete trace: assistant text and two tool calls

1. The core has already admitted a model Attempt against a frozen request manifest. That manifest binds output schema, tool catalog and continuation inputs. Transport receives only its execution capabilities; it cannot query or change the Session.
2. Provider execution captures bytes into charged unlinked scratch. When it reaches its effect-specific terminal boundary, its owner seals the source and delivers terminal facts for the exact Operation/Attempt. An ended connection alone is not proof of a valid complete provider response.
3. The shared serial workspace interprets the sealed response using the producing request's frozen facts. It validates provider structure, terminal meaning, identities, ordered output and required continuation. Host/tool-owned validators check supported tool bindings and complete argument shapes. A malformed second call rejects the whole semantic candidate, even if the first is valid.
4. Successful preparation describes assistant content and two ordered proposed calls, with exact references to required provider content. It contains no permission decisions, child Operation IDs, final-answer declaration or new Session state.
5. One settlement transaction checks the current admitted Attempt, unresolved Operation, applicable stop/interruption and relevant Session facts. It imports required content, sets the Operation's immutable Resolution and creates the permitted Conversation/child/permission facts atomically. Tool permissions use the mode selected at Action admission, not an old mode inferred from model-request settings.
6. Only committed work becomes eligible for execution. Permission and capacity still govern child dispatch. Temporary preparation is released after commit or safe failure handling. A lost return value does not erase committed facts; crash recovery reads the Operation rather than replaying a saved parser object.

For assistant-only output, the parser reports assistant content. Settlement decides whether it is a Final Answer: a newly admitted applicable message can require another model request. Provider-level completion and Turn completion are distinct.

## Proposed private handoffs

Names describe roles, not selected Zig types or a public wire schema.

| Handoff | Required information | Ownership and restrictions |
| --- | --- | --- |
| Sealed execution input | Exact Operation/Attempt binding, physical terminal facts, immutable response source when available, producing manifest facts needed for interpretation | Execution owns delivery/cleanup. Validation receives fixed reads, not live Session, credential, network or SQLite capabilities. Some failures have no complete response source. |
| Prepared response | Ordered item/content ranges and classifications, required continuation/provenance, validated tool proposals, or bounded failure classification | One temporary preparation owns its source and scratch-backed metadata through import. It is neither a committed result nor authority to execute. No borrowed view may outlive its owner or shared workspace reuse. |
| Settlement result | Established committed disposition or explicit storage failure/uncertainty | Core owns transaction and policy. Return only what was established; failed/uncertain commit requires checking actual transaction/recovery state. No external effect is authorized merely by a prepared response. |

Use fixed resident state and one sequential metadata file when response cardinality grows. A value interface does not require a response-sized object, per-item files or an in-memory tool list. Prepared sources remain immutable through import; ranges alone cannot safely outlive or identify a replaced source. Keep preparation and import sequential in the existing shared workspace, without a queue of prepared candidates or per-Attempt parsers.

There are two different kinds of validation:

- **Fixed-content checks:** provider grammar and completion, output-schema interpretation under the frozen manifest, preserved fields, tool names/arguments and complete candidate consistency. These can run without current Session state.
- **Current-state checks:** exact active Attempt, absence of final Resolution, stop authority, applicable pending messages, Action permission mode, retry allowance and eligibility. These belong to settlement/admission transactions.

Provider-specific error interpretation supplies facts such as a supported temporary failure or confirmed context overflow. Core policy decides whether to retry, compact or resolve under the conserved allowance. Local scratch/import/storage failure must not be disguised as malformed provider output or automatically trigger another paid request. Existing effect-recovery rules govern process loss before required facts commit.

## What the talk exposes

**Prepared output needs an explicit lifetime.** A convenient return struct holding slices into a reusable parser buffer would violate the proposed interface. The source/metadata owner must survive until import completes, fails or is abandoned. A private owned preparation or a scoped callback can express this; choose the smaller representation during implementation.

**Protocol interpretation must not acquire Session policy.** A provider's terminal marker cannot produce a host Final Answer directly. A tool-call decoder cannot approve a tool. A provider error cannot spend the next retry allowance. These are concrete constraints on the interface, not reasons to add public modules.

**The surrounding code has real decisions.** Current-state validation and atomic publication deserve real SQLite integration tests. The talk's simple largely untested shell is not a sufficient testing model for this runtime.

**Bounded memory does not establish responsiveness.** Validation and import are serial. Fixed read windows do not prove a long response or SQLite transaction yields promptly to controls. Existing large-payload/control-latency gates must measure both phases. Do not add a worker, resumable parser or split publication transaction without evidence and a separate decision.

## Falsifying examples for implementation

| Example | Required observation |
| --- | --- |
| Valid first call, malformed final call | No child, permission or partial Conversation publication |
| Same sealed response after Session configuration changes | Fixed schema/interpretation unchanged; current Action permission rules applied only at admission |
| New message before assistant-only settlement | Text accepted as ordinary assistant output; no premature Turn completion |
| Session stop before result acceptance | No new output, private continuation or tool consequence from the stopped model work |
| Response accepted before stop | Accepted meaning remains immutable; stop governs remaining applicable work |
| Unknown consequential provider item | Bounded typed rejection/provenance; no accepted continuation or effects; no requirement for permanent full raw capture |
| Source read or scratch growth failure during preparation | No successful prepared response and no partial semantic publication; infrastructure failure remains distinguishable |
| Import fails after writing initial content | Transaction publishes no partial result or child set; commit uncertainty is handled honestly |
| Crash after seal/preparation but before settlement | Temporary evidence disappears; current admitted uncertainty follows the existing model recovery policy |
| Crash after settlement before reply | Original Operation result/content recovered without another provider call |
| Duplicate/stale terminal notification after custody reuse | Local delivery/identity checks prevent touching newer execution; no historical Completion replay subsystem |
| Large response with many items | Bounded resident state, charged metadata and measured control latency across validation and import |

Run interpretation cases through the real decoder with fixed sources and independent expected outcomes; no fake Session core is needed. Run settlement cases through real transactions and failure injection. Small byte-array fixtures and file-backed fragmented/large fixtures test different obligations. Protocol fixtures do not certify storage behavior, and storage fixtures do not establish provider wire compatibility.

## Historical implementation evidence

The existing source at `d76c7350a3661da48e9d107258e3dd699f9b0aa7` has useful capability separation but is not the accepted redesign. `model_operation.Provider` takes a request cursor and append-only candidate writer; `ProviderIo` retains Session/content ownership ([source](../../src/model_operation.zig)). `CodexProvider.dispatch` couples transport to a live `Capture` parser, and the older shared model protocol includes `final_answer` and removed `input_request` dispositions ([provider](../../src/codex_provider.zig), [protocol](../../src/model_protocol.zig)). These show why a narrow-looking signature alone does not prove the current post-seal, multi-call and host-settlement contract.

No code or production tests changed or ran. The review recommends making the two handoffs explicit within existing modules, preserving one atomic settlement and the existing serial resource owner. It identifies implementation obligations rather than selecting new services, processes, queues, persistence stages or provider wire behavior.
