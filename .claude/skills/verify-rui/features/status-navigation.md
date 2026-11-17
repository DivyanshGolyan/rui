# Chat info and navigation

Alt-I or the clickable chat footer opens Chat info above the input. Recent messages stay visible above the panel, and your draft stays in place. With the panel closed, the feed scrolls through messages and tool results; Ctrl-O opens tool output in place or a collapsed message's full text.

## Sub-features

- Chat info shows **Effort**, **Permissions**, **Allowed tools**, **Folder** and **Model**. **Context** appears only when an estimate is available; a known zero is shown as zero.
- **Rename**, **Archive** and **Copy last answer** follow a blank separator. Left/Right move between actions when they fit on one row; Up/Down follow them when stacked. Copy feedback reads **Copied**.
- Folder uses `~` for HOME. A long folder keeps its right end, with an ellipsis on the left; whole trailing folders are kept when they fit.
- Opening Model adds its matches above the input. Filtering shrinks that list and gives space back to the feed. One info footer sits on the last screen row, below the input and its lower divider.
- Consecutive tool calls are adjacent for every outcome. Failed Bash calls show quiet `exit 127` at the right edge; labels yield with an ellipsis first. An opened result keeps its output below its heading and the next tool immediately after its output. NO_COLOR preserves alignment.
- Ctrl-O or a click on a tool heading opens its saved output, up to 20 rows followed by **… N more lines**. Several tools can stay open. The same key or heading click folds the selected output.
- Ctrl-O on a collapsed message opens its full text. Ctrl-O or Esc returns to the previous view.
- PgUp/PgDn, arrows and the wheel scroll. New replies keep the scrolled position and show **new** beside **↓**. Click **↓**, or use Esc, End with an empty draft, or Ctrl-G to return to the latest messages.

## How to get to it (user POV)

Open a chat and press Alt-I or click the chat footer outside its controls. Use Up/Down and Enter on fields, or click them. Esc closes an open choice first, then info. Clicking the chat's model or effort word opens that choice directly; see [Model choice](./model-choice.md).

For an unresolved or rejected submission, Alt-D or **alt+d details** opens the separate repair page. An environment-too-large refusal also offers clickable **details**. Read it with the scroll keys or wheel; Esc returns to the chat.

## Driving it with verify-rui

Frame states: `chat-footer-below-half`, `chat`, `fold-hover`, `tool-open`, `tool-open-two`, `tool-open-long`, `tool-open-nocolor`, `chat-scrolled`, `chat-top`, `chat-new-below`, `markdown`, `markdown-wrapped`, `chat-info`, `chat-info-model`, `chat-info-archive`, `chat-info-copied`, `chat-info-stacked-actions`, `panels-chat-info`

Run `$V frames FULLSHA --only chat-footer-below-half,chat,fold-hover,tool-open,tool-open-two,tool-open-long,tool-open-nocolor,chat-scrolled,chat-top,chat-new-below,markdown,markdown-wrapped,chat-info,chat-info-model,chat-info-archive,chat-info-copied,chat-info-stacked-actions,panels-chat-info`.

Use both 140×40 and 46×30 captures. The completed short chat in `chat-footer-below-half` must omit context and the permanent info hint. In the info states, two completed answer lines must stay above the panel, and **keep this retry draft** must stay in the input. Opening Model should use only the space its matches need; filtering should return that space. Check one info footer on the physical last row, no extra blank notice row, and no **Context** for these fixtures without an estimate.

For a live recipe, open a terminal on `demo` with `doctor` PASS. Send `--keys M-i`, wait for **Copy last answer** with `--after GEN`, then capture. From Effort, Down then Enter opens Permissions; choose **ask first** and compare the saved Session inspection. From Effort, Down three times then Enter opens Model because Folder is read only. Type a filter, close the choice with Esc, wait for a new frame, then close info. Your draft must remain unchanged and no message should be sent.

Check tool results after their stored output has loaded. The tool frames show two open results, a long result's **… 14 more lines**, and the same output without color. Compare headings, wrapped code, tables and links in **markdown** and **markdown-wrapped**. **chat-new-below** checks the scrolled position while an answer arrives.

The action frames check horizontal Archive selection, **Copied**, and **Archive: couldn't archive** after the fixture Host is paused. At narrow width the longer labels stack; Down must follow their drawn order. A failed save stays on its field so you can correct it and press Enter again. Refreshing facts while info is open must keep an open choice; a late refresh must not reopen a closed panel.

For synthetic wheel checks, `--keys SGRWheelUp` and `--keys SGRWheelDown` send mouse reports at cell 10,10. Check the widget under that cell. Save `screen` snapshots and `wait --after GEN` generations for each step.

## Gotchas

Message pages and submission details have no dedicated named frame yet; capture their public entry paths with `send`, `wait --after GEN` and `screen`. Info shows chat facts rather than request recovery records; use `/requests` for those. Wait for a lone Esc to finish before sending another key. Synthetic wheel reports are L1–L3 evidence; physical wheel proof belongs to [Hardware input](./hardware-input.md).

Source: [chat panel](../../../../src/chat_info.zig), [footer controls](../../../../src/SessionChrome.zig), [message and browsing views](../../../../src/SessionScreen.zig), [feed presentation](../../../../src/session_view.zig), [details entry](../../../../src/SessionFrontend.zig).
