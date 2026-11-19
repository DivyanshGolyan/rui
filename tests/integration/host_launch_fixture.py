import os
import pathlib
import signal
import subprocess
import sys

from host_process import close_stdin, dispose_all, stop_process, wait_for
import os_semantics
import runtime_leftovers


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



def dispose_provider_case(process, store):
    dispose_all(
        lambda: close_stdin(process) if process is not None else None,
        lambda: process.wait(timeout=20) if process is not None else None,
        lambda: stop_process(process, timeout=5) if process is not None else None,
        lambda: forced_crash_cleanup(store),
    )


def matching_hosts(store, *, descendants=False):
    """(pid, resolved Store) for each detached Host on `store` (or beneath it, with descendants)."""
    expected = str(pathlib.Path(store).resolve())
    owned = os_semantics.processes_executing(RUI)
    matches = []
    for pid, text in os_semantics.process_commands():
        if pid in owned and len(text) >= 5 and text[1:4] == ["host", "serve", "--store"]:
            try:
                selected = str(pathlib.Path(text[4]).resolve())
            except OSError:
                continue
            if selected == expected or (descendants and pathlib.Path(selected).is_relative_to(expected)):
                matches.append((pid, selected))
    return matches


def matching_processes(store, *, descendants=False):
    return [pid for pid, _ in matching_hosts(store, descendants=descendants)]


def forced_crash_cleanup(store, *, descendants=False):
    hosts = matching_hosts(store, descendants=descendants)
    for pid, _ in hosts:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    wait_for(lambda: matching_processes(store, descendants=descendants), "forced-crash cleanup to reap the detached Host",
             timeout=5, interval=0.02, ready=lambda found: not found)
    # The reaped Hosts left their sockets and .store hints behind; retire them before the caller deletes the Store.
    for stored in {pathlib.Path(store).resolve(), *(pathlib.Path(selected) for _, selected in hosts)}:
        runtime_leftovers.retire(stored)
