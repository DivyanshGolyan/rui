# Action read invariants

These rows cover the Action value read changes. The contract is [Action read](../contracts/execution.md#model-output-tools-and-permission). IDs use ARD to distinguish them from Action publication.

| Id | Level | Invariant | Seam | Owner test | Source |
| --- | --- | --- | --- | --- | --- |
| ARD-1 | Module | Reading published values returns ordered pages of at most 16 items and 16 KiB of text with continuation cursors and does not consume delivery state. | Store readAction and readActionForTool | `action value pages preserve delivery state` | [Execution](../contracts/execution.md), `src/store/domain/action_read.zig` |
| ARD-2 | Host | An Action read wire request preserves its identity and independent canonical decimal cursors, defaulting omitted cursors to zero. | Wire request parser | `Action read request preserves canonical identity and optional cursor` | [Execution](../contracts/execution.md), `src/protocol.zig` |
| ARD-3 | Module | The largest escaped Action read reply fits its advertised byte budget and preserves its value page. | `renderActionRead` JSON output | `Action read JSON reaches its exact bound with an escaped final window` | `src/host_reply.zig`, `src/protocol.zig` |
| ARD-4 | Surface | The TypeScript Action read sends independent cursors without losing decimal precision and returns the value page unchanged. | `Session.readAction` | `Action reads preserve identity and byte cursor without mutation` | [Execution](../contracts/execution.md), `clients/ts/src/sessions.ts` |
| ARD-5 | Host | Rendered native Action read replies conform to the published OpenAPI schema for pending and resolved states and value pages. | Rendered wire JSON and OpenAPI schema | `action read replies conform to the published schema` | `src/openapi.zig`, `src/host_reply.zig` |
| ARD-6 | Surface | The CLI accepts a value ordinal cursor from zero through the signed Store limit and rejects malformed or out-of-range values. | Action read CLI grammar | `Action read accepts a bounded value ordinal cursor` | [Execution](../contracts/execution.md), `src/cli_args.zig` |

## Migration scope

The Action read cases formerly embedded in the general OpenAPI conformance test now have ARD-5 as their owner. The existing generated-document equality test and the remaining general OpenAPI conformance cases cover all routes; they are retained as legacy tests because migrating all route catalogs and their owners is broader than this change. The Store paging owner still includes the existing corruption-fencing check, which belongs to the wider Store failure contract and must move to its catalog when that area migrates. The remaining general numeric-options test retains its other commands; ARD-6 replaces its Action read `--after` case. No CI test selector references the names of these owners.
