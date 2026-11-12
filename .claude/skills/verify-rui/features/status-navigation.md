# Chat info and navigation

Alt-I or the clickable **alt+i info** footer opens chat info in a Layer above the retained chat input, never in the feed.
History still scrolls with PgUp/PgDn, arrows or the wheel when the panel is closed; Esc, End or Ctrl-G returns to live without losing the draft.

## Sub-features

- `chat-info`: Effort, Permissions, Tools, Folder, Model and Context, followed by Rename, Archive and Copy last answer. No Session IDs, Store paths or recovery records.
- `chat-info-model`: the Model field's full-width, provider-scoped choice; typing filters, arrows move and Enter saves.
- `chat-info-refresh`: current inspection facts refresh without resetting an open choice; late reads do not reopen a closed panel.
- `tool-output`: Ctrl-O or a click on a tool heading opens its saved output in place, at most 20 rows then `… N more lines`; the same key or click closes it.
- `scroll-page`: PgUp/PgDn move through one continuous feed; repeated PgUp stops at the first saved row.
- `return-live`: Esc, End (empty draft) and Ctrl-G return to the latest messages with the draft unchanged.

## How to get to it (user POV)

Press Alt-I or click **alt+i info**. Use Up/Down and Enter on fields; Esc closes the topmost choice first, then info.
While an original is held unresolved or rejected, Alt-D or the clickable **alt+d details** footer opens its separate repair and identity page. An environment-too-large notice also has clickable **details**; opening info must not show those recovery details.

## Driving it with verify-rui

Preconditions: a run with `--seed 3` or more, `doctor` PASS, and a terminal on `demo`.

- **Info.** Run `$V send "$RUN" s1 --keys M-i`, then `$V wait "$RUN" s1 --marker 'Copy last answer' --after G`. Capture at 140×40 and 46×30; verify the fields above the input and no IDs or Store paths in the panel.
- **Nested choice.** From Effort, send Down three times (Folder is not selectable), then Enter. Wait for the current model. Esc closes only the choice; another Esc closes info and restores the input's focus.
- **Settings.** From Effort, Down and Enter open Permissions. Choose **ask first**, wait for the save, and compare with `$V rui "$RUN" session inspect --store STORE --session ID` (ID is `sessions.demo` in `run.json`). A failed save stays on the field; opening or saving must not send a Message.
- **Refresh.** Send `slow please` and Enter, then open info while it streams. Check Context against a fresh Session inspection; a choice stays open as new reads settle, and a closed panel stays closed.
- **Draft survives.** Type `keep me`, open info, open and close a choice, then close info. The caret row remains `› keep me` and the provider count is unchanged. Separately test PgUp then Ctrl-G on that draft.
- **Page.** With info closed, send PgUp until another PgUp leaves the first Message unchanged, then PgDn until live.
- **Wheel path (L1–L3 only).** Byte replay of Up/Down or SGR mouse reports is not hardware proof. Inside info, Up/Down selects fields rather than scrolling history.
- **Proof.** Save snapshots per step with committed-frame generations and times. Use `frames --only chat-info,chat-info-model,model-picker,model-filter` for layout captures; overview model states open app settings, not a composer command.

## Gotchas

- Match fields by joined words at narrow widths.
- After a lone Esc, wait for the next frame before sending another key.
- Info does not clear or consume a draft; recovery handles belong to `/requests` and refused-environment repair details, not info.
