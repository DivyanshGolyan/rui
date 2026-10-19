# Synthetic direct-PTY key matrix

This is the proposed primary direct key matrix, with four short tmux smoke rows.
It is additive. It does not replace, reduce, or qualify any existing landing gate.
Injected bytes do not establish physical-human or terminal-emulator qualification.

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
```

Output directories must be fresh. `--row NAME` is repeatable. `--surface direct`
selects only the direct PTY rows, `--surface tmux` selects the smoke set, and the
default `--surface all` runs both. `--list` lists the selected stable row names.

The default inventory has 36 direct rows and four tmux rows. It covers editing,
graphemes, unbound modifiers, double ESC, marked paste, explicit fragmentation,
bare ESC expiry, incomplete input, rejection, resize, and raw Ctrl-R recovery.
The tmux smoke set covers typing, paste, resize, and Alt-J newline.

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

The `expiry` scenario requires `IncompleteTerminalInput`, nonzero exit,
restoration, no new capture, and no provider request. The `rejection` scenario
requires a visible refusal with no capture or request, then successful fresh
`valid` input. Fixture Configure's pre-existing capture is the baseline.

## Evidence and limits

Each row retains `input.bin`, `output.bin`, `stderr.bin`, timestamped
`events.jsonl`, its input JSON, result, and cleanup receipt. Direct output is
saved before the shared `ScreenCapture` observer parses committed frames.
Recovery also retains exact Message exchanges. Provider requests are synthetic.
HOME, Store, credentials, and scratch are never copied into evidence.

The manifest records the source commit and tree, native platform, interpreter,
binary SHA-256, and runner source hashes. A row reports `passed`, `assertion`,
`setup`, `timeout`, `error`, or `interrupted`. Worker exit codes distinguish
assertion 1, setup 2, timeout 3, and other error 4. The controller exits nonzero
for any failed row. INT, HUP, and TERM retain exits 130, 129, and 143 after cleanup.
Controls require an intentionally wrong exact-byte expectation to fail at the
Message assertion and prove owned Host and caller retirement after each signal.

Send timestamps record the test driver's calls, not kernel arrival or frontend
processing times. Zero-delay chunks need not produce separate reads. The 20-ms
fragment splits, 150-ms bare ESC wait, and two-second incomplete-input checks do
not prove precedence when rendering delays input service. PTY output checks do
not establish physical key delivery or native emulator cursor placement.
