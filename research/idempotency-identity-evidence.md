# Compact core idempotency identity

Research on 2026-09-11. This compares proposals; it changes no accepted contract and provides no implementation qualification.

## Primary-source findings

- AWS recommends explicit caller-provided tokens rather than inferring intent from identical request payloads: callers may intentionally request identical work twice. It requires recording the token atomically with service mutations. This supports Latifa's existing operation/input conflict checks. It does not prohibit hashing an explicit logical identity, which is different from hashing a prompt to infer intent. [AWS Builders' Library](https://aws.amazon.com/builders-library/making-retries-safe-with-idempotent-APIs/)
- Stripe recommends UUIDv4 or another sufficiently random client token, reusing it on retries and comparing parameters. Its 255-character limit is service policy, not a bound Latifa should copy. Stripe does not retain pre-execution validation failures, so that aspect differs from Latifa's stronger committed-rejection contract. [Stripe](https://docs.stripe.com/api/idempotent_requests)
- AWS's transactional outbox saves an event in the same transaction as local state before sending it. Its example uses the saved event ID as the downstream deduplication ID. This supports assigning a transport token to an already-required durable intent rather than encoding all business names in it. [AWS transactional outbox](https://docs.aws.amazon.com/prescriptive-guidance/latest/cloud-design-patterns/transactional-outbox.html)

## Local premise

[ARCHITECTURE.md](../ARCHITECTURE.md#validating-and-publishing-encountered-calls) already requires durable submission intents, separate Workflow/core transactions, exact input retention, and replay lookup by Workflow ID, Session reference and submission name. Its ownership table says the Runtime resubmits a committed intent when the core reply is missing. Therefore, saving a token with that intent need not add a registry or a network lookup. At the time of this comparison, the contract required derivation from the tuple. The subsequently accepted saved-token amendment lives in ARCHITECTURE.md.

## Comparison

| Proposal | Extra work and limits | Assessment |
| --- | --- | --- |
| UUID generated once and saved with intent | One fixed token field; entropy failure and collision policy; must commit before send | Conventional, decouples core key length from names. Reuse saved token after restart. |
| Saved intent's integer ID as a namespaced string | Needs actual nonreused intent ID, unambiguous namespace across core clients | Potentially smaller if the intent already has this ID. Do not assume current schema supplies it. This is not an evaluation encounter counter. |
| Hash explicit identity tuple | Stable encoding/domain separation, algorithm/version and collision policy | Compact and no saved-token dependency, but retains encoding design underneath the digest. More useful if reconstruction without durable intent is required. Never include changed payload as a way to escape conflict checks. |
| Separate opaque scope + submission fields in core | Core composite index and changed observation API; no Workflow terminology needed | Valid but moves naming structure into core and broadens this boundary. Not required to achieve compact retries. |
| Length-prefixed concatenated tuple | Custom framing, larger maximum, names duplicated in transport identity | Exact and reversible, but core does not consume decoded components. No demonstrated need for that reversibility. |

## Recommended smallest candidate

Keep the author's identity tuple in the existing durable Workflow submission record. Assign one opaque token when that record is first committed. Send the Session reference, token and inputs through the ordinary core API. Repeat the same token for every later delivery.

For example, `(43, "workflow/42/reviewer", "review-patch")` locates one saved intent whose token is `8fef6923-a50d-4d96-a57c-3f20cdbf751a`. Core sees that token and the Session reference, not Workflow 43 or the submission name. A different Workflow gets a different saved intent/token even when it reuses the Session and name.

Before commit, no core send is permitted. After commit/before send, recovery sends the saved token. After a lost core reply, recovery sends the same token. A rejected first configuration also has a saved token before a Session exists. On reevaluation, lookup and complete input comparison recover the saved intent rather than generating another token. Changed inputs must conflict in Runtime even if core was never called again.

This recommendation is an application of the sources to Latifa, not a claim that those sources mandate UUIDs. Prefer an existing stable intent ID if source inspection proves it already meets the namespace/nonreuse requirements; otherwise a UUID is a familiar candidate. Do not generate random tokens on every evaluation or retry. Do not add a second mapping table solely to remember a token that fits the existing intent record.
