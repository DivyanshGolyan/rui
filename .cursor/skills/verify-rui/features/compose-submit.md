# Compose and submit

The user types a request at `› `, sees exactly that text in the composer, presses Enter once and gets one answer. Exactly one Message is admitted, with one capture key.

## Sub-features

- `compose-draft`: typed text appears on the caret row, with the caret after it.
- `compose-paste`: bracketed multiline paste stays in the draft unsent.
- `compose-submit`: one Enter sends one Message carrying exactly the draft text.
- `compose-answer`: the answer appears under the Message and the composer is ready again.
- `compose-capture`: one new capture key whose saved input sha256 equals the text's.

## How to get to it (user POV)

- Run `rui session resume --store STORE -- demo` (or bare `rui` in a project), type, press Enter.
- Retry an uncertain submission with Ctrl-R, which reuses the same key.

## Driving it with verify-rui

Preconditions:

- `doctor` reports PASS.
- Note the provider request count first: `jq -s 'map(select(.kind))|length' "$RUN/evidence/provider.jsonl"`.

- **Scripted proof.** Run `$V journey "$RUN" j1 --surface tmux-detached` (or `pty` / `tmux-attached`). It prints a PASS/ISSUES verdict and writes `evidence/journey-j1.json`.
- **Open.** Run `$V term "$RUN" c1 --surface pty` and `$V wait "$RUN" c1 --marker '›' --composer`. A frame shows the conversation with the cursor on `› `. Record its gen as G0.
- **Draft.** Run `$V send "$RUN" c1 --text 'Investigate the failing test'` and `$V wait "$RUN" c1 --marker '› Investigate the failing test' --after G0`. The caret row equals `› Investigate the failing test`, the cursor x is 2 plus the text length, and the provider count is unchanged.
- **Paste.** Run `$V send "$RUN" c1 --hex 1b5b3230307e6c696e65310a6c696e65321b5b3230317e` (`ESC[200~line1\nline2ESC[201~`). The draft shows two lines and nothing is sent.
- **Submit.** Run `$V send "$RUN" c1 --keys Enter` and `$V wait "$RUN" c1 --marker 'Fixture answer' --composer --after G1`. Exactly one new `provider.jsonl` entry exists, and its `user_text` is the exact draft.
- **Capture.** Run `$V rui "$RUN" request list` and diff it against the earlier list. One new key appears. `request inspect --store STORE --key KEY` shows `kind: message` and `input.sha256 = sha256(text)`.
- **Proof.** Run `$V screen "$RUN" c1 --label submitted` and `$V evidence "$RUN"`. `timeline.txt` shows one `inject` Enter, one `received \r` and one `provider` line.

## Gotchas

- In tmux, Rui first receives DECRPM replies. Exclude `ESC[?…$y` from "typed input" counts.
- A second provider request or a second new key after one Enter is the duplicate-submission symptom. Keep both keys and their `request inspect` output.
- Any draft prefix you did not type (for example `.` or ` is`) is a stray-input symptom. Find its first byte in `input.jsonl` before blaming the editor.
