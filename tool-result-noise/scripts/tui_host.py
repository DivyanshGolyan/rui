"""Scratch: hold a real Host with a fixture provider for a tmux TUI capture.
argv: RUI_BINARY ROOT. Writes ROOT/ready with store and session; stops when ROOT/stop exists."""
import json, pathlib, sys, threading, time

binary, root = sys.argv[1], pathlib.Path(sys.argv[2])
sys.argv = [sys.argv[0], binary]
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "tests/integration"))
import model_fixture as fixture  # noqa: E402
import bash_integration as bash_fixture  # noqa: E402

root.mkdir(parents=True, exist_ok=True)
workspace = root / "workspace"
workspace.mkdir(exist_ok=True)
for name in ("README.md", "main.zig", "build.zig"):
    (workspace / name).write_text("x\n")
store = root / "store"
responses = []
bash_fixture.add_exchange(responses, "listing", "ls", answer="Listed the workspace.")
bash_fixture.add_exchange(responses, "missing file", "ls missing-file", answer="That file is absent.")
endpoint = fixture.SuccessEndpoint(responses)
threading.Thread(target=endpoint.serve_forever, daemon=True).start()
host = fixture.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses")
try:
    session = "demo/tui"
    bash_fixture.configure(root, store, "tui-config", session, permission="bypass", workspace=workspace)
    (root / "ready").write_text(json.dumps({"store": str(store), "session": session}))
    while not (root / "stop").exists() and host.poll() is None:
        time.sleep(0.2)
    (root / "outputs.json").write_text(json.dumps(
        [[i["output"] for i in json.loads(r)["input"] if i.get("type") == "function_call_output"] for r in endpoint.requests]))
finally:
    fixture.stop_host(host)
    endpoint.shutdown()
