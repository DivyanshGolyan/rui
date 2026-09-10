# Workflow Runtime and private evaluator

Accepted 2026-09-10. Design clarification, not implementation or performance evidence.

## Public ownership

One Workflow Runtime owns the complete Run lifecycle and consumes the ordinary Session core API. It contains a private evaluator; callers do not assemble two peer components or manage an evaluator lifecycle. Earlier references to the workflow coordinator name the runtime's coordination responsibility.

The private boundary exchanges fixed input and returned descriptions of work. It remains useful between source files, for isolated tests and across the existing child-process boundary. Retain disposable evaluation, limits, protocol validation and parent-owned termination/reaping. This decision changes public ownership, not process containment or the Session core/workflow persistence boundary.

The [prior-art comparison](../research/evaluator-coordinator-module-prior-art.md) found independent SDK consumers and deployment requirements as concrete reasons for public splits. None is currently required for OnePage's evaluator. Gary Bernhardt's supplied *Boundaries* talk reinforces the internal value boundary: computation returns descriptions of actions and the surrounding owner performs them. It does not require a public evaluator API or make persistence/recovery logic trivial.

## Invariant

Evaluation computes from fixed inputs and emits descriptions of work. It never waits for that work to happen. JavaScript alone determines branches, joins and the returned workflow value. No second dependency graph or Promise interpreter exists in the surrounding runtime.

## Interface and control direction

Workflow JavaScript consumes the runtime-provided workflow interface. The evaluator implements its local side: return original saved results and collect requested calls. The surrounding runtime implements its effectful side: retain call identities and inputs, scope caller keys, submit through the Session core API, and record replies/results.

The runtime invokes its evaluator with source, arguments and fixed available results. The evaluator returns encountered calls and an outcome: waiting with unresolved calls, returned value, or failure. This is an input/output computation, not a live Session RPC connection. The runtime then validates and handles the returned work under the existing admission/publication rules.

```text
Caller -> Workflow Runtime -> Session core
             |
             +-- private evaluator
                   input: source + arguments + fixed results
                   output: requested calls + outcome
```

Dependency direction and invocation direction differ: JavaScript consumes the workflow interface, but Workflow Runtime controls the private evaluator lifecycle. Workflow Runtime consumes the ordinary Session core API.

## Ownership

| Owner | Responsibility |
| --- | --- |
| Workflow Runtime | Complete Run lifecycle, saved call inputs and results, caller-side key scoping, evaluation eligibility and fixed inputs, core submission, cancellation and terminal publication. |
| Private evaluator within Workflow Runtime | Execute JavaScript, supply saved results through its bridge, collect requested calls, determine whether the returned root is waiting, fulfilled or rejected. |
| Session core | Session state, idempotent core request admissions, permissions, model/tool execution and original work outcomes. |

The surrounding runtime may decide when to give JavaScript another evaluation; it does not decide which branch can proceed or whether a Promise.all join has enough inputs. A result for an unresolved call can justify another evaluation even if it only waits again. The closed #114 pull policy remains selected: choose the oldest eligible Run, finish one evaluation lifecycle, service host work and immediately recheck; wait on the shared asynchronous one-second timer only when none is eligible. No completion hook or resident ready queue replaces it. Exact core observation transport remains implementation work.

## Fixed input and temporary memory

No live configuration/model result is injected into a running evaluation. A Session reference is constructed locally from the caller-provided key and requires no core operation, existence check or generated-ID discovery. Workflow callers scope short names by Run identity; core treats the full key as opaque. Run-state inspection exposes associated durable Session keys so an agent can write an exact key into a later workflow. Such a key is used unchanged and continues current Session state; no previous-Run argument, lookup helper or output-metadata requirement is introduced. The first complete configuration establishes durable Session state and returns a committed acknowledgement through the ordinary keyed result mechanism. Awaiting that result before describing a message is a real JavaScript dependency that may need a fresh evaluation. No special creation-reference resolver or dependent creation-failure mechanism remains. Exact encoding is implementation work; see the [accepted initialization decision](session-initialization-proposal.md).

Fixed input does not require all results decoded or resident at once. Native lookup may read prepared immutable input as selected by #114; JavaScript has no live database, filesystem or network API. Whether to preload more bytes is a measured memory/I/O tradeoff, not a consequence of this invariant. No startup-only allocation or performance guarantee follows.

Waiting Runs retain no evaluator heap or Promise graph. Workflow Runtime persists the facts needed to reconstruct calls and results. Under the retained closed #114 recovery amendment, a crash abandons the interrupted computation; a fresh generation uses currently available original keyed results. Already committed calls survive and changed reuse conflicts. The prior generation cannot publish after replacement. Fixed inputs apply within a live evaluation, not across an abandoned one.

## Completion and follow-through

Test the private evaluator using real fixed inputs and returned values. Test runtime persistence, submission, cancellation and recovery through their actual integration and failure boundaries. The functional-core analogy does not remove those decisions or require extracting every transactional check into a separate pure engine. Public consolidation itself claims no CPU or memory improvement.

The workflow entry's returned value/Promise determines completion. A fulfilled root does not wait for unrelated calls; encountered calls still undergo required validation/admission before terminal publication. Admitted Session work continues independently and cannot reopen a terminal Run. A pending root reports its complete encountered unresolved calls, without Promise-reachability analysis. Author keys and inputs must remain stable across replay; this boundary does not promise arbitrary completion-sensitive shared-state determinism.

Owning references: [architecture](../architecture/workflows.md#workflow-runs), [Session API](session-core-api-contract.md), [closed workflow decision](https://github.com/DivyanshGolyan/onepage/issues/114#issuecomment-5575748275), [creation/wakeup reconsideration](../research/workflow-creation-and-wake-decision-review.md), and [compute-only comparison](../research/compute-only-evaluator-prior-art.md). Exact wire types and observation transport remain implementation work under the selected behavior. This decision neither reinstates old shared core/workflow transactions nor claims production implementation.
