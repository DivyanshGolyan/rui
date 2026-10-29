# Running the Host

The **Host** is the background process that runs work. The **Store** is its private directory of saved state.

Commands pick a Store in this order: `--store`, your saved default, then `$HOME/.local/share/rui/store`. `rui defaults configure --store PATH` saves that default for every directory and names it on stderr. In scripts, pass `--store` so the destination never depends on saved defaults.

## Start and check the Host

```sh
rui host status
rui host start
```

`rui` starts a Host when it needs one. `host start` starts one explicitly, or connects to a running Host without changing its settings. It prints where the diagnostic log is.

If startup times out, run `host status` and read the diagnostic log. A timeout does not prove that the Host stopped. Rui installs no OS service and never restarts a crashed Host.

### Capacity and file limits

A new Host can run 100 executions at once. `rui host start --active-capacity 8` starts a new Host with a different capacity. A running Host keeps the capacity it started with, even after you upgrade Rui. If you pass a different `--active-capacity` while a Host is running, `host start` connects to that Host unchanged and says so on stderr. To change the capacity, stop the Host and start it again.

`host status` reports the capacity as `active_capacity`, the slots in use as `custody_occupied` (running work and cleanup that still holds a slot), and the Unix second the Host started as `started_at`.

The Host raises its open-file soft limit as far as the hard limit allows. If that is still too low, the Host accepts fewer simultaneous client requests but keeps all 100 executions. If the hard limit is too low even for that, startup fails and names the limit to raise.

## Stop the Host

`host stop` interrupts all work in the selected Store:

```sh
rui host stop
```

An acknowledgment means Rui accepted the shutdown request. Cleanup can still be running. If the reply is lost, run the retry command that Rui printed. It targets the same Host, so it cannot stop a replacement.

## Run in the foreground

```sh
rui host serve --store PATH --codex
rui host serve --store PATH --active-capacity 8 --codex
```

Without `--codex` or a development endpoint, `host serve` makes no model requests. The [Host reference](../ARCHITECTURE.md#platforms-and-server-lifetime) states the startup and shutdown guarantees.

## Export a failed model response

When a model request fails after the provider sent bytes, the Host keeps those bytes in the Store's private `diagnostics/failed-responses/` directory. It never uploads them. They can contain private conversation content.

Each response keeps at most 16 MiB, and each Store keeps at most 64 MiB, deleting the oldest first. A metadata file records the failure reason, length, SHA-256 and whether the copy is `complete`, `partial` or `omitted`.

To export one, find its Operation and Attempt with `rui session inspect --profile full`. Then, with a compatible Host serving the Store, export the metadata and the body separately:

```sh
umask 077
rui session inspect --store "$STORE" --session SESSION_REF \
	--operation OPERATION_ID --attempt ATTEMPT_NUMBER --failed-response metadata > response.json
rui session inspect --store "$STORE" --session SESSION_REF \
	--operation OPERATION_ID --attempt ATTEMPT_NUMBER --failed-response body > response.body
```

Each command writes the exact stored bytes to stdout. Always redirect the body to a file, because it can contain binary bytes and terminal controls.

Before you use a file, check its command's exit status. A failed command writes its error to stderr and can leave a partial file.

- A `partial` body exports only the kept prefix.
- An `omitted` body fails, but its metadata still exports.
- A Session, Operation or Attempt that was evicted, never kept, or does not match fails with no payload.
- The two reads are independent, so eviction between them can make the second one fail.

Inspection never starts a Host, contacts a provider, changes saved work or refreshes retention.
