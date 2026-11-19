"""Only a refusing socket whose hinted Store is gone is a fixture leftover (#1855).

Disposal through host_process.stop_process and host_launch_fixture.forced_crash_cleanup
retires the Host's own socket and hint, so a batch that kills Hosts leaves no leftovers.
"""
import importlib.util
import os
import pathlib
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests/integration"))
import runtime_leftovers  # noqa: E402

SPEC = importlib.util.spec_from_file_location("host_process", ROOT / "tests/integration/host_process.py")
HOST = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HOST)

# A stand-in Host: listens on <runtime>/x.sock, writes the .store hint, and prints the
# ready line that start_ready_process reads. Mode "early" leaves its socket and hint
# behind and exits before ready.
FAKE_HOST = r"""
import os, pathlib, signal, socket, sys
store = sys.argv[sys.argv.index("--store") + 1]
mode = sys.argv[sys.argv.index("--mode") + 1]
path = pathlib.Path(os.environ["RUI_TEST_LEFTOVER_RUNTIME"]) / "x.sock"
if path.exists():
    path.unlink()
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(str(path))
path.with_suffix(".store").write_text(store)
if mode == "early":
    server.close()
    sys.exit(1)
server.listen(1)
print(f"ready instance=0 store={store} socket={path}", flush=True)
signal.pause()
"""


class RuntimeLeftovers(unittest.TestCase):
    def test_sweep_removes_only_dead_sockets_with_a_missing_store(self):
        with tempfile.TemporaryDirectory(dir="/tmp") as raw:
            root = pathlib.Path(raw)
            store = root / "store"
            store.mkdir()
            listening = []

            def make(name, hint, listen):
                path = root / f"{name}.sock"
                server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                server.bind(str(path))
                if listen:
                    server.listen(1)
                    listening.append(server)
                else:
                    server.close()
                if hint is not None:
                    path.with_suffix(".store").write_text(hint)
                return path

            dead = make("dead", str(root / "deleted-store"), listen=False)
            live = make("live", str(root / "deleted-store"), listen=True)
            owned = make("owned", str(store), listen=False)
            hintless = make("hintless", None, listen=False)
            relative = make("relative", "relative/store", listen=False)
            try:
                removed = runtime_leftovers.sweep(root)
            finally:
                for server in listening:
                    server.close()
            self.assertEqual([(dead, str(root / "deleted-store"))], removed)
            self.assertFalse(dead.exists() or dead.with_suffix(".store").exists())
            for kept in (live, owned, hintless, relative):
                self.assertTrue(kept.exists(), kept)
            self.assertEqual([], runtime_leftovers.leftovers(root / "missing"))

    def test_retire_removes_only_a_refusing_socket_hinted_to_the_store(self):
        with tempfile.TemporaryDirectory(dir="/tmp") as raw:
            root = pathlib.Path(raw)
            store = root / "store"
            other = root / "other-store"
            listening = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                matching = root / "matching.sock"
                refusing = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                refusing.bind(str(matching))
                refusing.close()
                matching.with_suffix(".store").write_text(str(store))

                different = root / "different.sock"
                refusing = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                refusing.bind(str(different))
                refusing.close()
                different.with_suffix(".store").write_text(str(other))

                accepting = root / "accepting.sock"
                listening.bind(str(accepting))
                listening.listen(1)
                accepting.with_suffix(".store").write_text(str(store))

                removed = runtime_leftovers.retire(store, root)
                self.assertEqual([(matching, str(store))], removed)
                self.assertFalse(matching.exists() or matching.with_suffix(".store").exists())
                self.assertTrue(different.exists() and different.with_suffix(".store").exists())
                self.assertTrue(accepting.exists() and accepting.with_suffix(".store").exists())
            finally:
                listening.close()


class HostDisposal(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir="/tmp")
        self.addCleanup(self.tmp.cleanup)
        self.runtime = pathlib.Path(self.tmp.name) / "runtime"
        self.runtime.mkdir()
        self.script = pathlib.Path(self.tmp.name) / "fake_host.py"
        self.script.write_text(FAKE_HOST)
        previous = os.environ.get(runtime_leftovers.OVERRIDE)
        os.environ[runtime_leftovers.OVERRIDE] = str(self.runtime)
        self.addCleanup(lambda: os.environ.pop(runtime_leftovers.OVERRIDE) if previous is None
                        else os.environ.__setitem__(runtime_leftovers.OVERRIDE, previous))
        self.env = dict(os.environ)

    def store(self, name):
        path = pathlib.Path(self.tmp.name) / name
        path.mkdir()
        return path.resolve()

    def start(self, store, mode="serve"):
        args = [sys.executable, str(self.script), "--store", str(store), "--mode", mode]
        return HOST.start_ready_process(args, env=self.env, isolate_providers=False)[0]

    def assert_no_leftovers(self):
        self.assertEqual([], runtime_leftovers.leftovers(self.runtime))

    def test_live_host_is_retired_by_stop_process(self):
        store = self.store("store")
        process = self.start(store)
        HOST.stop_process(process)
        shutil.rmtree(store)
        self.assertFalse((self.runtime / "x.sock").exists())
        self.assert_no_leftovers()

    def test_killed_host_is_retired_by_stop_process(self):
        store = self.store("store")
        process = self.start(store)
        process.kill()
        process.wait(timeout=10)
        HOST.stop_process(process)
        shutil.rmtree(store)
        self.assertFalse((self.runtime / "x.sock").exists())
        self.assert_no_leftovers()

    def test_successor_on_the_same_socket_path_is_kept(self):
        old_store = self.store("old")
        new_store = self.store("new")
        old = self.start(old_store)
        successor = self.start(new_store)
        try:
            HOST.stop_process(old)
            shutil.rmtree(old_store)
            self.assertTrue((self.runtime / "x.sock").exists())
            self.assertEqual(str(new_store), (self.runtime / "x.store").read_text())
            self.assert_no_leftovers()
        finally:
            HOST.stop_process(successor)
        shutil.rmtree(new_store)
        self.assert_no_leftovers()

    def test_hint_for_a_different_store_is_kept(self):
        store = self.store("store")
        other = pathlib.Path(self.tmp.name) / "other-store"
        process = self.start(store)
        (self.runtime / "x.store").write_text(str(other))
        HOST.stop_process(process)
        shutil.rmtree(store)
        self.assertEqual([(self.runtime / "x.sock", str(other))], runtime_leftovers.leftovers(self.runtime))
        runtime_leftovers.remove(runtime_leftovers.leftovers(self.runtime))

    def test_host_that_exits_before_ready_is_retired_through_its_store_argument(self):
        store = self.store("store")
        with self.assertRaises(HOST.HostStartError):
            self.start(store, mode="early")
        self.assertFalse((self.runtime / "x.sock").exists())
        shutil.rmtree(store)
        self.assert_no_leftovers()


if __name__ == "__main__":
    unittest.main()
