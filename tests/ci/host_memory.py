#!/usr/bin/env python3
"""Measure a Rui executable's Host memory in fixed scenarios, for release notes.

    python3 tests/ci/host_memory.py RUI > host-memory.md

Each scenario starts a fresh Host, brings it to one state with the
tests/integration fixtures (no network), waits until the scenario's metric
from /proc/PID/smaps_rollup stops changing, and reads it. Every scenario runs
RUNS times; the Markdown printed reports the median and range in KiB. A
feature adds a row by adding one entry to SCENARIOS.

Nothing here fails a release. A scenario that cannot be measured prints
"not measured" with its reason in its row, and a run that cannot start prints
one "not measured" line; either way the exit status is 0.
"""
import contextlib
import os
from pathlib import Path
import socket
import ssl
import statistics
import subprocess
import sys
import tempfile
import threading
from typing import Callable, NamedTuple

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests/integration"))
import host_process
import launch_frame_fixture
import os_semantics
from product_defaults import compaction_trigger

RUNS = 7
AGENTS = 100
# A reading is taken once the metric repeats this many reads in a row, a tenth
# of a second apart: a Host's last start-up writes land after it is ready.
STEADY_READS = 3
COMPARABLE = ("Numbers are comparable only release to release on the same runner type; "
              "another machine, kernel or glibc reads other values.")


class Scenario(NamedTuple):
    name: str
    metric: str  # A /proc/PID/smaps_rollup field.
    # (binary, root) -> a context manager that yields the Host's pid once the
    # Host is in the state to read, and stops it on exit.
    host: Callable


def smaps_rollup(pid, metric):
    for line in Path(f"/proc/{pid}/smaps_rollup").read_text().splitlines():
        if line.startswith(metric + ":"):
            return int(line.split()[1])
    raise ValueError(f"/proc/{pid}/smaps_rollup has no {metric}")


def steady(pid, metric):
    reads = []

    def read():
        reads.append(smaps_rollup(pid, metric))
        return reads[-1] if reads[-STEADY_READS:] == [reads[-1]] * STEADY_READS else None

    return host_process.wait_for(read, f"Host {metric} to stop changing", timeout=10, interval=0.1)


def h2_endpoint(root, requests=0):
    # model_fixture, under h2_fixture, reads the binary from sys.argv[1] at import.
    import h2_fixture
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(root / "cert.pem", root / "key.pem")
    tls.set_alpn_protocols(["h2"])
    # One more than the requests it will see, so it answers none of them.
    endpoint = h2_fixture.Endpoint(tls, requests + 1, sse=True)
    threading.Thread(target=endpoint.serve_forever, daemon=True).start()
    return endpoint


@contextlib.contextmanager
def served(endpoint, args, **options):
    try:
        host, ready = host_process.start_ready_process(args, **options)
        try:
            yield host, ready
        finally:
            host_process.stop_process(host)
    finally:
        if endpoint.models_release is not None:
            endpoint.models_release.set()
        endpoint.shutdown()
        endpoint.server_close()


def codex_args(binary, root, store, endpoint):
    return [binary, "host", "serve", "--store", store, "--active-capacity", AGENTS,
            "--provider-endpoint", f"https://localhost:{endpoint.server_address[1]}/responses",
            "--provider-ca-file", root / "cert.pem"]


@contextlib.contextmanager
def empty(binary, root, store):
    endpoint = h2_endpoint(root)
    with served(endpoint, codex_args(binary, root, store, endpoint), required_fields={"execution": "enabled"}) as (host, _):
        yield host.pid


@contextlib.contextmanager
def waiting(binary, root, store):
    import h2_fixture
    endpoint = h2_endpoint(root, AGENTS)
    with served(endpoint, codex_args(binary, root, store, endpoint),
                required_fields={"execution": "enabled"}) as (host, ready):
        configuration = {"workspace": str(root), "provider": "codex", "model": "gpt-6-sol", "tools": ["bash"],
                         "permissionMode": "ask", "compactAt": compaction_trigger("codex", "gpt-6-sol"),
                         "effort": "medium"}
        for index in range(AGENTS):
            configured = h2_fixture.closed_host_request(ready["socket"], store, "configure", key=f"c{index}",
                                                        session="", configuration=configuration)
            assert configured["answer"]["status"] == "accepted", configured
            sent = h2_fixture.closed_host_request(
                ready["socket"], store, "message", key=f"m{index}", session=configured["answer"]["session"],
                sender=None, sender_handle=None, text={"state": "value", "value": f"waiting-{index}"})
            assert sent["answer"]["status"] == "accepted", sent
        host_process.wait_for(lambda: len(endpoint.streams) == AGENTS, f"{AGENTS} model requests held open", timeout=30)
        yield host.pid


@contextlib.contextmanager
def model_listing(binary, root, store):
    endpoint = h2_endpoint(root)
    endpoint.models_release = threading.Event()
    environment = {**os.environ, "RUI_OPENAI_KEY_FILE": str(root / "openai.key"),
                   "RUI_OPENAI_BASE_URL": f"https://localhost:{endpoint.server_address[1]}/v1/",
                   **os_semantics.system_trust(root / "cert.pem")}
    with served(endpoint, [binary, "host", "serve", "--store", store, "--provider", "openai",
                           "--active-capacity", AGENTS], env=environment) as (host, _):
        host_process.wait_for(lambda: any(headers[b":path"] == b"/v1/models" for headers in list(endpoint.request_headers)),
                              "the OpenAI model listing held open", timeout=10)
        yield host.pid


@contextlib.contextmanager
def mcp_listing(binary, root, store):
    # As in launch_frame_integration: a server that accepts and never answers
    # holds the Host in its start-up tools/list.
    silent = socket.socket()
    try:
        silent.bind(("127.0.0.1", 0))
        silent.listen(1)
        silent.settimeout(10)
        runtime = Path(tempfile.mkdtemp(dir=root))
        frame = {"v": 1, "store": str(store), "runtimeDir": str(runtime), "activeCapacity": AGENTS,
                 "provider": {"kind": "openai_key", "baseUrl": "https://127.0.0.1:1/v1", "key": "sk-synthetic"},
                 "mcpServers": [{"name": "silent", "url": f"http://127.0.0.1:{silent.getsockname()[1]}/mcp",
                                 "bearerToken": "t"}]}
        host = subprocess.Popen([binary, "host", "serve", "--launch-frame"], stdin=subprocess.PIPE,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            host.stdin.write(launch_frame_fixture.frame(frame))
            host.stdin.flush()
            held, _ = silent.accept()
            with held:
                yield host.pid
        finally:
            host_process.stop_process(host)
    finally:
        silent.close()


SCENARIOS = (
    Scenario("Empty Host", "Private_Dirty", empty),
    Scenario(f"{AGENTS} agents waiting on the model", "Private_Dirty", waiting),
    Scenario("Model listing held at start", "Anonymous", model_listing),
    Scenario("MCP tool listing held at start", "Anonymous", mcp_listing),
)


def measure(binary, scenarios=SCENARIOS, runs=RUNS):
    """{scenario name: [KiB per run]} or {scenario name: "reason"} when a run failed."""
    # smaps counts a mapped page that is dirty in the page cache as dirty, so a
    # binary just written or unpacked reads several MiB high until written back.
    descriptor = os.open(binary, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    readings = {}
    with tempfile.TemporaryDirectory(prefix="rui-host-memory-", dir="/tmp") as temporary:
        root = host_process.canonical_fixture_root(temporary)
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", root / "key.pem",
                        "-out", root / "cert.pem", "-days", "1", "-subj", "/CN=localhost",
                        "-addext", "subjectAltName=DNS:localhost"], capture_output=True, check=True)
        (root / "openai.key").write_text("sk-synthetic-openai-key\n")
        (root / "openai.key").chmod(0o600)
        for index, scenario in enumerate(scenarios):
            runs_read = []
            try:
                for run in range(runs):
                    with scenario.host(binary, root, root / f"store-{index}-{run}") as pid:
                        runs_read.append(steady(pid, scenario.metric))
                readings[scenario.name] = runs_read
            except Exception as error:
                readings[scenario.name] = reason(error)
    return readings


def reason(error):
    text = " ".join(str(error).split()) or type(error).__name__
    return text if len(text) <= 300 else text[:297] + "..."


def runner():
    """The machine facts a reader needs to compare releases, read before the fixture boundary clears them."""
    model = next((line.split(":", 1)[1].strip() for line in Path("/proc/cpuinfo").read_text().splitlines()
                  if line.startswith("model name")), "unknown CPU")
    image = " ".join(filter(None, (os.environ.get("ImageOS"), os.environ.get("ImageVersion")))) or "unknown image"
    return {"image": image, "cpu": model, "kernel": os.uname().release, "glibc": os.confstr("CS_GNU_LIBC_VERSION")}


def summary(version, machine, readings, scenarios=SCENARIOS):
    """The release-notes section for readings from measure()."""
    metrics = {scenario.name: scenario.metric for scenario in scenarios}
    lines = ["### Host memory", "",
             f"Measured on this release's linux-x86_64 executable ({version}), on a GitHub-hosted runner "
             f"({machine['image']}, {machine['cpu']}, kernel {machine['kernel']}, {machine['glibc']}). "
             "Each run starts a fresh Host and reads its /proc/PID/smaps_rollup field once it stops changing. "
             "Values in KiB.", "",
             "| Scenario | Metric | Runs | Median | Range |", "| --- | --- | --- | --- | --- |"]
    for name, runs in readings.items():
        if isinstance(runs, str):
            lines.append(f"| {name} | {metrics[name]} | not measured: {runs.replace('|', '/')} | | |")
        else:
            lines.append(f"| {name} | {metrics[name]} | {len(runs)} | {statistics.median(runs):g} | "
                         f"{min(runs)}-{max(runs)} |")
    return "\n".join([*lines, "", COMPARABLE])


def not_measured(why):
    return f"### Host memory\n\nNot measured: {why}\n"


def main():
    try:
        if len(sys.argv) != 2:
            raise ValueError("usage: host_memory.py RUI")
        binary = Path(sys.argv[1]).resolve()
        version = subprocess.run([binary, "--version"], capture_output=True, text=True, timeout=10,
                                 check=True).stdout.strip()
        machine = runner()
        host_process.enter()
        print(summary(version, machine, measure(binary)))
    except (Exception, SystemExit) as error:
        print(not_measured(reason(error)))


if __name__ == "__main__":
    main()
