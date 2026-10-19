# One displayed editor and approval owner

Design proposal for Divyansh. Runtime implementation starts only after the
renderer lands. This document changes no accepted runtime contract and grants
no implementation, merge, deployment, or qualification authority.

The inspected base is published renderer `wip/sole-renderer-h` at
[`f15c2b57`](https://github.com/DivyanshGolyan/rui/commit/f15c2b57dea17a92b60a0bfcefed6e77b7e1ea87).
The design branch is `design/displayed-editor-projection`. The
[completed audit](https://ampcode.com/threads/T-01a15237-583d-7509-b948-d9a5b963f104)
inspected an earlier renderer revision. Source claims below were checked again
at this proposal's base. Its transcript-mark finding is not assumed to remain
unfixed at this base.

The owning accepted behavior remains in
[Architecture](../../ARCHITECTURE.md), particularly its conversation frontend,
approval presentation, draft custody, and staged-read contracts. Required
qualification remains in [Verification](../../VERIFICATION.md#canonical-gates).
This separate proposal is an explicit exception requested for frozen renderer
qualification. Acceptance later moves its decisions into those owning sections,
rather than retaining a second contract indefinitely.

## Put presentation decisions with SessionScreen

Make `SessionScreen` the invocation's presentation owner. It already owns the
selected document, Action preview completeness, row coverage, and layout.
Move the frontend's consent value into it. Keep `session_consent.zig` as its
pure value policy, extended to derive one typed projection. No new controller,
event bus, worker, or presentation cache is needed.

The projection selects the editor, prompt kind, approval instructions, and
whether Enter can request a Message or an exact Permission Decision. Rendering
and dispatch consume that same value. Prompt text is output of that selection,
never an input to policy. The current `prompt == "> "` inference disappears.

`SessionInput` still owns draft banks and the sole byte stream. The frontend
still owns the 64-byte choice editor and performs effects. `SessionSubmission`
still owns the original intent, capture, key, worker, retry, and release.
`SessionScreen` learns borrowed blocker facts, not capture or worker lifecycle.

The alternative of adding a presentation controller beside `SessionScreen`
would duplicate view and layout facts or require moving its resource-owning
methods behind another layer. The existing owner plus its existing pure policy
is the smaller interface. Naming `SessionScreen` does not mean libvaxis grants
permission. Rui's value policy remains the authority.

## Preserve these invariants

1. **One editor selection.** For a selected projection, the editor whose bytes
   and caret the frame encodes is the editor that receives decoded edit events.
   Dispatch never reconstructs `consent.active() && actionVisible()`.
2. **Visibility is not permission.** A complete visible Action can select the
   choice editor while its rows or fresh-input boundary are incomplete. Its
   text cannot authorize until both conditions hold. A hidden or oversized
   Action selects the draft and blocks Message submission, retaining that draft.
3. **Only delivered rows count.** Frame planning, cell construction, a joined
   read, writer buffering, and a partial terminal write grant no coverage or
   prompt authority. Only a successfully completed frame's matching receipt
   can advance coverage.
4. **Coverage belongs to one Action and layout.** Adoption, withdrawal,
   replacement, resize, and width-method change invalidate the applicable
   evidence. Paging cannot skip beyond the first unseen row. Rows count only
   contiguously from the top. Oversized previews never grant approval.
5. **Fresh input follows the delivered decision prompt.** Observed empty input,
   no pending decoder state, and no interruption or command blocker must follow
   that prompt. Budget exhaustion, expiry, a paste terminator, or printing the
   final Action row is insufficient. Final-row delivery clears old choice text
   and requires a new prompt frame and empty-input boundary.
6. **A decision consumes exact identity once.** Only exact typed `a` or `d`
   produces a decision. Consumption precedes fallible submission. Another
   client's decision invalidates local authority; no successor Action inherits
   coverage, freshness, text, or the original recovery request. The Host still
   revalidates the exact target. No terminal observation replaces that check.
7. **Presentation cannot release an original.** No frame receipt, editor switch,
   view change, read completion, or decision consumption releases a Message
   loan. Only the existing submission owner can release it after validated
   acceptance or explicit rejected-original discard. Uncertainty remains bound
   to that original, including a consumed Permission Decision.
8. **One stream survives transitions.** Keep paste, UTF-8, Escape deadlines, and
   ordered decoded suffixes in `SessionInput.stream`. Replacing an editor never
   replaces the stream or converts a paste tail into typed permission input.
9. **Pinned routing does not pin submission permission.** Before every Enter,
   the same presentation owner checks current borrowed blockers. A command
   queued during output blocks a later Message in that same frame. A frame's
   old instructions never grant a submission permit.

Here "displayed editor" means the editor selected for Rui's encoded frame and
its input service, not proof of what a physical terminal has painted or what a
person has read. There is no atomic screen-and-keyboard transaction. During
output backpressure, the pinned frame projection below defines routing and
withholds new approval authority until delivery and fresh input observations.

## Current behavior is split across owners

These are observations at the pinned base, not proposed behavior.

| Current owner and symbols | Existing responsibility | Proposed disposition |
| --- | --- | --- |
| `SessionScreen.ViewKind`, `view`, `action_view`, `preview_complete` | Selected document and immutable Action file loan | Stay in `SessionScreen`; Action identity joins them through the consent value |
| `SessionScreen.action_seen`, `approval_ready`, `browse`, `render`, `setWidth` | Contiguous delivered coverage, unseen-row clamp, layout invalidation | Keep coverage at the owner; derive completion from coverage instead of a separate readiness Boolean |
| `SessionFrontend.driveActive`, `actionVisible`, `approvalReady`, `step` | Repeated editor choice, status, geometry and command checks | Replace with one projection; no second predicate in dispatch |
| `SessionFrontend.consent`; `session_consent.Consent` | Exact Action, preview classification, fresh scope, one-time consumption | Move the value into `SessionScreen`; remove duplicated preview classification from consent |
| `TerminalFrame.plan` | Row allocation, document preparation, candidate coverage end | Return measured coverage as a candidate, with no semantic acknowledgement |
| `SessionScreen.render`; `SessionTerminal.redraw`, `write` | Encode cells, write and flush, pump input on `EAGAIN`, then currently acknowledge coverage in `render` | Return a stamped result; terminal proves complete output; presentation owner applies it explicitly |
| `SessionFrontend.choiceEvent`, `draftEvent`, `withdrawDecided` | Apply selected editor events, effects, and withdrawal after decoder custody ends | Keep editor effects, replace policy checks with projection and owner transitions |
| `SessionInput.applySelected`, `message`, `release`; `SessionSubmission.begin`, `advance`, `requestRecovery`, `discardRejected` | Draft sealing and original-bound submission safety | Preserve their ownership and loan protocol |
| `freeze`, `launch`, `joinReader`, `settleReader`; `session_reads.Job` | Frozen worker inputs, join before result application | Unchanged; projection introduces no worker access to UI state |
| `beginMessage`, `sent`, `details_sent`, `transcript` | Sending returns to latest and rejects stale details or history application | Preserve and test; these are page applicability facts, not editor readiness |

The current render path selects choice from `consent.active()` and
`actionVisible()`, then `step` recomputes that selection. `approvalReady()` adds
command and live geometry checks to the screen's coverage flag. The current
post-write screen update protects against a width-method change during output,
but does not expose a general Action-and-projection receipt. This motivates
explicit ownership. It is not evidence of an exploitable stale-receipt sequence
at this pin.

The frontend's `delivered` admission high-water and `echo` are a different kind
of presentation fact. `applyReader` advances them from a successfully joined,
settled live page. `SessionTerminal.permanent` appends retained text, not a
terminal frame. Preserve that existing "page applied to the live presentation"
meaning. Do not reinterpret the frontier as proof every earlier row appeared in
the currently painted viewport, and do not use it to authorize an Action.

The audit's earlier mark-collision finding is separate. At this base,
`session_reads.scan` sets non-opening marks from the first item that actually
shows, and a silent non-opening page supplies none. `Marks.record` replaces
equal-offset boundaries and an empty opening retains its start anchor. This
proposal neither enlarges the ring nor replaces canonical Conversation IDs.

## A small typed interface replaces repeated predicates

The following is an interface sketch, not compilable Zig or a new wire format.
Names are proposed. Keep existing lifecycle methods where their meaning fits.

```text
Facts {
	opening, permission_preparing, command_blocked,
	original: none | message | decision
}

Projection {
	editor: draft | choice { action },
	approval: absent | paused | preview | reading | draining | ready,
	stamp: { frame, scope }
}

SessionScreen.beginFrame(facts) -> Projection
SessionScreen.projection() -> Projection
SessionScreen.prepareAction(action, immutable_file) !void
SessionScreen.presented(DeliveredFrame) -> PresentationChange
SessionScreen.messageEligibility(stamp, current_facts) -> allowed | blocked { reason }
SessionScreen.promptCompleted(stamp, input_observation, facts) -> bool
SessionScreen.submitChoice(stamp, text, facts) -> ?Decision
SessionScreen.invalidateChoice() / withdrawAction()
```

`beginFrame` borrows current Facts, selects a projection through the pure policy,
and issues its frame stamp. `projection` reads the currently selected value
without issuing a ticket. Selection neither copies Submission's state nor
predicts a worker result. The screen's selected view, preview facts,
and coverage combine with consent's exact identity and freshness in the pure
policy. The owner passes those values into policy; policy imports no screen,
vaxis, terminal, client, or Submission handles. Keep it in `test-logic` and the
existing core-boundary check.

`Projection.editor` is the only selector of `Input.composition()` versus
`choice.buffer`. The frontend resolves that tag once for rendering and once for
each event through the same selected projection, without preserving a borrowed
editor slice across a call that can pump input. `Projection.approval` supplies
the status variant. Neither field grants an Enter permit.

`messageEligibility` checks the current selected editor and stamp plus current
borrowed Facts through the same pure policy. Call it immediately before
`SessionInput.applySelected` can seal a Message, without a pump or other effect
between the probe and sealing. `submitChoice` likewise checks current Facts,
scope, coverage, freshness, and exact Action before consumption. Neither probe
uses eligibility cached when the frame began. The input owner still checks
its submitted bank before sealing. An unresolved Message allows editing and
retains the existing busy behavior on a second Enter. A pending Decision,
command, opening, permission preparation, or adopted Action blocks Message
submission for its existing reason. Command recognition remains available
through `applySelected` when Message eligibility is blocked.

The Draft tag means the active composition role, not a loan of a particular
bank. After Enter seals a Message, subsequent edits belong to the next draft.
The old frame contains a byte snapshot, never writable authority over the
sealed bank. Normal edits can likewise make displayed bytes lag input until
redraw. The invariant concerns draft-versus-choice routing and permission
authority, not instantaneous byte-for-byte screen equality.

The meaningful combinations are closed policy outputs, not a Cartesian product
callers may construct. Enter below describes a live probe, not a field cached
in the projection:

| Owner facts | Editor | Approval | Enter |
| --- | --- | --- | --- |
| No adopted Action | Draft | Absent | Message if existing blockers permit |
| Adopted Action hidden by another view | Draft | Paused | Block Message; commands remain available |
| Oversized Action preview, visible or hidden | Draft | Preview | Block Message; exact shell guidance remains available |
| Visible complete Action with unread rows | Choice | Reading | Commands only; no decision |
| All rows delivered, but no matching fresh-input boundary | Choice | Draining | Commands only; no decision |
| Same Action, complete rows and fresh scope, no command or layout blocker | Choice | Ready | Exact `a` or `d` can consume that Action |

Policy blocks decision submission if the real Submission owner is busy; it
never overrides `SessionSubmission.begin`'s ownership precondition.

`prepareAction` is called only after the permission worker joins, the file is
complete and immutable, and the draft decoder has relinquished custody. It
adopts identity and preview classification together. The frontend remains the
file owner and closes it only after the screen's loan ends. File-load failure
retains the existing fatal invocation policy; no half-adopted choice survives.

`PresentationChange` only reports the existing effects the frontend must apply,
such as clearing choice text and requesting another frame when coverage first
completes. It does not carry arbitrary commands, replacement draft bytes, a
submission ticket, or authority to launch work.

## Apply receipts after complete output, at the owner

Keep rendering's legitimate layout and cell mutation. Remove semantic coverage
acknowledgement from `render`. `TerminalFrame` measures a range. `SessionScreen`
encodes the selected projection and returns a candidate for that range.
`SessionTerminal.redraw` returns `DeliveredFrame` only after every frame byte
and writer flush succeeds. The frontend immediately gives that value back to
`SessionScreen.presented`. A failed write returns an error and follows existing
fatal restoration and borrower-retirement rules, with no receipt.

The receipt contains the issued frame stamp, the Action identity if any, the
measured first and next positions, and which approval prompt the frame encoded.
The scope identifies adoption and layout, including geometry and width method,
plus invalidations of view or consent authority. Positions keep their existing
`ConversationViewport.Position` representation in the screen owner. The pure
policy needs only the owner's coverage-complete fact, not byte offsets or vaxis.
No Position extraction, new layout abstraction, or second copy of coverage is
required.

The owner keeps one frame-ticket record, with issued or delivered phase, and a
monotonic scope revision. Issuing a frame changes its ticket, not consent
freshness. Invalidating transitions advance the scope. `presented` changes the
outstanding ticket to delivered once and checks its scope and Action. Retain
that delivered stamp for the following `promptCompleted` probe. A duplicate or
superseded receipt makes no state change. This is local invocation state, not
persisted identity or a receipt queue.

For a matching Action frame, advance coverage only when the first measured row
is at or before the existing frontier and its next row extends that frontier.
Completion is `action_seen == Position.end` and a complete preview. Planning
past a gap cannot close it. Conservatively discard a receipt whose scope changed
during its write, even if some of its rows reached the terminal. Redrawing those
rows is safe; crediting an unrelated Action is not.

Completing coverage changes Reading to Draining, clears any previous choice
text, invalidates freshness, and requests a frame with decision instructions.
It does not open readiness from a frame that only said "read the rest".
`promptCompleted` accepts post-write input observations only for that delivered
decision-prompt stamp, the unchanged Action and scope, no pending decoder state,
actual empty input, no interruption, no command blocker, and no changed view
or dirty state since that prompt frame. The supplied input observation includes
those post-write facts, not a saved pre-write emptiness result. A normal redraw
of the same ready choice preserves fresh typed text and freshness. Invalid
choice, command handoff, departure, layout change, or view change revokes them.

### Reentrant pumping uses the selected frame projection

This is a same-thread reentrancy problem to model, not a proven data race.
`SessionTerminal.write` calls the frontend pump on `EAGAIN`; input can arrive
while an older encoded frame is still being written.

Before selecting a frame, sample geometry and invalidate layout evidence if it
changed. Then issue the projection and pin it through that frame's output.
The pump uses this projection's editor tag, not a new choice-versus-draft
predicate. Editing may make the next frame dirty. A transition that changes
the view or editor revokes decision authority immediately, but its replacement
projection takes effect at the next frame boundary. Until then, events remain
with the pinned editor. An interrupt still cancels immediately.

Only routing and frame evidence are pinned. Both submission probes read current
Facts on every Enter, including from the pump. For example, an initially
unblocked draft frame can pump `/configure --permission-mode ask` and Enter.
The queued command immediately blocks a subsequent Message Enter, even though
both events still route to the draft. The distinct next draft stays unsealed
and editable until the command finishes. Its original Enter is not queued as
future submission authority. Apply the same rule to live opening, permission,
adopted-Action, interruption, and original-submission blockers.

No raw-input queue is added. Existing command snapshots and navigation state
record the user's requested work; changing view state makes the pending receipt
stale. After the frame returns, select the replacement projection and redraw
before its ordinary input service. A decoded suffix cannot be sent to a new
editor merely because an earlier event requested navigation. Pending stream
framing keeps its original deadline and cannot become a fresh typed choice.

When the frame first selects a choice editor, its scope is not fresh. Input
serviced before complete prompt delivery is handled by the existing discard
policy, with slash commands and interruption preserved. A hidden Action frame
selects the draft instead, so typed text edits the retained draft and Enter
explains the pending decision. Ordinary draft redraws still accept draft edits
while output is held. Frozen read jobs likewise do not suppress draft edits.

An unchanged ready-choice redraw may consume a fresh exact decision during its
write. Consumption invalidates the scope before submission, so the finishing
old frame cannot restore authority. It cannot redirect its remaining input to
the next draft. If a width report arrives during output, invalidate scope
immediately. Sample actual geometry again before every decision probe, including
inside the pump, and invalidate changed layout before checking its stamp. No
requirement for physical terminal acknowledgement or a blocking `tcdrain` is
introduced.

All added metadata has one invocation as its population multiplier: one
projection, one frame-ticket record, and the scope counter. Reuse existing
coverage positions and consent storage. Frame candidates are bounded values,
not retained history. Draft banks, the choice buffer, immutable file loans,
and the existing 32-MiB cell and frame allocator retain their owners and bounds.
No byte payload, per-worker state, or per-Session allocation is added. Exact
type sizes and allocation high-water must be measured on the implementation;
this is an ownership estimate, not a memory result.

## Keep other lifecycles independent

Submission receives only `Decision { action, choice }` after consumption or the
existing Message ticket after input sealing. A failed key reservation or launch
therefore retains the same original under existing not-started or uncertain
rules. `/recover` and Ctrl-R remain original-bound Submission operations.
This design does not normalize the raw Ctrl-R and CSI-u routes; that separate
input-normalization question stays out of the ownership migration.

Joined read application still publishes staged history, footer, Current, live
calls, cursor, and the admission frontier together. It is not an atomic Host
snapshot: `sameWork` compares selected facts and `force` applies after three
unsettled reads. A stronger snapshot guarantee needs a separate product decision.

Keep `sent` and `details_sent`, transcript identity and cursor checks, status
request supersession, and all command suffix-discard behavior. Page application
must remain valid for the view and Message generation it targeted. A frame
stamp neither replaces those checks nor permits a worker to read UI state.

The audited source copies inputs into `Job`, lends only that job to the worker,
joins before result application, and uses `ClientTask`'s protected completion
state. That limited source observation supports keeping worker ownership
unchanged. It does not establish general race freedom, OS behavior, or native
qualification of this proposed interface.

## Tests must distinguish the wrong transitions

These are proposed implementation acceptance tests, not results obtained by
this design-only branch. Extend the existing consent model and owning tests.
TD1's current-state sequence model remains a separate description of the
pinned runtime, not an oracle that silently assumes this redesign exists.

The [TD1 owner](https://ampcode.com/threads/T-01a15281-f285-75dd-a515-8fa7854143cf)
confirmed a plan for 512 length-three words per seeded current-state scenario,
binding unchanged private frontend transitions through a disposable test-only
source overlay. Its independent observations cover draft and choice text and
caret, selected view and request epoch, consent alive and fresh, and admitted
canonical identities. Reuse those observation names and reproducer traces,
not that overlay as production code. Proposed frame stamps, pinned routing,
and receipt rejection need separate expectations after implementation. TD1
also confirmed that prompt completion alone is insufficient: the subsequent
decoder service must find empty input without pending decoding, commands, or
changed view or dirty state. Its runtime results remain pending, not passes
claimed by this proposal.

| Contract case | Independent observation | Targeted red control |
| --- | --- | --- |
| Hide ready Action A, type `nextéZ`, move left, press Enter, return, then type fresh `d` | Draft and non-tail caret survive; no Message; only A is denied | Dispatch selects choice from Action existence instead of projection |
| Draw final rows of A, then inspect or replace A with B before completing output | No receipt opens readiness for B or the hidden view | Ignore receipt scope or identity |
| Plan full coverage, withhold or fail final output | No coverage or readiness change; failure retains restoration policy | Apply the candidate before complete write and flush |
| Deliver rows with a gap; coalesce many PgDn events between frames; resize and change width method | First unseen row remains a hard limit; layout changes require new coverage | Credit planned rows or retain coverage across layout invalidation |
| Complete coverage with old `a` choice text or an incomplete marked paste | Clear old choice text; no decision until new instructions and real empty service | Treat final-row receipt, expiry, or budget exhaustion as freshness |
| Fresh A, invalidate or consume once, deliver old ready frame, then adopt B | No second A decision, no B decision without new coverage and freshness | Receipt reopens consumed scope or identity is retargeted |
| Block output and request view change within a decoded suffix | Every suffix event keeps the pinned editor; replacement gets no stale authority | Recompute editor selection while finishing the old frame |
| Hold a real draft-frame writer, queue `/configure`, then type distinct Unicode text, move its caret left, and press Enter | Zero Message capture or admission; exact draft and non-tail caret remain unsealed until command completion and a new Enter | Replace the live Message eligibility probe with eligibility from frame start |
| Hold a ready-choice frame, queue a command, then type `a` and Enter | No Decision capture or consumption; the same Action needs a new post-command fresh scope | Replace the live Decision probe with old frame readiness |
| Unresolved Message X, edit distinct draft Y, deliver receipts, accept X or lose reply | X's bytes and original key stay exact; Y and caret survive; uncertainty cannot release X | Treat delivery, join alone, or editor switch as loan release |
| Hold a details or older-history read, send, then complete that old read | Latest view stays selected and stale page cannot cover the new Message | Independently remove `details_sent == sent` or transcript identity applicability |
| Permission A decided externally; B becomes first Action | Local typed approval remains bound to A and fails safely; B needs new adoption | Substitute `current.first_action` at submit time |

For bounded value exploration, enumerate prefixes over adoption, hide, return,
layout invalidation, coverage candidate, successful delivery, failed delivery,
empty service, budget exhaustion, pending or expired decoding, command,
invalid choice, interruption, consumption, and successor adoption. Probe both
allow and deny after every prefix. Expected values come from an independent
reference state, not from `Projection.approval` or the production predicates.
Retain the existing 512 three-event consent words, and add longer named traces
for crossings that cannot fit three events. Record explored bounds and seeds;
finite exploration does not prove all event sequences.

Pure tests prove policy, not terminal delivery. Screen-owner tests must use a
writer that reenters real dispatch during a held frame, and verify receipt
application, token replay, geometry and exact editor contents. Native PTY cases
must retain the existing output-credit, exact Action, pasted typeahead,
interruption and restoration witnesses. A purported regression is effective
only if its targeted mutation fails at its intended assertion, not setup or
timeout. The audit's stale-page mutation passed the old scripted renderer
selection, so those passes alone are insufficient evidence for that contract.

## Implement in stages only after renderer landing

1. **Reconcile the landed base and freeze behavior.** Re-read the final renderer
   diff and TD1's current-state model. Preserve current successful journeys and
   write the crossing tests and red controls above against actual owner
   interfaces. Resolve any newly observed behavior conflict before changing
   ownership. Do not import a failing native campaign into this design branch.
2. **Centralize selection without changing routing.** Add the pure projection
   in `session_consent.zig`; make rendering, prompt styling and dispatch use it.
   Keep existing acknowledgement timing and worker ownership. Test existing
   paths unchanged. Commit this refactor separately from receipt invalidation.
3. **Move consent into the presentation owner.** Adopt Action identity with the
   immutable file, move freshness and consume operations into `SessionScreen`,
   remove frontend consent writes and duplicate `actionVisible` and
   `approvalReady` policy. Derive coverage completion rather than storing the
   extra screen readiness Boolean. Keep the pure value policy independent of
   handles. Commit and verify ownership preservation before changing receipts.
4. **Make delivery explicit.** Return the stamped candidate and delivered
   receipt, apply it at `SessionScreen.presented`, and pin projection routing
   through reentrant writes. Add the missing scope invalidations and stale
   receipt controls. This is the behavior-strengthening stage, separate from
   the refactors. Recheck every receipt producer and every view, layout,
   command, Action withdrawal and consumption path as one failure class.
5. **Qualify and update contracts.** On the final implementation, run the
   canonical affected frontend minimum: `test-logic`, `check`, and
   `admission-debug-integration` on Linux and Apple Silicon macOS. Confirm the
   selector's current mapping and native PTY membership rather than inventing a
   new gate. Inspect paused, reading, draining, ready, preview, resized, and
   backpressured journeys with draft and non-tail Unicode caret; retain real
   output and a bounded UX review. Run the existing installed-build check under
   soft descriptor limit 256 because the shipped frontend changes. Schedule
   native work through its owner after landing, not beside frozen qualification.

No migration reader, deprecated method alias, parallel renderer, old consent
path, adapter, dual projection, Store change, wire change, or compatibility shim
belongs in any stage. Move all callers and tests with the owning refactor and
delete superseded fields and predicates. The proposal's "migration" means code
ownership only. Native and installed-path qualification above are future work,
not something this branch ran or a request for a Mac runner now.

## Review and decisions

The recommendation is to reuse `SessionScreen` plus the existing pure consent
policy, consume delivery receipts there, and pin one editor selection while a
frame is in flight. This keeps geometry resources and presentation authority
local without moving draft or Submission ownership. Submission eligibility
always comes from a live owner probe, even when routing is pinned.

Before implementation, Divyansh must accept the proposed ownership and the
explicit frame-boundary routing rule. In particular, navigation during held
output revokes authority immediately but does not redirect the remaining
decoded suffix into a different editor. This is a proposed rule that needs its
own red controls, not a claim that the current runtime already guarantees it.

The [independent GPT-6.1 Sol read-only review](https://ampcode.com/threads/T-01a15288-29d4-71db-966e-05b0b7093900)
found one design ambiguity: cached frame eligibility could let a Message pass a
command queued by reentrant input. The direction was otherwise accepted by
source inspection, including a bounded UX lens. The correction separates
pinned routing from both live submission probes and adds the Message and
Decision controls above. The review's Rich Hickey lens interpreted
[Simple Made Easy](https://www.infoq.com/presentations/Simple-Made-Easy/), not an
endorsement, as keeping independent concerns separate rather than minimizing
method count.

The finding's search scope covered `draftEvent` to `applySelected` to
`beginMessage`, `choiceEvent` to consent consumption to Submission, and both
`beginMessage` callers. Interactive Message and Decision paths need live probes.
The initial command-line text path in `drive` is explicit prevalidated initial
intent before interactive service, not a frame permit, and remains unchanged.
Recovery retries an owned original through Submission, not a new editor Enter.
The analogous command-before-choice case needs the Decision red control too.
Prompt freshness independently retains its current post-write blocker checks.
This accounts for the known submission paths without asserting a current
runtime bug or expanding into worker scheduling.

Corrected-artifact review and final document checks remain to be recorded before
handoff. There are no native, physical-terminal, hosted Mac, rendered-UX, or
runtime-correctness claims in this proposal.
