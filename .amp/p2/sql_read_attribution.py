#!/usr/bin/env python3
"""Attribute existing first-execution SQL text, without another workload capture."""
import gzip
import hashlib
import json
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent
# These prefixes identify complete statement texts at their baseline owner.
# A statement may also run during admission: classification is not a phase clock.
OWNERS = (
    ("SELECT turn_id,attempt_ordinal,interrupted_by_command_key FROM model_operation", "control_reconciliation", "src/store.zig:5610; src/server.zig:1769; src/execution_turn.zig:37"),
    ("SELECT action_id,parent_operation_id FROM action_operation INDEXED BY action_operation_unresolved_attempt", "uncertain_action_recovery", "src/store.zig:4579; src/execution_turn.zig:60"),
    ("SELECT turn_id,operation_id FROM model_operation INDEXED BY model_operation_retry_exhausted", "exhausted_retry_recovery", "src/store.zig:5785; src/execution_turn.zig:64"),
    ("SELECT action.action_id,action.parent_operation_id,operation.turn_id,action.bash_timeout_override_ms", "bash_admission_probe", "src/store.zig:4352; src/execution_turn.zig:74"),
    ("SELECT 1 FROM message_admission m INDEXED BY message_admission_pending", "message_admission_probe", "src/store.zig:74,5034; src/execution_turn.zig:79"),
    ("SELECT active.session_ref,active.first_admission_id,input_cutoff", "tool_continuation_probe", "src/store.zig:90,5034; src/execution_turn.zig:80"),
    ("SELECT active.session_ref,active.first_admission_id,active.input_cutoff", "tool_continuation_probe", "src/store.zig:90,5034; src/execution_turn.zig:80"),
    ("SELECT operation.operation_id FROM turn active JOIN model_operation operation ON operation.operation_id=active.operation_id WHERE active.outcome_code IS NULL", "blocked_tool_validation", "src/store.zig:5053; src/store.zig:5043"),
    ("SELECT turn_id,operation_id,attempt_ordinal,allowance_used,retry_due_at_ms FROM model_operation INDEXED BY model_operation_retry_due", "retry_admission_probe", "src/store.zig:4957,106; src/execution_turn.zig:78"),
    ("SELECT CAST(unixepoch('subsec') * 1000 AS INTEGER)", "retry_clock", "src/store.zig:7369,4959; also retry settlement"),
)


def owner(sql):
    matches = [(name, site) for prefix, name, site in OWNERS if sql.startswith(prefix)]
    assert len(matches) <= 1, (sql, matches)
    return matches[0] if matches else ("other_work_or_observation", "not uniquely assigned")


def reduce(path, messages):
    text = gzip.decompress(path.read_bytes()).decode()
    statements = [line.removeprefix("P2_SQL\t").strip() for line in text.splitlines() if line.startswith("P2_SQL\t")]
    assert "P2_SQL_REGISTRATION_FAILED" not in text
    selects = Counter(sql for sql in statements if sql.startswith("SELECT "))
    groups = Counter()
    rows = []
    for sql, count in selects.most_common():
        group, site = owner(sql)
        groups[group] += count
        rows.append({"count": count, "per_message": count / messages, "owner": group, "source": site, "sql": sql})
    assert sum(groups.values()) == sum(selects.values())
    return {"source": str(path.relative_to(ROOT)), "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "instrumented_counts_only": True, "messages": messages,
            "first_executions": len(statements), "select_first_executions": sum(selects.values()),
            "select_percent": 100 * sum(selects.values()) / len(statements),
            "select_groups": dict(groups), "select_texts": rows,
            "limits": "First executions, not completion or commit success; whole-run scope. Poll-capable owners also run during actual work. Existing traces have no phase clock; no exact historical idle/work split inferred."}


if __name__ == "__main__":
    print(json.dumps([reduce(ROOT / "raw" / f"sql{n}-host.log.gz", 2 * n) for n in (1, 100)], indent=2))
