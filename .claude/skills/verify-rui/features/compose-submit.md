# Compose and submit

The user types a request at `› `, sees exactly that text in the composer, presses Enter once and gets one answer. Exactly one Message is admitted, with one capture key.

## Sub-features

- `compose-draft`: typed text appears on the caret row, with the caret after it.
- `compose-paste`: bracketed multiline paste stays in the draft unsent.
- `compose-submit`: one Enter sends one Message carrying exactly the draft text.
- `compose-answer`: the answer appears under the Message and the composer is ready again.
- `compose-capture`: one new capture key whose saved input is exactly the draft.
- `compose-matrix`: the input cases below hold on every surface that hosts the editor.

## How to get to it (user POV)

- Run `rui session resume --store STORE -- demo` (or bare `rui` in a project), type, press Enter.
- Retry an uncertain submission with Ctrl-R, which reuses the same key.

## Driving it with verify-rui

Frame states: `chat-draft-kept`, `chat-draft-multiline`, `send-optimistic-night`, `send-failed-night`, `send-optimistic-day`, `send-failed-day`

Run `$V frames FULLSHA --only chat-draft-kept,chat-draft-multiline` to check a draft and caret after leaving and reopening, and a wrapped multiline draft.

Run `$V frames FULLSHA --only send-optimistic-night,send-failed-night,send-optimistic-day,send-failed-day --sizes 140x40,46x30` for optimistic sending and attached failure. Each state opens a separate real conversation, types and verifies its draft, suspends only the identity-checked owned Host, then presses Enter through the PTY. The optimistic state waits for the original Message and a cleared composer within three seconds, before the admission deadline; the failure state waits for the real admission timeout and the exact quiet `Not confirmed · ctrl+r retries original` note immediately below the Message body. Every state rejects `Sending…` and resumes the owned Host in `finally` before closing its terminal, including errors. A provider hold cannot substitute for this admission hold. PNG rendering runs after cell captures, outside the brief optimistic interval.

Inspect text and HTML/PNG in both themes and sizes: the optimistic original is in the feed, not in the composer, with a normal message band; the failure and retry action are attached to that same original, not a generic footer notice. The attached note uses semantic quiet ink on conversation ground, not the terminal dim attribute. Check cursor/composer placement, exactly one original Message and its captured request identity. These are L1 protocol-path captures, not physical keyboard proof. Host STOP/CONT injections remain in the run evidence. The failure scenario is an unconfirmed admission caused by transport inactivity, not a provider-answer failure or a Host rejection.

Preconditions:

- `doctor` reports PASS.
- Note the provider request count first: `jq -s 'map(select(.kind))|length' "$RUN/evidence/provider.jsonl"`.

- **Scripted proof.** Run `$V journey "$RUN" j1 --surface tmux-detached` (or `pty` / `tmux-attached`). It prints a PASS/ISSUES verdict and writes `evidence/journey-j1.json`.
- **Open.** Run `$V term "$RUN" c1 --surface pty` and `$V wait "$RUN" c1 --marker '›' --composer`. A frame shows the conversation with the cursor on `› `. Record its gen as G0.
- **Draft.** Run `$V send "$RUN" c1 --text 'Investigate the failing test'` and `$V wait "$RUN" c1 --marker '› Investigate the failing test' --after G0`. The caret row equals `› Investigate the failing test`, the cursor x is 2 plus the text length, and the provider count is unchanged.
- **Paste.** Run `$V send "$RUN" c1 --hex 1b5b3230307e6c696e65310a6c696e65321b5b3230317e` (`ESC[200~line1\nline2ESC[201~`). The draft shows two lines and nothing is sent.
- **Submit.** Run `$V send "$RUN" c1 --keys Enter` and `$V wait "$RUN" c1 --marker 'Fixture answer' --composer --after G1`. Exactly one new `provider.jsonl` entry exists, and its `user_text` is the exact draft.
- **Capture.** Run `$V rui "$RUN" request list` and diff it against the earlier list. One new key appears. Its capture `HOME/.config/rui/requests/KEY.json` has `text.value` equal to the draft, and `request inspect --store STORE --key KEY` shows `kind: message` with `input.bytes` equal to the text length. `input.sha256` is Rui's domain-separated digest, not a plain sha256.
- **Proof.** Run `$V screen "$RUN" c1 --label submitted` and `$V evidence "$RUN"`. `timeline.txt` shows one `inject` Enter, one `received \r` and one `provider` line.

### Input matrix

Run each case on `--session demo` and on a new chat opened with Home then Enter from `--session overview`, at `--size 80x24` and `--size 40x24`, once from an empty composer and once after `--text 'x '` is already in the draft. Note the provider count and `request list` before each case. The Expected column is for the empty composer. From the `x ` draft, every expected draft line and `user_text` starts with `x ` (for example draft lines `x a` and `b`, and `user_text` `x   indented`), since the editor inserts into the existing draft. Unit tests own the full width range and every encoding; this lane proves the real terminal path on both surfaces.

| Case | Send | Expected |
| --- | --- | --- |
| Shift-Enter and Alt-Enter | `--text a`, then one of `--hex 1b0d` (ESC CR), `1b0a` (ESC LF), `1b5b31333b3275` (CSI 13;2u), `1b5b31333b323b313375` (CSI 13;2;13u), `1b5b31333a31333b3275` (CSI 13:13;2u), `1b5b32373b323b31337e` (CSI 27;2;13~), `1b5b31333b3375` (CSI 13;3u), `1b5b31333b333b313375` (CSI 13;3;13u), `1b5b32373b333b31337e` (CSI 27;3;13~), then `--text b` | Draft lines `a` and `b`; provider count unchanged |
| Alt-J | `--text a`, `--hex 1b6a`, `--text b` | Draft lines `a` and `b`; provider count unchanged |
| Malformed paste | `--hex 1b5b3230307e6669727374ff7365636f6e641b5b3230317e` (`first\xffsecond`), then `--keys Enter` | The refusal notice: `! Input rejected; nothing sent.` in both existing and new chats. No new `provider.jsonl` entry and no new request key |
| Leading spaces | `--hex 1b5b3230307e2020696e64656e7465641b5b3230317e`, then `--keys Enter` | One new `provider.jsonl` entry whose `user_text` is `  indented` (two leading spaces) |
| Wide grapheme | `--hex f09f9a80` (🚀) | Caret x advances by 2 |

A case that passes on one surface and fails on the other is a parity bug: the second surface is not using the shared editor.

## Gotchas

- In tmux, Rui first receives DECRPM replies. Exclude `ESC[?…$y` from "typed input" counts.
- A second provider request or a second new key after one Enter is the duplicate-submission symptom. Keep both keys and their `request inspect` output.
- Any draft prefix you did not type (for example `.` or ` is`) is a stray-input symptom. Find its first byte in `input.jsonl` before blaming the editor.
