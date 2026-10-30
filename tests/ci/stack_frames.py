#!/usr/bin/env python3
"""Fail when a Host thread can reach a stack frame over the budget.

ReleaseSafe probes every page of a frame on entry, so a big frame stays resident
for the life of the thread that ran it. This reads the frames of a ReleaseSafe
x86-64 Linux binary from its disassembly and walks the direct-call graph from
each Host stack: the main thread from server.serve, and every thread whose entry
a reachable function passes to spawn. Calls through function pointers and the
std.Io vtable leave no direct call, so every function of a module named in
host_modules is walked as well. The walk stops at the panic handlers, which run
only as the thread dies.

stack_frames.json holds the budget, each Host thread's anchor and chain ceiling,
the Host modules, and shrink-only exceptions. An exception's frame_bytes and a
thread's chain_ceiling are ceilings in whole pages, the unit the probe makes
resident, so CPU-model noise of a few bytes moves no verdict. A frame or chain
past its ceiling fails, and one a whole page under it must lower it. An
exception whose frame fits the budget or is gone must be deleted. Names drop
Zig's __func_N/__struct_N/__union_N suffixes so they survive rebuilds.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[2]
POLICY = Path(__file__).with_name("stack_frames.json")
MAIN_ROOT = "server.serve"
PAGE = 4096
# The probe helper walks its caller's frame; its own loop is not a frame.
PROBE = "__zig_probe_stack"
# The prologue sets the frame within this many instructions.
PROLOGUE_LINES = 40
HEADER = re.compile(r"^[0-9a-f]+ <(.+)>:$")
PROBE_SIZE = re.compile(r"\bmov\s+\$0x([0-9a-f]+),%[er]ax$")
SUB_SIZE = re.compile(r"\bsub\s+\$0x([0-9a-f]+),%rsp$")
CALL = re.compile(r"\b(?:call|jmp)\s+[0-9a-f]+ <([^>+]+)>$")
# std.Thread.spawn's entry, referenced by address where a thread starts.
SPAWN = re.compile(r"# [0-9a-f]+ <([^>+]+\.entryFn)>$")
GENERATED = re.compile(r"__(?:func|struct|union)_\d+")
# std.debug's panic entry points and the handlers they dispatch to.
PANIC = re.compile(r"^debug\.(?:FullPanic|defaultPanic|panic|panicExtra)\b")


def normalize(name):
    return GENERATED.sub("", name)


def ceiling(frame):
    return -(-frame // PAGE) * PAGE


def skipped(name):
    return name == PROBE or PANIC.match(normalize(name)) is not None


def parse(disassembly):
    """{raw name: {"frame": bytes, "calls": set, "spawns": set}} from objdump -d."""
    functions = {}
    current = None
    for line in disassembly.splitlines():
        header = HEADER.match(line)
        if header:
            name = header.group(1)
            current = functions.setdefault(name, {"frame": 0, "calls": set(), "spawns": set()})
            lines, probe, framed = 0, None, False
            continue
        if current is None:
            continue
        lines += 1
        if not framed and lines <= PROLOGUE_LINES:
            if match := PROBE_SIZE.search(line):
                probe = int(match.group(1), 16)
            elif f"<{PROBE}>" in line and probe is not None:
                current["frame"], framed = probe, True
            elif match := SUB_SIZE.search(line):
                current["frame"], framed = int(match.group(1), 16), True
        if match := CALL.search(line):
            if match.group(1) != name:
                current["calls"].add(match.group(1))
        elif match := SPAWN.search(line):
            current["spawns"].add(match.group(1))
    return functions


def walk(functions, *roots):
    """Each function reachable from roots by direct calls, with a call path to it."""
    paths = {root: (root,) for root in roots}
    pending = list(roots)
    while pending:
        caller = pending.pop(0)
        for callee in sorted(functions[caller]["calls"]):
            if callee in functions and callee not in paths and not skipped(callee):
                paths[callee] = paths[caller] + (callee,)
                pending.append(callee)
    return paths


def host_roots(functions, threads):
    """{entry: label}: server.serve, then each thread a Host stack spawns.

    threads maps a label to its anchor, a function only that thread reaches; the
    main thread's anchor is server.serve itself. A spawned thread that no anchor
    names is a new Host stack the policy must name.
    """
    if MAIN_ROOT not in functions:
        raise ValueError(f"Host root {MAIN_ROOT} is not in the binary")
    main = [label for label, spec in threads.items() if spec["anchor"] == MAIN_ROOT]
    if len(main) != 1:
        raise ValueError(f"name the main thread by the anchor {MAIN_ROOT} exactly once in stack_frames.json threads")
    spawned = {label: spec["anchor"] for label, spec in threads.items() if label != main[0]}
    roots = {MAIN_ROOT: main[0]}
    pending = [MAIN_ROOT]
    while pending:
        for function in walk(functions, pending.pop(0)):
            for entry in sorted(functions[function]["spawns"] & functions.keys() - roots.keys()):
                reached = {normalize(name) for name in walk(functions, entry)}
                labels = [label for label, anchor in spawned.items() if anchor in reached]
                if len(labels) != 1:
                    raise ValueError(f"the thread {normalize(function)} spawns reaches anchors {labels}; "
                                     "name each Host thread by exactly one anchor in stack_frames.json threads")
                roots[entry] = labels[0]
                pending.append(entry)
    missing = sorted(set(threads) - set(roots.values()))
    if missing:
        raise ValueError(f"no Host thread reaches the anchor of {missing}; update stack_frames.json threads")
    return roots


def key(name, roots):
    # Every thread entry normalizes to one std name; its label tells them apart.
    return f"{normalize(name)} ({roots[name]})" if name in roots and name != MAIN_ROOT else normalize(name)


def module_functions(functions, modules):
    """Every function defined in one of modules, named by its Zig namespace."""
    found = {module: [name for name in functions if normalize(name).startswith(module + ".")] for module in modules}
    missing = sorted(module for module, names in found.items() if not names)
    if missing:
        raise ValueError(f"no function of host_modules {missing} is in the binary; update stack_frames.json host_modules")
    return sorted({name for names in found.values() for name in names if not skipped(name)})


def cycles(callees):
    """{name: members of its recursive cycle} for each function on a call cycle."""
    index, low, stack, on_stack, members = {}, {}, [], set(), {}
    for start in callees:
        if start in index:
            continue
        index[start] = low[start] = len(index)
        stack.append(start)
        on_stack.add(start)
        work = [(start, iter(callees[start]))]
        while work:
            name, pending = work[-1]
            for callee in pending:
                if callee not in index:
                    index[callee] = low[callee] = len(index)
                    stack.append(callee)
                    on_stack.add(callee)
                    work.append((callee, iter(callees[callee])))
                    break
                if callee in on_stack:
                    low[name] = min(low[name], index[callee])
            else:
                work.pop()
                if work:
                    low[work[-1][0]] = min(low[work[-1][0]], low[name])
                if low[name] == index[name]:
                    component = []
                    while not component or component[-1] != name:
                        component.append(stack.pop())
                        on_stack.discard(component[-1])
                    if len(component) > 1:
                        members.update(dict.fromkeys(component, frozenset(component)))
    return members


def deepest(functions, roots):
    """{root: (total bytes, chain)}: each root's heaviest chain of distinct functions.

    A function on a recursive cycle can call back into the cycle members already
    on the chain, so its heaviest chain depends on which of them are; it is
    memoized under that set. Any other function's heaviest chain is the same
    wherever the walk reaches it.
    """
    sys.setrecursionlimit(max(sys.getrecursionlimit(), 20000))
    callees = {name: sorted(callee for callee in function["calls"] if callee in functions and not skipped(callee))
               for name, function in functions.items()}
    cycle = cycles(callees)
    memo, active = {}, set()

    def depth(name):
        members = cycle.get(name)
        state = (name, frozenset(active & members)) if members else name
        if state in memo:
            return memo[state]
        active.add(name)
        below = max((depth(callee) for callee in callees[name] if callee not in active), default=(0, ()))
        active.discard(name)
        memo[state] = functions[name]["frame"] + below[0], (name,) + below[1]
        return memo[state]

    return {root: depth(root) for root in roots}


def check(functions, policy):
    """(report lines, failures) for the Host stacks in functions under policy."""
    budget = policy["budget_bytes"]
    exceptions = {entry["function"]: entry["frame_bytes"] for entry in policy["exceptions"]}
    threads = policy["threads"]
    roots = host_roots(functions, threads)
    report, failures = [], []
    # Name -> (largest reachable frame of that name, call path to it).
    frames = {}
    chains = deepest(functions, roots)
    for entry, label in roots.items():
        total, chain = chains[entry]
        allowed = threads[label]["chain_ceiling"]
        report.append(f"{label} ({entry}): deepest chain {total} bytes ({total // 1024} KiB), ceiling {allowed}")
        report.extend(f"  {functions[name]['frame']:>8} {key(name, roots)}" for name in chain)
        if total > allowed:
            failures.append(f"{label}: deepest chain grew to {total} bytes, past its {allowed}-byte chain_ceiling")
        elif allowed - total >= PAGE:
            failures.append(f"{label}: deepest chain shrank to {total} bytes; lower its chain_ceiling "
                            f"from {allowed} to {ceiling(total)} in stack_frames.json")
    walks = [walk(functions, entry) for entry in roots]
    walks.append(walk(functions, *module_functions(functions, policy["host_modules"])))
    for paths in walks:
        for name, path in paths.items():
            frame = functions[name]["frame"]
            if frame > frames.get(key(name, roots), (-1,))[0]:
                frames[key(name, roots)] = frame, path
    for name, (frame, path) in sorted(frames.items(), key=lambda item: (-item[1][0], item[0])):
        if frame <= budget:
            break
        allowed = exceptions.get(name)
        via = " > ".join(key(step, roots) for step in path)
        if allowed is None:
            failures.append(f"{name}: frame {frame} bytes exceeds the {budget}-byte budget (via {via}). "
                            "Give big values one address their owner provides instead of a stack slot.")
        elif frame > allowed:
            failures.append(f"{name}: frame grew to {frame} bytes, past its {allowed}-byte exception (via {via})")
        elif allowed - frame >= PAGE:
            failures.append(f"{name}: frame shrank to {frame} bytes; lower its frame_bytes "
                            f"from {allowed} to {ceiling(frame)} in stack_frames.json")
    for name in exceptions:
        if frames.get(name, (0,))[0] <= budget:
            state = f"now fits ({frames[name][0]} bytes)" if name in frames else "is no longer reachable"
            failures.append(f"{name}: {state}; delete this exception from stack_frames.json")
    return report, failures


def git(root, *args):
    result = subprocess.run(["git", "-C", str(root), *args], text=True, capture_output=True)
    if result.returncode:
        raise ValueError("stack frame allowance requires complete trusted Git history: " + result.stderr.strip())
    return result.stdout.strip()


def allowance_growth(root=ROOT, policy_path=POLICY):
    """Allowances that grew since the trusted review base; empty when none did."""
    review_base = git(root, "merge-base", "HEAD", "origin/main")
    name = policy_path.resolve().relative_to(root.resolve()).as_posix()
    if not git(root, "ls-tree", "--name-only", review_base, "--", name):
        # First introduction: the reviewed seed is the allowance.
        return []
    trusted = json.loads(git(root, "show", f"{review_base}:{name}"))
    policy = json.loads(policy_path.read_text())
    grown = []
    if policy["budget_bytes"] > trusted["budget_bytes"]:
        grown.append(f"budget_bytes {policy['budget_bytes']} exceeds the trusted {trusted['budget_bytes']}")
    before = {entry["function"]: entry["frame_bytes"] for entry in trusted["exceptions"]}
    for entry in policy["exceptions"]:
        if entry["frame_bytes"] > before.get(entry["function"], 0):
            grown.append(f"{entry['function']}: frame_bytes {entry['frame_bytes']} exceeds the trusted "
                         f"{before.get(entry['function'], 'absence')}")
    ceilings = {label: spec["chain_ceiling"] for label, spec in trusted["threads"].items()}
    for label, spec in policy["threads"].items():
        if spec["chain_ceiling"] > ceilings.get(label, 0):
            grown.append(f"{label}: chain_ceiling {spec['chain_ceiling']} exceeds the trusted "
                         f"{ceilings.get(label, 'absence')}")
    return grown


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("binary", type=Path, help="ReleaseSafe x86-64 Linux Rui")
    parser.add_argument("policy", type=Path, nargs="?", default=POLICY)
    args = parser.parse_args()
    disassembly = subprocess.run(["objdump", "-d", "--no-show-raw-insn", "-C", str(args.binary)],
                                 check=True, capture_output=True, text=True).stdout
    try:
        report, failures = check(parse(disassembly), json.loads(args.policy.read_text()))
    except ValueError as error:
        parser.exit(1, f"{error}\n")
    print("\n".join(report))
    if failures:
        parser.exit(1, "Host stack frame gate failed:\n" + "\n".join(f"  {failure}" for failure in failures) + "\n")


if __name__ == "__main__":
    main()
