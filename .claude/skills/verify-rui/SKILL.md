---
name: verify-rui
description: Drive Rui's full-screen interactive terminal (the renderer) the way a user does, on a pinned build, in a synthetic HOME/Store with a deterministic provider, through a plain PTY or tmux (detached or with an attached client), and capture byte-exact evidence. Use to prove or diagnose the overview, compose/submit, consent, /status, scrolling, exit/signal restoration, tmux and hardware-input behavior on macOS or Linux.
---

# verify-rui

Drives the real `rui session resume` terminal. You never touch the user's default Store, credentials or tmux server: every run gets a fresh synthetic HOME, a private Store under it, an owned fixture provider, an owned Host and a private tmux socket. Every Rui call passes `--store` explicitly. `request list` is the one exception: it takes no `--store` and lists captures under the run's synthetic HOME.

The helper is `scripts/verify-rui`. Set `V=.claude/skills/verify-rui/scripts/verify-rui` from the repo root. Every subcommand has `--help`. Read the [feature map](features/README.md) before driving a feature.

## Launch

1. **Build once per pinned head.** Use a full SHA. Make a clean detached worktree for it, or let `build` create one under `~/.cache/verify-rui/src/SHA`:

   ```sh
   git fetch origin && git worktree add --detach ../rui-verify-pin-SHORT FULLSHA
   $V build FULLSHA --source ../rui-verify-pin-SHORT --pkg-dir "$ZIG_LOCAL_PKG_DIR"
   ```

   The build refuses a dirty or mismatched checkout. It runs `zig build -Doptimize=ReleaseSafe` and copies `zig-out/bin` to `~/.cache/verify-rui/builds/SHA/bin`. It also writes `manifest.json` with the SHA, tree and binary sha256 values. A cold build takes about 5 minutes on an M-series Mac. A line saying `failed command: sh ./src/build_transport.sh` in the log is normal when rc=0. The first use creates `~/.cache/verify-rui/venv` with `pyte==0.8.2` and `wcwidth==0.2.13`, matching CI's `.github/actions/setup`:

   ```sh
   python3 -m venv ~/.cache/verify-rui/venv && ~/.cache/verify-rui/venv/bin/pip install 'pyte==0.8.2' 'wcwidth==0.2.13'
   ```

2. **New run, one per experiment.**

   ```sh
   RUN=$($V new FULLSHA --seed 3 --label my-check)
   ```

   This prints the evidence root `~/.cache/verify-rui/runs/ID`. Scratch lives at `/private/tmp/vr.*` because Unix socket paths are short, and contains `home/` (with synthetic Codex credentials), `store/`, `project/` and `tmux.sock`. The run then:
   - starts the fixture provider and `rui host serve --store STORE --provider-endpoint FIXTURE`;
   - waits for `host status` to report `ready`;
   - starts Session `demo` (bypass) and Session `approve` (ask), each labelled with its name, and records their IDs in `run.json` under `sessions`;
   - seeds N answered messages into `demo`. Use `--seed 3` or more when you need PgUp history.

   `--host-setenv NAME=VALUE` (repeatable) adds a variable to the Host's own environment, for example a Host-only secret Bash must not see.

   `--no-sessions` skips `demo` and `approve` for an empty Store. `--active-capacity N` sets the Host's Active Capacity; it defaults to 2.

   Ready means `host status` reports `"status":"ready"` and both Sessions exist. Teardown is `cleanup` (see below).

3. **Open a terminal: one Rui client per name.**

   ```sh
   $V term "$RUN" NAME --surface pty|tmux-detached|tmux-attached [--session demo|approve|overview] [--size 80x24]
   ```

   - `--session demo` or `approve` opens that Session with `rui session resume ID`, inside the overview, so Esc returns to it. `--session overview` runs bare `rui --store STORE` in the project directory: the overview of every Session.
   - `pty`: headless PTY. Input arrives through `send` into a FIFO.
   - `tmux-detached`: Rui in a window of the run's private tmux server, with no client attached.
   - `tmux-attached`: the same, plus an owned tmux client attached through its own recorded PTY, recorded as terminal `NAME.client`.
   - `--setenv NAME=VALUE` (repeatable) sets a variable in that terminal's environment. In a PATH value, `{PATH}` stands for the run's PATH.
   - `--no-tap` (tmux only): runs Rui directly in the pane, as a control for harness effects. It records no input bytes.

   Each Rui runs under the tap: an inner PTY proxy that records every byte Rui receives and emits.

## Doctor

Run it first, and again whenever anything looks off:

```sh
$V doctor "$RUN" --expect-sha FULLSHA
```

Doctor is read-only. It checks:
- the binary sha256 against the build manifest;
- the source HEAD against the run SHA (`--expect-sha` checks the intended head);
- the synthetic HOME/Store, which must not be the default Store;
- that the owned fixture and Host PIDs are alive with unchanged start times;
- that the fixture answers with this run's ID;
- that the Host is `ready` with the instance ID recorded at launch, and holds this Store open (`lsof`);
- that both Sessions are present;
- that the tmux server is on the private socket.

It also prints macOS Accessibility and Screen Recording status for information only. Any `BAD` line means you must not drive this run.

## Drive

| Action | Command |
| --- | --- |
| Type text | `$V send "$RUN" NAME --text 'hello'` (tmux: `send-keys -l`; pty: FIFO) |
| Keys | `$V send "$RUN" NAME --keys Enter`. Names: `Enter Esc C-c C-g C-r BSpace PgUp PgDn S-PgUp Up Down End Home Tab SGRWheelUp SGRWheelDown`. Through tmux these are sent as exact bytes with `send-keys -H`. The SGR names send unsolicited mouse reports; a real wheel reaches Rui as `Up`/`Down`. |
| Raw bytes | `$V send "$RUN" NAME --hex 1b5b4d2069730a` (tmux: `send-keys -H`) |
| Through the attached client | add `--via client` (bytes enter tmux as terminal input, not `send-keys`) |
| Signal Rui | `$V signal "$RUN" NAME INT\|TERM\|HUP` (verifies the PID is this terminal's Rui) |
| Wait for a frame | `$V wait "$RUN" NAME --marker 'TEXT' [--composer] [--after GEN] [--absent TEXT]` |
| Snapshot | `$V screen "$RUN" NAME --label 02-draft` (committed frame; tmux also gets `capture-pane` plain/ANSI and pane flags) |
| One-shot Rui | `$V rui "$RUN" request inspect --store STORE --key KEY` (STORE = `jq -r .store "$RUN/run.json"`) |
| Replay input | `$V replay "$RUN" SRC NEW [--from-run OTHER] [--skip-reports]` (re-feeds SRC's received bytes, with original gaps, into a new PTY) |
| Physical terminal | `$V physical FULLSHA` (guided, auto-graded L4 session for a present human; `--smoke` launch check, `--rehearse` tooling check). `$V gui "$RUN" NAME --open` attaches Terminal.app to one tmux window by hand |

`wait` matches committed frames only. A committed frame is the cells at a synchronized-update close, decoded by the repo's `tests/integration/terminal_screen.ScreenCapture`. Raw-byte markers are not evidence. Always pass `--after GEN` from the previous step, so the match is a new frame and not history. `--composer` additionally requires the cursor to sit on the `› ` prompt row, or on the overview's composer row.

Stable handles from the product:
- `›`: the composer prompt.
- `Browsing · Esc returns`: an inspection or scrolled view.
- `Session: NAME` and `Work:`: the /status page.
- `Start of conversation`.
- `Detached. Host work continues.` and `Resume: rui session resume …`: shown after exit.
- `Run Bash`: the consent prompt.
- `Fixture answer N: received "…"`: the fixture echoes the exact received text.

Fixture policy, chosen by the latest user text:
- `tool demonstration`: three Bash calls (`ls`, `exit 127`, stderr plus `exit 1`), then a summary.
- `consent check`: one 32-line Bash command, which needs consent in `approve`.
- `long bash`: one Bash command that sleeps 8 s, so a Session runs Bash long enough to stop.
- `show environment`: one Bash call that prints `CLIENT_MARK`, `command -v brew` and `PATH`, so a run can show which terminal's environment Bash got.
- `start a child`: one Bash call that starts Session `child` with `show environment` through `rui session start`.
- `parallel bash`: two Bash commands issued together that sleep 12 s and 20 s, so two calls run side by side.
- `slow`: the answer streams for about 10 s.
- `rate limit`: HTTP 429 with `Retry-After: 8` the first time that text arrives, then an echo. The Session retries for 8 s.
- `invalid output`: a stream that is not JSON, so the Turn fails.
- Anything else: an echo.

The fixture never runs out of replies, so an extra submission shows up as an extra request and doesn't fail.

The scripted proof journey (compose → draft cells → submit → answer → exactly one provider request and one new capture key whose saved text is exactly the draft → `/exit` restoration):

```sh
$V journey "$RUN" j1 --surface tmux-detached   # or pty / tmux-attached
```

## Evidence

Everything lives under `$RUN/evidence/`:
- `commands.jsonl`: every Rui CLI call, with argv, rc, stdout and stderr.
- `injections.jsonl`: every injection. Records the mechanism (`fifo`, `tmux` with exact `send-keys` argv, `client`, `kill`, `replay`, `gui-open`), the payload hex and text, and monotonic `t_ns` and `t_end_ns`.
- `terms/NAME/input.jsonl` and `input.bin`: the bytes Rui actually received, with monotonic `t_ns` and offsets. In tmux they include terminal replies such as `ESC[?2027;0$y`.
- `terms/NAME/output.bin` and `output.jsonl`: every output byte.
- `terms/NAME/frames.jsonl`: every committed frame, with `t_ns`, generation, cursor and output offset. Use it for initial and draft cells and for timing.
- `committed.txt` and `display.txt`: the latest committed frame and the latest raw pyte display.
- `meta.json`, `exit.json`: the wrapper and Rui PIDs, target rc, `stty -g` before and after with PENDIN/FLUSHO masked like `terminal_restoration_integration.py`, whether the alternate screen was active at exit, and the main-screen tail (resume hint).
- `shots/`: snapshots.
- `provider.jsonl` and `provider/request-NNNN.json`: every model request, with the exact user text, kind, headers (minus Authorization) and the full body.
- `$V evidence "$RUN"`: exports `request list`, each key's `request inspect`, and Session inspects into `export/`. Writes `timeline.txt`, which merges injections, received bytes and provider requests on one monotonic clock, and `summary.json`.

Proof standards:
- Drive the real `session resume` user path. Never use internal setters or test endpoints.
- Capture the action and the resulting state, before and after, by generation.
- Verify side effects: provider request count and text, capture keys with their saved text (`HOME/.config/rui/requests/KEY.json`) and `request inspect` result, saved results.
- The provider is the only mock. It sits at the production HTTP boundary.
- A surface you did not exercise is not covered by one you did. PTY, tmux-detached, tmux-attached and physical terminal are different surfaces.
- Name the input layer of every input claim:
  - L1: FIFO bytes;
  - L2: tmux `send-keys`;
  - L3: bytes typed into an attached tmux client PTY (`--via client`);
  - L4: a physical keyboard or wheel in a GUI terminal.
- Hardware claims need L4. L1–L3 replay is not hardware coverage. A missing human or permission makes the result BLOCKED.
- Report every result as `PASS`, `ISSUES` or `BLOCKED`. Include the SHA, the binary sha256, the run path, the method, the first wrong state (or what was observed), controls and limits. Non-reproduction is not PASS for a reported bug. Say what was tried and at which layer.

## Cleanup

```sh
$V cleanup "$RUN"
```

Cleanup runs `evidence` first, then:
- kills the private tmux server only (`-S RUN/tmux.sock`);
- runs `rui host stop --store`;
- stops each PID in `owned.jsonl`, but only if its start time still matches;
- archives the Store to `evidence/store-after.tgz`;
- removes the scratch tree.

It never kills by process name. Evidence under `~/.cache/verify-rui/runs/ID/` survives. Check with `ls "$RUN/evidence"`. Run cleanup after failed attempts too. `$V list` shows runs that are still `LIVE`.

## Gotchas

- Opening a terminal in tmux makes Rui receive DECRPM replies (`ESC[?2027;0$y ESC[?1007;0$y`). These are terminal reports, not typed input. A PTY run receives none.
- Rui exits 0 after `/exit`, Ctrl-C and SIGTERM, and prints `Detached. Host work continues.` on the main screen.
- Esc completes only after the decoder's lone-Esc deadline. Wait for the next frame before sending more bytes, or they join it as Alt-key input.
- PENDIN can be set after exit when input is queued. It is kernel-owned and masked in `termios_restored`, and the raw `stty_after` is kept.
- The tap's wrapper shell (`/bin/sh -c`) is the session leader. Rui is its only child, and `signal` resolves and verifies that child.
- Parser-level decode events are not exposed by the product. Use received bytes plus committed frames plus `replay`, and state that limit.
