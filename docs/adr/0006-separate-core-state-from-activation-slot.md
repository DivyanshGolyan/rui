# Separate Core State from the Activation Slot

OnePage keeps a reusable bounded resident Activation Slot separate from an agent's durable identity. Core State is compact semantic data with an explicit versioned encoding; activation decodes it into a slot, while response content and stage-specific scratch remain under their narrower Host owners. The slot currently contains only decoded Core State. Suspension scrubs and releases the whole slot. This preserves allocator-free bounded activation while preventing native layout, unused reserve, or pointers into transient storage from becoming durable compatibility requirements.

Raw 64 KiB images remain useful historical measurements and may be used only as invalidatable same-build caches. They are not authoritative checkpoints.

ADR-0008 supersedes the native/Wasm conformance choice. ADR-0011 supersedes the exact 64 KiB constraint. The Core State and Activation Slot separation remains accepted.
