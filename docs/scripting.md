# Using Rui from scripts and agents

Scripts and agents use one-shot commands grouped by resource: `session`, `request`, `action`, `host`, `defaults` and `auth`.
`rui RESOURCE --help` and `rui RESOURCE COMMAND --help` describe the installed version's exact options.
Help needs no Host or credentials.

Output follows three rules:

- Mutation receipts and metadata are JSON on stdout.
- `.context.session` is the Session ID and `.context.key` is the request handle in mutation receipts.
- Recovery notices and diagnostics go to stderr.

## Upgrade the standalone client

`rui upgrade --check` inspects the latest published stable release without installing or starting a Host.
`rui upgrade` installs it and conditionally restarts an already-running supported Host for the selected Store, interrupting work across that Store's Sessions.
If no Host is running it only installs; installation and activation have separate outcomes, and unsupported or application-owned launches are not blindly stopped.
The installer's defaults-selected Store probe is not necessarily the explicitly selected active Store.
Manual source and release installers remain install-only.

## Start a Session

One-shot commands never start a Host or sign in.
Start the Host first:

```sh
STORE="$HOME/.local/share/rui/store"
rui host start --store "$STORE"
RECEIPT=$(printf '%s' 'Investigate the failing test' | rui session start --store "$STORE" \
	--workspace "$PWD" --provider codex --model gpt-6-luna --permission-mode ask)
SESSION=$(printf '%s' "$RECEIPT" | jq -r .context.session)
HANDLE=$(printf '%s' "$RECEIPT" | jq -r .context.key)
```

`session start` creates the Session and admits its first Message in one transaction.
The JSON receipt confirms admission, not a finished answer.
Its start-only `configuration` member reports the resolved provider, model and effective reasoning effort.
`configuration.effort_source` is `flag` when `--reasoning-effort` was given, `saved` when a compatible saved override was selected, or `model_default` otherwise.
The effective effort falls back to the catalog default, or null for an unlisted model.
An ID is exactly six random lowercase Crockford base32 characters (`0123456789abcdefghjkmnpqrstvwxyz`), such as `k7m2qx`.
Creation settings you omit come from the current directory and your saved defaults.

## Send Messages and read results

```sh
printf '%s' 'Also check the error path' | rui session send --store "$STORE" --to "$SESSION"
rui request inspect SAVED_HANDLE
rui request read-result SAVED_HANDLE
```

`session start` and `session send` return the handle in `.context.key` and announce it on stderr.
Use it in place of `SAVED_HANDLE`.
Both commands return once Rui admits the Message, not when the work finishes.

- `request inspect` reports the Message's current state once.
  To wait, run it again later.
- `request read-result` prints the saved answer only after the work completes, even if the Session has done newer work since.
- `request list` lists saved handles.

If you lose the output of `session start`, recover its original handle to get the allocated ID.
Do not start again with a new key.

The conversation shows commentary and the final answer as separate assistant messages, in the provider's stream order around tool calls.
For a completed Message, `request read-result` returns only the final answer; a skill refusal or catalog reload instead returns its saved diagnostic or acknowledgement.
For responses whose messages have no phase, it returns the last assistant message.

### Addressing

`--to` takes the bare ID, without JSON or a prefix.
A person or script can pass `--store`, or omit it to use the saved default Store.
A peer Session always sends within its own Store, even when `HOME` points elsewhere, and rejects a different `--store`.
An unknown ID fails with `no session k7m2qx in this Store` and creates no work.
Random IDs are not authorization.

### Message text and instructions

Message text comes only from stdin.
Rui keeps the exact UTF-8 bytes, including NULs and trailing newlines.
To send a file, redirect it.
There is no `--text` option, inline text operand or file-valued instructions option.

Set instructions separately:

```sh
rui session configure --store "$STORE" --session "$SESSION" --instructions - < instructions.txt
```

An empty instruction stream clears the instructions.
An empty Message stream sends nothing.
Without `--session`, `session configure` creates a Session with no Message.
With `--session`, it updates only that Session and keeps the settings you omit.

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

If a command loses its reply or exits nonzero, Rui may still have accepted the work.
To check, run `rui request inspect HANDLE`.
To resend the same saved request, run `rui request recover HANDLE`.
Do not submit a new Message to find out whether the first one arrived.

## Agents calling Rui

Agents use the same commands from their Bash tool.
Bash runs in the environment of the terminal that last sent the Session a Message, so a tool you install or a venv you activate is found by the agent's next command after your next Message.
The `rui` installation that runs the Host comes first on `PATH`.
A Message from another agent never replaces your environment, but fills a Session no person has sent to.
Rui keeps the environment only in the Host's memory, never in the Store or request records, and never passes on variables whose names start with `RUI_`.
A recovered request carries the environment of the terminal that recovers it.

An environment over 64 KiB is refused before anything is sent, naming its largest variables; recover the request from a shell with a smaller one.
After a Host restart, or when the Host has dropped a long-unused Session's environment, Bash gets the system's own command directories (on macOS, those listed in `/etc/paths` and `/etc/paths.d`, such as Homebrew's) and the Host's `HOME` until a Message arrives.
Bash never gets the Host's own environment, such as credentials.

Each model request tells the agent its own bare ID.
Bash receives that ID as `RUI_ADDRESS`, its Store as `RUI_STORE`, and private sender authority.
To get an answer from another Session, an agent puts its own ID in the Message.
The other Session replies with an ordinary `session send --to ID`.

An agent can label its own Session: `rui session configure --store "$RUI_STORE" --session "$RUI_ADDRESS" --label "Fix the flaky resize test"`.
`--label ""` clears it.
A Label is display text: it never addresses a Session or reaches the model.

## Watch Sessions

`rui session list` reports each unarchived Session's Label, archive state, work state and when that began, who sent its first Message, and when a person or script last wrote to it.
Use `--archived` for archived Sessions or `--include-archived` for both.
`--all` still selects every Workspace.

To watch many Sessions:

1. List once and keep the reply's `since`.
2. List again with `--since` that value.
   `delta` says `not_modified` (keep your rows), `changed` (replace the rows returned and remove any whose `archive_state` no longer matches your filter) or `full` (a complete listing).
   Every reply carries the next `since`.

Keep the same Workspace and archive filters when you reuse the token.
When you change either filter, discard the old rows and token and start a fresh listing.
The token is opaque and does not survive a Host restart.
A retry falling due changes no row, so compare `due_at_ms` with the clock yourself.
To watch one Session, use `rui session inspect --session ID` rather than a listing.

## Archive a Session

```sh
rui session archive --session ID
rui session unarchive --session ID
```

Archive saves a stop-and-archive intent.
Its accepted reply reports `completion.status` as `pending` or `completed`.
The Session remains unarchived until its selected work has stopped.
Inspect the original request to follow completion, or recover its captured command after a lost reply.
Recovery uses kind `session-archive` for archive and unarchive.

Unarchive restores visibility without starting work.
A new Message to an archived Session also restores it in the admission transaction.
Messages during archive settlement reject as `session_archiving`.
Exact Session reads remain available in every archive state.

## Invoke and reload skills

```sh
rui session send --store "$STORE" --to "$SESSION" --skill NAME
rui session configure --store "$STORE" --session "$SESSION" --reload-skills
```

Invocation uses the Session's advertised skill path and admits the complete current UTF-8 `SKILL.md` plus its absolute path as an ordinary Message, instead of reading stdin.
Reload is an idle-safe mutation: it rescans repository and Host-home `.agents/skills`, appends only catalog changes and returns `answer.skills` as `reloaded` or `unchanged` without scheduling model work.
Do not mix reload with configuration settings or a preset.
Both operations use normal capture keys and `request recover`; replay preserves the original captured result even after files change or disappear.
`request read-result` reads the saved reload acknowledgement or typed skill refusal diagnostic, and never reopens the skill file.
Catalog metadata tracks name, description and winning path only; body-only edits are read by the next fresh invocation without a catalog change.
Explicit `--tools` restrictions remain authoritative; skills grant no tools or permissions and run no scripts on load.
