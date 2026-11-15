# Subsystem documentation move

This records an organization-only change from `94d1881a`. It is historical evidence, not a second contract or a rule that freezes future documentation.

The root [Architecture](../../ARCHITECTURE.md) keeps shared guarantees, terminology, the source map, and subsystem routes. The root [Verification](../../VERIFICATION.md) keeps shared evidence rules and routes. Subsystem references contain accepted contracts and required evidence. Global gates, release rules, and qualification requirements remain separate references.

## Reproduce the preservation audit

Run these commands at this change's commit:

```sh
python3 tests/ci/doc_moves.py
PYTHONPATH=tests/ci python3 -m unittest test_doc_moves test_docs_only test_selection.WorkflowEntrypointsTest test_selection.SelectionTest.test_docs_are_not_runtime_acceptance
git diff --check
```

The [move map](../../tests/ci/doc_move_map.json) assigns every original line to one destination and records every original heading's destination. The [audit](../../tests/ci/doc_moves.py) checks the source hashes, exact content after heading and link migration, anchor destinations, and new broken links. Its explicit index edits change navigation only.

The retired-workflow check now reads both the root and the moved references. Three temporary mutations were rejected at their intended assertions: deleting a composer requirement, adding a retired workflow name to the Session UI reference, and restoring a stale root anchor. Each mutation was restored before the passing run.

Before the move, Architecture had 4,675 lines and Verification had 991. Regenerate the before counts with `git show 94d1881a:ARCHITECTURE.md | wc -l` and the corresponding Verification command. Regenerate the current layout counts with `wc -l ARCHITECTURE.md VERIFICATION.md docs/contracts/*.md docs/verification/*.md`.

## Limits retained from the baseline

The audit found these pre-existing local link defects. This move adds none:

- Architecture links to the absent README `status` anchor.
- `docs/host.md`, `docs/integrating-rui.md`, and `docs/waiting-agent-memory.md` link to the absent README `install` anchor.
- `docs/integrating-rui.md` and `docs/using-rui.md` link to the absent README `start-a-conversation` anchor.
- `docs/waiting-agent-memory.md` links to the absent README `run-your-first-swarm` anchor.
- `research/evaluator-memory/README.md` links to the removed `src/workflow_evaluator.zig` and `src/workflow_evaluator_main.zig`.
- `research/tool-activity-rendering-prior-art.md` links to the removed `src/SessionTerminal.zig`.
- `research/transport-memory/README.md` links to the removed `src/codex_native.zig`.

The [remaining decisions](../../ARCHITECTURE.md#remaining-decisions) still exclude dynamic tools and MCP, while the accepted [skills and parent-creation evidence](../../docs/contracts/conversation.md#skills-1) includes MCP behavior. That ambiguity predates this organization change. Both texts are preserved for a separate contract decision.

The complete selector unittest module exceeded local 20-second and 120-second budgets without a verdict. The focused owner subset passed instead. No local native build or runtime qualification is claimed. Hosted admission and review still govern landing.

## Concurrent documentation

The sign-in and pinning PRs change behavior and evidence in the Session UI, CLI, Store, and Session controls sections. This move preserves their baseline text and changes only ownership paths. Their owners received the actual path map, including the separated verification rows. The model-instructions owner received the model-context and Conversation map through the coordinator's cross-host relay. There is no source, API, or behavioral dependency on those features.

The [decision log](decisions.tsv) records the structural choices and evidence.
