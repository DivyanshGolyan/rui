# Native unit roots

`test` compiles two ReleaseSafe roots in parallel from the canonical
`src/tests.zig` aggregate:

* **native**: all non-`store.` tests;
* **store**: every `store.` test, including migration/dialect acceptance.

Module ownership preserves each module's process globals. Executions are
**serial, Store last**: the MySQL dialect fixture uses fixed schema names and
rewrites `RUI_TEST_MYSQL_RECORD`. The final record remains the Store owner's
positive prepare/migration/conformance evidence, not a suite-wide counter sum.
An earlier failure stops the chain. The check shard gives the entire chain the
original **one 1200-second deadline**, entering `host_process.py` for each binary.

Compiler filters reduce sema/codegen, but Zig always includes anonymous tests
and matches filter substrings anywhere in a name. A generated adaptation of the
**installed stock runner** exposes only its root's exact owned subset, both in
terminal mode and in the build runner's metadata/index protocol. No runner is
vendored. `module.test.` compiler filters avoid the especially costly `tests.`
substring collision with `store.tests.`. Nested container tests use a safe
literal-name superset; runner ownership resolves overlap. Source enumeration
tracks file contents and directory additions. Discovery imports must be eager
in the aggregate: a module imported only inside an excluded named test body is
not discovered merely because its compiler filter exists.

Explicit `-Dtest-filter` invocations retain the original single stock-runner
`test` binary, full debug info, filter behavior and globals. This also preserves
renderer-mutation reproduction and cache-execution probes. `test-full` retains
its separate aggregate/default witness and `RUI_TEST_EXACT_INACTIVITY=1`; normal
unit/check runs force `0`. The complete aggregate also remains the macOS
semantic/type-check root.

Only unfiltered **Mac unit roots** omit DWARF. ReleaseSafe optimization and
runtime safety checks are unchanged. This reduces LLVM memory; filtered
reproduction retains source-resolved diagnostics. Production artifacts, stack
trace/codegen probes, logic tests and the deadline witness are not stripped.
Each Mac root reserves 3 GiB in Zig's scheduler. The existing separate macOS
unit producer and all PR/stable/qualification target names remain unchanged.
Artifact receipts validate both independently named executables.

## Verification and measurements

Measurements were run as non-root `tester`, Zig 0.17.0, Linux x86_64, four
2.10 GHz Xeon cores, 15 GiB RAM, no swap. LLVM is a Linux stand-in for the Mac
configuration, **not** a measured native Mac result. Packages were already
available; cold runs emptied both local and global compiler caches. Linux
self-hosted retains DWARF; LLVM-after uses the Mac unit-only DWARF policy.

The two-root choice trades a small wall-time difference for substantial memory
headroom: an exploratory three-root LLVM split took 397 s / 7.02 GiB aggregate
peak RSS, versus two roots' 425 s / 5.48 GiB. Those exploratory layouts exposed
lazy-discovery omissions; the final canonical imports fix those omissions.
They are performance-selection measurements, not the final coverage proof.
Three concurrent LLVM optimizers leave insufficient room on a 7 GiB runner.
The two-root split does **not** establish the desired less-than-half Mac job
time; a native Mac measurement is still needed, and repeated common Zig helper
compilation limits the speedup. Do not infer a native Mac time from Linux.

The completed cold benchmark (November 6, 2026):

| Configuration | Before producer wall | After producer wall | Before/after unit compile window | Before/after aggregate peak RSS |
| --- | ---: | ---: | ---: | ---: |
| Linux self-hosted, DWARF retained | 468.8 s | 426.5 s | 199.7 / 178.5 s | 2.13 / 3.36 GiB |
| Linux LLVM | 976.4 s | not run after scope cut | 695.5 s / — | 5.79 GiB / — |

The cold baseline is the original stacked `b8382a1a` tree (1,906 tests); the
completed after measurement is `a8647bcf` plus this split (1,908 tests, including
two added upstream launch-frame tests). Fresh shared transport/translation/C
builds and build-runner bootstrap are included in producer wall time; unit
window starts at the unit compiler invocation. Peaks sum descendant RSS sampled
at 0.5-second intervals; maximum single-process `ru_maxrss` was 2.16 / 1.90 GiB
for the self-hosted before/after builds. Both final roots compiled concurrently
in 163.4 and 178.5 seconds. This is an 11% unit-window reduction (9% producer).

For context only, the later `a8647bcf` monolith's cold unit compile with cached
C/shared dependencies took 658.7 s using LLVM (659.7 s producer, 5.69 GiB
aggregate peak), versus the earlier two-root **exploratory** 425.3 s / 5.48 GiB
layout with the Mac DWARF policy. That layout lacked five lazily discovered
word-search tests; its coverage is not the final proof. No further LLVM timing
was started after the user's scope cut. The real `macos_build_unit` producer is
the authoritative next performance measurement.

After fetching/rebasing onto `50f450cb` (which includes newer wire changes),
baseline and split are rebuilt for correctness only, without new timing runs.
The final metadata comparison is **1,930 = 1,370 native + 560 Store**, with
identical complete name counters (no dropped, extra or duplicate occurrences).
SHA-256 of the sorted names joined with `\n` (no trailing newline):
`0e840ca23af9f583ccc9d8d184d694567f162b220f5d2a36e4e5da8c0abb380c`.
The earlier `a8647bcf` comparison independently matched all 1,908 names.

The final runtime uses CI's pinned MySQL server with a tmpfs datadir and
`--innodb-stats-persistent=OFF`, required `sqlite,mysql`, the unchanged engine
credentials/record environment, non-root `tester`, and the actual check native
helper's shared 1200-second deadline. The local account needed its soft file
descriptor limit raised from 1,024 to its available 20,000; an earlier attempt
exhausted the lower fixture budget. No test assertions or skips were changed.
The CI Python harness suite passes: 353 tests, with only the explicitly opt-in
compiler probe skipped (the initial probe was also exercised during development).
Generator, metadata, serial execution/shared-deadline and multipart executable
integrity regressions are included. `zig fmt --check --ast-check`, shell syntax
and `git diff --check` pass. The rebased full run **passed in 434.3 seconds**: native 1,368 passed plus
its two existing skips (macOS-only `path_helper` and the separate real-time
inactivity witness), Store all 560 passed; **1,928 passed, 2 unchanged skips,
0 failures**. CI's MySQL verification passed with `ddl=118`, `prepares=448`,
`probes=4`, `migrations=2`, `conformance=184`, and zero DDL/PREPARE refusals.
No new skip was introduced. Logs, exact JSON name lists and benchmark process
samples are retained locally in `/home/tester/unit-split-bench/`.

Recheck full inventories (including anonymous/nested names and multiplicities):

```sh
python3 -B tests/ci/unit_test_names.py BEFORE/test-tests \
  AFTER/unit-native-tests AFTER/unit-store-tests
```

`--dump` exports raw names. The comparison uses counters, rejecting drops,
additions and duplicate occurrences. The opt-in compiler/protocol fixture also
covers anonymous discovery, nested containers/directories, overlapping filter
text and an import previously reachable only from a named test body:

```sh
RUI_TEST_ZIG_METADATA_PROBE=1 python3 -B -m unittest discover \
  -s tests/ci -p test_unit_test_names.py -v
python3 -B -m unittest discover -s tests/ci
```
