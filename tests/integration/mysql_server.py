#!/usr/bin/env python3
"""The one pinned MySQL 8.4 image Rui's tests run, and how they start it.

mysql_wire_integration.py imports this file. check.yml runs it as a script
for the unit binary's live dialect check:

  mysql_server.py start NAME SOCKET_DIR STATUS_FILE
      `docker run --detach` (the pull included), with root's password from
      RUI_TEST_MYSQL_ROOT_PASSWORD; writes the exit status to STATUS_FILE.
  mysql_server.py wait NAME STATUS_FILE
      fails when `start` failed, else blocks until the server is ready.

The server runs the image's own settings, durability included. Its Unix
socket is SOCKET_DIR/mysqld.sock, a directory shared with the host.
"""
import os
import subprocess
import sys

import host_process
import live_engines

IMAGE = "mysql:8.4.13@sha256:a0225d1ea6631c8bc2385dc4c2faba17bbf1834ecf369e1659a9a382bd8d5dd7"
READY_SECONDS = 180


def docker(*args, **kwargs):
    return subprocess.run(["docker", *args], check=True, text=True, **kwargs)


def socket_path(socket_dir):
    return os.path.join(socket_dir, "mysqld.sock")


def start(name, socket_dir, root_password, *arguments):
    """Starts the image detached; `arguments` go to `docker run` before it."""
    # mysqld in the container runs as its own user and creates the socket here.
    os.chmod(socket_dir, 0o777)
    docker("run", "--detach", "--name", name, "--env", f"MYSQL_ROOT_PASSWORD={root_password}",
           "--volume", f"{socket_dir}:/var/run/mysqld", *arguments, IMAGE, capture_output=True)


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
            start(name, socket_dir, root_password)
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
