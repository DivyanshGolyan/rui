# Rui UI product decisions

Decision record for the UI review stack, coordinated by Session `22wzgn`.
This records product decisions, not implementation or verification claims.
The older `libvaxis-ui-decisions.tsv` records engineering history; it does not override these later user decisions.

## Accepted

- Show information when it helps the user's current task, not merely because it exists.
  Each visible field needs an actual source, an unknown fallback, and a reason to appear.
  Do not invent one-line progress descriptions or infer collaboration from names.
- Prefer libvaxis's native mechanics and delete the custom mechanics they replace.
  Any exception needs a concrete reason.
  Do not keep a custom cursor, offset, or wrapping owner behind an additional adapter.
- `/upgrade` acts as a command in the existing view, not a separate panel or a second confirmation step.
  Consume its submitted draft only when the operation is actually accepted.
  Preserve a refused or newer draft.
  Show compact progress and actionable results in the existing status area.
- Routine Message send/receive rows should be visually consistent with compact tool rows, distinguished by an icon.
  Do not repeat internal `Queued` scheduling labels for each received Message.
  Failed tool rows should not acquire extra blank spacing or a fully red description; emphasize the failure glyph instead.
- Use one ordinary scrolling conversation feed, not a separate history presentation or mode.
  Show a perceptible scroll position, including without colour, through the native scrollbar.
  Do not change the bottom status bar merely because the user is viewing older content.
  While looking back, one Escape returns to the bottom and resumes following new output.
  Keep the composer as the normal keyboard focus; do not introduce a separate conversation-focus or browsing mode just to scroll.
  Mouse/trackpad scrolling navigates output without moving the input caret; page-scroll keys can route to the native scroll widget without transferring focus.
  Escape while looking back restores the latest position without clearing or changing the draft.
  Paragraphs wrap to the available width; wide tables and code use native horizontal scrolling.
  Do not squeeze wide tables into unreadable columns or replace their rendered presentation with raw Markdown solely because of width.
- Render semantic output blockquotes distinctly rather than as literal Markdown prefixes.
  Preserve editable draft markers and exact source/copy bytes.
  Add subdued table gridlines without introducing separate painting and navigation geometry.
- Remove the full-row permission disclosure/read gate and its exclusive bookkeeping.
  Do not require scrolling or viewing every detail before explicit confirmation.
  Keep confirmation tied to the correct Action, deliberate input, and protection against stale or pasted input confirming another Action.
  A bounded preview must be honest about truncation and provide optional access to exact complete details.
  Oversized content alone must not make a valid Action impossible to confirm.
- Remove the separate interactive `/help` command and help-specific panel/admission policy.
  Preserve CLI and operation `--help`, command-menu descriptions, and relevant shortcut discoverability.
  Do not retain a hidden `/help` compatibility alias.
  Preserve exact Action-detail access by placing its existing captured-ID command on a relevant existing surface, not by keeping the deleted help panel.
- Remove the separate interactive `/status` page rather than moving its entire contents into the bottom bar.
  Show only useful current activity/settings and actionable attention in context.
  Existing configuration commands own settings; CLI inspection owns diagnostics.
  Check unique status-only operations and their existing replacement before deleting their access.
- Archiving a Session means stopping its agent/work and removing it from the active list.
  The user explicitly confirmed both effects; archiving is not merely hiding running work.
- Typing `/archive` and pressing Enter is sufficient; do not ask for a second confirmation.
  This changes the explicit command only, not confirmation for easy-to-hit keyboard shortcuts.
- Remove `/undo`, its repeated archive hint, and its exclusive last-archived tracking.
  Preserve `/sessions archived` and explicit `/unarchive`; restoring a Session does not restart its stopped work.
- Show sent user Messages in full rather than automatically replacing them with collapsed previews.
  Preserve bounded retained history and access to original source; do not conflate tool-output summaries with user-Message collapse.
- Show all currently queued Messages, not only the newest Message plus a count.
  One compact line per pending Message is sufficient; queue items do not expand.
  Preserve authoritative queue identity and ordering, including distinct Messages with identical text.
  If the queue exceeds available space, every pending item must remain reachable without expanding individual items.
  Multiline source remains exact and is shown in full in the conversation, not in the deliberately one-line queue entry.
- Give the composer a visible bottom edge as well as its top edge, with status outside the input region.
  Apply this consistently in the overview and conversation.
- Use the high-level libvaxis framework, vxfw, as the default for the terminal UI redesign.
  Preserve Host, Store, protocol, and installer ownership; this is not a rewrite of those systems.
- Use one shared plain-text multiline composer component in the overview and conversation.
  The overview submits a first Message to a new Session; the conversation submits a new Message to the existing Session.
  The surrounding owner supplies the submission destination; do not maintain separate editing components.
  Do not render Markdown decorations, blockquote gutters, or table formatting while editing.
  Preserve literal source, editing, and exact submitted bytes; rich formatting belongs in output.
  Use the native editor as the sole text-buffer and cursor owner, with a concrete extension for any missing multiline capability rather than a mirrored editor.
- Include inline skill invocation PR #1062 as a dependent member of the UI stack, with coordinated parent updates and whole-stack qualification/landing.
  Preserve its own source ownership rather than duplicating its implementation.
- Use native libvaxis ListView for the model picker, replacing custom generic selection/window/offset machinery.
  Preserve stable model identity and composer input routing; verify concrete library boundary defects before adoption.
- Use the existing direct-contact fact for overview “Yours”, not creation ownership.
  A Session qualifies after an admitted Message without a Session sender; peer Messages and merely opening a Session do not qualify.
  This includes scripts using the same direct route, is not verified person identity, and currently does not expire.
- Overview selection only highlights the target row; it does not reveal an extra detail line.
  Keep rows a stable height; opening the Session shows its conversation and details.
- Preserve separate unsent drafts and cursor positions for the overview and each conversation when switching between them.
  Reuse the same composer component with the appropriate draft and destination; opening a different Session never transfers text to that recipient.
- Keep keyboard focus in the overview composer while wheel/trackpad scrolling moves the Session list.
  Clicking a Session opens it; ordinary arrows edit text and Enter sends.
  Provide keyboard-only Session navigation through an explicit modified shortcut routed to the native list, without a separate persistent list-focus mode; exact bindings remain to be chosen.
- Discuss new ceremony-removal candidates one at a time before implementing them.

## Still under discussion

- Tool-output summaries and detached inspection still need their own justification; the accepted removal of sent-user-Message previews does not itself delete those distinct paths.
- Overview product redesign and native ListView adoption.
  Renderer extraction is not the proposed product redesign.
  Native list adoption is prioritized, but exact presentation and implementation remain to be verified.
  Preferred overview order discussed with the user is: directly contacted active Sessions, directly contacted finished Sessions, other active Sessions, other finished Sessions, then all archived Sessions.
  Sort by real update time descending within each category; express categories through order and row visuals rather than requiring section headings.
  The user accepted the existing direct-contact meaning of “Yours” instead of creation ownership.
  Proposed compact columns are Session name, short distinguishing directory, and update age.

## Implementation choices, not user-interface facts

- Current table treatment planned by the author: vertical dividers and one measured header rule, without an outer box.
- Existing exact Action export is an acceptable optional full-detail path; opening it is not an approval prerequisite.
- No decision in this record claims a new preview was built, a test passed, or a PR was admitted or merged.
