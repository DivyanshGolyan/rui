# Coordinated libvaxis UI refactor

## Goal

Make Rui's terminal UI easier to use and simpler to maintain by giving generic rendering and scrolling one library-backed owner.
Preserve the runtime guarantees that the library cannot own.
This is one coordinated effort, not separate competing renderer rewrites.

## Current checkpoint

The local task branch is at b8f8e1b2, including reviewed output activation, the bounded rich-paint contract, consent documentation, and final CLI/helper/root corrections.
Both output source reviews are complete within the supported producer and geometry contracts.
The corrected ReleaseSafe product build, 1,042 selected logic/dependency tests, and macOS typechecks pass.
The earlier failed 8503daae build remains separate evidence.
Final verification is not complete: the full policy run found one obsolete pending diagnostic name after the narrow error-contract cleanup.
That one-entry cleanup is assigned separately; three unrelated Darwin harness failures remain reproduced baseline issues, not passing checks.
The exact b8f8e1b2 terminal journey is authorized and underway, with its evidence attributed only to that pin.
No completed output native qualification, installation, publication, or main landing is claimed.

## Definition of done

- Routine tool activity is visually subordinate to assistant prose, with indentation in NO_COLOR and prominent failures and approvals.
- Ineffective Up or PgUp on fitted conversation content does not insert rows, change layout, or enter a visible history mode.
- Conversation look-back preserves the logical reading anchor across incoming output, older history, and resize.
  The footer and loaded-content scrollbar show the position.
  Down follows only at the actual current end; Ctrl-End selects latest explicitly.
- One terminal invocation owns the input decoder across overview/detail transitions.
  Incomplete CSI and SS3 sequences cannot leak their final character into a new Session's draft.
- Overview and conversation use libvaxis cell rendering and frame diffs.
  Rui no longer owns a separate overview ANSI screen-diff implementation or a parallel generic scroll offset.
- Session and model selection retain semantic identity after data refresh.
  Editing ordinary text does not accidentally navigate a list or execute a different stop target.
- Terminal modes, output credit, cancellation, restoration, and delivered-frame approval authority retain one explicit owner each.
- Blockquotes are clear in editable input, submitted user messages, and assistant output, including wrapped lines, nesting, blank quote lines, narrow resize, and NO_COLOR.
  Editable source and caret mapping remain literal; code and escaped markers do not become false quotes.
- Assistant Markdown tables have a bounded streaming, source-backed rendering path with narrow-width fallback, alignment, safe inline styles and links, and resize reflow.
  Structured table widgets are reused only where their verified API replaces a real owner.
- Existing bounded documents and charged screen allocations remain bounded.
  Tests cover long styled text, large words, narrow and resized terminals, links, and failed or partial delivery.
- Focused regression tests, mutation controls, real isolated terminal captures, and independent review prove the integrated head.
  A zero-match test filter, a successful build alone, or an author summary is not verification.

## Responsibility boundaries

| Responsibility | Owner |
| --- | --- |
| Session identities, filtering, grouping, model/default choices, commands, and effects | Rui's domain cores |
| Input decoder, terminal modes, descriptor flags, output pump, and restoration lifetime | One terminal invocation |
| Screen grids, clipping, Unicode word layout, ANSI encoding, and frame diff | libvaxis through one charged rendering backend |
| Viewport row offset and final extent clamp | Low-level libvaxis ScrollView |
| Temporary logical anchors, bounded canonical history joins, source continuity, and retention gaps | Rui conversation presentation |
| Whether a precise Action was fully delivered and may be approved | Existing Rui consent scope, tickets, and receipts |
| Stable semantic selection across refreshed rows | Rui; library indices are a projection, not another authority |

## Work universe and sequence

### U0. Baselines and acceptance contract

Keep the original session-detail findings and the input-handoff regression as executable acceptance cases.
Capture overview, model picker, draft, NO_COLOR, consent, resize, and unchanged-frame behavior before replacing their owner.
The existing session baseline is real private tmux at 80x24.
Up and PgUp on already-fitting text inserted a Browsing header and Start marker, moving the content down two rows.

### U1. Foundations, independently verified

- U1a.
  Update the exact libvaxis pin and remove local fixes now provided upstream.
  Audit every retained safety patch.
  A discovered pre-existing cross-segment word-wrap failure gets its own root-cause correction and test, not a weakened assertion or an unrelated upgrade change.
- U1b.
  Move TerminalInput to the terminal invocation.
  Overview and SessionInput borrow the same decoder and synchronously consume borrowed events.
  No copying or swapping decoders at a view boundary.

These lanes have separate worktrees.
Their overlap with later lifecycle changes is integrated before a shared terminal/backend extraction.

### U2. Session-detail interaction and scroll ownership

Complete the active session implementation against the U1 interfaces.
Separate retained text from the library's row offset.
Remove Document.top, pinned movement/clamping walkers, and redundant progress revisions.
Keep logical Position only as a source and consent coordinate or a temporary reflow anchor.
Preserve bounded snapshot and canonical seam proofs.
Use explicit trailing blank canvas rows to preserve a short pinned anchor, never grow that padding on downward input, and make bounded-view limits distinct from genuinely missing retention.

Keep assistant prose normal, quiet and indent routine tools, preserve meaningful failure details, and retain the existing compact tool grouping.
Do not add expandable tool groups in this unit.

### U3. Shared charged rendering backend

The shared encoded-frame owner must balance OSC8 links on every nonempty successful frame; terminal restoration separately closes links after partial output.
Encoding commits the library's retained grid before terminal delivery, so ordinary navigation must not abandon a partial frame and then reuse that cache as if delivery completed.
The preferred policy freezes the encoded frame and defers a benign view transition until its write finishes, with immediate domain scope invalidation and at most a constant-size pending transition.
Urgent exit and signal cancellation keep their existing bounded restoration path.
This policy requires a partial-CSI/OSC/link probe and review before production adoption; queueRefresh alone is not a cancellation recovery protocol.

Extract the generic grid, resize, link-budget, and libvaxis encode/diff custody from conversation-specific state after U2 is verified.
Keep terminal I/O separate from painting and encoding.
Preserve exact consent receipt timing.
The overview must use this backend rather than converting widget surfaces back to the old Span/ANSI renderer.

One owner implements this shared boundary.
No concurrent SessionScreen or SessionTerminal rewrite is allowed.

### U4. Overview and picker adoption

Move the overview off its custom ANSI diff owner.
Prototype bounded, fixed-height Session/model rows and library list behavior against the shared backend.
Library layout/navigation is adopted only where its old generic owner is deleted.
Preserve stable IDs, composer text, persistence, and a clearly visible stop target; incidental old viewport positioning is not a requirement.
Group headings and status rows need an explicit selection model rather than accidentally becoming stoppable Sessions.

Stock full-answer vxfw Text/RichText is not part of this implementation.
Executable probes show input-sized surface/cell allocation even for a small viewport.
Fixed-height bounded list rows are a different case and require their own proof.
Do not infer one widget's safety from another's name.

#### U4b. Tables

Include tables in the coordinated adoption plan.
Distinguish structured application tables from Markdown tables in assistant answers.
Evaluate the low-level Table widget for existing tabular overview/status surfaces, with one selection owner and bounded per-frame allocation.
Separately prove a bounded streaming Markdown-table path for dynamic columns, alignment, styles, links, narrow widths, and resize.
Retain only bounded typed block spans over the existing raw bytes, and derive cell ranges transiently through the same pure row parser at capture and layout; do not retain a second per-row/cell index model without measured need.
Normalization, splice, retention clipping, history loading and frozen-tail copying must all preserve that typed provenance through one source-edit rule.
The library does not own Markdown parsing.
Adopt its table layout/drawing only where a small data projection replaces local machinery; do not force a compile-time record-table API onto arbitrary Markdown through an unbounded or mirrored model.
If the existing widget cannot satisfy those contracts, record the precise limitation and scope the missing capability as its own reviewed unit before implementation.
The overview/table analysis owner supplies the prototype and actual deletion/integration accounting.

#### U4c. Blockquotes in input and output

Include the user's explicit blockquote request in the same program.
Use one bounded quote-prefix policy across editable drafts, submitted user text, and assistant output, without hiding or rewriting editable `>` source bytes or introducing a preview mode.
Continuation rows need an aligned visual gutter; nesting, blank quoted lines, Unicode, narrow widths, resize, and NO_COLOR must remain understandable.
Recognize assistant quote semantics before inline flattening so escaped literal markers and fenced code cannot be promoted accidentally.
Reuse the existing inline style/link recognizer for quote contents, not a second Markdown engine.
Coordinate quote and table/fence boundaries through the reviewed typed source seam where needed, without making the generic backend own Markdown.

The existing Document.quotes Action-preview field continuation rule is a distinct safety behavior, not a Markdown quotation flag.
Do not infer approval or trusted field identity from a user quote gutter.
Draft layout must keep one source-byte-to-caret projection even when continuation gutters occupy decorative cells.
The read-only design reviewer is c8ndtr, coordinating with xn25qw.
ctk85b owns an isolated Q1 foundation in rui-markdown-blocks: a pure raw-prefix/fence core and tests, with only behavior-preserving delegation from the existing renderer.
Editable layout and output decoration are not enabled by that foundation; their coupled-file ownership waits for U3/U4 release.
The first reviewed subset uses up to three leading ASCII spaces, explicit separated or adjacent quote markers, at most eight levels, literal fallback for unsupported prefixes, and at least two body cells before continuation decoration.
Quoted fences retain visible literal code/delimiters in this slice, and table-looking content inside quotes stays quoted literal text.
This is not a full CommonMark claim or a change to canonical copy/code extraction.

### U5. Integrated verification and removal

Verify overview-to-detail-to-overview transitions, split keyboard encodings across those transitions, history paging while live output arrives, consent, draft editing, provider/model choices, status/details pages, stop behavior, resize, NO_COLOR, shutdown, and restoration.
Measure full retained-document row-census cost against the old path before adding any cache.
Remove old APIs and tests that only enforce the deleted implementation shape; retain independently specified behavior and failure assertions.

### U6. Delivery

Use a small ordered stack of coherent verified changes, not one giant rewrite.
Shared-file work stacks behind the current owner.
Coordinate the open archive change before publishing overlapping files.
Each unit has an independent reviewer and an explicit verified, not verified, or inconclusive verdict.
Only the current tested head counts.
No force-push, deployment, installation, user Store mutation, or unrelated change is implied by this plan.

## Accepted checkpoints and current implementation

The original session-detail changes are committed at e5362f2e9e66950bc8393a86f583819f2f30f22b.
Independent source reviews and scoped clean-build native terminal qualification passed there; the original fitted-content jump is absent, look-back and actual-end catchup work, and quiet tools plus explicit consent denial remain readable with and without color.
The native report is FINAL-ACCEPTANCE.md under the 20261106T185401-e5362f2-27194 verification run.
All verifier-owned resources were cleaned up.
This is not qualification of the later shared backend, tables, quotes, physical input, allow execution, or a full repository gate.

Q1's unused raw quote-prefix/fence lexical foundation is independently verified at 051d537c87b4dd32685d3b25744d545d9975627c.
Its 65 focused tests and two selector tests preserve existing renderer/copy-code behavior; no quote decoration is enabled.
T1 is independently verified at d8ab9bce7827d6addcc7dc053179183901dcab5a in the same isolated formatting branch.
It returns at most eight transient source ranges, uses explicit pending/LF/canonical-EOF endings, and leaves fence/quote eligibility with the existing renderer.
It introduces no durable row index, new held buffer, rendering activation, or typed-custody bypass.

U3 production extraction is committed; independent review requested three corrections at 5c9b1fd3.
The narrow corrected checkpoint 84b76d62469fbb0a9ecd80ed5263f41ecef24ce6 passed independent re-review; all three findings are closed.
Scoped pinned-build native qualification passed: controlled consent/backpressure checks and a separate real-screen transition journey used the same exact binary.
The U3-FINAL-ACCEPTANCE.md report under verification run 20261106T210138-84b76d6-89161 records the observed transitions, input readiness, links, look-back resize, NO_COLOR, explicit denial, and complete owned-resource cleanup.
This does not qualify U4, tables, quotes, retention overflow, physical input, or the full combined test gate.
The earlier blocked-fixture timeout was isolated and corrected under the finish-then-switch contract; its unsuccessful run remains historical evidence, not a passing test.
U4 removes the old overview diff owner at e4d2003ac397a6c56c6369b8c35c760df1f0fdb1.
Independent review found one test-oracle coupling issue, corrected only in tests at 0be23055c95d66b20ec0ae503162c3e3bde69c17.
Narrow independent re-review closed that finding; production bytes and retained snapshot literals are unchanged by the correction.
The corrected pinned build and scoped actual-terminal product qualification passed at 0be23055; the earlier e4d2003a artifact remains distinct.
The U4-FINAL-ACCEPTANCE.md report under run 20261106T221335-0be2305-59246 records public model picking, selection and resize, shared-view transitions, NO_COLOR, safe explicit denial, exact provider counts, and complete owned cleanup.
The helper pyte decoder cannot interpret the new colon-form color SGR correctly; that harness issue remains open.
All affected visual judgments use preserved actual tmux captures and pane cursor facts, not the corrupt decoded projection.
The local task integration branch now includes independently reviewed typed-custody correction checkpoint 9b867109dad738f7af72223e36983b47e85a6824, based on reviewed main reconciliation 61fa753f.
The earlier 4b1528f0 input checkpoint retains its scoped native evidence; no native result is relabeled to the main merge.
No push, installation, or origin/main landing is implied.
The unused shared quote/code opacity core is also independently verified at 8028458ab82c49b4a9c89c2c010c96bd4e44cd99 under CTX-V1-CRLF.
It does not enable a production caller.
Atomic editable quote decoration is independently source-verified and scoped-native-qualified at 4b1528f0dfdf972ff507494bd5cab6911043139f.
The Q2-FINAL-ACCEPTANCE.md report under run 20261106T230732-4b1528f-6008 records both composers, source caret positions, narrow resize, NO_COLOR, tab/fence fallbacks, exact original-source submission, and complete cleanup.
The separate protocol content digest is domain-prefixed; the evidence preserves both its correct computation and the original plain-file digest assumption.
Assistant and submitted-user output quotes and tables are not enabled by this input slice.
Current main advanced to 939c7b2a while the refactor ran, including merged archive/restore and compact saved-tail behavior.
A distinct true merge checkpoint 61fa753f7801e535eab4f80c306e0eec27ae0e8f reconciles those features before deep output-custody changes; independent review cleared the integration with no actionable findings.
Typed output custody checkpoint b54234be introduced the optional complete live/history source path with production capabilities deliberately null.
Independent review found planned-metadata credit underflow, short-EOF quote extent ordering, and opacity-only opener literalness issues.
The bounded correction at 9b867109dad738f7af72223e36983b47e85a6824 passed both narrow independent re-reviews, including the original failing owner regressions.
Common consuming-unit layout and output table/quote activation are implemented and independently source-reviewed at 769c5676, with the bounded rich-window guard reviewed at afdfb537.
The local task now includes the reviewed final compile/policy and bounded encoder corrections through 9834be99.
Its application output code remains identical to the b8f8e1b2 native build; only the dependency encoder and durable regression tests changed afterward.
Actual terminal testing found duplicated table-row text after a copy-status redraw involving a ZWJ glyph.
The first incorrect frames and raw output are preserved; the native run is classified ISSUES and all private resources are cleaned.
A bounded library encoder correction addresses the observed narrower joined-emoji advance without changing layout or adding a full refresh.
Its independent review found an adjacent-unlinked-cell OSC8 boundary issue; the correction passed narrow re-review at 9834be99.
The fresh exact-head build and scoped terminal qualification passed at 9834be99.
The original copy-cycle regression is stable before any resize, and saved output, NO_COLOR, narrow fallback, look-back catchup, source-preserving copy and explicit consent denial passed.
All four terminal exits restored their settings and all private test resources were cleaned.
The final report is FINAL-NATIVE-ACCEPTANCE.md under the final-9834be9-native verification run.
The old b8f8e1b2 issue report remains immutable and is not relabeled as passing.
Expanded Message inspection deliberately remains literal; semantic user fenced-tail painting retains unit-test coverage rather than a native qualification claim.
The final selected development tests pass 1046/1046 and the Mac typecheck passes 47/47 steps.
The full policy run retains only three separately reproduced Darwin baseline failures; its obsolete pending-name regression is corrected and independently reviewed.

## Current ownership

- Coordinator and integration/acceptance owner.
  Rui session 22wzgn.
- Completed session-detail checkpoint owner. ctk85b; the rui-session-detail-ux task worktree now includes reviewed output activation and final source corrections through f8a5aa3d.
- Dependency-only owner. s3rzqz, worktree rui-session-ux-vaxis-upgrade, branch session-ux-vaxis-upgrade.
- Input-lifetime owner.
  4dme4x, worktree rui-input-handoff, branch fix/input-handoff-b.
- Broader overview/library and Markdown-table design. xn25qw, worktree rui-markdown-tables, branch markdown-tables-wayfinding.
  Scratch-only probes and exact usage/deletion contracts inform U3/U4/U4b; no shared production-file writes.
- Shared backend implementation. bttx3k, worktree rui-shared-vaxis-backend, branch refactor/shared-vaxis-backend, from integrated checkpoint 3993ca8f.
  Stage A completed independent source review and fresh 15-test Debug/ReleaseSafe acceptance.
  Stage B and its correction are reviewed and scoped-native-qualified at 84b76d62.
  U4 direct overview adoption and legacy Span/diff removal are independently source-cleared at 0be23055 in rui-vaxis-overview; that source remains frozen as the scoped-native-qualified checkpoint.
  Coupled formatting ownership now transfers to ctk85b in a new dependent worktree, never by editing the frozen verifier source.
- Native verifier. snt38m, completed and cleaned the baseline and qualified U1/U2/U3 runs.
  The exact corrected U4 build and scoped product journey are complete, and all owned resources are cleaned.
  The Q2 input journey is also complete with all five terminal exits restored and private resources cleaned.
  The final 8503daae build failed before runtime and remains preserved.
  The corrected b8f8e1b2 build passes, but its terminal journey found an actual table redraw issue and stopped.
  All its owned resources are cleaned; the first wrong frame and unfinished-case limits remain preserved.
  The separately reviewed encoder correction has a fresh 9834be99 build and completed scoped terminal qualification.
  All four terminals exited with settings restored; private resources are cleaned and no further runtime is authorized.
- Native helper and recipe owner. a7q8bf, worktree rui-verify-rui-receipts.
  Receipt/selector repair is integrated; doc-only consent-control correction d6ec69c8 is reviewed separately, without claiming native allow, paste, or physical-input execution.
- Dependency wrapping regression and durable gate owner. edpcce, worktree rui-libvaxis-contracts, branch refactor/vaxis-layout-contracts.
  The durable harness reproduced the baseline failure.
  Its root correction also covers style-run partitions and replayable, allocation-free segment iteration, so bounded callers no longer split words across separate print calls.
- Independent dependency upgrade reviewer. bw58t7 completed exact commit ad1f4b0e with no actionable new findings; this does not qualify the integrated UI stack.
  The native helper, shared-backend corrections, and U4 source plus test-oracle correction reviews are complete; native evidence remains separately scoped.
- Independent session-detail reviewer.
  52sct0, read-only review of the stable U2 diff and final correction deltas.
- Low-level ScrollView design reviewer. t5gjkb, finished scratch proof and ownership/deletion inventory.
- Full-widget bounded-allocation review. bttx3k finished those scratch proofs and now owns the separate U3 implementation lane above.
- Input/output blockquote design and review. c8ndtr, read-only source and bounded scratch proposal, coordinated with the table/source-seam owner.
- Formatting implementation. ctk85b keeps the reviewed rui-markdown-blocks foundation branch immutable at 8028458a.
  The rui-draft-quotes worktree is frozen at verified input checkpoint 4b1528f0.
  The new rui-output-blocks worktree, branch feature/output-blocks, owns main reconciliation and subsequent typed output custody and common table/quote layout.
  Accepted foundation integrations are 999ed203, 9c4a1ca3, and 9e4ae08b; disjoint root and selector registrations merged without replacement.
  True merge 61fa753f and corrected typed custody 9b867109 have passed independent source review.
  Common output units, table cells and quote gutters are implemented and activated in the reviewed source after live/history and layout proofs.
  The branch is frozen after the reviewed encoder integration at 9834be99.
  edpcce owns only the bounded dependency encoder correction and its durable regressions.
  No application redraw workaround or new input probe is introduced.
  Corrected-source review and the exact-head scoped terminal qualification are complete.
  Source remains frozen; no publication or installation is authorized.
  Known harness limitations and the three unrelated Darwin policy failures remain explicit rather than waived.

Only one worker writes each branch.
Shared implementation files are changed in sequence.
Independent probes, baselines, review, and disjoint foundation work can run in parallel.

## Known evidence and blockers

- Baseline. /Users/divyanshgolyan/.cache/verify-rui/runs/20261106T172412-2c6e1d5-29606/evidence/BASELINE.md.
- Low-level direct Window.print bridge. /tmp/rui-scrollview-build-t5gjkb/probe.zig.
  Parent reran the one-test build successfully.
- Strict clamp and fixed rail probes. /tmp/rui-scrollview-probe-t5gjkb.zig.
- Full-widget allocation probes. /tmp/rui-widget-probe.qdzand5u.
  Source and bounded tests, not a full native UI proof.
- Parent review constraints. /tmp/rui-session-ux-parent-review.md.
- Held pre-refactor patch. /tmp/rui-session-ux-22wzgn-held.patch.
- Input red reproduction. /tmp/rui-input-handoff-red.log.
  Installed pre-fix binary showed a stray B when an unfinished arrow sequence crossed the detail/overview transition.
  The one-decoder source correction and later scoped e5362f2e native qualification are complete; the red artifact remains historical evidence.
- Dependency expanded tests found Window.test.print: word failing on both old and upgraded patched sources.
  Segments h, e, l, l, o at width four produce the wrong final row.
  This was not an upgrade regression.
  The subsequently integrated replayable iterator/root correction and durable 108-test dependency target resolve it; the old red artifact remains historical evidence.
- Archive PR 1026 is merged upstream.
  True merge 61fa753f reconciles archive/restore, compact saved tails and current task-scoped guidance with the UI refactor; independent both-parent review is complete.
  Publication still obeys the repository's ownership and stacking rules.

## Not in this refactor

No general widget framework, new event-loop framework, terminal emulator, persistent unread tracking, new history wire protocol, expandable tool groups, native scrollback migration, image feature, theme redesign, or unrelated Host/runtime architecture change.
Findings outside the definition of done become explicit follow-ups rather than hidden scope.

## Decision discipline

Retain a new abstraction only if it has one responsibility and deletes an old owner.
A library widget is not an automatic simplification.
A thin bridge is acceptable; two independently mutable positions, two render diffs, copied decoder state, and duplicate lifecycle authorities are not.

The coordinator reviews artifacts and diffs, reconciles scope, owns integration order, and records decisions in libvaxis-ui-decisions.tsv.
Authors do not verify their own conclusions by status text.
A failure is kept as evidence until a source correction makes its regression pass.
