#!/usr/bin/env python3
"""Hold N coding agents on one local fake model endpoint and measure memory.

Adapted from /mnt/project-files/rui-fx-memory/fx_hold.py. The fixture accepts
any POST (OpenAI chat/responses, Anthropic messages, Gemini generateContent),
reads the body, sends 200 + text/event-stream headers, then sends nothing and
holds the connection. Each agent's prompt carries a unique token
`ruiprobe<i>x`; an agent counts as held when a request carrying its token and a
tool list reached the fixture and is still being held.

usage: hold.py TOOL N OUTDIR [WARMUP_S]
Prints one JSON line. Sums cover the whole process tree of every launched root.
"""
import http.server, json, os, re, signal, subprocess, sys, threading, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
NPM = HERE / "npm" / "node_modules"
tool, n, out = sys.argv[1], int(sys.argv[2]), Path(sys.argv[3]).resolve()
warmup = float(sys.argv[4]) if len(sys.argv) > 4 else 10
out.mkdir(parents=True)
TOK = re.compile(rb"ruiprobe(\d+)x")
lock = threading.RLock()
held = {}          # agent index -> list of (path, has_tools)
other = []         # requests without a token
log = open(out / "requests.log", "w")

def read_body(h):
    if "chunked" in (h.headers.get("Transfer-Encoding") or ""):
        data = b""
        while True:
            size = int(h.rfile.readline().strip().split(b";")[0], 16)
            if size == 0:
                h.rfile.readline(); return data
            data += h.rfile.read(size); h.rfile.readline()
    return h.rfile.read(int(h.headers.get("Content-Length") or 0))

MODELS = json.dumps({"object": "list", "data": [{"id": "fake-model", "object": "model", "owned_by": "fixture", "type": "language", "context_window": 200000}],
                     "models": [{"name": "models/fake-model"}]}).encode()

class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *_): pass
    def do_HEAD(self):
        self.send_response(200); self.send_header("Content-Length", "0"); self.end_headers()
    def do_GET(self):
        with lock: log.write(f"GET {self.path}\n"); log.flush()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(MODELS))); self.end_headers(); self.wfile.write(MODELS)
    def do_POST(self):
        body = read_body(self)
        m = TOK.search(body)
        tools = b'"tools"' in body or b'"functionDeclarations"' in body
        with lock:
            log.write(f"POST {self.path} len={len(body)} token={m.group(1).decode() if m else '-'} tools={tools}\n"); log.flush()
            if m: held.setdefault(int(m.group(1)), []).append((self.path, tools))
            else: other.append(self.path)
        self.send_response(200); self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache"); self.end_headers(); self.wfile.flush()
        while True:
            time.sleep(1)  # hold: send nothing

srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
srv.daemon_threads = True
srv.request_queue_size = 1024
threading.Thread(target=srv.serve_forever, daemon=True).start()
port = srv.server_port
base = f"http://127.0.0.1:{port}"

def prompt(i): return f"Task ruiprobe{i}x: reply with the word hi."

def clean_env(home):
    drop = ("OPENAI_", "ANTHROPIC_", "GEMINI_", "GOOGLE_", "CLAUDE", "CODEX_", "OPENCODE", "CRUSH", "PI_", "XDG_")
    env = {k: v for k, v in os.environ.items() if not k.startswith(drop) and k not in ("HTTPS_PROXY", "HTTP_PROXY", "https_proxy", "http_proxy", "ALL_PROXY")}
    env.update(HOME=str(home), NO_PROXY="127.0.0.1,localhost", no_proxy="127.0.0.1,localhost")
    return env

def bin_codex():
    return next(NPM.glob("@openai/codex-linux-x64/vendor/*/bin/codex"))
def bin_crush():
    return NPM / "@charmland/crush/bin/crush"

roots = []         # Popen objects whose trees are measured
def spawn(cmd, env, cwd, i, stdin=subprocess.DEVNULL):
    return subprocess.Popen(cmd, cwd=cwd, env=env, stdin=stdin, stdout=open(out / f"a{i}.out", "w"),
                            stderr=open(out / f"a{i}.err", "w"), start_new_session=True)

def agent_dirs(i):
    home = out / f"a{i}" / "home"; ws = out / f"a{i}" / "ws"
    home.mkdir(parents=True); ws.mkdir(); return home, ws

# ---- per-process tools: one OS process tree per agent ----
def claude(i):
    home, ws = agent_dirs(i); env = clean_env(home)
    env.update(ANTHROPIC_BASE_URL=base, ANTHROPIC_API_KEY="fixture-key", CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1",
               DISABLE_AUTOUPDATER="1", DISABLE_TELEMETRY="1", DISABLE_ERROR_REPORTING="1")
    return spawn([str(NPM / ".bin/claude"), "-p", prompt(i), "--model", "claude-sonnet-4-5"], env, ws, i)

def codex_exec(i):
    home, ws = agent_dirs(i); env = clean_env(home)
    ch = home / ".codex"; ch.mkdir()
    (ch / "config.toml").write_text(f'model = "fake-model"\nmodel_provider = "fake"\n[model_providers.fake]\nname = "fake"\nbase_url = "{base}/v1"\nwire_api = "responses"\nenv_key = "FAKE_KEY"\n[features]\nplugins = false\n')
    env.update(CODEX_HOME=str(ch), FAKE_KEY="fixture-key")
    return spawn([str(bin_codex()), "exec", "--skip-git-repo-check", prompt(i)], env, ws, i)

def gemini(i):
    home, ws = agent_dirs(i); env = clean_env(home)
    (home / ".gemini").mkdir()
    (home / ".gemini/settings.json").write_text(json.dumps({"security": {"auth": {"selectedType": "gemini-api-key"}}, "privacy": {"usageStatisticsEnabled": False},
        "general": {"disableAutoUpdate": True, "disableUpdateNag": True}, "telemetry": {"enabled": False}}))
    env.update(GEMINI_API_KEY="fixture-key", GOOGLE_GEMINI_BASE_URL=base, GEMINI_CLI_TRUST_WORKSPACE="true")
    return spawn([str(NPM / ".bin/gemini"), "-p", prompt(i), "-m", "gemini-2.5-flash"], env, ws, i)

def crush(i):
    home, ws = agent_dirs(i); env = clean_env(home)
    cfg = {"providers": {"fake": {"type": "openai-compat", "base_url": base + "/v1", "api_key": "fixture-key",
            "models": [{"id": "fake-model", "name": "fake", "context_window": 200000, "default_max_tokens": 4096}]}},
           "models": {"large": {"model": "fake-model", "provider": "fake"}, "small": {"model": "fake-model", "provider": "fake"}},
           "options": {"disable_provider_auto_update": True, "disable_metrics": True}}
    (ws / "crush.json").write_text(json.dumps(cfg))
    env.update(CRUSH_DISABLE_PROVIDER_AUTO_UPDATE="1", CRUSH_DISABLE_METRICS="1", DO_NOT_TRACK="1")
    return spawn([str(bin_crush()), "run", "--quiet", prompt(i)], env, ws, i)

def pi(i):
    home, ws = agent_dirs(i); env = clean_env(home)
    ag = home / ".pi/agent"; ag.mkdir(parents=True)
    (ag / "models.json").write_text(json.dumps({"providers": {"fake": {"baseUrl": base + "/v1", "api": "openai-completions", "apiKey": "fixture-key",
        "models": [{"id": "fake-model", "name": "fake", "reasoning": False, "input": ["text"], "contextWindow": 200000, "maxTokens": 4096,
                    "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0}}]}}}))
    env.update(PI_SKIP_VERSION_CHECK="1", PI_OFFLINE="1")
    return spawn([str(NPM / ".bin/pi"), "-p", "--provider", "fake", "--model", "fake-model", prompt(i)], env, ws, i)

def fx(i):
    home, ws = agent_dirs(i); env = clean_env(home)
    (home / ".fx").mkdir()
    (home / ".fx/settings.json").write_text(json.dumps({"provider": "gateway", "model": "openai/gpt-5.5", "max_agent_steps": 0, "session_titles": False}))
    env.update(AI_GATEWAY_API_KEY="fixture-key", FX_GATEWAY_BASE_URL=base, FX_E2E_GATEWAY_CHAT_URL=base + "/chat",
               FX_E2E_GATEWAY_MODELS_URL=base + "/coding-agent/v1/models", FX_MODEL="openai/gpt-5.5", FX_MAX_AGENT_STEPS="0")
    return spawn([os.environ["FX_BIN"], "ask", "--json", "--yolo", prompt(i)], env, ws, i)

PER_PROCESS = {"claude": claude, "codex-exec": codex_exec, "gemini": gemini, "crush": crush, "pi": pi, "fx": fx}

# ---- shared-server tools: one server hosts every agent session ----
def http_json(method, url, body=None, timeout=30):
    import urllib.request
    req = urllib.request.Request(url, method=method, data=None if body is None else json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(req, timeout=timeout) as r:
        raw = r.read(); return json.loads(raw) if raw else None

PER_DIR = tool.endswith("-dirs")  # give every session its own working directory
def wsdir(ws, i):
    if not PER_DIR: return ws
    d = ws / f"s{i}"; d.mkdir(exist_ok=True); return d

def opencode_serve():
    home = out / "server" / "home"; ws = out / "server" / "ws"; home.mkdir(parents=True); ws.mkdir()
    env = clean_env(home)
    cfg = {"$schema": "https://opencode.ai/config.json", "autoupdate": False, "share": "disabled", "model": "fake/fake-model", "small_model": "fake/fake-model",
           "provider": {"fake": {"npm": "@ai-sdk/openai-compatible", "name": "fake", "options": {"baseURL": base + "/v1", "apiKey": "fixture-key"},
                                 "models": {"fake-model": {"name": "fake"}}}}}
    env.update(OPENCODE_CONFIG_CONTENT=json.dumps(cfg), OPENCODE_DISABLE_MODELS_FETCH="1", OPENCODE_DISABLE_AUTOUPDATE="1",
               OPENCODE_DISABLE_LSP_DOWNLOAD="1", OPENCODE_DISABLE_DEFAULT_PLUGINS="1", OPENCODE_DISABLE_SHARE="1")
    if tool == "opencode-serve-maxreq": env["BUN_CONFIG_MAX_HTTP_REQUESTS"] = "4096"  # Bun fetch default is 256
    p = spawn([str(NPM / ".bin/opencode"), "serve", "--hostname", "127.0.0.1", "--port", "0", "--print-logs"], env, ws, "server")
    roots.append(p)
    url = None; t0 = time.time()
    while time.time() - t0 < 60 and url is None:
        for line in (out / "aserver.out").read_text().splitlines() + (out / "aserver.err").read_text().splitlines():
            mm = re.search(r"(http://127\.0\.0\.1:\d+)", line)
            if mm: url = mm.group(1)
        time.sleep(0.2)
    if not url: raise SystemExit("opencode serve did not report a URL")
    for i in range(n):
        d = wsdir(ws, i)
        s = http_json("POST", f"{url}/session?directory={d}", {})
        http_json("POST", f"{url}/session/{s['id']}/prompt_async?directory={d}",
                  {"model": {"providerID": "fake", "modelID": "fake-model"}, "parts": [{"type": "text", "text": prompt(i)}]})

def codex_app_server():
    home = out / "server" / "home"; ws = out / "server" / "ws"; home.mkdir(parents=True); ws.mkdir()
    env = clean_env(home); ch = home / ".codex"; ch.mkdir()
    (ch / "config.toml").write_text(f'model = "fake-model"\nmodel_provider = "fake"\n[model_providers.fake]\nname = "fake"\nbase_url = "{base}/v1"\nwire_api = "responses"\nenv_key = "FAKE_KEY"\n[features]\nplugins = false\n')
    env.update(CODEX_HOME=str(ch), FAKE_KEY="fixture-key")
    p = subprocess.Popen([str(bin_codex()), "app-server"], cwd=ws, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=open(out / "aserver.err", "w"), start_new_session=True)
    roots.append(p)
    resp = {}
    def reader():
        for line in p.stdout:
            try: msg = json.loads(line)
            except Exception: continue
            if "id" in msg and ("result" in msg or "error" in msg): resp[msg["id"]] = msg
    threading.Thread(target=reader, daemon=True).start()
    rid = [0]
    def call(method, params):
        rid[0] += 1; k = rid[0]
        p.stdin.write((json.dumps({"jsonrpc": "2.0", "id": k, "method": method, "params": params}) + "\n").encode()); p.stdin.flush()
        t0 = time.time()
        while k not in resp and time.time() - t0 < 30: time.sleep(0.01)
        if k not in resp or "error" in resp[k]: raise SystemExit(f"{method} failed: {resp.get(k)}")
        return resp[k]["result"]
    call("initialize", {"clientInfo": {"name": "rui-probe", "version": "0"}})
    p.stdin.write(b'{"jsonrpc":"2.0","method":"initialized"}\n'); p.stdin.flush()
    for i in range(n):
        th = call("thread/start", {"cwd": str(wsdir(ws, i))})
        call("turn/start", {"threadId": th["thread"]["id"], "input": [{"type": "text", "text": prompt(i)}]})

def stdio_rpc(p):
    resp = {}
    def reader():
        for line in p.stdout:
            try: msg = json.loads(line)
            except Exception: continue
            if "id" in msg and ("result" in msg or "error" in msg): resp[msg["id"]] = msg
            elif "id" in msg and "method" in msg:  # agent->client request: answer with an empty result
                p.stdin.write((json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": {}}) + "\n").encode()); p.stdin.flush()
    threading.Thread(target=reader, daemon=True).start()
    rid = [0]
    def call(method, params, wait=True):
        rid[0] += 1; k = rid[0]
        p.stdin.write((json.dumps({"jsonrpc": "2.0", "id": k, "method": method, "params": params}) + "\n").encode()); p.stdin.flush()
        if not wait: return None
        t0 = time.time()
        while k not in resp and time.time() - t0 < 60: time.sleep(0.01)
        if k not in resp or "error" in resp[k]: raise SystemExit(f"{method} failed: {resp.get(k)}")
        return resp[k]["result"]
    return call

def gemini_acp():
    home = out / "server" / "home"; ws = out / "server" / "ws"; home.mkdir(parents=True); ws.mkdir()
    env = clean_env(home); (home / ".gemini").mkdir()
    (home / ".gemini/settings.json").write_text(json.dumps({"security": {"auth": {"selectedType": "gemini-api-key"}}, "privacy": {"usageStatisticsEnabled": False},
        "general": {"disableAutoUpdate": True, "disableUpdateNag": True}, "telemetry": {"enabled": False}}))
    env.update(GEMINI_API_KEY="fixture-key", GOOGLE_GEMINI_BASE_URL=base, GEMINI_CLI_TRUST_WORKSPACE="true")
    p = subprocess.Popen([str(NPM / ".bin/gemini"), "--acp", "-m", "gemini-2.5-flash"], cwd=ws, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=open(out / "aserver.err", "w"), start_new_session=True)
    roots.append(p); call = stdio_rpc(p)
    call("initialize", {"protocolVersion": 1, "clientCapabilities": {}})
    for i in range(n):
        d = ws / f"s{i}"; d.mkdir()
        s = call("session/new", {"cwd": str(d), "mcpServers": []})
        call("session/prompt", {"sessionId": s["sessionId"], "prompt": [{"type": "text", "text": prompt(i)}]}, wait=False)

def pi_sdk():
    home = out / "server" / "home"; ws = out / "server" / "ws"; home.mkdir(parents=True); ws.mkdir()
    env = clean_env(home); ag = home / ".pi/agent"; ag.mkdir(parents=True)
    (ag / "models.json").write_text(json.dumps({"providers": {"fake": {"baseUrl": base + "/v1", "api": "openai-completions", "apiKey": "fixture-key",
        "models": [{"id": "fake-model", "name": "fake", "reasoning": False, "input": ["text"], "contextWindow": 200000, "maxTokens": 4096,
                    "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0}}]}}}))
    env.update(PI_SKIP_VERSION_CHECK="1", PI_OFFLINE="1")
    roots.append(spawn(["node", str(HERE / "pi_sdk_many.mjs"), str(NPM / "@earendil-works/pi-coding-agent/dist/index.js"), str(n), str(ws)], env, ws, "server"))

def crush_cs():
    # Crush opt-in client/server mode (CRUSH_CLIENT_SERVER=1): one crush server plus one crush run client per agent.
    home = out / "server" / "home"; home.mkdir(parents=True)
    import socket as _s
    _k = _s.socket(); _k.bind(("127.0.0.1", 0)); cport = _k.getsockname()[1]; _k.close()
    host = f"tcp://127.0.0.1:{cport}"
    env = clean_env(home); env.update(CRUSH_DISABLE_PROVIDER_AUTO_UPDATE="1", CRUSH_DISABLE_METRICS="1", DO_NOT_TRACK="1")
    roots.append(spawn([str(bin_crush()), "server", "--host", host], env, out, "server"))
    t0 = time.time()
    while time.time() - t0 < 30:
        try: _s.create_connection(("127.0.0.1", cport), 1).close(); break
        except OSError: time.sleep(0.1)
    for i in range(n):
        h, ws = agent_dirs(i); e = dict(env); e.update(HOME=str(h), CRUSH_CLIENT_SERVER="1")
        cfg = {"providers": {"fake": {"type": "openai-compat", "base_url": base + "/v1", "api_key": "fixture-key",
                "models": [{"id": "fake-model", "name": "fake", "context_window": 200000, "default_max_tokens": 4096}]}},
               "models": {"large": {"model": "fake-model", "provider": "fake"}, "small": {"model": "fake-model", "provider": "fake"}},
               "options": {"disable_provider_auto_update": True, "disable_metrics": True}}
        (ws / "crush.json").write_text(json.dumps(cfg))
        roots.append(spawn([str(bin_crush()), "--host", host, "run", "--quiet", prompt(i)], e, ws, i))
        time.sleep(0.05)

SERVER = {"opencode-serve": opencode_serve, "codex-app-server": codex_app_server, "gemini-acp": gemini_acp, "pi-sdk": pi_sdk, "crush-cs": crush_cs,
          "opencode-serve-dirs": opencode_serve, "opencode-serve-maxreq": opencode_serve, "codex-app-server-dirs": codex_app_server}

def mem_available_mib():
    for line in open("/proc/meminfo"):
        if line.startswith("MemAvailable:"): return int(line.split()[1]) // 1024

aborted = None
t_start = time.time()
if tool in PER_PROCESS:
    for i in range(n):
        if mem_available_mib() < 2048:
            aborted = f"stopped launching at agent {i}: MemAvailable < 2 GiB"; break
        roots.append(PER_PROCESS[tool](i))
        time.sleep(0.05)
else:
    SERVER[tool]()
launched = len(roots) if tool in PER_PROCESS else n

def ok_agents():
    with lock: return sum(1 for i, rs in held.items() if any(t for _, t in rs))
deadline = time.time() + 120
while ok_agents() < launched and time.time() < deadline: time.sleep(0.2)
t_held = time.time() - t_start
time.sleep(warmup)

def children_map():
    m = {}
    for p in Path("/proc").iterdir():
        if p.name.isdigit():
            try: ppid = int((p / "stat").read_text().rsplit(")", 1)[1].split()[1])
            except Exception: continue
            m.setdefault(ppid, []).append(int(p.name))
    return m
cm = children_map()
def tree(pid):
    out_ = [pid]
    for c in cm.get(pid, []): out_ += tree(c)
    return out_

def kib(pid, f, key):
    try:
        for line in Path(f"/proc/{pid}/{f}").read_text().splitlines():
            if line.startswith(key): return int(line.split()[1])
    except Exception: pass
    return 0

pids = [q for p in roots for q in tree(p.pid)]
rss = sum(kib(p, "status", "VmRSS:") for p in pids)
pss = sum(kib(p, "smaps_rollup", "Pss:") for p in pids)
pd = sum(kib(p, "smaps_rollup", "Private_Dirty:") for p in pids)
threads = sum(kib(p, "status", "Threads:") for p in pids)
fds = 0
for p in pids:
    try: fds += len(os.listdir(f"/proc/{p}/fd"))
    except Exception: pass
comms = {}
for p in pids:
    try: c = Path(f"/proc/{p}/comm").read_text().strip(); comms[c] = comms.get(c, 0) + 1
    except Exception: pass
alive = sum(p.poll() is None for p in roots)
def established():
    # server-side sockets on the fixture port in ESTABLISHED state (st == 01)
    c = 0
    for f in ("/proc/net/tcp", "/proc/net/tcp6"):
        try:
            for line in open(f).readlines()[1:]:
                parts = line.split()
                if int(parts[1].split(":")[1], 16) == port and parts[3] == "01": c += 1
        except Exception: pass
    return c
open_conns = established()
with lock:
    ok = ok_agents(); reqs_tok = sum(len(v) for v in held.values()); reqs_other = len(other)
print(json.dumps({"tool": tool, "agents": n, "launched": launched, "held_ok": ok, "failed": n - ok, "token_requests": reqs_tok,
                  "untokened_requests": reqs_other, "roots_alive": alive, "open_fixture_conns": open_conns, "processes": len(pids), "comm": comms, "threads": threads, "fds": fds,
                  "rss_mib": round(rss / 1024, 1), "pss_mib": round(pss / 1024, 1), "pd_kib": pd, "pss_per_agent_kib": round(pss / max(n, 1)),
                  "secs_to_hold": round(t_held, 1), "aborted": aborted}))
sys.stdout.flush()
for p in pids:
    try: os.kill(p, signal.SIGKILL)
    except Exception: pass
os._exit(0)
