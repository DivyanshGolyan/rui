#!/usr/bin/env python3

import base64
import hashlib
import json
import os
import pathlib
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import urllib.error
import urllib.parse
import urllib.request

import codex_fixture
import model_fixture as fixture
import host_process
from host_process import close_stdin, retain_failure_state, start_ready_process


CLIENT = "rui-test-plan-client"
SUBJECT = "plan-subject"
EMAIL = "someone@example.com"
ISSUER = "https://auth.openai.com"
PLAN_SCOPE = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
FAR = 4102444800
HOST_ID = re.compile(r"urn:uuid:[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}")


def compact(claims, signature):
    payload = base64.urlsafe_b64encode(json.dumps(claims, separators=(",", ":")).encode()).rstrip(b"=").decode()
    return "e30." + payload + "." + signature


def credential_facts(path):
    return dict(line.split("=", 1) for line in path.read_text().splitlines())


class IssuerHandler(fixture.SuccessHandler):

    def do_POST(self):
        for name, queue, seen in (("/oauth/token", "tokens", "token_requests"),
                                  ("/oauth/revoke", "revocations", "revoke_requests")):
            if self.path.endswith(name):
                body = self.rfile.read(int(self.headers["Content-Length"]))
                with self.server.lock:
                    getattr(self.server, seen).append(urllib.parse.parse_qs(body.decode(), strict_parsing=True))
                    status, answer = getattr(self.server, queue).pop(0)
                payload = json.dumps(answer).encode() if answer is not None else b""
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(payload)
                self.close_connection = True
                return
        with self.server.lock:
            self.server.bearers.append(self.headers.get("Authorization"))
        super().do_POST()


class Login:

    def __init__(self, url, *extra):
        test_issuer = ["--test-chatgpt-fixture-endpoint", url] if url else []
        test_issuer += extra
        environment = {name: value for name, value in os.environ.items() if name not in ("DISPLAY", "WAYLAND_DISPLAY")}
        self.process = subprocess.Popen(
            [str(fixture.RUI), "auth", "login", "chatgpt", *test_issuer],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=environment,
        )
        self.lines = []
        self.reader = threading.Thread(target=self.read, daemon=True)
        self.reader.start()

    def read(self):
        for line in self.process.stderr:
            self.lines.append(line)

    def link(self, base, authorize="/oauth/authorize?"):
        found = fixture.wait_for(
            lambda: next((line.strip() for line in list(self.lines) if line.startswith(base + authorize)), None),
            "the sign-in link",
        )
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(found).query, strict_parsing=True)
        assert all(len(values) == 1 for values in query.values()), query
        return {name: values[0] for name, values in query.items()}

    def finish(self):
        close_stdin(self.process)
        stdout, _ = self.process.communicate(timeout=15)
        self.reader.join(timeout=5)
        return self.process.returncode, stdout, "".join(self.lines)


def callback(port, query):
    return f"http://127.0.0.1:{port}/auth/callback?" + urllib.parse.urlencode(query)


def get(url):
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(url, timeout=15) as answer:
            return answer.status, answer.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()


def tokens(link, access, refresh):
    id_token = compact({"iss": ISSUER, "aud": [CLIENT], "sub": SUBJECT, "email": EMAIL, "exp": FAR,
                        "nonce": link["nonce"], "https://api.openai.com/auth": {"per_user_salt": "made-up"}}, "c2ln")
    return (200, {"access_token": access, "id_token": id_token, "refresh_token": refresh,
                  "expires_in": 3600, "token_type": "Bearer", "scope": PLAN_SCOPE})


def default_receipt(stdout):
    lines = stdout.splitlines(keepends=True)
    assert lines[0] == "Rui: Signed in to ChatGPT.\n", stdout
    return "".join(line for line in lines[1:] if line.startswith("Rui: "))


def start_line(stdout):
    return stdout.splitlines(keepends=True)[-1]


def saved_default():
    inspected = fixture.command("defaults", "inspect")
    return inspected["connection"], inspected["model"]


SIGNED_OUT = "Rui: Signed out of ChatGPT.\n"
NOTHING = "Rui: Not signed in to ChatGPT; nothing changed.\n"
UNCONFIRMED = ("Rui: Signed out of ChatGPT: Rui deleted its tokens, but ChatGPT did not confirm it ended the "
               "browser sign-in. To end it there too, disconnect Rui in ChatGPT's settings.\n")


def logout(url, **variables):
    return subprocess.run([str(fixture.RUI), "auth", "logout", "chatgpt", "--test-chatgpt-fixture-endpoint", url],
                          capture_output=True, text=True, timeout=30, env={**os.environ, **variables})


def named_file_present(path):
    """Whether a named sign-in's record still holds a signed-in account (signing out empties it)."""
    return path.exists() and "state=signed_out" not in path.read_text()


def unfound(way, variable):
    return (f"rui: could not end the ChatGPT {way} sign-in: Rui could not find its credential. Set {variable} "
            "to an absolute path, or leave it unset with HOME absolute, then run rui auth logout chatgpt again.\n")


def challenge(verifier):
    return base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()


def run():
    state = pathlib.Path(tempfile.mkdtemp(prefix="rui-chatgpt-login.")).resolve()
    home = state / "home"
    home.mkdir(mode=0o700)
    credential_dir = state / "private"
    credential_dir.mkdir(mode=0o700)
    credential_file = credential_dir / "chatgpt.json"
    host_id_file = home / ".config" / "rui" / "host-id"
    device_file = home / ".config" / "rui" / "codex.json"
    os.environ["HOME"] = str(home)
    os.environ["RUI_CHATGPT_CREDENTIAL_FILE"] = str(credential_file)
    os.environ["RUI_CODEX_CREDENTIAL_FILE"] = str(device_file)
    first, second, third = compact({"exp": FAR}, "Zmlyc3Q"), compact({"exp": FAR}, "c2Vjb25k"), compact({"exp": FAR}, "dGhpcmQ")
    fourth, fifth = compact({"exp": FAR}, "Zm91cnRo"), compact({"exp": FAR}, "ZmlmdGg")
    endpoint = fixture.SuccessEndpoint([
        fixture.sse_answer("plan-1", "plan-r1", "plan-m1", "first plan answer")[0],
        fixture.sse_answer("plan-2", "plan-r2", "plan-m2", "after a returning sign-in")[0],
        fixture.sse_answer("plan-3", "plan-r3", "plan-m3", "after signing in again")[0],
    ])
    endpoint.RequestHandlerClass = IssuerHandler
    endpoint.bearers, endpoint.token_requests, endpoint.revoke_requests = [], [], []
    endpoint.tokens, endpoint.revocations = [], []
    thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    thread.start()
    base = f"http://127.0.0.1:{endpoint.server_port}/v1"
    url = base + "/responses"
    store = state / "store"
    host = None
    logins = []
    complete = False
    try:
        status = subprocess.run([str(fixture.RUI), "auth", "status"], capture_output=True, text=True, timeout=15)
        assert status.returncode == 0 and EMAIL not in status.stdout, status
        nothing = logout(url)
        assert (nothing.returncode, nothing.stdout, nothing.stderr) == (0, NOTHING, ""), nothing
        assert not credential_file.exists() and not device_file.exists() and not endpoint.revoke_requests, nothing
        for spelling in (["codex"], ["chatgpt", "--device-code"], ["openai", "--device-code"]):
            other = subprocess.run([str(fixture.RUI), "auth", "login", *spelling, "--test-chatgpt-fixture-endpoint", url],
                                   stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=15)
            assert other.returncode == 2 and not credential_file.exists(), (spelling, other)
            assert not device_file.exists(), spelling
        keyless = subprocess.run([str(fixture.RUI), "auth", "login", "openai", "--device-code"],
                                 stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=15)
        assert keyless.returncode == 2 and not (home / ".config" / "rui" / "openai.key").exists(), keyless
        interrupted = Login(url)
        interrupted.link(base)
        interrupted.process.send_signal(signal.SIGINT)
        code, _, _ = interrupted.finish()
        assert code == 1 and not credential_file.exists() and not endpoint.token_requests, code
        real = Login(None)
        real_link = real.link(ISSUER, "/api/accounts/authorize?")
        assert real_link["client_id"] == "dynamic_agent_client" and "id_token_hint" not in real_link, real_link
        real.process.send_signal(signal.SIGINT)
        code, _, _ = real.finish()
        assert code == 1 and not credential_file.exists(), code

        login = Login(url)
        logins.append(login)
        link = login.link(base)
        host_id = host_id_file.read_text().strip()
        assert HOST_ID.fullmatch(host_id) and host_id_file.stat().st_mode & 0o777 == 0o600, host_id
        redirect = urllib.parse.urlsplit(link["redirect_uri"])
        assert (redirect.scheme, redirect.hostname, redirect.path) == ("http", "127.0.0.1", "/auth/callback"), link
        port = redirect.port
        assert link == {
            "client_id": "dynamic_agent_client", "agent_name_hint": "Rui", "ext_agent_host_id": host_id,
            "response_type": "code", "redirect_uri": f"http://127.0.0.1:{port}/auth/callback", "scope": PLAN_SCOPE,
            "resource": "https://api.openai.com/v1", "state": link["state"], "nonce": link["nonce"],
            "code_challenge_method": "S256", "code_challenge": link["code_challenge"],
        }, link
        with endpoint.lock:
            endpoint.tokens.append(tokens(link, first, "plan-refresh-1"))
        assert get(f"http://127.0.0.1:{port}/favicon.ico")[0] == 404
        answered = get(callback(port, {"code": "ac-made-up-1", "scope": PLAN_SCOPE, "state": link["state"], "client_id": CLIENT}))
        assert answered[0] == 200 and answered[1].count(b"\n") == 1 and answered[1].endswith(b"\n"), answered
        code, stdout, stderr = login.finish()
        assert code == 0, (code, stdout, stderr)
        exchange = endpoint.token_requests[0]
        assert exchange == {
            "grant_type": ["authorization_code"], "client_id": [CLIENT], "code": ["ac-made-up-1"],
            "code_verifier": exchange["code_verifier"], "redirect_uri": [f"http://127.0.0.1:{port}/auth/callback"],
            "resource": ["https://api.openai.com/v1"],
        }, exchange
        assert challenge(exchange["code_verifier"][0]) == link["code_challenge"], exchange
        facts = credential_facts(credential_file)
        assert (facts["generation"], facts["state"], facts["client_id"], facts["account_id"], facts["access_token"]) == \
            ("1", "ready", CLIENT, SUBJECT, first), facts
        assert first not in stdout + stderr and "plan-refresh-1" not in stdout + stderr
        assert default_receipt(stdout) == "Rui: New Sessions will use this sign-in.\n", stdout
        assert start_line(stdout) == "Start a conversation with: rui\n", stdout
        assert "Codex" not in stdout + stderr, (stdout, stderr)
        assert saved_default() == ("chatgpt", None)

        status = subprocess.run([str(fixture.RUI), "auth", "status"], capture_output=True, text=True, timeout=15)
        assert status.returncode == 0 and EMAIL in status.stdout and "2100-01-01 00:00 UTC" in status.stdout, status
        assert first not in status.stdout + status.stderr

        host, _ = start_ready_process(
            [fixture.RUI, "host", "serve", "--store", store, "--set", 'execution.activeCapacity=2', "--set", f"providers.chatgpt.endpoint={url}", "--set", f"providers.chatgpt.tokenEndpoint={base}/oauth/token",
             "--set", f"providers.codex.endpoint={url}"],
            required_fields={"execution": "enabled"},
        )
        configured = fixture.command(
            "session", "configure", "--store", store, "--record", state / "configure.json", "--key", "configure",
            "--workspace", fixture.ROOT, "--connection", "chatgpt", "--model", "gpt-6-sol", "--tools", "none",
        )
        assert configured["answer"]["status"] == "accepted", configured
        session = configured["answer"]["session"]
        fixture.message(state, store, "first", session, "first plan message")
        fixture.wait_for(lambda: fixture.completed_observation(store, "first"), "first plan answer")
        assert endpoint.bearers == ["Bearer " + first], endpoint.bearers

        fixture.command("defaults", "configure", "--connection", "openai", "--model", "gpt-6-sol")
        login = Login(url)
        logins.append(login)
        link = login.link(base)
        assert link["client_id"] == CLIENT and link["ext_agent_host_id"] == host_id, link
        assert "agent_name_hint" not in link and "id_token_hint" not in link, link
        port = urllib.parse.urlsplit(link["redirect_uri"]).port
        with endpoint.lock:
            endpoint.tokens.append(tokens(link, second, "plan-refresh-2"))
        pasted = callback(port, {"code": "ac-made-up-2", "state": link["state"]}).replace("&", "&amp;")
        login.process.stdin.write("not an address\n  `" + pasted + "`\n")
        login.process.stdin.flush()
        code, stdout, stderr = login.finish()
        assert code == 0, (code, stdout, stderr)
        assert endpoint.token_requests[1]["client_id"] == [CLIENT] and endpoint.token_requests[1]["code"] == ["ac-made-up-2"]
        facts = credential_facts(credential_file)
        assert (facts["generation"], facts["client_id"], facts["access_token"]) == ("2", CLIENT, second), facts
        assert default_receipt(stdout) == ("Rui: Your default provider for new Sessions is unchanged. "
                          "To use ChatGPT instead: rui defaults configure --connection chatgpt\n"), stdout
        assert start_line(stdout) == "Start a conversation with: rui --connection chatgpt\n", stdout
        assert saved_default() == ("openai", "gpt-6-sol")
        assert host_id_file.read_text().strip() == host_id
        fixture.message(state, store, "second", session, "after a returning sign-in")
        fixture.wait_for(lambda: fixture.completed_observation(store, "second"), "answer after a returning sign-in")
        assert endpoint.bearers[1:] == ["Bearer " + second], endpoint.bearers

        login = Login(url)
        logins.append(login)
        link = login.link(base)
        port = urllib.parse.urlsplit(link["redirect_uri"]).port
        refused = get(callback(port, {"code": "ac-made-up-3", "state": "another-attempt", "client_id": CLIENT}))
        assert refused[0] == 400, refused
        code, stdout, stderr = login.finish()
        assert code != 0, (code, stdout, stderr)
        assert len(endpoint.token_requests) == 2 and credential_facts(credential_file)["generation"] == "2"

        with endpoint.lock:
            endpoint.revocations.append((200, None))
        out = logout(url)
        assert (out.returncode, out.stdout, out.stderr) == (0, SIGNED_OUT, ""), out
        assert endpoint.revoke_requests == [{"token": ["plan-refresh-2"], "token_type_hint": ["refresh_token"], "client_id": [CLIENT]}]
        facts = credential_facts(credential_file)
        assert (facts["state"], facts["client_id"], facts["generation"]) == ("signed_out", CLIENT, "3"), facts
        assert facts["access_token"] == facts["refresh_token"] == facts["id_token"] == "", facts
        assert host_id_file.read_text().strip() == host_id
        status = subprocess.run([str(fixture.RUI), "auth", "status"], capture_output=True, text=True, timeout=15)
        assert status.returncode == 0 and EMAIL not in status.stdout, status
        fixture.message(state, store, "signed-out", session, "after logout")
        failure = fixture.wait_for(
            lambda: (value := fixture.observe(store, "signed-out")).get("result", {}).get("code") and value,
            "sign-in failure after logout",
        )
        assert failure["result"]["code"] == "provider_sign_in_required", failure
        assert len(endpoint.bearers) == 2, endpoint.bearers

        codex_fixture.credentials(device_file)
        fixture.command("defaults", "configure", "--connection", "codex", "--model", "gpt-6-sol")
        login = Login(url)
        logins.append(login)
        link = login.link(base)
        assert link["client_id"] == CLIENT and "agent_name_hint" not in link, link
        port = urllib.parse.urlsplit(link["redirect_uri"]).port
        with endpoint.lock:
            endpoint.tokens.append(tokens(link, third, "plan-refresh-3"))
        assert get(callback(port, {"code": "ac-made-up-4", "state": link["state"]}))[0] == 200
        code, stdout, stderr = login.finish()
        assert code == 0, (code, stdout, stderr)
        assert credential_facts(credential_file)["access_token"] == third
        assert default_receipt(stdout) == "Rui: New Sessions will use this sign-in; Sessions already open keep theirs.\n", stdout
        assert start_line(stdout) == "Start a conversation with: rui\n", stdout
        assert "Codex" not in stdout + stderr, (stdout, stderr)
        assert saved_default() == ("chatgpt", "gpt-6-sol")
        status = subprocess.run([str(fixture.RUI), "auth", "status"], capture_output=True, text=True, timeout=15)
        lines = status.stdout.splitlines()
        assert status.returncode == 0 and lines[0].startswith("ChatGPT: signed in as " + EMAIL), status
        assert lines[1] == "ChatGPT (device code): signed in (remote acceptance not checked).", status
        assert "Codex" not in status.stdout, status
        fixture.message(state, store, "third", session, "after signing in again")
        fixture.wait_for(lambda: fixture.completed_observation(store, "third"), "answer after signing in again")
        assert endpoint.bearers[2:] == ["Bearer " + third], endpoint.bearers

        with endpoint.lock:
            endpoint.responses.append(fixture.sse_answer("device-1", "device-r1", "device-m1", "device-code answer")[0])
        device_session = fixture.command(
            "session", "configure", "--store", store, "--record", state / "configure-device.json", "--key", "configure-device",
            "--workspace", fixture.ROOT, "--connection", "codex", "--model", "gpt-6-sol", "--tools", "none",
        )["answer"]["session"]
        fixture.message(state, store, "device", device_session, "device-code message")
        fixture.wait_for(lambda: fixture.completed_observation(store, "device"), "device-code answer")
        assert endpoint.bearers[3:] == ["Bearer " + codex_fixture.ACCESS], endpoint.bearers

        with endpoint.lock:
            endpoint.revocations.append((200, None))
        out = logout(url)
        assert (out.returncode, out.stdout, out.stderr) == (0, SIGNED_OUT, ""), out
        assert [request["token"] for request in endpoint.revoke_requests] == [["plan-refresh-2"], ["plan-refresh-3"]], endpoint.revoke_requests
        assert credential_facts(credential_file)["state"] == "signed_out"
        device = credential_facts(device_file)
        assert (device["state"], device["generation"], device["account_id"]) == ("signed_out", "2", codex_fixture.ACCOUNT), device
        assert device["access_token"] == device["refresh_token"] == device["id_token"] == "" and "client_id" not in device, device
        status = subprocess.run([str(fixture.RUI), "auth", "status"], capture_output=True, text=True, timeout=15)
        assert status.returncode == 0 and status.stdout == (
            "ChatGPT: not signed in; sign in with `rui auth login chatgpt` (add --device-code to use a code instead of the browser).\n"
            "OpenAI API key: missing.\n"), status
        for key, chat in (("browser-out", session), ("device-out", device_session)):
            fixture.message(state, store, key, chat, "after logging out of both")
            failure = fixture.wait_for(
                lambda: (value := fixture.observe(store, key)).get("result", {}).get("code") and value,
                "sign-in failure after logging out of both",
            )
            assert failure["result"]["code"] == "provider_sign_in_required", (key, failure)
        assert len(endpoint.bearers) == 4, endpoint.bearers

        out = logout(url)
        assert (out.returncode, out.stdout, out.stderr) == (0, NOTHING, ""), out
        assert len(endpoint.revoke_requests) == 2, endpoint.revoke_requests

        codex_fixture.credentials(device_file)
        out = logout(url)
        assert (out.returncode, out.stdout, out.stderr) == (0, SIGNED_OUT, ""), out
        assert len(endpoint.revoke_requests) == 2, endpoint.revoke_requests
        assert credential_facts(device_file)["state"] == "signed_out"

        login = Login(url)
        logins.append(login)
        link = login.link(base)
        port = urllib.parse.urlsplit(link["redirect_uri"]).port
        with endpoint.lock:
            endpoint.tokens.append(tokens(link, fourth, "plan-refresh-4"))
        assert get(callback(port, {"code": "ac-made-up-5", "state": link["state"]}))[0] == 200
        code, stdout, stderr = login.finish()
        assert code == 0 and credential_facts(credential_file)["access_token"] == fourth, (code, stdout, stderr)
        codex_fixture.credentials(device_file)
        with endpoint.lock:
            endpoint.revocations.append((400, {"error": "invalid_request"}))
        out = logout(url)
        assert (out.returncode, out.stdout, out.stderr) == (0, UNCONFIRMED, ""), out
        assert endpoint.revoke_requests[2]["token"] == ["plan-refresh-4"], endpoint.revoke_requests
        assert credential_facts(credential_file)["state"] == credential_facts(device_file)["state"] == "signed_out"

        login = Login(url)
        logins.append(login)
        link = login.link(base)
        port = urllib.parse.urlsplit(link["redirect_uri"]).port
        with endpoint.lock:
            endpoint.tokens.append(tokens(link, fifth, "plan-refresh-5"))
        assert get(callback(port, {"code": "ac-made-up-6", "state": link["state"]}))[0] == 200
        code, stdout, stderr = login.finish()
        assert code == 0, (code, stdout, stderr)
        codex_fixture.credentials(device_file)
        out = logout(url, RUI_CHATGPT_CREDENTIAL_FILE="private/chatgpt.json")
        assert (out.returncode, out.stdout, out.stderr) == (
            1, "Rui: Signed out of ChatGPT with a device code.\n", unfound("browser", "RUI_CHATGPT_CREDENTIAL_FILE")), out
        assert len(endpoint.revoke_requests) == 3, endpoint.revoke_requests
        assert credential_facts(credential_file)["access_token"] == fifth
        assert credential_facts(device_file)["state"] == "signed_out"
        codex_fixture.credentials(device_file)
        with endpoint.lock:
            endpoint.revocations.append((200, None))
        out = logout(url, RUI_CODEX_CREDENTIAL_FILE="codex.json")
        assert (out.returncode, out.stdout, out.stderr) == (
            1, "Rui: Signed out of ChatGPT in the browser.\n", unfound("device-code", "RUI_CODEX_CREDENTIAL_FILE")), out
        assert endpoint.revoke_requests[3]["token"] == ["plan-refresh-5"], endpoint.revoke_requests
        assert credential_facts(credential_file)["state"] == "signed_out"
        assert credential_facts(device_file)["state"] == "ready"
        fixture.stop_host(host)
        host = None
        # A named sign-in keeps its own record and leaves the built-ins and the saved default alone.
        built_in_before = credential_file.read_bytes() if credential_file.exists() else None
        default_before = saved_default()
        work_file = credential_dir / "work.json"
        os.environ["RUI_WORK_CREDENTIAL_FILE"] = str(work_file)
        refused = subprocess.run([str(fixture.RUI), "auth", "login", "chatgpt", "--connection", "chatgpt", "--test-chatgpt-fixture-endpoint", url],
                                 stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=15)
        assert refused.returncode == 2 and not work_file.exists(), refused
        named_login = Login(url, "--connection", "work")
        logins.append(named_login)
        named_link = named_login.link(base)
        named_port = urllib.parse.urlsplit(named_link["redirect_uri"]).port
        named_token = compact({"exp": FAR}, "bmFtZWQ")
        with endpoint.lock:
            endpoint.tokens.append(tokens(named_link, named_token, "plan-refresh-named"))
        assert get(callback(named_port, {"code": "ac-made-up-named", "scope": PLAN_SCOPE, "state": named_link["state"], "client_id": CLIENT}))[0] == 200
        code, stdout, stderr = named_login.finish()
        assert code == 0, (code, stdout, stderr)
        named_facts = credential_facts(work_file)
        assert (named_facts["state"], named_facts["client_id"], named_facts["access_token"]) == ("ready", CLIENT, named_token), named_facts
        assert "Signed in to ChatGPT in the browser as work." in stdout and "oauth credential" in stdout, stdout
        assert named_token not in stdout + stderr and "plan-refresh-named" not in stdout + stderr
        assert "New Sessions will use" not in stdout and "Start a conversation with" not in stdout, stdout
        assert (credential_file.read_bytes() if credential_file.exists() else None) == built_in_before
        assert saved_default() == default_before
        revoked_before = len(endpoint.revoke_requests)
        named_out = subprocess.run([str(fixture.RUI), "auth", "logout", "chatgpt", "--connection", "work", "--test-chatgpt-fixture-endpoint", url],
                                   capture_output=True, text=True, timeout=30)
        assert named_out.returncode == 0 and named_out.stderr == "", named_out
        assert named_out.stdout.startswith("Rui: Signed out of ChatGPT as work in the browser"), named_out
        asked = endpoint.revoke_requests[revoked_before:]
        assert asked and all(request["token"] == ["plan-refresh-named"] for request in asked), asked
        assert not named_file_present(work_file), work_file.read_text() if work_file.exists() else None
        assert (credential_file.read_bytes() if credential_file.exists() else None) == built_in_before
        again = subprocess.run([str(fixture.RUI), "auth", "logout", "chatgpt", "--connection", "work", "--test-chatgpt-fixture-endpoint", url],
                               capture_output=True, text=True, timeout=30)
        assert (again.returncode, again.stdout) == (0, "Rui: Not signed in as work; nothing changed.\n"), again
        # A name's grammar is refused on both commands before anything is touched.
        for argv in (["login", "openai", "--connection", "work"], ["login", "chatgpt", "--connection", "Work"],
                     ["login", "chatgpt", "--connection", "2fa"], ["logout", "chatgpt", "--connection", "codex"],
                     ["logout", "chatgpt", "--connection", "2fa"]):
            bad = subprocess.run([str(fixture.RUI), "auth", *argv, "--test-chatgpt-fixture-endpoint", url],
                                 stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=15)
            assert bad.returncode == 2 and "Nothing was changed" in bad.stderr, (argv, bad)
        # A ready device-code record under the name is not replaced by a browser login, and
        # logging out of it signs it out locally without asking the issuer to revoke anything.
        codex_fixture.credentials(work_file)
        device_before = work_file.read_bytes()
        crossed = subprocess.run([str(fixture.RUI), "auth", "login", "chatgpt", "--connection", "work", "--test-chatgpt-fixture-endpoint", url],
                                 stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=15)
        assert crossed.returncode == 2 and "already holds the other kind" in crossed.stderr, crossed
        assert work_file.read_bytes() == device_before
        revoked_before = len(endpoint.revoke_requests)
        device_out = subprocess.run([str(fixture.RUI), "auth", "logout", "chatgpt", "--connection", "work", "--test-chatgpt-fixture-endpoint", url],
                                    capture_output=True, text=True, timeout=30)
        assert (device_out.returncode, device_out.stderr) == (0, ""), device_out
        assert device_out.stdout.startswith("Rui: Signed out of ChatGPT as work with a device code"), device_out
        assert len(endpoint.revoke_requests) == revoked_before and credential_facts(work_file)["state"] == "signed_out"
        # An unreadable record is not signed out and says so.
        work_file.write_text("not a credential\n")
        work_file.chmod(0o600)
        broken = subprocess.run([str(fixture.RUI), "auth", "logout", "chatgpt", "--connection", "work", "--test-chatgpt-fixture-endpoint", url],
                                capture_output=True, text=True, timeout=30)
        assert broken.returncode == 1 and broken.stdout == "" and broken.stderr != "", broken
        del os.environ["RUI_WORK_CREDENTIAL_FILE"]
        print("chatgpt login passed: listener and pasted sign-in, returning client reused, stale answer refused, "
              "logout ends both sign-ins and a running Host refuses either until the next sign-in, and says when "
              "ChatGPT has not confirmed; an unset default is filled, an OpenAI default stays and a device-code one is "
              "replaced keeping its model")
        complete = True
    finally:
        incoming_error = sys.exc_info()[1]
        errors = []
        for login in logins:
            if login.process.poll() is None:
                login.process.kill()
                login.process.wait(timeout=5)
        for dispose in (lambda: fixture.stop_host(host) if host is not None else None,
                        endpoint.shutdown, endpoint.server_close, lambda: thread.join(timeout=5)):
            try:
                dispose()
            except BaseException as error:
                errors.append(error)
        del os.environ["RUI_CHATGPT_CREDENTIAL_FILE"]
        del os.environ["RUI_CODEX_CREDENTIAL_FILE"]
        if complete and incoming_error is None and not errors:
            shutil.rmtree(state)
        else:
            retain_failure_state("ChatGPT login failure state", state)
        if errors and incoming_error is None:
            raise errors[0]


if __name__ == "__main__":
    host_process.enter()
    run()
