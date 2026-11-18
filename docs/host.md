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
If Rui must show recovery or repair instructions, follow the departure guidance instead; see the [Upgrade contract](contracts/store.md#store-format-and-upgrades).

A selected source build or managed build with unknown release identity is refused before installation.
The [standalone release installer](../README.md#install) can deliberately convert it to a release.
An unmanaged, custom, or packaged destination belongs to its application or package manager.
Source and release installers run `rui host restart --all` after publishing.
You can run it again yourself:

```sh
rui host restart --all
```

`--all` is required; this command does not accept `--store` yet.
It discovers this user's running Hosts through private runtime sockets and same-user process hints, authenticates each resolved socket peer, and restarts eligible Hosts one at a time on the selected installed build, preserving capacity and saved work. Process hints are not stop authority; saved DIR placement finds nested MySQL and moved interfaces without a registry.
Each line names the Host directory (independently of its Store identity) and reports restarted, already current, left running with a reason, or failure with recovery instructions; a total follows.
Socket discovery retries transient connection refusal for up to 200 ms inside its observation deadline.
A standard SQLite Host publishes a private same-owner `<hash>.store` routing hint beside its socket under the Store lease, atomically before binding; clean retirement removes it after the socket, while a crash leaves it.
For an unreachable socket, discovery skips silently only when `platform` validates the hint and exact socket mapping and observes the Store lease free. It deletes nothing.
A held or inaccessible lease, absent/untrusted hint (including an older Host), or connected unreadable peer is reported as unconfirmed and counted as failed, with the socket path and recovery advice. The hint is not liveness state or activation authority.
It does not reclaim sockets or infer absence from failed transport.
No running Hosts prints `No running Hosts.` and starts nothing.
A newer Host is not downgraded; unsupported, application-owned and unconfirmed-ownership launches are left running with a reason.
Success requires readiness on DIR's socket, a different instance from the stopped Host, and the answering managed executable's target release version. A concurrent starter of that version may win; it need not be our child or the selected executable path. If only the target client can read the new wire, its public status is bracketed by authenticated peer generations and the result advises using that client; incompatible transport alone is never success.
A failed or unconfirmed restart returns an operational caller error; installer activation failures print a note without failing the completed install.
The selected build must report a verified release version; an unversioned source target cannot be activated by the existing lifecycle and is reported without stopping Hosts.

The Upgrade restart may interrupt work in all Sessions across every affected Store, not only the client's selected Store.
A running Host keeps its configured capacity through the restart.
A Host that an earlier release started with its retired flags (`--provider`, `--active-capacity` and the others) restarts with the `--set` assignments that replace them, serving the same providers.
Installation and activation are reported separately.
Unsupported or application-owned Hosts remain running with an explained successful skip. A failed or unconfirmed Host restart returns `host_restart_failed` (exit 6) after the installation receipt; the binary upgrade is not rolled back.
Automatic activation supports released and source managed `host serve` launches whose public settings can be preserved and whose executable reports a verified numeric version.
Unknown managed builds, foreign executables and hidden-option launches are not paused. For admission, capability and source replay before retirement, see the [detached launch contract](contracts/host.md#detached-launch-admission). Stdin documents/lifetime, relative paths and refused documents leave the Host running and count as failed (exit 6), rather than an unsupported successful skip.
This does not make a selected source installation eligible for `rui upgrade`; Upgrade still requires a selected managed release.
When that selection is released but its running Host came from a managed source build, the usual version comparison applies: a newer Host stays running without a downgrade; an equal or older Host can restart on the pinned release.
Check, start and status receive the same captured Host environment with cwd `/` and null stdin. Snapshots, normalized source buffers, environment copies and subprocess captures are kept only in memory and wiped after the operation.
Saved moved SQLite storage, explicit interfaces and MySQL use the shared starter. DIR is retained separately from wire Store identity; unsaved nondefault placement remains subject to the ordinary detached starter's discoverability rule.
After exact-instance stop, upgrade waits for the old process generation to retire (an unreaped zombie is retired) and its runtime/Store lease to retire before starting. A concurrent new owner is never stopped. Released v0.75.0 is refused as a target before stop because its check admits stdin lifetime while its detached starter refuses it; older targets without `settings --check` also leave the old Host running. Intentional source builds are not labelled from version text alone.

Updates keep saved work and sign-in.
Retained earlier builds are not an unconditional rollback after a Store migration.
The target build's schema determines compatibility, not version punctuation.
At Host startup, Rui backs up and migrates supported SQLite formats.
MySQL schema changes are operator-owned.
For MySQL TCP URLs, the only query option is `ssl-ca=/absolute/path/to/ca.pem` (the path may be percent-encoded), which replaces system trust with that PEM bundle alone; socket URLs and verification-disabling options are refused.
If target compatibility facts are unavailable, compatibility is unknown until startup validates it.
See [Store format and upgrades](contracts/store.md#store-format-and-upgrades) for the contract.

### Capacity and file limits

A new Host can run 100 executions at once.
`rui host start --set execution.activeCapacity=8` starts a new Host with a different capacity.
A running Host keeps its configured capacity through an Upgrade restart.
If you pass `--set` or `--settings` while a Host is running, or another start wins the race to launch one, `host start` connects to that Host unchanged and says so on stderr.
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

## Save Host settings

```sh
rui host set --store PATH execution.activeCapacity 8
rui host settings --store PATH
rui host unset --store PATH execution.activeCapacity
rui host settings --paths
rui host settings --store PATH --check
```

Settings are saved sparsely in `PATH/host.json`, privately and atomically.
The settings document sets a new Host: `host_start` reads and composes its sources for bare `rui`, `rui host start` and `rui host serve`. Every client can inspect available leaves with `rui host settings --paths`, save them with `rui host set`, and check admission with `rui host settings --check`.
The order is defaults, saved settings, `--settings FILE|-`, then repeatable `--set PATH=VALUE` assignments in order.
Use `rui host set --store PATH SETTING @FILE` to read a JSON value from a file.
`settings` fills in defaults and shows secret sources, not secret bytes; saved literal secrets are refused.
`unset` removes the saved assignment, restoring its default when no later source overrides it.

Credential-location defaults for client and Host share `src/credential_location.zig`: `RUI_OPENAI_KEY_FILE`, `RUI_CODEX_CREDENTIAL_FILE` and `RUI_CHATGPT_CREDENTIAL_FILE` select absolute paths; a provider credential leaf overrides its default. Without a variable, the default is under `~/.config/rui/`.

Retired environment inputs are refused by name: replace `RUI_OPENAI_BASE_URL` with `providers.openai.endpoint`, and `RUI_TEST_MODELS_DEV_URL` with `models.catalogUrl`. Hidden Host `--test-*-fixture-endpoint` flags are gone; fixture identity derives from the loopback endpoint and transport trust. The `providers.chatgpt.tokenEndpoint` leaf supplies the loopback token URL required for an authenticated ChatGPT fixture.

A typed refusal writes the same `rui_start_error` JSON line on stdout for start, save and check. On stderr the respective sentences begin `rui: the Host did not start`, `rui: the setting was not saved`, and `rui: these settings would not start a Host`; a refused detached start emits its refusal once.
`settings --check` checks a detached start without opening or locking a Store: it reads and applies every source, refuses stdin lifetime and unrooted paths, checks saved placement, resolves credentials, anchors and seals. Pass absolute `--settings FILE`, `@FILE` and path/secret sources; unlike a newly typed `host start`, this check does not rebase argv. It does not prove database availability or lock acquisition.
Changes apply to the next Host; they do not reconfigure a running one.
`rui host start` takes `--settings FILE` but not `-`, because a started Host has no stdin; pass a document on stdin with `rui host serve --settings -`.
Clients given `--store PATH` read that directory's saved placement, including MySQL, a moved `interface.dir`, or a different `store.sqlite.dir`.
Pause the Host before changing placement: directory-based clients immediately use the saved location, while a running Host keeps its original settings.
Directory-based lookup checks an existing explicit interface directory with the same private-directory admission as legacy MySQL lookup before connecting; missing saved interface directories remain startable.
Save Store and interface placement with `rui host set`; a differing placement supplied only through `host start --settings` or `--set` is refused because a later client cannot see it.
Other one-off settings still apply to a new Host. Foreground `host serve` permits unsaved placement, but directory-based clients need the same placement saved.
New generated and explicit request captures retain the selected Host directory in a private `.routing` companion, separately from the immutable request's Store identity. HANDLE-based recover, inspect, wait and read-result rediscover that directory's current saved placement and refuse if it identifies a different Store. Legacy opaque MySQL selection retains its runtime hint. Keep the companion with the request; older records without one retain their existing identity-based lookup.
A started Host runs in `/` without stdin. Relative paths you type on the command line (`--settings FILE`, `@FILE`, and `--set` paths or `file:` sources) are taken from the directory you run the command in.
`rui host set` refuses relative path values before saving. A relative path already saved in `host.json` or written inside a document has no such directory, so bare `rui` and `rui host start` refuse it, as they refuse `interface.lifetime` `stdin`; give an absolute path.
Run such a Host with `rui host serve --store PATH`.

## MySQL

After an operator creates the database and applies `rui store schema --engine mysql`, save a login source and open the TUI:

```sh
export DATABASE_URL='mysql://USER:PASSWORD@HOST:3306/DATABASE'
rui host set --store /absolute/host-dir store.mysql.url env:DATABASE_URL
rui --store /absolute/host-dir
```

The Host resolves `DATABASE_URL`; clients do not read the login bytes.
`rui host start --store /absolute/host-dir` starts it without opening the TUI; Session, request and Host commands use the same `--store /absolute/host-dir`.
Without an explicit interface, MySQL uses a short private per-user directory derived from the canonical Host directory; SQLite keeps its existing short hashed default socket.
Long Host directory names therefore do not hit the explicit interface directory's 94-byte limit.
To choose another interface, save `rui host set --store /absolute/host-dir interface.dir /absolute/private-interface` before starting.
Upgrade stops the exact observed MySQL Host and waits for its process and runtime retirement, then invokes the target starter. Runtime retirement does not prove `GET_LOCK` release: replacement readiness proves its own Store lock acquisition. Database lock/start failures retain their typed start report; other Hosts in the batch are still processed.

The existing foreground and opaque-id form remains supported: start `rui host serve --store /absolute/host-dir` with its settings, then use `RUI_RUNTIME_DIR=/absolute/interface rui --store STOREID`, where `STOREID` comes from Host readiness and the interface is the Host's actual interface directory.
Do not put the login URL in argv. Literal secrets are accepted only in a foreground stdin document.

## Run in the foreground

```sh
rui host serve --store PATH --set 'providers.codex={}'
rui host serve --store PATH --set 'providers.codex={}' --set 'providers.openai={}'
rui host serve --store PATH --set execution.activeCapacity=8 --set 'providers.codex={}'
```

An explicit `providers` setting lists exactly which built-in providers to serve: each `providers.LABEL` assignment adds that provider, while `providers=` with an object replaces the whole set.
Each is served at its own endpoint with its own credential: `codex` is ChatGPT by device code (`rui auth login chatgpt --device-code`), `chatgpt` is ChatGPT in a browser (`rui auth login chatgpt`), and `openai` is an OpenAI API key (`rui auth login openai`, which reads the key from stdin).
A Host reads the key once when it starts and refuses to start `openai` without one, so after saving a key, pause a running Host and start it again to add it.
An auto-started Host serves `openai` whenever a key is saved.
To use an OpenAI-compatible server that speaks the Responses API, such as Azure OpenAI or a company proxy, set `providers.openai.endpoint` to its `https://` Responses URL (for example `https://example.openai.azure.com/openai/v1/responses`) with `rui host set --store DIR providers.openai.endpoint URL`; the key is then sent only to that endpoint and its sibling `/models`.
A Host with a key reads the key's model list from `/models` as it starts and again each time the model picker asks; if that fails, the picker shows the models Rui knows.
A Host serving a ChatGPT plan sign-in (`chatgpt`) reads that plan's list the same way, from `https://api.openai.com/v1/models`; without a usable sign-in it does not ask, and the picker shows the models Rui knows.
The endpoint comes from the [Host settings](#save-host-settings); a running Host keeps the URL it started with.
An invalid one stops a Host explicitly configured to serve `openai`; with automatic provider selection, the Host reports it and starts serving its ChatGPT sign-ins only.
Sessions of a provider the Host does not serve wait until a Host that serves it starts.
Without a `providers` setting, every start path uses automatic provider selection: device-code sign-in is served even while signed out, browser sign-in when its credential is usable, and OpenAI when its key is usable. To serve no model providers, pass `--set 'providers={}'`.
The [Host reference](contracts/host.md#platforms-and-server-lifetime) states the startup and shutdown guarantees.

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
