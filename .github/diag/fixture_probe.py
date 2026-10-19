"""Reproduce the pinned helper's `_fixture` launch outside the helper and record where it stalls."""
import json, os, pathlib, signal, socket, subprocess, sys, time

helper, source, out = map(pathlib.Path, sys.argv[1:4])
out.mkdir(parents=True, exist_ok=True)


def t(label, fn):
    started = time.monotonic()
    try:
        value = fn()
    except Exception as error:
        value = repr(error)
    print(f"{time.strftime('%H:%M:%S')} {label}: {time.monotonic() - started:.3f}s -> {value}", flush=True)


def launch(name, wait=25):
    scratch = pathlib.Path(f"/private/tmp/vd.{name}.{os.getpid()}")
    for path in (scratch / "home", scratch / "tmp", scratch / "tmux"):
        path.mkdir(parents=True, exist_ok=True)
    root = out / name
    (root / "evidence").mkdir(parents=True)
    (root / "run.json").write_text(json.dumps({
        "id": name, "scratch": str(scratch), "home": str(scratch / "home"), "store": str(scratch / "store"),
        "project": str(scratch), "binary": "/usr/bin/true", "source": str(source)}))
    env = {"HOME": str(scratch / "home"), "PATH": os.environ["PATH"], "TERM": "xterm-256color", "LANG": "en_US.UTF-8",
           "TMPDIR": str(scratch / "tmp"), "XDG_CONFIG_HOME": str(scratch / "home/.config"),
           "TMUX_TMPDIR": str(scratch / "tmux"), "PYTHONFAULTHANDLER": "1", "PYTHONPROFILEIMPORTTIME": "1"}
    started = time.monotonic()
    log = open(root / "fixture.log", "w")
    process = subprocess.Popen([sys.executable, str(helper), "_fixture", str(root)], stdout=log, stderr=subprocess.STDOUT,
                               env=env, start_new_session=True)
    return name, process, scratch, started, root, wait


def finish(name, process, scratch, started, root, wait):
    port = scratch / "fixture.port"
    while not port.exists() and process.poll() is None and time.monotonic() - started < wait:
        time.sleep(0.05)
    elapsed = time.monotonic() - started
    state = "port" if port.exists() else ("exited %s" % process.poll() if process.poll() is not None else "STALLED")
    print(f"{time.strftime('%H:%M:%S')} fixture {name}: {state} after {elapsed:.2f}s", flush=True)
    if state == "STALLED":
        subprocess.run(["sample", str(process.pid), "3", "-file", str(root / "sample.txt")], capture_output=True)
        process.send_signal(signal.SIGABRT)
    else:
        process.terminate()
    process.wait()
    text = (root / "fixture.log").read_text(errors="replace")
    slow = [line for line in text.splitlines() if line.startswith("import time:") and line.split("|")[1].strip().isdigit()
            and int(line.split("|")[1]) > 200000]
    print("  slow imports (>0.2s cumulative):", *slow[:12], sep="\n    ")
    tail = [line for line in text.splitlines() if not line.startswith("import time:")]
    print("  non-import output:", *tail[-40:], sep="\n    ")
    if (root / "sample.txt").exists():
        lines = (root / "sample.txt").read_text(errors="replace").splitlines()
        print("  sample (first 60 call-graph lines):", *lines[10:70], sep="\n    ")


which = sys.argv[4]
if which == "cold":
    finish(*launch("cold-single", wait=60))
elif which == "ttl":
    for delay in (0, 0, 5, 15, 30, 60):
        time.sleep(delay)
        t(f"gethostbyaddr after {delay}s", lambda: socket.gethostbyaddr("127.0.0.1"))
elif which == "parallel":
    runs = [launch(f"par-{i}") for i in range(6)]
    for run in runs:
        finish(*run)
