#!/usr/bin/env python3
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
BASE = os.environ.get("OPENAI_BASE_URL", "https://api.openai.com/v1").rstrip("/")
KEY = os.environ.get("OPENAI_API_KEY")

FILLER = " ".join(f"Rule {i}: answer briefly and never invent facts about item {i}." for i in range(260))
INSTRUCTIONS = "You are a terse test assistant. " + FILLER

BASH = {
    "type": "function",
    "name": "bash",
    "description": "Run a shell command.",
    "parameters": {"type": "object", "properties": {"cmd": {"type": "string"}}, "required": ["cmd"], "additionalProperties": False},
}
CLOCK = {
    "type": "function",
    "name": "read_clock",
    "description": "Return the current time. Call it whenever the user asks for the time.",
    "parameters": {"type": "object", "properties": {}, "additionalProperties": False},
}

raw = []


def post(body):
    request = urllib.request.Request(
        BASE + "/responses",
        data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {KEY}", "Content-Type": "application/json"},
    )
    started = time.time()
    try:
        with urllib.request.urlopen(request, timeout=300) as response:
            out = {"status": response.status, "body": json.loads(response.read())}
    except urllib.error.HTTPError as err:
        text = err.read().decode(errors="replace")
        try:
            parsed = json.loads(text)
        except ValueError:
            parsed = text
        out = {"status": err.code, "body": parsed}
    out["seconds"] = round(time.time() - started, 2)
    raw.append({"request": body, "response": out})
    return out


def cached(response):
    usage = (response["body"] or {}).get("usage") or {}
    return (usage.get("input_tokens_details") or {}).get("cached_tokens", 0), usage.get("input_tokens", 0)


def base(model, effort, tools, items):
    return {
        "model": model,
        "instructions": INSTRUCTIONS,
        "input": items,
        "tools": tools,
        "reasoning": {"effort": effort},
        "store": False,
        "include": ["reasoning.encrypted_content"],
        "prompt_cache_key": "rui-p1-probe",
    }


def user(text):
    return {"type": "message", "role": "user", "content": [{"type": "input_text", "text": text}]}


def replayable(response):
    return [item for item in response["body"].get("output", []) if item.get("type") in ("message", "reasoning", "function_call")]


def error_text(response):
    body = response["body"]
    if isinstance(body, dict) and body.get("error"):
        return json.dumps(body["error"])[:300]
    return f"HTTP {response['status']}"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", default="gpt-6.1-sol")
    parser.add_argument("--effort", default="low")
    parser.add_argument("--changed-effort", default="high")
    args = parser.parse_args()
    if not KEY:
        sys.exit("set OPENAI_API_KEY")
    results = []

    first = [user("Say OK.")]
    warm = post(base(args.model, args.effort, [BASH], first))
    if warm["status"] != 200:
        sys.exit(f"first request failed: {error_text(warm)}")
    post(base(args.model, args.effort, [BASH], first))
    history = first + replayable(warm)

    item = {"type": "configuration_update", "reasoning": {"effort": args.changed_effort}}
    r = post(base(args.model, args.effort, [BASH], history + [item, user("Say OK again.")]))
    hit, total = cached(r)
    results.append(("effort_update", r["status"] == 200 and hit > 0, f"HTTP {r['status']}, cached {hit}/{total}" if r["status"] == 200 else error_text(r)))

    item = {"type": "additional_tools", "role": "developer", "tools": [CLOCK]}
    r = post(base(args.model, args.effort, [BASH], history + [item, user("What time is it? Use the tool.")]))
    hit, total = cached(r)
    called = r["status"] == 200 and any(o.get("type") == "function_call" and o.get("name") == "read_clock" for o in r["body"].get("output", []))
    detail = f"HTTP {r['status']}, cached {hit}/{total}, read_clock called: {called}" if r["status"] == 200 else error_text(r)
    results.append(("additional_tools", r["status"] == 200 and hit > 0 and called, detail))

    removed = [
        user("Run ls."),
        {"type": "function_call", "call_id": "call_p1_removed", "name": "list_files", "arguments": "{}"},
        {"type": "function_call_output", "call_id": "call_p1_removed", "output": "this tool was removed"},
        user("Say OK."),
    ]
    r = post(base(args.model, args.effort, [BASH], history + removed))
    results.append(("removed_tool", r["status"] == 200, f"HTTP {r['status']}" if r["status"] == 200 else error_text(r)))

    r = post(base(args.model, args.effort, [{"type": "web_search"}], [user("Search the web: what is the latest Zig release? One line.")]))
    searched = r["status"] == 200 and any(o.get("type") == "web_search_call" for o in r["body"].get("output", []))
    results.append(("web_search", searched, f"HTTP {r['status']}, web_search_call: {searched}" if r["status"] == 200 else error_text(r)))

    lines = [f"# P1 probe: {args.model} at {BASE}", "", f"Run {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}", "", "| Check | Result | Detail |", "|---|---|---|"]
    lines += [f"| {name} | {'PASS' if ok else 'FAIL'} | {detail} |" for name, ok, detail in results]
    report = "\n".join(lines) + "\n"
    print(report)
    (HERE / "p1-results.md").write_text(report)
    (HERE / "p1-raw.json").write_text(json.dumps(raw, indent=1))
    sys.exit(0 if all(ok for _, ok, _ in results) else 1)


if __name__ == "__main__":
    main()
