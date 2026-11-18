# Marks and display width invariants

| Id | Level | Invariant | Seam | Owner test | Source |
| --- | --- | --- | --- | --- | --- |
| MRK-1 | Module | Every status has its designated Unicode mark, printable ASCII fallback and tone, and the spinner includes the active mark. | `marks`, `spinner` | `MRK-1 status marks and spinner represent their states` | `src/marks.zig` |
| MRK-2 | Module | Failure causes provide the appropriate explanation, repair location or retry advice for the failure and provider. | `cause` | `MRK-2 failure causes provide the appropriate explanation and advice` | `src/marks.zig` |
| MRK-3 | Module | Display width counts the text shown by the target renderer and saturates at the maximum cell count. | `display_text.width` | `MRK-3 display width measures rendered text and saturates` | `src/display_text.zig` |
| MRK-4 | Module | Every status mark and spinner frame occupies one cell under each renderer width method. | `marks`, `spinner`, `display_text.width` | `MRK-4 status marks and spinner frames occupy one cell` | `src/marks.zig`, `src/display_text.zig` |
