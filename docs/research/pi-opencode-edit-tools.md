# Pi, OpenCode V2 and Codex CLI edit tools

Research date: 2026-09-06. Read-only investigation of upstream implementation; no proposed OnePage contract is accepted by this note. No upstream memory benchmark was run.

## Conclusion

All three projects demonstrate that targeted file editing can use text replacement without launching Git. OpenCode **V2** is especially relevant: its new edit tool deliberately implements exact replacement and defers its older fuzzy correction machinery. That is useful prior art for simplifying OnePage's edit contract.

None of these implementations demonstrates bounded memory: each reads the complete file, constructs replacement content and has line-dependent representations or diff work. Copying their implementation would remove the Git process but would not establish a small fixed memory footprint. OnePage should evaluate the replacement semantics separately from their whole-file JavaScript implementation.

## Sources inspected

- Pi repository `badlogic/pi-mono`, main commit [`9767ba275f3e9a5ee0f5c5342249b629ab1b2282`](https://github.com/badlogic/pi-mono/tree/9767ba275f3e9a5ee0f5c5342249b629ab1b2282).
- OpenCode repository `anomalyco/opencode`, dev commit [`337fd144d2ba144743368f78d9579a99cce175bd`](https://github.com/anomalyco/opencode/tree/337fd144d2ba144743368f78d9579a99cce175bd).

The relevant OpenCode V2 path is **`packages/core/src/tool/edit.ts`**, whose module comment explicitly identifies the model-facing V2 exact-edit tool. The similarly named `packages/opencode/src/tool/edit.ts` is not the implementation analyzed here. These are pinned development snapshots, not a claim about a specific installed release.

## Pi

### Semantics

Pi's coding-agent tool takes a path and a nonempty array of `oldText`/`newText` replacements. All replacements match the original file, not earlier replacements in the same call. It rejects empty search text, absent matches, ambiguous matches, overlaps and a final no-op. The model-facing contract requests exact, unique text. [Tool schema and execution](https://github.com/badlogic/pi-mono/blob/9767ba275f3e9a5ee0f5c5342249b629ab1b2282/packages/coding-agent/src/core/tools/edit.ts), [matching implementation](https://github.com/badlogic/pi-mono/blob/9767ba275f3e9a5ee0f5c5342249b629ab1b2282/packages/coding-agent/src/core/tools/edit-diff.ts#L296-L361).

The implementation is more permissive than that description: it first tries exact matching, then applies Unicode NFKC normalization, trims trailing line whitespace and normalizes selected quotes, dashes and spaces. Its occurrence count uses this fuzzy-normalized view even when an exact match exists. If any edit requires fuzzy matching, all matches are evaluated in that normalized space. Unchanged line blocks are restored from the original normalized input; touched lines can carry normalization beyond the literal replacement span. [Normalization](https://github.com/badlogic/pi-mono/blob/9767ba275f3e9a5ee0f5c5342249b629ab1b2282/packages/coding-agent/src/core/tools/edit-diff.ts#L28-L54), [lookup and occurrence count](https://github.com/badlogic/pi-mono/blob/9767ba275f3e9a5ee0f5c5342249b629ab1b2282/packages/coding-agent/src/core/tools/edit-diff.ts#L202-L251), [line preservation](https://github.com/badlogic/pi-mono/blob/9767ba275f3e9a5ee0f5c5342249b629ab1b2282/packages/coding-agent/src/core/tools/edit-diff.ts#L123-L173).

Pi strips and restores a UTF-8 BOM. It normalizes CRLF and bare CR to LF before matching, then restores the detected LF/CRLF style to the full output. This is text normalization, not byte-for-byte preservation of arbitrary mixed line endings. [Newline functions](https://github.com/badlogic/pi-mono/blob/9767ba275f3e9a5ee0f5c5342249b629ab1b2282/packages/coding-agent/src/core/tools/edit-diff.ts#L11-L25), [execution](https://github.com/badlogic/pi-mono/blob/9767ba275f3e9a5ee0f5c5342249b629ab1b2282/packages/coding-agent/src/core/tools/edit.ts).

### Memory and mutation

The coding-agent implementation holds a complete file Buffer and decoded string, normalized content and resulting string. Fuzzy matching adds normalized strings and line arrays; replacement and diff generation add further content-dependent work. It writes the complete final string, then produces both a display diff and a unified patch. These are observations about allocation topology, not a measured peak or exact simultaneous-live-byte total: JavaScript substring storage and garbage collection are runtime-dependent. [Execution](https://github.com/badlogic/pi-mono/blob/9767ba275f3e9a5ee0f5c5342249b629ab1b2282/packages/coding-agent/src/core/tools/edit.ts), [diff generation](https://github.com/badlogic/pi-mono/blob/9767ba275f3e9a5ee0f5c5342249b629ab1b2282/packages/coding-agent/src/core/tools/edit-diff.ts#L365-L499).

A process-local queue serializes cooperating mutations by resolved real path. The tool holds it across read, write and diff generation; cancellation checks after awaited operations avoid releasing the queue while an in-flight write can still finish. The default operation uses `fs.writeFile`; this tool does not reread and compare the file immediately before writing or implement a temporary-file atomic replacement/recovery protocol. The local queue cannot exclude external editors. [Mutation queue](https://github.com/badlogic/pi-mono/blob/9767ba275f3e9a5ee0f5c5342249b629ab1b2282/packages/coding-agent/src/core/tools/file-mutation-queue.ts), [default file operations and execution](https://github.com/badlogic/pi-mono/blob/9767ba275f3e9a5ee0f5c5342249b629ab1b2282/packages/coding-agent/src/core/tools/edit.ts).

The newer `packages/agent/src/harness/tools/edit.ts` also exists at this revision. It has the same multi-edit shape and matching/diff strategy, but delegates reading and writing to environment operations. It does not make the matching/diff algorithm streaming. [Harness tool](https://github.com/badlogic/pi-mono/blob/9767ba275f3e9a5ee0f5c5342249b629ab1b2282/packages/agent/src/harness/tools/edit.ts), [harness matching](https://github.com/badlogic/pi-mono/blob/9767ba275f3e9a5ee0f5c5342249b629ab1b2282/packages/agent/src/harness/tools/edit-diff.ts).

## OpenCode V2

### Semantics

V2 takes `path`, `oldString`, `newString`, and optional `replaceAll`. It rejects an empty search string, identical input strings, no match, and multiple exact matches unless `replaceAll` is explicitly true. Occurrences are counted without overlap. It explicitly defers V1 fuzzy correction, formatter, watcher, snapshot/undo and LSP integrations. [V2 tool](https://github.com/anomalyco/opencode/blob/337fd144d2ba144743368f78d9579a99cce175bd/packages/core/src/tool/edit.ts#L23-L86), [matching and replacement](https://github.com/anomalyco/opencode/blob/337fd144d2ba144743368f78d9579a99cce175bd/packages/core/src/tool/edit.ts#L127-L182).

V2 decodes UTF-8 and handles BOM separately. It detects CRLF if the source contains any CRLF and converts the supplied search/replacement newlines to that style; it does not first normalize the entire existing file to LF. Its exactness therefore includes deliberate LF/CRLF accommodation. [Encoding functions](https://github.com/anomalyco/opencode/blob/337fd144d2ba144743368f78d9579a99cce175bd/packages/core/src/tool/edit.ts#L41-L54), [execution](https://github.com/anomalyco/opencode/blob/337fd144d2ba144743368f78d9579a99cce175bd/packages/core/src/tool/edit.ts#L161-L196).

### Memory and mutation

V2 reads complete file bytes, decodes a full string, builds a replacement string, computes `diffLines` for counts and creates a complete unified patch for the result. Its short model-facing preview does not remove that full diff work. Before writing, `FileMutation.writeIfUnchanged` reads the complete current file again and byte-compares it against the initial bytes under a canonical-target process-local lock. This catches stale content between the first read and the locked comparison for cooperating mutations. [V2 execution and diff](https://github.com/anomalyco/opencode/blob/337fd144d2ba144743368f78d9579a99cce175bd/packages/core/src/tool/edit.ts#L161-L208), [mutation service](https://github.com/anomalyco/opencode/blob/337fd144d2ba144743368f78d9579a99cce175bd/packages/core/src/file-mutation.ts).

The lock protects cooperating OpenCode mutations; it is not an atomic filesystem compare-and-swap against arbitrary external writers. The service directly calls the filesystem write operation after comparison, and its TODOs explicitly leave crash recovery/idempotency and multi-file transaction design for later. This is not equivalent to OnePage's existing recovery promises. [Mutation implementation and deferred work](https://github.com/anomalyco/opencode/blob/337fd144d2ba144743368f78d9579a99cce175bd/packages/core/src/file-mutation.ts).

Upstream tests cover exact rejection cases, replace-all, BOM/CRLF and an injected intervening file change. They were inspected, not executed here. [Tests](https://github.com/anomalyco/opencode/blob/337fd144d2ba144743368f78d9579a99cce175bd/packages/core/test/tool-edit.test.ts#L293-L411).

## Codex CLI

Inspected official `openai/codex` main commit [`ac192cd7937b0d73edc6dffe009940ae53782dd4`](https://github.com/openai/codex/tree/ac192cd7937b0d73edc6dffe009940ae53782dd4). This is a development snapshot, not a claim about the installed Codex build.

### Semantics

Codex's native Rust `codex-rs/apply-patch` crate implements its own patch language and application algorithm. Its format has `Begin Patch`, add/delete/update-file sections, optional move targets, context markers and line-based changes. It does not need to invoke Git to perform the patch application; filesystem access goes through `ExecutorFileSystem`. This does not imply that Codex never uses Git for other features or never uses a helper process. [Grammar/parser](https://github.com/openai/codex/blob/ac192cd7937b0d73edc6dffe009940ae53782dd4/codex-rs/apply-patch/src/parser.rs), [application loop](https://github.com/openai/codex/blob/ac192cd7937b0d73edc6dffe009940ae53782dd4/codex-rs/apply-patch/src/lib.rs#L470-L719).

The matching algorithm searches forward through source lines, first exactly, then ignoring trailing whitespace, then ignoring leading and trailing whitespace, then normalizing selected Unicode punctuation/spaces. It returns the first acceptable sequence at the current search position; it does not reject a patch merely because equivalent matches occur elsewhere. Context and end-of-file markers help position a hunk, and successful chunks advance the search position. Therefore this is a more permissive line-patch contract than exact unique old-text replacement. [Search](https://github.com/openai/codex/blob/ac192cd7937b0d73edc6dffe009940ae53782dd4/codex-rs/apply-patch/src/seek_sequence.rs#L1-L131), [chunk placement](https://github.com/openai/codex/blob/ac192cd7937b0d73edc6dffe009940ae53782dd4/codex-rs/apply-patch/src/file_update.rs#L84-L218).

Two newline modes exist. `NormalizeToLf` is the enum default; `PreserveLineEndings` retains source-line terminators and uses the first existing terminator style for inserted lines. The CLI tool selects the preservation mode through a feature flag. Both reconstruction paths preserve historical behavior of adding a final newline. No separate BOM-strip/restore logic appears in this crate's file-update path: the BOM remains part of the first line's text. [Mode selection](https://github.com/openai/codex/blob/ac192cd7937b0d73edc6dffe009940ae53782dd4/codex-rs/core/src/tools/handlers/apply_patch.rs#L63-L73), [mode definition](https://github.com/openai/codex/blob/ac192cd7937b0d73edc6dffe009940ae53782dd4/codex-rs/apply-patch/src/lib.rs#L62-L95), [line representation](https://github.com/openai/codex/blob/ac192cd7937b0d73edc6dffe009940ae53782dd4/codex-rs/apply-patch/src/text_file.rs).

### Memory and mutation

Rust does not make this particular algorithm constant-memory. The update path reads the complete file as a `String`. The legacy mode copies every source line into `Vec<String>`; the preservation mode constructs owned `SourceLine` strings and clones their text into another `Vec<String>` for matching. It builds replacement line lists and the final full string. Preview generation uses `similar::TextDiff::from_lines` and returns original content, resulting content and unified diff together. This is explicit file-size and line-count-dependent storage: the short-line test scenario remains relevant to this representation too. No exact RSS estimate or benchmark of Codex is claimed. [Content derivation](https://github.com/openai/codex/blob/ac192cd7937b0d73edc6dffe009940ae53782dd4/codex-rs/apply-patch/src/file_update.rs#L19-L81), [line cloning](https://github.com/openai/codex/blob/ac192cd7937b0d73edc6dffe009940ae53782dd4/codex-rs/apply-patch/src/text_file.rs), [diff generation](https://github.com/openai/codex/blob/ac192cd7937b0d73edc6dffe009940ae53782dd4/codex-rs/apply-patch/src/file_update.rs#L248-L346).

The crate applies files sequentially. Ordinary updates pass a cloned complete output byte vector to `write_file`; moves write the destination and then remove the source. An accumulated result records prior/new content and changes that happened before failure. The implementation explicitly marks that result as inexact when a write fails, because a failed write may already have truncated or changed the target. This is useful partial-effect reporting, not an atomic multi-file transaction or evidence of OnePage's durable prepared-content recovery contract. The inspected application loop contains no locked expected-content comparison before its write. [Application and partial-failure accounting](https://github.com/openai/codex/blob/ac192cd7937b0d73edc6dffe009940ae53782dd4/codex-rs/apply-patch/src/lib.rs#L470-L719).

`StreamingPatchParser` is used by the tool handler to emit progress while patch arguments arrive. Its presence should not be confused with a bounded streaming rewrite of the target file: actual file updates still use the complete-file machinery above. [Progress consumer](https://github.com/openai/codex/blob/ac192cd7937b0d73edc6dffe009940ae53782dd4/codex-rs/core/src/tools/handlers/apply_patch.rs#L88-L155).

Codex therefore supplies an additional option: a native custom patch engine can remove Git while retaining a line-patch interface. Reimplementing its permissive matching and line-based representation would add more algorithmic surface than exact replacement and would not, as written, remove line-count memory amplification. That is a design inference from the inspected source, not a benchmark result.

## Implications for OnePage

These are design inferences, not accepted amendments:

1. An exact, unique old-text/new-text contract is credible prior art and removes the need for a Git helper for that operation. GitHub is unrelated: the current helper under discussion is the local Git executable.
2. Prefer explicit failure on absent/ambiguous text initially. Pi's fuzzy machinery brings normalization choices and additional content/line-dependent allocations; OpenCode V2 itself defers that complexity.
3. Keep OnePage's prepared-content hash checks, charged temporary output and recovery/commit boundary. Replacing the preparation algorithm does not justify weakening these guarantees or copying a direct overwrite.
4. To obtain predictable memory, examine a native scan-and-copy implementation with bounded I/O buffers, literal replacement bytes and no full-file line index. Search/replacement inputs and any matching workspace must still be explicitly bounded or streamed; removing Git alone proves nothing about those costs.
5. Do not automatically generate an unrestricted whole-file diff on the critical edit path. Existing replacement spans can describe the change; richer display output needs its own bounded design.
6. This changes the model-visible editing contract if it replaces unified patches. Decide that product tradeoff explicitly; it is not merely swapping a library behind unchanged semantics.

No new Patch concurrency default is established by this note, and no claim is made that Pi, OpenCode or Codex themselves use less than 12 MiB per edit.
