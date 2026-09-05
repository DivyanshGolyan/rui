# Local Claude Code workflows against the proposed OnePage interface

> **Research record, published 6 September 2026.** Findings and proposals below reflect the dated investigation. Subsequent decisions are owned by [ARCHITECTURE.md](../../ARCHITECTURE.md) and [PRODUCT.md](../../PRODUCT.md); historical recommendations and implementation-ticket references do not override them.

Checked 5 September 2026. This is a read-only audit of saved scripts and execution evidence, not a workflow execution or acceptance of a new API. The candidate under review is [Session IDs and ordinary functions](../design/workflow-interface-round2/b-data-functions.md), with separate creation already accepted.

## Conclusion

The proposed creation/message interface can express the observed orchestration patterns. The evidence supports ordinary IDs, functions, and Promises. It does not establish that the current implementation can run all these workloads unchanged: existing output limits, excluded MCP tools, and different failure semantics are concrete compatibility concerns. The existing numeric limits are not approved final V1 requirements; their retention is an open decision. Per-worker configuration and useful progress inspection must also survive the simplified surface.

The dominant observed use is independent workers exchanging selected result data, often with a fresh adversarial reviewer. There is no script-level continuation of a worker Session in this corpus. Reusable Sessions remain useful for OnePage's broader promise, but are not needed to reproduce these scripts. Do not translate every stage into messages to one shared Session: that changes both reviewer context and the possibility of independent results.

## Evidence and coverage

Found 22 saved `.js` scripts under `~/.claude/projects/*/**/workflows/scripts/`: 19 task scripts and three probes (`ping-pong`, `memprobe`, `memprobe-heavy`). Twenty-one have adjacent saved Run metadata and journals: 20 metadata statuses are `completed`, one is `killed`. The stateless comment-audit script lacks adjacent Run metadata in the scanned location. Status alone is not successful work: one `completed` planning Run has a null final result. Journal counts may span multiple launches and must not be treated as counts of simultaneous workers or distinct tasks.

All scripts were inspected for orchestration calls, options, and result processing. Detailed source review covered independent audits, per-item pipelines, nested fan-out, report aggregation, parallel edits, and external sheet writes. `cclog` confirmed Workflow launches, two explicit resumes of the removal-guard scan, and actual tool use in one dossier worker. No Claude executable, saved workflow, provider, Slack API, or Google Sheet mutation was run by this audit.

The [inventory](local-claude-workflow-inventory.json) uses neutral workflow labels and retains Run status, record counts, calculated output sizes, and source hashes. Machine paths, source filenames, and local Run IDs are omitted from the published inventory; prompts, answers, and business records are not copied. Original locators remain only in the maintainer’s private archive. The sampled source files may change independently of this note.

## Observed use cases

### Independent discovery, verification, and synthesis

`unnecessary-complexity-audit` launches eight region finders, deterministically deduplicates and ranks candidates, caps verification at 20, invokes independent skeptics, then runs a ranking and completeness pass. Its journal has 30 started and 30 result records. Script lines 129–195 contain the dynamic fan-out and filtering; lines 242–275 contain final synthesis.

`split-1389` maps a 106-commit branch through mapping, seam analysis, alternative proposals, judgment, and critique. Its final saved Run reports 20 agents. The stages are ordinary arrays, schema results, and Promise dependencies; no workflow-specific command description language is needed.

**Fit:** create a fresh Session for each independent role/item, then send one message. Carry selected answer data to the next fresh Session. Reuse a Session only when deliberately continuing its conversation. This preserves the requested independent verification without a runtime ownership or isolation mechanism.

### Per-item pipelines and nested dynamic fan-out

`writing-for-agents-review-agent-dir`, lines 137–187, reviews each group then conditionally verifies its findings. Six scripts use `pipeline`. `scan-removal-guard-tests`, lines 61–99, goes further: each scanner's result determines a new collection of verifier calls. Its parent transcript records an initial Workflow launch and two `resumeFromRunId` launches on 9 August 2026.

**Fit:** ordinary async functions and `Promise.all` express those dependencies. Use keys derived from a stable group/shard identity and an index within that recorded result, rather than physical completion order. One old display label uses only a file basename and line; display labels must not automatically become unique replay keys.

The interface can express a pipeline without a native `pipeline()` primitive. Matching its latency is a separate scheduler question: replay visibility must preserve deterministic behavior, and an implementation that waits for every sibling before exposing a fast result delays that result's dependent verifier. This audit does not claim the current Host implements either release strategy or that equivalent JavaScript proves equivalent scheduling.

### Parallel edits in a shared worktree

`clear-no-runtime-typeof`, lines 42–44 and 70–84, allocates disjoint file lists to ten workers in the same worktree, passes per-slice effort, and instructs them to report out-of-scope changes instead of editing another slice. Other stages classify sites and independently verify the resulting changes.

**Fit:** fresh Sessions can use the same Workspace. Separate Sessions provide distinct conversations, not filesystem isolation. File assignment remains workflow input and instructions, consistent with the accepted trusted-client model. Preserve explicit baseline/model/effort/tool/permission configuration using the existing owning contracts; the minimal two-function sketch must not accidentally remove those capabilities.

### Large fan-out with partial results and external writes

The two sheet-dossier scripts each have 61 started and 61 result journal records. Workers read a finding and its transcript, read a Slack thread, write their assigned sheet row, and return compact structured status. The Sonnet version explicitly separates successful results, missing results, blocked evidence, and write failures at lines 171–194. Prompts assign unique temporary filenames and disjoint row ranges; runtime Session ownership is not the coordination mechanism.

**Fit for orchestration:** one fresh Session per finding, then collect fulfilled and rejected results while preserving each finding ID. Use `Promise.allSettled()` when the workflow should keep successful branches. Claude scripts commonly use nullable results and `filter(Boolean)`; OnePage's frozen rejected Promises require a deliberate translation. `Promise.all` rejects on a rejection and does not by itself cancel sibling work.

The user's follow-up confirms that failure should be expected, not prevented through extra machinery. A failed message rejects; ordinary `try/catch`, `Promise.all`, or `Promise.allSettled` expresses the caller's desired behavior. Preserve the recorded outcome on replay and require an explicit new submission for a deliberate retry. No automatic semantic retry, custom partial-success framework, or guarantee that a model answer is substantively correct follows from this audit. Existing transport/effect recovery remains its own contract.

**End-to-end gap:** the sampled Sonnet worker actually used `mcp__drift__get_finding`, `mcp__drift__list_messages`, Slack search/read tools, Bash, and StructuredOutput, with no recorded tool error in that sample. These were not merely unused prompt suggestions. OnePage [V1 excludes MCP execution](../../PRODUCT.md) and currently specifies Bash and Patch. The same source access therefore needs an explicitly available CLI/tool route or a separate scope decision. Session syntax cannot supply it.

The script's `gog sheets batch-update` writes can be expressed through Bash when the CLI and credentials are available. Existing uncertain-Bash recovery deliberately does not redispatch automatically. A crash after a remote write needs verification/reconciliation; keyed workflow replay alone does not make arbitrary external writes exactly once.

## A representative translation

This sketch illustrates the proposed shape, not executable OnePage code or finalized configuration names. `FINDINGS` and `VERDICT` are the caller's supported output schemas. Baseline/provider configuration is omitted here, not removed.

```js
export default async function workflow({ createSession, sendMessage }, args) {
  const groups = await Promise.allSettled(args.groups.map(async (group) => {
    const finder = await createSession({ key: `find-session:${group.id}` });
    const found = await sendMessage(finder, group.prompt, {
      key: `find:${group.id}`, schema: FINDINGS,
    });

    const verdicts = await Promise.allSettled(found.findings.map(async (f, i) => {
      const key = `verify:${group.id}:${i}`;
      const verifier = await createSession({ key: `${key}:session` });
      return await sendMessage(verifier, `Try to refute:\n${JSON.stringify(f)}`, {
        key, schema: VERDICT,
      });
    }));

    return { groupId: group.id, found, verdicts };
  }));

  // Produce a bounded plain-data report. Rejection reasons must be mapped
  // to supported error fields, not returned as raw JavaScript Error objects.
  return summarize(groups, args.groups);
}
```

Creation adds one explicit durable operation per fresh worker but no model request. A local helper can package creation plus first message when a script repeats the pattern; that does not require adding a third runtime capability or reversing separate creation. This corpus gives little reason to prefer Session wrappers or operation descriptors over IDs.

## Resource limits exposed by actual results

Current [protocol limits](../../src/workflow_protocol.zig) include 64 KiB final workflow output, 512 KiB aggregate visible output, 4,096 entries per encoded value, and 256 request slots. The [evaluator](../../src/workflow_evaluator.zig) checks final encoded output size and counts all requests encountered in an evaluation, including replayed requests; `pending_jobs` is not merely a count of currently running workers.

**Decision status correction:** these are implemented constants and are described in the [QuickJS dependency research note](quickjs-ng-dependency-selection.md), not settled final V1 policy. [Choose Workflow Evaluator containment limits](https://github.com/DivyanshGolyan/onepage/issues/90) explicitly owns whether source, result, frame, visibility, heap, and other evaluator limits protect independent boundaries. [Wayfind the minimal V1 limit model](https://github.com/DivyanshGolyan/onepage/issues/85) places the burden of proof on retention and leaves exact values unfrozen. [Approve the minimal V1 limit matrix and removal sequence](https://github.com/DivyanshGolyan/onepage/issues/89) is the later integration gate. This audit must not promote the 64 KiB constant into a product promise or require callers to shrink their reports to preserve it.

Six saved final results exceed the 64 KiB limit when calculated using the current tagged-value representation:

- `unnecessary-complexity-audit`: 86,653 bytes.
- `split-1389`: 727,714 bytes; 4,769 entries.
- `spec-1222-recon`: 296,544 bytes.
- `writing-for-agents-review-agent-dir`: 107,059 bytes.
- `clear-no-runtime-typeof`: 93,002 bytes.
- `comment-discipline-audit`: 465,325 bytes; 5,120 entries.

The entry counts for `split-1389` and `comment-discipline-audit` also exceed 4,096, independently of byte size. The split workflow records about 728 kB of encoded agent-result values across its journal; that is a warning for replay materialization, not a claim that all journal records must be simultaneously visible in every generation.

These are static encoding calculations from saved values, not measured heap usage or an executed port. Counts use one byte for tags, four-byte string/container lengths, eight-byte numbers, UTF-8 strings, and recursive member counts, matching the current protocol. They exclude framing and in-memory object overhead. Saved values below these limits are not thereby certified to pass every other bound.

Sixty-one independent first-message workers imply 61 creation operations plus 61 message operations in the proposed API. That illustrates the extra replay records; it does not prove an implementation with the current single-operation bridge can admit the revised API. Active Capacity must separately bound actual external work. No need for 61 permanently resident Sessions follows from the script.

Do not raise every limit or introduce automatic result references solely from these observations. The existing evaluator-limit ticket should first establish whether a separate result-byte cap protects anything not already protected by evaluator memory and bounded serialization/transfer. Delete or derive it if redundant; retain a separate boundary only with a concrete owner and failure scenario. Any restriction on full-report shapes needs justification. Disk-first history does not remove the cost of materializing JavaScript values, but bounded transfer need not impose a small total durable-output quota.

## Inspection and unsupported features

Nineteen scripts use schemas and phase calls, and 17 use logs, including the two memory probes. Progress labels such as `find:...`, `verify:...`, and per-item outcomes have concrete value at this scale. Stable operation keys plus existing Run inspection may cover basic monitoring; phase announcements and arbitrary intermediate summary logs are not yet supplied by the two-function candidate. Define the required inspection information before adding a new durable logging primitive. Missing model/effort options in a short example likewise are not evidence those existing capabilities should be removed.

No script-level Session continuation, Session-history lookup, `Promise.race`/`Promise.any`, child-workflow invocation, explicit isolation option, or actual token-budget API use was found in these saved scripts. A text match for `budget.` was a filename, not an API call. This is evidence about this corpus, not a universal claim about Claude workflows or future OnePage callers.

## Recommendation

Keep plain IDs and separate creation as a strong candidate. Preserve fresh-worker examples alongside conversation-continuation examples. The next valuable validation is a small port of the scan/verify pattern with explicit branch failures, plus a representative large-report case against chosen bounds. Separately identify the supported source-access route for the dossier workflow. This audit provides no reason to adopt a descriptor executor, add Session handles, or broaden V1 with all of Claude's helpers.

The original audit changed no canonical design, GitHub issue, production source, or local Claude artifact. In the user's follow-up, the limit status was clarified here, [workload evidence was attached to the existing evaluator-limit ticket](https://github.com/DivyanshGolyan/onepage/issues/90#issuecomment-5551176153), and [Evaluate the architecture needed for post-V1 MCP support](https://github.com/DivyanshGolyan/onepage/issues/109) was created as a native child of the architecture-audit map. That ticket investigates any changes needed now without adding MCP implementation to V1. No limit was selected or removed, and no MCP design was resolved.

Existing normative documents contain older Session/Turn clauses; this assessment uses the accepted amendments summarized in the [comparison brief](../design/workflow-interface-round2/requirements.md) for those decisions and current source for implementation limits.
