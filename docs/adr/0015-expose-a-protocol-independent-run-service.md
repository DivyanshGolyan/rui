# ADR-0015: Expose a protocol-independent Run Service

Status: accepted

OnePage exposes Workflow Runs through one native Run Service rather than making its CLI, Harness, or an industry protocol authoritative. The service separates pure committed inspection, acknowledged updates, fenced advancement, explicit cancellation, and immutable content reads. `RunSnapshot` is a derived read model over canonical Run, Turn, Session, interaction, and effect rows. V1 ships only a local CLI adapter; versioned JSON is complete and Markdown is a deterministic bounded rendering. User role, Caller, Principal, Authority, and Authorization remain distinct. Process death detaches without cancelling durable work.
