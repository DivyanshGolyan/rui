# OnePage integrated Host Runtime capacity proof

Status: disposable Wayfinder prototype for issue #67. This is not production
code and nothing in this directory is linked into OnePage.

> Historical topology note: ADR-0021 later removed this artifact's optional
> serial Patch thread. The normative design specifies temporary typed Action
> execution under Active Capacity and no permanent Patch lane. This prototype
> did not measure that replacement Patch topology; its measurements remain
> evidence only for the disk-first reactor, scratch, and shared-import design.

## Question

Can one Host keep content-sized custody on disk while Active Capacity rises from
1 to 100, without allocating a worker, parser, candidate, or response buffer per
effect?

This prototype intentionally contains only the topology needed to answer that
question:

```text
main / Storage Owner                 one reactor thread
  sole SQLite connection              libcurl multi handles
  custody-table scan          <---->   Bash stdout/stderr pipes
  one 4 KiB validator/import window    direct writes to unlinked spools
  short semantic transactions

optional serial Patch thread
  blocking filesystem work only
```

The fixed `PhysicalCustody` table is also the Active Credit mechanism. Its
records contain identities, descriptors, opaque library/process handles,
counters, deadlines, and state. They contain no content-sized arrays or owned
payload pointers. SQL contains backlog and recoverable meaning; a coalesced wake
only asks an owner to scan again.

Physical preparation starts after the Attempt transaction commits. Model and
Bash bytes stream into securely unlinked scratch files. The reactor publishes a
sealed descriptor through the custody record. The Storage Owner then validates
the sealed model artifact, imports it through one shared 4 KiB window, and
records Completion and Resolution in one transaction. The spool remains open
during import so the raw-plus-canonical overlap is measurable and is closed only
after commit. Reusing a custody record clears every per-Attempt identity,
descriptor, process field, deadline, counter, and flag before publishing the
record as free.

## Boundary of this first executable slice

`integrated_capacity.c` covers the mixed model/Bash data plane, minimal scratch
SQLite admission and settlement boundaries, a Patch lane timing control, exact
custody size, phase-specific process measurements, terminal validation after
seal, and repeated `0 -> capacity -> 0` cleanup without restarting the Host
lanes. Its SQLite tables exist only to measure
short commits and disk import; they are not a proposed OnePage schema.

Retry policy, candidate admission, cancellation winners, ordered sibling
projection, recovery, and relational fail-stop are intentionally absent. A
disposable simulator would merely duplicate those rules. Issue #52 must test
the relational constraints and projection commands; issue #34 must test the
physical admission, retry, cancellation, custody, and effect-recovery paths.

The earlier sibling artifact, `../reactor-capacity-100`, remains the narrow
transport control. It is not evidence for this combined topology.

## Build

```sh
clang -O2 -std=c11 -Wall -Wextra -Werror \
  integrated_capacity.c -o integrated_capacity \
  -lcurl -lsqlite3 -lpthread

./integrated_capacity integrated 10 \
  https://localhost:18443/responses cert.pem /tmp proof.sqlite3 lane 60

```

The matrix runner creates its certificate, database, spools, and generated
measurements under a temporary directory. Generated files do not belong in the
repository.

For the short, non-publishable correctness matrix:

```sh
chmod +x run_smoke_matrix.sh
./run_smoke_matrix.sh
```

The script prints the temporary results path. It runs capacities 1/10/50/100,
a three-wave capacity-100 churn case using the same reactor and Patch lane, and
a sealed model stream without its terminal protocol
item. It also proves that a post-commit scratch-open failure settles the admitted
Attempt rather than disappearing or launching without custody. Five Bash child
fixtures cover ordinary exit, TERM exit, TERM-ignore/KILL, inherited pipe ends,
and an escaped descendant whose pipe is closed at the fixed grace. Three
fence-free Patch fixtures use a real 1 MiB named target and a concurrent Bash
writer: interference before the preimage check conflicts, interference after
the check is overwritten and verified by Patch, and interference after Patch
verification leaves the later current file divergent without rewriting the
earlier directly observed Patch evidence. An isolated
low-`RLIMIT_NOFILE` run verifies that admitted preparations settle without a RAM
fallback and all descriptors return to baseline. It is
deliberately short. The publishable matrix uses longer rotated
runs, churn, fault injection, Patch-owner comparisons, cache controls, and the
real-provider gate described in issue #67.

`run_disk_full.sh` creates and mounts a disposable 5 MiB HFS+ image, fills it,
and verifies that a real spool write reaches local-resource Completion, imports
no partial artifact, drains and reaps Bash, releases its scratch charge, and
returns descriptors to baseline. The script always detaches the image through
its exit trap.

`run_vmmap_probe.sh` holds the capacity-100 process after every credit and spool
has released, captures `vmmap -summary`, and reports the retained total, stack,
and malloc dirty columns alongside the process counters. The raw summary path is
always included because the human-readable size strings are not suitable for
arithmetic thresholds.

`run_churn_probe.sh` keeps one reactor and Patch lane alive for ten consecutive
capacity-100 waves. It reports the retained physical-footprint change from the
first idle point to the final one, then repeats the same workload with one
allocator pressure-relief call only after Active Credit has returned to zero.

`run_duration_cache_probe.sh` compares cached and `F_NOCACHE` scratch spools for
equal ten-second capacity-100 streams, then holds the no-cache topology for a
sixty-second stream. It reports resident-footprint deltas separately from the
expected growth in transient disk allocation.

`run_rotated_matrix.sh` runs four Latin-square rotations of capacities
1/10/50/100 so every capacity appears once in every execution ordinal. It emits
raw JSONL and median capacity summaries; capture the machine load alongside the
result rather than treating a busy-host sample as a release budget.

## Claims this artifact may make

- measured parent-process residency and physical footprint at capacities
  1, 10, 50, and 100;
- exact parent thread and descriptor high-water;
- exact `sizeof(PhysicalCustody)` and the absence of content fields;
- model/Bash drainage correctness and reactor service tails;
- serial validation/import concurrency of one;
- SQLite cache use when the linked library reports it, support status for global
  heap accounting, and settlement latency;
- raw spool occupancy and raw-plus-canonical disk overlap; and
- retained parent footprint after all custody returns to zero.

It must not infer per-process filesystem-cache residency from global
`vm_stat`, nor call localhost TLS a real-provider proof. A real-provider run is
a separate publication gate.
