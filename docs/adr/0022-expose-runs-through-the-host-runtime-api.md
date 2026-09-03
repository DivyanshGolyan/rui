---
status: accepted
---

# Expose Runs through the Host Runtime API

OnePage has no separately instantiated Run Service. The single Host Runtime exposes one narrow typed Run API that prevents callers from accessing SQLite, the Storage Owner, scheduling internals, or effect custody. Explicit domain verbs admit an agent call and its initiating User Message, admit a later User Message through the same primitive without immediately projecting it into Conversation, decide one Permission Request, interrupt one exact unresolved Model Operation, and cancel one Run; a separate bounded `drive` operation may compose several individually atomic transitions without making the caller the scheduler.

Current inspection uses a resource-free logical pull scan whose continuation contains only bounded traversal values and retains no SQLite cursor, transaction, statement, or payload collection. Immutable content enters through the semantic mutation that first references a sealed source and leaves through fixed-window reads; there is no public content-publication protocol. JSON and Markdown remain CLI adapters outside the native boundary. Complete logical snapshot collections are streamed without collection caps, recursive Workflow Values cross as immutable content rather than native object trees, and one Permission Decision is one mutation. V1 has no model-created conversational Input Request or generic Interaction Response. This supersedes ADR-0015 and amends ADR-0005, ADR-0010, ADR-0012, and ADR-0021.
