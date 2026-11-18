# Session UI invariants

| Id | Level | Invariant | Seam | Owner test | Source |
| --- | --- | --- | --- | --- | --- |
| UI-1 | Surface | The Session overview has a blank top row, with its visible controls clickable at their drawn positions at narrow and wide widths. | Overview rendered frame and mouse input | `overview top space leaves controls and Session clicks aligned at narrow and wide widths` | `src/Overview.zig` |
| UI-2 | Surface | Clicking a visible Session after scrolling opens the Session drawn under the pointer at narrow and wide widths. | Overview rendered frame and mouse input | `a click on a Session row, as a terminal sends it, opens the row under it after the list scrolls` | `src/Overview.zig` |
| UI-3 | Owner | Answer prose wraps within 88 text columns while fenced code and tables use the available pane width. | Answer renderer and conversation viewport | `UI-3 answer prose has a bounded measure while code and tables use the pane` | `src/ConversationViewport.zig` |
