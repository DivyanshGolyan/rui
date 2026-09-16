# Durable command identity: collision handling

Research date: 2026-09-12. Primary-source reading and local contract reasoning at ab686a6; no runtime measurements, qualification or accepted contract changes. [ARCHITECTURE.md](../ARCHITECTURE.md#recovering-a-submission-after-a-lost-reply) remains authoritative.

## Recommendation

Keep a single durable identity for each logical command. Persist identity and immutable inputs before sending. Recover uncertain submissions by resending that pair. Matching identity and inputs recover the original admission; mismatched inputs are a definitive contract error. Do not automatically replace a key to hide that error, and do not endlessly retry it.

For Runtime-generated UUIDv4 commands, this is the smallest coherent design provided secure unique generation is an explicit assumption, as it already is for other opaque identities. A generic nonretryable command-delivery conflict is enough to classify the outcome; this research does not select a new terminal cancellation lifecycle. A cancellation-specific recovery subsystem is not justified solely by random collisions. This is design judgment, supported by the source patterns below rather than prescribed verbatim by any source.

If the requirement is stronger—independent producers must be unable to claim each other's command identity—use a producer-scoped identity whose namespace is enforced by Core. A prefix only works when other callers cannot claim that prefix. Do not add producer registration, durable sequence state, and restore rules merely to eliminate the negligible random-collision risk of correctly generated UUIDs.

## Evidence

### AWS: a caller token names intent, not a request's shape

AWS favors a caller-provided request identifier over deriving identity from request parameters: two identical inputs may intentionally request two creations. Its deduplication domain combines caller identity with the token. Recording the token and mutations must be atomic. Repeated requests receive semantically equivalent outcomes, which need not be byte-for-byte identical when resource progress changes. Reusing the token with different inputs produces a parameter-mismatch validation error. AWS's simple retry contract explicitly excludes validation errors. [AWS Builders' Library: Making retries safe with idempotent APIs](https://aws.amazon.com/builders-library/making-retries-safe-with-idempotent-APIs/)

This supports separating stable admission/target from progressing cancellation completion. It also shows that a universal rule for state-changing commands does not imply that all producers must share one unscoped string namespace.

### Stripe: UUIDv4 plus input comparison, with a retention boundary

Stripe recommends UUIDv4 or enough random entropy to avoid collisions. A key recovers the first executed request's status and body, including failures; changed parameters produce an error. Validation failures before execution and concurrent execution conflicts do not save a result. Keys may be pruned after 24 hours, and reuse after pruning creates a new request. That expiration rule is unsuitable for unlimited durable workflow recovery without an additional contract. [Stripe idempotent requests](https://docs.stripe.com/api/idempotent_requests)

Stripe distinguishes network uncertainty from definitive errors: retries after a network error keep both key and inputs; modifying an invalid request uses a fresh key. Stripe advises against a fresh key after a server error because effects may already have occurred. Its general 4xx advice is specific to its API ordering and must not be transplanted as proof that every failure is safe to rename. [Stripe advanced error handling](https://docs.stripe.com/error-low-level)

### TigerBeetle: persist before submission and recover matching duplicates

TigerBeetle recommends that the initiating client generate and persist the transfer ID before submission and reuse it after both network failures and client restart. A newly created transfer and an already-existing transfer allow a client to reconcile the same operation. [TigerBeetle reliable transaction submission](https://docs.tigerbeetle.com/coding/reliable-transaction-submission/)

Its API distinguishes matching existing transfers from existing IDs with different fields. It also remembers certain state-dependent failed attempts, preventing a retry from succeeding merely because database state changed. Intentionally attempting that failed operation again requires a new ID. That is a new attempt after a known outcome, not recovery of an uncertain request. [TigerBeetle create_transfers](https://docs.tigerbeetle.com/reference/requests/create_transfers/)

TigerBeetle's recommended IDs contain a timestamp and random component. Their documented collision risk is insignificant, not mathematically impossible; they avoid a central ID oracle and optimize storage access. This is useful evidence that a durable financial system can explicitly rely on probabilistic identity uniqueness rather than engineer recovery for every theoretical collision. It does not justify replacing UUIDv4 for Rui absent a demonstrated storage need. [TigerBeetle data modeling](https://docs.tigerbeetle.com/coding/data-modeling/)

## Cases that must remain distinct

| Observation | Meaning | Coherent action |
| --- | --- | --- |
| No definitive response | Admission may have happened | Replay identical key and inputs |
| Matching duplicate | Same command already exists | Recover its admission/target; observe completion |
| Key exists with different inputs | This submitted command cannot be admitted under this identity | Return a nonretryable conflict; preserve evidence |
| Rejected before admission, authoritatively known | No effect from this submission | Caller may intentionally construct a new command; automatic renaming needs an explicit contract |
| Same key and identical inputs chosen for a different intended command | Indistinguishable from a retry | Key uniqueness is an assumption or must be enforced structurally |

The last case is decisive. A collision between two `stop(session)` calls can have identical parameters. Input comparison then cannot identify the collision: it returns the earlier stop. A regenerate-on-mismatch loop cannot provide collision correctness because it cannot handle this matching collision.

## Why automatic key replacement is not the default

After a definitive mismatched-input rejection, a replacement key can be safe from duplicate execution of the rejected payload, if the Core guarantees rejection occurred before any effect, the conflicting binding is permanent for the recovery period, and the replacement is durably saved before sending. It is therefore not inherently impossible or always unsafe.

But it introduces a durable compare-and-swap replacement transition and crash recovery for that transition, masks accidental changed-input retries or key bookkeeping bugs, and does not solve matching collisions. For commands that select work at admission, the fresh request also selects work at a later time. Calling this the same retry hides a relevant semantic distinction. Prefer making a fresh command an intentional decision rather than a generic error handler.


## UUID standard boundary

RFC 9562 specifies 122 random bits for UUIDv4, recommends secure random generation, and requires applications to weigh collision consequences. It distinguishes practical decentralized uniqueness from schemes using shared knowledge. Thus negligible collision probability is a deliberate assumption, not proof of absolute uniqueness. [RFC 9562 sections 5.4 and 6.7–6.9](https://www.rfc-editor.org/rfc/rfc9562.html#section-6.7)
