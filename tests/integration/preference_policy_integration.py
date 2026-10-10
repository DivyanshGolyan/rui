"""Native production-owner publication/privacy checks; no CLI or provider traffic.

Build the driver with:
zig build-exe -O ReleaseSafe -lc --dep preferences \
  -Mroot=tests/integration/preference_policy.zig -Mpreferences=src/preferences.zig \
  -femit-bin=zig-out/bin/preference-policy
Then run this file with that binary's path. Linux/Darwin fsync interposition
is returned-error evidence, not power-loss evidence; other platforms report the skip.
"""
import base64
from contextlib import contextmanager
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import resource
import shutil
import stat
import subprocess
import sys
import tempfile
import time

from host_process import canonical_fixture_root


@contextmanager
def private_fixture_root(deadline):
    root = canonical_fixture_root(Path(tempfile.mkdtemp(prefix="rui-preference-policy-")))
    try:
        yield root
        time_left(deadline, 1)
        shutil.rmtree(root)
        time_left(deadline, 1)  # Cleanup shares the same, never-renewed budget.
    except BaseException:
        print(json.dumps({"phase": "failure_retention", "private_root": str(root),
                          "root_remains": root.exists()}), flush=True)
        raise


def artifact_identity(path):
    assert stat.S_ISREG(path.stat().st_mode), path
    with path.open("rb") as file:
        before = os.fstat(file.fileno())
        assert stat.S_ISREG(before.st_mode), path
        digest = hashlib.file_digest(file, "sha256").hexdigest()
        after = os.fstat(file.fileno())
    assert all(getattr(before, name) == getattr(current, name)
               for current in (after, path.stat())
               for name in ("st_dev", "st_ino", "st_uid", "st_mode", "st_size", "st_mtime_ns")), path
    return {"path": str(path), "dev": before.st_dev, "inode": before.st_ino,
            "uid": before.st_uid, "mode": before.st_mode, "size": before.st_size,
            "mtime_ns": before.st_mtime_ns, "sha256": digest}


def require_darwin_fsync(output, path, architecture, *, interpose):
    assert output.splitlines()[0] == f"{path} [{architecture}]:", output

    def section(name):
        matches = re.findall(rf"(?ms)^    -{name}:\n(.*?)(?=^    -[a-z_]+:|\Z)", output)
        assert len(matches) == 1, (name, output)
        return matches[0]

    imported = section("imports")
    imports = re.findall(r"(?m)^\s+(?:0x[0-9A-Fa-f]+\s+)?_fsync\s+\(from ([^)]+)\)$", imported)
    assert len(re.findall(r"\b_fsync\b", imported)) == 1, output
    assert imports == ["libSystem"], ("ordinary fsync import missing", output)
    fixups = section("fixups")
    symbolic = section("symbolic_fixups")
    if not interpose:
        return
    slots = [line.split() for line in fixups.splitlines()
             if line.split()[:2] == ["__DATA", "__interpose"]]
    assert len(slots) == 2 and all(len(slot) == 5 for slot in slots), output
    assert slots[0][3] == "rebase" and int(slots[0][4], 16) > 0, output
    assert slots[1][3:] == ["bind", "libSystem/_fsync"], output
    assert int(slots[1][2], 16) == int(slots[0][2], 16) + 8, output
    assert len(re.findall(r"(?m)^_sync_interpose:$", symbolic)) == 1, output
    groups = re.findall(r"(?ms)^_sync_interpose:\n(.*?)(?=^\S|\Z)", symbolic)
    assert len(groups) == 1, output
    entries = [line.split() for line in groups[0].splitlines()]
    assert entries == [["+0x0000", "rebase", "_probe_sync"],
                       ["+0x0008", "bind", "libSystem/_fsync"]], output
    return slots[0][2], slots[0][4]


def time_left(deadline, limit):
    remaining = deadline - time.monotonic()
    assert remaining > 0, "preference fixture budget exhausted"
    return min(limit, remaining)


def audit_darwin_images(shim, compiled_inputs, environment, deadline):
    reader_name = shutil.which("dyld_info")
    assert reader_name is not None, "dyld_info unavailable; no cuts admitted"
    reader = Path(reader_name).resolve(strict=True)
    paths = {name: Path(identity["path"]) for name, identity in compiled_inputs.items()}
    paths.update(shim=shim, reader=reader)
    source = paths["source"]
    identities = {name: artifact_identity(path) for name, path in paths.items()}
    assert all(identities[name] == expected for name, expected in compiled_inputs.items())
    architecture = platform.machine()
    assert architecture in ("arm64", "x86_64"), architecture
    print(json.dumps({"phase": "pre_cut_identity", "architecture": architecture,
                      "inputs": identities}), flush=True)
    reader_uses = 0

    def inspect(name, *options):
        nonlocal reader_uses
        reader_uses += 1
        assert reader_uses <= 3
        assert {name: artifact_identity(path) for name, path in paths.items()} == identities
        command = [str(reader), "-arch", architecture, *options, str(paths[name])]
        stdout = source.parent / f"audit-{reader_uses}.stdout"
        stderr = source.parent / f"audit-{reader_uses}.stderr"
        # Never lift an inherited limit. At most six private 1 MiB output files,
        # with one reader at a time; the enclosing allowance owns the total clock.
        limit = min(value for value in (1024 * 1024, *resource.getrlimit(resource.RLIMIT_FSIZE))
                    if value != resource.RLIM_INFINITY)
        failure = None
        result = None
        with stdout.open("xb") as output, stderr.open("xb") as errors:
            try:
                result = subprocess.run(command, stdin=subprocess.DEVNULL, stdout=output, stderr=errors,
                    env=environment, timeout=time_left(deadline, 10),
                    preexec_fn=lambda: resource.setrlimit(resource.RLIMIT_FSIZE, (limit, limit)))
            except subprocess.TimeoutExpired as error:
                failure = error  # subprocess.run kills and waits for its own child before raising.
        raw_output, raw_errors = stdout.read_bytes(), stderr.read_bytes()
        print(json.dumps({"phase": "pre_cut_audit", "argv": command,
            "exit": result.returncode if result is not None else None, "timeout": failure is not None,
            "per_output_limit": limit, "stdout_path": str(stdout), "stderr_path": str(stderr),
            "own_reader_reaped": True, "output_files_closed_read_to_eof": True,
            "stdout_base64": base64.b64encode(raw_output).decode(),
            "stderr_base64": base64.b64encode(raw_errors).decode()}), flush=True)
        if failure is not None:
            raise failure
        assert len(raw_output) < limit and len(raw_errors) < limit, "audit output limit reached"
        assert result.returncode == 0, f"{name} Mach-O audit failed"
        current = {name: artifact_identity(path) for name, path in paths.items()}
        print(json.dumps({"phase": "post_reader_identity", "inputs": current}), flush=True)
        assert current == identities
        return raw_output.decode("utf-8")

    for name in ("actor", "shim"):
        output = inspect(name, "-imports", "-fixups", "-symbolic_fixups")
        addresses = require_darwin_fsync(output, paths[name], architecture, interpose=name == "shim")
    # Symbolic fixup groups omit their base address. Resolve the raw tuple base
    # and replacement target through the same reader to correlate exact addresses.
    output = inspect("shim", "-lookup_va", ",".join(addresses))
    assert output.splitlines()[0] == f"{shim} [{architecture}]:", output
    symbols = [re.fullmatch(r"  (0x[0-9A-Fa-f]+) (\S+)", line)
               for line in output.splitlines()[1:] if line.strip()]
    assert all(symbol is not None for symbol in symbols), output
    assert [(int(symbol[1], 16), symbol[2]) for symbol in symbols] == [
        (int(addresses[0], 16), "_sync_interpose"),
        (int(addresses[1], 16), "_probe_sync")], output
    assert {name: artifact_identity(path) for name, path in paths.items()} == identities
    print("PASS pre-cut Darwin artifact audit (not load/cut equivalence)", flush=True)
    return paths, identities


def main():
    binary = Path(sys.argv[1]).resolve()
    budget = float(os.environ.get("RUI_TEST_PREFERENCE_BUDGET_SECONDS", "300"))
    assert math.isfinite(budget) and budget > 0, "invalid preference fixture budget"
    deadline = time.monotonic() + budget
    if sys.platform == "darwin":
        assert not any(name.startswith("DYLD_") for name in os.environ), "ambient DYLD override"
        print(json.dumps({"phase": "fixture_budget", "seconds": budget}), flush=True)
    with private_fixture_root(deadline) as root:
        home = root / "home"
        home.mkdir(mode=0o700)
        environment = {**os.environ, "TMPDIR": str(root)}

        def run(action, *args, error=None, extra=None):
            result = subprocess.run([str(binary), action, str(home), *args],
                                    env={**environment, **(extra or {})},
                                    capture_output=True, timeout=time_left(deadline, 10))
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
        if sys.platform == "darwin":
            compiler_name = shutil.which("cc")
            assert compiler_name is not None, "cc unavailable"
            compiler[0] = str(Path(compiler_name).resolve(strict=True))
            compiled_inputs = {name: artifact_identity(path) for name, path in
                               {"actor": binary, "source": source, "compiler": Path(compiler[0])}.items()}
            print(json.dumps({"phase": "shim_compile_input", "inputs": compiled_inputs}), flush=True)
        subprocess.run([*compiler, "-o", str(shim)], check=True, env=environment,
                       timeout=time_left(deadline, 60))
        audited = audit_darwin_images(shim, compiled_inputs, environment, deadline) if sys.platform == "darwin" else None
        injection = "DYLD_INSERT_LIBRARIES" if sys.platform == "darwin" else "LD_PRELOAD"
        for cut in (1, 2, 3):
            if audited is not None:
                paths, identities = audited
                current = {name: artifact_identity(path) for name, path in paths.items()}
                print(json.dumps({"phase": "pre_cut_identity", "cut": cut, "inputs": current}), flush=True)
                assert current == identities
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
