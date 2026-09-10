# Fixed execution tracking

Accepted in architecture discussion on 2026-09-08. Documentation only; implementation and measurements remain pending.

Allocate exactly `active_capacity` content-free tracking records once at startup. Each holds neutral work or one reservation/execution whose cleanup is incomplete. The control loop visits the full array; neutral work is a no-op. Admission replaces neutral work, reservation rollback releases an unused reservation, and completed cleanup returns occupied work to neutral. The array never grows and uses no separate free list or active-entry list.

Neutral records have no durable Operation or Attempt and own no execution resources. Waiting work remains discoverable from SQLite. Only tracking metadata is preallocated: execution buffers, transport and subprocess resources retain their own bounded ownership. A saved outcome does not release a record whose resources remain in use.

Planning estimate: 128–256 bytes per record, or 8–16 KiB for 64 records and 128–256 KiB for 1,024. These are arithmetic estimates, not a measured layout or total runtime footprint. Measure structure size and full-capacity loop behavior during implementation.

The idea applies [Matklad's static-allocation and constant-work discussion](https://matklad.github.io/2026/09/02/static-allocation-constant-work.html) to the small live-execution population, not the unbounded durable history or every library allocation. The architecture's Physical Custody contract and the verification document own the requirements.

## Waiting-work selection

Accepted 2026-09-09: oldest eligible Operation receives the next available record. Use durable Operation admission order with a stable unique tie-breaker; approval, retries and restart do not reset age. Filter eligibility first so blocked older work cannot prevent younger eligible work from starting. Revalidate in the Attempt-admission transaction, dispatch after commit, and release reservations if admission fails. An uncertain admitted tool Attempt is recovered as indeterminate, never selected for replay.

SQLite owns waiting work; bounded indexed selection avoids a full-history scan. No separate waiting queue, per-Session rotation or priority framework is introduced. The rule orders admissions and does not promise bounded waiting when all records remain occupied. Protected controls and inspection retain their own service rules.

## Wakeups

Accepted 2026-09-09: handle events, save results, fill available records, then use the ordinary OS/event-library wait when no immediate progress is possible. Wake for client activity, provider readiness, subprocess output/exit, applicable cleanup notifications or the next relevant timer. Include the existing retry-eligibility poll deadline. Continue bounded passes without waiting when local work can advance; retain protected-control and inspection service rules.

The same local owner writes SQLite, so it checks eligibility after its writes rather than watching the database. Full capacity makes an approved action wait until cleanup releases a record. Register event sources and check pending work without losing arrivals at the wait boundary. Reconstruct pending work on restart.

The [throwaway native prototype](../../research/idle-loop-prototype/README.md) measured a 64-slot idle scan-only loop at 99.26% of one core versus 0.0010% with an OS wait. Short-run synthetic measurements support waiting; they are not production CPU or latency guarantees and do not change the unmeasured tracking-layout estimate above.
