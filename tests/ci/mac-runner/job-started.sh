#!/bin/bash
# Installed with its allowlist in a root-owned directory below a root-owned home.
set -euo pipefail
# Runner-only entrypoint: a rejected manual invocation kills its calling process.
# actions/runner v2.338.2 ScriptHandler -> DefaultStepHost -> ProcessInvoker
# starts this Bash directly under Runner.Worker. A mere failed step still permits
# always()/failure() steps, so terminate that worker before returning a refusal.
refuse_worker() {
    local result=$?
    if [[ $result != 0 ]]; then
        printf '%s\n' 'Mac runner hook failed; terminating the job worker before any job steps.' >&2
        kill -KILL "$PPID"
    fi
}
trap refuse_worker EXIT
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
policy_dir=$(cd -- "$(dirname -- "$0")" && pwd -P)
python3 -I -S - "$policy_dir/allowlist" <<'PY'
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys

# Read the exact root-owned source: never resolve packages or cached bytecode,
# including leftovers in an installation being adopted or repaired.
policy_path = Path(sys.argv[1]).with_name("mac_runner.py")
policy = {"__name__": "installed_mac_runner", "__file__": str(policy_path)}
exec(compile(policy_path.read_bytes(), str(policy_path), "exec"), policy)
admission = policy["admission"]


def reject(message):
    raise ValueError(message)


def object_without_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            reject("duplicate event key")
        result[key] = value
    return result


def login(value):
    if not isinstance(value, str) or not value:
        reject("missing login")
    return value


try:
    expected = "DivyanshGolyan/rui"
    allowed = {login(line.strip()) for line in Path(sys.argv[1]).read_text().splitlines() if line.strip()}
    if not allowed:
        reject("empty allowlist")
    if os.environ.get("GITHUB_REPOSITORY") != expected:
        reject("wrong repository")
    event_name = os.environ.get("GITHUB_EVENT_NAME")
    actor = os.environ.get("GITHUB_ACTOR")
    triggering_actor = os.environ.get("GITHUB_TRIGGERING_ACTOR")
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text(),
                       object_pairs_hook=object_without_duplicates)
    if event["repository"]["full_name"] != expected:
        reject("wrong event repository")
    if login(event["sender"]["login"]) != actor:
        reject("event sender differs from actor")
    if event_name == "pull_request" and event["pull_request"]["base"]["repo"]["full_name"] != expected:
        reject("wrong pull request base")
    admitted, reason = admission(event_name, event, actor, triggering_actor, expected, allowed)
    if not admitted:
        reject(reason)
    # Admission comes first: rejected work must not mutate even the build cache.
    cache_root = Path.home() / ".cache"
    if cache_root.is_symlink():
        reject("cache parent is a symlink")
    cache = cache_root / "zig"
    if cache.exists() and not cache.is_symlink():
        if not stat.S_ISDIR(cache.stat().st_mode):
            reject("Zig cache is not a directory")
        size = subprocess.run(["/usr/bin/du", "-sk", str(cache)], check=True,
                              capture_output=True, text=True)
        if int(size.stdout.split()[0]) > 40 * 1024 * 1024:
            shutil.rmtree(cache)
            print("Removed Zig cache larger than 40 GiB", flush=True)
    print("Mac runner job admitted", flush=True)
except (KeyError, ValueError, TypeError, OSError, subprocess.SubprocessError) as error:
    print(f"Mac runner job refused: {error}", file=sys.stderr, flush=True)
    raise SystemExit(1)
PY
