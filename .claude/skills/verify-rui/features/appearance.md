# Terminal themes and input focus

Rui follows the terminal's colors. Night, day and mist captures show the same chat and list with different terminal backgrounds. The input, draft, selected row and focused model remain readable; a terminal without color still shows the content and marks.

## Sub-features

- Empty and multiline inputs use the shared input background in night and day themes.
- Tab focuses the model without changing the footer's words.
- New Session's selected input and a selected existing chat use the same input and selection colors.
- Day shows Overview and formatted answers. Mist shows a scrolled chat. No-color keeps headings, code, tables and links readable without color.

## How to get to it (user POV)

Use Rui in a terminal with a dark or light background. Open a chat, type a multiline draft, then Tab to its model. Open New Session and press Esc to return to the list. Use PgUp to see scrolled messages.

## Driving it with verify-rui

Run `$V frames FULLSHA --only inputtint-night-empty,inputtint-night-draft,inputtint-night-model-focus,inputtint-night-new-selected,inputtint-night-chat-selected,inputtint-day-empty,inputtint-day-draft,inputtint-day-model-focus,inputtint-day-new-selected,inputtint-day-chat-selected,day-start,day-chat,mist-chat-scrolled,no-color`.

Frame states: `inputtint-night-empty`, `inputtint-night-draft`, `inputtint-night-model-focus`, `inputtint-night-new-selected`, `inputtint-night-chat-selected`, `inputtint-day-empty`, `inputtint-day-draft`, `inputtint-day-model-focus`, `inputtint-day-new-selected`, `inputtint-day-chat-selected`, `day-start`, `day-chat`, `mist-chat-scrolled`, `no-color`

The scenario configures real terminal color-query replies for each theme. Inspect PNG or HTML as well as text; text alone cannot prove color or focus styling. Input states assert the input marker's background. The model-focus recipes hold the changed frame because the footer text stays the same.

## Gotchas

These are terminal themes, not an App settings theme picker. The named states show selected examples; color-role unit tests cover the color rules. [Chat info and navigation](./status-navigation.md) owns the other formatted-answer captures.

Source: [theme setup and expectations](../scripts/frames.json), [style roles](../../../../src/widget_style.zig), [frame color assertions](./frames.md).
