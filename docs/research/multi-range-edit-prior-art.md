# Multiple replacements in one Edit call

Research date: 2026-09-09. The recommendation was accepted on 2026-09-09 and is recorded in [the owning decision](../design/fixed-location-edit-approval.md). This research remains source evidence, not production implementation. Four separate Luna investigations inspect pinned source and tests. “Py” is interpreted as Pi (`badlogic/pi-mono`). Per-harness notes record revisions, source links, and evidence limits.

## Question and recommendation

A model often needs to change an import, a function signature, and a call site in the same file. Requiring three separate Edit calls introduces avoidable model/tool round trips and makes subsequent coordinates depend on the earlier results. Recommend one file path with a nonempty list of fixed-range replacements, retaining the existing expected-text check and permission lifecycle.

All ranges refer to the same file state before this call applies any replacement. They do not refer to successively modified content. Reject overlapping ranges rather than inventing edit ordering. Two insertions at the same position should be combined into one entry; exact coordinate and insertion-boundary conventions must be specified before implementation.

This adds a list and a collective validation rule, not another durable workflow stage. Save and display the submitted proposal, obtain approval, then read the target and check every range and expected text before mutating it. If any check fails, reject the whole call without changing the target. A preview made without reading the file shows the proposed before/after snippets at the declared positions; it cannot claim those snippets match the current file or include independently verified surrounding context.

Multiple files remain a separate question. Recommend separate calls initially: the benefit of same-file batching does not require a multi-file transaction, rollback, or recovery mechanism.

## Implementation comparisons

| Harness | Multiple changes in one call | Relevant behavior |
| --- | --- | --- |
| [Pi](edit-pi.md) | One path plus `edits[]` | Resolves every old-text match against original content; rejects missing, ambiguous, or overlapping targets before one full-file write. Matching has fuzzy fallbacks. |
| [OpenCode v2](edit-opencode-v2.md) | `edit` takes one replacement; `patch` accepts multiple hunks/files | Prepares file contents and previews before approval, then writes sequentially. Tests demonstrate partial application after a later write fails. |
| [DeepSeek Harness](edit-deepseek.md) | One search/replacement, optionally replace every occurrence | No list of distinct edits. Proposal presenter uses submitted text; execution uses an optional observed-version guard and staged one-file publication. |
| [Codex CLI](edit-codex.md) | One textual patch containing multiple chunks/files | Preflights reads and diffs before approval; rereads and applies the raw patch during execution. Later runtime failures can leave earlier changes applied. |

## What transfers to OnePage

Pi is the closest precedent for the input shape and original-state semantics. OnePage need not copy its fuzzy matching or whole-file in-memory representation. Fixed coordinates remove search and uniqueness resolution; expected text still detects a stale or mistaken proposal. Bounded scratch can hold a prepared result without retaining the whole file in memory. That is a private execution detail, not a durable approval preimage or recovery artifact.

DeepSeek provides a useful precedent for rendering a proposal from submitted text. OpenCode demonstrates why a pre-approval read alone is insufficient: its tests intentionally allow a prepared replacement to overwrite content changed after matching. OnePage's chosen execution-time target checks remain necessary regardless of preview preparation.

“All checks before writing” guarantees that a bad range does not cause partial application. It does not guarantee that an I/O failure, cancellation, or crash leaves the target unchanged. Preserve the agreed honest outcome reporting and no automatic replay of an uncertain tool action. A batch changes how many replacements belong to one attempt; it does not settle the physical file-publication strategy or provide external-writer isolation.

The model should not have to recalculate later coordinates after earlier replacements. For example, inserting two lines near the top and replacing original line 80 in the same call still targets original line 80. Execution can translate those original positions internally. If the model needs a second edit to depend on the first edit's result, it should submit a later call after seeing that result.

## Evidence limits

The investigations read actual implementations and tests, rather than relying on tool descriptions alone. They did not run the harness test suites. The reports distinguish validation-before-write, process-local serialization, staged one-file publication, and durable recovery; these are different guarantees. None of these comparisons establishes production evidence for OnePage.
