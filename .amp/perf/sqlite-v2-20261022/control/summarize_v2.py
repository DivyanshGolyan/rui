#!/usr/bin/env python3
"""Aggregate control-v2 per-trial measures by arm, per the predeclared rule (attempts.md)."""
import glob
import json
import math
import statistics as st
import sys

directory = sys.argv[1]
arms = {"baseline": [], "cand2": []}
for path in sorted(glob.glob(f"{directory}/*.trials.jsonl")):
    arm = path.rsplit("-", 1)[1].split(".")[0]
    arms[arm] += [json.loads(line) for line in open(path)]


def q(values, p):
    values = sorted(values)
    return values[min(len(values) - 1, int(p * len(values)))] if values else None


def summary(rows):
    mech = [r["mechanism"] for r in rows if r["mechanism"]]
    out = {"n": len(rows), "trace_missing_rows": sum(1 for r in rows if not r["mechanism"]),
           "unpublished": sum(1 for r in rows if not r["pid_published"])}
    for key in ("m1_host_store_fsyncs", "m1_host_scratch_fsyncs", "m1_host_other_fsyncs"):
        out[key + "_total"] = sum(m[key] for m in mech)
        out[key + "_trials_with_any"] = sum(1 for m in mech if m[key])
    for key in ("m2_jbd2_commits", "m3_host_oncpu_ms", "m4_shell_D_ms", "m4_shell_preempted_ms", "m4_shell_oncpu_ms", "m1_host_fsync_ms", "bash_exec_after_spawn_ms"):
        values = [m[key] for m in mech if m[key] is not None]
        out[key] = {"median": round(st.median(values), 3), "p90": round(q(values, 0.9), 3), "max": round(max(values), 3), "mean": round(st.mean(values), 3)}
    out["trials_with_shell_D_gt_1ms"] = sum(1 for m in mech if m["m4_shell_D_ms"] > 1)
    pub = [r["spawn_to_pid_published_ms"] for r in rows if r.get("spawn_to_pid_published_ms") is not None]
    out["publish_ms"] = {"median": round(st.median(pub), 2), "p90": round(q(pub, 0.9), 2), "max": round(max(pub), 2)} if pub else None
    return out


result = {"all": {arm: summary(rows) for arm, rows in arms.items()},
          "unpublished_only": {arm: summary([r for r in rows if not r["pid_published"]]) for arm, rows in arms.items()}}
b, c = result["all"]["baseline"], result["all"]["cand2"]
pb, pc = b["unpublished"] / b["n"], c["unpublished"] / c["n"]
se = math.sqrt(pb * (1 - pb) / b["n"] + pc * (1 - pc) / c["n"])
result["primary"] = {"baseline_rate": round(pb, 4), "candidate_rate": round(pc, 4), "difference_pp": round(100 * (pc - pb), 2),
                     "wald95_pp": [round(100 * (pc - pb - 1.96 * se), 2), round(100 * (pc - pb + 1.96 * se), 2)]}
print(json.dumps(result, indent=1))
