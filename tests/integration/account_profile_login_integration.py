#!/usr/bin/env python3
"""Exercise fresh profile login and scoped logout with a loopback issuer."""
import os
import pathlib
import re
import shutil
import subprocess
import tempfile
import threading
import urllib.parse

import chatgpt_login_integration as login_fixture
import chatgpt_plan_integration as plan_fixture
import codex_fixture
import model_fixture as fixture
from host_process import retain_failure_state


def run():
    state = pathlib.Path(tempfile.mkdtemp(prefix="rui-profile-login.")).resolve()
    home = state / "home"
    config = home / ".config/rui"
    config.mkdir(mode=0o700, parents=True)
    home.chmod(0o700)
    (home / ".config").chmod(0o700)
    os.environ["HOME"] = str(home)
    browser = config / "chatgpt.json"
    device = config / "codex.json"
    os.environ["RUI_CHATGPT_CREDENTIAL_FILE"] = str(browser)
    os.environ["RUI_CODEX_CREDENTIAL_FILE"] = str(device)
    codex_fixture.credentials(device)
    plan_fixture.credentials(browser, token=plan_fixture.access(plan_fixture.FAR, "c2ln"),
                             expires_at=plan_fixture.FAR)
    before_browser, before_device = browser.read_bytes(), device.read_bytes()
    configured = subprocess.run([str(fixture.RUI), "defaults", "configure", "--provider", "codex"],
                                text=True, capture_output=True, timeout=15)
    assert configured.returncode == 0, configured.stderr
    preferences = config / "preferences"
    before_preferences = preferences.read_bytes()
    endpoint = fixture.SuccessEndpoint([])
    endpoint.RequestHandlerClass = login_fixture.IssuerHandler
    endpoint.bearers, endpoint.token_requests, endpoint.revoke_requests = [], [], []
    endpoint.tokens, endpoint.revocations = [], []
    thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    thread.start()
    base = f"http://127.0.0.1:{endpoint.server_port}/v1"
    url = base + "/responses"
    active = []
    complete = False
    try:
        ids = []
        for index in range(2):
            attempt = login_fixture.Login(url)
            active.append(attempt)
            link = attempt.link(base)
            token = login_fixture.compact({"exp": login_fixture.FAR}, "c2ln")
            with endpoint.lock:
                endpoint.tokens.append(login_fixture.tokens(link, token, f"synthetic-profile-{index}"))
            port = urllib.parse.urlsplit(link["redirect_uri"]).port
            response = login_fixture.get(login_fixture.callback(port, {
                "code": f"synthetic-code-{index}", "scope": login_fixture.PLAN_SCOPE,
                "state": link["state"], "client_id": login_fixture.CLIENT,
            }))
            assert response[0] == 200, response[0]
            code, stdout, stderr = attempt.finish()
            active.remove(attempt)
            assert code == 0, (code, stdout, stderr)
            matched = re.search(r"ChatGPT profile ([0-9a-f]{32}) saved", stdout)
            assert matched, stdout
            ids.append(matched.group(1))
            assert token not in stdout + stderr and f"synthetic-profile-{index}" not in stdout + stderr
            assert browser.read_bytes() == before_browser and device.read_bytes() == before_device
            assert preferences.read_bytes() == before_preferences
        assert ids[0] != ids[1]
        listing = subprocess.run([str(fixture.RUI), "auth", "profiles"], text=True, capture_output=True, timeout=15)
        status = subprocess.run([str(fixture.RUI), "auth", "status"], text=True, capture_output=True, timeout=15)
        assert listing.returncode == status.returncode == 0, (listing.stderr, status.stderr)
        assert all(id_ in listing.stdout and id_ in status.stdout for id_ in ids)
        assert login_fixture.EMAIL in listing.stdout
        first, second = (config / "profiles" / id_ for id_ in ids)
        second_before = second.read_bytes()
        with endpoint.lock:
            endpoint.revocations.append((403, None))
        logout = subprocess.run([str(fixture.RUI), "auth", "logout", "chatgpt", "--profile", ids[0],
                                 "--test-chatgpt-fixture-endpoint", url], text=True, capture_output=True, timeout=30)
        assert logout.returncode == 0, (logout.stdout, logout.stderr)
        assert "signed out locally" in logout.stdout and "did not confirm remote revocation" in logout.stderr
        assert login_fixture.credential_facts(first)["state"] == "signed_out"
        assert second.read_bytes() == second_before
        assert browser.read_bytes() == before_browser and device.read_bytes() == before_device
        assert preferences.read_bytes() == before_preferences
        complete = True
    finally:
        for attempt in active:
            attempt.process.terminate()
            attempt.process.wait(timeout=5)
            attempt.reader.join(timeout=5)
        endpoint.shutdown()
        endpoint.server_close()
        thread.join(timeout=5)
        if complete:
            shutil.rmtree(state)
        else:
            retain_failure_state("profile login failure state", state)


if __name__ == "__main__":
    run()
