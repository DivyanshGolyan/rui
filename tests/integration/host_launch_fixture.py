"""Host launch helpers the human CLI fixture shares: run a start command and clean
up after a forced crash."""
import os
import pathlib
import shlex
import signal
import subprocess
import sys

from host_process import wait_for
import os_semantics


RUI = pathlib.Path(sys.argv[1]).resolve()


COMMAND_TIMEOUT = 16


def run_start(store, env, *arguments, **options):
    return subprocess.run(
        [RUI, "host", "start", "--store", store, *arguments],
        env=env,
        capture_output=True,
        text=True,
        timeout=COMMAND_TIMEOUT,
        **options,
    )


def matching_processes(store, *, descendants=False):
    """Test-cleanup discovery only; PIDs are never treated as Host authority."""
    expected = str(pathlib.Path(store).resolve())
    # A Host is owned when it executes this RUI; its argv only says which Store it serves.
    owned = os_semantics.processes_executing(RUI)
    matches = []
    candidates = []
    if pathlib.Path("/proc").is_dir():
        for entry in pathlib.Path("/proc").iterdir():
            if not entry.name.isdigit():
                continue
            try:
                argv = (entry / "cmdline").read_bytes().split(b"\0")
                candidates.append((int(entry.name), [part.decode() for part in argv if part]))
            except (FileNotFoundError, ProcessLookupError, PermissionError, UnicodeDecodeError):
                continue
    else:
        listing = subprocess.run(
            ["ps", "-axo", "pid=,command="], capture_output=True, text=True, timeout=5, check=True
        )
        for line in listing.stdout.splitlines():
            try:
                pid_text, command = line.strip().split(maxsplit=1)
                candidates.append((int(pid_text), shlex.split(command)))
            except (ValueError, IndexError):
                continue
    for pid, text in candidates:
        if pid in owned and len(text) >= 5 and text[1:4] == ["host", "serve", "--store"]:
            try:
                selected = str(pathlib.Path(text[4]).resolve())
            except OSError:
                continue
            if selected == expected or (descendants and pathlib.Path(selected).is_relative_to(expected)):
                matches.append(pid)
    return matches


def forced_crash_cleanup(store, *, descendants=False):
    # #329 is intentionally not part of this fixture. SIGKILL is a forced
    # crash used only to avoid leaking detached test processes.
    for pid in matching_processes(store, descendants=descendants):
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    wait_for(lambda: matching_processes(store, descendants=descendants), "forced-crash cleanup to reap the detached Host",
             timeout=5, interval=0.02, ready=lambda found: not found)
