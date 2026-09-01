---
status: amended by ADR-0020
---

# Separate model-tool data from execution authority

OnePage uses one provider-neutral Conversation and model-tool contract. Conversation contains User text, assistant text, Tool Calls, and Tool Results. One Model Request Manifest binds the exact model, Instruction Set, Tool Catalog, Model Context, limits, and output contract for a model Operation. Provider adapters lower that request and convert one bounded response into a Final Answer, an input request, or an optional bounded assistant-text prefix with ordered Tool Calls; failures remain typed. Final Answer has no Tool Calls. Unknown provider metadata is open; consumed fields and must-understand semantic variants are closed.

One model response may contain multiple Tool Calls. Complete output validation precedes atomic admission. Each call creates one child Action Operation with exact parent and call ordinal. The Tool Catalog grants no execution authority: V1 maps only `bash` and `apply_patch` through a closed Host binding, while permission, Authorization, Attempt admission, Resolution, and recovery remain separate. After every child settles, Tool Result entries append atomically in original call order before the next model Operation begins.

An `input_request` appends assistant prompt text and creates one immutable Interaction Request within the same Turn. A matching typed response appends User text and resumes that Turn. Model-presented choices remain ordinary prompt text; V1 adds no generic forms, runtime tool registry, plugin system, permission-through-text path, or provider-owned Conversation authority.
