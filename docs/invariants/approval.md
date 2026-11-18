# Approval invariants

The [Session UI contract](../contracts/session-ui.md#accepted-contract) owns the visible permission prompt and shared needs-you mark.

| Id | Level | Invariant | Seam | Owner test | Source |
| --- | --- | --- | --- | --- | --- |
| APPROVAL-1 | Module | Each Bash, image or MCP permission heading uses the needs-you glyph for its script and the needs-you tone when colour is enabled. | `session_view.renderPermissionArguments` | `APPROVAL-1 permission headings use the shared glyph and tone in both scripts` | `src/session_view.zig`, `src/marks.zig` |
| APPROVAL-2 | Module | A wrapped permission heading preserves the quote continuation treatment for both needs-you glyphs. | `ConversationViewport.draw` | `APPROVAL-2 wrapped permission headings mark continuation rows in both scripts` | `src/ConversationViewport.zig` |
| APPROVAL-3 | Product | A terminal shows the needs-you glyph in the pending Action heading for its locale at wide and narrow sizes. | Session terminal | `approval_glyph_domain` | `src/SessionFrontend.zig`, `src/session_reads.zig` |
