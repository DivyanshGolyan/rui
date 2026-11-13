# Running the Host

The **Host** is the background process that runs work.
The **Store** is its private directory of saved state.

Commands pick a Store in this order: `--store`, your saved default, then `$HOME/.local/share/rui/store`.
`rui defaults configure --store PATH` saves that default for every directory and names it on stderr.
In scripts, pass `--store` so the destination never depends on saved defaults.

## Start and check the Host

```sh
rui host status
rui host start
```

`rui` starts a Host when it needs one.
`host start` starts one explicitly, or connects to a running Host without changing its settings.
It prints where the diagnostic log is.

If startup times out, run `host status` and read the diagnostic log.
A timeout does not prove that the Host stopped.
Rui installs no OS service and never restarts a crashed Host.

## Upgrade and activation

Run `rui --version` to see the selected build.
`rui upgrade --check` inspects the latest published stable release without installing it or starting a Host.
`rui upgrade` updates an eligible released managed installation under `~/.local` to that release.
It uses the same restart-all core as `rui host restart --all`: every running same-user Host it can safely activate is restarted, one at a time. The read-only check names the discovered Stores and Host count, including unsupported Hosts and their reasons.
`--store` selects the client context, not the restart scope. With an eligible installation and no running Hosts, Upgrade only installs; it starts no absent Store. Discovery runs again after publication to include Hosts started during preparation.
The Version row in the terminal's app settings starts the same run from the overview or with a conversation open, on the status row: it installs a found release at once, and Esc cancels until publishing starts.
After installing, it redraws in the new Rui and returns to the same place with unsent drafts intact.
Restart keeps the current Store even if saved defaults changed, and restores existing work without requiring fresh-session preferences or local sign-in.
That also resolves the old client's protocol/restart hold; a failed or unconfirmed Host activation still needs its recovery instructions.
If Rui must show recovery or repair instructions, follow the departure guidance instead; see the [Upgrade contract](../ARCHITECTURE.md#store-format-and-upgrades).

A selected source build or managed build with unknown release identity is refused before installation.
The [standalone release installer](../README.md#install) can deliberately convert it to a release.
An unmanaged, custom, or packaged destination belongs to its application or package manager.
Source and release installers run `rui host restart --all` after publishing.
You can run it again yourself:

```sh
rui host restart --all
```

`--all` is required; this command does not accept `--store` yet.
It discovers this user's running Hosts through their private runtime sockets and restarts eligible Hosts one at a time on the selected installed build, preserving capacity and saved work.
Each line names the Store and reports restarted, already current, left running with a reason, or failure with recovery instructions; a total follows.
Socket discovery retries transient connection refusal for up to 200 ms inside its observation deadline.
A standard SQLite Host publishes a private same-owner `<hash>.store` routing hint beside its socket under the Store lease, atomically before binding; clean retirement removes it after the socket, while a crash leaves it.
For an unreachable socket, discovery skips silently only when `platform` validates the hint and exact socket mapping and observes the Store lease free. It deletes nothing.
A held or inaccessible lease, absent/untrusted hint (including an older Host), or connected unreadable peer is reported as unconfirmed and counted as failed, with the socket path and recovery advice. The hint is not liveness state or activation authority.
It does not reclaim sockets or infer absence from failed transport.
No running Hosts prints `No running Hosts.` and starts nothing.
A newer Host is not downgraded; unsupported, application-owned and unconfirmed-ownership launches are left running with a reason.
A verified exact pinned launch with a different protocol is reported as restarted with advice to use the selected Rui client, never as ordinary Host readiness.
A failed or unconfirmed restart returns an operational caller error; installer activation failures print a note without failing the completed install.
The selected build must report a verified release version; an unversioned source target cannot be activated by the existing lifecycle and is reported without stopping Hosts.

The Upgrade restart may interrupt work in all Sessions across every affected Store, not only the client's selected Store.
A running Host keeps its configured capacity through the restart.
Installation and activation are reported separately.
Unsupported or application-owned Hosts remain running with an explained successful skip. A failed or unconfirmed Host restart returns `host_restart_failed` (exit 6) after the installation receipt; the binary upgrade is not rolled back.
Automatic activation supports released and source managed `host serve` launches whose public settings can be preserved and whose executable reports a verified numeric version.
Unknown managed builds, foreign executables, application-owned `--settings`, hidden-option, and relative configuration-path launches are not paused.
This does not make a selected source installation eligible for `rui upgrade`; Upgrade still requires a selected managed release.
When that selection is released but its running Host came from a managed source build, the usual version comparison applies: a newer Host stays running without a downgrade; an equal or older Host can restart on the pinned release.
Private launch environment is observed only in memory and wiped after the operation.
Upgrade waits for the observed Host's lease to retire and checks the pinned target's readiness before reporting activation.

Updates keep saved work and sign-in.
Retained earlier builds are not an unconditional rollback after a Store migration.
The target build's schema determines compatibility, not version punctuation.
At Host startup, Rui backs up and migrates supported SQLite formats.
MySQL schema changes are operator-owned.
For MySQL TCP URLs, the only query option is `ssl-ca=/absolute/path/to/ca.pem` (the path may be percent-encoded), which replaces system trust with that PEM bundle alone; socket URLs and verification-disabling options are refused.
If target compatibility facts are unavailable, compatibility is unknown until startup validates it.
See [Store format and upgrades](../ARCHITECTURE.md#store-format-and-upgrades) for the contract.

### Capacity and file limits

A new Host can run 100 executions at once.
`rui host start --active-capacity 8` starts a new Host with a different capacity.
A running Host keeps its configured capacity through an Upgrade restart.
If you pass a different `--active-capacity` while a Host is running, `host start` connects to that Host unchanged and says so on stderr.
To change the capacity, pause the Host and start it again.

`host status` reports the capacity as `active_capacity`, the slots in use as `custody_occupied` (running work and cleanup that still holds a slot), and the Unix second the Host started as `started_at`.

The Host raises its open-file soft limit as far as the hard limit allows.
If that is still too low, the Host accepts fewer simultaneous client requests but keeps all 100 executions.
If the hard limit is too low even for that, startup fails and names the limit to raise.

## Pause the Host

`host pause` shuts the Host down and interrupts all work in the selected Store:

```sh
rui host pause
```

Paused work is not cancelled.
When a Host starts again, including the one the next `rui` starts, each Session picks up where its saved work left off.
A Bash command cut off by the pause is never run again automatically.
To end work for good, stop its Session with `rui session stop --session ID` or Ctrl-X in the overview.
To stop every Session that Ctrl-X could stop, run `rui session stop --all`.
It needs a running Host, so to cancel the work of a paused Host, start it with `rui host start` and run `rui session stop --all` right away; work resumes in between.
Each stop is its own saved request with its own reply line, so a lost reply is recovered with `rui request recover`, as for a single stop.

An acknowledgment means Rui accepted the shutdown request.
Cleanup can still be running.
If the reply is lost, run the retry command that Rui printed.
It targets the same Host, so it cannot stop a replacement.

## Run in the foreground

```sh
rui host serve --store PATH --provider codex
rui host serve --store PATH --provider codex --provider openai
rui host serve --store PATH --active-capacity 8 --provider codex
```

Each `--provider LABEL` serves one built-in provider at its own endpoint with its own credential: `codex` is ChatGPT sign-in (`rui auth login codex`), and `openai` is an OpenAI API key (`rui auth login openai`, which reads the key from stdin).
A Host reads the key once when it starts and refuses to start `openai` without one, so after saving a key, pause a running Host and start it again to add it.
An auto-started Host serves `openai` whenever a key is saved.
To use an OpenAI-compatible server that speaks the Responses API, such as Azure OpenAI or a company proxy, set `RUI_OPENAI_BASE_URL` to its `https://` base URL (for example `https://example.openai.azure.com/openai/v1`) in the environment that starts the Host; the key is then sent only to that URL's `/responses` and `/models`.
A Host with a key reads the key's model list from `/models` once as it starts, for the model picker; if that fails, the picker shows the models Rui knows.
An auto-started Host takes it from the command that starts it, and a running Host keeps the URL it started with.
An invalid one stops `host serve --provider openai`; an auto-started Host reports it and starts serving Codex only.
Sessions of a provider the Host does not serve wait until a Host that serves it starts.
Without `--provider` or a development endpoint, `host serve` makes no model requests.
The [Host reference](../ARCHITECTURE.md#platforms-and-server-lifetime) states the startup and shutdown guarantees.

## Export a failed model response

When a model request fails after the provider sent bytes, the Host keeps those bytes in the Store's private `diagnostics/failed-responses/` directory.
It never uploads them.
They can contain private conversation content.

Each response keeps at most 16 MiB, and each Store keeps at most 64 MiB, deleting the oldest first.
A metadata file records the failure reason, length, SHA-256 and whether the copy is `complete`, `partial` or `omitted`.

To export one, find its Operation and Attempt with `rui session inspect --profile full`.
Then, with a compatible Host serving the Store, export the metadata and the body separately:

```sh
umask 077
rui session inspect --store "$STORE" --session SESSION_REF \
	--operation OPERATION_ID --attempt ATTEMPT_NUMBER --failed-response metadata > response.json
rui session inspect --store "$STORE" --session SESSION_REF \
	--operation OPERATION_ID --attempt ATTEMPT_NUMBER --failed-response body > response.body
```

Each command writes the exact stored bytes to stdout.
Always redirect the body to a file, because it can contain binary bytes and terminal controls.

Before you use a file, check its command's exit status.
A failed command writes its error to stderr and can leave a partial file.

- A `partial` body exports only the kept prefix.
- An `omitted` body fails, but its metadata still exports.
- A Session, Operation or Attempt that was evicted, never kept, or does not match fails with no payload.
- The two reads are independent, so eviction between them can make the second one fail.

Inspection never starts a Host, contacts a provider, changes saved work or refreshes retention.
