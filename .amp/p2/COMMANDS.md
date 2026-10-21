# Executed attribution commands

All run from `/home/user/workspace/repo` unless stated. Exact source/binary hashes are in `raw/identity.txt`; initial estimates and controls are in `NOTES.md`. Commands below describe Linux fixtures, not Mac headline qualification. Nonzero/incomplete results remain nonzero/incomplete.

```sh
zig build -Doptimize=ReleaseFast -j2 --summary all
cp zig-out/bin/rui .amp/p2/bin/rui-baseline
GOTOOLCHAIN=local go -C tests/qualification build -mod=readonly -o /home/user/workspace/repo/.amp/p2/bin/model-output ./model-output

# Host-only tracer uses -D so the Host retains the PID the canonical runner owns.
P2_SYSCALL_OUTPUT=/home/user/workspace/repo/.amp/p2/raw/stream1-strace.txt .amp/p2/bin/model-output --capacity 1 --output /home/user/workspace/repo/.amp/p2/raw/stream1-strace.json /home/user/workspace/repo/.amp/p2/bin/rui-strace
P2_DIAGNOSTICS=0 P2_SYSCALL_OUTPUT=/home/user/workspace/repo/.amp/p2/raw/stream1-no-trace-strace.txt .amp/p2/bin/model-output --capacity 1 --output /home/user/workspace/repo/.amp/p2/raw/stream1-no-trace.json /home/user/workspace/repo/.amp/p2/bin/rui-strace
```

Standard tools: Debian linux-perf 6.1.190, strace 6.1, heaptrack 1.4.0. Hardware-counter capability output is retained verbatim. FlameGraph tooling is upstream `brendangregg/FlameGraph` at 41fee1f99f9276008b7cd112fca19dc3ea84ac32. It only post-processes the one requested N=100 on-CPU profile.

Research SQL binary: export baseline with `git archive 240aef2e46d7240ce31a02ce4cefceb695551a56`; apply retained `sql-instrumentation.patch` (one C translation unit and registration in configureSqlite), use copied pinned `zig-pkg`, then `zig build -Doptimize=ReleaseFast -j2 --summary all` from that export. No product settings/durability changes. First build failed due to a dependency-directory symlink; its log remains separate from the corrected second build.
