"""Fake Codex credentials and the user agent Rui sends, for every fixture that
signs in to Codex."""
import pathlib
import re
import shutil
import subprocess

import model_fixture as fixture


ACCESS = "e30.eyJleHAiOjQxMDI0NDQ4MDB9.c2ln"


ID = "e30.eyJjaGF0Z3B0X2FjY291bnRfaWQiOiJydWktdGVzdC1hY2NvdW50In0.c2ln"


FEDRAMP_ID = "e30.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoicnVpLXRlc3QtYWNjb3VudCIsImNoYXRncHRfYWNjb3VudF9pc19mZWRyYW1wIjp0cnVlfX0.c2ln"


ACCOUNT = "rui-test-account"


def expected_user_agent():
    if not (fixture.ROOT / ".git").exists() or shutil.which("git") is None:
        return "rui/unknown"
    identity = subprocess.run(
        ["git", "rev-parse", "--show-toplevel", "HEAD"], cwd=fixture.ROOT,
        capture_output=True, text=True,
    )
    lines = identity.stdout.splitlines()
    revision = lines[1] if (identity.returncode == 0 and len(lines) == 2
                           and pathlib.Path(lines[0]).resolve() == fixture.ROOT
                           and re.fullmatch(r"[0-9a-f]{40}", lines[1])) else "unknown"
    return "rui/" + revision


def credentials(path, *, state="ready", access=ACCESS, fedramp=False, generation=1):
    path.write_text(
        "version=3\ngeneration=" + str(generation) + "\naccount_id=" + ACCOUNT +
        "\nfedramp=" + str(int(fedramp)) + "\nid_token=" + (FEDRAMP_ID if fedramp else ID) +
        "\naccess_token=" + access + "\nrefresh_token=synthetic-not-real\n"
        "expires_at=4102444800\nrefreshed_at=1750000000\nstate=" + state + "\n"
    )
    path.chmod(0o600)


OPENAI_KEY = "sk-synthetic-openai-key"
