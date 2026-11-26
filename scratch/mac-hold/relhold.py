#!/usr/bin/env python3
"""Standalone held-agent memory sampler for released Rui binaries (Linux).

Own H2 TLS endpoint that accepts every model request and never answers, so
each agent holds one open stream. No repo fixtures, so one harness measures
every release the same way. Samples smaps_rollup + per-mapping groups after a
settle period. No madvise, trim or warmup.

  relhold.py --build LABEL=PATH [--build ...] --out DIR [--cells 100:0,100:100]
             [--reps 3] [--settle 10] [--dump-smaps]
"""
import argparse, concurrent.futures, json, os, pathlib, shutil, socket, ssl, subprocess, sys, tempfile, threading, time
import h2.config, h2.connection, h2.events, h2.settings

ap = argparse.ArgumentParser()
ap.add_argument("--build", action="append", required=True)
ap.add_argument("--out", required=True)
ap.add_argument("--cells", default="100:0,100:100")
ap.add_argument("--reps", type=int, default=3)
ap.add_argument("--settle", type=float, default=10)
ap.add_argument("--workers", type=int, default=8)
ap.add_argument("--dump-smaps", action="store_true")
opts = ap.parse_args()
builds = [tuple(b.split("=", 1)) for b in opts.build]
cells = [tuple(int(x) for x in c.split(":")) for c in opts.cells.split(",")]
out = pathlib.Path(opts.out); out.mkdir(parents=True, exist_ok=True)
results = out / "results.jsonl"


class Endpoint:
    def __init__(self, certfile, keyfile):
        self.ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.ctx.load_cert_chain(certfile, keyfile)
        self.ctx.set_alpn_protocols(["h2"])
        self.sock = socket.create_server(("127.0.0.1", 0), backlog=512)
        self.port = self.sock.getsockname()[1]
        self.lock = threading.Lock()
        self.open_streams = set(); self.requests = 0; self.resets = 0; self.connections = 0; self.closed = 0
        self.stop = False
        threading.Thread(target=self.accept, daemon=True).start()

    def accept(self):
        while not self.stop:
            try:
                raw, addr = self.sock.accept()
            except OSError:
                return
            threading.Thread(target=self.serve, args=(raw, addr), daemon=True).start()

    def serve(self, raw, addr):
        try:
            conn = self.ctx.wrap_socket(raw, server_side=True)
        except Exception:
            raw.close(); return
        with self.lock:
            self.connections += 1
        h = h2.connection.H2Connection(h2.config.H2Configuration(client_side=False, header_encoding="utf-8"))
        h.local_settings[h2.settings.SettingCodes.MAX_CONCURRENT_STREAMS] = 100
        h.initiate_connection()
        mine = set()
        try:
            conn.sendall(h.data_to_send())
            while True:
                data = conn.recv(65536)
                if not data:
                    break
                for ev in h.receive_data(data):
                    if isinstance(ev, h2.events.RequestReceived):
                        with self.lock:
                            self.requests += 1; self.open_streams.add((addr, ev.stream_id))
                        mine.add(ev.stream_id)
                    elif isinstance(ev, h2.events.DataReceived):
                        h.acknowledge_received_data(ev.flow_controlled_length, ev.stream_id)
                    elif isinstance(ev, h2.events.StreamReset):
                        with self.lock:
                            self.resets += 1; self.open_streams.discard((addr, ev.stream_id))
                out_bytes = h.data_to_send()
                if out_bytes:
                    conn.sendall(out_bytes)
        except Exception:
            pass
        finally:
            with self.lock:
                self.closed += 1
                for s in mine:
                    self.open_streams.discard((addr, s))
            try: conn.close()
            except Exception: pass

    def held(self):
        with self.lock:
            return len(self.open_streams)

    def counts(self):
        with self.lock:
            return {"requests": self.requests, "resets": self.resets, "connections": self.connections, "closed": self.closed}

    def close(self):
        self.stop = True
        self.sock.close()


ROLLUP = ("Rss", "Pss", "Private_Dirty", "Private_Clean", "Shared_Clean", "Shared_Dirty", "Anonymous", "Swap")

def rollup(pid):
    v = {}
    for line in open(f"/proc/{pid}/smaps_rollup"):
        p = line.split()
        if len(p) >= 2 and p[0].endswith(":") and p[0][:-1] in ROLLUP:
            v[p[0][:-1]] = int(p[1])
    return v

def stack_pointers(pid):
    sps = {}
    for tid in os.listdir(f"/proc/{pid}/task"):
        try:
            f = open(f"/proc/{pid}/task/{tid}/syscall").read().split()
            name = open(f"/proc/{pid}/task/{tid}/comm").read().strip()
        except OSError:
            continue
        if len(f) >= 3 and f[0] != "running":
            sps[int(f[-2], 16)] = f"{name}"
    return sps

def groups(pid, exe):
    sps = stack_pointers(pid)
    g = {}; maps = []; cur = None; m = None
    for line in open(f"/proc/{pid}/smaps"):
        h = line.split()
        if "-" in h[0] and not h[0].endswith(":"):
            start, end = (int(x, 16) for x in h[0].split("-"))
            perms = h[1]; path = " ".join(h[5:]) if len(h) > 5 else ""
            owner = [n for sp, n in sps.items() if start <= sp < end]
            if path == exe:
                grp = {"r-xp": "binary text", "rw-p": "binary data"}.get(perms, "binary rodata")
            elif path == "[heap]":
                grp = "[heap]"
            elif path == "[stack]" or (not path and owner):
                grp = "stack:" + (owner[0] if owner else "main")
            elif not path or path.startswith("[anon"):
                grp = "other anon"
            else:
                grp = "other files"
            cur = g.setdefault(grp, {k: 0 for k in ("mappings", "Rss", "Private_Dirty", "Anonymous")})
            cur["mappings"] += 1
            m = {"start": start, "size": end - start, "perms": perms, "path": path, "group": grp}
            maps.append(m)
            continue
        k = h[0].rstrip(":")
        if cur is not None and k in ("Rss", "Private_Dirty", "Anonymous"):
            cur[k] += int(h[1]); m[k] = int(h[1])
    return g, maps

def run(rui, *args, input=None):
    c = subprocess.run([rui, *map(str, args)], text=True, input=input, capture_output=True, timeout=30)
    if c.returncode != 0:
        raise AssertionError(f"{args[:2]} -> {c.returncode}: {c.stdout[:200]} {c.stderr[:300]}")
    return json.loads(c.stdout)

def find_session(obj):
    if isinstance(obj, dict):
        for k in ("session", "session_id"):
            if isinstance(obj.get(k), str):
                return obj[k]
        for v in obj.values():
            s = find_session(v)
            if s: return s
    return None

def cell(label, rui, cap, n, rep):
    root = pathlib.Path(tempfile.mkdtemp(prefix=f"rh-{label}-"))
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", root / "key.pem",
                    "-out", root / "cert.pem", "-days", "1", "-subj", "/CN=localhost", "-addext",
                    "subjectAltName=DNS:localhost"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
    ep = Endpoint(root / "cert.pem", root / "key.pem")
    store = root / "store"; rec = root / "records"; rec.mkdir(mode=0o700); ws = root / "ws"; ws.mkdir()
    row = {"build": label, "capacity": cap, "agents": n, "rep": rep, "errors": []}
    env = dict(os.environ, HOME=str(root / "home")); (root / "home").mkdir()
    host = subprocess.Popen([rui, "host", "serve", "--store", str(store), "--active-capacity", str(cap),
                             "--provider-endpoint", f"https://localhost:{ep.port}/responses",
                             "--provider-ca-file", str(root / "cert.pem")], stdout=subprocess.PIPE,
                            stderr=open(root / "host.err", "wb"), env=env, cwd=ws)
    try:
        ready = host.stdout.readline().decode()
        row["ready"] = ready.strip()[:400]
        threading.Thread(target=lambda: host.stdout.read(), daemon=True).start()
        def agent(i):
            r = run(rui, "session", "configure", "--store", store, "--record", rec / f"c{i}.json", "--key", f"c{i}",
                    "--workspace", ws, "--provider", "codex", "--model", "gpt-6-sol", "--tools", "bash",
                    "--permission-mode", "ask")
            s = find_session(r)
            run(rui, "session", "send", "--store", store, "--to", s, "--record", rec / f"m{i}.json", "--key", f"m{i}",
                input=f"hold-{i}")
        t0 = time.monotonic()
        with concurrent.futures.ThreadPoolExecutor(opts.workers) as pool:
            for f in [pool.submit(agent, i) for i in range(n)]:
                try: f.result()
                except Exception as e: row["errors"].append(repr(e)[:400])
        deadline = time.monotonic() + 60
        while ep.held() != n and time.monotonic() < deadline:
            time.sleep(0.2)
        row["start_seconds"] = round(time.monotonic() - t0, 2)
        time.sleep(opts.settle)
        row["held"] = ep.held(); row["alive"] = host.poll() is None; row["fixture"] = ep.counts()
        pid = host.pid; exe = os.readlink(f"/proc/{pid}/exe")
        row["threads"] = len(os.listdir(f"/proc/{pid}/task")); row["fds"] = len(os.listdir(f"/proc/{pid}/fd"))
        row["rollup"] = rollup(pid); row["groups"], maps = groups(pid, exe)
        if opts.dump_smaps:
            d = out / "smaps"; d.mkdir(exist_ok=True)
            shutil.copy(f"/proc/{pid}/smaps", d / f"{label}-c{cap}-n{n}-r{rep}.smaps")
            json.dump(maps, open(d / f"{label}-c{cap}-n{n}-r{rep}.maps.json", "w"))
        if row["held"] != n or not row["alive"]:
            row["errors"].append("held/alive check failed")
    except Exception as e:
        row["errors"].append(repr(e)[:400])
    finally:
        host.terminate()
        try: host.wait(10)
        except Exception: host.kill()
        ep.close()
        if row["errors"]:
            try: row["host_err"] = open(root / "host.err").read()[-500:]
            except Exception: pass
        shutil.rmtree(root, ignore_errors=True)
    with open(results, "a") as f:
        f.write(json.dumps(row) + "\n")
    r = row.get("rollup", {})
    print(f"{label} cap={cap} N={n} rep={rep} held={row.get('held')} thr={row.get('threads')} err={len(row['errors'])} "
          f"PD={r.get('Private_Dirty')} Anon={r.get('Anonymous')} RSS={r.get('Rss')} {row['errors'][:1]}", flush=True)

os.sync()
for rep in range(opts.reps):
    for cap, n in cells:
        for label, rui in builds:
            cell(label, rui, cap, n, rep)
