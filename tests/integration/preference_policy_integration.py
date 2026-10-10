"""Native production-owner publication/privacy checks; no CLI or provider traffic.

Build the driver with:
zig build-exe -O ReleaseSafe -lc --dep preferences \
  -Mroot=tests/integration/preference_policy.zig -Mpreferences=src/preferences.zig \
  -femit-bin=zig-out/bin/preference-policy
Then run this file with that binary's path. Linux/Darwin fsync interposition
is returned-error evidence, not power-loss evidence; other platforms report the skip.
"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

from host_process import canonical_fixture_root


def main():
    binary = Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory(prefix="rui-preference-policy-") as name:
        root = canonical_fixture_root(Path(name))
        home = root / "home"
        home.mkdir(mode=0o700)

        def run(action, *args, error=None, extra=None):
            result = subprocess.run([str(binary), action, str(home), *args],
                                    env={**os.environ, **(extra or {})},
                                    capture_output=True, timeout=10)
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
        if sys.platform not in ("linux", "darwin"):
            print("PASS preference privacy; fsync injection UNAVAILABLE (Linux/Darwin only)")
            return

        source = root / "sync.c"
        shim = root / ("sync.dylib" if sys.platform == "darwin" else "sync.so")
        trace = root / "sync.trace"
        source.write_text(r'''
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>
static int probe_sync(int fd) {
    static unsigned directories;
    struct stat st;
#ifdef __APPLE__
    /* dyld exempts references in the tuple-owning image from replacement. */
    int (*real_sync)(int) = fsync;
#else
    int (*real_sync)(int) = dlsym(RTLD_NEXT, "fsync");
#endif
    if (fstat(fd, &st) || !S_ISDIR(st.st_mode)) return real_sync(fd);
    directories++;
    int log = open(getenv("RUI_SYNC_TRACE"), O_WRONLY|O_CREAT|O_APPEND, 0600);
    char marker = '0' + directories;
    if (log < 0 || write(log, &marker, 1) != 1 || close(log)) _exit(97);
    if (directories == (unsigned)atoi(getenv("RUI_SYNC_CUT"))) {
        errno = EIO;
        return -1;
    }
    return real_sync(fd);
}
#ifdef __APPLE__
__attribute__((used)) static const struct { const void *replacement; const void *original; }
    sync_interpose __attribute__((section("__DATA,__interpose"))) =
        { (const void *)&probe_sync, (const void *)&fsync };
#else
int fsync(int fd) { return probe_sync(fd); }
#endif
''')
        compiler = ["cc", "-dynamiclib", str(source)] if sys.platform == "darwin" else ["cc", "-shared", "-fPIC", str(source), "-ldl"]
        subprocess.run([*compiler, "-o", str(shim)], check=True)
        injection = "DYLD_INSERT_LIBRARIES" if sys.platform == "darwin" else "LD_PRELOAD"
        for cut in (1, 2, 3):
            trace.unlink(missing_ok=True)
            saved.write_bytes(old)
            run("set", "new-pin", error="PreferenceDirectorySyncFailed",
                extra={injection: str(shim), "RUI_SYNC_TRACE": str(trace), "RUI_SYNC_CUT": str(cut)})
            assert trace.read_bytes() == b"123"[:cut], "fault missed real directory sync"
            expected = old if cut < 3 else b"version=1\nstore=\nprovider=codex\nmodel=new-pin\n"
            assert saved.read_bytes() == expected, "partial/incorrect publication"
            assert not temporary.exists(), "temporary publication owner leaked"
            run("read")
        print("PASS preference privacy and all 3 real directory-sync cuts (old/old/new)")


if __name__ == "__main__":
    main()
