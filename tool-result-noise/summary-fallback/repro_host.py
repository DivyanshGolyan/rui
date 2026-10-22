"""Scratch: real Host whose fixture model runs the reviewer's repro command.
argv: RUI_BINARY ROOT. Writes ROOT/ready; stops when ROOT/stop exists and writes
ROOT/outputs.json with every function_call_output the provider received."""
import json, pathlib, sys, threading, time

binary, root = sys.argv[1], pathlib.Path(sys.argv[2])
sys.argv = [sys.argv[0], binary]
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "tests/integration"))
import model_fixture as fixture  # noqa: E402
import bash_integration as bash_fixture  # noqa: E402

workspace = root / "workspace"
workspace.mkdir(exist_ok=True)
store = root / "store"
responses = []
bash_fixture.add_exchange(responses, "repro", "printf 'useful diagnostic B'; printf '\\n' >&2; exit 7",
                          answer="The check failed.")
endpoint = fixture.SuccessEndpoint(responses)
threading.Thread(target=endpoint.serve_forever, daemon=True).start()
host = fixture.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses")
try:
    bash_fixture.configure(root, store, "repro-config", "demo/repro", permission="bypass", workspace=workspace)
    (root / "ready").write_text("ready")
    while not (root / "stop").exists() and host.poll() is None:
        time.sleep(0.2)
    (root / "outputs.json").write_text(json.dumps(
        [[i["output"] for i in json.loads(r)["input"] if i.get("type") == "function_call_output"] for r in endpoint.requests]))
finally:
    fixture.stop_host(host)
    endpoint.shutdown()
