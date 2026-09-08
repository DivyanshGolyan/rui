# Final Host policy: diagnostic rotation and retry polling

Status: research and recommendations, 2026-09-06. No new product decisions or production qualification. The accepted OnePage allowances are 128 MiB diagnostic history and a separate 8 GiB scratch allowance; the choices below are proposals.

## External precedent

Size rotation is conventional. Python's standard rotating handler uses a current file plus a configured number of backups. Its source explicitly avoids rotating an empty file before a record write: an oversized single record can therefore exceed the nominal file size. A file-size option alone is not evidence of a hard total cap. [CPython source](https://github.com/python/cpython/blob/main/Lib/logging/handlers.py)

systemd documents size-based retention without a necessary age expiry. It enforces limits when files extend, but deletes only archived files and explicitly warns that retained usage can exceed its nominal cap. This supports size retention as a convention, not copying its soft-limit semantics into OnePage. [journald configuration](https://www.freedesktop.org/software/systemd/man/252/journald.conf.html)

Unlinking a file that remains open does not release its contents until references close. Thus an exporter holding old rotated files open can defeat accounting that counts only directory entries. [Apple unlink documentation](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/unlink.2.html)

SQLite documents indexes that satisfy both filtering and ordering, avoiding a separate sort and its temporary storage. `EXPLAIN QUERY PLAN` shows scans/searches and temporary sorts; its rendered format is not a stable application API. [Query planning](https://www.sqlite.org/queryplanner.html), [EXPLAIN QUERY PLAN](https://www.sqlite.org/eqp.html)

## Recommended OnePage choices

Use one Host-owned append writer and a fixed small number of size-rotated structured files. Include the active file in the 128 MiB logical-byte total. As an internal layout, sixteen files of at most 8 MiB would fit the default, but neither the sources nor measurements establish that layout as uniquely right. Derive file size from the configurable allowance and keep file count bounded. Delete an oldest closed segment before accepting bytes that would exceed the allowance; if deletion fails, drop the new diagnostic rather than exceeding the cap or failing semantic work. Whole-segment eviction is coarser than record-by-record eviction but avoids rewriting retained history.

Encode each ordinary event through a fixed-size workspace; shorten optional text with an explicit omission marker before serialization would exceed that workspace. Preserve identifiers and error classification. Never construct an arbitrarily large record and only then check its size. The exact workspace constant is an implementation choice that must appear in the Host resource inventory.

Keep opt-in raw detail in the same retention budget as bounded chunk records with capture identity, order and completeness markers. No separate unbounded payload files or pinned captures. Old detail may rotate away; the export must not imply that a partial capture is complete. This is the simplest shared-budget policy, with an explicit tradeoff: enabling verbose capture shortens ordinary history. If protecting ordinary history later proves necessary, a separate partition is a new product choice, not a requirement established by these sources.

For append failure, stop writing to that damaged active tail. At restart, discard an incomplete final record before resuming append; do not treat diagnostic tail loss as canonical corruption. No per-event durability transaction or fsync promise is needed: the existing contract permits a missing crash tail. These are proposed consequences of OnePage's non-authoritative diagnostics contract, not a claim that plain append is crash-atomic.

Export through bounded reads into an ordinary charged scratch file, then deliver that file using the existing report/client lifecycle. Avoid keeping old diagnostic descriptors open for a slow client. For the simplest V1 export, record a best-effort cutoff and allow rotation to remove not-yet-copied segments; report the resulting gaps. Close each source between bounded copy turns. If rotation needs the currently open source, defer its deletion only to the end of that turn, without permitting excess retained bytes; meanwhile drop new diagnostics if necessary. A complete point-in-time snapshot would require stronger coordination and is not implied by “export recent diagnostics.” Copy and original bytes count in their respective live budgets.

## Retry poll

A one-second interval is a reasonable OnePage latency/idle-wakeup tradeoff, not a SQLite recommendation. Keep the existing single periodic eligibility poll; do not build a timer or task per waiting Operation. On each tick, use an indexed due-time selection with a bounded result count, and revalidate eligibility and allowance in the admission transaction. Visit actual due work rather than scanning historical Operations. Confirm its plan with representative data; a `LIMIT` alone does not bound work done before results are produced.

A retry becomes eligible at its saved due time; polling may add about one interval before discovery under otherwise idle service. It does not promise dispatch within one second when capacity, controls, imports or other work delay service. On late wake/sleep resume, run one current poll rather than replaying missed ticks. This cadence is independent of provider backoff policy and cannot create permission to retry uncertain external effects. No benchmark is needed to select the proposed cadence; actual idle CPU and query cost remain implementation verification.

## Verification implications

Test active-plus-archived cap enforcement, oversized/multibyte records, incomplete crash tails, failed removal/write, restart with a reduced configured cap, detailed capture rotation, and export overlapping rotation. Account for descriptors retained during copy as well as visible files. Test one retry timer, indexed bounded selection with substantial history, clock/sleep behavior, cancellation before admission and capacity-full service without a busy loop. These are required scenarios for the proposed choices, not passing evidence.
