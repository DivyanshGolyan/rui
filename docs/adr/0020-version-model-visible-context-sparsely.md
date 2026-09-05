---
status: accepted
---

# Version model-visible context sparsely

## Accepted amendment — request construction

The [Session and workflow decision](https://github.com/DivyanshGolyan/onepage/issues/101#issuecomment-5550876667) supersedes the combined patch/Turn admission and Turn-wide model-setting freeze below. Session creation establishes a complete baseline; independent configuration records sparse persistent changes. Each new model request uses committed Session state at construction and freezes its selected revision, settings, and inputs in its immutable Model Request Manifest. Existing requests and retries do not reread current settings. No per-setting activation queue or Turn-wide settings copy is needed. Validity and provider compatibility remain independent checks.

Permission Mode is persistent Session configuration selected at child Action admission, with its configuration provenance and exact request or Authorization committed together. Later changes do not answer pending requests, revoke Authorizations, or interrupt running actions; recovery reuses those admitted facts. The Turn Contract grouping is removed under the ownership amendment below. Output schema is optional persistent Session configuration, frozen at request construction. The provider adapter translates it and validates structured output against that request; absence means ordinary text. It adds no message override, output conversion, or automatic model repair. The original decision below remains historical rationale for sparse storage and exact requests, not a competing settings-selection contract.

System Instructions become applied history atomically with their first assistant-response request, after preceding tool results and applicable user input. Compare instruction content against canonical prior application; retries reuse the entry. Pre-admission compaction leaves unapplied changes for later assistant work, while post-admission overflow retains them. The [first-inclusion traces](../design/system-instruction-first-inclusion.md) specify this mapping without a queue or duplicate application record.

## Accepted ownership amendment — 5 September 2026

Remove the separate Turn Contract and `turn_contracts` relation. Persistent settings belong to Session Context Revisions; exact model inputs belong to request manifests and their immutable instruction/history references. Supplied date/time/Workspace information follows those same input bindings; tool observations remain Completion evidence and Tool Results. Session Workspace identity and admitted Action/Authorization targets keep their existing owners. This adds no ambient-refresh or Workspace-rebinding policy.

Host resource controls belong to the Host, evaluator limits to the Workflow Run/Evaluation Generation, and per-Operation retry facts to the existing request/Operation and eligibility bindings. If #91 retains a Turn-wide budget or deadline, typed fields on the Turn retain that scope across requests, retries, and compaction. Removing the grouping does not select those limits or bypass the #89 gate. No generic replacement snapshot is introduced. The [field audit](../design/turn-contract-removal.md) records the consumers and required recovery traces.

## Original decision

OnePage records persistent Session context as typed sparse revisions, resolves one immutable Turn Contract when ordinary User input starts a Turn, and binds one immutable exact Model Request Manifest to each model Operation. The only V1 mutation path after the complete baseline is an authorized closed Session Context Patch supplied to Turn admission for an idle Session; the new revision, Turn, Contract, and initiating entry commit atomically. Unchanged model, Instruction Set, Tool Catalog, context policy, and reasoning defaults continue by reference; Turn-local runtime facts such as date and Workspace observations live only in the Turn Contract. Replacement Attempts reuse the same manifest while credentials and transport remain late-bound. This preserves historical meaning without copying a monolithic system prompt or depending on ambient provider state and amends ADR-0012 and ADR-0015.
