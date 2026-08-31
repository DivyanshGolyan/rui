# Deletion-first memory efficiency

## Scope

This is a non-normative research note. It asks whether mature systems support a simple working
rule for OnePage: before introducing a clever allocator, cache, event loop, or compression scheme,
first remove state, representations, work, and ownership lifetimes that the product does not need.

The evidence supports that rule, with one qualification: deletion must preserve the system's real
semantic and recovery invariants. The useful question is not "can this byte be removed?" but "which
job still owns this byte, and why must that job remain live now?"

## Primary-source evidence

### Cloudflare: immutable data should not retain mutation machinery

Cloudflare reduced the per-entry memory of the 1.1.1.1 DNS cache by more than 50%, freeing about
100 TB across a population of more than 250 billion entries. Insert throughput increased 43% and
lookup latency fell 19%. The changes mostly removed unnecessary representation rather than adding
a sophisticated allocator:

- immutable `Vec` and `String` values became fixed `Box` values, removing capacity fields and
  unused reserved space;
- three record-section lists became one list plus two small offsets;
- record owners equal to the already-present cache key stopped being stored again;
- parsed enum variants and their separate allocations became one contiguous length-prefixed byte
  representation, eliminating both padding and repeated field-by-field serialization.

Cloudflare measured allocations per cache entry and lookup/insert performance, then verified
whole-process resident memory during rollout. The resulting p99 process memory fell from 9.3 GB to
5.3 GB. [Cloudflare, "How we saved 100 terabytes of memory by optimizing 1.1.1.1's DNS
cache"](https://blog.cloudflare.com/dns-cache-memory-optimization-1111/)

The OnePage lesson is broader than struct packing. Once a fact becomes immutable, it should not
retain growth capacity, an independently owned copy of an identity already available from its
context, or both parsed and encoded forms. This supports keeping one provider-neutral durable
Conversation, reconstructing requests at dispatch, and retaining only the bounded fields that can
still become authoritative while a provider event is being classified. A provider wire document,
JSON DOM, canonical response, and materialized Conversation must not all coexist merely because
each is convenient for a different function.

### Ghostty: do not let an exceptional allocation acquire the common lifetime

Ghostty's largest reported memory leak came from reusing an unusually large terminal page while
resetting only its size metadata. The underlying non-standard `mmap` allocation then appeared to be
a standard pooled page and was never unmapped. The fix was deliberately simpler than adaptive
pooling: never reuse a non-standard page; destroy it and return to the standard pooled size. Ghostty
also added Mach VM tags so the owning subsystem could be seen in whole-process tools. [Mitchell
Hashimoto, "Finding and Fixing Ghostty's Largest Memory
Leak"](https://mitchellh.com/writing/ghostty-memory-leak-fix)

Ghostty 1.3 applies the same lifetime discipline elsewhere: alternate-screen memory is allocated
only when used, saving several megabytes for terminals that never enter that mode, and its search
thread exits when the search UI closes. [Ghostty 1.3.0 release
notes](https://ghostty.org/docs/install/release-notes/1-3-0)

For OnePage, an unusually large provider value, workflow output, or tool result must not enlarge the
normal reusable cell after the operation ends. The ordinary reusable unit should return to its
declared shape; exceptional content belongs in immutable storage or a separately accounted,
short-lived allocation. Likewise, a closed Harness, blocked QuickJS evaluation, completed transport,
or unused validation stage should retain neither its owner object nor a worker merely because reuse
might someday be cheaper. Component-level high-water counters play the role of Ghostty's VM tags:
they make the physical owner visible before the implementation reaches for a global allocator fix.

### Orleans: durable identity does not require a resident activation

Microsoft Orleans defines a grain activation as an on-demand, temporary in-memory embodiment of a
logical grain. Idle activations are deactivated by removing references from the runtime's own data
structures, leaving only recently used grains resident. Orleans also warns that delaying
deactivation is an optimization rather than a way to pin an identity permanently. [Microsoft,
"Activation
collection"](https://learn.microsoft.com/en-us/dotnet/orleans/host/configuration-guide/activation-collection)

This is the closest established analogue to OnePage's density claim. A durable Session or Job is an
identity and history in SQLite, not a retained Harness, Activation Slot, provider client, timer, or
workflow evaluator. Reopening those resources on demand is the architecture, not a cache miss to be
eliminated. Any Host index that holds a strong reference to every historical or dormant object
would recreate the resident-actor model that Orleans activation collection is designed to avoid.

### Tokio: bound production instead of absorbing it

Tokio's bounded MPSC channel applies backpressure when its configured capacity is full. Its
unbounded channel instead makes available system memory the implicit bound and explicitly warns
that a lagging receiver can cause the process to abort from memory exhaustion. Received blocks are
freed, except for one block retained for immediate reuse. [Tokio `mpsc`
documentation](https://docs.rs/tokio/latest/tokio/sync/mpsc/) and [unbounded-channel
warning](https://docs.rs/tokio/latest/tokio/sync/mpsc/fn.unbounded_channel.html)

OnePage can be simpler still because it does not need a general work queue in V1. Active Credits and
private resource permits should be acquired before producing work; exhaustion should return
bounded `busy`. A queue added to smooth over admission failure would create a second resident
population, obscure backpressure, and retain request or response content outside the owner that can
execute it.

### Git: provisional bytes should not become authority

Git receives objects into a temporary quarantine directory, migrates them to the main object store
only after validation succeeds, removes the directory when the push fails, and forbids refs from
pointing at quarantined objects. [Git `receive-pack` quarantine
documentation](https://git-scm.com/docs/git-receive-pack#_quarantine_environment)

This supports OnePage's existing Candidate Writer and Host settlement boundary. Provider output may
be streamed once into provisional storage without also becoming Session state. Failure discards the
draft; successful sealing produces immutable evidence; only later admission may reference it from
authoritative lifecycle facts. A general mutable response transaction, recovery-visible partial
blob, or second in-memory response copy would weaken rather than simplify that ownership model.

## What this says about OnePage

The recent measurements already found two deletion-first wins:

- removing the Host's retained list of closed 8,088-byte Harness owners changed the 10,000-Session
  physical-footprint slope from about 83.9 MiB to about 0.88 MiB;
- deleting two unused 4 KiB scratch arrays reduced each Activation Slot from 8,360 bytes to 168
  bytes.

Neither improvement required a new allocator. Both corrected ownership: historical handles had no
live job, and stage scratch had no Slot job. The industry evidence suggests this should become the
default investigation order.

Before optimizing a measured cost, ask:

1. **Can the owner stop existing?** A dormant Session, blocked Run, closed Harness, or settled
   Attempt should normally be durable data, not a resident runtime object.
2. **Can the value be reconstructed?** Prefer a stable reference and bounded reconstruction over a
   resident derived view when the derivation is cheap relative to the wait.
3. **Are two representations live?** Look specifically for wire plus DOM, parsed plus canonical,
   content plus preview, mutable builder plus immutable result, or duplicated identity fields.
4. **Is a limit being mistaken for an allocation unit?** Maximum event, transcript, or output bytes
   should usually be a counted work bound, not an equally sized resident buffer.
5. **Did an exceptional case enlarge the common case?** Large values should use short-lived or
   durable overflow ownership rather than permanently growing a reusable pool or cell.
6. **Is buffering hiding missing backpressure?** Acquire the relevant permit before admitting or
   producing work; do not add an unbounded or weakly bounded queue to make overload appear smooth.
7. **Does the measurement cover the process and the lifecycle?** Measure allocation ownership for
   diagnosis, but decide from production-shaped whole-process physical memory, throughput, latency,
   churn, and post-quiescence retention.

## Recommended audit order

For each forthcoming vertical slice, use this sequence:

1. run the real workflow and attribute fixed, per-live-owner, per-active-operation, per-durable-byte,
   and workload-child costs;
2. remove owners that outlive their job;
3. remove duplicate or over-capable representations;
4. replace implicit buffering with admission control;
5. make exceptional allocations return to the ordinary envelope;
6. only then compare pools, caches, incremental parsers, reactors, or custom allocators against the
   simpler measured baseline.

The resulting design rule is:

> Durable population may grow on disk. Resident population may grow only with explicitly active
> work, and every resident byte must name the live job that owns it.

This rule does not forbid caching or pooling. It makes them measured optimizations with an explicit
owner, eviction point, and retained-memory budget rather than the default architecture.
