# Overview marks

These invariants cover the overview list's work-state marks and repaint scheduling.

| Id | Level | Invariant | Seam | Owner test | Source |
| --- | --- | --- | --- | --- | --- |
| OVM-1 | Surface | Overview rows show each work state with its appropriate mark, age, style and animation across supported displays and list surfaces. | `Lines` and rendered frame | `OVM-1 overview marks and ages across states and spinner frames` | `docs/contracts/session-ui.md` (overview groups and rows), `src/overview_view.zig` |
| OVM-2 | Surface | The overview requests a repaint at the earliest visible age, quota or eligible spinner change, and does not animate ineligible rows. | `nextRedrawAt` and `Lines.spins` | `OVM-2 overview redraw deadlines follow visible changing content` | `docs/contracts/session-ui.md` (overview groups and rows), `src/overview_view.zig` |
| OVM-3 | Surface | Overview lines retain their targets, navigation, focus, selection and archive presentation for every list shape and display capability. | `Lines` and list input | `OVM-3 overview lines preserve navigation targets and presentation across list states` | `docs/contracts/session-ui.md` (overview groups and rows), `src/overview_view.zig` |
| OVM-4 | Surface | A stop gesture sends one stop for stoppable work and reports the current state for work that cannot be stopped. | Overview input and effects | `OVM-4 stop gestures follow the work state` | `src/overview_view.zig` |
| OVM-5 | Surface | An active row spins only while it is the viewer's own live work, and every other active row holds still with a quiet dot and its word (`working`, `retrying` or `stopping`) in the age column. | `Lines.at`, `Lines.spins` and `nextRedrawAt` | `OVM-5 an active row spins only while yours and live, and otherwise holds its word` | `docs/contracts/session-ui.md` (overview groups and rows), `src/overview_view.zig` |
