#!/usr/bin/env python3
"""P1b: is "top-level tools empty, first declaration at the head of the span" (D75) safe?
Checks: head-declared function callable; hosted web_search declared in additional_tools works;
a later re-declaration (reword) of the same name is accepted; cache still hits after each."""
import json, os, sys, time, urllib.request, urllib.error
BASE = os.environ.get("OPENAI_BASE_URL", "https://api.openai.com/v1").rstrip("/")
KEY = os.environ["OPENAI_API_KEY"]; MODEL = sys.argv[1] if len(sys.argv) > 1 else "gpt-6.1-sol"
FILLER = " ".join(f"Rule {i}: answer briefly and never invent facts about item {i}." for i in range(260))
INSTR = "You are a terse test assistant. " + FILLER
def fn(name, desc): return {"type": "function", "name": name, "description": desc,
    "parameters": {"type": "object", "properties": {"cmd": {"type": "string"}}, "required": ["cmd"], "additionalProperties": False}}
BASH = fn("bash", "Run a shell command.")
BASH2 = fn("bash", "Run a shell command. Always pass cmd exactly as the user typed it.")
WEB = {"type": "web_search", "external_web_access": True}
raw = []
def post(body):
    req = urllib.request.Request(BASE + "/responses", data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {KEY}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=300) as r: out = {"status": r.status, "body": json.load(r)}
    except urllib.error.HTTPError as e: out = {"status": e.code, "body": e.read().decode()[:2000]}
    raw.append({"request": body, "response": out}); return out
def cached(r):
    try: return r["body"]["usage"]["input_tokens_details"]["cached_tokens"], r["body"]["usage"]["input_tokens"]
    except Exception: return None, None
def base(inp): return {"model": MODEL, "instructions": INSTR, "input": inp, "tools": [], "store": False, "reasoning": {"effort": "low"}, "include": ["reasoning.encrypted_content"]}
head = [{"type": "additional_tools", "role": "developer", "tools": [BASH, WEB]}]
u1 = [{"role": "user", "content": "Use the bash tool to run: echo hi"}]
results = []
r1 = post(base(head + u1))
calls = [i for i in r1["body"]["output"] if i.get("type") == "function_call"] if r1["status"] == 200 else []
results.append(("head_function", r1["status"] == 200 and bool(calls), f"HTTP {r1['status']}, bash called: {bool(calls)}" if r1["status"] == 200 else str(r1["body"])[:300]))
# second request: same prefix + call/result, cache should hit
hist = head + u1 + ([i for i in r1["body"]["output"]] if r1["status"] == 200 else [])
for c in calls: hist.append({"type": "function_call_output", "call_id": c["call_id"], "output": "hi"})
time.sleep(2)
r2 = post(base(hist + [{"role": "user", "content": "Thanks. Say ok."}]))
c, t = cached(r2)
results.append(("head_cache", r2["status"] == 200 and (c or 0) > 0, f"HTTP {r2['status']}, cached {c}/{t}" if r2["status"] == 200 else str(r2["body"])[:300]))
# hosted web_search declared only in the head item
r3 = post(base(head + [{"role": "user", "content": "Search the web: what is the latest Zig release? One line."}]))
ws = r3["status"] == 200 and any(i.get("type") == "web_search_call" for i in r3["body"]["output"])
results.append(("head_web_search", ws, f"HTTP {r3['status']}, web_search_call: {ws}" if r3["status"] == 200 else str(r3["body"])[:300]))
# reword: re-declare bash later with new text
reword = hist + [{"role": "user", "content": "Thanks. Say ok."}] + ([i for i in r2["body"]["output"]] if r2["status"] == 200 else []) + \
    [{"type": "additional_tools", "role": "developer", "tools": [BASH2]}, {"role": "user", "content": "Use bash to run: echo again"}]
time.sleep(2)
r4 = post(base(reword))
c, t = cached(r4)
called = r4["status"] == 200 and any(i.get("type") == "function_call" for i in r4["body"]["output"])
results.append(("reword_redeclare", r4["status"] == 200 and called and (c or 0) > 0, f"HTTP {r4['status']}, cached {c}/{t}, bash called: {called}" if r4["status"] == 200 else str(r4["body"])[:300]))
out = os.environ.get("P1B_OUT", os.path.dirname(os.path.abspath(__file__)))
with open(f"{out}/p1b-raw.json", "w") as f: json.dump(raw, f, indent=1)
lines = [f"# P1b probe: {MODEL} at {BASE}", "", f"Run {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}", "", "| Check | Result | Detail |", "|---|---|---|"]
lines += [f"| {n} | {'PASS' if ok else 'FAIL'} | {d} |" for n, ok, d in results]
open(f"{out}/p1b-results.md", "w").write("\n".join(lines) + "\n"); print("\n".join(lines))
