#!/usr/bin/env python3
"""The one pinned MySQL 8.4 image Rui's tests run, and how they start it.

mysql_wire_integration.py imports this file. check.yml runs it as a script
for the unit binary's live dialect check:

  mysql_server.py start NAME SOCKET_DIR STATUS_FILE
      `docker run --detach` (the pull included), with root's password from
      RUI_TEST_MYSQL_ROOT_PASSWORD; writes the exit status to STATUS_FILE.
  mysql_server.py wait NAME STATUS_FILE
      fails when `start` failed, else blocks until the server is ready.

The server runs the image's own settings, durability included, apart from
how it keeps optimizer statistics (UNIT_SERVER_COMMAND). Its Unix
socket is SOCKET_DIR/mysqld.sock, a directory shared with the host.

It also holds the one pinned ProxySQL image, which `start_proxy` runs in
front of a server through that same directory (store_rounds_cases.py).
"""
import os
import subprocess
import sys

import host_process
import live_engines

# The unit binary's server lives one job. Its data sits in memory, so commits
# still flush with the durability settings Rui checks, but to no disk. Its
# optimizer statistics update as each test's tables fill: persistent ones
# recompute in the background at most every ten seconds, so a table that
# grows from empty in a second is planned as empty and an indexed lookup
# becomes a scan (one test took 386 s instead of 26).
UNIT_SERVER = ("--tmpfs", "/var/lib/mysql")
UNIT_SERVER_COMMAND = ("--innodb-stats-persistent=OFF",)
IMAGE = "mysql:8.4.13@sha256:a0225d1ea6631c8bc2385dc4c2faba17bbf1834ecf369e1659a9a382bd8d5dd7"
READY_SECONDS = 180
# The oldest ProxySQL release whose handshake offers what Rui's driver
# requires (CLIENT_PLUGIN_AUTH_LENENC_CLIENT_DATA; 3.0.5 does not).
PROXY_IMAGE = "proxysql/proxysql:3.0.11@sha256:a504b3624312497f493a37426329af8efa044373906b8f9733c111b510285844"
# ProxySQL as it ships, multiplexing on, with the two settings a Rui Store
# needs of it: the sign-in Rui's driver speaks, which is not ProxySQL's
# default, and the server version it announces. It reaches the server and
# serves clients over Unix sockets in the one shared directory.
PROXY_CONFIG = """datadir="/var/lib/proxysql"
mysql_variables=
{{
    interfaces="/var/run/mysqld/{socket}"
    server_version="8.4.13"
    multiplexing=true
    default_authentication_plugin="caching_sha2_password"
    monitor_enabled=false
}}
mysql_servers=
(
    {{ address="/var/run/mysqld/mysqld.sock", port=0, hostgroup=0 }}
)
mysql_users=
(
    {{ username="root", password="{password}", default_hostgroup=0, active=1 }}
)
"""


def docker(*args, **kwargs):
    return subprocess.run(["docker", *args], check=True, text=True, **kwargs)


def socket_path(socket_dir):
    return os.path.join(socket_dir, "mysqld.sock")


def start(name, socket_dir, root_password, *arguments, command=()):
    """Starts the image detached; `arguments` go to `docker run` before it,
    and `command` to mysqld after it."""
    # mysqld in the container runs as its own user and creates the socket here.
    os.chmod(socket_dir, 0o777)
    docker("run", "--detach", "--name", name, "--env", f"MYSQL_ROOT_PASSWORD={root_password}",
           "--volume", f"{socket_dir}:/var/run/mysqld", *arguments, IMAGE, *command, capture_output=True)


def proxy_socket_path(socket_dir, name):
    return os.path.join(socket_dir, f"{name}.sock")


def start_proxy(name, socket_dir, root_password, config_path):
    """Starts ProxySQL detached in front of the server whose socket is in
    `socket_dir`, writing its settings to `config_path`, and returns once
    it listens on `proxy_socket_path`, where it serves root's clients."""
    path = proxy_socket_path(socket_dir, name)
    with open(config_path, "w", encoding="utf-8") as config:
        config.write(PROXY_CONFIG.format(socket=os.path.basename(path), password=root_password))
    docker("run", "--detach", "--name", name, "--network", "none", "--volume", f"{socket_dir}:/var/run/mysqld",
           "--volume", f"{config_path}:/etc/proxysql.cnf:ro", PROXY_IMAGE, capture_output=True)

    def observe():
        running = docker("inspect", "--format", "{{.State.Running}}", name, capture_output=True).stdout.strip()
        if running != "true":
            raise SystemExit("ProxySQL exited before it was ready:\n" + docker("logs", name, capture_output=True).stderr)
        return os.path.exists(path)

    host_process.wait_for(observe, f"ProxySQL listening on {path}", timeout=READY_SECONDS, interval=0.2)


def wait_ready(name):
    # The entrypoint first runs a setup server on port 0, then the real one.
    def observe():
        running = docker("inspect", "--format", "{{.State.Running}}", name, capture_output=True).stdout.strip()
        if running != "true":
            raise SystemExit("MySQL exited before it was ready:\n" + docker("logs", name, capture_output=True).stderr)
        return docker("logs", name, capture_output=True).stderr

    host_process.wait_for(observe, "MySQL ready on port 3306", timeout=READY_SECONDS, interval=1,
                          ready=lambda logs: any("mysqld: ready for connections" in line and "port: 3306 " in line
                                                 for line in logs.splitlines()))


def main(argv, root_password):
    if argv[:1] == ["start"] and len(argv) == 4:
        name, socket_dir, status_file = argv[1:]
        try:
            start(name, socket_dir, root_password, *UNIT_SERVER, command=UNIT_SERVER_COMMAND)
            status = "0"
        except subprocess.CalledProcessError as error:
            print(error.stderr, file=sys.stderr)
            status = str(error.returncode)
        with open(status_file, "w") as file:
            file.write(status)
        return int(status)
    if argv[:1] == ["wait"] and len(argv) == 3:
        name, status_file = argv[1:]
        status = host_process.wait_for(lambda: open(status_file).read() if os.path.exists(status_file) else "",
                                       f"{status_file} from mysql_server.py start", timeout=READY_SECONDS,
                                       interval=1)
        if status != "0":
            raise SystemExit(f"mysql_server.py start exited {status}")
        wait_ready(name)
        return 0
    raise SystemExit(__doc__)


if __name__ == "__main__":
    password = os.environ.get(live_engines.MYSQL_ROOT_PASSWORD, "")
    host_process.enter()
    sys.exit(main(sys.argv[1:], password))
