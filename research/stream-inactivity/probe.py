#!/usr/bin/env python3
"""Throwaway timing probe; no response content or credentials are written."""
import argparse
import http.client
import json
import signal
import time
from datetime import datetime, timezone
from pathlib import Path


class EventNames:
    """Keep only a short SSE line prefix, discarding data as it arrives."""
    def __init__(self):
        self.prefix = bytearray()
        self.event = None
        self.terminal = None

    def feed(self, chunk):
        for byte in chunk:
            if byte == 10:
                line = bytes(self.prefix).rstrip(b"\r")
                if line.startswith(b"event:"):
                    name = line[6:].strip()
                    self.event = name if name in (
                        b"response.completed", b"response.failed", b"response.incomplete", b"error"
                    ) else None
                elif not line:
                    if self.event:
                        self.terminal = self.event.decode("ascii")
                    self.event = None
                self.prefix.clear()
            elif len(self.prefix) < 80:
                self.prefix.append(byte)


def measure(connection, path, body, headers, emit):
    start = time.monotonic()
    previous = None
    first = None
    largest = 0.0
    total = count = 0
    status = None
    content_type = None
    events = EventNames()
    outcome = "eof_without_terminal"
    emit({"kind": "start", "utc": datetime.now(timezone.utc).isoformat()})
    try:
        connection.request("POST", path, body=body, headers=headers)
        response = connection.getresponse()
        status = response.status
        content_type = response.getheader("Content-Type", "")
        emit({"kind": "headers", "elapsed_s": time.monotonic() - start, "http_status": status,
              "content_type": content_type})
        if status != 200:
            outcome = "http_rejection"
        elif content_type and content_type.split(";", 1)[0].strip().lower() != "text/event-stream":
            outcome = "unexpected_content_type"
        else:
            while True:
                chunk = response.read1(65536)
                now = time.monotonic()
                if not chunk:
                    break
                gap = now - (previous if previous is not None else start)
                if first is None:
                    first = now - start
                else:
                    largest = max(largest, gap)
                previous = now
                count += 1
                total += len(chunk)
                emit({"kind": "chunk", "elapsed_s": now - start, "gap_s": gap, "bytes": len(chunk)})
                events.feed(chunk)
                if events.terminal:
                    outcome = events.terminal
                    break
    except Exception as exc:
        # Exception messages and response bodies can contain private material.
        outcome = type(exc).__name__
    finally:
        connection.close()
    summary = {
        "kind": "summary", "http_status": status, "content_type": content_type, "outcome": outcome,
        "duration_s": time.monotonic() - start, "first_body_chunk_s": first,
        "largest_between_body_chunks_s": largest if count > 1 else None,
        "chunks": count, "bytes": total,
        "terminal_event": events.terminal,
    }
    emit(summary)
    return summary


PROMPTS = {
    "short": "Reply with exactly: timing probe complete.",
    "reasoning": "Find the smallest positive integer n such that n mod 17 = 3, n mod 19 = 7, and n mod 23 = 11. Verify your answer and give a concise explanation. Do not use tools.",
    "longer": "Explain why Dijkstra's shortest-path algorithm requires nonnegative edge weights. Include a precise invariant, proof, a small counterexample with a negative edge, and a comparison with Bellman-Ford. Use about 1000 words. Do not use tools.",
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live", action="store_true", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--case", choices=PROMPTS, required=True)
    parser.add_argument("--effort", default="high")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    # Read existing credentials in memory, with no refresh or account changes.
    tokens = json.loads((Path.home() / ".codex/auth.json").read_text())["tokens"]
    headers = {
        "Authorization": "Bearer " + tokens["access_token"],
        "ChatGPT-Account-Id": tokens["account_id"],
        "Originator": "onepage", "Accept": "text/event-stream",
        "Content-Type": "application/json", "Accept-Encoding": "identity",
        "OpenAI-Beta": "responses=experimental",
    }
    body = json.dumps({
        "model": args.model, "instructions": "Answer the synthetic timing exercise. No tools are available.",
        "input": [{"role": "user", "content": [{"type": "input_text", "text": PROMPTS[args.case]}]}],
        "reasoning": {"effort": args.effort}, "store": False, "stream": True,
    }).encode()
    # Experiment backstops, not proposed product limits. No automatic retries.
    def deadline(_signum, _frame):
        raise TimeoutError("experiment lifetime")
    signal.signal(signal.SIGALRM, deadline)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("x") as output:
        def emit(row):
            output.write(json.dumps(row, separators=(",", ":")) + "\n")
            output.flush()
        emit({"kind": "experiment", "model": args.model, "case": args.case,
              "effort": args.effort, "receive_timeout_s": 300, "lifetime_s": 900,
              "transport": "python-http.client-HTTP1.1-SSE"})
        signal.alarm(900)
        try:
            summary = measure(http.client.HTTPSConnection("chatgpt.com", timeout=300),
                              "/backend-api/codex/responses", body, headers, emit)
        finally:
            signal.alarm(0)
    print(json.dumps(summary))


if __name__ == "__main__":
    main()
