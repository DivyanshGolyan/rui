#!/usr/bin/env python3
"""Observe allocator environment before main, not after a too-late setenv."""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from unittest.mock import patch

from host_process import start_ready_process, stop_process


PROBE = r"""
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

__attribute__((constructor)) static void observe(void) {
    const char *magazines = getenv("MallocMaxMagazines");
    const char *space = getenv("MallocSpaceEfficient");
    FILE *log = fopen(getenv("RUI_ALLOCATOR_PROBE"), "a");
    if (!log) _exit(90);
    if (fprintf(log, "%ld\t%s\t%s\t%d\n", (long)getpid(),
                magazines ? magazines : "absent", space ? space : "absent",
                access(getenv("RUI_ALLOCATOR_STORE"), F_OK) == 0) < 0) _exit(91);
    if (fclose(log)) _exit(92);
    const char *remove = getenv("RUI_ALLOCATOR_REMOVE_EXECUTABLE");
    if (remove && unlink(remove)) _exit(93);
}
"""


def main():
    binary = Path(sys.argv[1]).resolve()
    macos = sys.platform == "darwin"
    with tempfile.TemporaryDirectory(prefix="rui-allocator-", dir="/tmp") as temporary:
        root = Path(temporary)
        source, library = root / "probe.c", root / "probe.so"
        source.write_text(PROBE)
        subprocess.run(
            ["cc", "-dynamiclib" if macos else "-shared", "-fPIC", str(source), "-o", str(library)],
            check=True,
        )
        base = {
            key: value for key, value in os.environ.items()
            if not key.startswith(("Malloc", "RUI_HOST_MALLOC_", "DYLD_", "LD_PRELOAD"))
        }
        base["DYLD_INSERT_LIBRARIES" if macos else "LD_PRELOAD"] = str(library)
        cases = [
            ({}, ("1", "1"), 2),
            ({"RUI_HOST_MALLOC_DEFAULTS": "0"}, ("absent", "absent"), 1),
            ({"MallocMaxMagazines": "2"}, ("2", "1"), 2),
            ({"MallocSpaceEfficient": "0"}, ("1", "0"), 2),
            ({"MallocMaxMagazines": "2", "MallocSpaceEfficient": "0"}, ("2", "0"), 1),
            ({"MallocMaxMagazines": "", "MallocSpaceEfficient": ""}, ("", ""), 1),
        ]
        for index, (overrides, expected, count) in enumerate(cases):
            store, log = root / f"store-{index}", root / f"log-{index}"
            env = dict(base, **overrides, RUI_ALLOCATOR_PROBE=str(log), RUI_ALLOCATOR_STORE=str(store))
            # The second image must preserve argv, cwd, stdio and the PID that
            # the supervising caller owns. A relative Store also checks cwd.
            relative_store = os.path.relpath(store)
            with patch.dict(os.environ, env, clear=True):
                process, _ = start_ready_process(
                    [binary, "serve", "--store", relative_store, "--active-capacity", "1"]
                )
            try:
                rows = [line.split("\t") for line in log.read_text().splitlines()]
                if not macos:
                    count = 1
                    expected = (overrides.get("MallocMaxMagazines", "absent"), overrides.get("MallocSpaceEfficient", "absent"))
                assert len(rows) == count, rows
                assert all(row[0] == str(process.pid) and row[3] == "0" for row in rows), rows
                assert tuple(rows[-1][1:3]) == expected, rows
                assert (store / "rui.sqlite3").is_file()
            finally:
                stop_process(process)

        # Ordinary CLI invocations do not change allocator policy or re-exec.
        log = root / "cli-log"
        env = dict(base, RUI_ALLOCATOR_PROBE=str(log), RUI_ALLOCATOR_STORE=str(root / "unused"))
        subprocess.run([binary], env=env, capture_output=True, timeout=10)
        rows = [line.split("\t") for line in log.read_text().splitlines()]
        assert len(rows) == 1 and rows[0][1:] == ["absent", "absent", "0"], rows

        if macos:
            # Make executable-path resolution/replacement fail before Store
            # effects, without any production fault hook or restart marker.
            removed = root / "removed-rui"
            shutil.copy2(binary, removed)
            store, log = root / "failed-store", root / "failed-log"
            env = dict(base, RUI_ALLOCATOR_PROBE=str(log), RUI_ALLOCATOR_STORE=str(store),
                       RUI_ALLOCATOR_REMOVE_EXECUTABLE=str(removed))
            result = subprocess.run(
                [removed, "serve", "--store", store, "--active-capacity", "1"],
                env=env, capture_output=True, timeout=10,
            )
            assert result.returncode != 0 and b"ready" not in result.stdout, result
            assert not store.exists()
            assert len(log.read_text().splitlines()) == 1
    print("Host allocator startup checks passed")


if __name__ == "__main__":
    main()
