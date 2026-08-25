# Separate Core State from the Activation Slot

OnePage keeps the exact 64 KiB constraint on a reusable resident Activation Slot, not on an agent's durable identity. Core State is compact semantic data with an explicit versioned encoding; activation decodes it into a slot alongside transient parser, response, and transition scratch, and suspension scrubs and releases the whole slot. This preserves allocator-free bounded activation while preventing native layout, Wasm offsets, unused scratch, or pointers into scratch from becoming durable compatibility requirements.

Raw 64 KiB images remain useful historical measurements and may be used only as invalidatable same-build caches. They are not authoritative checkpoints. Native and Wasm conformance compares transition outcomes and encoded Core State rather than complete slot bytes.
