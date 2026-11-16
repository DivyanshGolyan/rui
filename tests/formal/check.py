"""Model-check Rui's TLA+ models with a pinned TLC.

    python3 tests/formal/check.py            # every model, expected results
    python3 tests/formal/check.py --trace    # also print each violation's path

Each check names a model, a config and the invariants that must hold. A
known finding is an invariant the current design breaks: the check passes
only while it still breaks, so a fix shows up as a failure asking to move
the invariant into the holding list. Each mutation flips one Break switch,
which removes one guard the code has, and must make a named invariant fail:
a rule never seen failing proves nothing.

TLC comes from the release below, verified by its SHA-256, cached under
$XDG_CACHE_HOME/rui (or ~/.cache/rui). Set TLA2TOOLS to use a local jar and
JAVA to pick a Java 11+ binary.
"""
import argparse
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import urllib.request

TLC_VERSION = "1.7.4"
TLC_URL = f"https://github.com/tlaplus/tlaplus/releases/download/v{TLC_VERSION}/tla2tools.jar"
TLC_SHA256 = "936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88"
HERE = Path(__file__).resolve().parent

OWNERSHIP = HERE / "mysql_ownership" / "MysqlOwnership.tla"
SAFETY = ("TypeOK", "SavedOnce", "SavedMeansSaved", "OnlyLatestOwnerWrites")

# (name, spec, config, invariants that hold, known findings)
CHECKS = (
    ("mysql ownership, exact lock", OWNERSHIP, "ExactLock.cfg",
     SAFETY + ("NotSavedMeansNotSaved", "RerunOnlyUnsaved"), ()),
    # The contract says GET_LOCK only refuses early; the epoch fence owns
    # the Store. Safety holds without the lock. Reclaim's "nothing landed"
    # does not: it reads commit_seq as final once it holds the lock.
    ("mysql ownership, advisory lock", OWNERSHIP, "AdvisoryLock.cfg",
     SAFETY, ("RerunOnlyUnsaved",)),
)

# (switch, config, invariant that must break)
MUTATIONS = (
    ("BreakFenceEpoch", "AdvisoryLock.cfg", "OnlyLatestOwnerWrites"),
    ("BreakLockWait", "ExactLock.cfg", "RerunOnlyUnsaved"),
    ("BreakSettleEpoch", "ExactLock.cfg", "SavedMeansSaved"),
)


def tla2tools():
    if os.environ.get("TLA2TOOLS"):
        return Path(os.environ["TLA2TOOLS"])
    cache = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "rui"
    jar = cache / f"tla2tools-{TLC_VERSION}.jar"
    if jar.exists() and hashlib.sha256(jar.read_bytes()).hexdigest() == TLC_SHA256:
        return jar
    cache.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(TLC_URL, timeout=60) as response:
        data = response.read()
    digest = hashlib.sha256(data).hexdigest()
    if digest != TLC_SHA256:
        raise RuntimeError(f"{TLC_URL} has SHA-256 {digest}, expected {TLC_SHA256}")
    partial = jar.with_suffix(".partial")
    partial.write_bytes(data)
    partial.replace(jar)
    return jar


def config_text(spec, config, invariants, switch=None):
    text = (spec.parent / config).read_text()
    head = text.split("INVARIANTS")[0]
    if switch:
        head, count = re.subn(rf"\b{switch} = FALSE\b", f"{switch} = TRUE", head)
        if count != 1:
            raise ValueError(f"{config} has no '{switch} = FALSE'")
    return head + "INVARIANTS\n" + "".join(f"    {name}\n" for name in invariants)


def run(spec, config, invariants, switch=None):
    """TLC's verdict: (None, output) when every invariant holds, else (name, output)."""
    with tempfile.TemporaryDirectory() as scratch:
        # TLC reads the config beside the spec, so both are copied in.
        (Path(scratch) / spec.name).write_text(spec.read_text())
        (Path(scratch) / f"{spec.stem}.cfg").write_text(config_text(spec, config, invariants, switch))
        result = subprocess.run(
            [os.environ.get("JAVA", "java"), "-XX:+UseParallelGC", "-cp", str(tla2tools()), "tlc2.TLC",
             "-workers", "1", "-cleanup", "-metadir", str(Path(scratch) / "states"),
             spec.name],
            capture_output=True, text=True, cwd=scratch, timeout=600)
    output = result.stdout + result.stderr
    broken = re.search(r"Invariant (\w+) is violated", output)
    if broken:
        return broken.group(1), output
    if "Deadlock reached" in output:
        return "NoDeadlock", output
    if result.returncode != 0 or "Model checking completed. No error has been found." not in output:
        raise RuntimeError(f"TLC failed on {spec.name} with {config}:\n{output}")
    return None, output


def path_of(output):
    """The violating behaviour as numbered action names."""
    return [f"{n}. {action}" for n, action in re.findall(r"^State (\d+): <(\w+)", output, re.M)]


def failures(trace=False):
    found = []
    for name, spec, config, holding, known in CHECKS:
        broken, output = run(spec, config, holding)
        if broken:
            found.append(f"{name}: {broken} breaks:\n  " + "\n  ".join(path_of(output)))
        for invariant in known:
            broken, output = run(spec, config, (invariant,))
            if broken is None:
                found.append(f"{name}: known finding {invariant} now holds; move it to the holding list")
            elif trace:
                print(f"{name}: known finding {invariant}:\n  " + "\n  ".join(path_of(output)))
    for switch, config, expected in MUTATIONS:
        holding = next(h for _, spec, c, h, _ in CHECKS if c == config)
        broken, _ = run(OWNERSHIP, config, holding, switch)
        if broken != expected:
            found.append(f"{switch} on {config}: expected {expected} to break, got {broken or 'no violation'}")
    return found


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--trace", action="store_true", help="print each known finding's path")
    found = failures(parser.parse_args().trace)
    for line in found:
        print(line, file=sys.stderr)
    if not found:
        print(f"{len(CHECKS)} models hold their rules, findings unchanged, {len(MUTATIONS)} mutations caught")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
