# Rui vxfw implementation plan

## Goal and authorization

Build the agreed Rui experience on the high-level libvaxis framework, vxfw.
The user authorized planning and implementation through Terra.
This replaces UI ownership rather than adding widgets over the old terminal loop.
Preserve Host, Store, protocol, installer, exact Message intent, and recovery semantics.
The adjacent rui-ui-product-decisions.md is the accepted product record.
A compile, a mock, and an actual terminal journey are separate evidence.

## Program checklist

- [ ] One owner per PR.
- [ ] A fresh worker for each independent task.
- [ ] A sub-coordinator only when one area has many parallel workers.
- [ ] Fork when new work needs a worker's built state.
- [ ] Each PR gets a verifier that isn't its author.
- [ ] Start with one unit.

Session 22wzgn owns product decisions and the plan.
Session 1915h4 retains integration, worktree, compiler, source-owner and publication coordination because it owns the existing state.
Terra gpt-6.1-terra with high reasoning authors implementation.
Use fresh isolated author worktrees, not concurrent edits to existing preserved work.
No cloud tool is available here; builds and terminal checks require this machine and private fixture resources.
Do not publish incomplete mechanical slices or claim that final-tree evidence certifies intermediate heads.
Existing stack and preview remain intact until a tested replacement is ready.

## 1. Pin the baseline and sketch the real caller

- [ ] Record a clean immutable baseline, branch, source tree and known failures before edits.
  The preserved core is 9c149b13e166aff3eda034dae82f1f8f010927d8.
  Its two known panel-related test-logic failures remain red evidence, not a passing baseline.
  The coordinator may choose a better already-preserved coherent base and must state why.
- [ ] Create one new migration worktree; do not reset or overwrite the existing stack or abandoned partial units.
- [ ] Read actual current task guidance, SimpleMadeEasy.md, and Boundaries by Gary Bernhardt.md.
- [ ] Inspect /Users/divyanshgolyan/code/vendor/libvaxis and libvaxis-rui-pin.
  They are raw upstream, not Rui's patched prepared dependency.
  Select and record a compatible source pin from evidence; the clone does not authorize an unexamined dependency upgrade.
- [ ] Write a short usage-first module and state sketch beside the implementation plan.
  Use one App runtime, one shared composer implementation, native list and scrolling state, and stable Session/model IDs.
  Rui owns domain observations, immutable submitted intent, destination-specific drafts, and explicit effects.
  Framework widgets own editable buffer/cursor, focus, scrolling, layout, cells and terminal runtime where provided.
  A draft is the widget's owned state for its destination, not a synchronized second mutable editor.
- [ ] List concrete library gaps and the smallest complete capability extension for each.
  Native multiline editing and bounded long-output drawing need actual checks.
  Do not use these gaps as blanket reasons to retain the old runtime, wrap algorithm, editor or parallel navigation.

## 2. Implement one end-to-end slice with one Terra author

- [ ] Start vxfw.App as the actual UI runtime rather than wrapping the old SessionTerminal event loop.
  Adapt existing asynchronous domain effects to its event boundary without rewriting Host/Store operations.
- [ ] Show real Session observations in a native ListView.
  Keep fixed-height rows with name, one state glyph, short distinguishing directory and truthful update age.
  No selected-row extra detail, invented summaries, inferred relationships or fake timestamps.
  Yours uses from_person_at, not creation ownership.
  Order contacted active, contacted finished, other active, other finished, then archived; recency within each.
  Establish the genuine update source; use an explicit unknown rather than work.since or polling time as a substitute.
- [ ] Use the same plain-text multiline composer component for new-Session and existing-Session submission.
  Give it top and bottom borders, with status outside.
  No Markdown decorations while editing.
  Preserve independent destination drafts and cursor positions when switching.
- [ ] Open a conversation from the list, submit an actual Message through existing domain admission, show its output, then return.
- [ ] Keep normal keyboard focus in the composer.
  Wheel/trackpad scroll list or feed; a Session click opens it.
  Ordinary arrows edit and Enter sends.
  Choose and document a nonconflicting modified shortcut for keyboard-only native list selection/opening.
  Preserve an accessible multiline newline binding and existing completion/skill routing where applicable.
- [ ] Use one normal scrolling feed with a visible native scrollbar.
  Do not add a history mode or alternate history footer.
  Escape while looking back returns to latest without changing the draft.
  Prose wraps; wide code/tables use native horizontal scrolling.
- [ ] Run an actual isolated Host-backed terminal journey.
  Prove overview to conversation to submit to output to return, both draft restorations, wheel/page navigation, Escape, resize and cleanup.
  A mock-only fixture is not a working application slice.
- [ ] Independently review the concrete slice and inspect the actual resulting source before parallel fanout.
  Do not run a new design contest or rotate authors around an unchanged failed premise.

## 3. Complete disjoint feature units on the proven core

Only fan out once shared interfaces have real consumers from step 2.
Name exact owned files and use ordinary integration; one writer for shared app/composer interfaces.

- [ ] Native overview/model lists and minimal presentation.
  Keep stable identity reconciliation and exact data provenance.
  Delete replaced numeric cursor, viewport, list offset, heading-to-row and ANSI diff machinery.
  Do not add a mirrored framework cursor or a second runtime.
- [ ] Output and source access.
  Rich output quotes use a subdued rail; tables have measured gridlines.
  Keep parser/source authority and exact copy/export bytes, including unsafe controls.
  Implement complete source reachability for large sent Messages through the framework feed, not automatic collapsed previews or an export-only substitute.
  Validate huge no-LF, quote/fence, mixed Unicode/link, saved/live, resize and bounded memory cases.
  Prefer a narrow library visible-drawing capability to another Rui-owned wrapping/census/navigation engine.
- [ ] Pending work.
  Show one compact first line for every authoritative queued admission, all reachable without expansion.
  Keep duplicate-text identities, order, snapshot consistency and stop/eviction behavior.
  Do not build an optimistic second queue.
- [ ] Actions, commands and compact activity.
  No mandatory all-details-visible or scroll-to-enable approval policy.
  Keep exact Action identity, explicit fresh confirmation, stale/pasted input rejection, occupied-submission handling, honest truncation and optional exact inspection/copy.
  Upgrade remains a command in the existing view with accepted-command consumption, compact progress and truthful results.
  Remove interactive help/status and undo, keep CLI help/config/diagnostics and explicit unarchive.
  Typed archive plus Enter stops/removes the captured Session without a second confirmation; keep shortcut policy and real recovery ledger.
  Use compact peer/tool rows; failed glyph red, not the entire description; no per-peer Queued label.
- [ ] Compose inline skill invocation with its existing owner pz34yw after a stable published parent.
  Preserve its local 62f compatibility fix and published history.
  No duplicate child implementation, WIP merge, fake completion or loss of wire/schema/source-binding guarantees.

## 4. Delete replaced owners and qualify one preview

- [ ] Remove old live UI code, duplicate cursors/offsets/layout paths, old mode-specific chrome and superseded tests.
  No permanent compatibility UI or dormant framework scaffolding.
  Transitional breakage is private and explicit; verified boundaries must be executable and reviewable.
- [ ] Audit behavioral parity against the accepted decisions, not every revoked historical UI rule.
  Remove tests of the rejected read gate and decorative composer rather than preserving them by stealth.
  Keep effect identity, admission/cancellation/recovery, exact bytes, stale input, failure and cleanup checks.
- [ ] Test framework boundaries with meaningful omissions or unfixed counterexamples for actual fixes.
  Use committed cells or domain values rather than parsing raw styling into a second geometry model.
- [ ] Measure representative bounded memory and long-text/large-list interaction costs before claiming performance.
- [ ] Treat the Store as the source of truth: UI resident memory must be a bounded working set, not proportional to total history or the largest Message. Preserve complete, exactly reloadable source and native framework geometry; do not introduce a duplicate persistent history.
- [ ] Verify the working-set guarantee with measured growth in both history size and individual Message size, including reload/navigation and source authentication. Distinguish bounded temporary disk custody from resident memory, and report concrete library, range-access, or authentication obstacles before changing this guarantee.
  Include narrow/NO_COLOR, huge payload, empty/shrink lists and repeated queued input.
- [ ] Integrate current main once at a stable source boundary and preserve nonoverlapping upstream contracts.
- [ ] Run the repository's selected local gates and focused owner tests on the final exact source.
  Record skips, material limits and all known red outcomes honestly; no broad repeated local CI mirrors.
- [ ] Obtain an independent exact-head review and real terminal acceptance of the complete agreed flow.
- [ ] Build one normal pinned preview binary, retain the previous 696a preview, and provide its absolute launch command and source SHA.
  Do not install it or operate the user's Store during automated verification.
- [ ] Update the stack/PRs only with coherent tested units and fresh required admission/review.
  No force push, partial stack landing or bypass of existing guards.

## Delivery and throughput rules

The first deliverable is one real working vxfw application slice, not four disconnected widgets.
Do not spend the first phase implementing all output edge cases or repairing obsolete panel tests.
A concrete inability to preserve a user-visible behavior is a reported tradeoff with evidence, not an invented veto.
No new product review loop is required for ordinary reversible implementation choices.
Stop and reframe a repeated root assumption instead of adding one fixture exception per failure.
The full milestone remains the agreed experience; a partial preview must say what is and is not implemented.

## Current evidence

The user approved this direction and implementation.
This plan itself proves no implementation, build, native journey, review clearance or publication.

## Execution checkpoint — 87b3fc54

The following is scoped evidence for `87b3fc54cd3e8ff91a2f38b001cc935a838dfcc2` (tree `eb4718b6e35c15e4250fdd5b6e36cd99cd8abcc4`), not preview acceptance.

### Implemented, with scoped evidence

- [x] In exercised isolated Host/PTTY cases, native App opens and creates Sessions, submits Messages, preserves destination-specific drafts and carets, and handles a delayed response while away.
- [x] In exercised cases, native paging and resize present rich prose, quotes, code and tables; captured Activity source can be exported exactly, and normal exit restores the terminal. This is not a claim of complete rich-output parity.
- [x] Scoped original-Message recovery journeys cover pre-start failure and an accepted-but-lost response followed by same-key retry.

The receipts are under `/private/tmp/rui-vxfw-index-cancel-production-evidence-6hq76d/`; source export and earlier CRLF checks have separately pinned receipts. History memory and disk figures were samples, not peaks or global bounds.

### Remaining completion gates

- [ ] Localize the original 900-second focused test-runner timeout before another broad run. Seventy-four separately passing protocol executions do not make that invocation green. Preserve the first log and use bounded lifecycle diagnostics.
- [ ] Implement and qualify authoritative pending admissions with distinct identities, correct paging/order and apply/stop transitions. The original real-Host witness reports two queued admissions but the UI shows neither (`host-queued-first`). Preserve draft, Action and terminal custody.
- [ ] Implement real Action decisions with correct identity, deliberate fresh input, pasted/stale-input rejection and original-submission capacity, without reinstating a scroll/read prerequisite.
- [ ] Complete upgrade/archive and compact peer/tool presentation, native `/model` selection, and completion/skill routing. Reconcile the accepted removal of interactive `/help`, `/status` and `/undo`, retain `/unarchive`, and apply direct typed-archive behavior. Existing legacy code is not proof of native implementation.
- [ ] Qualify bounded memory across history and individual Messages, authenticated reload/export, eviction and source anchors, and report disk and replay costs. Resolve or accurately scope same-instance destructive replacement, Unicode/link/rich behavior, exact user-accessible copy versus export, and failure/cancellation races.
- [ ] Integrate skill PR #1062 with its sole owner after a stable parent, preserving history and obtaining fresh combined qualification.
- [ ] Delete replaced UI owners, reconcile current main, complete independent exact-head review, selected repository gates and real-terminal acceptance, then build a normal pinned preview. Do not merge or claim hosted admission without the applicable gates.

**Next completion predicate:** a source-pinned real-Host queue witness covering duplicate admissions, page reachability, apply/stop transitions, draft custody and cleanup, plus concrete bounded localization of the test-runner timeout. Do not substitute unrelated happy-path passes for these results.
