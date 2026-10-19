#!/usr/bin/env python3
"""Hosted macOS renderer matrix: the approved verify-rui rows, fanned out.

Runs the pinned helper and probe bits unchanged. Each row process gets its own
layout root, synthetic HOME and Store (the helper creates them), so rows that
share a VM share no files, sockets or tmux servers. Verdicts are the helper's
and probes' own; this driver only refuses outcomes outside the approved
inventory (new N/A or UNAVAILABLE rows, missing rows or nonzero exits).
"""
import argparse
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys
import threading
import time

HERE = pathlib.Path(__file__).resolve().parent
# Exact approved bits: helper 012861d0 carries the TMUX/TMUX_PANE inheritance
# fix; the probes and trace wrappers are the 52ee5d4a diagnostic drivers.
PINS = {
    "verify-rui": "012861d052ff62aa02581b66ccbdd8fe696ff23f9cd3f6a0738f6cae3d0b0898",
    "prefix-chain-probe.py": "431ca8ac97a516154e7361f92595729b932308063d4ca2ee62e0ece24effa248",
    "meta-origin-probe.py": "d25130bbb1d453e8191ab760dcfd2c14c04efac26d979d1fa262ac87d1417ae9",
    "meta-fixed-probe.py": "6f65331b6ebb5726c1bc6c9e2afd577546e9e47596f104535cd39e7b3b8f1231",
    "meta-drop-probe.py": "612873d410e257f0ae40b2ac2225f7df6488ef868377360139b24043e43a21ab",
    "meta-drop-probe.real-tmux-environment.py": "91f020c11726d26c8c88c7d845382bf6c7b3a19de6a8e229a8227dd60c1d7de5",
    "tmux-environment-control.py": "9481f360159546c30c7162974efdafc902e5ca6654b8b7e81aaa8732759ba480",
    "native-human-with-traces.py": "b725670b7198b5bf61f2a576bb6667a2628a5fa605156590e3182b624a2bac41",
    "native-restoration-with-traces.py": "f198aedf60535d9f5a9e00f1e4704b44f139bbd90ce422a6cb76913dcdb4a315",
}
# The probes locate the helper, cache and venv relative to this layout.
HELPER = pathlib.Path(".cursor/skills/verify-rui/scripts/verify-rui")
PROBES = pathlib.Path(".amp/in/artifacts/takeover-20261018")
CACHE = pathlib.Path(".amp/in/prefix-diagnosis-cache")
# Pre-existing attached-client input reports (52ee5d4a baseline). Any other
# N/A is a new outcome to diagnose, never an accepted relabel.
QUALIFY = {
    "pty": (35, set()),
    "tmux-detached": (35, set()),
    "tmux-attached": (28, {"key-up-ss3", "key-end-csi-f", "key-end-ss3-f", "mouse-sgr-wheel",
                           "mouse-x10-wheel", "mouse-x10-split", "focus-reports"}),
}
# Three attached-client translations may be UNAVAILABLE only with the probe's
# own outer/inner byte proof; direct-pane rows must pass.
MODIFIER = {
    "tmux-detached": (41, set()),
    "tmux-attached": (64, {"kitty-hyper-dot", "kitty-meta-dot", "bound-shift-enter"}),
}
NATIVE = (
    ("renderer", "native-human-with-traces.py"),
    ("persistent-opening", "native-human-with-traces.py"),
    ("persistent-permission", "native-human-with-traces.py"),
    ("visible-stream", "native-restoration-with-traces.py"),
    ("commands", "native-restoration-with-traces.py"),
)


def digest(path):
    with open(path, "rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def verify_bundle():
    actual = {name: digest(HERE / name) for name in PINS}
    wrong = {name: value for name, value in actual.items() if value != PINS[name]}
    if wrong:
        raise SystemExit(f"Renderer matrix bundle differs from the approved bits: {wrong}")


def layout(root, cache, venv):
    """One private root per row process, the probes' expected relative layout."""
    (root / HELPER).parent.mkdir(parents=True)
    shutil.copy2(HERE / "verify-rui", root / HELPER)
    (root / PROBES).mkdir(parents=True)
    for name in PINS:
        if name.endswith(".py"):
            shutil.copy2(HERE / name, root / PROBES / name)
    (root / CACHE).mkdir(parents=True)
    (root / CACHE / "builds").symlink_to(cache / "builds")
    (root / CACHE / "venv").symlink_to(venv)
    return root


class Load:
    """Load-average samples, so shared-VM rows can show they were not CPU-starved."""

    def __init__(self, path):
        self.path, self.stop = path, threading.Event()
        self.thread = threading.Thread(target=self.sample, daemon=True)
        self.thread.start()

    def sample(self):
        with open(self.path, "a") as output:
            while not self.stop.is_set():
                value = subprocess.run(["sysctl", "-n", "vm.loadavg"], capture_output=True, text=True).stdout.strip()
                output.write(json.dumps({"t": time.time(), "loadavg": value}) + "\n")
                output.flush()
                self.stop.wait(5)

    def close(self):
        self.stop.set()
        self.thread.join()


def launch(rows, out, serial):
    """Start every row with its own log; return (name, exit, seconds) per row."""
    results = {}

    def start(name, argv, env):
        log = open(out / f"{name}.log", "wb")
        started = time.monotonic()
        process = subprocess.Popen(argv, stdout=log, stderr=subprocess.STDOUT, env=env, start_new_session=True)
        return process, log, started

    def finish(name, process, log, started):
        code = process.wait()
        log.close()
        results[name] = {"exit": code, "seconds": round(time.monotonic() - started, 1)}
        print(f"{name}: exit={code} {results[name]['seconds']}s", flush=True)

    if serial:
        for name, argv, env in rows:
            finish(name, *start(name, argv, env))
    else:
        running = [(name, *start(name, argv, env)) for name, argv, env in rows]
        for item in running:
            finish(*item)
    return results


def retain(out):
    """Copy row evidence out of the hidden layout trees so the artifact keeps it.

    Regular files only: the layout's builds/venv symlinks and the helper's
    terminal FIFOs stay behind (opening a FIFO would block).
    """
    for root in sorted(out.glob("root-*")):
        for tree in (root / CACHE / "qualify", *sorted((root / PROBES).glob("*/"))):
            if not tree.is_dir() or tree.is_symlink():
                continue
            for path in tree.rglob("*"):
                if path.is_file() and not path.is_symlink():
                    target = out / "evidence" / root.name / tree.name / path.relative_to(tree)
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(path, target)


def last_json(path):
    for line in reversed(path.read_text(errors="replace").splitlines()):
        if line.startswith("{"):
            try:
                return json.loads(line)
            except json.JSONDecodeError:
                continue
    return None


def terminal(args):
    verify_bundle()
    out, cache, venv = map(pathlib.Path, (args.out, args.cache, args.venv))
    out.mkdir(parents=True)
    python = str(venv / "bin/python")
    rows = []
    for surface in QUALIFY:
        root = layout(out / f"root-qualify-{surface}", cache, venv)
        env = {**os.environ, "VERIFY_RUI_CACHE": str(root / CACHE)}
        rows.append((f"qualify-{surface}", [python, str(root / HELPER), "qualify", args.sha, "--surfaces", surface], env))
    for surface in MODIFIER:
        root = layout(out / f"root-modifier-{surface}", cache, venv)
        rows.append((f"modifier-{surface}", [python, str(root / PROBES / "meta-drop-probe.real-tmux-environment.py"),
                                             "--sha", args.sha, "--surface", surface], dict(os.environ)))
    root = layout(out / "root-tmux-environment", cache, venv)
    rows.append(("tmux-environment", [python, str(root / PROBES / "tmux-environment-control.py"),
                                      "--sha", args.sha, "--label", "green-corrected-helper"], dict(os.environ)))
    load = Load(out / "load.jsonl")
    try:
        results = launch(rows, out, args.serial)
    finally:
        load.close()
        retain(out)
    issues = []
    for surface, (passes, unavailable) in QUALIFY.items():
        name = f"qualify-{surface}"
        summaries = sorted((out / f"root-{name}" / CACHE / "qualify").glob("*/summary.json"))
        summary = json.loads(summaries[-1].read_text()) if summaries else {}
        state = summary.get("surfaces", {}).get(surface, {})
        results[name].update(verdict=summary.get("verdict"), passed=state.get("pass"),
                             not_applicable=state.get("not_applicable"), issues=state.get("issues"))
        expected_exit = 3 if unavailable else 0
        if (results[name]["exit"] != expected_exit or not state.get("complete") or state.get("issues")
                or state.get("pass") != passes or set(state.get("not_applicable") or ()) != unavailable):
            issues.append(f"{name}: {results[name]}")
    for surface, (count, unavailable) in MODIFIER.items():
        name = f"modifier-{surface}"
        files = sorted((out / f"root-{name}" / PROBES / "meta-drop-real-tmux-environment").glob("*/summary.json"))
        summary = json.loads(files[-1].read_text()) if files else {}
        found = [row for s in summary.get("surfaces", []) for row in s.get("rows", [])]
        marked = {row["case"] for row in found if row.get("unavailable")}
        results[name].update(verdict=summary.get("verdict"), rows=len(found), unavailable=sorted(marked),
                             passed=sum(1 for row in found if row["passed"]))
        if (results[name]["exit"] != 0 or len(found) != count or marked != unavailable
                or any(not row["passed"] and not row.get("unavailable") for row in found)):
            issues.append(f"{name}: {results[name]}")
        # Super is evidence only as the delivered Alt sequence, never as Super.
        if surface == "tmux-attached":
            supers = [row for row in found if row["case"] == "kitty-super-dot" and row["via"] == "client"]
            results[name]["super_client_delivered_hex"] = [row.get("delivered_hex") for row in supers]
            if not supers or not all(row["passed"] for row in supers):
                issues.append(f"{name}: attached Super row missing or failed")
    control = out / "root-tmux-environment" / PROBES / "tmux-environment-green-corrected-helper" / "summary.json"
    rows_seen = json.loads(control.read_text())["rows"] if control.exists() else []
    results["tmux-environment"].update(rows=len(rows_seen), passed=sum(1 for row in rows_seen if row["passed"]))
    if results["tmux-environment"]["exit"] != 0 or len(rows_seen) != 5 or not all(row["passed"] for row in rows_seen):
        issues.append(f"tmux-environment: {results['tmux-environment']}")
    return report(out, args, results, issues)


def native(args):
    verify_bundle()
    out, cache, venv = map(pathlib.Path, (args.out, args.cache, args.venv))
    out.mkdir(parents=True)
    manifest = json.loads((cache / "builds" / args.sha / "manifest.json").read_text())
    source, binary = manifest["source"], manifest["binary"]
    rows = [(f"native-{selector}", [str(venv / "bin/python"), str(HERE / script), source, binary,
                                     str(out / f"native-{selector}"), selector], dict(os.environ))
            for selector, script in NATIVE]
    load = Load(out / "load.jsonl")
    try:
        results = launch(rows, out, args.serial)
    finally:
        load.close()
    issues = []
    for selector, _ in NATIVE:
        name = f"native-{selector}"
        trace = out / name / "trace-summary.json"
        summary = json.loads(trace.read_text()) if trace.exists() else {}
        results[name].update(completed=summary.get("completed"), ptys=summary.get("ptys"),
                             binary_sha256=summary.get("binary_sha256"))
        if results[name]["exit"] != 0 or summary.get("completed") is not True \
                or summary.get("binary_sha256") != manifest["files_sha256"]["rui"]:
            issues.append(f"{name}: {results[name]}")
    return report(out, args, results, issues)


def report(out, args, results, issues):
    summary = {"sha": args.sha, "mode": "serial" if args.serial else "parallel", "rows": results,
               "issues": issues, "verdict": "ISSUES" if issues else "PASS",
               "physical_input": "UNVERIFIED: injected bytes only; physical keyboard, wheel and trackpad remain local checks"}
    (out / "matrix-summary.json").write_text(json.dumps(summary, indent=1))
    print(json.dumps(summary, indent=1))
    return 1 if issues else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("verify-bundle")
    for name in ("terminal", "native"):
        p = sub.add_parser(name)
        p.add_argument("sha")
        p.add_argument("--out", required=True)
        p.add_argument("--cache", required=True, help="verify-rui cache holding builds/SHA")
        p.add_argument("--venv", required=True)
        p.add_argument("--serial", action="store_true", help="run rows one at a time (load control)")
    args = parser.parse_args()
    if args.command == "verify-bundle":
        verify_bundle()
        return 0
    return terminal(args) if args.command == "terminal" else native(args)


if __name__ == "__main__":
    sys.exit(main())
