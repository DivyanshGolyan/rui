#!/usr/bin/env python3
"""Run TD1 against unchanged private renderer transitions in a disposable overlay.

Only test declarations are injected. No transition is replaced, no downloaded
artifact is used, and the supplied source (including a TD3 mutant) is not edited.
The model draws through the production drawFrame and consentReceipt, so
editor selection is tested rather than reimplemented by the fixture.
"""
import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import select
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import time

from host_process import dispose_all


SELECTORS = ("focus", "pages", "acknowledgement", "retention", "publication")
SCRATCH = {".git", ".zig-cache", "zig-out", ".amp", "__pycache__"}


def entry(path):
    mode = path.lstat().st_mode
    record = {"mode": stat.S_IMODE(mode)}
    if stat.S_ISLNK(mode):
        record.update(kind="link", target=str(path.readlink()))
        if path.exists():
            record["target_mode"] = stat.S_IMODE(path.stat().st_mode)
    elif stat.S_ISDIR(mode):
        record["kind"] = "directory"
    else:
        record["kind"] = "file" if stat.S_ISREG(mode) else "special"
    if path.is_file():
        record["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
    return record


def manifest(root):
    # Bind all source/test bytes and modes, plus root links and their file
    # targets. Native dependency directories are bound by link, not traversed.
    paths = [path for path in root.iterdir() if path.name not in SCRATCH]
    for name in ("src", "tests"):
        paths.extend(path for path in (root / name).rglob("*")
                     if not SCRATCH.intersection(path.relative_to(root).parts))
    return {str(path.relative_to(root)): entry(path) for path in sorted(paths)}


def identity(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def overwrites_inputs(path, source):
    path = path.resolve()
    return path == source or (path.is_relative_to(source) and
                              path.relative_to(source).parts[0] not in SCRATCH)


def unsafe_cache(cache, source):
    overlay = cache / "source"
    # Default compilation scratch below .zig-cache is allowed. No cache write
    # may overlap supplied inputs, including an equal/ancestor overlay root.
    if source.is_relative_to(overlay.resolve()):
        return f"cache overlaps supplied source: {overlay}"
    for path in (cache, overlay.resolve()):
        if overwrites_inputs(path, source):
            return f"cache writes supplied inputs: {path}"
    for path in (cache, overlay, overlay / "src", cache / "build"):
        if path.is_symlink() or (path.exists() and not path.is_dir()):
            return f"unsafe cache directory: {path}"
    lock = cache / "lock"
    paths = [lock] if lock.exists() or lock.is_symlink() else []
    paths.extend((overlay / "src").rglob("*"))
    for path in paths:
        mode = path.lstat().st_mode
        if stat.S_ISLNK(mode) or (not stat.S_ISDIR(mode) and
                                (not stat.S_ISREG(mode) or path.stat().st_nlink != 1)):
            return f"unsafe cache entry: {path}"
    return None


@contextmanager
def source_overlay(cache, source):
    # Stable source paths let Zig reuse compiled dependencies across selectors
    # and mutations. Concurrent invocations never share writable source custody.
    unsafe = unsafe_cache(cache, source)
    assert unsafe is None, unsafe
    with (cache / "lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        # Recheck under custody: a preceding invocation may have retired a
        # failed, aliased overlay between preflight and lock acquisition.
        unsafe = unsafe_cache(cache, source)
        assert unsafe is None, unsafe
        overlay = cache / "source"
        overlay.mkdir(exist_ok=True)
        yield overlay


@contextmanager
def retention_root(log):
    root = Path(tempfile.mkdtemp(prefix="td1-retention-"))
    outcome = {"exit": None}
    try:
        yield root, outcome
    finally:
        if outcome["exit"] == 0 and sys.exception() is None:
            shutil.rmtree(root)
        else:
            print(f"Retained TD1 fixture: {root}", file=log, flush=True)


def execute(command, overlay, log, retention, cache):
    environment = {**os.environ, "RUI_TEST_EXACT_INACTIVITY": "0"}
    if not retention:
        return subprocess.run(command, cwd=overlay, env=environment, stdout=log, stderr=subprocess.STDOUT).returncode
    # Use the existing real Host/provider fixture. The UI's first scan, not a
    # sleep, releases the held answer. No ReplyProxy/socket replacement is used.
    # Imported here: model_fixture reads its binary from this process's argv at import.
    import model_fixture as fixture
    fixture.RUI = overlay / "zig-out/bin/rui"
    build = subprocess.run(["zig", "build", "-j2", "--cache-dir", str(cache / "build")],
                           cwd=overlay, stdout=log, stderr=subprocess.STDOUT)
    if build.returncode:
        return build.returncode
    with retention_root(log) as (root, outcome):
        store, workspace = root / "store", root / "workspace"
        workspace.mkdir()
        release = threading.Event()
        # The queued Message shows collapsed, so the answer alone must outgrow
        # the live view for eviction to cut its echo.
        answer = "\n".join(f"ANSWER-{index:05d} " + "y" * 50 for index in range(4400))
        response = fixture.ResponseSpec(fixture.sse_answer("held", "reason", "message", answer)[0], {}, gate_timeout=600)
        endpoint = fixture.SuccessEndpoint([(response, release), fixture.sse_answer("next", "reason2", "message2", "TD1 DONE")[0]])
        thread = threading.Thread(target=endpoint.serve_forever)
        thread.start()
        host = process = None
        for name in ("ready", "release"):
            os.mkfifo(root / name, 0o600)
        # FIFO paths survive the build runner's descriptor hygiene. These two
        # parent ends prevent spurious EOF before the test opens its own ends.
        ready = os.open(root / "ready", os.O_RDWR | os.O_NONBLOCK)
        done = os.open(root / "release", os.O_RDWR | os.O_NONBLOCK)
        try:
            host = fixture.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses")
            configured = fixture.command("session", "configure", "--store", store, "--record", root / "configure.json", "--key", "configure", "--provider", "codex", "--model", "gpt-6-sol", "--workspace", workspace)
            assert configured["answer"]["status"] == "accepted", configured
            session = configured["answer"]["session"]
            for key, text in (("driver", "driver"), ("queued", "m" * 59199)):
                admitted = fixture.command("session", "send", "--store", store, "--to", session, "--record", root / f"{key}.json", "--key", key, input=text)
                assert admitted["answer"]["status"] == "accepted", admitted
                if key == "driver":
                    fixture.wait_for(lambda: len(endpoint.requests) == 1, "held provider request")
            environment.update(RUI_TD1_STORE=str(store), RUI_TD1_SESSION=session, RUI_TD1_GATE=str(root))
            process = subprocess.Popen(command, cwd=overlay, env=environment, stdout=log, stderr=subprocess.STDOUT)
            deadline = time.monotonic() + 600  # Includes first native compilation.
            while not select.select([ready], [], [], 0.1)[0]:
                if process.poll() is not None:
                    outcome["exit"] = process.returncode
                    return outcome["exit"]
                assert time.monotonic() < deadline, "TD1 first-scan handshake deadline"
            assert os.read(ready, 1) == b"x"
            release.set()
            fixture.wait_for(lambda: fixture.command("session", "inspect", "--store", store, "--session", session)["work"]["state"]["kind"] == "finished" and len(endpoint.requests) == 2,
                             "queued Message canonical completion", timeout=30)
            os.write(done, b"x")
            outcome["exit"] = process.wait(timeout=60)
            return outcome["exit"]
        finally:
            def retire():
                if process is not None and process.poll() is None:
                    process.kill()
                    process.wait(timeout=10)
            dispose_all(release.set, retire,
                        lambda: fixture.stop_host(host) if host is not None else None,
                        endpoint.shutdown, endpoint.server_close, lambda: thread.join(timeout=5),
                        lambda: os.close(ready), lambda: os.close(done))


def run(source, output, selector, cache):
    source = source.resolve()
    output = output.resolve()
    # Evidence is also a write owner. Refusal cannot write a receipt into an
    # unsafe output location; stderr is the only report in that case.
    assert not overwrites_inputs(output, source), "evidence output overlaps supplied inputs"
    for name in ("overlay-manifest.json", "receipt.json", "test.log", "terminal-report.log"):
        path = output / name
        if path.exists() or path.is_symlink():
            mode = path.lstat().st_mode
            assert stat.S_ISREG(mode) and path.stat().st_nlink == 1, f"unsafe evidence destination: {path}"
    output.mkdir(parents=True, exist_ok=True)
    frontend = source / "src/SessionFrontend.zig"
    original = frontend.read_text()
    # draw() is drawFrame() then the post-write consent observation,
    # consentReceipt(). The model drives the frame alone; its receipt event
    # is that observation.
    bridge = ""
    for name in SELECTORS:
        bridge += f'''
test "TD1 sequence model {name}" {{
    try @import("session_sequence_model_test.zig").run(Self, .{{
        .step = step, .draw = drawFrame, .navigation = navigation,
        .beginTranscript = beginTranscript, .settleReader = settleReader,
        .olderWanted = olderWanted,
        .showStaged = showStaged, .applyReader = applyReader,
        .presentAdmission = presentAdmission, .freeze = freeze,
        .receipt = consentReceipt, .showInspection = showInspection,
        .scan = reads.scan,
    }}, .{name});
}}
'''
    supplied = manifest(source)
    inputs = {path: record["sha256"] for path, record in supplied.items() if "sha256" in record}
    inputs["tests/integration/session_sequence_model.py"] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    # Expected authority comes from supplied inputs, NEVER cache/source. The
    # only transformed input is the frontend with these exact declarations.
    expected_overlay = dict(supplied)
    for path in source.iterdir():
        if path.name in SCRATCH or path.name == "src":
            continue
        expected_overlay[path.name] = {"kind": "link", "mode": 0o777, "target": str(path),
                                       "target_mode": stat.S_IMODE(path.stat().st_mode)}
        if path.is_file():
            expected_overlay[path.name]["sha256"] = supplied[path.name]["sha256"]
    expected_overlay["src/SessionFrontend.zig"] = {
        **supplied["src/SessionFrontend.zig"],
        "sha256": hashlib.sha256((original + bridge).encode()).hexdigest(),
    }
    (output / "overlay-manifest.json").write_text(json.dumps(expected_overlay, indent=2, sort_keys=True) + "\n")
    # Keep compilation scratch outside the review-artifact directory. The
    # shared cache contains compilation only; Zig's Run step executes afresh.
    cache = cache.resolve() if cache is not None else source / ".zig-cache/td1-model"
    unsafe = unsafe_cache(cache, source)
    if unsafe is not None:
        # Preserve refusal BEFORE root acquisition, copying or chmod. A failed
        # retained overlay is not authority to dereference a cached alias.
        receipt = {"source": str(source), "selector": selector, "inputs": inputs,
                   "exit": None, "direct_exit": None, "binary": None, "binary_sha256": None,
                   "source_unchanged": manifest(source) == supplied,
                   "overlay_unchanged": False, "failure": unsafe}
        (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
        raise AssertionError(unsafe)
    cache.mkdir(parents=True, exist_ok=True)
    with source_overlay(cache, source) as overlay:
        for path in source.iterdir():
            if path.name == "src" or path.name in SCRATCH:
                continue
            link = overlay / path.name
            if link.is_symlink() and link.readlink() != path:
                link.unlink()
            if not link.exists():
                link.symlink_to(path, target_is_directory=path.is_dir())
        # Preserve unchanged files' identity: Zig's native compilation cache
        # keys include filesystem identity, not just bytes. This bounded source
        # overlay is compilation scratch, not cached test acceptance.
        expected = set()
        for path in (source / "src").rglob("*"):
            if not path.is_file():
                continue
            target = overlay / path.relative_to(source)
            expected.add(target)
            target.parent.mkdir(parents=True, exist_ok=True)
            data = (original + bridge).encode() if path == frontend else path.read_bytes()
            if not target.exists() or target.read_bytes() != data:
                target.write_bytes(data)
            mode = stat.S_IMODE(path.stat().st_mode)
            if stat.S_IMODE(target.stat().st_mode) != mode:
                target.chmod(mode)
        for path in (overlay / "src").rglob("*"):
            if path.is_file() and path not in expected:
                path.unlink()
        command = ["zig", "build", "test", "-j2", "--cache-dir", str(cache / "build"),
                   "-Dtest-filter=TD1 sequence model" + ("" if selector == "all" else " " + selector),
                   "--summary", "all", "--verbose"]
        print("Running:", " ".join(command), flush=True)
        observations = {}
        differences = {}

        def observe(phase):
            actual = manifest(overlay)
            observations[phase] = identity(actual)
            differences[phase] = sorted(path for path in actual.keys() | expected_overlay.keys()
                                        if actual.get(path) != expected_overlay.get(path))
            return not differences[phase]

        result = direct = binary = binary_digest = None
        with (output / "test.log").open("w") as log:
            if observe("before_build"):
                result = execute(command, overlay, log, selector in ("all", "retention"), cache)
            observe("after_build")
        report = (output / "test.log").read_text()
        # An abnormal build is not an assertion failure and must not launch a
        # binary, even when its verbose log contains a discoverable path.
        if result in (0, 1) and not any(differences.values()):
            binaries = set(re.findall(r"(?m)^info\(verbose\): [^\n]*?(/[^\s\"]+/test) --cache-dir=", report))
            if len(binaries) == 1 and observe("before_direct"):
                binary = Path(binaries.pop())
                binary_digest = hashlib.sha256(binary.read_bytes()).hexdigest()
                # SAME artifact; diagnostic replay never substitutes for the
                # build result. Zig's protocol can omit assertion error types.
                with (output / "terminal-report.log").open("w") as log:
                    direct = execute([str(binary)], overlay, log, selector in ("all", "retention"), cache)
                observe("after_direct")
                report += (output / "terminal-report.log").read_text()
        unchanged = manifest(source) == supplied
        unchanged = unchanged and hashlib.sha256(Path(__file__).read_bytes()).hexdigest() == inputs["tests/integration/session_sequence_model.py"]
        overlay_unchanged = len(observations) == 4 and not any(differences.values())
        receipt = {"source": str(source), "selector": selector, "inputs": inputs,
                   "bridge_sha256": hashlib.sha256(bridge.encode()).hexdigest(),
                   "exit": result, "direct_exit": direct, "binary_sha256": binary_digest,
                   "binary": str(binary) if binary is not None else None,
                   "assertions": re.findall(r"FAIL \(([^)]+)\)", report),
                   "source_unchanged": unchanged, "overlay_unchanged": overlay_unchanged,
                   "overlay": {"expected_sha256": identity(expected_overlay),
                               "observations": observations, "differences": differences}}
        (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
        print(report, end="")
        assert unchanged, "source changed during model execution; evidence invalid"
        assert not any(differences.values()), "executed overlay changed; evidence invalid"
        assert result in (0, 1), f"abnormal build status {result}; direct replay prohibited"
        assert direct is not None, "emitted narrow test executable missing from verbose build output"
        assert overlay_unchanged, "executed overlay checks incomplete; evidence invalid"
        assert (result == 0) == (direct == 0), "build/direct outcomes disagree"
        required = SELECTORS if selector == "all" else (selector,)
        if result == 0:
            for name in required:
                assert f"test.TD1 sequence model {name}...OK" in report, "named model test did not execute"
        return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--cache", type=Path, help="Compilation-only cache parent; serial overlay lock, never test acceptance reuse")
    parser.add_argument("--selector", choices=("all", *SELECTORS), default="all")
    args = parser.parse_args()
    raise SystemExit(run(args.source, args.output.resolve(), args.selector, args.cache))
