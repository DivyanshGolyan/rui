"""Only a refusing socket whose hinted Store is gone is a fixture leftover (#1855)."""
import pathlib
import socket
import tempfile
import unittest

import runtime_leftovers


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


if __name__ == "__main__":
    unittest.main()
