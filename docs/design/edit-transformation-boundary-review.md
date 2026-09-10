# Edit transformation and target writing

Reviewed 2026-09-10 against the supplied *Boundaries* talk. Design review and proposed private interface clarification; no new accepted contract or production changes.

## Recommendation

Keep one Edit module and one live invocation owning the opened target, output scratch, bounded buffers, offsets and cleanup. Inside it, separate checking/building the edited output from writing the target. The first part receives read access to source/proposal content and write access only to output scratch. The second uses the existing opened target after complete preparation succeeds.

```text
Authorized invocation owns target + scratch
  |
  +-- check/build: source bytes + approved replacements -> output scratch
  |
  +-- only after complete success: copy back -> set length -> flush
  |
  +-- return observed execution result to Session core
```

This clarifies the [accepted physical mechanism](edit-file-writing-proposal.md) and [whole-line proposal contract](fixed-location-edit-approval.md). It introduces no public prepare/apply protocol, saved preparation stage, replacement-file publication or new worker. Existing bounded service turns remain; do not add a generic streaming state machine solely to imitate the talk.

## What can be isolated

The text transformation needs source bytes, ranges, expected text and replacement text. It does not need permission policy, Session state, SQLite, Git, pathname resolution or target-write access. It should check and construct output through a small private interface that can also consume fixed test data.

In production, source reading and scratch writing remain I/O. This function is therefore not literally pure just because it has explicit inputs. Its useful property is narrower: it cannot modify the target, and its text behavior is determined by the bytes and proposal supplied. Small pure helpers may handle calculations, comparisons or range rules where they simplify the implementation; every chunk need not become a new immutable object.

The surrounding Edit invocation opens the existing target only after authorization and Attempt admission, establishes applicable file/handle checks, creates charged unlinked scratch, and owns both through completion or cleanup. Existing caller coordination remains necessary for concurrent filesystem writers; a read interface does not freeze a live file or establish atomic compare-and-swap.

## Concrete two-range example

Source: `alpha\nbeta\ngamma\ndelta\n`.

| Original range | Expected | Replacement |
| --- | --- | --- |
| `[2,3)` | `beta\n` | `BETA\nextra\n` |
| `[4,5)` | `delta\n` | `DELTA\n` |

The builder can write `alpha\nBETA\nextra\n` to scratch before it reaches the second range. If the second expected slice mismatches, it discards that partial output and reports failure before target mutation. Scratch writes are permitted before complete validation; target writes are not.

On complete success, scratch contains `alpha\nBETA\nextra\ngamma\nDELTA\n`. The second range uses original coordinates despite the first replacement's growth. The source/proposal traversal and exact encoding remain private implementation work under the existing bounded-content contract.

## What must cross the private handoff

Preparation success establishes that all ranges, expected bytes, EOF rules and complete output construction passed. Merely having a scratch descriptor or some output bytes cannot establish success. The invocation retains the correct source/proposal binding, final output length and ownership of complete scratch until copy-back finishes or fails.

An ordinary private return value or scoped result can express this. It need not be a new publicly constructible `PreparedEdit` type. Do not return slices into a buffer that will be reused before consumption, reopen the pathname to find a possibly different target, or let the builder independently close resources still needed for writing.

No entire file, line, replacement or edit list needs to be resident. Use the accepted bounded windows and charged content/metadata traversal. A descriptor is a temporary capability with a lifetime, not a self-contained immutable value or a durable recovery reference. The complete output's temporary disk cost remains proportional to output size; this interface does not remove it.

## The first target mutation matters

Before any target mutation, mismatch, source-read failure, scratch exhaustion or cancellation can finish with an established not-applied result after cleanup. Building output successfully is still not an applied result.

For nonempty output, copy-back writes can begin changing the target. For an empty output, truncation is the mutation even though no copy-loop iteration runs. A write, length or flush failure must preserve whether unchanged content was actually established; a generic error cannot be translated automatically into not applied.

Once mutation begins, retain custody through the accepted safe execution/cleanup policy. Cancellation is not rollback. The Edit invocation reports its observed result; the Session core owns its durable publication. Process loss before publication remains indeterminate under [unified tool recovery](unified-tool-recovery.md), including when writing and flushing may have completed. Scratch is discarded and cannot authorize replay or repair.

No new durable phase, completion receipt or per-write log is needed for this distinction. Live bookkeeping supports accurate reporting while the invocation exists; the accepted conservative recovery rule covers its loss.

## Test division

| Test surface | Cases and independent expectations |
| --- | --- |
| Text transformation with fixed sources | Mixed growth/shrinkage; original coordinates; late mismatch; overlapping ranges; adjacent ranges; insertion boundaries; LF/CRLF; missing final newline; empty source and output. Compare complete output against manually specified byte expectations. |
| Same transformation with varied chunk boundaries | Split LF/CRLF, expected text and replacements at different byte positions; long single lines and replacements. Chunking must not change applicability or output. Include file-backed large cases for memory evidence. |
| Actual Edit invocation | Target opening/eligibility; same-handle copy-back; scratch limits; short and failed writes; final-length and flush failures; cancellation before/after first mutation, including empty-output truncation; safe cleanup. |
| Core and Edit integration | Authorization precedes execution; late preparation failure cannot publish success; result publication failure and fresh-process recovery never replay the tool; final meaning and required content belong to the Operation under the accepted execution model. |

Use the real transformation in both fixed-source and filesystem tests. A second production algorithm made only for tests would undermine the isolation benefit. Avoid a mock sequence spelling out every read/write; assert resulting bytes, target-mutation exclusions, reported evidence and resource release. No tests were implemented or run by this review.

## Limits and source evidence

The historical `src/patch_tool.zig` at `d76c7350a3661da48e9d107258e3dd699f9b0aa7` combines Git-backed preparation, whole-file digests and optional copy-back in `prepareSnapshot`; it truncates before copying ([source](../../src/patch_tool.zig)). Those are historical mechanics, not the accepted whole-line/no-replay design. Its old tests cannot establish the proposed interface or current guarantees.

The useful change is an explicit private restriction on target access and preparation lifetime. The accepted behavior and physical mechanism already support it. Fixed-sized reads/writes do not prove bounded filesystem latency; integrated control-latency checks remain necessary. This review supplies no reason to add a worker, process, generic transformation framework or public prepared-edit API.
