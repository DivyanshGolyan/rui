#!/usr/bin/env python3
"""Public one-shot caller recovery and exact Bash authorization."""
import errno
import json
import fcntl
import os
import pathlib
import pty
import select
import shlex
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time

from host_process import canonical_fixture_root
import dispatch_integration as fixture
import codex_integration as codex_fixture


def run(home, *args, success=True, environment=None):
    env = {**os.environ, "HOME": str(home), **(environment or {})}
    result = subprocess.run([str(fixture.RUI), *map(str, args)], env=env, capture_output=True, text=True, timeout=20)
    if success:
        assert result.returncode == 0, (args, result.stdout, result.stderr)
    else:
        assert result.returncode != 0, (args, result.stdout, result.stderr)
    return result.stdout


def admit(home, *args):
    captured, admission = map(json.loads, run(home, *args, "--json").splitlines())
    assert captured == {"event": "captured", "request": admission["request"]}, (captured, admission)
    assert admission["event"] == "admission", admission
    return admission


def preference_edits(home, store):
    """Exact saved intent, independent of prospective recommendation output."""
    run(home, "setup", "--store", store, "--provider", "codex", "--model", "gpt-6-luna")
    saved = home / ".config/rui/preferences"
    pinned = f"version=1\nstore={store.resolve()}\nprovider=codex\nmodel=gpt-6-luna\n"
    cleared = f"version=1\nstore={store.resolve()}\nprovider=codex\nmodel=\n"
    assert saved.read_text() == pinned
    run(home, "setup", "--store", store)
    assert saved.read_text() == pinned, "omitted model lost its selection"
    assert "Model: not selected" in run(home, "setup", "--clear-model")
    assert saved.read_text() == cleared, "clear persisted a recommendation or retained the model"
    run(home, "setup")
    assert saved.read_text() == cleared, "inspection persisted a recommendation"
    for flags in (("--clear-model", "--model", "gpt-6-luna"),
                  ("--model", "gpt-6-luna", "--clear-model"), ("--model", "")):
        run(home, "setup", *flags, success=False)
        assert saved.read_text() == cleared, "rejected edit changed preferences"
    saved.write_text(pinned.replace("provider=codex", "provider=retired").replace("gpt-6-luna", "old-model"))
    run(home, "setup", "--clear-model")
    assert saved.read_text() == cleared.replace("provider=codex", "provider=retired")
    assert "saved provider is unsupported; no fallback" in run(home, "setup")
    run(home, "setup", "--provider", "codex", "--clear-model")
    assert saved.read_text() == cleared
    run(home, "setup", "--model", "gpt-6-luna")
    assert saved.read_text() == pinned


def read_terminal(master, marker, timeout=15):
    output = b""
    deadline = time.monotonic() + timeout
    while marker.encode() not in output:
        remaining = deadline - time.monotonic()
        assert remaining > 0, (marker, output.decode(errors="replace"))
        assert select.select([master], [], [], remaining)[0], (marker, output.decode(errors="replace"))
        output += os.read(master, 65536)
        assert len(output) < 1024 * 1024, "unexpected unbounded terminal output"
    return (output.decode(errors="replace").replace("\r\n", "\n")
        .replace("\x1b[?2004h", "").replace("\x1b[?2004l", ""))


def terminal_step(master, command, marker="rui> "):
    os.write(master, (command + "\n").encode())
    return read_terminal(master, marker)


def store_selection_cases(state, workspace, valid_store):
    for case in ("saved-initial", "saved-after", "explicit-override", "explicit-create", "home-create"):
        home = state / case
        home.mkdir(mode=0o700)
        destination = home / ".local/share/rui/store" if case == "home-create" else home / "store"
        saved = case.startswith("saved") or case == "explicit-override"
        if saved:
            destination.mkdir(mode=0o700)
            run(home, "setup", "--store", destination, "--provider", "codex", "--model", "gpt-6-luna")
            if case != "saved-after":
                destination.rmdir()
                assert run(home, "host", "status", success=False) == ""
        if not case.startswith("saved"):
            (home / ".config/rui").mkdir(mode=0o700, parents=True, exist_ok=True)
            codex_fixture.credentials(home / ".config/rui/codex.json")
        explicit = valid_store if case == "explicit-override" else destination
        if case == "explicit-override":
            assert "Host: ready" in run(home, "host", "status", "--store", explicit)
        args = ["--store", str(explicit)] if case.startswith("explicit") else []
        master, slave = pty.openpty()
        ready_read, ready_write = os.pipe()
        caller = subprocess.Popen([str(fixture.RUI), *args], cwd=workspace,
            env={**os.environ, "HOME": str(home), "RUI_TEST_ACTION_READY_FD": str(ready_write)},
            pass_fds=(ready_write,), stdin=slave, stdout=slave, stderr=subprocess.PIPE)
        os.close(slave)
        os.close(ready_write)
        try:
            if case == "saved-after":
                assert "No locally ready provider" in provider_prompt(master, ready_read)
                destination.rmdir()
                assert run(home, "host", "status", success=False) == ""
                os.write(master, b"d\n")
            if not case.startswith("saved"):
                assert "Session: rui/" in read_terminal(master, "rui> ")
                terminal_step(master, "/exit", "Detached.")
            _, errors = caller.communicate(timeout=5)
            if case.startswith("saved"):
                assert caller.returncode != 0 and b"FileNotFound" in errors, (case, errors)
                assert not destination.exists() and not (home / ".config/rui/requests").exists()
            else:
                assert caller.returncode == 0, (case, errors)
                record, = (home / ".config/rui/requests").glob("*.json")
                binding = json.loads(record.read_bytes())
                assert binding["store"] == str(explicit.resolve()) and binding["require_model"] is True
            print("Store provenance:", case, "passed", flush=True)
        finally:
            if caller.poll() is None:
                caller.kill()
                caller.wait(timeout=5)
            os.close(ready_read)
            os.close(master)
            if case in ("explicit-create", "home-create") and destination.exists():
                run(home, "host", "stop", "--store", destination)
                fixture.wait_for(lambda: "Host: unavailable" in run(home, "host", "status", "--store", destination), "created Host stopped")


def action_ready(descriptor):
    assert select.select([descriptor], [], [], 15)[0], "Action input flush did not finish"
    assert os.read(descriptor, 1) == b"x", "Action caller exited before readiness"


def provider_prompt(master, ready, command=None):
    # Initial prompts use a fresh pipe. Later prompts must not consume an
    # unread notification from an earlier choice as readiness for this one.
    if command is not None:
        assert not select.select([ready], [], [], 0)[0], "stale provider readiness"
        os.write(master, (command + "\n").encode())
    deadline = time.monotonic() + 15
    output = read_terminal(master, "Provider: [c]", timeout=deadline - time.monotonic())
    remaining = deadline - time.monotonic()
    assert remaining > 0 and select.select([ready], [], [], remaining)[0], "provider input flush did not finish"
    assert os.read(ready, 1) == b"x", "provider caller exited before readiness"
    assert not select.select([ready], [], [], 0)[0], "extra provider readiness"
    return output


def terminal_bulk(master, command, marker="rui> "):
    fixture.wait_for(lambda: not termios.tcgetattr(master)[3] & termios.ICANON,
        "noncanonical terminal input")
    def send():
        payload = (command + "\n").encode()
        for offset in range(0, len(payload), 1024):
            os.write(master, payload[offset:offset + 1024])

    writer = threading.Thread(target=send, daemon=True)
    writer.start()
    output = read_terminal(master, marker)
    writer.join(timeout=5)
    assert not writer.is_alive(), "bulk terminal writer stalled"
    return output


def saved_capture_cases(state, store, workspace):
    home = state / "capture-home"
    home.mkdir()
    records = home / ".config/rui/requests"
    args = ["configure", "--store", store, "--session", "capture/original",
        "--workspace", workspace, "--provider", "codex", "--model", "model-a"]
    gate = state / "capture-original-reader"
    caller = subprocess.Popen([str(fixture.RUI), *map(str, args), "--json"],
        env={**os.environ, "HOME": str(home), "RUI_TEST_CAPTURE_GATE": str(gate)},
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    original = None
    record = None
    try:
        fixture.wait_for(lambda: pathlib.Path(f"{gate}.ready").exists(), "capture reader publication")
        handles = json.loads(run(home, "requests", "--json"))
        assert len(handles) == 1, handles
        handle = handles[0]
        record = records / f"{handle}.json"
        original = record.read_bytes()
        assert fixture.command("observe-command", "--store", store,
            "--key", handle)["observation"]["status"] == "absent"
        # A pathname replacement after publication must not swap the bytes
        # selected by the captured owner before its announcement.
        replaced = json.loads(original)
        replaced["session"] = "capture/replacement"
        replacement = records / "replacement"
        replacement.write_text(json.dumps(replaced, separators=(",", ":")))
        replacement.replace(record)
        pathlib.Path(f"{gate}.release").touch()
        output, errors = caller.communicate(timeout=20)
        assert caller.returncode == 0, (output, errors)
        captured, admission = map(json.loads, output.splitlines())
        assert captured["request"] == handle and admission["admission"]["answer"]["status"] == "accepted"
        observed = fixture.command("observe-command", "--store", store, "--key", handle)["observation"]
        assert observed["target"] == "capture/original", ("captured owner transmitted a replaced pathname", observed)
    finally:
        if caller.poll() is None:
            caller.kill()
            caller.communicate(timeout=5)
        if original is not None:
            record.write_bytes(original)

    # Recovery must ignore a newly selected, nonexistent preference Store.
    run(home, "setup", "--store", store)
    preferences = home / ".config/rui/preferences"
    preferences.write_text(f"version=1\nstore={state / 'missing-capture-store'}\n")
    assert json.loads(run(home, "recover", handle, "--json"))["answer"]["replayed"] is True

    # Failure to announce happens after publication but before any send.
    before = set(run(home, "requests").splitlines())
    output = run(home, *args, success=False,
        environment={"RUI_TEST_CAPTURE_GATE": str(state / "missing-parent/gate")})
    assert output == "", output
    failed_notice, = set(run(home, "requests").splitlines()) - before
    assert fixture.command("observe-command", "--store", store,
        "--key", failed_notice)["observation"]["status"] == "absent"
    assert json.loads(run(home, "recover", failed_notice, "--json"))["answer"]["replayed"] is False

    # Linux libc fault injection reaches the actual post-rename directory sync,
    # not a fixture-only success path. No automatic send may follow uncertainty.
    if sys.platform == "linux":
        source, library = state / "capture-sync.c", state / "capture-sync.so"
        source.write_text(r"""
#include <dlfcn.h>
#include <errno.h>
#include <sys/stat.h>
#include <unistd.h>
int fsync(int fd) {
    struct stat value;
    if (!fstat(fd, &value) && S_ISDIR(value.st_mode)) { errno = EIO; return -1; }
    int (*real_sync)(int) = dlsym(RTLD_NEXT, "fsync");
    return real_sync(fd);
}
""")
        subprocess.run(["cc", "-shared", "-fPIC", str(source), "-ldl", "-o", str(library)], check=True)
        before = set(run(home, "requests").splitlines())
        failed = subprocess.run([str(fixture.RUI), *map(str, args)],
            env={**os.environ, "HOME": str(home), "LD_PRELOAD": str(library)},
            capture_output=True, text=True, timeout=20)
        assert failed.returncode != 0 and "RecordDirectorySyncFailed" in failed.stderr, failed
        assert failed.stdout == "", failed.stdout
        uncertain, = set(run(home, "requests").splitlines()) - before
        assert fixture.command("observe-command", "--store", store,
            "--key", uncertain)["observation"]["status"] == "absent"
        assert json.loads(run(home, "recover", uncertain, "--json"))["answer"]["replayed"] is False
    else:
        print("capture directory-sync injection: unavailable outside Linux", flush=True)

    invalid = "01234567-89ab-4cde-8012-3456789abcde"
    unsupported = "01234567-89ab-4cde-8012-3456789abcdf"
    (records / f"{invalid}.json").write_text("not a readable record")
    stop = {"version": "1", "kind": "session_stop", "store": str(store.resolve()),
        "key": unsupported, "session": "capture/original"}
    (records / f"{unsupported}.json").write_text(json.dumps(stop, separators=(",", ":")))
    (records / "not-a-handle.json").write_text("not a record")
    listed = json.loads(run(home, "requests", "--json"))
    assert invalid in listed and unsupported in listed and "not-a-handle" not in listed, listed
    assert run(home, "recover", invalid, success=False) == ""
    assert run(home, "recover", unsupported, success=False) == ""
    master, slave = pty.openpty()
    entered = subprocess.Popen([str(fixture.RUI), "session", "--store", str(store),
        "--session", "capture/original"], env={**os.environ, "HOME": str(home)},
        stdin=slave, stdout=slave, stderr=slave)
    os.close(slave)
    try:
        read_terminal(master, "rui> ")
        listing = terminal_step(master, "/requests")
        assert handle in listing and failed_notice in listing, listing
        assert invalid not in listing and unsupported not in listing, listing
        terminal_step(master, "/exit", "Detached.")
        assert entered.wait(timeout=5) == 0
    finally:
        if entered.poll() is None:
            entered.kill()
            entered.wait(timeout=5)
        os.close(master)
    print("saved capture owner: pinned original bytes, preference-independent recovery, failed announcement, "
        "sync uncertainty, listing asymmetry", flush=True)


def main():
    import canonical_failure_integration
    import terminal_restoration_integration
    terminal_restoration_integration.main()
    canonical_failure_integration.main()
    state = canonical_fixture_root(tempfile.mkdtemp(prefix="rui-human-cli."))
    home = state / "home"
    home.mkdir()
    store = state / "store"
    workspace = state / "workspace"
    workspace.mkdir()
    session = "human/bash"
    counter = workspace / "effect-count"
    arguments = json.dumps({"cmd": "printf x >> effect-count", "timeout_ms": None}, separators=(",", ":"))
    control_call = "human-call\x1b[1Ghidden\u202e"
    control_arguments = arguments + "\r  "
    sibling_started = state / "sibling-started"
    sibling_release = state / "sibling-release"
    sibling_effect = workspace / "sibling-effect"
    sibling_arguments = json.dumps({"cmd": f"touch {shlex.quote(str(sibling_started))}; "
        f"while [ ! -e {shlex.quote(str(sibling_release))} ]; do sleep 0.05; done; "
        "printf y >> sibling-effect", "timeout_ms": None}, separators=(",", ":"))
    endpoint = fixture.SuccessEndpoint([
        fixture.sse_tool_calls("human-calls", [("bash", control_call, control_arguments)]),
        fixture.sse_answer("human-answer", "human-reason", "human-message", "first answer")[0],
        fixture.sse_answer("second-answer", "second-reason", "second-message", "second answer")[0],
        fixture.sse_tool_calls("sibling-calls", [("bash", "pending-call", arguments),
            ("bash", "running-call", sibling_arguments)]),
        fixture.sse_answer("sibling-answer", "sibling-reason", "sibling-message", "siblings done")[0],
    ])
    thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    thread.start()
    url = f"http://127.0.0.1:{endpoint.server_port}/responses"
    host = None
    failure_release = None
    stop_release = None
    observation_release = None
    race_predecessor_release = threading.Event()
    race_message_release = threading.Event()
    race_follower = None
    race_waiter = None
    terminal_waiter = None
    race_gate = state / "follow-queued-before-current"
    wait_gate = state / "wait-active-before-current"
    completed = False
    try:
        host = fixture.start_host(store, url)
        store_selection_cases(state, workspace, store)
        saved_capture_cases(state, store, workspace)
        preferences_home = state / "preferences-home"
        preferences_home.mkdir()
        fallback = preferences_home / ".local/share/rui/store"
        fresh_setup = run(preferences_home, "setup")
        assert f"Store: {fallback} (HOME fallback)" in fresh_setup
        assert "choose a supported provider" in fresh_setup and "Host: unavailable" in fresh_setup
        assert not (preferences_home / ".config").exists(), "inspection created private state"
        # The shorter preferences path fits while the unsaved Store fallback
        # does not. Independent provider publication still succeeds.
        max_path = os.pathconf(preferences_home, "PC_PATH_MAX")
        long_home = str(preferences_home) + "/." * ((max_path - 16 - len(str(preferences_home))) // 2)
        oversized_setup = run(long_home, "setup", "--provider", "codex")
        assert "Saved defaults" in oversized_setup and "Store unavailable" in oversized_setup
        assert "no alternate Store selected" in oversized_setup and "Host: unavailable" in oversized_setup
        assert (preferences_home / ".config/rui/preferences").read_text().endswith("provider=codex\nmodel=\n")
        invalid_home = os.fsencode(state) + b"/home-\xff"
        try:
            os.mkdir(invalid_home, mode=0o700)
        except OSError as err:
            if err.errno != errno.EILSEQ:
                raise
            # macOS filesystems may reject this name before Rui sees HOME.
        invalid = subprocess.run([os.fsencode(fixture.RUI), b"setup", b"--provider", b"codex"],
            env={**os.environb, b"HOME": invalid_home}, capture_output=True, timeout=20)
        assert invalid.returncode != 0 and b"InvalidHome" in invalid.stderr, invalid
        assert not os.path.exists(invalid_home + b"/.config"), invalid
        bidi_store = state / "store-\u202ehidden"
        bidi_store.mkdir(mode=0o700)
        bidi_home = state / "bidi-home"
        bidi_home.mkdir()
        canonical_bidi_store = bidi_store.resolve()
        assert "Store: " + str(canonical_bidi_store).replace("\u202e", "\\u202e") + " (saved)" in run(
            bidi_home, "setup", "--store", bidi_store)
        assert f"store={canonical_bidi_store}\n" in (bidi_home / ".config/rui/preferences").read_text()
        assert "HomeUnavailable" in subprocess.run([str(fixture.RUI), "setup"],
            env={key: value for key, value in os.environ.items() if key != "HOME"},
            capture_output=True, text=True).stderr
        alias = state / "store-alias"
        alias.symlink_to(store, target_is_directory=True)
        assert "Saved defaults" in run(preferences_home, "setup", "--store", alias,
            "--provider", "codex", "--model", "gpt-6-luna")
        saved = preferences_home / ".config/rui/preferences"
        assert saved.read_text() == f"version=1\nstore={store.resolve()}\nprovider=codex\nmodel=gpt-6-luna\n"
        preference_edits(preferences_home, store)
        original_preferences = saved.read_text()
        saved.write_text(original_preferences.replace("model=gpt-6-luna", "model=family=variant"))
        assert saved.read_text().endswith("provider=codex\nmodel=family=variant\n")
        assert "Model: family=variant" in run(preferences_home, "setup")
        saved.write_text(original_preferences)
        assert saved.stat().st_mode & 0o777 == 0o600
        assert saved.parent.stat().st_mode & 0o777 == 0o700
        missing_setup = run(preferences_home, "setup")
        assert str(store.resolve()) in missing_setup
        assert "credential: missing" in missing_setup and "No fallback" in missing_setup
        assert "Host: ready without managed Codex" in missing_setup
        linked_home = state / "linked-home"
        (linked_home / ".config").mkdir(parents=True)
        (linked_home / ".config/rui").symlink_to(saved.parent, target_is_directory=True)
        assert run(linked_home, "setup", "--store", store,
            "--provider", "codex", "--model", "gpt-6-luna", success=False) == ""
        assert saved.read_text() == f"version=1\nstore={store.resolve()}\nprovider=codex\nmodel=gpt-6-luna\n"
        backup = saved.parent / "saved-preferences"
        saved.rename(backup)
        os.mkfifo(saved, mode=0o600)
        try:
            blocked = subprocess.run([str(fixture.RUI), "setup"],
                env={**os.environ, "HOME": str(preferences_home)},
                capture_output=True, text=True, timeout=2)
            assert blocked.returncode != 0, blocked
        finally:
            saved.unlink()
            backup.rename(saved)
        retired_store = state / "retired-store"
        retired_store.mkdir(mode=0o700)
        assert "Saved defaults" in run(preferences_home, "setup", "--store", retired_store)
        retired_store.rmdir()
        unavailable_setup = run(preferences_home, "setup")
        assert str(retired_store) in unavailable_setup and "Store unavailable" in unavailable_setup
        assert "no alternate Store selected" in unavailable_setup and "Host: unavailable" in unavailable_setup
        assert "Saved defaults" in run(preferences_home, "setup", "--clear-model")
        assert saved.read_text().endswith("provider=codex\nmodel=\n")
        assert f"store={retired_store}\n" in saved.read_text()
        assert "Saved defaults" in run(preferences_home, "setup", "--model", "gpt-6-luna")
        assert "Saved defaults" in run(preferences_home, "setup", "--store", store)
        assert f"store={store.resolve()}\n" in saved.read_text()
        credential = saved.parent / "codex.json"
        lock = saved.parent / ".codex.json.lock"
        assert not credential.exists() and not lock.exists()
        codex_fixture.credentials(credential)
        configured_setup = run(preferences_home, "setup")
        assert "credential: configured locally" in configured_setup and "remote acceptance not checked" in configured_setup
        assert not lock.exists(), "status must not create a credential lock"
        fresh_provider_home = state / "fresh-provider-home"
        (fresh_provider_home / ".config/rui").mkdir(parents=True, mode=0o700)
        codex_fixture.credentials(fresh_provider_home / ".config/rui/codex.json")
        assert "Saved defaults" in run(fresh_provider_home, "setup", "--model", "gpt-6-luna")
        assert (fresh_provider_home / ".config/rui/preferences").read_text().endswith(
            "store=\nprovider=codex\nmodel=gpt-6-luna\n")
        credential.unlink()
        os.mkfifo(credential, mode=0o600)
        try:
            blocked = subprocess.run([str(fixture.RUI), "setup"],
                env={**os.environ, "HOME": str(preferences_home)},
                capture_output=True, text=True, timeout=2)
            assert blocked.returncode == 0 and "credential: error" in blocked.stdout, blocked
        finally:
            credential.unlink()
        codex_fixture.credentials(credential, state="refresh_pending")
        assert "credential: refresh required" in run(preferences_home, "setup")
        assert "state=refresh_pending" in credential.read_text(), "status must not refresh"
        credential.chmod(0o644)
        assert "credential: error" in run(preferences_home, "setup")
        credential.unlink()
        assert run(preferences_home, "setup", "--provider", "other", success=False) == ""
        assert "Saved defaults" in run(preferences_home, "setup", "--model", "other-model")
        assert saved.read_text().endswith("model=other-model\n")
        assert "Saved defaults" in run(preferences_home, "setup", "--model", "gpt-6-luna")
        assert saved.read_text().endswith("model=gpt-6-luna\n")
        assert run(preferences_home, "setup", "--store", state / "missing", success=False) == ""
        assert saved.read_text().endswith("model=gpt-6-luna\n")
        # A directory in the temporary-file slot is an honest save failure;
        # no partial replacement may appear as a saved preference.
        temp = saved.parent / "preferences.tmp"
        temp.mkdir()
        blocked = subprocess.run([str(fixture.RUI), "setup", "--store", str(store)],
            env={**os.environ, "HOME": str(preferences_home)},
            capture_output=True, text=True, timeout=2)
        assert blocked.returncode != 0 and "save failed: InsecurePreferenceFile" in blocked.stderr, blocked
        assert saved.read_text().endswith("model=gpt-6-luna\n")
        temp.rmdir()
        os.mkfifo(temp, mode=0o600)
        try:
            blocked = subprocess.run([str(fixture.RUI), "setup", "--store", str(store)],
                env={**os.environ, "HOME": str(preferences_home)},
                capture_output=True, text=True, timeout=2)
            assert blocked.returncode != 0, blocked
            assert saved.read_text().endswith("model=gpt-6-luna\n")
        finally:
            temp.unlink()
        codex_fixture.credentials(credential)
        saved.write_text(f"version=1\nstore={store.resolve()}\nprovider=retired\nmodel=old-model\n")
        stale = run(preferences_home, "setup")
        assert "credential: configured locally" in stale and "saved provider is unsupported; no fallback" in stale
        assert saved.read_text().endswith("provider=retired\nmodel=old-model\n")
        assert "Saved defaults" in run(preferences_home, "setup", "--store", store)
        assert saved.read_text().endswith("provider=retired\nmodel=old-model\n")
        assert "Saved defaults" in run(preferences_home, "setup", "--provider", "codex")
        assert saved.read_text().endswith("provider=codex\nmodel=\n")
        saved.write_text(f"version=1\nstore={store.resolve()}\nprovider=retired\nmodel=old-model\n")
        assert "Saved defaults" in run(preferences_home, "setup", "--provider", "codex", "--model", "gpt-6-luna")
        saved.write_text(f"version=1\nstore={store.resolve()}\nprovider=codex\nmodel=old-model\n")
        assert "Next Session: codex / old-model" in run(preferences_home, "setup")
        assert "Saved defaults" in run(preferences_home, "setup", "--model", "gpt-6-luna")
        saved.rename(saved.parent / "preferences.backup")
        sole = run(preferences_home, "setup")
        assert "Provider: not selected" in sole and "Next Session: codex / gpt-6-luna" in sole
        (saved.parent / "preferences.backup").rename(saved)
        credential.unlink()
        saved.write_text("version=9\n")
        assert run(preferences_home, "setup", success=False) == ""
        assert run(preferences_home, "setup", "--model", "another-model", success=False) == ""
        saved.write_text(f"version=1\nstore={store.resolve()}\nprovider=codex\nmodel=gpt-6-luna\n")
        saved.chmod(0o644)
        assert run(preferences_home, "setup", success=False) == ""
        saved.chmod(0o600)
        saved.rename(saved.parent / "real-preferences")
        saved.symlink_to("real-preferences")
        assert run(preferences_home, "setup", success=False) == ""
        saved.unlink()
        (saved.parent / "real-preferences").rename(saved)
        assert run(preferences_home, "setup", "--model", "bad\nmodel", success=False) == ""
        assert saved.read_text().endswith("model=gpt-6-luna\n")
        config = admit(home, "configure", "--store", store, "--session", session,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a",
            "--tools", "bash", "--permission-mode", "ask")
        assert config["admission"]["answer"]["status"] == "accepted", config
        # A one-shot read selects the saved Store; explicit targeting bypasses
        # even corrupt preferences, and an invalid saved destination never falls back.
        assert json.loads(run(preferences_home, "wait-session", "--session", session,
            "--json")) == {"return": "idle"}
        saved.write_text("version=9\n")
        assert run(preferences_home, "wait-session", "--session", session,
            "--json", success=False) == ""
        assert json.loads(run(preferences_home, "wait-session", "--store", store,
            "--session", session, "--json")) == {"return": "idle"}
        master, slave = pty.openpty()
        entered = subprocess.Popen([str(fixture.RUI), "session", "--store", str(store),
            "--session", session], env={**os.environ, "HOME": str(preferences_home)},
            stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            assert f"Session: {session}" in read_terminal(master, "rui> ")
            terminal_step(master, "/exit", "Detached.")
            assert entered.wait(timeout=5) == 0
        finally:
            if entered.poll() is None:
                entered.kill()
                entered.wait(timeout=5)
            os.close(master)
        saved.unlink()
        fallback.parent.mkdir(parents=True)
        fallback.symlink_to(store, target_is_directory=True)
        master, slave = pty.openpty()
        entered = subprocess.Popen([str(fixture.RUI), "session", "--session", session],
            env={**os.environ, "HOME": str(preferences_home)},
            stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            assert f"Session: {session}" in read_terminal(master, "rui> ")
            terminal_step(master, "/exit", "Detached.")
            assert entered.wait(timeout=5) == 0
        finally:
            if entered.poll() is None:
                entered.kill()
                entered.wait(timeout=5)
            os.close(master)
        fallback.unlink()
        saved.write_text(f"version=1\nstore={state / 'missing'}\nprovider=codex\nmodel=gpt-6-luna\n")
        saved.chmod(0o600)
        assert run(preferences_home, "wait-session", "--session", session,
            "--json", success=False) == ""
        master, slave = pty.openpty()
        entered = subprocess.run([str(fixture.RUI), "session", "--session", session],
            env={**os.environ, "HOME": str(preferences_home)}, stdin=slave,
            stdout=slave, stderr=subprocess.PIPE, timeout=5)
        os.close(slave)
        os.close(master)
        assert entered.returncode != 0 and b"FileNotFound" in entered.stderr, entered.stderr
        saved.write_text(f"version=1\nstore={store.resolve()}\nprovider=codex\nmodel=gpt-6-luna\n")
        assert json.loads(run(home, "wait-session", "--store", store, "--session", session,
            "--json")) == {"return": "idle"}
        before = run(preferences_home, "requests", "--json")
        invalid_store = subprocess.run([str(fixture.RUI), "message", "--store", "",
            "--session", session, "not sent"], env={**os.environ, "HOME": str(preferences_home)},
            capture_output=True, text=True, timeout=5)
        assert invalid_store.returncode != 0 and "InvalidStore" in invalid_store.stderr, invalid_store
        assert invalid_store.stdout == "" and run(preferences_home, "requests", "--json") == before
        no_tty_home = state / "no-tty-home"
        no_tty_home.mkdir()
        no_terminal = subprocess.run([str(fixture.RUI)], cwd=workspace,
            env={**os.environ, "HOME": str(no_tty_home)}, capture_output=True, text=True, timeout=5)
        assert no_terminal.returncode != 0 and "InteractiveTerminalRequired" in no_terminal.stderr
        assert not (no_tty_home / ".config").exists(), "non-TTY invocation created preferences or a request"
        assert not (no_tty_home / ".local/share/rui/store").exists(), "non-TTY invocation changed the Store"
        before_missing = set(run(preferences_home, "requests").splitlines())
        master, slave = pty.openpty()
        ready_read, ready_write = os.pipe()
        try:
            deferred = subprocess.Popen([str(fixture.RUI)], cwd=workspace,
                env={**os.environ, "HOME": str(preferences_home),
                    "RUI_TEST_ACTION_READY_FD": str(ready_write)},
                pass_fds=(ready_write,), stdin=slave, stdout=slave, stderr=slave)
        except BaseException:
            os.close(master)
            os.close(ready_read)
            raise
        finally:
            os.close(slave)
            os.close(ready_write)
        try:
            offered = provider_prompt(master, ready_read)
            assert "No locally ready provider" in offered and "Codex login" in offered, offered
            assert "No new Session created" in terminal_step(master, "d", "No new Session created")
            assert deferred.wait(timeout=5) == 0
            assert set(run(preferences_home, "requests").splitlines()) == before_missing
        finally:
            if deferred.poll() is None:
                deferred.kill()
                deferred.wait(timeout=5)
            os.close(ready_read)
            os.close(master)
        explicit_home = state / "explicit-home"
        explicit_config = explicit_home / ".config/rui"
        explicit_config.mkdir(parents=True, mode=0o700)
        malformed = explicit_config / "preferences"
        malformed.write_text("version=9\n")
        malformed.chmod(0o600)
        master, slave = pty.openpty()
        ready_read, ready_write = os.pipe()
        try:
            explicit = subprocess.Popen([str(fixture.RUI), "--store", str(store),
                "--provider", "codex", "--model", "gpt-6-luna"], cwd=workspace,
                env={**os.environ, "HOME": str(explicit_home),
                    "RUI_TEST_ACTION_READY_FD": str(ready_write)},
                pass_fds=(ready_write,), stdin=slave, stdout=slave, stderr=slave)
        except BaseException:
            os.close(master)
            os.close(ready_read)
            raise
        finally:
            os.close(slave)
            os.close(ready_write)
        try:
            assert "No locally ready provider" in provider_prompt(master, ready_read)
            # Another client installs a fixture credential while this caller
            # waits for a choice. Its explicit selectors must still bypass the
            # malformed prospective defaults when it rechecks readiness.
            codex_fixture.credentials(explicit_config / "codex.json")
            os.write(master, b"d\n")
            welcome = b""
            deadline = time.monotonic() + 10
            while b"rui> " not in welcome and time.monotonic() < deadline:
                if not select.select([master], [], [], max(0, deadline - time.monotonic()))[0]:
                    break
                try:
                    welcome += os.read(master, 65536)
                except OSError as err:
                    if err.errno != errno.EIO:
                        raise
                    break
            welcome = welcome.decode(errors="replace")
            assert "Session: rui/" in welcome and "Provider: codex" in welcome, welcome
            assert "Model: gpt-6-luna" in welcome, welcome
            assert malformed.read_text() == "version=9\n"
            assert "Detached." in terminal_step(master, "/exit", "Detached.")
            assert explicit.wait(timeout=5) == 0
        finally:
            if explicit.poll() is None:
                explicit.kill()
                explicit.wait(timeout=5)
            os.close(ready_read)
            os.close(master)
        # A valid opaque credential arrives while the prompt is open, then
        # becomes renewal-due before the choice. It remains usable for creation.
        (explicit_config / "codex.json").unlink()
        master, slave = pty.openpty()
        ready_read, ready_write = os.pipe()
        try:
            expiring = subprocess.Popen([str(fixture.RUI), "--store", str(store),
                "--provider", "codex", "--model", "gpt-6-luna"], cwd=workspace,
                env={**os.environ, "HOME": str(explicit_home),
                    "RUI_TEST_ACTION_READY_FD": str(ready_write)},
                pass_fds=(ready_write,), stdin=slave, stdout=slave, stderr=slave)
        except BaseException:
            os.close(master)
            os.close(ready_read)
            raise
        finally:
            os.close(slave)
            os.close(ready_write)
        try:
            assert "No locally ready provider" in provider_prompt(master, ready_read)
            expiry = int(time.time()) + 2
            credential_file = explicit_config / "codex.json"
            codex_fixture.credentials(credential_file)
            credential_file.write_text(credential_file.read_text().replace("expires_at=4102444800", f"expires_at={expiry}"))
            assert "credential: error" in run(preferences_home, "setup", environment={"RUI_CODEX_CREDENTIAL_FILE": str(credential_file)}), "JWT/record expiry mismatch was accepted"
            codex_fixture.credentials(credential_file, access="synthetic-opaque-access")
            credential_file.write_text(credential_file.read_text().replace("expires_at=4102444800", "expires_at=0").replace("refreshed_at=1750000000", f"refreshed_at={expiry - 8 * 24 * 60 * 60}"))
            while time.time() < expiry:
                time.sleep(0.01)
            assert "usable locally; renewal due at dispatch" in run(preferences_home, "setup", environment={"RUI_CODEX_CREDENTIAL_FILE": str(credential_file)})
            welcome = terminal_step(master, "d", "rui> ")
            assert "Session: rui/" in welcome and "Permission: bypass" in welcome, welcome
            assert "Detached." in terminal_step(master, "/exit", "Detached.")
            assert expiring.wait(timeout=5) == 0
            assert malformed.read_text() == "version=9\n"
        finally:
            if expiring.poll() is None:
                expiring.kill()
                expiring.wait(timeout=5)
            os.close(ready_read)
            os.close(master)
        longer_store = state / "another-longer-store-selector"
        other_host = fixture.start_host(longer_store, url)
        try:
            for index, (before, after) in enumerate(((store, longer_store), (longer_store, store))):
                changing_home = state / f"changing-home-{index}"
                changing_home.mkdir()
                assert "Saved defaults" in run(changing_home, "setup", "--store", before,
                    "--provider", "codex", "--model", "gpt-6-luna")
                master, slave = pty.openpty()
                ready_read, ready_write = os.pipe()
                try:
                    changing = subprocess.Popen([str(fixture.RUI)], cwd=workspace,
                        env={**os.environ, "HOME": str(changing_home),
                            "RUI_TEST_ACTION_READY_FD": str(ready_write)},
                        pass_fds=(ready_write,), stdin=slave, stdout=slave, stderr=slave)
                except BaseException:
                    os.close(master)
                    os.close(ready_read)
                    raise
                finally:
                    os.close(slave)
                    os.close(ready_write)
                try:
                    assert "No locally ready provider" in provider_prompt(master, ready_read)
                    assert "Saved defaults" in run(changing_home, "setup", "--store", after)
                    codex_fixture.credentials(changing_home / ".config/rui/codex.json")
                    welcome = terminal_step(master, "d")
                    assert "Diagnostics:" not in welcome, welcome
                    handle = next(line.split("request: ", 1)[1].strip() for line in welcome.splitlines()
                        if line.startswith("request: "))
                    selected = json.loads((changing_home / ".config/rui/requests" / f"{handle}.json").read_bytes())
                    assert selected["store"] == str(after.resolve()), selected
                    current = fixture.command("inspect-session", "--store", after,
                        "--session", f"rui/{handle}")
                    assert current["session"]["model"] == "gpt-6-luna", current
                    assert "Detached." in terminal_step(master, "/exit", "Detached.")
                    assert changing.wait(timeout=5) == 0
                finally:
                    if changing.poll() is None:
                        changing.kill()
                        changing.wait(timeout=5)
                    os.close(ready_read)
                    os.close(master)
        finally:
            fixture.stop_host(other_host)
        codex_fixture.credentials(credential)
        for tools, mode, warning in (("none", "bypass", False), ("edit", "bypass", False),
                                     ("bash,edit", "bypass", True), ("bash", "ask", False)):
            warning_ref = f"warnings/{tools}/{mode}"
            admit(preferences_home, "configure", "--store", store, "--session", warning_ref,
                  "--workspace", workspace, "--provider", "codex", "--model", "model-a",
                  "--tools", tools, "--permission-mode", mode)
            listing = run(preferences_home, "sessions", "--store", store, "--all")
            selected = listing.split(f"Session: {warning_ref}\n", 1)[1].split("Session: ", 1)[0]
            assert ("Bash runs without approval" in selected) == warning, selected
            master, slave = pty.openpty()
            caller = subprocess.Popen([str(fixture.RUI), "session", "--store", str(store), "--session", warning_ref],
                env={**os.environ, "HOME": str(preferences_home)}, stdin=slave, stdout=slave, stderr=slave)
            os.close(slave)
            try:
                welcome = read_terminal(master, "rui> ")
                assert ("Bash runs without approval" in welcome) == warning, welcome
                status = terminal_step(master, "/status")
                assert ("Bash runs without approval" in status) == warning, status
                terminal_step(master, "/exit", "Detached.")
                assert caller.wait(timeout=5) == 0
            finally:
                if caller.poll() is None:
                    caller.kill()
                    caller.wait(timeout=5)
                os.close(master)
        created = []
        for _ in range(2):
            master, slave = pty.openpty()
            caller = subprocess.Popen([str(fixture.RUI)], cwd=workspace,
                env={**os.environ, "HOME": str(preferences_home)},
                stdin=slave, stdout=slave, stderr=slave)
            os.close(slave)
            try:
                welcome = read_terminal(master, "rui> ")
                assert "Attached to the ready Host" not in welcome and "Diagnostics:" not in welcome, welcome
                handle = next(line.split("request: ", 1)[1].strip() for line in welcome.splitlines()
                    if line.startswith("request: "))
                reference = f"rui/{handle}"
                saved = json.loads((preferences_home / ".config/rui/requests" / f"{handle}.json").read_bytes())
                assert saved["require_model"] is True and saved["store"] == str(store.resolve())
                assert saved["session"] == reference and saved["configuration"]["workspace"] == {"state": "value", "value": str(workspace.resolve())}
                assert saved["configuration"]["tools"] == {"state": "value", "value": ["bash"]} and saved["configuration"]["permission_mode"] == {"state": "value", "value": "bypass"}
                assert f"Session: {reference}" in welcome and "Permission: bypass" in welcome, welcome
                assert f"Workspace (Bash cwd): {workspace.resolve()}" in welcome, welcome
                assert "Model: gpt-6-luna" in welcome and "Provider: codex" in welcome, welcome
                current = fixture.command("inspect-session", "--store", store, "--session", reference)
                assert current["session"]["permission_mode"] == "bypass", current
                assert current["session"]["workspace"] == str(workspace.resolve()), current
                assert json.loads(run(preferences_home, "recover", handle, "--json"))["answer"]["replayed"] is True
                created.append(reference)
                assert "Detached." in terminal_step(master, "/exit", "Detached.")
                assert caller.wait(timeout=5) == 0
            finally:
                if caller.poll() is None:
                    caller.kill()
                    caller.wait(timeout=5)
                os.close(master)
        assert created[0] != created[1], "independent new intent reused a reference"
        blocked_home = state / "blocked-capture-home"
        blocked_config = blocked_home / ".config/rui"
        blocked_config.mkdir(parents=True, mode=0o700)
        (blocked_config / "preferences").write_text(
            f"version=1\nstore={store.resolve()}\nprovider=codex\nmodel=gpt-6-luna\n")
        (blocked_config / "preferences").chmod(0o600)
        (blocked_config / "requests").write_text("not a directory")
        codex_fixture.credentials(blocked_config / "codex.json")
        sessions_before = run(preferences_home, "sessions", "--store", store, "--all", "--json")
        master, slave = pty.openpty()
        original_mode = termios.tcgetattr(master)
        blocked = subprocess.Popen([str(fixture.RUI)], cwd=workspace,
            env={**os.environ, "HOME": str(blocked_home)}, stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            # Capture fails before the send/uncertain-admission diagnostic.
            output = read_terminal(master, "error: NotDir")
            assert blocked.wait(timeout=5) == 1
            # The reaped caller has closed its PTY. Include any final output
            # before checking that no intent, handle or prompt escaped.
            while True:
                assert select.select([master], [], [], 0)[0], "failed caller retained its terminal"
                try:
                    tail = os.read(master, 65536)
                except OSError as error:
                    if error.errno != errno.EIO:
                        raise
                    break
                if not tail:
                    break
                output += tail.decode(errors="replace")
                assert len(output.encode()) < 1024 * 1024
            assert "New Session intent" not in output and "request: " not in output and "rui> " not in output, output
            assert termios.tcgetattr(master) == original_mode
            assert (blocked_config / "requests").read_text() == "not a directory"
            assert run(preferences_home, "sessions", "--store", store, "--all", "--json") == sessions_before
        finally:
            if blocked.poll() is None:
                blocked.kill()
                blocked.wait(timeout=5)
            os.close(master)
        before = set(run(preferences_home, "requests").splitlines())
        gate = state / "new-session-capture"
        master, slave = pty.openpty()
        interrupted = subprocess.Popen([str(fixture.RUI)], cwd=workspace,
            env={**os.environ, "HOME": str(preferences_home), "RUI_TEST_CAPTURE_GATE": str(gate)},
            stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            fixture.wait_for(lambda: pathlib.Path(f"{gate}.ready").exists(), "fresh configuration captured")
            early = os.read(master, 65536) if select.select([master], [], [], 0)[0] else b""
            assert b"New Session intent" not in early, "announced before the capture callback"
            after = set(run(preferences_home, "requests").splitlines())
            assert len(after - before) == 1, (before, after)
            handle = (after - before).pop()
            captured = json.loads((preferences_home / ".config/rui/requests" / f"{handle}.json").read_text())
            assert captured["require_model"] is True, captured
            interrupted.kill()
            interrupted.wait(timeout=5)
            recovered = json.loads(run(preferences_home, "recover", handle, "--json"))
            assert recovered["answer"]["status"] == "accepted" and not recovered["answer"]["replayed"], recovered
            recovered_again = json.loads(run(preferences_home, "recover", handle, "--json"))
            assert recovered_again["answer"]["replayed"], recovered_again
            assert fixture.command("inspect-session", "--store", store,
                "--session", f"rui/{handle}")["session"]["permission_mode"] == "bypass"
        finally:
            if interrupted.poll() is None:
                interrupted.kill()
                interrupted.wait(timeout=5)
            os.close(master)
        credential.unlink()
        initial = fixture.command("inspect-session", "--store", store, "--session", session)
        assert initial["selected_message"] is None and initial["recent_messages"] == [], initial
        assert "InteractiveTerminalRequired" in subprocess.run(
            [str(fixture.RUI), "session", "--store", str(store), "--session", session],
            env={**os.environ, "HOME": str(home)}, capture_output=True, text=True, timeout=5).stderr
        assert config["request"] in json.loads(run(home, "requests", "--json"))
        assert json.loads(run(home, "recover", config["request"], "--json"))["answer"]["replayed"] is True
        assert run(home, "recover", config["request"]) == (
            f"Store: {store}\nSession: {session}\nkey: {config['request']}\n"
            "admitted: accepted\nreplayed: true\nrevision: 1; created: true\n")

        text = state / "input"
        text.write_text("first input")
        dropped = run(home, "message", "--store", store, "--session", session,
            "--text", text, "--test-drop-reply", "after-commit", success=False)
        first = dropped.split("request: ", 1)[1].splitlines()[0]
        record = home / ".config/rui/requests" / f"{first}.json"
        captured = record.read_bytes()
        assert json.loads(captured)["text"]["value"] == "first input"
        text.write_text("changed after capture")
        assert first in run(home, "requests").splitlines()
        fixture.wait_for(lambda: len(endpoint.requests) == 1, "first provider request")
        recovered = json.loads(run(home, "recover", first, "--json"))
        assert recovered["answer"]["status"] == "accepted" and recovered["answer"]["replayed"] is True
        assert record.read_bytes() == captured
        assert len(endpoint.requests) == 1, endpoint.requests

        attention = run(home, "follow", first)
        assert "return: attention" in attention and "status: waiting_for_permission" in attention, attention
        action = attention.split("action: ", 1)[1].splitlines()[0]
        selected, blocked = map(json.loads, run(home, "wait-session", "--store", store,
            "--session", session, "--json").splitlines())
        assert selected == {"event": "selection", "session": session, "message": first}, selected
        assert blocked == {"return": "attention", "status": "waiting_for_permission", "action": action}, blocked
        terminal_waiter = subprocess.Popen([str(fixture.RUI), "wait-session", "--store", str(store),
            "--session", session, "--terminal", "--json"],
            env={**os.environ, "HOME": str(home)}, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        assert json.loads(terminal_waiter.stdout.readline()) == selected
        time.sleep(0.1)
        assert terminal_waiter.poll() is None, "terminal-only wait returned on permission"
        queued = admit(home, "message", "--store", store, "--session", session,
            "queued behind permission")["request"]
        assert run(home, "result", queued) == "admitted: accepted\nresult: queued\n"
        queued_fact = fixture.command("observe-command", "--store", store, "--key", queued)["observation"]
        assert queued_fact["queue"]["status"] == "queued" and queued_fact["progress"] == {
            "status": "waiting_for_permission", "action": action}, queued_fact
        scratch = state / "render-scratch"
        scratch.mkdir()
        render_environment = {"TMPDIR": str(scratch)}
        queued_attention = json.loads(run(home, "follow", queued, "--json", environment=render_environment))
        assert queued_attention == {"return": "attention", "status": "waiting_for_permission", "action": action}, queued_attention
        presentation = run(home, "inspect-action", "--store", store, "--session", session, "--action", action)
        assert f"Action {action}\n" in presentation, presentation
        assert json.loads(presentation.split("call ID: ", 1)[1].splitlines()[0]) == control_call, presentation
        assert json.loads(presentation.split("Bash arguments: ", 1)[1].splitlines()[0]) == control_arguments, presentation
        assert "\\u001b" in presentation and "\\u202e" in presentation and "\\r  " in presentation, presentation
        assert "\x1b" not in presentation and "\u202e" not in presentation and "\r" not in presentation, presentation
        fresh_home = state / "fresh-home"
        fresh_home.mkdir()
        assert not (fresh_home / ".config").exists()
        assert json.loads(run(fresh_home, "inspect-action", "--store", store, "--session", session,
            "--action", action, "--json", environment=render_environment)) == {"action": action, "call_id": control_call, "arguments": control_arguments}
        assert not (fresh_home / ".config").exists()
        assert list(scratch.iterdir()) == []
        unavailable = subprocess.run([str(fixture.RUI), "inspect-action", "--store", str(store),
            "--session", session, "--action", action, "--json"],
            env={**os.environ, "HOME": str(fresh_home), "TMPDIR": str(state / "missing-scratch")},
            capture_output=True, text=True, timeout=20)
        assert unavailable.returncode != 0 and unavailable.stdout == "", unavailable
        exact = json.loads(run(home, "inspect-action", "--store", store, "--session", session,
            "--action", action, "--json"))
        assert exact == {"action": action, "call_id": control_call, "arguments": control_arguments}, exact
        assert run(home, "result", first) == "admitted: accepted\nresult: processing\n"
        assert not counter.exists()

        lost_decision = run(home, "allow-action", "--store", store, "--session", session,
            "--action", action, "--test-drop-reply", "after-commit", success=False)
        decision_key = lost_decision.split("request: ", 1)[1].splitlines()[0]
        assert decision_key in run(home, "requests").splitlines()
        recovered_decision = json.loads(run(home, "recover", decision_key, "--json"))["answer"]
        assert recovered_decision["status"] == "accepted" and recovered_decision["replayed"] is True
        fixture.wait_for(lambda: fixture.completed_observation(store, first), "first saved answer")
        fixture.wait_for(lambda: fixture.completed_observation(store, queued), "queued answer after permission")
        terminal_output, terminal_error = terminal_waiter.communicate(timeout=10)
        assert terminal_waiter.returncode == 0 and json.loads(terminal_output)["observation"]["result"]["status"] == "completed", terminal_error
        terminal_waiter = None
        stale = admit(home, "deny-action", "--store", store, "--session", session,
            "--action", action)
        assert stale["admission"]["answer"]["status"] == "rejected", stale
        assert run(home, "result", queued) == "admitted: accepted\nresult: completed\nfirst answer\n"
        current = fixture.command("inspect-session", "--store", store, "--session", session)
        assert current["selected_message"] is None and [r["message"] for r in current["recent_messages"]] == [queued, first], current
        assert [r["outcome"] for r in current["recent_messages"]] == ["completed", "completed"], current
        assert json.loads(run(home, "wait-session", "--store", store, "--session", session,
            "--json")) == {"return": "idle"}
        master, slave = pty.openpty()
        ready_read, ready_write = os.pipe()
        try:
            entered = subprocess.Popen([str(fixture.RUI), "session", "--session", session],
                env={**os.environ, "HOME": str(preferences_home),
                    "RUI_TEST_ACTION_READY_FD": str(ready_write)},
                pass_fds=(ready_write,), stdin=slave, stdout=slave, stderr=slave)
        except BaseException:
            os.close(master)
            os.close(ready_read)
            raise
        finally:
            os.close(slave)
            os.close(ready_write)
        try:
            greeting = read_terminal(master, "rui> ")
            assert f"Session: {session}" in greeting and f"Workspace (Bash cwd): {workspace.resolve()}" in greeting, greeting
            assert "Provider: codex" in greeting and "Model: model-a" in greeting, greeting
            assert "Permission: ask" in greeting and "Store:" not in greeting and "Work: completed" not in greeting and queued not in greeting, greeting
            help_text = terminal_step(master, "/help")
            for command in ("/help", "/status", "/wait", "/requests", "/result KEY", "/setup", "/login", "/configure", "/exit"):
                assert command in help_text, help_text
            for explanation in ("/help shows", "/status inspects", "/wait follows", "/requests lists",
                "/result KEY reads", "/configure changes", "/exit detaches"):
                assert explanation in help_text, help_text
            assert "Assistant: first answer" in terminal_step(master, f"/result {queued}")
            assert "Local recovery handles" in terminal_step(master, "/requests")
            assert not (fresh_home / ".config/rui/requests").exists(), "re-entry should not require saved records"
            assert "No work to wait for." in terminal_step(master, "/wait")
            assert "gpt-6-luna" in terminal_step(master, "/setup")
            login_prompt = provider_prompt(master, ready_read, "/login")
            assert "Supported integration: Codex" in login_prompt and "defer leaves this Session" in login_prompt
            assert "Login deferred" in terminal_step(master, "d")
            assert not credential.exists(), "deferred login created credentials"
            invalid_prompt = provider_prompt(master, ready_read, "/login")
            assert "Codex" in invalid_prompt
            assert "No login or preference change" in terminal_step(master, "x")
            provider_prompt(master, ready_read, "/login")
            assert "No login or preference change" in terminal_step(master, "12345678901234567")
            provider_prompt(master, ready_read, "/login")
            os.write(master, b"\xff\n")
            assert "No login or preference change" in read_terminal(master, "rui> ")
            assert "Permission: ask" in terminal_step(master, "/status")
            assert not credential.exists()
            assert "Saved defaults for future Sessions" in terminal_step(master, "/setup --model gpt-6-luna")
            assert "Saved defaults for future Sessions" in terminal_step(master, "/setup --model other-model")
            interactive_saved = preferences_home / ".config/rui/preferences"
            assert "Saved defaults for future Sessions" in terminal_step(master, "/setup --clear-model")
            assert interactive_saved.read_text().endswith("provider=codex\nmodel=\n")
            cleared_preferences = interactive_saved.read_bytes()
            for command, error in (("/setup --clear-model --model gpt-6-luna", "ConflictingPreferenceModelEdit"),
                                   ("/setup --model gpt-6-luna --clear-model", "ConflictingPreferenceModelEdit"),
                                   ('/setup --model ""', "InvalidPreferenceModel")):
                assert error in terminal_step(master, command)
                assert interactive_saved.read_bytes() == cleared_preferences
            assert "Permission: ask" in terminal_step(master, "/status")
            active = fixture.command("inspect-session", "--store", store, "--session", session)["session"]
            assert active["model"] == "model-a" and active["permission_mode"] == "ask", active
            assert "Saved defaults for future Sessions" in terminal_step(master, "/setup --model gpt-6-luna")
            spaced_store = state / "spaced store"
            spaced_store.mkdir(mode=0o700)
            assert "Saved defaults for future Sessions" in terminal_step(master, f'/setup --store "{spaced_store}"')
            assert str(spaced_store.resolve()) in run(preferences_home, "setup")
            quoted_store = state / 'quoted "store"'
            quoted_store.mkdir(mode=0o700)
            escaped_store = str(quoted_store).replace('"', r'\"')
            assert "Saved defaults for future Sessions" in terminal_step(
                master, f'/setup --store "{escaped_store}"')
            assert str(quoted_store.resolve()).replace('"', r'\"') in run(preferences_home, "setup")
            assert "Usage: /setup" in terminal_step(master, '/setup --store "unfinished')
            assert str(quoted_store.resolve()).replace('"', r'\"') in run(preferences_home, "setup")
            assert "Saved defaults for future Sessions" in terminal_step(master, f'/setup --store "{store}"')
            assert "Permission: ask" in terminal_step(master, "/status")
            assert fixture.command("inspect-session", "--store", store,
                "--session", session)["session"]["model"] == "model-a"
            assert "Usage: /configure" in terminal_step(master, "/configure --session human/other")
            assert "Use a file for" in terminal_step(master, "/configure --instructions -")
            assert "Use a file for" in terminal_step(master, "/configure --output-schema -")
            assert f"Session: {session}" in terminal_step(master, "/status")
            configured = terminal_step(master, '/configure --model "model-a"')
            assert "Configured." in configured and "request:" not in configured, configured
            assert f"Session: {session}" in terminal_step(master, "/status")
            assert "Detached. Host work continues." in terminal_step(master, "/exit", "Detached.")
            assert entered.wait(timeout=5) == 0
        finally:
            if entered.poll() is None:
                entered.kill()
                entered.wait(timeout=5)
            os.close(ready_read)
            os.close(master)
        assert run(home, "follow", queued) == "return: outcome\nadmitted: accepted\nstatus: completed\n"
        assert run(home, "recover", stale["request"]) == (
            f"Store: {store}\nSession: {session}\nkey: {stale['request']}\n"
            f"target Action: {action}; decision: deny\n"
            "admitted: rejected\nreplayed: true\ncode: action_not_pending\n")
        stale_default = run(home, "deny-action", "--store", store, "--session", session,
            "--action", action)
        stale_key = stale_default.splitlines()[0].removeprefix("request: ")
        assert stale_default == (
            f"request: {stale_key}\nStore: {store}\nSession: {session}\nkey: {stale_key}\n"
            f"target Action: {action}; decision: deny\n"
            "admitted: rejected\nreplayed: false\ncode: action_not_pending\n"), stale_default
        assert run(home, "result", first) == "admitted: accepted\nresult: completed\nfirst answer\n"
        completed_result = json.loads(run(home, "result", first, "--json", environment=render_environment))
        assert completed_result["answer"] == "first answer"
        assert completed_result["observation"]["result"]["status"] == "completed"
        assert list(scratch.iterdir()) == []
        completed_follow = json.loads(run(home, "follow", first, "--json"))
        assert completed_follow["return"] == "outcome"
        assert completed_follow["observation"]["result"]["status"] == "completed"
        assert counter.read_text() == "x"

        before = set(run(home, "requests").splitlines())
        gate = state / "captured-before-handle"
        caller = subprocess.Popen(
            [str(fixture.RUI), "message", "--store", str(store), "--session", session,
             "--text", str(text), "--json"],
            env={**os.environ, "HOME": str(home), "RUI_TEST_CAPTURE_GATE": str(gate)},
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        fixture.wait_for(lambda: pathlib.Path(f"{gate}.ready").exists(), "durable capture before handle output")
        after = set(run(home, "requests").splitlines())
        assert len(after - before) == 1, (before, after)
        second = (after - before).pop()
        assert caller.poll() is None
        assert fixture.command("observe-command", "--store", store,
            "--key", second)["observation"]["status"] == "absent"
        caller.kill()
        output, _ = caller.communicate(timeout=5)
        assert caller.returncode == -signal.SIGKILL and output == b"", output
        assert second != first
        text.unlink()
        initial_recovery = json.loads(run(home, "recover", second, "--json"))["answer"]
        assert initial_recovery["status"] == "accepted" and initial_recovery["replayed"] is False
        fixture.wait_for(lambda: fixture.completed_observation(store, second), "second saved answer")
        assert run(home, "result", first) == "admitted: accepted\nresult: completed\nfirst answer\n"
        assert run(home, "result", second) == "admitted: accepted\nresult: completed\nsecond answer\n"
        assert counter.read_text() == "x" and len(endpoint.requests) == 3

        fixture.stop_host(host)
        host = fixture.start_host(store, url, active_capacity=2)
        sibling_session = "human/siblings"
        sibling_config = run(home, "configure", "--store", store, "--session", sibling_session,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a",
            "--tools", "bash", "--permission-mode", "ask")
        assert f"configuration: {sibling_session} in {store}" in sibling_config
        assert "next: rui session (same Store and Session)" in sibling_config
        sibling_key = admit(home, "message", "--store", store, "--session", sibling_session,
            "two independent Actions")["request"]
        def two_actions():
            candidate = fixture.command("inspect-session", "--store", store, "--session", sibling_session)
            return candidate if len(candidate["actionable_permissions"]) == 2 else None

        report = fixture.wait_for(two_actions, "two actionable siblings")
        pending, running = [row["action"] for row in report["actionable_permissions"]]
        selection, permissions, attention = map(json.loads, run(home, "wait-session", "--store", store,
            "--session", sibling_session, "--json").splitlines())
        assert selection["message"] == sibling_key, selection
        assert permissions == {"event": "actionable_permissions", "actions": [pending, running]}, permissions
        assert attention["return"] == "attention" and attention["action"] == pending, attention
        master, slave = pty.openpty()
        entered = subprocess.Popen([str(fixture.RUI), "session", "--store", str(store),
            "--session", sibling_session], env={**os.environ, "HOME": str(fresh_home)},
            stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            read_terminal(master, "rui> ")
            status = terminal_step(master, "/status")
            assert status.count("Action requiring attention: ") == 2, status
            assert f"Action requiring attention: {pending}" in status and f"Action requiring attention: {running}" in status, status
            terminal_step(master, "/exit", "Detached.")
            assert entered.wait(timeout=5) == 0
        finally:
            if entered.poll() is None:
                entered.kill()
                entered.wait(timeout=5)
            os.close(master)
        run(home, "allow-action", "--store", store, "--session", sibling_session,
            "--action", running)
        fixture.wait_for(lambda: sibling_started.exists(), "approved sibling in flight")
        attention = run(home, "follow", sibling_key, "--json")
        assert json.loads(attention) == {"return": "attention", "status": "in_flight", "action": pending}, attention
        assert run(home, "result", sibling_key) == "admitted: accepted\nresult: processing\n"
        master, slave = pty.openpty()
        entered = subprocess.Popen([str(fixture.RUI), "session", "--store", str(store),
            "--session", sibling_session], env={**os.environ, "HOME": str(home)},
            stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            read_terminal(master, "rui> ")
            os.write(master, b"/wait\n")
            waiting = read_terminal(master, "An Action needs your choice while other work remains in flight.")
            assert "Allow once, deny, or later?" not in waiting, waiting
            run(home, "deny-action", "--store", store, "--session", sibling_session,
                "--action", pending)
            sibling_release.touch()
            assert "Assistant: siblings done" in read_terminal(master, "rui> ")
            terminal_step(master, "/exit", "Detached.")
            assert entered.wait(timeout=5) == 0
        finally:
            sibling_release.touch()
            if entered.poll() is None:
                entered.kill()
                entered.wait(timeout=5)
            os.close(master)
        fixture.wait_for(lambda: fixture.completed_observation(store, sibling_key), "sibling outcome")
        assert run(home, "result", sibling_key) == "admitted: accepted\nresult: completed\nsiblings done\n"
        assert sibling_effect.read_text() == "y" and counter.read_text() == "x"

        failure_release = threading.Event()
        endpoint.responses.extend([
            (fixture.ResponseSpec(b"permanent failure", {}, 422), failure_release),
            fixture.sse_answer("successor-answer", "successor-reason", "successor-message", "successor done")[0],
        ])
        failure_session = "human/failure"
        run(home, "configure", "--store", store, "--session", failure_session,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a")
        failed_key = admit(home, "message", "--store", store, "--session", failure_session,
            "first failing Turn")["request"]
        fixture.wait_for(lambda: len(endpoint.requests) == 6, "held first failed Turn")
        queued_key = admit(home, "message", "--store", store, "--session", failure_session,
            "queued successor")["request"]
        assert run(home, "result", queued_key) == "admitted: accepted\nresult: queued\n"
        follower = subprocess.Popen([str(fixture.RUI), "follow", failed_key],
            env={**os.environ, "HOME": str(home)}, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        time.sleep(0.15)
        assert follower.poll() is None, follower.communicate(timeout=5)
        follower.kill()
        follower.communicate(timeout=5)
        failure_release.set()
        fixture.wait_for(lambda: fixture.command("observe-command", "--store", store,
            "--key", failed_key)["observation"].get("result"), "failed first Turn")
        assert run(home, "result", failed_key) == "admitted: accepted\nresult: failed\ncode: provider_http_422\n"
        fixture.wait_for(lambda: fixture.completed_observation(store, queued_key), "queued successor")
        assert run(home, "result", queued_key) == "admitted: accepted\nresult: completed\nsuccessor done\n"
        master, slave = pty.openpty()
        entered = subprocess.Popen([str(fixture.RUI), "session", "--store", str(store),
            "--session", failure_session], env={**os.environ, "HOME": str(home)},
            stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            read_terminal(master, "rui> ")
            failed = terminal_step(master, f"/result {failed_key}")
            assert "Rui: This saved Message failed; no answer was produced." in failed, failed
            assert "Rui: Code: provider_http_422" in failed and "successor done" not in failed, failed
            assert "Assistant: successor done" in terminal_step(master, f"/result {queued_key}")
            terminal_step(master, "/exit", "Detached.")
            assert entered.wait(timeout=5) == 0
        finally:
            if entered.poll() is None:
                entered.kill()
                entered.wait(timeout=5)
            os.close(master)

        stop_release = threading.Event()
        endpoint.responses.append((fixture.sse_answer("stopped-answer", "stopped-reason",
            "stopped-message", "must not appear")[0], stop_release))
        stop_session = "human/stopped"
        run(home, "configure", "--store", store, "--session", stop_session,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a")
        stopped_key = admit(home, "message", "--store", store, "--session", stop_session,
            "running when stopped")["request"]
        fixture.wait_for(lambda: len(endpoint.requests) == 8, "held stopped Turn")
        excluded_key = admit(home, "message", "--store", store, "--session", stop_session,
            "queued when stopped")["request"]
        assert run(home, "result", excluded_key) == "admitted: accepted\nresult: queued\n"
        stopped = fixture.command("stop-session", "--store", store, "--session", stop_session,
            "--record", state / "stop.json", "--key", "human-stop")
        assert stopped["answer"]["status"] == "accepted", stopped
        stop_release.set()
        fixture.wait_for(lambda: fixture.command("observe-command", "--store", store,
            "--key", stopped_key)["observation"].get("result"), "stopped Turn")
        assert run(home, "result", stopped_key).startswith("admitted: accepted\nresult: cancelled\n")
        assert run(home, "result", excluded_key) == "admitted: accepted\nresult: cancelled\ncode: session_stopped\n"

        rejected = admit(home, "message", "--store", store, "--session", "human/absent",
            "unknown session")
        assert rejected["admission"]["answer"]["status"] == "rejected", rejected
        assert run(home, "result", rejected["request"]) == "admitted: rejected\nresult: rejected\ncode: unknown_session\n"
        assert run(home, "recover", rejected["request"]) == (
            f"Store: {store}\nSession: human/absent\nkey: {rejected['request']}\n"
            "admitted: rejected\nreplayed: true\ncode: unknown_session\n")

        large_answer = "x" * 4095 + "🍰" + "y" * (128 * 1024)
        endpoint.responses.append(fixture.sse_answer("large-answer", "large-reason",
            "large-message", large_answer)[0])
        large_session = "human/large"
        run(home, "configure", "--store", store, "--session", large_session,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a")
        large_key = admit(home, "message", "--store", store, "--session", large_session,
            "large output")["request"]
        fixture.wait_for(lambda: fixture.completed_observation(store, large_key), "large saved answer")
        reader = subprocess.Popen([str(fixture.RUI), "result", large_key, "--json"],
            env={**os.environ, "HOME": str(home), **render_environment},
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            assert reader.stdout.read(256).startswith(b'{"observation":')
            assert reader.poll() is None, "large result should block on unread stdout"
            assert list(scratch.iterdir()) == [], "rendering must not leave a named payload"
        finally:
            if reader.poll() is None:
                reader.kill()
            reader.communicate(timeout=5)
        assert reader.returncode == -signal.SIGKILL and list(scratch.iterdir()) == []
        assert json.loads(run(home, "result", large_key, "--json", environment=render_environment))["answer"] == large_answer

        fixture.crash_host(host, state, "human-cli-crash")
        failed_observation = run(home, "result", first, success=False)
        assert failed_observation == "", failed_observation
        host = fixture.start_host(store, url)
        assert json.loads(run(home, "recover", first, "--json"))["answer"]["replayed"] is True
        assert run(home, "result", first) == "admitted: accepted\nresult: completed\nfirst answer\n"
        recovered_session = fixture.command("inspect-session", "--store", store, "--session", session)
        assert recovered_session["selected_message"] is None
        assert [row["message"] for row in recovered_session["recent_messages"]] == [second, queued, first]
        assert counter.read_text() == "x" and sibling_effect.read_text() == "y" and len(endpoint.requests) == 9

        endpoint.responses.extend([
            (fixture.sse_answer("race-prior", "race-prior-reason", "race-prior-message", "prior done")[0], race_predecessor_release),
            (fixture.sse_answer("race-a", "race-a-reason", "race-a-message", "A done")[0], race_message_release),
            fixture.sse_tool_calls("race-b", [("bash", "race-b-call", arguments)]),
            fixture.sse_answer("race-b-done", "race-b-done-reason", "race-b-done-message", "B done")[0],
        ])
        race_session = "human/follow-race"
        run(home, "configure", "--store", store, "--session", race_session,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a",
            "--tools", "bash", "--permission-mode", "ask")
        prior_receipt = run(home, "message", "--store", store, "--session", race_session, "prior")
        prior = prior_receipt.split("request: ", 1)[1].splitlines()[0]
        assert f"message: {race_session} in {store}" in prior_receipt
        assert "next: rui session (same Store and Session)" in prior_receipt
        assert "next: rui follow" not in prior_receipt
        fixture.wait_for(lambda: len(endpoint.requests) == 10, "held predecessor request")
        message_a = admit(home, "message", "--store", store, "--session", race_session, "A")["request"]
        assert run(home, "result", message_a) == "admitted: accepted\nresult: queued\n"
        race_follower = subprocess.Popen([str(fixture.RUI), "follow", message_a, "--json"],
            env={**os.environ, "HOME": str(home), "RUI_TEST_FOLLOW_GATE": str(race_gate)},
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        fixture.wait_for(lambda: pathlib.Path(f"{race_gate}.ready").exists(), "queued A observed by follower")
        assert race_follower.poll() is None
        assert run(home, "result", message_a) == "admitted: accepted\nresult: queued\n"
        race_predecessor_release.set()
        fixture.wait_for(lambda: len(endpoint.requests) == 11, "A processing request")
        race_waiter = subprocess.Popen([str(fixture.RUI), "wait-session", "--store", str(store),
            "--session", race_session, "--json"],
            env={**os.environ, "HOME": str(home), "RUI_TEST_FOLLOW_GATE": str(wait_gate)},
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        fixture.wait_for(lambda: pathlib.Path(f"{wait_gate}.ready").exists(), "Session wait selected A")
        race_message_release.set()
        fixture.wait_for(lambda: fixture.completed_observation(store, message_a), "A outcome before Current")
        fixture.wait_for(lambda: fixture.completed_observation(store, prior), "predecessor completion")
        message_b = admit(home, "message", "--store", store, "--session", race_session, "B")["request"]
        def b_action():
            report = fixture.command("inspect-session", "--store", store, "--session", race_session)
            return report["actionable_permissions"][0]["action"] if report["actionable_permissions"] else None

        action_b = fixture.wait_for(b_action, "B permission before Current")
        assert fixture.command("observe-command", "--store", store, "--key", message_a)["observation"]["result"]["status"] == "completed"
        pathlib.Path(f"{race_gate}.release").touch()
        pathlib.Path(f"{wait_gate}.release").touch()
        output, error = race_follower.communicate(timeout=10)
        assert race_follower.returncode == 0, (output, error)
        followed = json.loads(output)
        assert followed["return"] == "outcome" and followed["observation"]["result"]["status"] == "completed", followed
        assert followed["observation"]["target"] == race_session, followed
        race_follower = None
        wait_output, wait_error = race_waiter.communicate(timeout=10)
        assert race_waiter.returncode == 0, wait_error
        selection, observed = map(json.loads, wait_output.splitlines())
        assert selection["message"] == prior and observed["return"] == "outcome", wait_output
        assert observed["observation"]["result"]["status"] == "completed", wait_output
        race_waiter = None
        assert b_action() == action_b
        assert json.loads(run(home, "inspect-action", "--store", store, "--session", race_session,
            "--action", action_b, "--json"))["call_id"] == "race-b-call"
        denied = admit(home, "deny-action", "--store", store, "--session", race_session,
            "--action", action_b)
        assert denied["admission"]["answer"]["status"] == "accepted", denied
        fixture.wait_for(lambda: fixture.completed_observation(store, message_b), "B outcome after decision")
        control_call = "interactive-bash\x1b[1Ghidden\u202e"
        argument_prefix = '{"cmd":"printf x >> effect-count # '
        padded_arguments = json.dumps({"cmd": "printf x >> effect-count # " +
            "A" * (4095 - len(argument_prefix)) + "é", "timeout_ms": None},
            ensure_ascii=False, separators=(",", ":")) + "\r  "
        assert padded_arguments.encode()[4095:4097] == "é".encode()
        endpoint.responses.extend([
            fixture.sse_tool_calls("interactive-call", [("bash", control_call, padded_arguments)]),
            fixture.sse_answer("interactive-answer", "interactive-reason", "interactive-message",
                "interactive complete")[0],
        ])
        interactive = "human/interactive"
        run(home, "configure", "--store", store, "--session", interactive,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a",
            "--tools", "bash", "--permission-mode", "ask")
        master, slave = pty.openpty()
        ready_read, ready_write = os.pipe()
        try:
            entered = subprocess.Popen([str(fixture.RUI), "session", "--store", str(store),
                "--session", interactive], env={**os.environ, "HOME": str(home),
                    "RUI_TEST_ACTION_READY_FD": str(ready_write)},
                pass_fds=(ready_write,), stdin=slave, stdout=slave, stderr=slave)
        except BaseException:
            os.close(master)
            os.close(ready_read)
            raise
        finally:
            os.close(slave)
            os.close(ready_write)
        try:
            assert "Permission: ask" in read_terminal(master, "rui> ")
            os.write(master, b"interactive request\na\n")
            proposal = read_terminal(master, "Allow once, deny, or later?")
            action_ready(ready_read)
            assert counter.read_text() == "x", "pasted typeahead approved an unseen Action"
            assert "You: interactive request" in proposal, proposal
            assert "Rui: Work needs your decision." in proposal, proposal
            assert "call ID:" not in proposal and "request:" not in proposal and "return:" not in proposal, proposal
            assert json.loads(proposal.split("Bash arguments: ", 1)[1].splitlines()[0]) == padded_arguments, proposal
            assert "\\u00e9" in proposal
            assert "\\r  " in proposal and "\x1b" not in proposal and "\u202e" not in proposal, proposal
            interactive_key = fixture.command("inspect-session", "--store", store, "--session", interactive)["selected_message"]
            assert interactive_key is not None, proposal
            assert interactive_key in run(home, "requests").splitlines(), "hidden receipt must remain recoverable"
            action_id = proposal.split("Action ", 1)[1].splitlines()[0]
            current_action = fixture.command("inspect-session", "--store", store, "--session", interactive)
            assert [item["action"] for item in current_action["actionable_permissions"]] == [action_id], current_action
            mismatch = admit(home, "allow-action", "--store", store, "--session", session,
                "--action", action_id)
            assert mismatch["admission"]["answer"]["status"] == "rejected", mismatch
            assert mismatch["admission"]["answer"]["code"] == "target_mismatch", mismatch
            assert "No decision sent" in terminal_step(master, "l")
            assert "Bash arguments:" in terminal_step(master, "/wait", "Allow once, deny, or later?")
            action_ready(ready_read)
            os.write(master, b" a \n")
            assert "No decision sent" in read_terminal(master, "Allow once, deny, or later?")
            action_ready(ready_read)
            assert counter.read_text() == "x", "padded choice approved an Action"
            assert "No decision sent" in terminal_step(master, "l")
            assert "Bash arguments:" in terminal_step(master, "/wait", "Allow once, deny, or later?")
            action_ready(ready_read)
            rejected_choice = terminal_step(master, "\x1b[200~a\x1b[201~")
            assert "InvalidTerminalInput" in rejected_choice, rejected_choice
            assert counter.read_text() == "x", "marked paste approved an Action"
            assert "Bash arguments:" in terminal_step(master, "/wait", "Allow once, deny, or later?")
            action_ready(ready_read)
            completed_turn = terminal_step(master, "a")
            assert "Assistant: interactive complete" in completed_turn and "result:" not in completed_turn and "request:" not in completed_turn, completed_turn
            assert "Assistant: interactive complete" in terminal_step(master, "/result " + interactive_key)
            assert "Recent messages" in terminal_step(master, "/status")
            assert "Detached. Host work continues." in terminal_step(master, "/exit", "Detached.")
            assert entered.wait(timeout=5) == 0
            assert termios.tcgetattr(master)[3] & termios.ICANON, "terminal mode not restored"
            assert counter.read_text() == "xx", counter.read_text()
        finally:
            if entered.poll() is None:
                entered.kill()
                entered.wait(timeout=5)
            os.close(ready_read)
            os.close(master)
        control_session = "human/name\n\x1b[2J\u202e"
        run(home, "configure", "--store", store, "--session", control_session,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a")
        master, slave = pty.openpty()
        entered = subprocess.Popen([str(fixture.RUI), "session", "--store", str(store),
            "--session", control_session], env={**os.environ, "HOME": str(home)},
            stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            greeting = read_terminal(master, "rui> ")
            assert "Session: human/name\\n\\x1b[2J\\u202e" in greeting, greeting
            assert "\x1b[2J" not in greeting and "\u202e" not in greeting, greeting
            terminal_step(master, "/exit", "Detached.")
            assert entered.wait(timeout=5) == 0
        finally:
            if entered.poll() is None:
                entered.kill()
                entered.wait(timeout=5)
            os.close(master)
        unsafe_session = "human/unsafe-key"
        unsafe_key = "message\n\x1b[2J\u202e"
        unsafe_release = threading.Event()
        endpoint.responses.append((fixture.sse_answer("unsafe-answer", "unsafe-reason",
            "unsafe-message", "safe result")[0], unsafe_release))
        run(home, "configure", "--store", store, "--session", unsafe_session,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a")
        unsafe_text = state / "unsafe-input"
        unsafe_text.write_text("report status")
        run(home, "message", "--store", store, "--session", unsafe_session,
            "--record", state / "unsafe-record.json", "--key", unsafe_key, "--text", unsafe_text)
        fixture.wait_for(lambda: fixture.command("inspect-session", "--store", store,
            "--session", unsafe_session)["selected_message"] == unsafe_key, "unsafe key selected")
        waiter = subprocess.Popen([str(fixture.RUI), "wait-session", "--store", str(store),
            "--session", unsafe_session], env={**os.environ, "HOME": str(home)},
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            assert waiter.stdout.readline() == "selected message: message\\n\\x1b[2J\\u202e\n"
            master, slave = pty.openpty()
            entered = subprocess.Popen([str(fixture.RUI), "session", "--store", str(store),
                "--session", unsafe_session], env={**os.environ, "HOME": str(home)},
                stdin=slave, stdout=slave, stderr=slave)
            os.close(slave)
            try:
                read_terminal(master, "rui> ")
                status = terminal_step(master, "/status")
                assert "Current message: message\\n\\x1b[2J\\u202e" in status, status
                assert "\x1b[2J" not in status and "\u202e" not in status, status
                assert "Detached." in terminal_step(master, "/exit", "Detached.")
                assert entered.wait(timeout=5) == 0
            finally:
                if entered.poll() is None:
                    entered.kill()
                    entered.wait(timeout=5)
                os.close(master)
        finally:
            unsafe_release.set()
            waiter.communicate(timeout=10)
        fixture.wait_for(lambda: fixture.completed_observation(store, unsafe_key), "unsafe key result")
        assert fixture.command("inspect-session", "--store", store,
            "--session", unsafe_session)["recent_messages"][0]["message"] == unsafe_key
        master, slave = pty.openpty()
        entered = subprocess.Popen([str(fixture.RUI), "session", "--store", str(store),
            "--session", unsafe_session], env={**os.environ, "HOME": str(home)},
            stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            greeting = read_terminal(master, "rui> ")
            assert "Session: human/unsafe-key" in greeting, greeting
            status = terminal_step(master, "/status")
            assert "message\\n\\x1b[2J\\u202e: completed" in status, status
            assert "\x1b[2J" not in status and "\u202e" not in status, status
            assert "Detached." in terminal_step(master, "/exit", "Detached.")
            assert entered.wait(timeout=5) == 0
        finally:
            if entered.poll() is None:
                entered.kill()
                entered.wait(timeout=5)
            os.close(master)
        empty_session = "human/empty-key"
        run(home, "configure", "--store", store, "--session", empty_session,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a")
        empty_release = threading.Event()
        endpoint.responses.append((fixture.sse_answer("empty-answer", "empty-reason", "empty-message",
            "empty key answer")[0], empty_release))
        empty_input = state / "empty-input"
        empty_input.write_text("empty key input")
        admission = json.loads(run(home, "message", "--store", store, "--session", empty_session,
            "--record", state / "empty-record.json", "--key", "", "--text", empty_input))
        assert admission["answer"]["status"] == "accepted", admission
        fixture.wait_for(lambda: fixture.command("inspect-session", "--store", store,
            "--session", empty_session)["work"]["status"] == "in_flight", "empty key active")
        current = fixture.command("inspect-session", "--store", store, "--session", empty_session)
        assert current["selected_message"] == "", current
        empty_wait = subprocess.Popen([str(fixture.RUI), "wait-session", "--store", str(store),
            "--session", empty_session, "--json"],
            env={**os.environ, "HOME": str(home)}, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            assert json.loads(empty_wait.stdout.readline()) == {"event": "selection", "session": empty_session, "message": ""}
            empty_release.set()
            assert json.loads(empty_wait.stdout.readline())["observation"]["result"]["status"] == "completed"
            assert empty_wait.wait(timeout=10) == 0
        finally:
            empty_release.set()
            if empty_wait.poll() is None:
                empty_wait.kill()
                empty_wait.communicate(timeout=5)
        current = fixture.command("inspect-session", "--store", store, "--session", empty_session)
        assert current["selected_message"] is None and current["recent_messages"][0]["message"] == "", current
        endpoint.responses.append(fixture.sse_answer("long-answer", "long-reason", "long-message", "long input intact")[0])
        long_session = "human/long-input"
        run(home, "configure", "--store", store, "--session", long_session,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a")
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 40, 0, 0))
        entered = subprocess.Popen([str(fixture.RUI), "session", "--store", str(store),
            "--session", long_session], env={**os.environ, "HOME": str(home)},
            stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            greeting = read_terminal(master, "rui> ")
            assert "Permission: bypass (Bash runs without approval)" in greeting, greeting
            assert "Rui: Bash commands can run without asking you." in greeting, greeting
            assert "Provider: codex" in greeting and "Model: model-a" in greeting, greeting
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 2048, 0, 0))
            before = len(endpoint.requests)
            long_text = "X" * 5000
            answer = terminal_bulk(master, long_text)
            assert "long input intact" in answer, answer
            assert len(endpoint.requests) == before + 1
            body = json.loads(endpoint.requests[-1])
            assert next(item["content"][0]["text"] for item in reversed(body["input"])
                if item.get("role") == "user") == long_text
            rejected = terminal_bulk(master, "Y" * (64 * 1024 + 1) + "\x7f")
            assert "input too long" in rejected and "nothing sent" in rejected, rejected[-1000:]
            assert len(endpoint.requests) == before + 1, "oversized input reached Host"
            rejected = terminal_step(master, "invalid\x00x")
            assert "InvalidTerminalInput" in rejected and "--text FILE" not in rejected, rejected
            assert len(endpoint.requests) == before + 1, "unsupported control reached Host"
            assert "Detached. Host work continues." in terminal_step(master, "/exit", "Detached.")
            assert entered.wait(timeout=5) == 0
            assert termios.tcgetattr(master)[3] & termios.ICANON
        finally:
            if entered.poll() is None:
                entered.kill()
                entered.wait(timeout=5)
            os.close(master)
        editor_session = "human/editor"
        run(home, "configure", "--store", store, "--session", editor_session,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a")
        cases = [
            ("first second\x1b\x7fZ", "first Z"),
            ("A中e\u0301🧑‍🌾\x7f", "A中e\u0301"),
            ("\x1b[200~line1\nline2\x1b[201~", "line1\nline2"),
            ("\x1b[200~a\n\u0301\x1b[201~\x01\x7f\x7fZ", "Z"),
            ("ab\x01\x04\x05\x04", "b"),
            ("ask src/foo-bar\x17", "ask "),
            ("\x1b[123;4~Z", "Z"),
            ("\x1bZ", "Z"),
            ("abc\x1b[D\x1b[DZ", "aZbc"),
            ("\x1b[200~line1\nline2\x1b[201~\x1b[A\x01X", "Xline1\nline2"),
        ]
        endpoint.responses.extend(fixture.sse_answer(f"editor-answer-{i}", f"editor-reason-{i}",
            f"editor-message-{i}", f"edited {i}")[0] for i in range(len(cases)))
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 2048, 0, 0))
        entered = subprocess.Popen([str(fixture.RUI), "session", "--store", str(store),
            "--session", editor_session], env={**os.environ, "HOME": str(home)},
            stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            read_terminal(master, "rui> ")
            for index, (typed, expected) in enumerate(cases):
                if index == 0:
                    os.write(master, b"first second\x1b\x7f")
                    repaint = read_terminal(master, "rui> first ")
                    assert "\x1b[0J" in repaint, repaint
                    observed = terminal_step(master, "Z", f"edited {index}")
                elif index == 1:
                    os.write(master, typed.encode())
                    repaint = read_terminal(master, "rui> A中e\u0301")
                    assert "\x1b[0J" in repaint, repaint
                    observed = terminal_step(master, "", f"edited {index}")
                elif typed == "abc\x1b[D\x1b[DZ":
                    os.write(master, b"abc\x1b[")
                    time.sleep(0.2)  # A recognized CSI must outlive the bare-ESC ambiguity timeout.
                    observed = terminal_step(master, "D\x1b[DZ", f"edited {index}")
                else:
                    observed = terminal_step(master, typed, f"edited {index}")
                assert f"edited {index}" in observed, observed
                if index == 2:
                    assert "You: line1\\nline2" in observed, observed
                    assert "Assistant: edited 2" in observed, observed
                if "rui> " not in observed.split(f"edited {index}", 1)[1]:
                    read_terminal(master, "rui> ")
                body = json.loads(endpoint.requests[-1])
                actual = next(item["content"][0]["text"] for item in reversed(body["input"])
                    if item.get("role") == "user")
                assert actual == expected, (typed, expected, actual)
            for index, (cluster, count) in enumerate((("a", 1000), ("e\u0301", 500))):
                marker = f"burst edited {index}"
                endpoint.responses.append(fixture.sse_answer(f"burst-answer-{index}",
                    f"burst-reason-{index}", f"burst-message-{index}", marker)[0])
                observed = terminal_bulk(master, cluster * count + "\x7f" * count + "Z", marker)
                assert len(observed.encode()) < 100_000, "tail deletion repainted the whole draft per key"
                body = json.loads(endpoint.requests[-1])
                actual = next(item["content"][0]["text"] for item in reversed(body["input"])
                    if item.get("role") == "user")
                assert actual == "Z", actual
                if "rui> " not in observed.split(marker, 1)[1]:
                    read_terminal(master, "rui> ")
            endpoint.responses.append(fixture.sse_answer("paced-answer", "paced-reason",
                "paced-message", "paced edited")[0])
            os.write(master, b"a" * 100)
            read_terminal(master, "a" * 100)
            for _ in range(100):
                os.write(master, b"\x7f")
                time.sleep(0.025)  # Longer than the editor's repaint window.
            observed = terminal_step(master, "Z", "paced edited")
            assert len(observed.encode()) < 3000, "paced ASCII deletion repainted the whole draft"
            body = json.loads(endpoint.requests[-1])
            actual = next(item["content"][0]["text"] for item in reversed(body["input"])
                if item.get("role") == "user")
            assert actual == "Z", actual
            if "rui> " not in observed.split("paced edited", 1)[1]:
                read_terminal(master, "rui> ")
            before = len(endpoint.requests)
            rejected = terminal_bulk(master, "a" * 2050 + "\x7f" * 2048,
                "cannot place the terminal cursor reliably")
            assert "nothing sent" in rejected, rejected[-1000:]
            assert len(endpoint.requests) == before, "a batch made an originally wrapped draft editable"
            if "rui> " not in rejected.split("cannot place the terminal cursor reliably", 1)[1]:
                read_terminal(master, "rui> ")
            for invalid in (b"\xc3(\n", b"\xc3\n"):
                os.write(master, invalid)
                rejected = read_terminal(master, "rui> ")
                assert "InvalidTerminalInput" in rejected, rejected
            assert len(endpoint.requests) == before, "malformed UTF-8 reached Host"
            endpoint.responses.append(fixture.sse_answer("editor-limit-answer", "editor-limit-reason",
                "editor-limit-message", "limit accepted")[0])
            at_limit = "a" * (64 * 1024 - 2) + "é"
            accepted = terminal_bulk(master, at_limit, "limit accepted")
            assert "limit accepted" in accepted, accepted[-1000:]
            body = json.loads(endpoint.requests[-1])
            assert next(item["content"][0]["text"] for item in reversed(body["input"])
                if item.get("role") == "user") == at_limit
            if "rui> " not in accepted.split("limit accepted", 1)[1]:
                read_terminal(master, "rui> ")
            before = len(endpoint.requests)
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 12, 0, 0))
            rejected = terminal_step(master, "A中e\u0301\x1b[D")
            assert "cannot place the terminal cursor reliably" in rejected and "--text FILE" in rejected, rejected
            assert len(endpoint.requests) == before, "uncertain display submitted a Message"
            os.write(master, b"\x04")
            assert "Detached. Host work continues." in read_terminal(master, "Detached.")
            assert entered.wait(timeout=5) == 0
            assert termios.tcgetattr(master)[3] & termios.ICANON
        finally:
            if entered.poll() is None:
                entered.kill()
                entered.wait(timeout=5)
            os.close(master)
        master, slave = pty.openpty()
        entered = subprocess.Popen([str(fixture.RUI), "session", "--store", str(store),
            "--session", empty_session], env={**os.environ, "HOME": str(fresh_home)},
            stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            assert "Recent messages" not in read_terminal(master, "rui> ")
            fixture.wait_for(lambda: not termios.tcgetattr(master)[3] & termios.ICANON,
                "terminal ready for Ctrl+C")
            os.write(master, b"\x03")
            assert "Detached. Host work continues." in read_terminal(master, "Detached.")
            assert entered.wait(timeout=5) == 0
            assert termios.tcgetattr(master)[3] & termios.ICANON
        finally:
            if entered.poll() is None:
                entered.kill()
                entered.wait(timeout=5)
            os.close(master)
        # Independent read-only callers can wait for the same production
        # deadline together; keep every input class and restoration assertion.
        incomplete_callers = []
        before = len(endpoint.requests)
        try:
            for incomplete in (b"\xc3", b"\x1b[200~unfinished", b"\x1b[", b"\x1bO"):
                master, slave = pty.openpty()
                try:
                    entered = subprocess.Popen([str(fixture.RUI), "session", "--store", str(store),
                        "--session", empty_session], env={**os.environ, "HOME": str(fresh_home)},
                        stdin=slave, stdout=slave, stderr=slave)
                except BaseException:
                    os.close(master)
                    raise
                finally:
                    os.close(slave)
                incomplete_callers.append((master, entered))
                read_terminal(master, "rui> ")
                os.write(master, incomplete)
            for master, entered in incomplete_callers:
                assert "IncompleteTerminalInput" in read_terminal(master, "IncompleteTerminalInput", timeout=7)
                assert entered.wait(timeout=5) != 0
                assert termios.tcgetattr(master)[3] & termios.ICANON
            assert len(endpoint.requests) == before, "incomplete terminal input reached Host"
        finally:
            for master, entered in incomplete_callers:
                if entered.poll() is None:
                    entered.kill()
                    entered.wait(timeout=5)
                os.close(master)
        observation_release = threading.Event()
        endpoint.responses.append((fixture.sse_answer("observed-later", "observed-later-reason",
            "observed-later-message", "observed later")[0], observation_release))
        observation_gate = state / "accepted-before-observation-loss"
        master, slave = pty.openpty()
        entered = subprocess.Popen([str(fixture.RUI), "session", "--store", str(store),
            "--session", empty_session], env={**os.environ, "HOME": str(home),
                "RUI_TEST_FOLLOW_GATE": str(observation_gate)}, stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            read_terminal(master, "rui> ")
            before = set(run(home, "requests").splitlines())
            os.write(master, b"observe after Host loss\n")
            # Own PTY output credit until the coherent observation gate, then
            # transfer reading back to the prompt helper. Keep the same budget.
            deadline = time.monotonic() + 8
            transcript = bytearray()
            while True:
                remaining = deadline - time.monotonic()
                assert remaining > 0, "timed out waiting for accepted Message observed before Host crash"
                if pathlib.Path(f"{observation_gate}.ready").exists():
                    break
                if select.select([master], [], [], min(remaining, 0.025))[0]:
                    transcript.extend(os.read(master, 65536))
                    assert len(transcript) < 1024 * 1024, "unexpected unbounded terminal output"
            after = set(run(home, "requests").splitlines())
            assert len(after - before) == 1, (before, after)
            saved_key = (after - before).pop()
            assert fixture.command("observe-command", "--store", store,
                "--key", saved_key)["observation"]["status"] == "accepted"
            fixture.crash_host(host, state, "accepted-before-observation-loss")
            pathlib.Path(f"{observation_gate}.release").touch()
            lost = (transcript.decode(errors="replace").replace("\r\n", "\n")
                .replace("\x1b[?2004h", "").replace("\x1b[?2004l", ""))
            lost += read_terminal(master, "rui> ")
            assert "Message accepted, but later observation or presentation failed" in lost, lost
            assert f"rui result {saved_key}" in lost, lost
            assert "admission may be uncertain" not in lost and "do not resubmit it" in lost, lost
            assert entered.poll() is None and set(run(home, "requests").splitlines()) == after
            terminal_step(master, "/exit", "Detached.")
            assert entered.wait(timeout=5) == 0
            endpoint.responses.append(fixture.sse_answer("observed-recovery", "observed-recovery-reason",
                "observed-recovery-message", "observed after recovery")[0])
            host = fixture.start_host(store, url)
            assert fixture.command("observe-command", "--store", store,
                "--key", saved_key)["observation"]["status"] == "accepted"
        finally:
            observation_release.set()
            if entered.poll() is None:
                entered.kill()
                entered.wait(timeout=5)
            os.close(master)
        completed = True
        print("human CLI: saved recovery, Session wait/re-entry, exact PTY approval, bounded input and Host restart passed")
    finally:
        sibling_release.touch()
        if failure_release is not None:
            failure_release.set()
        if stop_release is not None:
            stop_release.set()
        if observation_release is not None:
            observation_release.set()
        race_predecessor_release.set()
        race_message_release.set()
        if terminal_waiter is not None and terminal_waiter.poll() is None:
            terminal_waiter.kill()
            terminal_waiter.communicate(timeout=5)
        if race_follower is not None and race_follower.poll() is None:
            race_follower.kill()
            race_follower.communicate(timeout=5)
        if race_waiter is not None and race_waiter.poll() is None:
            race_waiter.kill()
            race_waiter.communicate(timeout=5)
        if host is not None:
            fixture.stop_host(host)
        endpoint.shutdown()
        endpoint.server_close()
        thread.join(timeout=5)
        if completed:
            shutil.rmtree(state)
        else:
            print(f"retained human CLI failure state: {state}", file=sys.stderr)


if __name__ == "__main__":
    main()
