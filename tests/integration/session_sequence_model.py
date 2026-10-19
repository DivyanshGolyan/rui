#!/usr/bin/env python3
"""Run TD1 against unchanged private renderer transitions in a disposable overlay.

Only test declarations are injected. No transition is replaced, no downloaded
artifact is used, and the supplied source (including a TD3 mutant) is not edited.
The draw adapter is extracted from the production redraw block, so editor
selection is tested rather than reimplemented by the fixture.
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
import subprocess
import tempfile
import threading
import time


SELECTORS = ("focus", "pages", "acknowledgement", "retention", "publication")


@contextmanager
def source_overlay(cache):
    # Stable source paths let Zig reuse compiled dependencies across selectors
    # and mutations. Concurrent invocations never share writable source custody.
    with (cache / "lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        overlay = cache / "source"
        overlay.mkdir(exist_ok=True)
        yield overlay


def unique_slice(text, start, stop):
    assert text.count(start) == text.count(stop) == 1, "renderer adapter anchors changed"
    return text[text.index(start):text.index(stop)]


def execute(command, overlay, log, retention, cache):
    environment = {**os.environ, "RUI_TEST_EXACT_INACTIVITY": "0"}
    if not retention:
        return subprocess.run(command, cwd=overlay, env=environment, stdout=log, stderr=subprocess.STDOUT).returncode
    # Use the existing real Host/provider fixture. The UI's first scan, not a
    # sleep, releases the held answer. No ReplyProxy/socket replacement is used.
    import model_fixture as fixture
    from host_process import dispose_all

    fixture.RUI = overlay / "zig-out/bin/rui"
    build = subprocess.run(["zig", "build", "-j2", "--cache-dir", str(cache / "build")],
                           cwd=overlay, stdout=log, stderr=subprocess.STDOUT)
    if build.returncode:
        return build.returncode
    with tempfile.TemporaryDirectory(prefix="td1-retention-") as temporary:
        root = Path(temporary)
        store, workspace = root / "store", root / "workspace"
        workspace.mkdir()
        release = threading.Event()
        answer = "\n".join(f"ANSWER-{index:05d} " + "y" * 50 for index in range(3700))
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
            configured = fixture.command("session", "configure", "--store", store, "--session", "model", "--record", root / "configure.json", "--key", "configure", "--provider", "codex", "--model", "model-a", "--workspace", workspace)
            assert configured["answer"]["status"] == "accepted", configured
            for key, text in (("driver", "driver"), ("queued", "m" * 59199)):
                text_path = root / f"{key}.txt"
                text_path.write_text(text)
                admitted = fixture.command("session", "send", "--store", store, "--session", "model", "--record", root / f"{key}.json", "--key", key, "--text", text_path)
                assert admitted["answer"]["status"] == "accepted", admitted
                if key == "driver":
                    fixture.wait_for(lambda: len(endpoint.requests) == 1, "held provider request")
            environment.update(RUI_TD1_STORE=str(store), RUI_TD1_GATE=str(root))
            process = subprocess.Popen(command, cwd=overlay, env=environment, stdout=log, stderr=subprocess.STDOUT)
            deadline = time.monotonic() + 600  # Includes first native compilation.
            while not select.select([ready], [], [], 0.1)[0]:
                if process.poll() is not None:
                    return process.returncode
                assert time.monotonic() < deadline, "TD1 first-scan handshake deadline"
            assert os.read(ready, 1) == b"x"
            release.set()
            fixture.wait_for(lambda: fixture.command("session", "inspect", "--store", store, "--session", "model")["work"]["status"] == "completed" and len(endpoint.requests) == 2,
                             "queued Message canonical completion", timeout=30)
            os.write(done, b"x")
            return process.wait(timeout=60)
        finally:
            def retire():
                if process is not None and process.poll() is None:
                    process.kill()
                    process.wait(timeout=10)
            dispose_all(release.set, retire,
                        lambda: fixture.stop_host(host) if host is not None else None,
                        endpoint.shutdown, endpoint.server_close, lambda: thread.join(timeout=5),
                        lambda: os.close(ready), lambda: os.close(done))


def run(source, output, selector):
    source = source.resolve()
    output.mkdir(parents=True, exist_ok=True)
    frontend = source / "src/SessionFrontend.zig"
    original = frontend.read_text()
    drawing = unique_slice(original, "            const action_visible = self.actionVisible();",
                           "            if (!approval_ready and self.approvalReady()) {")
    bridge = "\nfn td1Draw(self: *Self) !void {\nconst screen = self.terminal.screen;\n" + drawing + "\n}\n"
    receipts = re.findall(r"if \((self\.consent\.promptCompleted\(service, [^\n]+\))\) \{", original)
    assert len(receipts) == 1, "post-write consent adapter anchor changed"
    bridge += "\nfn td1Receipt(self: *Self, service: ConsentPolicy.Service) bool { return " + receipts[0] + "; }\n"
    for name in SELECTORS:
        bridge += f'''
test "TD1 sequence model {name}" {{
    try @import("session_sequence_model_test.zig").run(Self, .{{
        .step = step, .draw = td1Draw, .navigation = navigation,
        .beginTranscript = beginTranscript, .settleReader = settleReader,
        .olderWanted = olderWanted,
        .showStaged = showStaged, .applyReader = applyReader,
        .presentAdmission = presentAdmission, .freeze = freeze,
        .receipt = td1Receipt, .showInspection = showInspection,
        .scan = reads.scan,
    }}, .{name});
}}
'''
    inputs = {str(path.relative_to(source)): hashlib.sha256(path.read_bytes()).hexdigest()
              for path in sorted((source / "src").glob("*.zig"))}
    inputs["tests/integration/session_sequence_model.py"] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    # Keep compilation scratch outside the review-artifact directory. The
    # shared cache contains compilation only; Zig's Run step executes afresh.
    cache = source / ".zig-cache/td1-model"
    cache.mkdir(parents=True, exist_ok=True)
    with source_overlay(cache) as overlay:
        for path in source.iterdir():
            if path.name in ("src", ".git", ".zig-cache", "zig-out", ".amp"):
                continue
            link = overlay / path.name
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
        for path in (overlay / "src").rglob("*"):
            if path.is_file() and path not in expected:
                path.unlink()
        command = ["zig", "build", "test", "-j2", "--cache-dir", str(cache / "build"),
                   "-Dtest-filter=TD1 sequence model" + ("" if selector == "all" else " " + selector),
                   "--summary", "all", "--verbose"]
        print("Running:", " ".join(command), flush=True)
        with (output / "test.log").open("w") as log:
            result = execute(command, overlay, log, selector in ("all", "retention"), cache)
        report = (output / "test.log").read_text()
        binaries = set(re.findall(r"(?m)^info\(verbose\): [^\n]*?(/[^\s\"]+/test) --cache-dir=", report))
        binary_digest = None
        direct = None
        if len(binaries) == 1:
            binary = Path(binaries.pop())
            binary_digest = hashlib.sha256(binary.read_bytes()).hexdigest()
            # Diagnostic execution of the SAME narrow artifact, not a retry
            # accepted in place of a failed gate. Zig 0.17's build protocol can
            # omit returned errors; direct mode retains named OK/FAIL records.
            with (output / "terminal-report.log").open("w") as log:
                direct = execute([str(binary)], overlay, log, selector in ("all", "retention"), cache)
            report += (output / "terminal-report.log").read_text()
        unchanged = all(hashlib.sha256((source / path).read_bytes()).hexdigest() == digest
                        for path, digest in inputs.items() if path != "tests/integration/session_sequence_model.py")
        receipt = {"source": str(source), "selector": selector, "inputs": inputs,
                   "bridge_sha256": hashlib.sha256(bridge.encode()).hexdigest(),
                   "exit": result, "direct_exit": direct, "binary_sha256": binary_digest,
                   "assertions": re.findall(r"FAIL \(([^)]+)\)", report),
                   "source_unchanged": unchanged}
        (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
        print(report, end="")
        assert unchanged, "source changed during model execution; evidence invalid"
        assert direct is not None, "emitted narrow test executable missing from verbose build output"
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
    parser.add_argument("--selector", choices=("all", *SELECTORS), default="all")
    args = parser.parse_args()
    raise SystemExit(run(args.source, args.output.resolve(), args.selector))
