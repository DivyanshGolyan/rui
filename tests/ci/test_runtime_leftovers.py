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
import threading
import types
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests/integration"))
import os_semantics  # noqa: E402
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

    def test_retire_under_removes_refusing_sockets_for_stores_below_a_root(self):
        # Shell fixtures retire by their state directory; a sibling sharing the prefix stays.
        with tempfile.TemporaryDirectory(dir="/tmp") as raw:
            root = pathlib.Path(raw)
            state = root / "state"
            listening = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                def refusing(name, store):
                    path = root / name
                    probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                    probe.bind(str(path))
                    probe.close()
                    path.with_suffix(".store").write_text(str(store))
                    return path
                below = refusing("below.sock", state / "format-store")
                sibling = refusing("sibling.sock", root / "state-other" / "store")
                accepting = root / "accepting.sock"
                listening.bind(str(accepting))
                listening.listen(1)
                accepting.with_suffix(".store").write_text(str(state / "store"))
                runtime_leftovers.retire_under(state, root)
                self.assertFalse(below.exists() or below.with_suffix(".store").exists())
                self.assertTrue(sibling.exists() and accepting.exists())
            finally:
                listening.close()

    def test_retire_settles_a_host_that_dies_after_its_wrapper(self):
        # strace --kill-on-exit: the reaped wrapper's Host still accepts for a moment.
        with tempfile.TemporaryDirectory(dir="/tmp") as raw:
            root = pathlib.Path(raw)
            store = root / "store"
            path = root / "late.sock"
            listening = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            listening.bind(str(path))
            listening.listen(1)
            path.with_suffix(".store").write_text(str(store))
            closer = threading.Timer(0.2, listening.close)
            closer.start()
            saved = os.environ.get(runtime_leftovers.OVERRIDE)
            os.environ[runtime_leftovers.OVERRIDE] = str(root)
            try:
                HOST.retire_settled(store)
            finally:
                closer.cancel()
                listening.close()
                if saved is None:
                    os.environ.pop(runtime_leftovers.OVERRIDE, None)
                else:
                    os.environ[runtime_leftovers.OVERRIDE] = saved
            self.assertFalse(path.exists() or path.with_suffix(".store").exists())

    def test_probe_failure_other_than_refusal_keeps_the_socket(self):
        # The parent of the path is a file, so connect fails with ENOTDIR: no refusal errno.
        # Nothing proves the socket dead, so it is live and kept.
        with tempfile.TemporaryDirectory(dir="/tmp") as raw:
            root = pathlib.Path(raw)
            (root / "plain").write_text("")
            self.assertTrue(runtime_leftovers.answers(root / "plain" / "p.sock"))

    def test_a_live_socket_is_kept_by_leftovers_and_retire(self):
        with tempfile.TemporaryDirectory(dir="/tmp") as raw, os_semantics.unix_stream() as live:
            root = pathlib.Path(raw)
            path = root / "p.sock"
            live.bind(str(path))
            live.listen(8)
            gone = str(root / "gone")
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
        args = [sys.executable, str(self.script), "host", "serve", "--store", str(store), "--mode", mode]
        return HOST.start_ready_process(args, env=self.env, isolate_settings=False)[0]

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

    def scenario_client_on_the_store_retires_nothing(self):
        # A client command names the Store too but owns no socket: disposing it leaves the Host's
        # socket alone (a live Host would otherwise be probed), and the Host's own disposal retires it.
        store = self.store("client")
        host = self.start(store)
        self.kill(host)
        client = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)",
                                   "request", "read-result", "--store", str(store)])
        HOST.stop_process(client)
        self.assertTrue(self.socket.exists())
        HOST.stop_process(host)
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
            ("client on the Store retires nothing; its Host's disposal does", self.scenario_client_on_the_store_retires_nothing),
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


class DisposedStore(unittest.TestCase):
    """disposed_store over every process shape stop_process is handed: a Host (bare or behind a
    wrapper), a client command on the same Store, ready fields only, and objects with neither
    (fakes and wrappers without .args). Only a Host owns a socket, so only a Host names a Store:
    retiring for a client would probe the live Host still serving that Store."""

    def test_disposed_store_shapes(self):
        root = os.path.realpath(tempfile.gettempdir())
        store = os.path.join(root, "s")
        cases = [
            ("ready field wins", types.SimpleNamespace(rui_ready_fields={"store": "/r"}, args=["--store", store]), "/r"),
            ("Host --store", types.SimpleNamespace(args=["rui", "host", "serve", "--store", store]), store),
            ("Host --store-hex", types.SimpleNamespace(args=["rui", "host", "serve", "--store-hex", os.fsencode(store).hex()]), store),
            ("Host behind a wrapper", types.SimpleNamespace(args=["prlimit", "--nofile=64", "rui", "host", "serve", "--store", store]), store),
            ("Host with path-typed argv", types.SimpleNamespace(args=[pathlib.Path("rui"), "host", "serve", "--store", pathlib.Path(store)]), store),
            ("client --store", types.SimpleNamespace(args=["rui", "request", "read-result", "--store", store, "--key", "k"]), None),
            ("client --store-hex", types.SimpleNamespace(args=["rui", "session", "inspect", "--store-hex", os.fsencode(store).hex()]), None),
            ("Store before host serve", types.SimpleNamespace(args=["rui", "--store", store, "host", "serve"]), None),
            ("string args", types.SimpleNamespace(args="rui host serve --store x"), None),
            ("no args attribute", types.SimpleNamespace(), None),
            ("dangling --store", types.SimpleNamespace(args=["rui", "host", "serve", "--store"]), None),
        ]
        for name, process, expected in cases:
            with self.subTest(name):
                self.assertEqual(expected, HOST.disposed_store(process))


class OneRetirer(unittest.TestCase):
    def test_fixtures_retire_a_reaped_host_only_through_retire_settled(self):
        # A bare retire right after a kill can find the socket still accepting and keep it (#2017).
        # model_fixture retires crashed Stores at suite exit, long after their Hosts died.
        allowed = {"host_process.py", "model_fixture.py", "runtime_leftovers.py"}
        callers = sorted(path.name for path in (ROOT / "tests/integration").glob("*.py")
                         if path.name not in allowed and "runtime_leftovers.retire(" in path.read_text())
        self.assertEqual([], callers)


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

    def launch_fixture(self):
        saved = sys.argv
        sys.argv = [saved[0], sys.executable]
        try:
            spec = importlib.util.spec_from_file_location("host_launch_fixture", ROOT / "tests/integration/host_launch_fixture.py")
            launch = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(launch)
        finally:
            sys.argv = saved
        return launch

    def test_forced_crash_cleanup_waits_for_a_reaped_host_socket_to_close(self):
        # A killed Host can leave the process list (on Linux its /proc exe link goes with its memory) before its
        # files close, so its socket can still accept for a moment after the reap (#2017).
        launch = self.launch_fixture()
        store = pathlib.Path(self.tmp.name) / "store"
        store.mkdir()
        store = store.resolve()
        path = self.runtime / "closing.sock"
        listening = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.addCleanup(listening.close)
        listening.bind(str(path))
        listening.listen(1)
        path.with_suffix(".store").write_text(str(store))
        closer = threading.Timer(0.3, listening.close)
        self.addCleanup(closer.cancel)
        closer.start()
        launch.forced_crash_cleanup(store)
        self.assertFalse(path.exists() or path.with_suffix(".store").exists())

    def test_forced_crash_cleanup_retires_the_killed_host(self):
        launch = self.launch_fixture()
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
