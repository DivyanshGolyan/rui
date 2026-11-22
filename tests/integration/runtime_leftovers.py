"""Host sockets that test fixtures leave behind (#1855).

A fixture Host that is killed keeps its socket and Store hint in /tmp/rui-<uid>.
Rui never reclaims a socket during discovery, and the fixture then deletes its
temporary Store, so nothing removes them: on one Mac 2,500 piled up and every
`rui upgrade` listed them. A leftover is a socket that refuses connections and
whose `.store` hint names a directory that no longer exists, so no Host can
serve it. Live Hosts accept, and a Host's own Store directory still exists.

`platform.zig` owns this layout (`runtimeDirectory`, `storeHintPath`,
`socketStoreIsUnowned`); upgrade_integration's crashed-Host case checks this
reader against a real crashed Host, so a layout change fails there.
"""
import errno
import os
import pathlib

import os_semantics


# Tests of the harness itself point this at their own temporary directory.
OVERRIDE = "RUI_TEST_LEFTOVER_RUNTIME"


def runtime():
    return pathlib.Path(os.environ.get(OVERRIDE) or f"/tmp/rui-{os.geteuid()}")


def leftovers(directory=None):
    """Sorted leftover sockets as (socket path, hinted Store directory)."""
    directory = directory or runtime()
    found = []
    try:
        candidates = sorted(directory.glob("*.sock"))
    except FileNotFoundError:
        return found
    for path in candidates:
        try:
            store = path.with_suffix(".store").read_text()
        except (FileNotFoundError, UnicodeDecodeError):
            continue
        if not store.startswith("/") or os.path.lexists(store) or answers(path):
            continue
        found.append((path, store))
    return found


def answers(path):
    """True unless the socket is provably dead: refused or absent. Any other probe failure
    (timeout, permission, ...) cannot prove the socket dead, so it counts as live and is kept.
    A path at or over the limit raises UnixPathTooLong before any connect (os_semantics)."""
    with os_semantics.unix_stream() as probe:
        probe.settimeout(1)
        try:
            probe.connect(str(path))
        except OSError as error:
            return error.errno not in (errno.ECONNREFUSED, errno.ENOENT)
    return True


def remove(found):
    for path, _ in found:
        for owned in (path, path.with_suffix(".store")):
            try:
                owned.unlink()
            except FileNotFoundError:
                pass


def retire(store, directory=None):
    """Remove the leftover sockets whose hint names `store`; return what was removed.

    A fixture that kills its Host calls this once the Host is reaped, so the
    socket and hint go before the Store is deleted. An accepting socket is a
    live Host (or a successor on the same path) and stays.
    """
    named = str(store)
    return _retire(lambda hinted: hinted == named, directory)


def hinted(store, directory=None):
    """Whether any socket's hint still names `store`."""
    named = str(store)
    return _matching(lambda value: value == named, directory)


def retire_under(root, directory=None):
    """Like retire, for every Store under the directory `root` (a shell fixture's state)."""
    prefix = str(root).rstrip("/") + "/"
    return _retire(lambda hinted: hinted.startswith(prefix), directory)


def _matching(names, directory):
    """Whether a socket hinted to a matching Store still exists."""
    directory = directory or runtime()
    try:
        candidates = sorted(directory.glob("*.sock"))
    except FileNotFoundError:
        return False
    for path in candidates:
        try:
            if names(path.with_suffix(".store").read_text()):
                return True
        except (FileNotFoundError, UnicodeDecodeError):
            continue
    return False


def _retire(names, directory):
    directory = directory or runtime()
    found = []
    try:
        candidates = sorted(directory.glob("*.sock"))
    except FileNotFoundError:
        return found
    for path in candidates:
        try:
            hinted = path.with_suffix(".store").read_text()
        except (FileNotFoundError, UnicodeDecodeError):
            continue
        if names(hinted) and not answers(path):
            found.append((path, hinted))
    remove(found)
    return found


def sweep(directory=None):
    """Remove every leftover; return what was removed."""
    found = leftovers(directory)
    remove(found)
    return found


def describe(found):
    return "; ".join(f"{path.name} (Store {store})" for path, store in found)
