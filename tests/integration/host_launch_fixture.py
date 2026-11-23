import os
import pathlib
import signal
import subprocess
import sys

from host_process import close_stdin, dispose_all, host_store, stop_process, wait_for
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
        if pid in owned and text[1:3] == ["host", "serve"] and (selected := host_store(text)) is not None:
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
