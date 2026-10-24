# Start fresh after a Store format change

A Rui build opens only Stores in its own format. If they differ, Host startup fails and the error names the Store, its format and the format the build supports. Rui never migrates or resets a Store.

Release versions show the format. `0.35.x` releases all open the same Stores, and a `0.36.0` release needs a new Store.

You have two choices:

- Keep using the old Store with a compatible build.
- Back up the old Store and start an empty one.

## Use a compatible build

Earlier builds stay under `~/.local/lib/rui/install.*/bin/rui`. To identify one, run it with `--version`. Older source builds lack `--version`, so read the `revision` file in their `install.*` directory instead.

Set `RUI` to the full `bin/rui` path of a compatible build, and use `"$RUI"` in place of `rui`.

## Back up the old Store and start a new one

1. Close other clients. Until the copy finishes, run no Rui command against the Store except `host status`. Bare `rui` and `rui session resume` can start a Host.

2. Set `STORE` to the exact path printed in the error, and check its Host:

	```sh
	RUI="$HOME/.local/bin/rui"
	STORE="/absolute/path/from/the/error"
	"$RUI" host status --store "$STORE"
	```

3. If a Host is running, let its work finish. Then stop it, because `host stop` interrupts all remaining work:

	```sh
	"$RUI" host stop --store "$STORE"
	"$RUI" host status --store "$STORE"
	```

	Wait until status reports `Host: unavailable`. The stop acknowledgment alone is not enough.

4. Copy the whole stopped Store into a new private directory. Never copy `rui.sqlite3` alone, because committed work can still be only in `rui.sqlite3-wal` after a crash.

	```sh
	BACKUP=$(mktemp -d "$HOME/rui-store-backup.XXXXXX")
	cp -R -p "$STORE" "$BACKUP/store"
	printf 'Backup: %s/store\n' "$BACKUP"
	```

	If the copy fails, stop and fix the failure before you continue.

5. Create an empty Store and make it the default:

	```sh
	FRESH_STORE=$(mktemp -d "$HOME/rui-store.XXXXXX")
	"$RUI" host start --store "$FRESH_STORE"
	"$RUI" defaults configure --store "$FRESH_STORE"
	```

The old Store stays at its original path. Rui does not import its Sessions into the new Store.

## Restore a backup

A Store is bound to its original path. Neither a renamed Store nor a backup opens unchanged at a different path.

To restore a backup, stop every Host that uses the original path. Move aside any Store now at that path, then copy the complete backup there. Read it with a compatible build. To make it your default again, run `"$RUI" defaults configure --store "$STORE"` with that build.

The [Store format policy](../ARCHITECTURE.md#store-format-and-upgrades) describes the plans for migrations.
