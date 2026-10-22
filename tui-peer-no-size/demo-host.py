#!/usr/bin/env python3
"""Scratch: a real Host with a stub model and peer Messages both ways, for a
tmux capture of the real TUI. Usage: demo.py RUI STATE_DIR. Runs until killed."""
import json
import os
import pathlib
import subprocess
import sys
import threading
import time

sys.path.insert(0, "/home/user/workspace/repo/tests/integration")
import model_fixture as fixture  # noqa: E402  (reads argv[1] as RUI)
from host_process import TestHTTPServer, start_ready_process  # noqa: E402

RUI = pathlib.Path(sys.argv[1]).resolve()
state = pathlib.Path(sys.argv[2])
home, workspace, store = state / "home", state / "workspace", state / "store"
for path in (home, workspace):
    path.mkdir(parents=True, exist_ok=True)


class Handler(fixture.http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        self.rfile.read(int(self.headers["Content-Length"]))
        self.server.count += 1
        payload = fixture.sse_answer(f"r{self.server.count}", "reason", "message", "Noted.")[0]
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("X-Request-Id", f"demo-{self.server.count}")
        self.send_header("OpenAI-Model", "model-a-served")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)
        self.close_connection = True

    def log_message(self, *_):
        pass


server = TestHTTPServer(("127.0.0.1", 0), Handler)
server.count = 0
threading.Thread(target=server.serve_forever, daemon=True).start()
url = f"http://127.0.0.1:{server.server_address[1]}/responses"
env = {"PATH": os.environ["PATH"], "HOME": str(home)}
host, _ = start_ready_process([RUI, "host", "serve", "--store", store, "--provider-endpoint", url], env=env,
                              required_fields={"execution": "enabled"})


def rui(*args, sender=None):
    extra = {"RUI_ADDRESS": json.dumps({"store": os.path.realpath(store), "session": sender})} if sender else {}
    done = subprocess.run([str(RUI), *map(str, args)], env={**env, **extra}, capture_output=True, text=True, timeout=30)
    assert done.returncode == 0, (args, done)


for session in ("demo/main", "reviewer"):
    rui("session", "configure", "--store", store, "--session", session, "--workspace", workspace,
        "--provider", "codex", "--model", "model-a", "--tools", "bash", "--permission-mode", "bypass")


def send(target, text, sender=None):
    rui("session", "send", "--store", store, "--session", target, "--", text, sender=sender)
    time.sleep(1.5)


send("demo/main", "Short question for the agent.")
send("demo/main", "\n".join(f"Folded line {i}" for i in range(1, 7)))
send("demo/main", "Looks good to me.", sender="reviewer")
send("demo/main", "Please review the patch\nIt drops sizes from peer lines.\nThird line.", sender="reviewer")
send("demo/main", "Long single line " + "word " * 60 + "END", sender="reviewer")
send("reviewer", "done", sender="demo/main")
send("reviewer", "Plan follows\n1. remove sizes\n2. keep time", sender="demo/main")
print("READY", store, flush=True)
try:
    host.wait()
finally:
    server.shutdown()
