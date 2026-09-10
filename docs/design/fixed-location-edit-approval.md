# Fixed-location Edit approval

Accepted in architecture discussion on 2026-09-08; extended to multiple whole-line ranges, proposal-only preview and Bash-based reading on 2026-09-09. Design amendment only; no implementation or runtime evidence is claimed.

## Decision

Edit operates only on an existing file. A missing target fails without creation. The model uses Bash for file and directory creation through ordinary Bash permissions and the shared uncertain-outcome/no-replay rule. No Edit creation operation or separate Write tool is introduced. An existing empty file remains editable with `[1,1)`.

Approve one exact target path and a nonempty list of replacements, each containing a whole-line range, expected text and replacement text. All ranges refer to the same pre-edit file state. Reject overlaps; combine insertions at the same position. Different files use separate calls. After authorization, check every range and expected text before any target mutation. If any entry fails, reject the whole call without changes. Preserve unrelated current content. Do not relocate the edit or search for an alternative match. Additional matches elsewhere do not invalidate a location already approved.

Save and display the submitted proposal without requiring a target read. Validate its shape before admission; check target eligibility and applicability during authorized execution. The preview shows submitted before/after snippets at declared positions, not verified current content or independently obtained surrounding context. This adds no separate durable preparation stage.

If an approved range is absent or its text differs, fail before mutation. The model may inspect the file, propose a fresh edit and request permission again. Harmless shifts may fail deliberately; avoiding that failure does not justify relocation machinery.

Approval concerns the path and fixed coordinates rather than whole-file freshness or historical file-object identity. A matching range proves current applicability, not continuity of the original occurrence. Ordinary file eligibility and safe handle use still apply. How a proposed edit initially selects its range remains separate from revalidating an approved range; this decision does not add an ambiguous global-match selection policy.

## Range rules

Ranges include the start line and exclude the end line: `[4,7)` selects lines 4–6. `[4,4)` inserts before line 4 and requires empty expected text. Empty replacement text deletes the selected range. Lines are separated by LF; a preceding CR remains part of the CRLF terminator, and a final nonempty unterminated segment is a line. An empty file has zero lines; a trailing LF does not add a phantom line. For N lines, position N+1 denotes end of file; `[N+1,N+1)` appends, including `[1,1)` for an empty file. Require `1 <= start <= end <= N+1`. Expected text includes the selected lines' actual terminators. Replacement text is written exactly as supplied, with no newline normalization or implicit final newline. Appending to an unterminated last line therefore joins that line unless the replacement explicitly begins with a newline.

Adjacent nonempty ranges are allowed. An insertion inside or at the boundary of another replacement must be combined with that replacement, avoiding an ordering choice at the same position. Multiple insertions at the same position must likewise be combined.

## Reading convention

Use Bash for file reads; no dedicated Read tool is required. `cat -n -- file` numbers every line, including blank lines, starting at 1. To select a portion while retaining original line numbers, number first: `cat -n -- file | sed -n '40,80p'`. These numbers are presentation labels, not part of the expected file text.

Bash output can be truncated or transformed. It is not an authoritative snapshot or a required prior observation. Execution checks exact expected text at the submitted lines, rejecting incorrect or stale coordinates before mutation. Changing part of a line means supplying the complete affected line with the intended change; another change on that same line can therefore invalidate the proposal. A dedicated Read tool can be reconsidered for a concrete need such as consistent pagination, but is not part of this decision.

## Durable facts and module responsibility

Edit Intent retains the approved path and complete list of ranges and before/after text with existing Workspace and authorization provenance. Whole-file before/after copies are not required solely for approval or recovery. Temporary execution storage remains bounded and owned. Lines are numbered from 1, with no columns. Display and execution use the range rules below.

The Edit module hides file traversal, checks and mutation mechanics. It reports completed execution, rejection before mutation, or failure/uncertainty that may include changes. It cannot promise successful execution or silently repair the workspace to make the edit applicable. The decision owner saves the result; the model chooses subsequent investigation or a fresh proposal.

Concurrent writes during execution are a caller-coordination responsibility. Fixed-location approval is not an isolation or atomic compare-and-swap guarantee and adds no concurrent-writer coordination. Preservation of unrelated content concerns the state used for execution, not changes made by overlapping writers. The [shared tool recovery rule](unified-tool-recovery.md) continues to prohibit automatic replay of uncertain effects.

## Minimal execution contract

Save the approved patch and authorization; the Operation owns current Attempt admission and its final Resolution. Execute it and save an honest result. Report applied when completion is established, not applied when no mutation is established, and otherwise failure with available evidence or an indeterminate outcome. A write error alone does not establish that no bytes changed. If execution completed but its result was lost before publication, restart does not replay it.

The saved patch is the path, positions, expected text and replacement text; it is not a whole-file snapshot. Variable-length replacements and partial I/O still require correct implementation and bounded temporary resources. Those mechanics do not add durable recovery images, relocation, repair or coordination stages.

## Physical execution

The [accepted writing mechanism](edit-file-writing-proposal.md) builds and validates the complete edited output in charged unlinked scratch, then copies it through the same opened target handle, sets final length after copying and flushes. It preserves file-object identity without promising atomic writes. The scratch is temporary execution state, not a durable backup or replay source.

## Owning contracts

See [architecture](../architecture/execution.md#native-edit-module), [domain language](../../CONTEXT.md), [product guarantees](../../PRODUCT.md#product-guarantees), and [verification](../../VERIFICATION.md). This amends ADR-0003's whole-file approval binding while preserving its absence of Workspace isolation. Historical research and unselected architecture candidates remain evidence, not current requirements.

## Worked execution example

Given the exact file `alpha\nbeta\ngamma\ndelta\n`, one proposal contains:

| Range | Expected | Replacement |
| --- | --- | --- |
| `[2,3)` | `beta\n` | `BETA\nextra\n` |
| `[4,5)` | `delta\n` | `DELTA\n` |

Save the entire proposal and display it for permission without reading the target. After authorization, execution reads the target and validates both entries against the original file. It then produces `alpha\nBETA\nextra\ngamma\nDELTA\n`: the second entry still selects original line 4 even though the first replacement adds a line. Save the honest execution result.

If original line 4 now contains `changed\n`, the second check fails and neither replacement is applied. If an I/O failure happens after mutation begins, the all-checks-before-mutation rule does not imply that the file is unchanged. A lost outcome after mutation follows the existing indeterminate/no-replay policy.

For an empty file, `[1,1)` with empty expected text can insert `hello`. The result has no final newline. Appending `world\n` at `[2,2)` then produces `helloworld\n`; appending `\nworld\n` instead produces two lines. Newline bytes are explicit proposal content, including CRLF where intended.
