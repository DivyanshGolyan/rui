#!/usr/bin/env python3
"""Run the MySQL wire client's live tests against a real MySQL 8.4 server.

The server runs in Docker from a pinned image, with its Unix socket in a
directory shared with the host. A missing Docker fails the run; it never skips.
"""
import os
import secrets
import shutil
import subprocess
import sys
import tempfile

import host_process

IMAGE = "mysql:8.4.13@sha256:a0225d1ea6631c8bc2385dc4c2faba17bbf1834ecf369e1659a9a382bd8d5dd7"
READY_SECONDS = 180


def docker(*args, **kwargs):
    return subprocess.run(["docker", *args], check=True, text=True, **kwargs)


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


def main():
    test = os.path.abspath(sys.argv[1])
    password, root_password = secrets.token_hex(16), secrets.token_hex(16)
    name = f"rui-mysql-wire-{os.getpid()}"
    socket_dir = tempfile.mkdtemp(prefix="rui-mysql-")
    # mysqld in the container runs as its own user and creates the socket here.
    os.chmod(socket_dir, 0o777)
    try:
        docker("run", "--detach", "--name", name,
               "--env", f"MYSQL_ROOT_PASSWORD={root_password}", "--env", "MYSQL_DATABASE=rui",
               "--env", "MYSQL_USER=rui", "--env", f"MYSQL_PASSWORD={password}",
               "--volume", f"{socket_dir}:/var/run/mysqld", "--publish", "127.0.0.1::3306",
               IMAGE, capture_output=True)
        wait_ready(name)
        port = docker("port", name, "3306/tcp", capture_output=True).stdout.split()[0].rsplit(":", 1)[1]
        env = dict(os.environ, RUI_MYSQL_SOCKET=os.path.join(socket_dir, "mysqld.sock"), RUI_MYSQL_PORT=port,
                   RUI_MYSQL_PASSWORD=password, RUI_MYSQL_ROOT_PASSWORD=root_password)
        result = subprocess.run([test], env=env)
        if result.returncode != 0:
            print(docker("logs", name, capture_output=True).stderr[-4000:], file=sys.stderr)
        return result.returncode
    finally:
        subprocess.run(["docker", "rm", "--force", "--volumes", name], capture_output=True)
        shutil.rmtree(socket_dir, ignore_errors=True)


if __name__ == "__main__":
    host_process.enter()
    sys.exit(main())
