# OpenCode V2 as a reference for OnePage's local interface

> **Research record, published 6 September 2026.** Findings and proposals below reflect the dated investigation. Subsequent decisions are owned by [ARCHITECTURE.md](../../ARCHITECTURE.md) and [PRODUCT.md](../../PRODUCT.md); historical recommendations and implementation-ticket references do not override them.

Research on 5 September 2026. This note evaluates a proposal; it does not amend
the accepted OnePage contract or promise OpenCode client compatibility.

## Recommendation

Use selected OpenCode V2 contract conventions as a design reference. Preserve
OnePage's Run, Turn, exact-Operation interruption, durable Run cancellation,
explicit server startup, and caller-controlled mutation retry semantics. A
literal wire-compatible subset should earn its cost through a named client or
tool that would actually be reused.

## Reusable conventions

- **One authoritative typed contract.** OpenCode generates native client types
  and methods from the same contract as its API reference. OnePage can use this
  principle for compiled wire types and generated API documentation, without
  creating a second handwritten schema or requiring a new SDK for V1.
  [V2 client documentation](https://opencode.ai/v2/docs/build/client).
- **Admission acknowledgement separate from execution.** Its prompt operation
  durably admits input and then schedules execution. This is a useful reference
  for OnePage's acknowledgement of a committed command, independent of later
  workflow completion.
  [V2 API reference](https://opencode.ai/v2/docs/api).
- **Caller identity for replay.** The pinned core accepts an optional prompt ID,
  checks matching inputs when it already exists, and reports a conflict for
  changed input. OnePage already requires the corresponding semantic keys; keep
  those stronger requirements rather than copying optional-ID defaults.
  [Pinned prompt implementation](https://github.com/anomalyco/opencode/blob/e2894562f8ba943d72172d10b727c24d5f650c16/packages/core/src/session.ts#L360-L383).
- **Ordinary resource routes and declared errors.** The reference exposes
  resource-scoped HTTP operations, explicit HTTP error responses, and health
  inspection. These can guide OnePage's small interface without adopting the
  entire endpoint set or any particular implementation framework.
  [V2 API reference](https://opencode.ai/v2/docs/api).

## Where a literal subset diverges

OpenCode exposes a Session prompt command with optional delivery and resume
controls. Its Session interrupt operation targets active execution owned by
that process and is a no-op when idle. OnePage
instead needs independently named Run cancellation and exact-Operation
interruption. Identical-looking route names would not make these operations
interchangeable.
[Pinned prompt and interrupt contract](https://github.com/anomalyco/opencode/blob/e2894562f8ba943d72172d10b727c24d5f650c16/packages/protocol/src/groups/session.ts#L345-L356).

The public API reference and pinned source differ: the reference exposes an
interrupt continuation option, while the inspected protocol declaration does
not; the pinned prompt response is `SessionInput.Admitted`. Use the pinned
protocol when defining any actual compatibility target.
[Pinned prompt response](https://github.com/anomalyco/opencode/blob/e2894562f8ba943d72172d10b727c24d5f650c16/packages/protocol/src/groups/session.ts#L205-L223).

Its schema-defined errors and generated OpenAPI are concrete references for
OnePage's wire-contract work.
[Error definitions](https://github.com/anomalyco/opencode/blob/e2894562f8ba943d72172d10b727c24d5f650c16/packages/protocol/src/errors.ts#L3-L78),
[OpenAPI publication](https://github.com/anomalyco/opencode/blob/e2894562f8ba943d72172d10b727c24d5f650c16/packages/server/src/routes.ts#L56-L64).

Exact prompt replay can wake execution again because `resume` is outside stored
input equivalence. OnePage must preserve its existing durable command effects
when replaying a key. OpenCode's finite history pages and replayable SSE also
do not replace OnePage's accepted complete streamed inspection contract.
[Input equivalence](https://github.com/anomalyco/opencode/blob/e2894562f8ba943d72172d10b727c24d5f650c16/packages/core/src/session/input.ts#L191-L202),
[History and event routes](https://github.com/anomalyco/opencode/blob/e2894562f8ba943d72172d10b727c24d5f650c16/packages/protocol/src/groups/session.ts#L307-L340).

OpenCode's client also offers live event subscriptions and a separate service
helper whose `ensure` method can start a server. OnePage's accepted local V1
uses polling and explicit startup. Those facilities are optional reference
features, not prerequisites to adopting HTTP conventions.
[V2 client documentation](https://opencode.ai/v2/docs/build/client).

The client documentation explicitly marks V2 as beta. Pin concrete upstream
examples when freezing OnePage's wire design rather than automatically tracking
upstream API changes. Borrowing familiar conventions alone does not establish
that an existing OpenCode client will work against OnePage.
[V2 client documentation](https://opencode.ai/v2/docs/build/client).

## Scope and next implementation step

The recommendation is to use OpenCode as the first reference while completing
the existing Run interface implementation ticket. For each OnePage operation,
record the nearest OpenCode example, adopted conventions, and semantic
differences; generate the wire documentation from OnePage's compiled types.
Do not add adapters, model translations, event replay, or optional scheduling
controls merely to resemble upstream.

No interoperability experiment was run. The prior OnePage HTTP memory probe
does not measure an OpenCode-compatible interface. The adopted OnePage contract
remains recorded in
[Choose live Host ownership and cross-process command semantics](https://github.com/DivyanshGolyan/onepage/issues/100#issuecomment-5549173568).
