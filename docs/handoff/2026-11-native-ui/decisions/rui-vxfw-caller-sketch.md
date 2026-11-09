# Native vxfw caller sketch (initial slice)

```zig
// The existing interactive entry point supplies real Host-backed hooks/options.
var ui = try NativeUi.init(init, options, hooks);
defer ui.deinit(); // join/cancel Host borrowers before freeing drafts
var app = try vaxis.vxfw.App.init(init.io, init.gpa, init.environ_map, tty_buffer);
defer app.deinit();
try app.run(ui.widget(), .{});
```

`NativeUi` is the root widget and imperative shell, not a wrapper around `SessionTerminal.run`: it receives native events, dispatches Host work through the existing overview hooks, `SessionSubmission` and `session_reads`, and adopts completed immutable results on a native timer tick. A Host refusal leaves the submitted destination's draft intact; successful admission consumes only the captured draft, not edits made after capture. Quit cancels and joins outstanding work before freeing borrowed data. Exact entry-point signatures and callback plumbing must follow the actual callers, not this pseudocode.

State: `destination = overview | session(stable_id)`; overview observation rows contain stable IDs and sourced facts, ordered by direct contact, active/finished/archive and genuine update time (unknown when unavailable). A map keyed by destination owns one native editor instance each: switching changes the active widget, never copies its mutable text/cursor to a parallel editor. The same composer widget implementation supplies both destinations; submission captures immutable bytes and destination. The native `ListView` owns overview selection/viewport; native `ScrollView` and scrollbar own feed navigation. Composer keeps focus; route modified list navigation, page keys and wheel without a second focus mode; Escape resumes following. Output is a domain observation, not editor state.

Pin: manifest c1861acc835e42d6874f2b15744f472398fbdfb7, hash vaxis-0.6.0-BWNV_GQaDQAz9DPyb2245fA-MbFe1MtOMwVQ08z9-v50; build copies and applies `src/vaxis-parser.patch`. Vendor upstream clone 74b7d916 differs; do not silently upgrade.

Concrete gaps: pinned `TextField` has a single-row draw and no up/down or multiline layout; extend that native buffer/widget for newline insertion, visual-line movement and bounded multiline drawing rather than mirror it. Pinned `ScrollView` draws children and tracks item/line offsets; test very large single-child output and add a visible-range draw capability only if evidence shows unbounded work. Confirm paste provenance, timer wakeups and focus/mouse dispatch against the prepared patched tree before relying on them. The existing Host seams and actual output format still need integration verification; this sketch is not a working-slice claim.

Admission-boundary constraint discovered in source: `SessionSubmission.Intent.message` currently contains a `SessionInput.Ticket`; `SessionSubmission.submit` resolves it through `SessionInput.message`, and `release` releases that bank. Refactor that owner to capture immutable submitted bytes directly, preserving publication state, same-original retries, rejected/uncertain recovery and separation from later edits. Do not fabricate a ticket by inserting into the old editor. The current `Overview.run` creates `SessionScreen`/`SessionTerminal` and `Operations.converse` lends that terminal to `SessionFrontend`; neither can be retained as the runtime behind `App`.
