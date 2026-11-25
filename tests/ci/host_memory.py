#!/usr/bin/env python3
import contextlib
import os
from pathlib import Path
import resource
import socket
import ssl
import statistics
import subprocess
import sys
import tempfile
import threading
from typing import Callable, Iterator, NamedTuple

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests/integration"))
import host_process
import settings_fixture
import os_semantics

RUNS = 7                          # publish-only scenarios, each run one fresh Host
RAMP_RUNS = 5                     # gated ramp; each run is one fresh Host
RAMP_FROM, RAMP_TO = 100, 1_000   # 10 -> 100 is one-time warm-up (glibc arena, statements); the slope starts at 100
SLOPE_AGENTS = RAMP_TO - RAMP_FROM
PER_AGENT_BUDGET = 4_096          # bytes of Private_Dirty per agent waiting on the model; a product number, not a ratchet
MIN_RAMP_RUNS = 3                 # fewer completed runs is "not measured", never a pass
PUBLISH_AGENTS = 100              # activeCapacity the publish-only rows have always run at, so they stay comparable
STEADY_READS = 3
FIXTURE_DESCRIPTORS = RAMP_TO + 64          # this process's own sockets: one per held RAMP_TO stream, plus the listener and margin
COMPARABLE = ("Numbers are comparable only release to release on the same runner type; "
              "another machine, kernel or glibc reads other values.")


class Scenario(NamedTuple):
    name: str
    metric: str
    host: Callable


class Ramp(NamedTuple):
    """One Host's steady Private_Dirty (KiB, from smaps_rollup) at RAMP_FROM and then RAMP_TO waiting agents."""
    at_from: int
    at_to: int

    @property
    def delta(self) -> int:
        """KiB that the agents past RAMP_FROM added. Fixed costs and a bimodal second-arena step
        cancel inside one process instead of landing in one reading."""
        return self.at_to - self.at_from


class Verdict(NamedTuple):
    per_agent: int | None   # median bytes per agent, floored; None when not measured
    within: bool
    line: str               # the gate sentence: the pass note, or on failure the gate message


class Readings(NamedTuple):
    rows: dict              # publish-only scenario name -> KiB per run, or why it was not measured
    ramps: list | str       # gated ramp runs, or why the ramp did not run


def verdict(ramps, budget=PER_AGENT_BUDGET):
    """Pure. A str is the reason the ramp did not run. Fewer than MIN_RAMP_RUNS ramps is not measured
    and not within. Otherwise the median per-run delta, in integers, is compared with the budget,
    inclusive: median KiB * 1024 <= SLOPE_AGENTS * budget bytes."""
    if isinstance(ramps, str):
        return Verdict(None, False, f"Host memory gate failed: per-agent cost not measured: {ramps}")
    if len(ramps) < MIN_RAMP_RUNS:
        return Verdict(None, False, "Host memory gate failed: per-agent cost not measured: "
                                    f"{len(ramps)} of {RAMP_RUNS} ramp runs completed, "
                                    f"fewer than the {MIN_RAMP_RUNS} needed")
    # The upper middle of an even count, so a half-KiB median never rounds toward passing.
    median = statistics.median_high([ramp.delta for ramp in ramps])
    per_agent = median * 1024 // SLOPE_AGENTS
    if median * 1024 <= SLOPE_AGENTS * budget:
        return Verdict(per_agent, True, "Host memory gate passed: an agent waiting on the model costs "
                                        f"{per_agent:,} bytes (median of {len(ramps)}), within the {budget:,}-byte budget.")
    return Verdict(per_agent, False, "Host memory gate failed: an agent waiting on the model costs "
                                     f"{per_agent:,} bytes (median of {len(ramps)}), past the {budget:,}-byte budget.")


SCENARIOS = (                             # publish-only rows; failures become "not measured" rows
    Scenario("Empty Host", "Private_Dirty", lambda binary, root, store: empty(binary, root, store)),
    Scenario("Model listing held at start", "Anonymous", lambda binary, root, store: model_listing(binary, root, store)),
    Scenario("MCP tool listing held at start", "Anonymous", lambda binary, root, store: mcp_listing(binary, root, store)),
)


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
    import h2_fixture
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(root / "cert.pem", root / "key.pem")
    tls.set_alpn_protocols(["h2"])
    endpoint = h2_fixture.Endpoint(tls, requests + 1, sse=True)
    if requests:
        # The server advertises MAX_CONCURRENT_STREAMS=100 unless told otherwise, so hold one stream per request.
        endpoint.max_streams = requests + 1
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


def codex_args(binary, root, store, endpoint, capacity):
    return [binary, "host", "serve", "--store", store, "--set", f"providers.openai.endpoint=https://localhost:{endpoint.server_address[1]}/v1/responses", "--set", "execution.activeCapacity=" + str(capacity),
            "--set", "providers={}",
                "--set", "providers.codex.endpoint=" + str(f"https://localhost:{endpoint.server_address[1]}/responses"),
                "--set", "providers.codex.unauthenticated=true",
            "--set", "network.caFile=" + str(root / "cert.pem")]


@contextlib.contextmanager
def empty(binary, root, store):
    endpoint = h2_endpoint(root)
    with served(endpoint, codex_args(binary, root, store, endpoint, PUBLISH_AGENTS), required_fields={"execution": "enabled"}) as (host, _):
        yield host.pid


def admit(ready, store, configuration, start, stop):
    import h2_fixture
    for index in range(start, stop):
        configured = h2_fixture.closed_host_request(ready["socket"], store, "configure", key=f"c{index}",
                                                    session="", configuration=configuration)
        assert configured["answer"]["status"] == "accepted", configured
        sent = h2_fixture.closed_host_request(
            ready["socket"], store, "message", key=f"m{index}", session=configured["answer"]["session"],
            sender=None, sender_handle=None, text={"state": "value", "value": f"waiting-{index}"})
        assert sent["answer"]["status"] == "accepted", sent


def held_exactly(endpoint, count):
    host_process.wait_for(lambda: len(endpoint.streams) >= count, f"{count} model requests held open", timeout=120)
    held = len(endpoint.streams)
    assert held == count, f"{held} model requests held, expected exactly {count}"


@contextlib.contextmanager
def ramp(binary, root, store) -> Iterator[Ramp]:
    """One Host with execution.activeCapacity=RAMP_TO and an h2 endpoint holding RAMP_TO streams.
    Admit RAMP_FROM agents, wait until exactly RAMP_FROM streams are held, read steady(Private_Dirty);
    admit the rest, wait for exactly RAMP_TO streams, read again."""
    import h2_fixture
    endpoint = h2_endpoint(root, RAMP_TO)
    with served(endpoint, codex_args(binary, root, store, endpoint, RAMP_TO),
                required_fields={"execution": "enabled"}) as (host, ready):
        configuration = h2_fixture.codex_wait_configuration(root)
        admit(ready, store, configuration, 0, RAMP_FROM)
        held_exactly(endpoint, RAMP_FROM)
        at_from = steady(host.pid, "Private_Dirty")
        held_exactly(endpoint, RAMP_FROM)
        admit(ready, store, configuration, RAMP_FROM, RAMP_TO)
        held_exactly(endpoint, RAMP_TO)
        at_to = steady(host.pid, "Private_Dirty")
        held_exactly(endpoint, RAMP_TO)
        yield Ramp(at_from, at_to)


@contextlib.contextmanager
def model_listing(binary, root, store):
    endpoint = h2_endpoint(root)
    endpoint.models_release = threading.Event()
    environment = {**os.environ, "RUI_OPENAI_KEY_FILE": str(root / "openai.key"),
                   **os_semantics.system_trust(root / "cert.pem")}
    with served(endpoint, [binary, "host", "serve", "--store", store, "--set", 'providers={"openai":{}}',
                           "--set", f"providers.openai.endpoint=https://localhost:{endpoint.server_address[1]}/v1/responses", "--set", "execution.activeCapacity=" + str(PUBLISH_AGENTS)], env=environment) as (host, _):
        host_process.wait_for(lambda: any(headers[b":path"] == b"/v1/models" for headers in list(endpoint.request_headers)),
                              "the OpenAI model listing held open", timeout=10)
        yield host.pid


@contextlib.contextmanager
def mcp_listing(binary, root, store):
    silent = socket.socket()
    try:
        silent.bind(("127.0.0.1", 0))
        silent.listen(1)
        silent.settimeout(10)
        runtime = Path(tempfile.mkdtemp(dir=root))
        document = {"store": {"sqlite": {"dir": str(store)}},
                    "interface": {"dir": str(runtime), "lifetime": "stdin"},
                    "execution": {"activeCapacity": PUBLISH_AGENTS},
                    "providers": {"openai": {"endpoint": "https://127.0.0.1:1/v1/responses", "key": {"value": "sk-synthetic"}}},
                    "tools": {"mcp": {"silent": {"url": f"http://127.0.0.1:{silent.getsockname()[1]}/mcp",
                                                 "bearerToken": {"value": "t"}}}}}
        host = subprocess.Popen([binary, "host", "serve", "--settings", "-"], stdin=subprocess.PIPE,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            host.stdin.write(settings_fixture.frame(document))
            host.stdin.flush()
            held, _ = silent.accept()
            with held:
                yield host.pid
        finally:
            host_process.stop_process(host)
    finally:
        silent.close()


def raise_descriptor_limit(getrlimit=resource.getrlimit, setrlimit=resource.setrlimit):
    """Raise the soft descriptor limit to the hard limit, so the Host inherits it, and return the soft limit now in force.
    Whether the Host has enough is the Host's to say: it refuses to start with its own reason, which a ramp run reports."""
    soft, hard = getrlimit(resource.RLIMIT_NOFILE)
    if soft != hard:
        try:
            setrlimit(resource.RLIMIT_NOFILE, (hard, hard))
        except (OSError, ValueError):
            pass
        soft = getrlimit(resource.RLIMIT_NOFILE)[0]
    return soft


def fixture_shortfall(soft, needed=FIXTURE_DESCRIPTORS):
    """Only this process's own headroom is checked here. None when the soft limit covers it."""
    if soft != resource.RLIM_INFINITY and soft < needed:
        return f"the fixture's descriptor limit is {soft:,}, below the {needed:,} its {RAMP_TO:,} held streams need"
    return None


def completed_ramp(open_ramp, binary, root, store) -> Ramp:
    """The reading is returned only after ramp() has exited cleanly, so a failure at teardown raises
    and the run is never counted."""
    with open_ramp(binary, root, store) as measured:
        pass
    return measured


def ramp_runs(binary, root, raise_limit=raise_descriptor_limit, open_ramp=ramp):
    shortfall = fixture_shortfall(raise_limit())
    if shortfall:
        return shortfall
    ramps, last = [], "no ramp run started"
    for index in range(RAMP_RUNS):
        try:
            ramps.append(completed_ramp(open_ramp, binary, root, root / f"ramp-store-{index}"))
        except Exception as error:
            last = reason(error)
            print(f"host-memory: ramp run {index + 1} of {RAMP_RUNS} not measured: {last}", file=sys.stderr)
    return ramps or last


def measure(binary: Path) -> Readings:
    # smaps counts a mapped page that is dirty in the page cache as dirty, so a
    # binary just written or unpacked reads several MiB high until written back.
    descriptor = os.open(binary, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    rows = {}
    with tempfile.TemporaryDirectory(prefix="rui-host-memory-", dir="/tmp") as temporary:
        root = host_process.canonical_fixture_root(temporary)
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", root / "key.pem",
                        "-out", root / "cert.pem", "-days", "1", "-subj", "/CN=localhost",
                        "-addext", "subjectAltName=DNS:localhost"], capture_output=True, check=True)
        (root / "openai.key").write_text("sk-synthetic-openai-key\n")
        (root / "openai.key").chmod(0o600)
        for index, scenario in enumerate(SCENARIOS):
            runs_read = []
            try:
                for run in range(RUNS):
                    with scenario.host(binary, root, root / f"store-{index}-{run}") as pid:
                        runs_read.append(steady(pid, scenario.metric))
                rows[scenario.name] = runs_read
            except Exception as error:
                rows[scenario.name] = reason(error)
        ramps = ramp_runs(binary, root)
    return Readings(rows, ramps)


def reason(error):
    text = " ".join(str(error).split()) or type(error).__name__
    return text if len(text) <= 300 else text[:297] + "..."


def runner():
    model = next((line.split(":", 1)[1].strip() for line in Path("/proc/cpuinfo").read_text().splitlines()
                  if line.startswith("model name")), "unknown CPU")
    image = " ".join(filter(None, (os.environ.get("ImageOS"), os.environ.get("ImageVersion")))) or "unknown image"
    return {"image": image, "cpu": model, "kernel": os.uname().release, "glibc": os.confstr("CS_GNU_LIBC_VERSION")}


def table_row(name, metric, runs):
    if isinstance(runs, str):
        return f"| {name} | {metric} | not measured: {runs.replace('|', '/')} | | |"
    return f"| {name} | {metric} | {len(runs)} | {statistics.median(runs):g} | {min(runs)}-{max(runs)} |"


def summary(version, machine, readings, judged):
    ramps = readings.ramps
    lines = ["### Host memory", "",
             f"Measured on {version} on {machine['image']}, {machine['cpu']}, kernel {machine['kernel']}, "
             f"{machine['glibc']}. Each run starts a fresh Host and reads its /proc/PID/smaps_rollup field once it "
             "stops changing. Values in KiB.", "",
             "| Scenario | Metric | Runs | Median | Range |", "| --- | --- | --- | --- | --- |",
             table_row("Empty Host", "Private_Dirty", readings.rows.get("Empty Host", "not run")),
             table_row(f"{RAMP_FROM:,} agents waiting on the model", "Private_Dirty",
                       ramps if isinstance(ramps, str) else [ramp.at_from for ramp in ramps]),
             table_row(f"{RAMP_TO:,} agents waiting on the model", "Private_Dirty",
                       ramps if isinstance(ramps, str) else [ramp.at_to for ramp in ramps])]
    for scenario in SCENARIOS[1:]:
        lines.append(table_row(scenario.name, scenario.metric, readings.rows.get(scenario.name, "not run")))
    lines.append("")
    if verdict_measured(judged):
        deltas = [ramp.delta * 1024 // SLOPE_AGENTS for ramp in ramps]
        lines.append(f"Per agent ({RAMP_FROM:,} -> {RAMP_TO:,} waiting agents, same Host): {judged.per_agent:,} bytes "
                     f"median of {len(ramps)} (range {min(deltas):,}-{max(deltas):,}); budget {PER_AGENT_BUDGET:,} bytes.")
    else:
        lines.append(f"Per agent ({RAMP_FROM:,} -> {RAMP_TO:,} waiting agents, same Host): not measured.")
    return "\n".join([*lines, "", COMPARABLE, "", judged.line])


def verdict_measured(judged):
    return judged.per_agent is not None


def not_measured(why, judged):
    return f"### Host memory\n\nNot measured: {why}\n\n{judged.line}"


def main():
    notes = os.environ.get("RUI_HOST_MEMORY_NOTES")
    try:
        if len(sys.argv) != 2:
            raise ValueError("usage: host_memory.py RUI")
        binary = Path(sys.argv[1]).resolve()
        version = subprocess.run([binary, "--version"], capture_output=True, text=True, timeout=10,
                                 check=True).stdout.strip()
        machine = runner()
        host_process.enter()
        readings = measure(binary)
        judged = verdict(readings.ramps)
        text = summary(version, machine, readings, judged)
    except (Exception, SystemExit) as error:
        why = reason(error)
        judged = verdict(why)
        text = not_measured(why, judged)
    print(text)
    if notes:
        Path(notes).write_text(text + "\n")
    if not judged.within:
        print(judged.line, file=sys.stderr)
    return 0 if judged.within else 1


if __name__ == "__main__":
    sys.exit(main())
