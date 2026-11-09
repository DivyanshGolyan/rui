# Rui machine handoff

This note comes from product coordinator Session 22wzgn. Source/ref coordinator is Session 1915h4. User explicitly requested all work pushed remotely and all work stopped. Remote handoff receipts from 1915h4 must supply final branch names and exact SHAs. Nothing here is a green-build or merge claim.

## Resume goal

Complete the actual high-level libvaxis vxfw.App UI migration while preserving Rui's disk-first, memory-efficient architecture and exact submitted intent. Do not resume the earlier custom-loop design or reconstruct the retired seven-part stack. Native UI is the accepted direction. Preserve existing Host/Store/protocol/installer owners unless a concrete accepted requirement needs a bounded change.

## Current authority

Native author is 6hq76d, source checkout /tmp/rui-vxfw-native-migration, branch review/rui-vxfw-native-migration. Last checked clean committed checkpoint before handoff was e81d57aa. At the parent's handoff inventory it had modified src/client.zig and untracked src/NativeRequestLedger.zig. These are unfinished ledger implementation, not a tested feature. The coordinator must checkpoint them rather than discard them.

Model picker author 1styjv has separate native /model work and isolated Host/PTTY qualification. It is not yet combined with the latest Action/feed checkout. Its exact final handoff ref is the source coordinator's responsibility.

Inline skills child owner pz34yw has worktree /Users/divyanshgolyan/code/personal/rui-inline-skills-1058 and branch feature/inline-skill-invocation. Published PR1062 was 439fa104c6a00c7419e88482f785bde7cd26a573. Local 62f8ac0d37f663f67c6da9ca5d53c5229249c873 fixes the legacy refusal binding. Its full canonical prepush was cancelled, not green. Independent focused security and compatibility proof exists. Do not duplicate child source into parent. A normal merge and new UI/composer/wire compatibility qualification are required after parent stabilizes.

## Immediate unfinished unit

Fatal terminal exit can lose a frozen submitted original if worker startup failed before capture. The real isolated Host/PTTY reproduction is /private/tmp/rui-vxfw-action905-evidence-6hq76d/ui-action-original-loss.log. A submitted reason-then-deny Message was frozen, worker start failed, later draft existed, then EIO exited with no request JSON and no recoverable original. This is submitted-intent custody, separate from ordinary unsent-draft autosave.

e81 makes exit guidance more truthful. It does not preserve the original. Existing wire-only captures omit the observed Host fence and compound continuation. NativeUi teardown previously discarded join's accepted.denies continuation and described all unresolved kinds as Messages. Ordinary crash-draft autosave is NOT authorized.

The product coordinator authorized a bounded extension of the EXISTING private request ledger. One versioned record should preserve exact validated wire payload/binding/key/store/session, observed-instance authority, and typed operation/compound continuation. No second journal, emergency draft store, Host/Store schema change or new network protocol is authorized. Native acceptance cannot claim durability before atomic capture publication. Publication failure keeps original in current UI and sends nothing. Worker-start failure after publication must leave a real recoverable handle. Do not print original private text in diagnostics or send a new denial from fatal teardown.

Recovery must not duplicate the reason, change the Action, downgrade uncertainty to unsent, or treat reason acceptance as denial acceptance. Preserve ordinary same-key Message recovery across normal Host restart and the observed Host fence for a first Action decision. Historical accepted keys are not authorization for replacement Actions. Actual old readers must reject new records before transmission; current readers must retain supported old-record inspect/read-result/recover behavior. This unit needs exact crash/publication/fence/compound/tamper compatibility tests and independent review. No claim it is implemented or qualified.

## Qualification limits

Real isolated Host/PTTY receipts exist on earlier exact pins for native create/send/multiline, separate drafts and carets, large-source bidirectional paging, verified disk-backed content and eviction, quote/table/code horizontal output, exact Activity export, authoritative queue and model selection. They are scoped, not combined preview qualification or universal memory/terminal proofs.

Native Action 905 proved pre-redraw kernel-pending Alt-Y did not approve while a later fresh Alt-Y did. Input readiness bugs on macOS and retryable false-ready paths have been investigated at the framework owner. Genuine fatal input errors still terminate and ordinary in-memory drafts are not autosaved. Submitted-original loss remains the unfinished ledger unit above.

A prior 900-second build/test-runner timeout remains unresolved. Separate protocol passes do not qualify that aggregate. Final combined gates, legacy UI deletion, remaining agreed product integration, current-main reconciliation, fresh independent review and ReleaseSafe preview are still required.

## Source-of-truth documents

Preserve the five parent documents currently under /Users/divyanshgolyan/code/personal/rui-session-detail-ux/docs/proposals/: libvaxis-ui-decisions.tsv, libvaxis-ui-refactor.md, rui-ui-product-decisions.md, rui-vxfw-caller-sketch.md, rui-vxfw-implementation-plan.md. These are untracked in that old checkout and must become remote handoff artifacts. Prefer the latest native plan where it supersedes an earlier plan; do not overwrite newer content blindly.

Existing product decisions cover plaintext shared multiline composer, one normal feed with Esc latest, native list and editor ownership, quiet truthful overview rows, optional inspection and explicit Action confirmation without a read/scroll gate, compact peer/tool presentation, quote rails/table grid, all authoritative queued items and full sent Messages, accepted-command upgrade, removal of interactive help/status/undo, and direct typed archive with explicit unarchive. Refer to the decision document rather than inventing product changes.

The mock browser app rui-ux-preview is illustrative, not native implementation or test evidence. Its source may also need remote archival. Do not upload node_modules, private fixtures, stores, credentials or raw captured user content.

## Suggested skills on resume

Invoke current poteto-mode, recall/session pickup, how, architect and diagnosing-bugs as appropriate. Read Simple Made Easy and Boundaries resources if available. Use existing immutable source/test receipts, preserve exact pin attribution, and avoid new process-heavy review campaigns. Re-establish one source/ref coordinator and serialized heavy compiler ownership before implementation resumes.
