#!/usr/bin/env python3

import json
import pathlib
import os
import selectors
import shutil
import socket
import subprocess
import sys
import tempfile
import time

import host_process
import os_semantics
from preset_creation_cases import preset_creation
from empty_creation_cases import empty_creation
from settings_fixture import WIRE, frame, host_info, mcp_server, output, post, refusal, wait_for_host


RUI = pathlib.Path(sys.argv[1]).resolve()
def launch(raw):
    process = subprocess.Popen([RUI, "host", "serve", "--settings", "-"], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    process.stdin.write(raw)
    process.stdin.flush()
    return process


def host_stop(path, store, instance):
    return post(path, "control/host-stop", {"version": WIRE, "kind": "host_stop", "store": store},
                b"X-Rui-Host-Instance: " + instance.encode() + b"\r\n")


def mcp_entry(name, server):
    return name, {"url": f"http://127.0.0.1:{server.server_port}/mcp", "bearerToken": {"value": "t"}, "callTimeoutMs": 1000}


def sdk_tool_set(root, good, network, ci):
    if not shutil.which("node") or not shutil.which("npm"):
        assert not ci, "CI requires Node and npm for the real MCP SDK fixture"
        print("SKIP real MCP SDK: node/npm not installed locally")
        return
    fixture = pathlib.Path(__file__).with_name("mcp_sdk")
    subprocess.run(["npm", "ci", "--ignore-scripts", "--no-audit", "--no-fund"],
                   cwd=fixture, env=dict(os.environ, **network), check=True, timeout=120)
    with tempfile.TemporaryFile() as errors:
        server = subprocess.Popen(["node", str(fixture / "server.mjs"), "sdk-test-token"],
                                  stdout=subprocess.PIPE, stderr=errors)
        host = None
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(server.stdout, selectors.EVENT_READ)
                host_process.wait_for(lambda: bool(selector.select(timeout=0)),
                                      "the real MCP SDK server port", timeout=20)
            port = server.stdout.readline().decode().strip()
            assert port.isdecimal(), port
            entry = ("drift-sdk", {"url": f"http://127.0.0.1:{port}/mcp",
                     "bearerToken": {"value": "sdk-test-token"}, "callTimeoutMs": 1000})
            runtime = root / "sdk"
            runtime.mkdir(mode=0o700)
            base = dict(good, interface=dict(good["interface"], dir=str(runtime)), store={"sqlite": {"dir": str(root / "sdk-store")}})
            host = launch(frame(dict(base, tools={"mcp": dict([entry])})))
            wait_for_host(runtime / "rui.sock", base["store"]["sqlite"]["dir"], host)
            host_process.close_stdin(host)
            assert host.wait(timeout=30) == 0, output(host)
            for name in ("echo", "fail", "slow", "progress"):
                collision = mcp_server([name])
                try:
                    host = launch(frame(dict(base, tools={"mcp": dict([entry, mcp_entry("collision", collision)])})))
                    with selectors.DefaultSelector() as selector:
                        selector.register(host.stdout, selectors.EVENT_READ)
                        host_process.wait_for(lambda: bool(selector.select(timeout=0)),
                                              "the SDK tool-set collision refusal", timeout=30)
                    line = host.stdout.readline()
                    assert line.startswith(b"{"), (name, "expected a drift-sdk tool-set collision refusal", line)
                    refused = json.loads(line)["rui_start_error"]
                    assert host.wait(timeout=20) != 0
                    assert refused["code"] == "tool_name_collision", refused
                    assert all(value in refused["message"] for value in
                               (name, "drift-sdk", "collision")), refused
                finally:
                    if host.poll() is None:
                        host.kill()
                        host.wait(timeout=10)
                    collision.shutdown()
                    collision.server_close()
            print("real MCP SDK: Host tool set contains drift-sdk echo, fail, slow, progress")
        finally:
            if host is not None and host.poll() is None:
                host.kill()
                host.wait(timeout=10)
            server.terminate()
            try:
                server.wait(timeout=10)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait(timeout=10)
            errors.seek(0)
            diagnostic = errors.read().decode()
            if diagnostic:
                print(diagnostic, file=sys.stderr)


def source_modes(root, good):
    store = good["store"]["sqlite"]["dir"]
    settings_file = root / "settings.json"

    def file_host(document, *flags):
        settings_file.write_text(json.dumps(document))
        settings_file.chmod(0o600)
        return subprocess.Popen([RUI, "host", "serve", "--settings", str(settings_file), *flags],
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    private = dict(good, providers={})
    for process in (file_host(private),
                    subprocess.Popen([RUI, "host", "serve", "--store", store],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)):
        assert refusal(process, expected_exit=6)["code"] == "store_locked"

    secret = "sk-file-origin-must-not-appear"
    invalid = dict(private, providers={"openai": {"key": {"value": secret}}})
    refused = refusal(file_host(invalid), forbidden=(secret,), expected_exit=2)
    assert refused["code"] == "settings_invalid", refused
    assert "providers.openai.key" in refused["message"], refused

    for source in ("pipe", "file"):
        runtime = root / (source + "-lifetime")
        runtime.mkdir(mode=0o700)
        target = str(root / (source + "-store"))
        document = {"store": {"sqlite": {"dir": target}}, "providers": {},
                    "interface": {"dir": str(runtime)}, "execution": {"activeCapacity": 1}}
        if source == "file":
            document["interface"]["lifetime"] = "stdin"
            process = file_host(document, "--set", 'execution.activeCapacity=3')
        else:
            process = launch(frame(document))
            host_process.close_stdin(process)
        path = runtime / "rui.sock"
        wait_for_host(path, target, process)
        info = host_info(path, target)
        assert info["active_capacity"] == ("3" if source == "file" else "1"), info
        if source == "file":
            host_process.close_stdin(process)
        else:
            host_stop(path, target, info["instance"])
        expected_exit = 0 if source == "file" else 1
        assert process.wait(timeout=30) == expected_exit, output(process)
        assert not path.exists()


NO_KEY = "\nrui: no OpenAI API key; save one with `rui auth login openai`, then start the Host again.\n"
PROXY = "\nrui: https_proxy/HTTPS_PROXY names a scheme other than http://; Rui tunnels only through an http:// proxy. The Host did not start.\n"


def flag_start_failures(root):
    home = root / "flag-home"
    home.mkdir(mode=0o700)
    key = root / "flag-key"
    key.write_text("sk-flag-start\n")
    key.chmod(0o644)
    bad_key = root / "flag-bad-key"
    bad_key.write_text("not a key \x01\n")
    bad_key.chmod(0o600)
    endpoint = "http://127.0.0.1:9/responses"
    credential = {"RUI_CODEX_CREDENTIAL_FILE": str(root / "c.json"), "RUI_CHATGPT_CREDENTIAL_FILE": str(root / "c.json")}
    absent = {"RUI_OPENAI_KEY_FILE": str(root / "absent")}
    openai = ["--set", 'providers={"openai":{}}']
    unchanged = [
        (["--test-openai-fixture-endpoint", endpoint], {}, 1, "internal_unexpected", ""),
        (["--test-openai-fixture-endpoint", endpoint], absent, 6, "sign_in_required", NO_KEY),
        (["--test-openai-fixture-endpoint", endpoint], {"RUI_OPENAI_KEY_FILE": str(key)}, 1, "internal_unexpected", ""),
        (["--test-openai-fixture-endpoint", endpoint], {"RUI_OPENAI_KEY_FILE": str(bad_key)}, 1, "internal_unexpected", ""),
        (["--test-openai-fixture-endpoint", endpoint, *openai], absent, 6, "sign_in_required", NO_KEY),
        (openai, {}, 6, "sign_in_required", NO_KEY),
        (openai, {"HOME": None}, 6, "home_unavailable", ""),
        (["--set", 'providers={"codex":{}}'], {"HOME": None}, 6, "home_unavailable", ""),
        (["--set", 'providers={"chatgpt":{}}'], {"HOME": None}, 6, "home_unavailable", ""),
        (["--test-codex-fixture-endpoint", endpoint], {}, 1, "internal_unexpected", ""),
        (["--test-chatgpt-fixture-endpoint", endpoint], {}, 1, "internal_unexpected", ""),
        (["--test-chatgpt-fixture-endpoint", "http://127.0.0.1:9/other"], credential, 2, "invocation_invalid", ""),
        (["--set", f"providers.openai.endpoint={endpoint}", "--set", "providers.openai.unauthenticated=true"],
         {"HTTPS_PROXY": "https://proxy.example:1"}, 6, None, PROXY),
    ]
    retired = [
        ["--active-capacity", "2"],
        ["--provider", "codex"],
        ["--provider", "bogus"],
        ["--provider", "codex", "--provider", "codex"],
        ["--provider-endpoint", endpoint],
        ["--provider-ca-file", "/ca.pem"],
        ["--bash-path", "/bin/bash"],
        ["--bash-timeout-ms", "0"],
    ]
    for flags in retired:
        unchanged.append((flags, {}, 2, "host_option_retired", ""))
    leaf = [
        (["--set", "providers.codex.endpoint=ftp://127.0.0.1/responses"], {}, "providers.codex.endpoint: must be a valid HTTPS or loopback HTTP endpoint"),
        (["--test-codex-fixture-endpoint", "ftp://x/responses"], credential, "providers.codex.endpoint: must be a valid HTTPS or loopback HTTP endpoint"),
        (["--set", "tools.bash.path="], {}, "tools.bash.path: must be an absolute path"),
        (["--set", 'providers={"bogus":{}}'], {}, "providers.bogus: unknown provider"),
        (["--set", "tools.bash.timeoutMs=0"], {}, "tools.bash.timeoutMs: integer is outside its bounds"),
    ]

    def start(index, flags, changes):
        environment = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(home), "TMPDIR": os.environ.get("TMPDIR", "/tmp")}
        for name, value in changes.items():
            if value is None:
                environment.pop(name, None)
            else:
                environment[name] = value
        return subprocess.run([RUI, "host", "serve", "--store", str(root / f"flag-store-{index}"), *flags], env=environment,
                              stdin=subprocess.DEVNULL, capture_output=True, timeout=30)

    for index, (flags, changes, status, code, diagnostic) in enumerate(unchanged):
        done = start(index, flags, changes)
        stderr = done.stderr.decode(errors="replace")
        assert done.returncode == status and done.stdout == b"", (flags, changes, done)
        assert stderr.startswith(diagnostic), (flags, changes, stderr)
        caller = stderr[len(diagnostic):]
        if code is None:
            assert caller == "", (flags, stderr)
        else:
            assert caller.startswith("rui host serve: ") and caller.endswith(f" [{code}]\n") and caller.count("\n") == 1, (flags, stderr)
    for index, (flags, changes, message) in enumerate(leaf, len(unchanged)):
        done = start(index, flags, changes)
        assert done.returncode == 2, (flags, done)
        assert done.stderr.decode() == f"rui: the Host did not start: {message} [settings_invalid]\n", (flags, done)
        assert json.loads(done.stdout) == {"rui_start_error": {"code": "settings_invalid", "message": message}}, (flags, done)


def main(network, ci):
    root = host_process.canonical_fixture_root(tempfile.mkdtemp(prefix="rui-launch-"))
    store = root / "store"
    runtime = root / "run"
    runtime.mkdir(mode=0o700)
    good = {"store": {"sqlite": {"dir": str(store)}},
            "interface": {"dir": str(runtime), "lifetime": "stdin"},
            "execution": {"activeCapacity": 2},
            "providers": {"openai": {"endpoint": "https://api.openai.com/v1/responses", "key": {"value": "sk-launch-test"}}}}

    host = launch(frame(good))
    sock = runtime / "rui.sock"
    wait_for_host(sock, store, host)
    info = host_info(sock, str(store))
    assert info["active_capacity"] == "2", info
    assert info["capabilities"]["providers"]["openai"] == "key_file", info
    if os_semantics.PROC_FS:
        for name in ("cmdline", "environ"):
            assert b"sk-launch-test" not in pathlib.Path(f"/proc/{host.pid}/{name}").read_bytes(), name

    source_modes(root, good)
    flag_start_failures(root)

    other = root / "other"
    other.mkdir(mode=0o700)
    second = launch(frame(dict(good, interface=dict(good["interface"], dir=str(other)))))
    assert refusal(second, expected_exit=6)["code"] == "store_locked"

    shared = launch(frame(dict(good, store={"sqlite": {"dir": str(root / "store2")}})))
    refused = refusal(shared)
    assert refused["code"] == "runtime_dir_unusable", refused
    assert info == host_info(sock, str(store))

    open_dir = root / "open"
    open_dir.mkdir()
    open_dir.chmod(0o777)
    insecure = launch(frame(dict(good, store={"sqlite": {"dir": str(root / "store3")}}, interface=dict(good["interface"], dir=str(open_dir)))))
    refused = refusal(insecure)
    assert refused["code"] == "runtime_dir_unusable", refused
    assert not (open_dir / "rui.sock").exists()

    not_a_dir = root / "file"
    not_a_dir.write_text("x")
    refused = refusal(launch(frame(dict(good, store={"sqlite": {"dir": str(root / "store4")}}, interface=dict(good["interface"], dir=str(not_a_dir))))))
    assert refused["code"] == "runtime_dir_unusable", refused

    started = time.monotonic()
    host_process.close_stdin(host)
    assert host.wait(timeout=30) == 0, output(host)
    elapsed = time.monotonic() - started
    assert elapsed < 10, elapsed
    assert not sock.exists()

    host = launch(frame(good))
    wait_for_host(sock, store, host)
    host_stop(sock, str(store), host_info(sock, str(store))["instance"])
    assert host.wait(timeout=30) == 0, output(host)
    assert not sock.exists()

    host = launch(frame(dict(good, execution=dict(good["execution"], paused=True))))
    wait_for_host(sock, store, host)
    info = host_info(sock, str(store))
    assert info["paused"] is True, info
    lifted = post(sock, "control/host-pause", {"version": WIRE, "kind": "host_pause", "store": str(store), "paused": False},
                  b"X-Rui-Host-Instance: " + info["instance"].encode() + b"\r\n")
    assert lifted["paused"] is False, lifted
    assert host_info(sock, str(store))["paused"] is False
    host_process.close_stdin(host)
    assert host.wait(timeout=30) == 0, output(host)

    preset = {"model": "gpt-6.1-sol", "effort": "low", "compactAt": 100000,
              "tools": [], "permissionMode": "ask", "label": "Review"}
    host = launch(frame(dict(good, presets={"review": preset})))
    wait_for_host(sock, store, host)
    create = {"version": WIRE, "kind": "configure", "store": str(store), "key": "preset:create",
              "session": "", "preset": "review", "configuration": {"label": None}}
    created = post(sock, "configure", create)
    assert created["answer"]["status"] == "accepted", created
    session = created["answer"]["session"]
    replayed = post(sock, "configure", create)
    assert replayed["answer"]["replayed"] is True and replayed["answer"]["session"] == session, replayed
    saved = post(sock, "inspect-session", {"version": WIRE, "kind": "inspect_session", "store": str(store), "session": session})["session"]
    assert saved["model"] == preset["model"] and saved["tools"] == [] and saved["label"] is None, saved
    assert saved["compaction_trigger_override"] == "100000", saved
    assert saved["reasoning_effort"] == "low" and saved["reasoning_effort_override"] == "low", saved
    unknown = post(sock, "configure", dict(create, key="preset:unknown", preset="missing"))
    assert unknown["answer"]["code"] == "unknown_preset", unknown
    update = post(sock, "configure", dict(create, key="preset:update", session=session))
    assert update["answer"]["code"] == "preset_on_update", update
    host_process.close_stdin(host)
    assert host.wait(timeout=30) == 0, output(host)

    preset_creation(RUI, root / "cli-presets", good["store"], os.environ)
    empty_creation(RUI, root / "empty-creation", good["store"], os.environ)

    for presets in [
        {"Bad": preset},
        {"a" * 64: dict(preset, **{"\x01" * 64: None})},
        {"review": {name: value for name, value in preset.items() if name != "effort"}},
        {"review": dict(preset, tools=["bash"])},
    ]:
        refused = refusal(launch(frame(dict(good, presets=presets))), expected_exit=2)
        assert refused["code"] == "settings_invalid", refused
        assert "presets" in refused["message"], refused

    for raw, message in [
        (frame(dict(good, v=2)), "v"),
        (frame(dict(good, interface=dict(good["interface"], dir="relative"))), "interface.dir"),
        (frame(dict(good, providers={"openai": {"endpoint": "http://plain.example"}})), "providers.openai.endpoint"),
        (b"\x00\x00", "4-byte"),
    ]:
        process = launch(raw)
        host_process.close_stdin(process)
        refused = refusal(process, expected_exit=2)
        assert refused["code"] == "settings_invalid", refused
        assert message in refused["message"], refused

    docs = mcp_server(["search"])
    clash = mcp_server(["bash"])
    mcp_root = root / "mcp"
    mcp_root.mkdir(mode=0o700)
    base = dict(good, store={"sqlite": {"dir": str(root / "store5")}}, interface=dict(good["interface"], dir=str(mcp_root)))
    host = launch(frame(dict(base, tools={"mcp": dict([mcp_entry("docs", docs)])})))
    wait_for_host(mcp_root / "rui.sock", base["store"]["sqlite"]["dir"], host)
    host_process.close_stdin(host)
    assert host.wait(timeout=30) == 0, output(host)
    colliding = launch(frame(dict(base, tools={"mcp": dict([mcp_entry("docs", docs), mcp_entry("clash", clash)])})))
    line = colliding.stdout.readline()
    refused = json.loads(line)["rui_start_error"]
    assert colliding.wait(timeout=20) == 1
    assert output(colliding)[1].strip(), "a tool-name refusal omitted the stderr diagnostic"
    assert refused["code"] == "tool_name_collision", refused
    assert "bash" in refused["message"] and "clash" in refused["message"], refused
    docs.shutdown()
    docs.server_close()
    host = launch(frame(dict(base, tools={"mcp": dict([mcp_entry("docs", docs)])})))
    wait_for_host(mcp_root / "rui.sock", base["store"]["sqlite"]["dir"], host)
    host_process.close_stdin(host)
    assert host.wait(timeout=30) == 0, output(host)

    silent = socket.socket()
    silent.bind(("127.0.0.1", 0))
    silent.listen(8)
    hang_root = root / "hang"
    hang_root.mkdir(mode=0o700)
    entry = ("slow", {"url": f"http://127.0.0.1:{silent.getsockname()[1]}/mcp", "bearerToken": {"value": "t"}, "callTimeoutMs": 1000})
    host = launch(frame(dict(good, store={"sqlite": {"dir": str(root / "store6")}}, interface=dict(good["interface"], dir=str(hang_root)), tools={"mcp": dict([entry])})))
    silent.settimeout(20)
    held, _ = silent.accept()
    started = time.monotonic()
    host_process.close_stdin(host)
    assert host.wait(timeout=5) == 0, output(host)
    assert time.monotonic() - started < 3
    held.close()
    silent.close()
    sdk_tool_set(root, good, network, ci)
    print(f"settings document: ready, store_locked, runtime_dir_unusable, stdin close stopped the Host in {elapsed:.2f} s, opened paused, preset creation and four preset refusals, four document refusals, MCP tools listed, a collision refused, a server down tolerated")


if __name__ == "__main__":
    ci = bool(os.environ.get("CI") or os.environ.get("GITHUB_ACTIONS") or
              "--require-mcp-sdk" in sys.argv[2:])
    network = host_process.enter()
    main(network, ci)
