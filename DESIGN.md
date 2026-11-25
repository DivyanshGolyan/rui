# Rui design principles

These principles decide how Rui's terminal screens look and read.
They are the reasons behind the screens; [Session UI](docs/contracts/session-ui.md) owns the accepted behavior of each screen, and `src/theme.zig` owns the colour values.
Divyansh accepted principles 1 to 7 on 2026-11-16 with the TUI design review, and principle 8 the same day with the warmth pass.
Where a screen today disagrees with a principle, the screen changes, not the principle.
When a new screen raises a question these principles do not answer, decide it, then add the rule here if it will come up again.

Every principle reads from the person's side of the terminal: what they see, where they look, and what they must remember.
A screen that follows them shows only what is true now, puts it where the person is already looking, and says it once.

## 1. Feedback appears where you acted

The answer to an action appears at the place the person acted, not in a status bar or a notice somewhere else.
Clicking the version number shows "Updating…" in that same spot; a failed update says so in that spot, and a click there retries.
A person should never have to look away from what they just touched to learn whether it worked.

## 2. The screen shows state, never instructions

A screen describes what is true: which chat is open, what is running, what needs the person.
It does not teach the keys.
A hint is shown only for a key the person could not guess, and the full key list lives one step away in Settings, Keys.
Typed `/` commands stay available for every chat action, even when the action is also clickable.

## 3. Every word earns its cell

A terminal has few cells, and each word competes with the work.
No label for the obvious: a number that is plainly memory needs no "rui" in front of it.
No value at its normal level: context left appears only once half of it is used, and a finished row carries no mark.
No fact twice on one screen: the chat footer never carries the chat's name, which the Session list and the terminal title already hold.
A bare code is not a word; "exit 127" says what a lone "127" does not.

## 4. Nothing moves unless something happened

Panels open and close at once, with no animation.
The only motion on screen is work in progress: a spinner on a working chat or a running tool.
A clock that ticks every second is motion with no news, so times read "now" for the first minute and then in minutes.

## 5. Tint is what you said, lines are where you act

A tinted message band means a message the person sent. List selection and hover use tint to show where the person can act.
The two lines at the bottom of a chat hold the live area: the input, and any panel opened from it (the command list, chat info, Settings).
Panels opened from the input appear between those two lines, on the plain background, with no box and no tint.
So a glance answers two questions: what did I say (tint), and where do I type or choose (between the lines).

Tint never touches text: leave at least two columns before it and at least one, preferably two, after it. Sent-message bands keep one blank tinted row above and below. List rows keep only the sideways inset so neighbours stay together. Plain rows keep the same inset, so selection and hover never move text.

## 6. One edge, one grammar

Rows share one left edge: marks sit in one column and every word starts on the next.
The same kind of thing looks and reads the same on every screen: a mark means the same state in the list and in a chat, a tool row reads the same whether it ran a second ago or yesterday, and every panel footer has the same shape.
Consecutive rows of the same kind sit together, without blank rows between them; space separates different kinds of thing.

## 7. Rare things live one step away

What a person needs every minute is on the screen; what they need once a week is one step away.
Settings and the version sit at the bottom of the list, not at the top and not in the chat.
The chat footer carries only news about that chat; app news, such as an upgrade, belongs to the app's own place.

## 8. Rui is cloth

Rui means cotton, and the screens should feel like cloth, friendly and warm, not like a hacker's console.
Grounds are cotton or dyed cotton: the night theme is indigo cloth, the day theme undyed cotton.
Lines are stitches: rules and dividers use a dashed running stitch (`┄` horizontally, `┆` vertically) in the thread colour, quieter than any text. ASCII uses `-` and `|`; without colour the stitch remains uncoloured.
A dialog above the screen is a card laid on the cloth: the screen behind fades in place onto a darker ground, the card is a lighter one, and the card's edge is the same stitch.
Accents are dyes: indigo for links and names, turmeric for what needs the person, madder for what failed.
Nothing glows: no neon, no pure black or pure white grounds, no reverse-video highlight.
Words are warm too: a person has chats, not Sessions, and the screen speaks to them plainly ("No chats yet.").
The CLI, JSON output and the contracts keep their own terms, such as Session, because scripts and agents rely on them.
