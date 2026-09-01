---
status: accepted
---

# Version model-visible context sparsely

OnePage records persistent Session context as typed sparse revisions, resolves one immutable Turn Contract when ordinary User input starts a Turn, and binds one immutable provider-neutral Model Request Manifest to each model Operation. The only V1 mutation path after the complete baseline is an authorized closed Session Context Patch supplied to Turn admission for an idle Session; the new revision, Turn, Contract, and initiating entry commit atomically. Unchanged model, Instruction Set, Tool Catalog, context policy, and reasoning defaults continue by reference; Turn-local runtime facts such as date and Workspace observations live only in the Turn Contract. Replacement Attempts reuse the same manifest while credentials and transport remain late-bound. This preserves historical meaning without copying a monolithic system prompt or depending on ambient provider state and amends ADR-0012 and ADR-0015.
