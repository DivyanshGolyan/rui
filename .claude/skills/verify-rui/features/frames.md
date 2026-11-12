# Named frames

`frames SHA` uses a fresh `new --no-sessions --answers realistic` run, cumulative cast and one plain PTY per state. Build with `screen_library` (`build` without `--no-screen`). No tmux is involved. libghostty-vt answers queries, supplies terminal colors/cursor/mouse modes and commits cells at synchronized-update closes; The shared PTY owner retains the slave through child exit and final output collection, then commits the quiescent main screen. Text, ANSI and HTML use one committed snapshot; PNG uses that HTML at 2× through Node/Playwright/Chromium (omit with `--no-png`). These are L1 synthetic-input captures, not physical keyboard/mouse evidence.

Output defaults to `RUN/evidence/frames/`: `.txt`, `.ansi`, `.html`, `.png`, ordered `index.html` and `frames.json` results. Failed states retain captures/reasons; later states still run, and any selected failure exits nonzero. Cleanup preserves evidence. `--keep` retains the Host, fixture and Store, not live PTYs. Raw PTY output, exact injected bytes, terminal replies, mouse events (including no emitted bytes) and commit times live under `RUN/evidence/frames-pty/STATE/`.

## Scenario

A scenario has `sizes` and ordered `states`. Each state has `name`, `open` (`overview` or an earlier cast label), `steps`, optional `cast`, `sizes`, `theme` (`night`, `day`, `mist`), `env`, `expect`, `absent`, `record` and one-line `note`. Themes configure the terminal's real background, foreground and dark/light query response. Cast entries have `label`, HOME-relative `workspace`, `mode`, `messages`, optional `model`, `effort`, `settle` (`answered`, `pending`, `stop`), and `count` with `{n}` labels. `run.json` maps labels to Session IDs.

Steps:
- `{"text": "draft"}` or `{"keys": ["Enter", "PgUp"]}`: exact PTY input using the helper's key names. Lone Esc still needs Rui's decoder deadline; no tmux settle sleeps.
- `{"wait": "TEXT"}` / `{"gone": "TEXT"}`: match the latest committed frame, with optional `timeout` (default 20 s). Wait for resulting content, not merely the absence of a transient loading notice: a notice may not have appeared yet. No-op input need not produce a new frame.
- `{"mouse": {"at": "Settings", "do": "click"}}`: `at` is text (first cell of its first occurrence in the committed frame) or zero-based `[col, row]`. `do` is `move`, `click`, `press`, `release`, `wheel-up` or `wheel-down`; optional `button` is `left` (default), `right` or `middle`. Missing text/out-of-range cells fail clearly. The native encoder uses Rui's enabled modes; emitted bytes require changed committed cells (including styles) within 20 s. Set top-level `"repaint": false` for an intentional no-op, e.g. `{"mouse": {"at": "Settings", "do": "move"}, "repaint": false}`; no emitted bytes never waits.
- `{"send": {"to": "LABEL", "text": "message", "wait": false}}`: public Session send; `wait` defaults true.
- `{"host": "pause"}` / `{"host": "start"}`, `{"sleep": 1}` (explicit recorded hold), or `{"exited": 0}` (wait for that Rui exit status, optional `timeout`).

Only the first size runs steps; later sizes set the PTY window size and wait for a committed repaint, not a sleep. An exited terminal instead reflows its final screen. Sizes accept `140x40,46x30` or `["140x40", "46x30"]`; `--sizes` overrides all state sizes. `--only` captures chosen states while executing their predecessors through the last selection, preserving cumulative side effects.

Each size waits for the combined `expect`/`absent` predicate, then verifies the actual saved snapshot again. `expect` defaults to the last `wait`, or none when there is no wait. An action after the last wait requires explicit `expect` (text/list, or `[]` deliberately); `absent` is a list. Use content waits before acting on asynchronously loaded transcripts or Session lists. The tool-fold states wait for stored results before navigating; `many-sessions-end` waits for list population before Down. The Host-stopped chat starts the fixture-owned Host before pausing its live connection.

## Recordings

`--record` or state `"record": true` builds a first-size movie after the run by replaying `frames-pty/STATE/output.{bin,jsonl}` (recorded for every state, including resizes). Replay is silent and stops at the first resize. Playback drops identical cells, keeps the latest picture per 80 ms bucket, bounds delays to 60–1500 ms and holds the last frame for 2 s. Stills and movie frames share JSONL renderer jobs (2× transparent / 1× opaque). ffmpeg reads numbered PNGs from a concat list, generates a global palette in its own pass, then writes GIF and optional MP4. Recordings require PNG rendering and ffmpeg (checked before allocating a run); the index prefers the GIF.

For answer-markdown changes, select `chat,chat-scrolled,chat-top,markdown,markdown-wrapped,day-chat,no-color` at both sizes. `markdown-wrapped` pins the narrow continuation before widening; `day-chat` and `no-color` share its compact fixture answer. Tool-fold states start narrow to preserve selection when the sidebar appears.

The `first-run`, `first-run-codex` and `first-run-key` states open a separate terminal without local credentials. Its explicit `RUI_TEST_LOGIN=waiting` fixture supplies only the device code and waits for cancellation; no token or credential exchange occurs. The key state checks masking, and the terminal is closed without saving the key.

An `absent` marker of the form `{session:CAST LABEL}` resolves to that seeded Session's actual raw ID at capture time; validation rejects unknown labels. Literal absence markers are unchanged.
