# Terminal themes and input focus

Rui follows the terminal's colors. Night, day and mist captures show the same chat and list with different terminal backgrounds. The input, draft, selected row and focused model remain readable; a terminal without color still shows the content and marks.

## Sub-features

- Empty and multiline inputs use the untinted chat ground in night and day themes. The focused input has a blinking block caret; its bottom anchor and surrounding divider rows do not move.
- Tab visits only drawn controls without changing the draft or feed. In a wide chat, the order from the list is Settings, input, then Model; in a narrow chat, the order from the input is back, then Model. Focusing a control does not activate it.
- New Session and existing chats share the untinted input; list selection remains a separate ink-wash surface.
- Day shows Overview and formatted answers. Mist shows a scrolled chat. No-color keeps headings, code, tables and links readable without color.

## How to get to it (user POV)

Use Rui in a terminal with a dark or light background. Open a chat, type a multiline draft, then use Tab to visit the drawn controls and its model. Open New Session and press Esc to return to the list. Use PgUp to see scrolled messages.

## Driving it with verify-rui

Run `$V frames FULLSHA --only inputtint-night-empty,inputtint-night-draft,inputtint-night-model-focus,inputtint-night-new-selected,inputtint-night-chat-selected,inputtint-day-empty,inputtint-day-draft,inputtint-day-model-focus,inputtint-day-new-selected,inputtint-day-chat-selected,day-start,day-chat,mist-chat-scrolled,no-color`.

Frame states: `inputtint-night-empty`, `inputtint-night-draft`, `inputtint-night-model-focus`, `inputtint-night-new-selected`, `inputtint-night-chat-selected`, `inputtint-day-empty`, `inputtint-day-draft`, `inputtint-day-model-focus`, `inputtint-day-new-selected`, `inputtint-day-chat-selected`, `day-start`, `day-chat`, `mist-chat-scrolled`, `no-color`

The scenario configures real terminal color-query replies for each theme. Inspect PNG or HTML as well as text; text alone cannot prove color or focus styling. Input states assert the input marker's background. The model-focus recipes hold the changed frame because the footer text stays the same.

Run `$V frames FULLSHA --only focus-tab-list,focus-tab-settings,focus-tab-input,focus-tab-model,focus-tab-narrow-input,focus-tab-narrow-back,focus-tab-narrow-model` for the wide and narrow focus traversal comparisons. Wide list focus has a selected row, quiet prompt and no caret; input focus restores the bright prompt and caret. Settings and Model receive focus without opening their pages or pickers. Narrow captures omit the hidden list from the order and visit the visible back button instead. Inspect PNG or HTML: these states deliberately retain the same feed text, so text matches alone do not prove the focus target.

Frame states: `focus-tab-list`, `focus-tab-settings`, `focus-tab-input`, `focus-tab-model`, `focus-tab-narrow-input`, `focus-tab-narrow-back`, `focus-tab-narrow-model`

### Chatfeed appearance

Frame states: `chatfeed-night-empty`, `chatfeed-night-draft`, `chatfeed-day-empty`, `chatfeed-day-draft`, `chatfeed-night-blank-line`, `chatfeed-day-blank-line`

Run these states at 140x40 and 46x30. Their shared Session contains several real user Messages, a Bash tool demonstration and a recorded 61-second hold before the next Message. This crosses a minute boundary without modifying the transcript or clock. The first two Messages normally share a minute; the timestamp owner’s domain tests prove exact same-minute cases independently of wall-clock capture timing. Empty and retained-draft variants show the input anchor in both themes.

The `chatfeed-night-blank-line` and `chatfeed-day-blank-line` states send one Message containing exactly `first line\n\nsecond line`. Capture both at 140x40 and 46x30; inspect that its timestamp appears on the first line and that the user tint covers all three rows, including the interior blank row, without a ground-colored break. Use an explicit shared scenario with `--before` to preserve comparable before/after captures and `pairs.json`.

Inspect committed cells and PNG/HTML for faint user-message tint, upright text, quiet prompt marks, non-repeated adjacent minute stamps, and an untinted input. Compare input and surrounding divider row coordinates before and after at each width. PTY captures demonstrate layout and emitted cursor mode, not physical-terminal blinking.

## Gotchas

These are terminal themes, not an App settings theme picker. The named states show selected examples; color-role unit tests cover the color rules. [Chat info and navigation](./status-navigation.md) owns the other formatted-answer captures.

Source: [theme setup and expectations](../scripts/frames.json), [style roles](../../../../src/widget_style.zig), [frame color assertions](./frames.md).
