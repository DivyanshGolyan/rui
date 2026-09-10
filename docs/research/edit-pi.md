# Pi edit-tool prior art

This note records the edit implementations in `badlogic/pi-mono` at commit
[`9767ba275f3e9a5ee0f5c5342249b629ab1b2282`](https://github.com/badlogic/pi-mono/tree/9767ba275f3e9a5ee0f5c5342249b629ab1b2282).
The local checkout used for line references is `/tmp/pi-mono-research`.
The older extracts in `/tmp/onepage-edit-priors` agree with the pinned source.
This is comparison evidence, not a OnePage policy decision.

## Two implementations

Pi has two substantially parallel edit tools:

| Surface | Schema and execution | Relevant tests |
| --- | --- | --- |
| Coding agent | [`packages/coding-agent/src/core/tools/edit.ts`](https://github.com/badlogic/pi-mono/blob/9767ba275f3e9a5ee0f5c5342249b629ab1b2282/packages/coding-agent/src/core/tools/edit.ts) (`/tmp/pi-mono-research/packages/coding-agent/src/core/tools/edit.ts:21-41,143-220`) | [`packages/coding-agent/test/tools.test.ts`](https://github.com/badlogic/pi-mono/blob/9767ba275f3e9a5ee0f5c5342249b629ab1b2282/packages/coding-agent/test/tools.test.ts) (`:273-483`) |
| Agent harness | [`packages/agent/src/harness/tools/edit.ts`](https://github.com/badlogic/pi-mono/blob/9767ba275f3e9a5ee0f5c5342249b629ab1b2282/packages/agent/src/harness/tools/edit.ts) (`/tmp/pi-mono-research/packages/agent/src/harness/tools/edit.ts:17-145`) | [`packages/agent/test/harness/tools.test.ts`](https://github.com/badlogic/pi-mono/blob/9767ba275f3e9a5ee0f5c5342249b629ab1b2282/packages/agent/test/harness/tools.test.ts) (`:393-532`) |

Both are real implementations, not stubs. The harness version uses an injected `ExecutionEnv` for path, file-info, read, and write operations; the coding-agent version uses injected or default Node operations. Their edit and diff algorithms are duplicated with the same behavior. The harness has no separate range-write or patch-file implementation.

## Input and matching contract

The public input is one file path and a non-empty `edits` array. Every array item is `{ oldText, newText }`; there are no line numbers, byte offsets, explicit ranges, expected file digests, or postimages in the tool schema. The descriptions require each `oldText` to be unique and non-overlapping, and say that all entries match the original file rather than an incrementally modified file (`coding-agent/edit.ts:21-50`; `agent/edit.ts:17-37,90-101`).

One call can carry multiple disjoint replacements. This is the intended way to change several locations in one file; the coding-agent prompt explicitly says to use one call rather than several calls (`coding-agent/edit.ts:43-50`). The implementation resolves all matches first, sorts them by original offset, rejects overlaps, and only then constructs the result (`coding-agent/edit-diff.ts:300-361`; harness `edit-diff.ts:301-361`). Applying in reverse order keeps the original offsets stable (`coding-agent/edit-diff.ts:111-119`). A test proves a replacement that changes the text surrounding a second target does not retarget the second match (`coding-agent/test/tools.test.ts:375-388`).

Matching is exact first, but not exact-only. If exact `indexOf` fails, Pi normalizes Unicode compatibility forms, trailing line whitespace, smart quotes, several dashes, and special spaces, then searches the normalized content (`coding-agent/edit-diff.ts:27-55,201-245`). It counts normalized occurrences and rejects zero or more than one (`:247-273`). Thus the schema says “exact text” while execution accepts a unique fuzzy-normalized match. Empty `oldText`, missing text, duplicate text, identical output, and overlap all fail before the write (`:275-361`). The tests cover missing and duplicate targets, overlaps, and no partial application when one item is missing (`coding-agent/test/tools.test.ts:297-333,402-433`; harness `tools.test.ts:423-470`).

Pi normalizes CRLF/CR to LF for matching and applies, preserves a BOM, then restores the file's detected line-ending style (`coding-agent/edit.ts:185-198`; `coding-agent/edit-diff.ts:11-25`). The fuzzy path overlays changed line groups onto the original so unchanged line blocks retain their original bytes (`edit-diff.ts:122-173,352-355`). This is a byte-preservation detail for untouched lines, not a range-write mechanism.

## Preview, permission, and execution ordering

The coding-agent renderer has a pre-execution preview path. Once arguments are complete, `renderCall` asynchronously calls `computeEditsDiff`; that helper checks readability, reads the whole file, applies the same matching/validation algorithm, and generates a display diff without writing (`coding-agent/renderers/edit.ts:171-195`; `coding-agent/edit-diff.ts:510-543`). The TUI tests call this a preflight error and verify that an invalid edit produces no diff (`coding-agent/test/edit-tool-no-full-redraw.test.ts:201-220`). Therefore Pi can read the target before execution/approval UI presentation, but the preview is presentation code and is not an authorization record.

Neither edit tool contains a built-in permission decision or an approval object. The harness pipeline prepares and schema-validates arguments, applies an optional before-tool decision (which can block or replace arguments and revalidates replacements), and then invokes the edit tool (`agent/execution/tools.ts:77-122`). The coding-agent extension hook is likewise a generic `tool_call` hook that can block or mutate arguments (`coding-agent/agent-session.ts:478-506`; `coding-agent/extensions/types.ts:939-954`). Any permission policy therefore lives in the caller or extension; the edit implementation itself begins its mutation path with access/file checks and a full read (`coding-agent/edit.ts:159-194`; harness `edit.ts:102-124`).

The execution path does not save the edit as an independently durable patch before permission or mutation. It reads and validates the current file, builds the complete new string in memory, writes it, and only after the write returns generates the diff and unified patch included in the result (`coding-agent/edit.ts:185-211`; harness `edit.ts:116-139`).

## Write, serialization, and failure boundaries

The write operation receives the complete final string (`fsWriteFile(..., "utf-8")` in `coding-agent/edit.ts:83-96`; `env.writeFile(..., finalContent, ...)` in harness `edit.ts:126-129`). There is no line-range write, seek, temporary-file swap, fsync, or compare-and-swap in this path. Validation failures are all-before-write, which is why the no-partial test passes, but a failure or process loss during a full-file write has no tool-level atomicity or recovery claim.

Concurrent mutations to the same canonical file are serialized by an in-process queue; different files proceed in parallel. The coding-agent queue canonicalizes symlinks with `realpath` and holds the queue until the callback's in-flight operation settles (`coding-agent/file-mutation-queue.ts:16-60`). The harness keeps a queue per `ExecutionEnv` and canonical path (`agent/file-mutation-queue.ts:10-60`). Tests cover same-file edits, edit/write interaction, symlink aliases, and keeping the queue locked while an aborted write is still in flight (`coding-agent/test/file-mutation-queue.test.ts:37-99,101-273`; harness `tools.test.ts:473-532`). This is process-local serialization, not cross-process isolation or a durable lock.

Cancellation is checked before access, after access, after read, after matching, and after `writeFile` (`coding-agent/edit.ts:163-200`; harness checks `:108-129`). The coding-agent comment deliberately avoids an abort listener because it would release the queue while filesystem I/O might still finish (`:163-167`). If cancellation is observed after the write completed, the call can report `Operation aborted` even though the file changed; the source and tests do not turn that into an uncertainty record or recovery action. The tests only establish queue safety around an injected delayed write.

## Diff outputs and test scope

Successful execution returns a short text result plus two non-authoritative views: a display-oriented diff with the first changed line and a standard unified patch (`coding-agent/edit.ts:201-210`; harness `edit.ts:131-138`). Unified patches use four context lines (`coding-agent/edit-diff.ts:364-370`), while display diffs collapse large unchanged gaps; the test checks a 600-line file renders fewer than 50 lines (`coding-agent/test/tools.test.ts:352-373`). The patch is generated after mutation from the old and new strings; it is not the input representation and is not persisted by the edit tool.

Tests are strong on schema preparation, exact/fuzzy matching behavior, multiple disjoint entries, original-snapshot matching, overlap rejection, duplicate/missing targets, diff rendering, same-process queueing, and cancellation while a write is in flight. They do not test a process crash, restart reconciliation, partial bytes after a failed full-file write, durable intent, a permission decision bound to an immutable patch, or an external writer between read and write. Those absences limit what can be claimed from this prior art.

## Relevance to explicit-range patches

The closest useful comparison is the all-checks-before-write structure inside one tool call: all replacement targets are resolved against one read snapshot, all uniqueness and overlap checks finish, and only then is one full-file write attempted. Its useful properties are deterministic multi-edit behavior and no validation-induced partial application. Its limits are equally clear for a crash-resumable runtime: the input has no explicit coordinates or preimage identity, fuzzy matching can accept a normalized equivalent, the complete output is held as a string, and the mutation has no durable pre-write record or post-write reconciliation. The preview read is a separate UI convenience rather than proof that permission was based on a saved patch.
