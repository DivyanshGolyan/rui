#!/usr/bin/env python3
"""A Session on --provider chatgpt, against a loopback that answers as
OpenAI's API and as the plan's token issuer, with made-up tokens only."""

import base64
import json
import os
import pathlib
import shutil
import sys
import tempfile
import threading
import time
import urllib.parse

import bash_fixture as bash
import model_fixture as fixture
import host_process
from host_process import retain_failure_state, start_ready_process
from control_fixture import raw_request
from codex_fixture import expected_user_agent


# The client a plan fixture's record must name (codex_credential_policy.fixture_client_id).
CLIENT = "rui-test-plan-client"
SUBJECT = "plan-subject"
PLAN_SCOPE = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
FAR = 4102444800
# The plan's list as OpenAI's API answers it: a hidden entry is not offered,
# and the rest keep the server's order.
PLAN_MODELS = json.dumps({"models": [
    {"slug": "gpt-6-terra", "display_name": "Terra", "visibility": "list", "context_window": 1,
     "supported_reasoning_levels": [{"effort": "minimal"}]},
    {"slug": "plan-hidden", "visibility": "hide"},
    {"slug": "gpt-6-sol", "visibility": "list"},
]}).encode()
QUOTA = fixture.encode_sse([{"type": "response.failed", "response": {"status": "failed", "error": {
    "code": "subscription_sharing_usage_limit_exceeded", "message": "Plan limit reached."}}}])


def compact(claims, signature):
    payload = base64.urlsafe_b64encode(json.dumps(claims, separators=(",", ":")).encode()).rstrip(b"=").decode()
    return "e30." + payload + "." + signature


ID = compact({"sub": SUBJECT}, "c2ln")


def access(expires_at, signature):
    return compact({"exp": expires_at}, signature)


def credentials(path, *, token, expires_at, refresh="plan-refresh-1", client=CLIENT, generation=1):
    path.write_text(
        "version=3\ngeneration=" + str(generation) + "\naccount_id=" + SUBJECT + "\nclient_id=" + client +
        "\nfedramp=0\nid_token=" + ID + "\naccess_token=" + token + "\nrefresh_token=" + refresh +
        "\nexpires_at=" + str(expires_at) + "\nrefreshed_at=1750000000\nstate=ready\n"
    )
    path.chmod(0o600)


def credential_facts(path):
    return dict(line.split("=", 1) for line in path.read_text().splitlines())


class PlanHandler(fixture.SuccessHandler):
    """Responses at BASE/responses, as the fixture endpoint; the model list
    beside it at BASE/models; the token endpoint at BASE/oauth/token, which
    the Host derives from it."""

    def do_GET(self):
        with self.server.lock:
            self.server.model_gets.append({
                "path": self.path,
                "authorization": self.headers.get("Authorization"),
                "user_agent": self.headers.get("User-Agent"),
            })
            status, payload = self.server.models
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)
        self.close_connection = True

    def do_POST(self):
        if self.path.endswith("/oauth/token"):
            body = self.rfile.read(int(self.headers["Content-Length"]))
            with self.server.lock:
                self.server.token_requests.append(urllib.parse.parse_qs(body.decode(), strict_parsing=True))
                answer = self.server.tokens.pop(0)
            payload = json.dumps(answer).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(payload)
            self.close_connection = True
            return
        with self.server.lock:
            self.server.observed.append({
                "path": self.path,
                "authorization": self.headers.get("Authorization"),
                "account": self.headers.get("ChatGPT-Account-ID"),
                "fedramp": self.headers.get("X-OpenAI-FedRAMP"),
                "user_agent": self.headers.get("User-Agent"),
            })
        super().do_POST()


def start(store, endpoint):
    host, _ = start_ready_process(
        [fixture.RUI, "host", "serve", "--store", store, "--active-capacity", "2",
         "--test-chatgpt-fixture-endpoint", endpoint],
        required_fields={"execution": "enabled"},
    )
    return host


def plan_list(host, store):
    """The chatgpt entry of a model-list reply; each request also asks the
    Host to fetch the list again."""
    head, body = raw_request(host.rui_ready_fields["socket"], "/v1/model-list", json.dumps({
        "version": host_process.WIRE_VERSION, "kind": "model_list", "store": str(store),
    }).encode())
    assert b" 200 " in head, (head, body)
    return next(entry for entry in json.loads(body)["providers"] if entry["provider"] == "chatgpt")


def settled_list(host, store, source, description):
    return fixture.wait_for(
        lambda: (entry if (entry := plan_list(host, store))["source"] == source else None),
        description, timeout=20, interval=0.1)


def run():
    state = pathlib.Path(tempfile.mkdtemp(prefix="rui-chatgpt.")).resolve()
    credential_dir = state / "private"
    credential_dir.mkdir(mode=0o700)
    credential_file = credential_dir / "chatgpt.json"
    os.environ["RUI_CHATGPT_CREDENTIAL_FILE"] = str(credential_file)
    # Due at launch: inside the 300-second margin of its own exp.
    soon = int(time.time()) + 60
    first, second, third = access(soon, "Zmlyc3Q"), access(FAR, "c2Vjb25k"), access(FAR, "dGhpcmQ")
    credentials(credential_file, token=first, expires_at=soon)
    endpoint = fixture.SuccessEndpoint([
        fixture.sse_answer("plan-1", "plan-r1", "plan-m1", "first plan answer")[0],
        fixture.sse_answer("plan-2", "plan-r2", "plan-m2", "second plan answer")[0],
        fixture.ResponseSpec(b"stale token", {"X-Request-Id": "stale"}, 401),
        fixture.sse_answer("plan-3", "plan-r3", "plan-m3", "refreshed plan answer")[0],
        QUOTA,
    ])
    endpoint.RequestHandlerClass = PlanHandler
    endpoint.observed = []
    endpoint.model_gets = []
    endpoint.models = (200, PLAN_MODELS)
    endpoint.token_requests = []
    endpoint.tokens = [
        {"access_token": second, "refresh_token": "plan-refresh-2", "token_type": "Bearer", "scope": PLAN_SCOPE},
        {"access_token": third, "refresh_token": "plan-refresh-3", "token_type": "Bearer", "scope": PLAN_SCOPE},
    ]
    thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    thread.start()
    url = f"http://127.0.0.1:{endpoint.server_port}/v1/responses"
    store = state / "store"
    host = None
    complete = False
    try:
        host = start(store, url)
        status = fixture.command("host", "status", "--store", store)
        assert status["capabilities"]["providers"]["chatgpt"] == "chatgpt_plan", status
        configured = fixture.command(
            "session", "configure", "--store", store, "--record", state / "configure.json",
            "--key", "configure", "--workspace", fixture.ROOT,
            "--provider", "chatgpt", "--model", "gpt-6-sol", "--tools", "none",
        )
        assert configured["answer"]["status"] == "accepted", configured
        session = configured["answer"]["session"]

        # The token is inside the launch margin of its exp: the lease
        # refreshes it over the plan wire before the first request.
        fixture.message(state, store, "first", session, "first plan message")
        fixture.wait_for(lambda: fixture.completed_observation(store, "first"), "first plan answer")
        assert fixture.read_result(store, "first") == b"first plan answer"
        assert len(endpoint.token_requests) == 1, endpoint.token_requests
        assert endpoint.token_requests[0] == {
            "grant_type": ["refresh_token"], "client_id": [CLIENT], "refresh_token": ["plan-refresh-1"],
            "resource": ["https://api.openai.com/v1"],
        }, endpoint.token_requests[0]
        facts = credential_facts(credential_file)
        assert (facts["generation"], facts["state"], facts["access_token"], facts["client_id"]) == ("2", "ready", second, CLIENT), facts
        # The bearer alone, to the Responses path: no account or FedRAMP header.
        assert endpoint.observed[0] == {
            "path": "/v1/responses", "authorization": "Bearer " + second, "account": None, "fedramp": None,
            "user_agent": expected_user_agent(),
        }, endpoint.observed[0]

        # The plan's live list, fetched beside the Responses path with the
        # same bearer: listed entries only, in the server's order. Whichever
        # of the list and the first message leased first refreshed the token.
        listed = settled_list(host, store, "live", "the plan's live model list")
        assert [model["id"] for model in listed["models"]] == ["gpt-6-terra", "gpt-6-sol"], listed
        assert endpoint.model_gets and all(get == {
            "path": "/v1/models", "authorization": "Bearer " + second, "user_agent": expected_user_agent(),
        } for get in endpoint.model_gets), endpoint.model_gets
        assert len(endpoint.token_requests) == 1, endpoint.token_requests

        # openai-responses/3: an effort change goes on top of the next
        # request, never as a configuration_update item.
        changed = fixture.command(
            "session", "configure", "--store", store, "--session", session,
            "--record", state / "effort-high.json", "--key", "effort-high", "--reasoning-effort", "high",
        )
        assert changed["answer"]["status"] == "accepted", changed
        fixture.message(state, store, "second", session, "second plan message")
        fixture.wait_for(lambda: fixture.completed_observation(store, "second"), "second plan answer")
        later = json.loads(endpoint.requests[1])
        assert later["reasoning"] == {"effort": "high"}, later
        assert not [item for item in later["input"] if item.get("type") == "configuration_update"], later["input"]
        assert len(endpoint.token_requests) == 1, "a token far from expiry was refreshed"

        # A 401 spends the Operation's one forced refresh, over the plan
        # wire, and its one replacement Attempt carries the new token.
        fixture.message(state, store, "stale", session, "refresh a rejected token")
        answered = fixture.wait_for(lambda: fixture.completed_observation(store, "stale"), "answer after forced refresh")
        assert answered["binding"]["attempt"] == "2", answered
        assert fixture.read_result(store, "stale") == b"refreshed plan answer"
        assert len(endpoint.token_requests) == 2 and endpoint.token_requests[1]["refresh_token"] == ["plan-refresh-2"], endpoint.token_requests
        assert [seen["authorization"] for seen in endpoint.observed[2:]] == ["Bearer " + second, "Bearer " + third], endpoint.observed
        assert all(seen["account"] is None and seen["fedramp"] is None for seen in endpoint.observed), endpoint.observed
        assert endpoint.requests[2] == endpoint.requests[3], "the replacement changed the model request"
        assert credential_facts(credential_file)["generation"] == "3"

        # A plan limit is a quota refusal, answered once and never retried.
        fixture.message(state, store, "quota", session, "past the plan's limit")
        limited = fixture.wait_for(lambda: fixture.observe(store, "quota").get("result") and fixture.observe(store, "quota"), "plan quota refusal")
        assert limited["result"] == {"status": "failed", "code": "provider_quota"}, limited
        assert limited["binding"]["attempt"] == "1" and len(endpoint.requests) == 5, (limited, len(endpoint.requests))

        # A failed or refused list falls back to the catalog; a 401 on it
        # forces no refresh.
        for status, body in ((500, b'{"error":"unavailable"}'), (401, b"stale token")):
            endpoint.models = (200, PLAN_MODELS)
            settled_list(host, store, "live", "the plan's live list again")
            endpoint.models = (status, body)
            fallback = settled_list(host, store, "catalog_fallback", f"catalog fallback after {status}")
            assert fallback["models"] and all(model["known"] for model in fallback["models"]), fallback
        assert len(endpoint.token_requests) == 2, endpoint.token_requests

        # A record from another client never reaches the fixture.
        fixture.stop_host(host)
        host = None
        assert bash.rows(store, "SELECT provider, codec FROM session WHERE session_ref=?", (session,)) == [("chatgpt", "openai-responses/3")]
        credentials(credential_file, token=access(FAR, "b3RoZXI"), expires_at=FAR, client="another-client")
        gets = len(endpoint.model_gets)
        host = start(store, url)
        fixture.message(state, store, "foreign", session, "another client's record")
        fixture.wait_for(lambda: fixture.observe(store, "foreign").get("result"), "fixture refusal")
        settled_list(host, store, "catalog_fallback", "catalog fallback for another client's record")
        assert len(endpoint.requests) == 5 and len(endpoint.token_requests) == 2, "another client's record reached the fixture"
        assert len(endpoint.model_gets) == gets, "another client's record reached the model list"
        fixture.stop_host(host)
        host = None

        # With no sign-in, the list falls back without asking for one.
        credential_file.unlink()
        host = start(store, url)
        settled_list(host, store, "catalog_fallback", "catalog fallback without a sign-in")
        assert len(endpoint.model_gets) == gets, "the model list was asked for without a sign-in"
        fixture.stop_host(host)
        host = None
        for secret in (second.encode(), third.encode(), b"plan-refresh-3"):
            assert not bash.rows(store, "SELECT 1 FROM content WHERE instr(payload, ?) > 0", (secret,))
        print("chatgpt plan passed: bearer only, codec 3, refresh at expiry and on a 401 over the plan wire, "
              "a plan limit refused once, and a live model list that falls back without retrying")
        complete = True
    finally:
        incoming_error = sys.exc_info()[1]
        errors = []
        for dispose in (lambda: fixture.stop_host(host) if host is not None else None,
                        endpoint.shutdown, endpoint.server_close, lambda: thread.join(timeout=5)):
            try:
                dispose()
            except BaseException as error:
                errors.append(error)
        del os.environ["RUI_CHATGPT_CREDENTIAL_FILE"]
        if complete and incoming_error is None and not errors:
            shutil.rmtree(state)
        else:
            retain_failure_state("ChatGPT plan failure state", state)
        if errors and incoming_error is None:
            raise errors[0]


if __name__ == "__main__":
    host_process.enter()
    run()
