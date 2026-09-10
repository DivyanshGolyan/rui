# Bounded UTF-8 string construction for pinned QuickJS

Use the synchronous reader interface in [onepage_string_reader.h](onepage_string_reader.h) for this integration prototype. It validates/counts an immutable UTF-8 range, allocates the final correctly sized Latin-1 or UTF-16 string once, then fills it through bounded reads. It returns an ordinary owned JS value or a classified exception; no partially built string or engine pointer escapes. There is no begin/append/finish object to keep alive across callbacks.

The comparison justifies this small extension over collecting public-API string chunks and joining them. A 4 MiB ASCII prefix followed by `中` has a measured simultaneous backing-allocation peak of **8,622,640 bytes** with the reader, **12,849,712 bytes** with whole-input staging, and **24,129,584 bytes** with public constructors plus `join`. All three produce the same value under the same 16 MiB QuickJS setting. These are forced-moving allocator measurements, including old/new overlap, not predictions that every system realloc will move. [Derived measurements](measurements.md) keep process memory separate.

This selects a research integration interface, not a production dependency change or a complete evaluator rewrite. Accepted behavior still belongs to [ARCHITECTURE.md](../../../ARCHITECTURE.md#preparing-a-fixed-visibility-snapshot). The original [legacy-source audit and measurements](../README.md) remain historical production evidence; this follow-up does not make that bridge implement the redesigned contract.

## Reproduce and verify

From the repository root:

```sh
python3 research/evaluator-memory/string-reader/run.py
python3 research/evaluator-memory/string-reader/run.py --sanitize
python3 research/evaluator-memory/string-reader/run.py --negative-control
python3 research/evaluator-memory/string-reader/summarize.py
git diff --check
```

The default runner downloads the exact archive, checks its hash and every pinned top-level C/header file listed in [dependency.json](dependency.json), then appends a single include to a **temporary copy** of `quickjs.c`. It compiles the extension separately from the consumer probe. The original dependency, production source and build graph remain untouched. Use `--source /path/to/extracted/quickjs` offline; it must pass the same source hashes. `--smoke` runs a smaller development subset and writes `smoke.json`. Large payloads are generated through bounded chunks, not full parent strings. Preparation finishes writes, fsync and streamed SHA-256 verification before read-only handoff; deliberate later corruption is fault injection.

Both runners acquire `/tmp/onepage-memory-experiments.lock` before compilation and measurements. Each child receives empty environment, three stdio pipes and one explicitly inherited read-only prepared descriptor. The parent reaps it, closes the descriptor and removes scratch before reuse. Temporary build/dependency files disappear on exit. No credentials, provider calls, writable inherited input or production store access are used.

[Release records](results.json) contain the selected **16,777,216-byte QuickJS limit**, an **8,388,608-byte research native allocation ceiling**, **one-second soft/two-second hard CPU protection**, and **five-second parent timeout**. The native ceiling is a fixture control, not a proposed result-size policy. All compared methods use the same workload and limits. Provenance includes revision, pinned dependency hashes, harness hashes, compiler, OS and Python version.

[ASan/UBSan records](sanitizer-results.json) use the same memory settings with **10-second soft/11-second hard CPU and 30-second parent diagnostic limits**. Apple Clang does not define the macro this QuickJS pin checks for small-block allocator sanitization, so the runner explicitly sets `__SANITIZE_ADDRESS__=1`. That routes individual allocations through ASan instead of hiding them inside QuickJS's small-block arenas. These diagnostic footprints and times are not release qualification.

The first strict-budget sanitizer run was stopped by SIGXCPU while the JS oracle checked a 4 MiB value, after decoding had completed: [retained failure evidence](sanitizer-cpu-limit.json). Reproduce that profile with `--sanitize --strict-cpu --output /tmp/reader-strict-cpu.json`; a timing failure is expected on this machine, not a memory defect. The ordinary release matrix completes with the original selected limits. No sanitizer failure is described as a passing release-policy check.

## Interface and maintenance cost

The callable ownership/error rules are in the header. The implementation has one compatibility function, `op_allocate_string`, that accesses QuickJS string layout; callers use only the reader API and public QuickJS value/property APIs. The rest of the extension validates UTF-8 and traverses bounded input. The first pass derives width and UTF-16 units before allocating, so a late `U+0100`/CJK/astral character does not first allocate a payload-sized Latin-1 string and then widen it. Latin-1 characters such as `é` still use the compact engine representation. Native bytes are read twice; there is no whole serialized input string or native value tree.

Input immutability across the two passes is already required by the prepared-input contract. The constructor detects short reads, invalid UTF-8 and a changed width/count before an out-of-bounds write. It does not hash two passes to detect arbitrary same-width content changes; that would duplicate the existing immutable-input guarantee. The callback can return failure for I/O or cooperative cancellation. End-to-end cancellation/publication fences remain outside this prototype.

Production adoption would require maintaining this narrow private extension at the existing exact dependency pin, or obtaining a suitable upstream interface. That dependency-maintenance choice remains for the production implementation slice; this experiment does not silently approve a rolling engine fork. On **every pin/compiler/configuration update**:

- Re-audit `js_alloc_string`, `JSString`/`str8`/`str16`, `JS_STRING_LEN_MAX`, value tagging and refcount cleanup. Do not mechanically relax a failed hash check or apply fuzzy offsets.
- Rebuild the separate consumer against the pinned public header and rerun Unicode, key atomization, allocation-failure and teardown checks on both target OSes. Keep the extension compiled in the same configuration as the engine.
- Verify the pin's sanitizer allocator mode and run the allocator-growth cases. A green test using pooled small allocations does not exercise every individual failure point.
- Keep exception installation in the wrapper: this pin's atom conversion can return a null atom without installing an exception. The decoder explicitly turns that case into an engine-memory failure before unwinding.

The public-only baseline captures the pristine `Array.prototype.join` intrinsic before fixture code runs, constructs bounded UTF-8 chunks, and joins them into the same ordinary string. Its extra intermediate JS strings and growth/shrink copies explain the larger peak. It is a real tested alternative, not an assertion that public APIs cannot work. Its internal 4 KiB encoding array is fixed C stack, reported separately from heap allocation. Both the decoder and public baseline define own array elements instead of assigning through potentially author-modified prototypes. Object properties likewise use data-property definition. A [negative control](negative-control.json) restores assignment: all three methods then fail the prototype-accessor oracle. The fixed paths must preserve the complete value, invoke no inherited getter/setter, and ignore replacement of the captured join method. This protects native decoding from unexpected JS reentry; it does not freeze the returned values. Neither method caches decoded answers or changes mutable-object identity.

## What passed

The release matrix covers 111 cases. The diagnostic matrix covers 165, including failure at **each of 28 individual backing allocations** in the nested object/key/Promise path, for both direct and staged readers. In the normal pooled configuration the same small fixture makes only one backing-allocation request; that narrower fault sweep is not mislabeled as complete per-object coverage. Every injected failure is observed, produces the expected failure classification, emits no completed outcome and ends with zero tracked engine/native allocations. ASan/UBSan reported no memory/undefined-behavior diagnostics in the completed diagnostic run.

Coverage includes every Unicode scalar value (`U+0000` through `U+10FFFF`, excluding surrogate code points), all UTF-8 sequence widths, 1/2/3/7-byte windows, late Latin-1-to-wide and astral transitions, embedded NUL, numeric-looking keys, `__proto__`, distinct `é`/`Ã©` keys, 1 MiB keys, nested objects/arrays and 1,024 items. Invalid continuation, overlong encodings, encoded surrogates, values above `U+10FFFF`, truncated sequences, duplicate/invalid keys, nonfinite numbers, trailing bytes, impossible ranges, short input, injected read failures in either pass, native workspace/staging failure, engine exhaustion and source-change injection all reject without partial success.

The independent Python oracle uses its UTF-8/UTF-16 codecs; the JS oracle hashes every decoded UTF-16 code unit and structural field without materializing another serialized answer. That fingerprint is a regression oracle, not a cryptographic integrity primitive or a proof for every possible string combination. File integrity uses SHA-256 separately. Separate invocations verify distinct nested mutable objects; 10,000 awaits of one Promise preserve the mutated object's identity and perform one decode. Author-retained results and three burst/release cycles keep their real heap costs; teardown is checked after success and failure.

## Allocation and evidence boundaries

| Owner/population | Bound and release | Measurement boundary |
| --- | --- | --- |
| Native decoder | One borrowed string-read window during a synchronous lookup; 16 KiB in the main fixtures, smaller in boundary tests. The owner releases it before Promise handoff and on every error. | Requested and backing bytes separately, including tracker header and allocator rounding. Staged comparison additionally owns one complete input until decode finishes. |
| Engine | Final string once; ordinary arrays/objects, key atoms and Promises. Values remain until their actual JS/native references expire; runtime teardown releases the remainder. | All custom backing allocator calls. Forced-moving realloc allocates/copies before freeing, recording the exact simultaneous old/new peak. Native and engine maxima are not added from different instants. |
| C stack | Fixed cursor/scalar state, decoder frames with a retained 64-level research safety guard; public baseline also has a 4 KiB encoding array. | These automatic bytes are not heap allocations. Whole-process measurements include touched stack; exact total C-stack high-water is unmeasured. The depth guard is not an accepted architectural limit. |
| Parent | One completed scratch file and fixed write/hash windows for payload preparation. | Raw records show scratch bytes and Python preparation peaks. Fixture descriptions include small object/item lists and retained measurement rows; this is not a new production-parent-memory qualification. |
| OS/libc | Process mappings, allocator bookkeeping/caches, file cache and descriptors. | macOS task physical footprint and maximum RSS are separate from tracked allocations. File-cache/kernel-handle bytes and libc's internal metadata are not separately attributable. |

A material result is that **the 16 MiB QuickJS setting is not an instantaneous backing-allocation ceiling**. The pinned `js_realloc_rt` checks net growth; an allocator can hold old and new blocks simultaneously. The public baseline's 24,129,584-byte peak demonstrates this with forced relocation. The reader avoids growth/promotion for the final string, but general object/atom-table growth still needs the existing native/engine qualification. No new blanket memory cap is selected here.

`JS_ComputeMemoryUsage` is a structural estimate and can omit a string held only by a C-local handle before handoff. Its small pre-handoff number is not evidence that the large string is free. Use actual backing counters for overlap. Physical footprint can remain after live allocations fall; disposal and process exit, not a GC assertion, end this lifecycle's ownership. The full JS content oracle accounts for most of the large-case CPU; decoding checkpoints and full-lifecycle CPU are recorded separately.

The prototype consumes raw UTF-8 strings in a private tagged fixture format; it does not parse JSON escapes or select a production serialization/index layout. There is no complete hardened realm, visibility-key lookup, workflow publication, cancellation race, crash/power-loss or production evaluator integration proof. Production `check`/`workflow-check` were not run for these standalone research sources. Linux was not executed: allocator rounding, PSS/private-dirty/file-cache charges, containment and cleanup still require Linux runs. The C code's unavailable macOS footprint field is zero on Linux, meaning unmeasured rather than zero memory.

Primary evidence: the [pinned engine implementation](https://github.com/quickjs-ng/quickjs/blob/1ab8676f4b6d6d669baeb5f21790fb9734636a20/quickjs.c) (string allocation, `js_realloc_rt`, arena sanitizer switch, atom conversion), its [public API header](https://github.com/quickjs-ng/quickjs/blob/1ab8676f4b6d6d669baeb5f21790fb9734636a20/quickjs.h), and the [official memory/ownership guide](https://quickjs-ng.github.io/quickjs/developer-guide/intro/). The source files actually compiled are hash-checked by the runner; documentation claims are not substituted for execution.
