#!/usr/bin/env python3
"""The settings-document contract against CI's live MySQL Store.

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
import settings_fixture as frame_host
import store_rounds_cases


def main():
    host_process.enter()
    socket = os.environ.get(live_engines.MYSQL_SOCKET)
    password = os.environ.get(live_engines.MYSQL_ROOT_PASSWORD)
    if not socket or not password:
        assert "mysql" not in os.environ.get(live_engines.REQUIRE, "").split(","), "CI required MySQL but did not supply the launch fixture"
        print("MySQL settings document: skipped (no RUI_TEST_MYSQL_* server)")
        return
    rui, admin = map(lambda arg: str(pathlib.Path(arg).resolve()), sys.argv[1:3])
    root = host_process.canonical_fixture_root(tempfile.mkdtemp(prefix="rui-mysql-launch-"))
    database = "rui_launch_" + secrets.token_hex(6)
    # This URL exists only in the fixture's memory and the child's stdin.
    url = f"mysql://root:{quote(password, safe='')}@{quote(socket, safe='')}/{database}"
    runtime = root / "run"
    runtime.mkdir(mode=0o700)
    sock = runtime / "rui.sock"
    # Use the SQLite launch fixture's preset creation shape: the preset supplies
    # the required model, compaction trigger, tools, permission mode and effort.
    preset = {"model": "gpt-6.1-sol", "effort": "low", "compactAt": 100000,
              "tools": [], "permissionMode": "ask", "label": "Review"}
    good = {"store": {"mysql": {"url": {"value": url}}},
            "interface": {"dir": str(runtime), "lifetime": "stdin"},
            "execution": {"activeCapacity": 2}, "presets": {"review": preset},
            "providers": {"openai": {"endpoint": "https://api.openai.com/v1/responses", "key": {"value": "sk-mysql-launch-test"}}}}
    children = []
    limited_logins = [("rui_ro_" + secrets.token_hex(6), "SELECT"),
                      ("rui_no_update_" + secrets.token_hex(6), "SELECT, INSERT")]

    def sql(text):
        return subprocess.run([admin], input=text, text=True, capture_output=True, check=True).stdout.strip()

    def launch(value):
        # The CI fixture credentials are not inherited by the Host itself.
        env = {key: os.environ[key] for key in ("PATH", "HOME", "TMPDIR") if key in os.environ}
        child = subprocess.Popen([rui, "host", "serve", "--settings", "-"], stdin=subprocess.PIPE,
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
            frame_host.wait_for_host(sock, "", child)
        except AssertionError:
            if child.poll() is None:
                raise
            out, err = child.communicate(timeout=5)
            raise AssertionError(f"the Host exited {child.returncode} before it answered Host info: stdout={out!r} stderr={err!r}")
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
        host_process.close_stdin(child)
        assert child.wait(timeout=20) == 0, "stdin close did not cleanly stop the Host"
        assert not sock.exists(), "the stopped Host retained its socket"

    try:
        sql(f"CREATE DATABASE {database} CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_bin")
        wrong_password = secrets.token_hex(24)
        wrong_login = f"mysql://root:{wrong_password}@{quote(socket, safe='')}/{database}"
        login_refusal = frame_host.refusal(launch(dict(good, store={"mysql": {"url": {"value": wrong_login}}})))
        assert login_refusal["code"] == "mysql_login", login_refusal
        assert wrong_password not in login_refusal["message"] and password not in login_refusal["message"]
        missing_socket = str(root / "missing-mysql.sock")
        unreachable_url = f"mysql://root:{quote(password, safe='')}@{quote(missing_socket, safe='')}/{database}"
        unreachable = frame_host.refusal(launch(dict(good, store={"mysql": {"url": {"value": unreachable_url}}})))
        assert unreachable["code"] == "mysql_unreachable", unreachable
        assert missing_socket not in unreachable["message"] and password not in unreachable["message"]
        missing = launch(good)
        assert frame_host.refusal(missing)["code"] == "store_schema_missing"
        released()
        ddl = subprocess.run([rui, "store", "schema", "--engine", "mysql"], check=True, capture_output=True, text=True).stdout
        assert "CREATE TABLE store_meta" in ddl
        sql(f"USE {database};" + ddl)
        # Each refusal must precede metadata repair and ownership writes.
        # Leave other metadata absent so even a repair is observable.
        sql(f"INSERT INTO {database}.store_owner VALUES(1,7,9)")

        def admission_snapshot():
            return sql(f"SELECT meta_key,meta_value FROM {database}.store_meta ORDER BY meta_key;"
                       f"SELECT owner_key,epoch,commit_seq FROM {database}.store_owner;"
                       f"SELECT * FROM {database}.action_operation")

        cases = (
            ("format", "0", "the MySQL Store format is older than this build; apply its forward migrations"),
            ("format", "4294967295", "the MySQL Store format is newer than this build; use a compatible build"),
            ("format", "not-a-number", "the MySQL Store format metadata is not a valid number"),
            # Format 74 retired the Store's wire label: its row is an unknown key.
            ("wire_version", "retired-wire", "the MySQL Store metadata contains an unexpected key"),
            ("unexpected", "unexpected-value", "the MySQL Store metadata contains an unexpected key"),
            ("store_id", "not-an-id", "the MySQL Store identity metadata or connection target is invalid"),
            (None, None, "the MySQL Store catalog does not match this build"),
        )
        for key, value, message in cases:
            if key is None:
                sql(f"ALTER TABLE {database}.store_owner ADD COLUMN admission_probe BIGINT")
            else:
                if key == "unexpected":
                    sql(f"ALTER TABLE {database}.store_meta ALTER CHECK store_meta_chk_1 NOT ENFORCED")
                sql(f"INSERT INTO {database}.store_meta VALUES('{key}','{value}')")
            before = admission_snapshot()
            refusal = frame_host.refusal(launch(good))
            assert refusal == {"code": "store_schema_behind", "message": message}, refusal
            released()
            assert admission_snapshot() == before, f"admission wrote durable state for {key or 'catalog'}"
            if key is None:
                sql(f"ALTER TABLE {database}.store_owner DROP COLUMN admission_probe")
            else:
                sql(f"DELETE FROM {database}.store_meta")
                if key == "unexpected":
                    sql(f"ALTER TABLE {database}.store_meta ALTER CHECK store_meta_chk_1 ENFORCED")
        host = launch(good)
        store_id = ready(host)
        # Only private host-info discovery may omit the identity. Once known,
        # the exact opaque id works; database names and other ids never do.
        discovered = frame_host.host_info(sock, "")
        exact = frame_host.host_info(sock, store_id)
        assert exact["store"] == store_id and exact["instance"] == discovered["instance"], exact
        for wrong_id in (database, "0" * 32):
            wrong_info = frame_host.post(sock, "host-info", {"version": frame_host.WIRE, "kind": "host_info", "store": wrong_id}, expected_status=409)
            assert wrong_info["code"] == "wrong_store_identity", wrong_info
        assert "kind" not in exact and "engine" not in exact, exact
        assert store_id == sql(f"SELECT meta_value FROM {database}.store_meta WHERE meta_key='store_id'")
        other = root / "other"
        other.mkdir(mode=0o700)
        locked = launch(dict(good, interface=dict(good["interface"], dir=str(other))))
        assert frame_host.refusal(locked)["code"] == "store_locked"
        create = {"version": frame_host.WIRE, "kind": "configure", "store": store_id, "key": "mysql-launch-create",
                  "session": "", "preset": "review", "configuration": {"label": None}}
        configured = frame_host.post(sock, "configure", create)
        assert configured["answer"]["status"] == "accepted", configured
        session = configured["answer"]["session"]
        request = {"version": frame_host.WIRE, "kind": "inspect_session", "store": store_id, "session": session}
        wrong = frame_host.post(sock, "inspect-session", dict(request, store="0" * 32), expected_status=409)
        assert wrong["code"] == "wrong_store_identity", wrong
        empty = frame_host.post(sock, "inspect-session", dict(request, store=""), expected_status=409)
        assert empty["code"] == "wrong_store_identity", empty
        observed = frame_host.post(sock, "inspect-session", request)
        assert observed["session"]["reference"] == session, observed
        saved = observed["session"]
        assert saved["model"] == preset["model"] and saved["tools"] == [] and saved["label"] is None, saved
        assert saved["compaction_trigger_override"] == "100000", saved
        assert saved["reasoning_effort"] == "low" and saved["reasoning_effort_override"] == "low", saved
        # CLI/Bash peers route by the non-secret runtime hint, never the URL.
        env = dict(os.environ, RUI_RUNTIME_DIR=str(runtime))
        status = subprocess.run([rui, "host", "status", "--store", store_id], env=env, text=True, capture_output=True, check=True)
        status = json.loads(status.stdout)
        assert status["store"] == store_id and status["innodb_doublewrite"] == sql("SELECT @@global.innodb_doublewrite")
        assert status["diagnostics"] == str(runtime / "diagnostics")
        # A bad hint is refused, never retried as a relative SQLite directory.
        for hint in ("relative-runtime", ""):
            invalid = subprocess.run([rui, "host", "status", "--store", store_id],
                                     cwd=root, env=dict(env, RUI_RUNTIME_DIR=hint), text=True, capture_output=True, timeout=10)
            assert invalid.returncode != 0 and json.loads(invalid.stdout)["status"] == "access_failure", invalid
        missing_runtime = root / "missing-runtime"
        unavailable_env = dict(env, RUI_RUNTIME_DIR=str(missing_runtime))
        unavailable = subprocess.run([rui, "host", "start", "--store", store_id],
                                     cwd=root, env=unavailable_env, text=True, capture_output=True, timeout=10)
        assert unavailable.returncode != 0 and "[mysql_host_unavailable]" in unavailable.stderr, unavailable
        assert not missing_runtime.exists() and not (root / store_id).exists(), "MySQL routing created a SQLite Store or runtime"
        private(host)
        close(host)
        released()
        # Post-login access checks cover both ownership writes: SELECT-only
        # cannot INSERT, and SELECT+INSERT still cannot advance the epoch.
        for user, privileges in limited_logins:
            limited_password = secrets.token_hex(24)
            sql(f"CREATE USER '{user}'@'localhost' IDENTIFIED BY '{limited_password}';"
                f"GRANT {privileges} ON {database}.* TO '{user}'@'localhost'")
            limited_url = f"mysql://{user}:{limited_password}@{quote(socket, safe='')}/{database}"
            before = admission_snapshot()
            refused_host = launch(dict(good, store={"mysql": {"url": {"value": limited_url}}}))
            denied = frame_host.refusal(refused_host)
            assert denied["code"] == "mysql_login", denied
            assert "SELECT, INSERT, UPDATE" in denied["message"], denied
            out, err = frame_host.output(refused_host)
            assert limited_url.encode() not in out + err and limited_password.encode() not in out + err
            released()
            assert admission_snapshot() == before, f"limited login {privileges} changed durable state"
        for selector in (None, database):
            sql(f"DELETE FROM {database}.store_meta WHERE meta_key='store_selector'")
            if selector is not None:
                sql(f"INSERT INTO {database}.store_meta VALUES('store_selector','{selector}')")
            host = launch(good)
            assert ready(host) == store_id, "selector admission changed the durable Store id"
            close(host)
            released()
            assert sql(f"SELECT meta_value FROM {database}.store_meta WHERE meta_key='store_selector'") == database
        sql(f"UPDATE {database}.store_meta SET meta_value='legacy-other-database' WHERE meta_key='store_selector'")
        before = admission_snapshot()
        refusal = frame_host.refusal(launch(good))
        assert refusal == {"code": "store_schema_behind",
                           "message": "the MySQL Store identity metadata or connection target is invalid"}, refusal
        released()
        assert admission_snapshot() == before, "mismatched selector admission wrote durable state"
        assert not sock.exists(), "the refused Host retained its socket"
        # Restore the canonical selector before testing restart and fencing.
        sql(f"UPDATE {database}.store_meta SET meta_value='{database}' WHERE meta_key='store_selector'")
        host = launch(good)
        assert ready(host) == store_id, "the Store id changed across a Host restart"
        assert frame_host.post(sock, "inspect-session", request)["session"]["reference"] == session
        private(host)
        # A read that finds its connection killed fences the Store. A write
        # batch that finds it first (the Host's own, such as a saved model
        # list) reconnects and reruns instead, by design, and the read then
        # succeeds on the new connection: kill that one and read again.
        code = None
        for _ in range(5):
            connection = sql(f"SELECT ID FROM information_schema.PROCESSLIST WHERE DB='{database}'")
            assert connection.isdecimal(), "expected one Host connection"
            sql(f"KILL CONNECTION {connection}")
            # Drive a canonical read so the Store observes the killed connection.
            with contextlib.suppress(OSError, AssertionError):
                frame_host.post(sock, "inspect-session", request)
            try:
                code = host.wait(timeout=5)
                break
            except subprocess.TimeoutExpired:
                continue
        assert code == 1, f"a fenced MySQL Store exited {code}, not 1: {frame_host.output(host)!r}"
        out, err = frame_host.output(host)
        # stdout holds the readiness line, then exactly one named exit (D211).
        assert b"internal_unexpected" not in err, f"a fenced Host was reported as an internal fault: {err!r}"
        lines = out.decode().splitlines()
        assert len(lines) == 2 and lines[0].startswith("ready ") and json.loads(lines[1])["rui_start_error"]["code"] == "store_fenced", \
            f"missing named store_fenced exit: stdout={out!r} stderr={err[-4000:]!r}"
        print("MySQL settings document: readiness, Session round trip, stable id, selector repair and refusal, private credentials, mysql_login, mysql_unreachable, store_locked, stdin close, store_fenced")
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
        for user, _ in limited_logins:
            try:
                sql(f"DROP USER IF EXISTS '{user}'@'localhost'")
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
    # The Store's MySQL round-trip budget needs the same live server.
    store_rounds_cases.run(*(str(pathlib.Path(arg).resolve()) for arg in sys.argv[1:3]))
