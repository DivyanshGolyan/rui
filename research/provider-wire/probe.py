#!/usr/bin/env python3
"""Synthetic bounded wire/storage model, never a production adapter or live test."""
import copy
import hashlib
import json
import platform
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
LIMITS = {"bytes": 65536, "items": 32, "depth": 12, "rejection_bytes": 256}

class Rejected(Exception):
    pass

def encode(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"))

def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()

def validate(response):
    try:
        validate_shape(response)
    except (KeyError, TypeError, AttributeError):
        raise Rejected("malformed_provider_output") from None

def validate_shape(response):
    if len(encode(response).encode()) > LIMITS["bytes"]:
        raise Rejected("fixture_limit")
    def depth(value, level=0):
        if level > LIMITS["depth"]:
            raise Rejected("fixture_limit")
        if isinstance(value, dict):
            for child in value.values(): depth(child, level + 1)
        elif isinstance(value, list):
            for child in value: depth(child, level + 1)
    depth(response)
    if response["status"] != "completed":
        raise Rejected("unsupported_provider_output")
    if len(response["output"]) > LIMITS["items"]:
        raise Rejected("fixture_limit")
    for item in response["output"]:
        kind = item["type"]
        if kind not in {"reasoning", "message", "function_call", "compaction"}:
            raise Rejected("unsupported_provider_output")
        if "status" in item and item["status"] != "completed":
            raise Rejected("unsupported_provider_output")
        if item.get("phase") not in (None, "commentary", "final_answer"):
            raise Rejected("unsupported_provider_output")
        metadata = item.get("internal_chat_message_metadata_passthrough", {})
        if any(key in metadata for key in ("cell_id", "executed_tool_calls", "tool_calls_complete")):
            raise Rejected("unsupported_provider_output")
        if kind == "message":
            if item.get("role") != "assistant": raise Rejected("unsupported_provider_output")
            for block in item["content"]:
                if block["type"] != "output_text": raise Rejected("unsupported_provider_output")
                if not isinstance(block["text"], str): raise Rejected("malformed_provider_output")
                for annotation in block.get("annotations", []):
                    if annotation["type"] not in {"url_citation"}: raise Rejected("unsupported_provider_output")
        if kind == "reasoning":
            if not item.get("encrypted_content"):
                raise Rejected("continuation_unavailable")
            for block in item.get("content", []):
                if block["type"] != "reasoning_text": raise Rejected("unsupported_provider_output")
            for block in item.get("summary", []):
                if block["type"] != "summary_text": raise Rejected("unsupported_provider_output")
        if kind == "function_call":
            if item["name"] not in {"Bash", "Edit"} or item.get("namespace") or item.get("async") or item.get("encrypted_function_args") or item.get("caller", {}).get("type", "direct") != "direct":
                raise Rejected("unsupported_provider_output")

def replay(items):
    # Raw provider JSON: exclude documented response-only authorship; preserve open fields.
    result = copy.deepcopy(items)
    for item in result:
        for key in ("created_by",):
            item.pop(key, None)
    return result

def database(path):
    db = sqlite3.connect(path)
    db.executescript("""
    CREATE TABLE IF NOT EXISTS operation(id TEXT PRIMARY KEY, requested TEXT, served TEXT,
      correlation TEXT, request_id TEXT, wire TEXT, hash TEXT, covered INTEGER);
    CREATE TABLE IF NOT EXISTS projection(operation_id TEXT, ordinal INTEGER);
    CREATE TABLE IF NOT EXISTS rejection(operation_id TEXT, code TEXT);
    """)
    return db

def accept(db, key, response, covered=None):
    try:
        validate(response)
        if covered is not None:
            compactions = [i for i in response["output"] if i["type"] == "compaction"]
            if len(compactions) != 1 or not compactions[0].get("encrypted_content") or any(i["type"] == "function_call" for i in response["output"]):
                raise Rejected("unsupported_provider_output")
    except Rejected as error:
        evidence = {"operation_id": key, "code": str(error)}
        assert len(encode(evidence).encode()) <= LIMITS["rejection_bytes"]
        with db: db.execute("INSERT INTO rejection VALUES (?, ?)", (key, str(error)))
        return False
    wire = encode(response["output"])
    with db:
        db.execute("INSERT INTO operation VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (key, response["requested_model"], response["model"], response["id"], response.get("request_id"), wire, digest(wire), covered))
        for index, item in enumerate(response["output"]):
            if item["type"] == "message" and covered is None:
                db.execute("INSERT INTO projection VALUES (?, ?)", (key, index))
    return True

def load(db, key, requested):
    row = db.execute("SELECT requested, wire, hash FROM operation WHERE id=?", (key,)).fetchone()
    if row is None or row[0] != requested or digest(row[1]) != row[2]:
        raise Rejected("continuation_unavailable")
    return json.loads(row[1])

def complete_suffix(entries, frontier, last):
    if [index for index, _ in entries] != list(range(frontier + 1, last + 1)):
        raise Rejected("continuation_unavailable")
    return [value for _, value in entries]

def generic_read(db, key, ordinal):
    row = db.execute("SELECT ordinal FROM projection WHERE operation_id=? AND ordinal=?", (key, ordinal)).fetchone()
    if row is None: raise Rejected("private_or_absent")
    wire = db.execute("SELECT wire FROM operation WHERE id=?", (key,)).fetchone()[0]
    return "".join(block["text"] for block in json.loads(wire)[ordinal]["content"])

def reopen(path):
    db = database(path)
    result = {"replay": replay(load(db, "answer", "synthetic-model-a")), "identity": db.execute("SELECT requested, served, correlation, request_id FROM operation WHERE id='answer'").fetchone()}
    db.close()
    return result

def run():
    fixture = json.loads((HERE / "fixtures.json").read_text())
    passed = []
    with tempfile.TemporaryDirectory(prefix="onepage-wire-") as tmp:
        path = str(Path(tmp) / "model.sqlite")
        db = database(path)
        assert accept(db, "answer", fixture["response"])
        assert replay(load(db, "answer", "synthetic-model-a")) == fixture["expected_replay"]
        passed.append("ordered_exact_golden_replay_and_nested_open_fields")
        assert replay(load(db, "answer", "synthetic-model-a")) + [fixture["tool_result"]] == fixture["expected_tool_loop_replay"]
        assert fixture["tool_result"]["call_id"] == fixture["response"]["output"][2]["call_id"]
        passed.append("synthetic_tool_result_exact_call_id_and_output_golden")
        for index, encrypted in enumerate((None, "")):
            missing_private = copy.deepcopy(fixture["response"])
            if encrypted is None: del missing_private["output"][0]["encrypted_content"]
            else: missing_private["output"][0]["encrypted_content"] = encrypted
            key = "missing-private-" + str(index)
            assert not accept(db, key, missing_private)
            assert db.execute("SELECT code FROM rejection WHERE operation_id=?", (key,)).fetchone()[0] == "continuation_unavailable"
        passed.append("missing_private_continuation_fails_closed")
        result = subprocess.run([sys.executable, str(Path(__file__).resolve()), "--reopen", path], check=True, capture_output=True, text=True)
        reopened = json.loads(result.stdout)
        assert reopened["replay"] == fixture["expected_replay"]
        assert reopened["identity"] == ["synthetic-model-a", "synthetic-model-a-snapshot", "synthetic-response-1", "synthetic-request-1"]
        passed.append("fresh_process_sqlite_reopen_identical_replay")
        assert db.execute("SELECT requested, served, correlation FROM operation WHERE id='answer'").fetchone() == ("synthetic-model-a", "synthetic-model-a-snapshot", "synthetic-response-1")
        passed.append("requested_served_correlation_preserved")
        for ordinal in (0,):
            try: generic_read(db, "answer", ordinal)
            except Rejected: pass
            else: raise AssertionError("private item exposed")
        assert generic_read(db, "answer", 1) == "Hello."
        passed.append("toy_generic_read_excludes_private_items")
        mutations = [lambda r: r.update(status="future_terminal"),
            lambda r: r["output"].append({"type": "future_item"}),
            lambda r: r["output"][1]["content"].append({"type": "future_block"}),
            lambda r: r["output"].append({"type": "function_call", "name": "FutureAction"}),
            lambda r: r["output"].append({"type": "future_compaction"}),
            lambda r: r["output"][0]["summary"].append({"type": "future_summary"}),
            lambda r: r["output"][1].update(phase="future_phase"),
            lambda r: r["output"][0].update(content=[{"type": "future_reasoning"}]),
            lambda r: r["output"][1]["content"][0]["annotations"].append({"type": "future_annotation"}),
            lambda r: r["output"][1].update(internal_chat_message_metadata_passthrough={"cell_id":"forged"}),
            lambda r: r["output"][1].update(internal_chat_message_metadata_passthrough={"executed_tool_calls":[]}),
            lambda r: r["output"][1].update(internal_chat_message_metadata_passthrough={"tool_calls_complete":True})]
        for n, mutate in enumerate(mutations):
            response = copy.deepcopy(fixture["response"])
            mutate(response)
            key = "reject-" + str(n)
            assert not accept(db, key, response)
            assert db.execute("SELECT count(*) FROM operation WHERE id=?", (key,)).fetchone()[0] == 0
            assert db.execute("SELECT count(*) FROM projection WHERE operation_id=?", (key,)).fetchone()[0] == 0
        passed.append("twelve_unknown_discriminator_or_host_authority_atomic_rejections")
        malformed = copy.deepcopy(fixture["response"])
        del malformed["output"][1]["content"][0]["text"]
        assert not accept(db, "malformed", malformed)
        assert db.execute("SELECT code FROM rejection WHERE operation_id='malformed'").fetchone()[0] == "malformed_provider_output"
        passed.append("missing_required_text_typed_rejection")
        for key, requested in (("missing", "synthetic-model-a"), ("answer", "synthetic-model-b")):
            try: load(db, key, requested)
            except Rejected as error: assert str(error) == "continuation_unavailable"
            else: raise AssertionError("invalid continuation accepted")
        with db: db.execute("UPDATE operation SET wire=wire || ' ' WHERE id='answer'")
        try: load(db, "answer", "synthetic-model-a")
        except Rejected as error: assert str(error) == "continuation_unavailable"
        else: raise AssertionError("corruption accepted")
        passed.append("missing_corrupt_and_unproved_model_change_fail_closed")
        assert accept(db, "compact", fixture["compaction_response"], covered=3)
        items = load(db, "compact", "synthetic-model-a")
        compact_index = next(i for i, item in enumerate(items) if item["type"] == "compaction")
        suffix = complete_suffix(list(enumerate(fixture["suffix"], start=4)), 3, 5)
        retained = fixture["retained_host_input"]
        assert [entry["source_ref"] for entry in retained] == fixture["expected_retained_source_refs"]
        assert [entry["item"] for entry in retained] + replay(items[compact_index:]) + suffix == fixture["expected_compacted_replay"]
        try: complete_suffix([(5, fixture["suffix"][1])], 3, 5)
        except Rejected: pass
        else: raise AssertionError("incomplete suffix accepted")
        assert db.execute("SELECT covered FROM operation WHERE id='compact'").fetchone()[0] == 3
        try: generic_read(db, "compact", compact_index)
        except Rejected: pass
        else: raise AssertionError("private compaction exposed")
        passed.append("retained_host_refs_then_response_owned_compaction_and_complete_suffix")
        for n, mode in enumerate(("empty", "duplicate", "effect")):
            bad = copy.deepcopy(fixture["compaction_response"])
            if mode == "empty": bad["output"][1]["encrypted_content"] = ""
            elif mode == "duplicate": bad["output"].append(copy.deepcopy(bad["output"][1]))
            else: bad["output"].append(copy.deepcopy(fixture["response"]["output"][2]))
            assert not accept(db, "bad-compact-" + str(n), bad, covered=3)
        assert db.execute("SELECT count(*) FROM projection WHERE operation_id='compact'").fetchone()[0] == 0
        passed.append("empty_duplicate_or_effectful_compaction_rejected_no_projection")
        for n, mode in enumerate(("bytes", "items", "depth")):
            bad = copy.deepcopy(fixture["response"])
            if mode == "bytes": bad["padding"] = "x" * LIMITS["bytes"]
            elif mode == "items": bad["output"] *= LIMITS["items"]
            else:
                value = "leaf"
                for _ in range(LIMITS["depth"] + 1): value = [value]
                bad["padding"] = value
            assert not accept(db, "bounded-" + str(n), bad)
        passed.append("synthetic_byte_count_depth_limits_fail_explicitly")
        assert set(row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")) == {"operation", "projection", "rejection"}
        passed.append("no_stored_replay_request_or_checkpoint_copy")
        db.close()
    result = {"schema": 1, "kind": "synthetic_deterministic_fixture", "passed": passed,
        "fixture_limits_not_product_limits": LIMITS,
        "environment": {"python": platform.python_version(), "sqlite": sqlite3.sqlite_version, "platform": platform.platform(), "base_revision": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()},
        "sha256": {name: hashlib.sha256((HERE / name).read_bytes()).hexdigest() for name in ("probe.py", "fixtures.json")},
        "limitations": ["No provider calls, credentials, real encrypted payloads, or compatibility proof.",
          "Toy SQLite graceful subprocess reopen, not production restart, crash or power-loss qualification.",
          "Toy projection access check, not production storage/privacy integration.",
          "Bounded in-memory synthetic JSON; not production streaming or resource qualification."]}
    (HERE / "results.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))

if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--reopen": print(encode(reopen(sys.argv[2])))
    else: run()
