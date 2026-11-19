"""Run the same public tool-profile journeys against SQLite and supplied MySQL."""
from contextlib import contextmanager, nullcontext
from functools import partial
import json
import os
import pathlib
import secrets
import subprocess
from urllib.parse import quote

import live_engines
import model_fixture as fixture
import overview_fixture
from host_process import dispose_all, READY_TRANSPORT, short_interface_directory, start_ready_process, wait_for


def mysql_inputs(environ):
    socket = environ.get(live_engines.MYSQL_SOCKET)
    password = environ.get(live_engines.MYSQL_ROOT_PASSWORD)
    required = "mysql" in environ.get(live_engines.REQUIRE, "").split(",")
    if not socket and not password:
        assert not required, "tool profiles: required MySQL socket and password are missing"
        print("tool profiles (mysql): skipped (no RUI_TEST_MYSQL_* server)", flush=True)
        return None
    assert socket and password, "tool profiles: supply both MySQL socket and root password"
    admin = environ.get("RUI_TEST_MYSQL_ADMIN")
    assert admin, "tool profiles: supplied MySQL server requires RUI_TEST_MYSQL_ADMIN"
    return socket, password, str(pathlib.Path(admin).resolve())


@contextmanager
def profile_worlds():
    inputs = mysql_inputs(os.environ)
    worlds = [("sqlite", overview_fixture.world)]
    lease = live_engines.mysql_lease(os.environ) if inputs is not None else nullcontext()
    with lease:
        if inputs is not None:
            worlds.append(("mysql", partial(mysql_world, inputs)))
        yield worlds


class MysqlStore:
    def __init__(self, inputs, runtime):
        self.socket, self.password, self.admin = inputs
        self.runtime = runtime
        self.database = "rui_tool_profile_" + secrets.token_hex(6)

    def sql(self, text):
        env = dict(os.environ, **{live_engines.MYSQL_SOCKET: self.socket,
                                 live_engines.MYSQL_ROOT_PASSWORD: self.password})
        return subprocess.run([self.admin], input=text, env=env, text=True, capture_output=True,
                              check=True, timeout=30).stdout.strip()

    def start_host(self, store, endpoint, *, active_capacity):
        for setting, value in (("store.mysql.url", "env:RUI_TOOL_PROFILE_MYSQL_URL"),
                               ("interface.dir", str(self.runtime))):
            subprocess.run([str(fixture.RUI), "host", "set", "--store", str(store), setting, value],
                           text=True, capture_output=True, check=True, timeout=20)
        url = (f"mysql://root:{quote(self.password, safe='')}@"
               f"{quote(self.socket, safe='')}/{self.database}")
        env = dict(os.environ, RUI_TOOL_PROFILE_MYSQL_URL=url)
        args = fixture.host_arguments(store, endpoint, active_capacity=active_capacity)
        host, _ = start_ready_process(args, env=env,
                                     required_fields=READY_TRANSPORT)
        return host

    def drop(self):
        wait_for(lambda: self.sql(f"SELECT IS_FREE_LOCK('{self.database}')") == "1",
                 "the tool-profile Host to release its MySQL Store", timeout=20)
        self.sql(f"DROP DATABASE IF EXISTS {self.database}")


@contextmanager
def mysql_world(inputs, prefix, responses_by_input=None, *, active_capacity=1):
    with short_interface_directory() as runtime:
        store = MysqlStore(inputs, runtime)
        created = False
        try:
            store.sql(f"CREATE DATABASE {store.database} CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_bin")
            created = True
            ddl = subprocess.run([str(fixture.RUI), "store", "schema", "--engine", "mysql"],
                                 text=True, capture_output=True, check=True, timeout=20).stdout
            store.sql(f"USE {store.database};" + ddl)
            with overview_fixture.world(prefix, responses_by_input, active_capacity=active_capacity,
                                        host_factory=store.start_host) as world:
                status = json.loads(world.run("host", "status", "--store", world.store))
                identity = store.sql(f"SELECT meta_value FROM {store.database}.store_meta WHERE meta_key='store_id'")
                assert status["status"] == "ready" and status["store"] == identity, status
                assert not (world.store / "rui.sqlite3").exists(), "MySQL profile fixture created a SQLite Store"
                yield world
        finally:
            if created:
                dispose_all(store.drop)
