# Store conversations as append-only trees

Status: superseded by ADR-0019

OnePage stores model-visible history as immutable parent-linked Conversation Entries inside a durable Session. Model Context is a bounded projection of one root-to-leaf Branch. V1 exposes only the main Branch, implements no compaction behavior, and reserves no Conversation kind for a hypothetical compaction record. A future accepted design may add a typed replacement-context entry without rewriting or deleting source history when a current compaction consumer justifies it.

ADR-0009 replaces the physical Session WAL with a per-Session Ledger in the Host Store. Conversation content remains distinct from recovery facts, but a Session Ledger transition establishes when a Conversation Entry becomes authoritative for its Session.
