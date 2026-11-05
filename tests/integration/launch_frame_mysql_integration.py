#!/usr/bin/env python3
"""The launch-frame contract against CI's live MySQL Store.

No server is started locally. Like the Store's live tests, this skips when
RUI_TEST_MYSQL_* is absent, and fails when CI requires MySQL but omitted it.
"""
import contextlib
import json
import os
import pathlib
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
from urllib.parse import quote

import host_process
import live_engines
import os_semantics
import launch_frame_integration as frame_host


def main():
    host_process.enter()
    socket = os.environ.get(live_engines.MYSQL_SOCKET)
    password = os.environ.get(live_engines.MYSQL_ROOT_PASSWORD)
    if not socket or not password:
        assert "mysql" not in os.environ.get(live_engines.REQUIRE, "").split(","), "CI required MySQL but did not supply the launch fixture"
        print("MySQL launch frame: skipped (no RUI_TEST_MYSQL_* server)")
        return
    rui, admin = map(lambda arg: str(pathlib.Path(arg).resolve()), sys.argv[1:3])
    root = host_process.canonical_fixture_root(tempfile.mkdtemp(prefix="rui-mysql-launch-"))
    database = "rui_launch_" + secrets.token_hex(6)
    # This URL exists only in the fixture's memory and the child's stdin.
    url = f"mysql://root:{quote(password, safe='')}@{quote(socket, safe='')}/{database}"
    runtime = root / "run"
    runtime.mkdir(mode=0o700)
    sock = runtime / "rui.sock"
    good = {"v": 1, "store": url, "runtimeDir": str(runtime), "activeCapacity": 2,
            "provider": {"kind": "openai_key", "baseUrl": "https://api.openai.com/v1", "key": "sk-mysql-launch-test"}}
    children = []

    def sql(text):
        return subprocess.run([admin], input=text, text=True, capture_output=True, check=True).stdout.strip()

    def launch(value):
        # The CI fixture credentials are not inherited by the Host itself.
        env = {key: os.environ[key] for key in ("PATH", "HOME", "TMPDIR") if key in os.environ}
        child = subprocess.Popen([rui, "host", "serve", "--launch-frame"], stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        children.append(child)
        child.stdin.write(frame_host.frame(value))
        child.stdin.flush()
        return child

    def released():
        # MySQL ends an exited Host's session, and its GET_LOCK, a little
        # after the socket closes, so a relaunch waits for the lock to free.
        host_process.wait_for(lambda: sql(f"SELECT IS_FREE_LOCK('{database}')") == "1",
                              "the exited Host's Store lock", timeout=20)

    def ready(child):
        try:
            frame_host.wait_for_socket(sock, child)
        except AssertionError:
            if child.poll() is None:
                raise
            out, err = child.communicate(timeout=5)
            raise AssertionError(f"the Host exited {child.returncode} before its socket appeared: stdout={out!r} stderr={err!r}")
        info = frame_host.host_info(sock, "")
        assert re.fullmatch("[0-9a-f]{32}", info["store"]), "readiness did not report a Store id"
        assert info["active_capacity"] == "2"
        assert info["innodb_doublewrite"] == sql("SELECT @@global.innodb_doublewrite")
        assert not (runtime / "host.lock").exists(), "MySQL must not use a filesystem Store lock"
        return info["store"]

    def private(child):
        for path in runtime.rglob("*"):
            if path.is_file():
                data = path.read_bytes()
                assert url.encode() not in data and password.encode() not in data, "login reached a runtime file"
        if os_semantics.PROC_FS:
            for name in ("cmdline", "environ"):
                data = pathlib.Path(f"/proc/{child.pid}/{name}").read_bytes()
                assert url.encode() not in data and password.encode() not in data, f"login reached {name}"

    def close(child):
        child.stdin.close()
        assert child.wait(timeout=20) == 0, "stdin close did not cleanly stop the Host"
        assert not sock.exists(), "the stopped Host retained its socket"

    try:
        sql(f"CREATE DATABASE {database} CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_bin")
        missing = launch(good)
        assert frame_host.refusal(missing)["code"] == "store_schema_missing"
        released()
        ddl = subprocess.run([rui, "store", "schema", "--engine", "mysql"], check=True, capture_output=True, text=True).stdout
        assert "CREATE TABLE store_meta" in ddl
        sql(f"USE {database};" + ddl)
        sql(f"INSERT INTO {database}.store_meta VALUES('format','0')")
        assert frame_host.refusal(launch(good))["code"] == "store_schema_behind"
        sql(f"DELETE FROM {database}.store_meta")
        released()
        host = launch(good)
        store_id = ready(host)
        assert store_id == sql(f"SELECT meta_value FROM {database}.store_meta WHERE meta_key='store_id'")
        other = root / "other"
        other.mkdir(mode=0o700)
        locked = launch(dict(good, runtimeDir=str(other)))
        assert frame_host.refusal(locked)["code"] == "store_locked"
        fields = {name: {"state": "omitted"} for name in
                  ("workspace", "provider", "model", "instructions", "tools", "permission_mode", "output_schema")}
        for name, value in (("workspace", str(root)), ("provider", "openai"), ("model", "gpt-6-luna"),
                            ("instructions", ""), ("tools", []), ("permission_mode", "bypass")):
            fields[name] = {"state": "value", "value": value}
        configured = frame_host.post(sock, "configure", {"version": frame_host.WIRE, "kind": "configure", "store": store_id,
                                                        "key": "mysql-launch-create", "session": "", "configuration": fields})
        assert configured["answer"]["status"] == "accepted", configured
        session = configured["answer"]["session"]
        request = {"version": frame_host.WIRE, "kind": "inspect_session", "store": store_id, "session": session}
        wrong = frame_host.post(sock, "inspect-session", dict(request, store="0" * 32), expected_status=409)
        assert wrong["code"] == "wrong_store_identity", wrong
        empty = frame_host.post(sock, "inspect-session", dict(request, store=""), expected_status=409)
        assert empty["code"] == "wrong_store_identity", empty
        observed = frame_host.post(sock, "inspect-session", request)
        assert observed["session"]["reference"] == session, observed
        # CLI/Bash peers route by the non-secret runtime hint, never the URL.
        env = dict(os.environ, RUI_RUNTIME_DIR=str(runtime))
        status = subprocess.run([rui, "host", "status", "--store", store_id], env=env, text=True, capture_output=True, check=True)
        status = json.loads(status.stdout)
        assert status["store"] == store_id and status["innodb_doublewrite"] == sql("SELECT @@global.innodb_doublewrite")
        assert status["diagnostics"] == str(runtime / "diagnostics")
        private(host)
        close(host)
        released()
        host = launch(good)
        assert ready(host) == store_id, "the Store id changed across a Host restart"
        assert frame_host.post(sock, "inspect-session", request)["session"]["reference"] == session
        private(host)
        connection = sql(f"SELECT ID FROM information_schema.PROCESSLIST WHERE DB='{database}'")
        assert connection.isdecimal(), "expected one Host connection"
        sql(f"KILL CONNECTION {connection}")
        # Drive a canonical read so the Store observes the killed connection.
        with contextlib.suppress(OSError, AssertionError):
            frame_host.post(sock, "inspect-session", request)
        code = host.wait(timeout=20)
        assert code == 1, f"a fenced MySQL Store exited {code}, not 1: {frame_host.output(host)!r}"
        out, err = frame_host.output(host)
        # stdout holds the readiness line, then exactly one named exit (D211).
        lines = out.decode().splitlines()
        assert len(lines) == 2 and lines[0].startswith("ready ") and json.loads(lines[1])["rui_start_error"]["code"] == "store_fenced", \
            f"missing named store_fenced exit: stdout={out!r} stderr={err[-4000:]!r}"
        print("MySQL launch frame: readiness, Session round trip, stable id, private credentials, store_locked, stdin close, store_fenced")
    finally:
        primary = sys.exception()
        cleanup_errors = []
        for child in children:
            try:
                if child.poll() is None:
                    child.kill()
                frame_host.output(child)
            except Exception as error:
                cleanup_errors.append(error)
        try:
            sql(f"DROP DATABASE IF EXISTS {database}")
        except Exception as error:
            cleanup_errors.append(error)
        try:
            shutil.rmtree(root)
        except Exception as error:
            cleanup_errors.append(error)
        if cleanup_errors:
            if primary is not None:
                for error in cleanup_errors:
                    primary.add_note(f"MySQL fixture cleanup also failed: {error}")
            else:
                raise ExceptionGroup("MySQL fixture cleanup failed", cleanup_errors)


if __name__ == "__main__":
    main()
