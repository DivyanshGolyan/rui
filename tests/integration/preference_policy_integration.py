"""Native production-owner privacy checks; no CLI or provider traffic.

Run through zig build preference-policy-integration. Directory-sync failures
are tested beside the owner in src/preferences.zig using the real filesystem.
"""
from contextlib import contextmanager
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

import host_process
from host_process import canonical_fixture_root


@contextmanager
def private_fixture_root():
    root = canonical_fixture_root(Path(tempfile.mkdtemp(prefix="rui-preference-policy-")))
    try:
        yield root
        shutil.rmtree(root)
    except BaseException:
        print(json.dumps({"phase": "failure_retention", "private_root": str(root),
                          "root_remains": root.exists()}), flush=True)
        raise


def main():
    binary = Path(sys.argv[1]).resolve()
    with private_fixture_root() as root:
        home = root / "home"
        home.mkdir(mode=0o700)
        environment = {**os.environ, "TMPDIR": str(root)}

        def run(action, *args, error=None):
            result = subprocess.run([str(binary), action, str(home), *args],
                                    env=environment, capture_output=True, timeout=10)
            assert result.returncode == (1 if error else 0), result.stderr
            if error:
                assert error.encode() in result.stderr, result.stderr

        run("read")
        assert not (home / ".config").exists(), "inspection created an owner"
        run("login")
        private = home / ".config/rui"
        saved = private / "preferences"
        assert saved.read_bytes() == b"version=1\nstore=\nprovider=codex\nmodel=\n"
        run("set", "deliberate-pin")
        old = saved.read_bytes()
        temporary = private / "preferences.tmp"
        temporary.mkdir()
        run("set", "replacement", error="InsecurePreferenceFile")
        assert saved.read_bytes() == old
        temporary.rmdir()
        saved.chmod(0o644)
        run("read", error="InsecurePreferenceFile")
        saved.chmod(0o600)
        backup = private / "backup"
        saved.rename(backup)
        saved.symlink_to(backup.name)
        run("read", error="SymLinkLoop")
        saved.unlink()
        os.mkfifo(saved, 0o600)
        run("read", error="InsecurePreferenceFile")
        saved.unlink()
        backup.rename(saved)
        for invalid, error in [(b"version=9\n", "UnsupportedPreferencesVersion"),
                               (b"version=1\nstore=\nprovider=\nmodel=pin\n", "PreferenceProviderRequired")]:
            saved.write_bytes(invalid)
            run("login", error=error)
            assert saved.read_bytes() == invalid
        saved.write_bytes(old)
        run("read")
        print("PASS preference privacy and native publication/reload")


if __name__ == "__main__":
    host_process.enter()
    main()
