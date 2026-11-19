"""Host sockets that test fixtures leave behind (#1855).

A fixture Host that is killed keeps its socket and Store hint in /tmp/rui-<uid>.
Rui never reclaims a socket during discovery, and the fixture then deletes its
temporary Store, so nothing removes them: on one Mac 2,500 piled up and every
`rui upgrade` listed them. A leftover is a socket that refuses connections and
whose `.store` hint names a directory that no longer exists, so no Host can
serve it. Live Hosts accept, and a Host's own Store directory still exists.
"""
import errno
import os
import pathlib
import socket


def runtime():
    return pathlib.Path(f"/tmp/rui-{os.geteuid()}")


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
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as probe:
        probe.settimeout(1)
        try:
            probe.connect(str(path))
        except OSError as error:
            if error.errno in (errno.ECONNREFUSED, errno.ENOENT):
                return False
            raise
    return True


def remove(found):
    for path, _ in found:
        for owned in (path, path.with_suffix(".store")):
            try:
                owned.unlink()
            except FileNotFoundError:
                pass


def sweep(directory=None):
    """Remove every leftover; return what was removed."""
    found = leftovers(directory)
    remove(found)
    return found


def describe(found):
    return "; ".join(f"{path.name} (Store {store})" for path, store in found)
