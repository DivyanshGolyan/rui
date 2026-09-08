# Lower memory for exact edits

Research date: 2026-09-06. Primary-source web research; proposed implementation ideas only. This note does not amend the editing contract, establish a new limit, or report a new benchmark.

## Recommendation

The first opportunity is ordinary ownership: run the edit preparation inside the existing Host, borrow an existing bounded I/O buffer, retain only one copy of the search text, and reuse the buffer across scanning and output copying. Do not create one process, thread stack, complete-file string or generated line diff per edit.

The earlier roughly 0.78 MiB number measured a standalone process, not the incremental allocation required for another edit inside a running Host. Establish that process's idle baseline and its actual algorithm workspace before targeting a 10–100 times reduction. In-process execution amortizes startup/runtime cost; it does not make the Host's baseline disappear. This is a measurement inference, not a measured improvement.

A target below roughly 80 KiB of incremental preparation workspace (ten times below 0.78 MiB) is plausible for short search text and bounded I/O. Roughly 8 KiB (one hundred times below) is a different, more restrictive target: it leaves little room for a buffer, the input and matching metadata. Neither is established by literature or guaranteed for arbitrary search-text length. Count borrowed buffers and input bytes once under their actual owner rather than labeling them free.

## Streaming-search alternatives

KMP's failure-table form retains the search pattern and one integer per pattern position. Its scan advances through the text without rereading earlier text, so its state can carry across file-read chunks. Princeton's reference demonstrates the pattern plus `next` array and a scan that never moves its text index backward. The conversion from its string input to bounded file reads is our design inference. [Princeton KMPplus source](https://algs4.cs.princeton.edu/53substring/KMPplus.java.html).

For a byte pattern of length M and 32-bit entries, the owned pattern plus table is approximately 5M bytes, before the fixed I/O buffer and small state. Borrowing already owned pattern bytes avoids another M-byte copy, but does not remove those bytes from the system total. A 32-bit representation is valid only if the selected search bound fits and indexing arithmetic is checked. These are representation calculations, not empirical RSS predictions.

Keep the streaming match and output-copy phases separate so they can reuse one I/O window. If retaining the first match position and detecting a second match is sufficient for exact uniqueness, do not accumulate every match. This removes storage proportional to the number of occurrences. Boundary and overlapping-match semantics still need their existing tests.

## Constant auxiliary memory is real, with an important qualification

Crochemore and Perrin's Two-Way algorithm uses constant additional storage beyond the pattern and text, with linear-time preprocessing and searching. The original paper explicitly excludes the locations of the text and pattern from that auxiliary-space claim. It compares portions in both directions, requiring accessible content around the candidate match. [Original paper](https://monge.univ-mlv.fr/~mac/Articles-PDF/CP-1991-jacm.pdf), [C++ standards proposal](https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2017/p0638r0.pdf).

Real libraries demonstrate that this need not involve a heap allocation. musl's `memmem` uses local state, a 32-byte bitset and 256 machine-word shift entries—about 2 KiB for that table on a 64-bit target. Its input is already contiguous memory. That is evidence of a small search routine, not of constant-memory file editing. [musl source](https://git.musl-libc.org/cgit/musl/tree/src/string/memmem.c).

Rust's memchr `Finder` explicitly supports borrowing the needle; converting to an owned finder copies it. Its search has a constant-space guarantee while accepting a byte-slice haystack. That API is useful prior art for clear ownership. It does not include storage for an arbitrary file or a streaming window. [Finder documentation](https://docs.rs/memchr/latest/memchr/memmem/struct.Finder.html).

For a bounded small pattern, Two-Way can search overlapping read windows, but boundary retention, duplicate suppression and window sizing become our responsibility. An M-byte-scale window remains necessary for this straightforward adaptation. For patterns larger than the window, seek-backed access is possible but adds I/O behavior and correctness surface. Do not implement that machinery just to remove a small KMP table. Reconsider only if measured realistic search-text sizes make that table a material expense.

## mmap does not make file memory free

Apple documents that mapping brings accessed file pages into physical memory and that reading a large mapped file can force other memory out. Mapping can avoid a userspace copy, but a full scan still accesses the file and the OS controls residency. External file changes can also invalidate assumptions. It would complicate a strict fixed-workspace explanation without demonstrating lower machine-wide memory use. Prefer ordinary bounded reads for this sequential edit workflow. [Apple file-mapping guide](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemAdvancedPT/MappingFilesIntoMemory/MappingFilesIntoMemory.html), [Apple virtual-memory guide](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/ManagingMemory/Articles/AboutMemory.html).

## What to measure next

Measure an idle baseline and edit peak within the same native process, plus explicit maximum live algorithm bytes. Report process physical footprint separately from incremental workspace and filesystem cache. Exercise concurrent preparations only through the selected scheduling model; multiplying standalone process peaks is not an in-process concurrency estimate.

Keep recovery safeguards: prepared output remains charged scratch; source identity/content validation and durable commit/recovery remain intact. A smaller matcher is no reason to overwrite the source in place or omit hashes. Shrinking the I/O window should be justified by throughput and syscall measurements, not an attractive byte count.

The current OnePage prototype already uses libc `memmem` over overlapping windows, not a KMP table. Keep that simple mechanism while qualifying its supported-build behavior; KMP and Two-Way above are alternatives, not recommendations to add another search layer. Gnulib documents platform differences in `memmem` worst-case behavior, including macOS 14, so do not assume every libc provides a linear-time guarantee. [Gnulib portability notes](https://www.gnu.org/software/gnulib/manual/html_node/memmem.html). No custom allocator, whole-file mapping, rolling-hash collision protocol or new buffer-pool subsystem is justified by the current evidence.

## Follow-up baseline evidence

The parent investigation ran five rotated standalone baseline/edit pairs,
captured in local `codex/exact-edit-probe` commit `ff24807`,
`research/exact-edit-probe/baseline-results.json`. A tiny executable using the
same hash library but doing no edit used 819,712–836,160 bytes physical
footprint; the edit used 836,096–901,632. These are separate programs, not a
precise same-process incremental allocation measurement. They show why the
roughly 0.78 MiB process number must not be presented as per-edit workspace.

For the four-byte needle fixture, named current-prototype buffers are 16,391
heap bytes for needle/scan plus a 16,384-byte copy window, with two 104-byte
SHA-256 contexts and other control/library state. Reusing the scan buffer
after matching removes the separate copy window without changing the matcher.
A 4 KiB rather than 16 KiB window is another candidate, with throughput/syscall
cost to check; it is not needed to claim that incremental storage is already
much smaller than a standalone executable's baseline. No 10–100x whole-Host
memory improvement is established or implied.
