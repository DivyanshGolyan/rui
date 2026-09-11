# Session identity evidence

Primary-source reading on 2026-09-11. This note compares mechanisms; it selects no Latifa contract and contains no runtime measurements. Current behavior remains in [ARCHITECTURE.md](../ARCHITECTURE.md#naming-and-configuring-a-session).

## Integer storage IDs

SQLite `INTEGER PRIMARY KEY` is a signed 64-bit row ID and already allocates an unused integer when omitted on insertion. The `AUTOINCREMENT` keyword specifically prevents automatically allocated IDs from reusing previously committed IDs after deletion; it adds sequence bookkeeping and overhead. Rolled-back IDs may be reused, gaps remain possible, and exhausting the signed positive range causes `SQLITE_FULL` with `AUTOINCREMENT`. [SQLite: Autoincrement](https://www.sqlite.org/autoinc.html)

Inference: integers can identify native objects without also being their caller-supplied names. If an old external reference must never select a replacement object after deletion, ordinary automatic allocation alone does not establish that guarantee. An ID must not escape before its allocation commits. These guarantees are per table/database, so numeric equality across stores is not identity.

## JavaScript representation

The safe JavaScript Number integer range ends at `2^53 - 1`; SQLite's positive signed-64 range is larger. A decimal string can preserve an integer identity across JS/JSON without numeric rounding. BigInt can represent larger integers, but ordinary JSON serialization throws for a BigInt unless custom conversion intervenes. Choosing Number instead requires an explicit safe-integer limit and exhaustion behavior. [ECMAScript: Number.MAX_SAFE_INTEGER](https://tc39.es/ecma262/multipage/numbers-and-dates.html#sec-number.max_safe_integer), [ECMAScript: SerializeJSONProperty](https://tc39.es/ecma262/multipage/structured-data.html#sec-serializejsonproperty)

## Tuple selector versus storage key

A public selector and an internal integer primary key need not have the same shape. SQLite supports composite primary keys and unique indexes; choosing a composite identity does not force a `WITHOUT ROWID` table. That optimization has separate tradeoffs, including losing incremental BLOB access. [SQLite: WITHOUT ROWID](https://www.sqlite.org/withoutrowid.html)

Inference for discussion: a tagged selector such as `direct(name)` or `run(runId, name)` could map to an integer Session ID. Core could compare/store the selector without consulting workflow tables; the Run component would be an opaque namespace value. A tag keeps a direct caller name from accidentally colliding with a derived workflow name. Structured fields or an unambiguous encoded tuple avoid delimiter ambiguity. These are possible representations, not selected API syntax.

The recovery obligation is the stable mapping: replay of the same Run and local name must recover the same Session; a different Run must produce a different selector. Allocation order cannot supply the local name if reevaluation can encounter calls in another order. A core-generated integer learned only after creation would require a retained mapping and lost-reply recovery; a caller-computable selector avoids that discovery requirement under the current contract.

## Explicit reuse precedent

Temporal separates a caller Workflow ID from a system Run ID and exposes `getHandle(workflowId, runId?)`. This is a first-party example of explicit JS addressing with multiple identity components, not evidence that Latifa needs Temporal's semantics. Temporal Run IDs can change on retries and other operations; Latifa must follow its own replay identity contract. [Temporal identity](https://docs.temporal.io/workflow-execution/workflowid-runid), [Temporal TypeScript getHandle](https://typescript.temporal.io/api/classes/client.WorkflowClient#gethandle)

Inference: an explicit JS full-reference form can reuse a prior Session while the short-name form uses the current Run. Reuse must preserve the old Session selector but assign new submission identities under the new Run; otherwise it could recover an old message rather than send a new one.

## Bounds and remaining policy

A 32-byte name limit and a population of 1,000 Sessions are independent constraints. Names `reviewer-0` through `reviewer-999` fit easily, but that does not establish which author names are valid or impose a population bound. Tuple size includes its tag, Run ID, name and wire escaping; control-request budgeting must count all fields. No source here establishes 32 bytes as the right Latifa limit. The contract currently preserves exact text without a length quota, so imposing one needs an explicit decision.
