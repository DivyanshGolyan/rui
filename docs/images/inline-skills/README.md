# Inline skill runtime captures

These SVGs render actual native tmux cells, including colour and selected-token underlines; they are not interface mockups.
Independent verifier Session `302aka` captured both composers using isolated fixture skills and a loopback provider.

- `existing-two-marks.svg`: selecting two skills in the middle of an existing Session's prompt preserves its surrounding text.
- `fresh-two-marks.svg`: the fresh composer attaches the same two skills before Session creation.
- `command-skill-collision.svg`: the menu distinguishes a builtin command from a skill with the same name.

Captured production commit: `beef18915da6027ff0e249d6bb3ffe9722fba8f5`.
The later source change in `62dc5d7c` only corrects the shared CLI size-limit diagnostic and adds its rendered-message regression; it does not change these screens.
The captured native binary's SHA-256 is `362f3e5a1cd61d5c4847cacf225ac92a8d10a9eefbc17c17df5a680a0b14d181`.
