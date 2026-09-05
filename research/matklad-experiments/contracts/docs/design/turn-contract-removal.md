# Remove the Turn Contract grouping

Status: ownership audit and authorized design simplification, 5 September 2026. The user authorized removal if existing records cover the remaining uses. This note maps those uses and removes the grouping from the proposed architecture. It does not implement the relational runtime, choose numeric limits, or claim executed recovery tests.

## Finding

No remaining consumer requires a separate Turn Contract or `turn_contracts` relation. The earlier object bundled settings whose actual consumption boundaries differ. Keep each fact with the Session, Conversation input, model request, Action, Turn, Workflow Run, or Host resource that already owns it. Do not replace the removed object with a generic runtime-facts or policy bag.

| Former responsibility | Existing owner and consumption boundary |
| --- | --- |
| Persistent model, effort, instructions, tools, output schema | Session Context Revisions hold desired settings. A new model Operation's manifest freezes the selected settings and exact input references. |
| Date, time, timezone, or Workspace information supplied as instructions | The fixed initial instruction binding or appended System Instruction owns the exact selected content and any required rendering inputs. The request manifest references that historical input. Retries do not reread the clock or rerender old instructions from the filesystem. |
| Workspace identity and execution target | The Session owns its Workspace binding. Each admitted Action's exact descriptor and Authorization retain the execution target and provenance they need. Removal does not permit Session Workspace rebinding. |
| Workspace observations obtained by a tool | Existing Completion evidence and projected Tool Results retain the observation. Do not take another snapshot merely because a Turn starts. |
| Permission Mode and approval provenance | Session configuration owns the current mode; Action admission binds its configuration provenance and exact Permission Request or Authorization. |
| Provider request/output controls | The model request manifest freezes supported request controls and output schema. The producing request governs adapter validation. |
| Retry policy and eligibility for an existing model Operation | Existing request/Operation bindings and immutable retry eligibility retain the selected policy facts required by the retry contract. A replacement Attempt does not select new model inputs or reset consumed allowance. Exact values remain with issue #91. |
| A Turn-wide dispatch allowance or absolute deadline, if retained | Typed fields on the Turn own that scope. Consumption derives from the Turn's admitted Attempts across all its model Operations, including compaction. A new Operation must not reset a Turn-wide budget. Whether these limits survive and their values remain with issue #91. |
| Host memory, simultaneous execution, I/O workspace and scratch limits | Host admission/resource ownership and Active Capacity govern current resource use. They are not a frozen per-Turn copy of Host configuration. Issues #68 and #95 own these decisions. |
| Workflow evaluator limits | Existing Workflow Run bindings and Evaluation Generations own evaluator execution limits. They are independent of a Session Turn. |

The mapping establishes where supplied facts belong; it does not add new configuration fields, automatic date refresh, clock-driven instruction updates, Workspace polling, or provider wire features. Those need actual consumers. Model-visible changes still follow the accepted append-only instruction and provider-compatibility contracts.

## Concrete recovery traces

1. **The date changes after request admission.** Request A references its recorded instruction content/rendering inputs. After a crash, A's replacement Attempt reconstructs the same inputs. A later deliberately supplied date change can enter a new System Instruction under the existing first-inclusion rule. No Turn-wide date snapshot or automatic refresh mechanism is necessary.
2. **Another process changes the checkout.** Prior tool evidence and instructions remain historical facts; the Session's Workspace binding and admitted Action descriptors do not silently change. New tools observe current external state. Patch still uses its preimage and reconciliation contract; this creates no filesystem-isolation promise.
3. **Configuration changes while work is active.** New model requests select current Session configuration; existing requests retain their manifests. New Action admissions select current Permission Mode; existing permissions retain their provenance. No competing Turn settings snapshot needs synchronizing.
4. **A request overflows, compacts, then continues.** Each model Operation has its own exact manifest. If #91 retains a Turn-wide dispatch budget or deadline, the compaction and replacement conversation request consume that same Turn allowance; restart cannot reset it. The source manifest and selected Completion establish Compaction Base provenance without a Turn Contract.
5. **Host capacity changes on restart.** Current Host admission checks whether physical work can start under available resources. Existing admitted request/Action meaning remains unchanged; no prior Turn snapshot authorizes an oversized allocation. Existing overload and effect-recovery contracts govern progress.
6. **Preparation fails before a model Operation exists.** The existing failed Turn Outcome retains the selected configuration and input-frontier provenance required by the failure contract. Do not create a manifest or Turn Contract merely to explain a request that was never admitted.

## What is removed and what remains open

Remove `turn_contracts` from the proposed relation inventory, the active glossary entry, the instruction to resolve a contract at Turn admission, and compaction's dependency on it. Preserve the earlier ADR text as historical rationale beneath an explicit amendment. Production source still implements the older terminal-Session/ledger path: an exact-name search found no `Turn Contract`, `turn_contract`, or `turnContract` object in `src`; inspected `session_transition.zig` and `model_operation.zig` are evidence of that older implementation, not proof of the proposed relational mapping.

The budget decisions in #91 and the pre-implementation limit-matrix gate in #89 remain open. Removing a wrapper does not select those limits, remove a retained aggregate allowance, reset it per request, or resume the paused #52 implementation. Exact relational columns, supported configuration options, and ordinary Session stop/Run settlement integration also remain implementation or separately assigned design work.

## Sources and required evidence

- [Current Session decisions](https://github.com/DivyanshGolyan/onepage/issues/101#issuecomment-5550876667).
- [Session configuration and exact requests, #59](https://github.com/DivyanshGolyan/onepage/issues/59).
- [Retry and external-effect budget decision, #91](https://github.com/DivyanshGolyan/onepage/issues/91).
- [Host resource budget decision, #68](https://github.com/DivyanshGolyan/onepage/issues/68), [SQLite work limits, #95](https://github.com/DivyanshGolyan/onepage/issues/95), [limit-matrix gate, #89](https://github.com/DivyanshGolyan/onepage/issues/89).
- [System Instruction first inclusion](system-instruction-first-inclusion.md), [architecture](../../ARCHITECTURE.md), [verification](../../VERIFICATION.md).

Production fixtures must exercise the traces above with real admission/reopen boundaries. Documentation references, consistency, and whitespace checks validate this design edit only; no Zig/provider/SQLite crash tests were executed for it.
