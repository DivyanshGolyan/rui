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
import pwd
import shutil
import stat
import subprocess
import sys

# Read the exact root-owned source: never resolve packages or cached bytecode,
# including leftovers in an installation being adopted or repaired.
policy_path = Path(sys.argv[1]).with_name("mac_runner.py")
policy = {"__name__": "installed_mac_runner", "__file__": str(policy_path)}
exec(compile(policy_path.read_bytes(), str(policy_path), "exec"), policy)
runner_user = policy["RUNNER_USER"]
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


def warn(message):
    print(f"::warning::Mac runner cleanup: {message}", flush=True)


def clear_leftovers():
    """One job runs at a time, so every other process of this user and every
    TMPDIR entry is left by an earlier job. A hosted VM discards both; here a
    leftover `rui host serve` is discovered by later Host-discovery tests.
    Only the dedicated runner account may clear its own processes."""
    if pwd.getpwuid(os.getuid()).pw_name != runner_user:
        return
    try:
        listing = subprocess.run(["/bin/ps", "-x", "-u", str(os.getuid()), "-o", "pid=,ppid="],
                                 check=True, capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError) as error:
        warn(f"process list unavailable: {error}")
    else:
        parent = {}
        for line in listing.stdout.splitlines():
            fields = line.split()
            if len(fields) == 2 and all(field.isdigit() for field in fields):
                parent[int(fields[0])] = int(fields[1])
        # Keep this hook and the runner processes that started it.
        keep = set()
        pid = os.getpid()
        while pid > 1 and pid not in keep:
            keep.add(pid)
            pid = parent.get(pid, os.getppid() if pid == os.getpid() else 0)
        stopped = 0
        for pid in parent:
            if pid in keep or pid <= 1:
                continue
            try:
                os.kill(pid, 9)
                stopped += 1
            except ProcessLookupError:
                pass
            except OSError as error:
                warn(f"cannot stop process {pid}: {error}")
        if stopped:
            print(f"Stopped {stopped} leftover processes", flush=True)
    temp = Path.home() / "tmp"
    if temp.is_dir() and not temp.is_symlink():
        for entry in temp.iterdir():
            try:
                if entry.is_dir() and not entry.is_symlink():
                    # Tests leave read-only directories; open them first (Python 3.11 has no onexc).
                    entry.chmod(0o700)
                    for root, directories, _files in os.walk(entry):
                        for name in directories:
                            path = os.path.join(root, name)
                            if not os.path.islink(path):
                                os.chmod(path, 0o700)
                    shutil.rmtree(entry)
                else:
                    entry.unlink()
            except OSError as error:
                warn(f"cannot remove {entry}: {error}")


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
    clear_leftovers()
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
