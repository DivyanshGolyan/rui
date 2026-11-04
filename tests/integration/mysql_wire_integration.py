#!/usr/bin/env python3
"""Run the MySQL wire client's live tests against a real MySQL 8.4 server.

The server runs in Docker from mysql_server.py's pinned image, with its Unix
socket in a directory shared with the host. A missing Docker fails the run;
it never skips.
"""
import os
import secrets
import shutil
import subprocess
import sys
import tempfile

import host_process
import mysql_server
from mysql_server import docker


def main():
    test = os.path.abspath(sys.argv[1])
    password, root_password = secrets.token_hex(16), secrets.token_hex(16)
    name = f"rui-mysql-wire-{os.getpid()}"
    socket_dir = tempfile.mkdtemp(prefix="rui-mysql-")
    try:
        mysql_server.start(name, socket_dir, root_password,
                           "--env", "MYSQL_DATABASE=rui", "--env", "MYSQL_USER=rui",
                           "--env", f"MYSQL_PASSWORD={password}", "--publish", "127.0.0.1::3306")
        mysql_server.wait_ready(name)
        port = docker("port", name, "3306/tcp", capture_output=True).stdout.split()[0].rsplit(":", 1)[1]
        env = dict(os.environ, RUI_MYSQL_SOCKET=mysql_server.socket_path(socket_dir), RUI_MYSQL_PORT=port,
                   RUI_MYSQL_PASSWORD=password, RUI_MYSQL_ROOT_PASSWORD=root_password)
        result = subprocess.run([test], env=env)
        if result.returncode != 0:
            print(docker("logs", name, capture_output=True).stderr[-4000:], file=sys.stderr)
        return result.returncode
    finally:
        # Unchecked: the tests' own result stays the outcome, and a container
        # that failed to start leaves nothing to remove.
        subprocess.run(["docker", "rm", "--force", "--volumes", name], capture_output=True)
        shutil.rmtree(socket_dir, ignore_errors=True)


if __name__ == "__main__":
    host_process.enter()
    sys.exit(main())
