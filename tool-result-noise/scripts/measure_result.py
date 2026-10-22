"""Scratch: one typical successful Bash call through a real Host; prints the saved
and model-visible Tool Result and its byte count. argv: RUI_BINARY OUTPUT_JSON."""
import json, pathlib, sys, tempfile, threading

binary, output = sys.argv[1], sys.argv[2]
sys.argv = [sys.argv[0], binary]
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "tests/integration"))
import model_fixture as fixture  # noqa: E402
import bash_integration as bash_fixture  # noqa: E402

root = pathlib.Path(tempfile.mkdtemp(prefix="rui-measure."))
workspace = root / "workspace"
workspace.mkdir()
for name in ("README.md", "main.zig", "build.zig"):
    (workspace / name).write_text("x\n")
store = root / "store"
responses = []
bash_fixture.add_exchange(responses, "measure", "ls")
endpoint = fixture.SuccessEndpoint(responses)
thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
thread.start()
host = fixture.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses")
try:
    session = "direct/measure"
    bash_fixture.configure(root, store, "measure-config", session, workspace=workspace)
    fixture.message(root, store, "measure-message", session, "execute")
    action = fixture.wait_for(lambda: bash_fixture.action_for(store, session), "Action")
    bash_fixture.allow(root, store, "measure-allow", session, action["action"])
    fixture.wait_for(lambda: fixture.completed_observation(store, "measure-message"), "continuation")
    result = bash_fixture.result_text(store, session)
    request = json.loads(endpoint.requests[-1])
    model = [i["output"] for i in request["input"] if i.get("type") == "function_call_output"][0]
    assert model == result
    record = {"command": "ls", "result": result, "bytes": len(result.encode()), "platform": sys.platform}
    pathlib.Path(output).write_text(json.dumps(record, indent=1))
    print(json.dumps(record, indent=1))
finally:
    fixture.stop_host(host)
    endpoint.shutdown()
