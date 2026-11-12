# Idempotency source evidence

Primary-source reading on 2026-09-11; no runtime measurements or qualification. [ARCHITECTURE.md](../ARCHITECTURE.md#recovering-a-submission-after-a-lost-reply) owns Rui retry behavior.

- AWS distinguishes explicit caller-provided retry tokens from deduplication inferred from identical request payloads: identical requests can represent separate intended work. Its service records the token atomically with the relevant mutation. [AWS Builders’ Library](https://aws.amazon.com/builders-library/making-retries-safe-with-idempotent-APIs/)
- Stripe recommends UUIDv4 or another sufficiently random client token and compares retry parameters. It allows keys up to 255 characters, permits pruning after at least 24 hours, and does not save results for pre-execution validation failures. These are Stripe service policies. [Stripe idempotent requests](https://docs.stripe.com/api/idempotent_requests)
- AWS’s transactional outbox example saves an event with local state in one transaction and uses its event ID for downstream deduplication. [AWS transactional outbox](https://docs.aws.amazon.com/prescriptive-guidance/latest/cloud-design-patterns/transactional-outbox.html)
