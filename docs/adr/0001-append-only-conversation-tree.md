# Store conversations as append-only trees

Status: amended by ADR-0007

OnePage stores model-visible history as immutable parent-linked Conversation Entries inside a durable Session. Model Context is a bounded projection of one root-to-leaf Branch, and future compaction appends a validated Context Checkpoint that names its source range, replacement projection, retained tail, policy version, and predecessor without rewriting or deleting source history. V1 exposes only the main Branch and does not implement compaction, but adopting the tree shape now avoids a storage migration and preserves deterministic context reconstruction without a resident transcript.

ADR-0007 replaces the separate effect-only operation journal with one Session WAL. Conversation content remains distinct from recovery facts, but a WAL record establishes when a Conversation Entry becomes authoritative for its Session.
