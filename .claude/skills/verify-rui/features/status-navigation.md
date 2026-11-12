# Chat info and navigation

Alt-I or the clickable **alt+i info** footer opens chat info in a Layer above the retained chat input, never in the feed.
The panel’s one footer replaces the ordinary chat footer below the input’s lower divider on the physical last row; no footer sits between the panel and input, and no blank notice row follows it.
History still scrolls with PgUp/PgDn, arrows or the wheel when the panel is closed; Esc, End or Ctrl-G returns to live without losing the draft.

## Sub-features

- `chat-info`: Effort, Permissions, Tools, Folder and Model, with Context only for a non-null estimate, followed by a blank row before Rename, Archive and Copy last answer (also when stacked). Folder uses `~` for HOME and preserves its right edge with a leading ellipsis: whole trailing components when possible, otherwise the longest grapheme-aligned suffix of an oversized basename. No Session IDs, Store paths or recovery records.
- `chat-info-model`: the Model field’s provider-scoped inline value editor and compact indented matches; typing filters, arrows move and Enter saves. No separate `Filter:` row; the list shrinks with matches, with one quiet `↓ N more` only when models remain below.
- `chat-info-refresh`: current inspection facts refresh without resetting an open choice; late reads do not reopen a closed panel.
- `tool-output`: Ctrl-O or a click on a tool heading opens its saved output in place, at most 20 rows then `… N more lines`; the same key or click closes it.
- `scroll-page`: PgUp/PgDn move through one continuous feed; repeated PgUp stops at the first saved row.
- `return-live`: Esc, End (empty draft) and Ctrl-G return to the latest messages with the draft unchanged.

## How to get to it (user POV)

Press Alt-I or click **alt+i info**. Use Up/Down and Enter on fields; Esc closes the topmost choice first, then info.
While an original is held unresolved or rejected, Alt-D or the clickable **alt+d details** footer opens its separate repair and identity page. An environment-too-large notice also has clickable **details**; opening info must not show those recovery details.

## Driving it with verify-rui

Preconditions: a run with `--seed 3` or more, `doctor` PASS, and a terminal on `demo`.

- **Info.** Run `$V send "$RUN" s1 --keys M-i`, then `$V wait "$RUN" s1 --marker 'Copy last answer' --after G`. Capture text and PNG at 140×40 and 46×30; verify the fields above the unchanged input, one panel footer on the physical last row after the lower divider (no ordinary **alt+i info** footer or blank notice row beneath it), and no IDs or Store paths in the panel. The seeded no-estimate chat must omit Context, not show `unknown` or an invented zero.
- **Nested choice.** From Effort, send Down three times (Folder is not selectable), then Enter. Wait for the current model’s checkmark in the indented list and the inline field cursor; no separate Filter row may appear. Esc closes only the choice; another Esc closes info and restores the input's focus.
- **Settings.** From Effort, Down and Enter open Permissions. Choose **ask first**, wait for the save, and compare with `$V rui "$RUN" session inspect --store STORE --session ID` (ID is `sessions.demo` in `run.json`). A failed save stays on the field; opening or saving must not send a Message.
- **Refresh.** Send `slow please` and Enter, then open info while it streams. Compare Context with a fresh Session inspection when `context_estimate` is non-null; when it is null the row must be absent, while a known zero must display zero. A choice stays open as new reads settle, and a closed panel stays closed.
- **Field recovery.** Model filtering and Rename share `panel_editor` refusal/recovery: an overfull or rejected edit leaves usable text and caret editable, paints the failure on that field, and permits correction followed by Enter. No wrapper implements a second recovery path.
- **Draft survives.** Type `keep me`, open info, open and close a choice, then close info. The caret row remains `› keep me` and the provider count is unchanged. Separately test PgUp then Ctrl-G on that draft.
- **Folder and actions.** Check HOME→`~` and a long path at 46 columns: left ellipsis keeps whole trailing components when possible (normally `…/checkout/code/rui`). If the basename itself is oversized, retain its longest fitting grapheme-aligned suffix after the ellipsis; never cut its right edge or hide the whole name behind an ellipsis. A blank row must remain before both inline and stacked actions.
- **Page.** With info closed, send PgUp until another PgUp leaves the first Message unchanged, then PgDn until live.
- **Wheel path (L1–L3 only).** Byte replay of Up/Down or SGR mouse reports is not hardware proof. Inside info, Up/Down selects fields rather than scrolling history.
- **Proof.** Save snapshots per step with committed-frame generations and times. Use `frames --only chat-info,chat-info-model,settings-model,settings-model-filter,model-picker,model-filter` for layout captures; overview model states open app settings, not a composer command.

## Gotchas

- Match fields by joined words at narrow widths.
- After a lone Esc, wait for the next frame before sending another key.
- Info does not clear or consume a draft; recovery handles belong to `/requests` and refused-environment repair details, not info.
