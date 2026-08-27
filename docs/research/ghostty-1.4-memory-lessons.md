# Ghostty 1.4 memory work and OnePage

Research date: 2026-08-26

## Scope and status

This records the changes behind Mitchell Hashimoto's description of the upcoming Ghostty 1.4 memory results. At this date, Ghostty's published release index ends at 1.3.1, so this is merge/nightly evidence rather than final 1.4 release notes. The two headline changes are already merged to Ghostty `main`.

## What changed in Ghostty

### 1. Cold scrollback is compressed and physically discarded

[PR #13264](https://github.com/ghostty-org/ghostty/pull/13264), merged 2026-07-09, changes historical terminal pages from an always-resident representation to resident-or-compressed state. It compresses only complete history pages that are outside the visible viewport; restoration is lazy. The work is incremental and runs after an idle delay, rather than adding a large pause to terminal I/O. The PR reports 70--90% physical-memory savings for normal text history (content dependent), while its intentionally repetitive benchmark retained only 6.11% of the original backing.

The key detail is that Ghostty separates address space from physical memory. On supported macOS and 64-bit Linux targets it keeps the mapping needed for infallible restoration, but uses platform discard primitives to release the physical pages. Thus virtual size is not the success metric. The later configuration commit makes compression default-on, lifts the logical default scrollback limit from 10 MB to 50 MB, and documents that the physical saving depends on content and that virtual address space remains retained ([implementation commit](https://github.com/ghostty-org/ghostty/commit/0fb89f4ffebabd7ea868f75a93f14a41ff65764a)).

### 2. A fully hidden surface drops its GPU working set

[PR #14017](https://github.com/ghostty-org/ghostty/pull/14017), merged 2026-08-25, changes the renderer's swap chain from always present to optional. When a macOS surface becomes invisible, Ghostty waits for in-flight frames, destroys its swap-chain resources, clears API-held references, and leaves the terminal's semantic state intact. On the next draw, at a point where the graphics context is valid, it rebuilds the swap chain and forces a fresh frame.

This is large because each visible surface is triple buffered. The released resources include screen targets, uniform/cell/custom-shader buffers, and font texture copies. Mitchell's measurement with one visible and twenty hidden tabs fell from 384.6 MiB to 18.3 MiB in tracked GPU allocations; a swap-chain rebuild averaged 0.43 ms (maximum 0.55 ms). The implementation makes hidden and unrealized distinct states, so a hidden surface may rebuild on draw but an unrealized display may not.

### 3. The result is an accumulation of lifecycle fixes

These are not allocator tricks in isolation. The scrollback work first made ownership explicit, hid resident/compressed page variants behind a content-access boundary, and added generation checks before incremental reclamation. The renderer change similarly made "has a valid graphics context" and "has a resident swap chain" explicit state. That lets Ghostty reclaim aggressively without making a stale object or callback usable. The post's comparison intentionally excludes scrollback, so its reported visible/hidden-window improvement is separate from the potentially larger history saving.

Primary sources: [Ghostty release index](https://ghostty.org/docs/install/release-notes), [PR #13264](https://github.com/ghostty-org/ghostty/pull/13264), [offscreen-history follow-up](https://github.com/ghostty-org/ghostty/commit/95685afd26813b5ad93c912199f39e6295a919a3), [idle-scheduling follow-up](https://github.com/ghostty-org/ghostty/commit/461562ca4ffe344dd1a6f7f24ab1f32fbb0fd448), and [PR #14017](https://github.com/ghostty-org/ghostty/pull/14017).

## OnePage mapping

OnePage already has the most important prerequisite: it distinguishes durable Core State and immutable blobs from an actual-size resident Activation Slot with a 32 KiB V1 ceiling. Its normative lifecycle says that `drive` borrows a slot for one owner quantum, commits and encodes state, scrubs the slot, and releases it before returning ([ARCHITECTURE.md](../../ARCHITECTURE.md)). That is the OnePage equivalent of preserving Ghostty's terminal state while releasing the renderer's cache.

There is no direct GPU win today. OnePage is a terminal-first application; terminal frames and diagnostics are explicitly non-authoritative projections. It should not add a renderer abstraction merely to copy Ghostty. If a desktop/web client later keeps per-session frame buffers, textures, syntax-highlight caches, or transcript layouts, those must be disposable after full occlusion and rebuilt from committed Projections or blobs.

The stronger architectural lesson is to model every substantial allocation as one of three things:

| Class | OnePage authority | Lifetime and release rule |
| --- | --- | --- |
| Durable truth | Session Ledger and immutable blobs | Retained by explicit storage policy; never silently evicted. |
| Reconstructable warm state | decoded Core State, indexes, cached Projections, future UI layout | May be dropped after its durable source is committed; rebuild is normal. |
| In-flight ownership | Activation Slot, bounded request/response buffers, adapter record | Has one owner and generation; release only after commit/settlement makes it safe. |

This is stricter than calling every waiting Session "idle." A Session with an admitted model or tool Attempt is waiting but may still require bounded Completion-Inbox and recovery state. Its Core Slot, however, must not remain resident merely because the logical Session is waiting. Current lifecycle code deliberately closes the Core before model dispatch, which is the right shape.

## Recommendations

1. **Make waiting durable Host-Runtime state, not a retained Harness mode.** Keep `Harness.open / offer / drive` as the only Session seam, but close and destroy the Harness after a Session commits a waiting state. Reopening must follow the same bounded recovery path as crash recovery. This avoids a large number of open-but-waiting Harness objects becoming an accidental resident agent population and gives workflow Jobs the same zero-residency wait rule.

2. **Add a physical-footprint spike before treating a fixed slot pool as physically bounded.** `SlotPool` embeds its `ActivationSlot` array and scrubs released slots. That establishes logical capacity and secrecy, but it does not demonstrate that macOS returns the pages to the system. Measure baseline, dirty every slot, suspend/release, and report resident footprint, compressed memory, and virtual size separately. If high configured slot counts matter, investigate a host-owned reserved mapping that recommits on borrow and discards on release; retain the address/capacity ceiling and only adopt it if activation latency and zero-fill semantics are proven.

3. **Use cold compression for immutable bulk blobs, not for Core State.** Conversation entries, model bodies, patch bytes, and full tool-output spools are the closest analog to scrollback. A versioned blob codec with bounded streaming decode can reduce disk and page-cache pressure, provided the digest and canonical semantic bytes stay unambiguous, the content is written and synced before ledger reference, and decoding cannot allocate an unbounded resident buffer. The bounded Core State and Activation Slot are too small and latency-sensitive to justify an idle compressor.

4. **Turn the memory budget into a state-transition measurement, not a single headline.** Measure Host Runtime baseline (including SQLite), active-slot count and high-water bytes, in-flight adapter buffers, blob/page-cache footprint, and UI/process resources separately. Run the same workload as active, waiting on a provider, restored-but-not-driven, and closed. Ghostty's result was persuasive because it separated app/GPU allocations from scrollback and distinguished physical from virtual memory.

5. **Preserve Ghostty's safety pattern for all eviction.** An evictable object needs explicit `resident/cold/rebuilding` state, an idempotent release path, and a generation/epoch fence for callbacks begun before eviction. A rebuild must occur only at a valid owner/context boundary and must produce a complete projection before it is shown. Do not evict Completion Inbox evidence, admitted-Attempt descriptors, or the data needed to settle a control operation.

## Bottom line

Ghostty's lesson is not "compress everything" or "free memory when hidden." It is: retain authority, discard reconstructable working sets, and make the release/rebuild state machine explicit enough that stale work cannot revive old state. OnePage has the durable-vs-Activation-Slot boundary needed for this already. Its highest-value next step is measurement of released-slot physical footprint and host-level warm-state retention, then an internal cold-Harness path only if those measurements show a real long-lived cost.
