# Using Rui from scripts and agents

Scripts and agents use one-shot commands grouped by resource: `session`, `request`, `action`, `host`, `defaults` and `auth`. `rui RESOURCE --help` and `rui RESOURCE COMMAND --help` describe the installed version's exact options. Help needs no Host or credentials.

Output follows three rules:

- `session start` prints the new Session's six-character ID on stdout.
- Other metadata is JSON on stdout.
- Recovery handles and diagnostics go to stderr.

## Start a Session

One-shot commands never start a Host or sign in. Start the Host first:

```sh
STORE="$HOME/.local/share/rui/store"
rui host start --store "$STORE"
SESSION=$(printf '%s' 'Investigate the failing test' | rui session start --store "$STORE" \
	--workspace "$PWD" --provider codex --model gpt-6-luna --permission-mode ask)
```

`session start` creates the Session and admits its first Message in one transaction. The ID it returns is an admission receipt, not a finished answer. An ID is exactly six random lowercase Crockford base32 characters (`0123456789abcdefghjkmnpqrstvwxyz`), such as `k7m2qx`. Creation settings you omit come from the current directory and your saved defaults.

## Send Messages and read results

```sh
printf '%s' 'Also check the error path' | rui session send --store "$STORE" --to "$SESSION"
rui request inspect SAVED_HANDLE
rui request read-result SAVED_HANDLE
```

`session start` and `session send` print a handle on stderr. Use it in place of `SAVED_HANDLE`. Both commands return once Rui admits the Message, not when the work finishes.

- `request inspect` reports the Message's current state once. To wait, run it again later.
- `request read-result` prints the saved answer only after the work completes, even if the Session has done newer work since.
- `request list` lists saved handles.

If you lose the output of `session start`, recover its original handle to get the allocated ID. Do not start again with a new key.

The conversation shows commentary and the final answer as separate assistant messages, in the provider's stream order around tool calls. `request read-result` returns only the final answer. For responses whose messages have no phase, it returns the last assistant message.

### Addressing

`--to` takes the bare ID, without JSON or a prefix. A person or script can pass `--store`, or omit it to use the saved default Store. A peer Session always sends within its own Store, even when `HOME` points elsewhere, and rejects a different `--store`. An unknown ID fails with `no session k7m2qx in this Store` and creates no work. Random IDs are not authorization.

### Message text and instructions

Message text comes only from stdin. Rui keeps the exact UTF-8 bytes, including NULs and trailing newlines. To send a file, redirect it. There is no `--text` option, inline text operand or file-valued instructions option.

Set instructions separately:

```sh
rui session configure --store "$STORE" --session "$SESSION" --instructions - < instructions.txt
```

An empty instruction stream clears the instructions. An empty Message stream sends nothing. Without `--session`, `session configure` creates a Session with no Message. With `--session`, it updates only that Session and keeps the settings you omit.

## Approve Actions

If a request needs approval, inspect the reported Action first:

```sh
rui action inspect --store "$STORE" --session "$SESSION" --action ACTION_ID
```

After you review the command, allow it once:

```sh
rui action allow --store "$STORE" --session "$SESSION" --action ACTION_ID
```

To reject it, run `rui action deny` with the same options.

## Recover from a lost reply

If a command loses its reply or exits nonzero, Rui may still have accepted the work. To check, run `rui request inspect HANDLE`. To resend the same saved request, run `rui request recover HANDLE`. Do not submit a new Message to find out whether the first one arrived.

## Agents calling Rui

Agents use the same commands from their Bash tool. Bash runs the `rui` installation that runs the Host. It gets the Host's `HOME` but none of the Host's other environment, such as credentials.

Each model request tells the agent its own bare ID. Bash receives that ID as `RUI_ADDRESS`, its Store as `RUI_STORE`, and private sender authority. To get an answer from another Session, an agent puts its own ID in the Message. The other Session replies with an ordinary `session send --to ID`.
