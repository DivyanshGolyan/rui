# Transactional operations without a mandatory classifier

Research date: 2026-09-08. Prior-art evidence and OnePage design inferences; no normative amendment, dependency selection, or runtime verification.

## What the sources establish

Martin Fowler's Transaction Script organizes a request's business logic in a procedure that uses the database directly or through a thin wrapper. Shared subtasks can remain ordinary helper procedures. This is established prior art for putting a meaningful operation's checks and database writes together. The short catalog entry does not prescribe OnePage's exact SQL transaction boundaries or crash policy. [Fowler: Transaction Script](https://martinfowler.com/eaaCatalog/transactionScript.html)

Ecto offers both ordinary transactional functions and `Multi`, a structure describing named database operations for later execution. Its documentation explicitly recommends ordinary control flow inside `Repo.transact(fun)` for most cases; `Multi` is particularly useful when the set of operations is dynamic. `Multi` also supports inspection before execution and identifies which operation failed. These are concrete reasons to introduce an intermediate representation, rather than making it mandatory everywhere. [Ecto.Multi: when to use it](https://ecto.hexdocs.pm/Ecto.Multi.html#module-when-to-use-ecto-multi)

Ecto distinguishes input validation from database constraints. Format and value checks usually run before database writes. Uniqueness checks performed as preliminary queries cannot guarantee uniqueness; the database constraint supplies that guarantee. This supports accepting parsed content without treating it as authority about current database state. [Ecto.Changeset: validations and constraints](https://ecto.hexdocs.pm/Ecto.Changeset.html#module-validations-and-constraints)

Django supports transaction blocks within ordinary functions and recommends keeping transactions short, particularly in long-running processes. Its post-commit callbacks run only after successful commit, but their failure cannot roll the transaction back. Database rollback also does not restore ordinary in-memory objects. These boundaries must remain explicit even with a compact function interface. [Django: database transactions](https://docs.djangoproject.com/en/5.2/topics/db/transactions/)

The transactional outbox addresses a different problem: a database update commits, then the process crashes before sending a required message. It saves the message in the same transaction and sends it later. Its relay can send duplicates, so recipients must tolerate repeated delivery. This is evidence for durable discovery of required follow-up, not permission to repeat arbitrary external actions. [Chris Richardson: transactional outbox](https://microservices.io/patterns/data/transactional-outbox.html)

## Inferences for OnePage

The proposed baseline is supported: a meaningful durable operation can receive validated content, check relevant saved facts, write its changes, and commit using ordinary control flow. Helpers may parse or store content without making every operation construct a generic decision object for another layer to interpret.

For accepting a model response, validate its format and tool arguments before opening the transaction. Inside it, enforce the response's relationship to the saved operation and attempt, and the applicable outcome constraints, then publish the accepted content atomically. This is a division by authority and transaction lifetime; it does not require another worker or thread.

The exact checks must come from OnePage's lifecycle contract. The sources do not establish a new active flag or require rechecking every fact already guaranteed by the serialized owner. Nor does opening a transaction alone establish every invariant: SQL constraints and applicable transactional checks must actually encode them.

Post-commit work must remain recoverable from saved facts rather than existing only in a returned callback or an in-memory queue. For the discussed tool flow:

- Saved permission without an admitted Attempt can remain eligible for admission, subject to cancellation and capacity.
- After an Attempt is durably admitted, a crash without a saved tool result leaves execution uncertain. Under the agreed no-replay policy, save an indeterminate result rather than automatically execute that attempt again.
- Client notification can be reconstructed from the saved permission request. Its loss must not lose the request itself.

The outbox's repeated-delivery rule must not be applied to Bash or Edit effects. OnePage may conservatively report indeterminate even if a crash occurred between attempt admission and the actual invocation; there is no durable proof that invocation did not happen.

An intermediate decision representation remains an option when a concrete requirement needs inspection, composition, or independently testing substantial pure calculations. Nothing here supports a categorical ban on pure helpers. The comparison is the complete operation, including the interpreter and database behavior it would still need, against a direct transaction function.

## Evidence to request from an implementation

Check that invalid content publishes no result; related writes commit together or roll back together; rollback does not leave authoritative-looking in-memory state; pending permission survives lost notification; and an admitted tool attempt without a result is not replayed after restart. Exercise the actual database boundary, because testing a classifier alone cannot establish those properties.
