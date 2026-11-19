"""Only a refusing socket whose hinted Store is gone is a fixture leftover (#1855).

Disposal through host_process.stop_process and host_launch_fixture.forced_crash_cleanup
retires the Host's own socket and hint, so a batch that kills Hosts leaves no leftovers.
"""
import errno
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

    def test_probe_failure_other_than_refusal_keeps_the_socket(self):
        # A socket path past the AF_UNIX limit makes connect fail with an OSError that has no
        # refusal errno. Nothing proves the socket dead, so it is live and kept.
        with tempfile.TemporaryDirectory(dir="/tmp") as raw:
            root = pathlib.Path(raw) / ("d" * 60) / ("e" * 60)
            root.mkdir(parents=True)
            path = root / "p.sock"
            path.write_text("")
            gone = str(pathlib.Path(raw) / "gone")
            path.with_suffix(".store").write_text(gone)
            self.assertTrue(runtime_leftovers.answers(path))
            self.assertEqual([], runtime_leftovers.leftovers(root))
            self.assertEqual([], runtime_leftovers.retire(gone, root))
            self.assertTrue(path.exists() and path.with_suffix(".store").exists())


class HostDisposal(unittest.TestCase):
    """Every disposal outcome over one domain: which sockets survive, and which hints name a Store
    that is then gone (a leftover). Each row is a scenario; the runner checks the leftovers it returns."""

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
        self.socket = self.runtime / "x.sock"

    def store(self, name):
        path = pathlib.Path(self.tmp.name) / name
        path.mkdir()
        return path.resolve()

    def start(self, store, mode="serve"):
        args = [sys.executable, str(self.script), "--store", str(store), "--mode", mode]
        return HOST.start_ready_process(args, env=self.env, isolate_providers=False)[0]

    def kill(self, process):
        process.kill()
        process.wait(timeout=10)

    def scenario_live_host_stopped(self):
        store = self.store("live")
        HOST.stop_process(self.start(store))
        shutil.rmtree(store)
        return []

    def scenario_killed_then_stopped(self):
        store = self.store("killed")
        process = self.start(store)
        self.kill(process)
        HOST.stop_process(process)
        shutil.rmtree(store)
        return []

    def scenario_killed_stopped_without_retire_keeps_socket_and_hint(self):
        store = self.store("kept")
        process = self.start(store)
        self.kill(process)
        HOST.stop_process(process, retire=False)
        self.assertTrue(self.socket.exists())
        shutil.rmtree(store)
        return [(self.socket, str(store))]

    def scenario_live_host_stopped_without_retire_keeps_socket_and_hint(self):
        store = self.store("kept-live")
        HOST.stop_process(self.start(store), retire=False)
        shutil.rmtree(store)
        return [(self.socket, str(store))]

    def scenario_exits_before_ready_retired_through_store_argument(self):
        store = self.store("early")
        with self.assertRaises(HOST.HostStartError):
            self.start(store, mode="early")
        self.assertFalse(self.socket.exists())
        shutil.rmtree(store)
        return []

    def scenario_same_store_successor_on_the_socket_path_is_kept(self):
        store = self.store("same")
        old = self.start(store)
        self.kill(old)
        successor = self.start(store)
        try:
            HOST.stop_process(old)
            self.assertTrue(self.socket.exists())
            self.assertEqual(str(store), self.socket.with_suffix(".store").read_text())
            self.assertEqual([], runtime_leftovers.leftovers(self.runtime))
        finally:
            HOST.stop_process(successor)
        shutil.rmtree(store)
        return []

    def scenario_foreign_hint_is_kept(self):
        store = self.store("own")
        other = pathlib.Path(self.tmp.name) / "other-store"
        process = self.start(store)
        self.socket.with_suffix(".store").write_text(str(other))
        HOST.stop_process(process)
        shutil.rmtree(store)
        return [(self.socket, str(other))]

    def scenarios(self):
        return [
            ("live host stopped", self.scenario_live_host_stopped),
            ("killed then stopped", self.scenario_killed_then_stopped),
            ("killed, stopped with retire=False keeps socket and hint", self.scenario_killed_stopped_without_retire_keeps_socket_and_hint),
            ("live, stopped with retire=False keeps socket and hint", self.scenario_live_host_stopped_without_retire_keeps_socket_and_hint),
            ("exits before ready, retired through --store", self.scenario_exits_before_ready_retired_through_store_argument),
            ("same-Store successor on the same socket path is kept", self.scenario_same_store_successor_on_the_socket_path_is_kept),
            ("foreign hint is kept", self.scenario_foreign_hint_is_kept),
        ]

    def test_disposal_outcomes(self):
        for name, scenario in self.scenarios():
            with self.subTest(name):
                try:
                    expected = scenario()
                    self.assertEqual(expected, runtime_leftovers.leftovers(self.runtime))
                finally:
                    for leftover in self.runtime.iterdir():
                        leftover.unlink()


class ForcedCrashCleanup(unittest.TestCase):
    """forced_crash_cleanup finds, kills and reaps the detached Host on a Store, then retires its
    socket. The stand-in runs as `python host serve --store S`, the argv shape the real census matches,
    so discovery, kill, reap and retire are all real."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir="/tmp")
        self.addCleanup(self.tmp.cleanup)
        self.runtime = pathlib.Path(self.tmp.name) / "runtime"
        self.runtime.mkdir()
        (pathlib.Path(self.tmp.name) / "host").write_text(FAKE_HOST)
        previous = os.environ.get(runtime_leftovers.OVERRIDE)
        os.environ[runtime_leftovers.OVERRIDE] = str(self.runtime)
        self.addCleanup(lambda: os.environ.pop(runtime_leftovers.OVERRIDE) if previous is None
                        else os.environ.__setitem__(runtime_leftovers.OVERRIDE, previous))
        self.env = dict(os.environ)

    def test_forced_crash_cleanup_retires_the_killed_host(self):
        saved = sys.argv
        sys.argv = [saved[0], sys.executable]
        try:
            spec = importlib.util.spec_from_file_location("host_launch_fixture", ROOT / "tests/integration/host_launch_fixture.py")
            launch = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(launch)
        finally:
            sys.argv = saved
        store = pathlib.Path(self.tmp.name) / "store"
        store.mkdir()
        store = store.resolve()
        process = subprocess.Popen([sys.executable, "host", "serve", "--store", str(store), "--mode", "serve"],
                                   cwd=self.tmp.name, env=self.env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.addCleanup(lambda: process.poll() is None and process.kill())
        socket_path = self.runtime / "x.sock"
        HOST.wait_for(socket_path.exists, "stand-in Host to listen", timeout=10)
        self.assertEqual([process.pid], launch.matching_processes(store))
        launch.forced_crash_cleanup(store)
        process.wait(timeout=10)
        self.assertFalse(socket_path.exists() or socket_path.with_suffix(".store").exists())
        shutil.rmtree(store)
        self.assertEqual([], runtime_leftovers.leftovers(self.runtime))


if __name__ == "__main__":
    unittest.main()
