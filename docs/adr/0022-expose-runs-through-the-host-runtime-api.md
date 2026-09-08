---
status: accepted
---

# Expose Runs through the Host Runtime API

For implementation, read the consolidated [Run interface](../architecture/workflows.md#run-interface) and [verification](../verification/workflows.md#run-interface). The record below preserves the original decision and later amendments; superseded wording is historical.

## Accepted client/server and Session amendment — 5 September 2026

The explicitly started Host exposes local Unix-socket HTTP over its typed API. JSON encoding belongs at that external boundary; the thin CLI renders the same committed facts as JSON or Markdown. Driving is internal and automatic while work is eligible; there is no public `advance` requirement. Direct Session creation, configuration, messages, reads, waits, and stops keep Turns internal and use shared Local Owner access. Creation and messaging are separate; direct submissions have no caller key or automatic mutation retry. Workflow keys bind original Session operations/results, including shared work outcomes. Infrastructure server stop differs from client detachment and semantic cancellation. The owning [Run interface](../architecture/workflows.md#run-interface), [product contract](../../PRODUCT.md#v1-experience), and [verification](../../VERIFICATION.md#server-lifecycle-and-local-command-boundary) supersede conflicting caller-driven and CLI-only encoding language in the original decision below.

## Original decision

OnePage has no separately instantiated Run Service. The single Host Runtime exposes one narrow typed Run API that prevents callers from accessing SQLite, the Storage Owner, scheduling internals, or effect custody. Explicit domain verbs admit an agent call and its initiating User Message, admit a later User Message through the same primitive without immediately projecting it into Conversation, decide one Permission Request, interrupt one exact unresolved Model Operation, and cancel one Run; a separate bounded `drive` operation may compose several individually atomic transitions without making the caller the scheduler.

Current inspection follows [ADR-0024](0024-capture-run-inspection-before-delivery.md): capture a complete report under one read transaction on the existing connection, release database resources, then deliver charged private scratch. This replaces revision-invalidated resource-free scans. Immutable content enters through the semantic mutation that first references a sealed source and leaves through fixed-window reads; there is no public content-publication protocol. JSON and Markdown remain CLI adapters outside the native boundary. Complete logical snapshot collections are streamed without collection caps, recursive Workflow Values cross as immutable content rather than native object trees, and one Permission Decision is one mutation. V1 has no model-created conversational Input Request or generic Interaction Response. This supersedes ADR-0015 and amends ADR-0005, ADR-0010, ADR-0012, and ADR-0021.

## Accepted cancellation amendment — 5 September 2026

Run cancellation fences new work from that Run and propagates ordinary Session stops. An unfinished cancellation pass may be repeated after a crash, including successful or idle stops; callers coordinate Session reuse. The existing terminal Run outcome prevents propagation after cancellation completion. This replaces the interim no-retarget guarantee without adding per-Session propagation receipts, idle-check records, or a cancellation-specific queue. Ordinary Session execution, cleanup, and external-effect uncertainty retain their existing owners. See [Workflow Runs](../architecture/workflows.md#workflow-runs) and the [accepted trace](../design/workflow-cancellation-stop-mapping.md#accepted-simplification).
