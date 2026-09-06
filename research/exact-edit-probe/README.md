# Throwaway native exact-edit probe

Question: can OnePage prepare a unique literal replacement without Git, full-file strings, a line index or an unrestricted diff?

## Run

On macOS:

```sh
cc -O2 -Wall -Wextra -Wno-deprecated-declarations research/exact-edit-probe/edit.c -o /tmp/onepage-exact-edit-probe-bin
python3 research/exact-edit-probe/run.py
```

No production code. Files are disposable fixtures; the native executable never overwrites the input. `results.json` contains the final run.

## Candidate and result

Input is an **already sealed snapshot**, a nonempty literal search string, and replacement bytes. Count every match, including overlapping matches; reject zero matches or a second match before creating output. For one match, stream prefix + replacement + suffix into separate scratch, calculating preimage and postimage SHA-256. Preserve bytes outside the span, including CRLF, UTF-8 and BOM bytes if present. There is no fuzzy matching, newline rewriting, replace-all or full-file diff generation.

The scan uses the platform `memmem` over overlapping chunks. Keep the last needle-length-minus-one bytes across reads, and choose a chunk at least as long as the needle. This avoids a custom string-search algorithm or line index. Copies use a 16 KiB stack window. The prototype first explored KMP; the retained implementation uses the simpler libc search and needs no prefix table. This is a native function candidate, not a proposal to spawn a new edit executable per operation.

All 12 final cases passed: ordinary replacement; a match crossing the 16 KiB boundary; overlapping ambiguity; absent and empty needles; CRLF; UTF-8; deletion; the same roughly 1 MiB/500,000-line source as the Git fixture; 128 MiB source; 4 MiB replacement; and 1,000,001-byte search text. Successful small outputs matched a byte-for-byte reference; all successful cases' streamed preimage/postimage hashes matched independent Python hashes. The 128 MiB case additionally checked output length and replacement tail. Failure cases created no output. These finite checks are not a full correctness or failure campaign.

## Memory observations

Measurements are `/usr/bin/time -l` for the native executable, excluding Python fixture generation. Each is a single observation, not a distribution or whole-Host benchmark.

| Fixture | Peak process physical footprint |
| --- | ---: |
| 1,000,004-byte file / 500,000 short lines; 4-byte search | 819,712 bytes (~0.78 MiB) |
| 128 MiB source with small search | 836,160 bytes (~0.80 MiB) |
| 4 MiB replacement streamed from its file | 819,712 bytes (~0.78 MiB) |
| 1,000,001-byte search text | 2,884,224 bytes (~2.75 MiB) |

The equivalent many-short-lines Git fixture used about 11.5–12.6 MiB in the separate `codex/patch-scratch-probe` run. This comparison supports eliminating file/line-proportional preparation work, not a complete Patch latency or Host budget claim. Git and this executable have different semantics and scope; this executable does not parse unified patches or mutate the live file.

Memory is **O(search-text size), not fixed for arbitrary inputs**. The scan allocates the needle plus `max(16 KiB, needle length) + needle length - 1` bytes: approximately 16 KiB plus twice a short needle, or three times a large needle. The copying function has one 16 KiB stack window; two small hash states and other control state are additional. Resident physical footprint can differ from allocated bytes. Replacement content and file content are streamed. The 1 MiB needle case deliberately exposes this remaining input dependency rather than hiding it behind a small fixture.

Before production acceptance, choose an explicit search-text bound justified by its resident workspace, or select a different scratch-backed matching mechanism. No numeric bound is selected by this prototype; the address-size guard is an arithmetic safety check, not product policy. It would be misleading to promise flat RAM with unbounded oldText. Full tool JSON parsing must also preserve the existing disk-first argument/content path.

## Preserve OnePage's existing guarantees

This only replaces preparation of the expected postimage. Production must still own authorization, exact descriptor/content references, preimage/expected-postimage hashes, live-target identity/revalidation, storage reservation and errors, and crash reconciliation. An in-process file lock cannot exclude arbitrary external writers; do not claim atomic compare-and-swap or unconditional atomic edit from this probe.

The sealed input and prepared output coexist temporarily and both consume logical scratch. The candidate output size is exactly source length minus oldText length plus replacement length; use checked arithmetic and ordinary write-boundary reservation. No Git helper, named Git tree, helper-specific scratch reservation or inherited Git lock is needed for this preparation. The live effect's existing write/recovery policy is a separate decision; do not substitute a rename casually if inode semantics must remain unchanged.

Changing from unified Patch input to oldText/newText is an explicit model-visible contract change. Pi/OpenCode/Codex research supplies prior art but not acceptance. No new concurrency cap, changed 256 MiB target, dropped permission guarantee, file-creation feature or Git-tracking-policy change is made here. Actual integrated memory/CPU/fault/recovery qualification remains required.

## Separate executable baseline from edit workspace

Follow-up to the request for 10–100x lower memory: `baseline.c` links the same hash library and hashes an empty string without performing an edit. Build with the same flags to `/tmp/onepage-exact-edit-baseline`, then run `python3 research/exact-edit-probe/baseline.py` after building the edit executable. Five rotated baseline/edit pairs are recorded in `baseline-results.json`.

Baseline physical footprint ranged 819,712–836,160 bytes (median819,712); the many-line edit ranged836,096–901,632 bytes (median852,544). These are separate executables, not a precise in-process allocation subtraction. Nevertheless the roughly0.78MiB minimum largely exists without any editing, so reporting it as per-edit workspace would be misleading. One CommonCrypto SHA-256 context is104bytes on this build; the prototype has two. For a4-byte search the explicitly allocated search/scan buffers total16,391bytes, while the copy function has a separate16,384-byte stack buffer. They coexist in the current prototype. Other stack/library/allocator state is additional.

A direct simplification is to reuse the scan buffer for copying after matching finishes, and release search text when no longer needed. Borrowing an existing Host window is possible only where lifetimes permit; truly simultaneous users cannot share a mutable buffer. Smaller I/O windows trade memory against more read/write calls and require throughput evidence. No change to production or the accepted concurrency policy follows from the baseline measurement. A claim of10–100x lower whole-process memory is not supported; a tens-of-KiB incremental workspace is the relevant in-process design quantity.

## Reused 16 KiB versus 4 KiB buffer experiment

Run `python3 research/exact-edit-probe/tuning.py`. It compiles `tuning.c` three ways: separate scan/copy16KiB windows (control), reused16KiB window, and reused4KiB window. All variants release search text before output copying. Original `edit.c` and its historical results remain unchanged. `run.py` now accepts optional executable/results environment overrides so the same correctness fixtures exercise all three variants.

All **36 correctness cases** passed (the existing12cases per variant). The benchmark then ran **45 cases**: three fixtures, three variants and five rotated repetitions. Output sizes and streamed hashes were checked; Python independently rehashed actual output bytes outside the timed native region. `tuning-results.json` contains all raw measurements and summaries; `correctness-*.json` contains each variant's correctness observations.

| Fixture | Separate16KiB windows median wall | Reused16KiB median wall | Reused4KiB median wall |
| --- | ---: | ---: | ---: |
| 64 KiB | 0.384 ms | 0.407 ms | 0.465 ms |
| 1,000,004-byte many-line file | 2.708 ms | 2.706 ms | 3.702 ms |
| 128 MiB | 319.409 ms | 321.989 ms | 467.310 ms |

The reused16KiB design has no meaningful observed timing disadvantage over the separate-buffer control in these samples. Reused4KiB was about37% slower on the many-line fixture and45% slower on128MiB. For128MiB,16KiB used16,387 reads and8,193 writes;4KiB used65,539 reads and32,769 writes. Counts include needle input and final EOF reads; they count actual calls made by this native path, not an OS-wide trace. Smaller windows trade syscall overhead for less buffer storage.

For the four-byte needle, reused16KiB needs16,391 explicitly allocated needle/scan bytes at scan peak and has no second16,384-byte copy buffer. Reused4KiB needs4,103 such bytes. Two104-byte hash contexts, other state, allocator/runtime memory and search-library internals remain additional. The needle is freed before copying. Search-text growth still changes buffer size; no numeric search cap is selected here.

Standalone physical-footprint medians were885,248bytes for both16KiB variants on128MiB, versus819,712bytes for4KiB. On64KiB all three were819,712bytes. The many-line medians were885,248 versus868,864bytes. Thus actual process residency is page/allocator/baseline dependent, not a byte-for-byte reflection of buffer removal. This is not evidence of10–100x smaller process memory. The structural removal of the redundant buffer is the reliable result.

Native wall time starts inside main and includes input open/read, matching, hashes, output creation/write and cleanup, excluding process launch and Python verification. CPU measurements use process-lifetime getrusage and therefore include startup work; short-fixture CPU must not be compared directly with this wall interval. I/O is cached local-file I/O, without fsync; these are not durable-write latency, full OnePage live-edit/recovery timing, a statistical equivalence test or concurrency certification. Single-file traversal also does not prove bounded control-service latency for arbitrarily large edits.

Recommendation: reuse one16KiB window for scan and copy, retain simple libc matching and streamed content, and stop tuning the window size for now. This is a prototype recommendation, not acceptance of a new Edit tool contract or a change to production source.
