# Synthetic direct-PTY key matrix

Divyansh approved this primary direct key/escape/paste/wheel/mouse matrix and
five-row tmux smoke set in place of full attached/detached tmux key matrices.
This area supplies that workload; workflow owners apply the gate wiring.
Other qualification gates are unchanged. Physical checks are post-landing,
Ghostty first. Injected bytes establish neither physical-human nor emulator
qualification.

## Commands

The runner requires Python 3.11 or newer, the pinned packages in
`requirements.txt`, tmux for the smoke rows, and a native built Rui binary.
Each worker sets its soft `RLIMIT_NOFILE` to 256 without changing the hard limit.
The controller runs up to `--jobs` independent worker processes, each with its own
HOME, Store, Host, provider endpoint, caller, and PTY or private tmux server.

```sh
python3 -m venv .amp/td4/venv
.amp/td4/venv/bin/pip install -r tests/qualification/direct-pty/requirements.txt
zig build -Doptimize=ReleaseSafe
.amp/td4/venv/bin/python tests/qualification/direct-pty/test_driver.py -v
.amp/td4/venv/bin/python tests/qualification/direct-pty/matrix.py "$PWD/zig-out/bin/rui" --output .amp/td4/matrix --jobs 4
.amp/td4/venv/bin/python tests/qualification/direct-pty/controls.py "$PWD/zig-out/bin/rui" --output .amp/td4/controls
.amp/td4/venv/bin/python tests/qualification/direct-pty/matrix.py "$PWD/zig-out/bin/rui" --output .amp/td4/ghostty --jobs 4 --vectors tests/qualification/direct-pty/ghostty.json
```

Output directories must be fresh. `--row NAME` is repeatable. `--surface direct`
selects only the direct PTY rows, `--surface tmux` selects the smoke set, and the
default `--surface all` runs both. `--list` lists the selected stable row names.

The default inventory covers editing, graphemes, unbound modifiers, Kitty keys,
double ESC, marked paste, explicit fragmentation, bare ESC expiry, incomplete
input, rejection, resize, and raw Ctrl-R recovery. Seeded-history rows cover
PgUp/PgDn, Shift-PgUp, CSI/SS3 Up, three End forms, Esc and Ctrl-G return,
alternate-scroll wheel Up/Down encodings, and `/status`. Unsolicited SGR/X10
wheel and split-X10 reports must leave submitted text unchanged. The tmux smoke
set covers typing, paste, resize, Alt-J newline, and `/status`.
Navigation checks exact seeded-history ranges after entry, intermediate
Down/PgDn steps and return, distinguishing one-line movement from page movement.
It observes a later printable composer marker before checking each range, then
clears that marker with Ctrl-U. The ordered marker prevents an intermediate
frame from crediting an overshooting key batch; it never submits a Message.

**A green default run is not complete Ghostty conformance.** `ghostty.json` is a
separate mandatory conformance workload with no expected-failure conversion.
It checks Kitty and legacy case27 Shift-Enter, Ctrl-Enter rejection, and encoded
Ctrl-R recovery. On the unchanged renderer base, the Kitty modified-Enter
probes pass; legacy case27 modified Enter and both encoded recovery probes
remain runtime failures until the renderer owner supplies a separately approved
fix. Ghostty v1.2.3's default legacy modified Enter encodings
are `ESC[27;2;13~` and `ESC[27;5;13~`; this runtime does not negotiate Kitty or
modifyOtherKeys. TD2 owns the exhaustive split-vector and editor-policy matrix.

The direct key workload does not replace the pinned renderer campaign's
submitted-frame, tool-row, status-freshness, consent-context, external-decision,
or restoration witnesses. Keep those owning checks; do not credit them from a
key result. This harness does not prove rendering-delay precedence or physical
terminal behavior.

## External byte sequences

`--vectors FILE` accepts a JSON array. Every row has a unique filesystem-safe
`name`, a `scenario`, and `chunks`. An input chunk contains `hex` and an optional
`delay_before` in seconds. A resize chunk contains `resize: [columns, rows]`.
An `editor` row supplies `expected`, the exact submitted Unicode text.

```json
[
  {"name":"split-left","scenario":"editor","chunks":[
    {"hex":"61631b5b"},{"hex":"44620d","delay_before":0.02}
  ],"expected":"abc"},
  {"name":"original-recovery","scenario":"recovery","chunks":[{"hex":"12"}]}
]
```

The `recovery` scenario loses the first real Message reply. It checks a replay
of exactly the original key and wire bytes, a separately edited next draft
`next cafXé!` with caret column 11, and then `next cafXYé!` after `Y` and Enter.
The original is `original éZ`. Provider requests must show exactly these two
Messages, with no duplicate provider execution. Encoded recovery probes can
replace the raw `12` chunk without changing those assertions.
The provider hold is released and the original answer observed before recovery
input; a failing recovery wait therefore cannot expire that hold and trigger a
confounding provider retry.

The `expiry` scenario requires `IncompleteTerminalInput`, nonzero exit,
restoration, no new capture, and no provider request. The `rejection` scenario
requires a visible refusal with no capture or request, then successful fresh
`valid` input. Fixture Configure's pre-existing capture is the baseline.

## Evidence and limits

Each row retains `input.bin`, `output.bin`, `stderr.bin`, timestamped
`events.jsonl`, its input JSON, result, and cleanup receipt. Direct output is
saved before the shared `ScreenCapture` observer parses committed frames.
Observed events include the committed screen and caret, not just a mode label.
Recovery also retains exact Message exchanges. Provider requests are synthetic.
HOME, Store, credentials, and scratch are never copied into evidence.

The manifest records the source commit and tree, native platform, interpreter,
binary SHA-256, and runner source hashes. A row reports `passed`, `assertion`,
`setup`, `timeout`, `error`, or `interrupted`. Worker exit codes distinguish
assertion 1, setup 2, timeout 3, and other error 4. The controller exits nonzero
for any failed row. INT, HUP, and TERM retain exits 130, 129, and 143 after cleanup.
Controls require an intentionally wrong exact-byte expectation to fail at the
Message assertion and prove owned Host and caller retirement after each signal.
Wrong arrow/wheel/page distances and wheel direction must fail at the exact
history-anchor assertion, rather than merely entering and leaving Browsing.
They also inject setup interruption before/after provider start, after Host
start, PTY acquisition and caller launch, plus tmux interruption and failed
server teardown paired with a body assertion. Failed disposal retains the
private control root and reports no successful cleanup receipt. The controller
requires both a matching passed receipt and zero worker exit; a late crash or
signal cannot turn green.

Send timestamps record the test driver's calls, not kernel arrival or frontend
processing times. Zero-delay chunks need not produce separate reads. The 20-ms
fragment splits, 150-ms bare ESC wait, and two-second incomplete-input checks do
not prove precedence when rendering delays input service. PTY output checks do
not establish physical key delivery or native emulator cursor placement.
