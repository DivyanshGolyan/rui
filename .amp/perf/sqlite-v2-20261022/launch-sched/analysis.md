# Bash launch delay, rebased: bbabd879 vs SQLite v2 on bbabd879 (2026-10-22)

Arms: base = exact bbabd879db9edb941464a5e358e3d6fb40424a48 (bash -c, old fork spawn); cand = af5ecee8eeb2269d086614de640b44ba4f278f3e
(ref wip/sqlite-v2-on-bbabd879, tree fadb8d10, clean cherry-pick of 2586290c, 100 ms and assertions unchanged).
Both ReleaseFast in this orb (zig 0.17.0); hashes in ../strace-pair-bbabd879/identity.sha256 and identity.sha256 here.
Load: 4 busy loops on 2 vCPU. Command: control/same_group_control_v2.py, 1 trial, timeout_ms=100. Every run published the
PID and resolved timed_out. Order: strace pair base,cand; mem base,cand; perf base,cand; perf+strace base,cand.

## 1. strace-only pair (same method as ../strace-pair)
| | base | cand |
|---|---|---|
| clone entry→return | 0.130 ms | 0.180 ms |
| clone return→child first syscall | 0.100 ms | 12.037 ms |
| first syscall→execve entry | 0.210 ms | 0.221 ms |
| execve (both unfinished/resumed) | 1.202 ms | 1.249 ms |
| clone entry→execve entry | 0.440 ms | 12.438 ms |
Pre-spawn Attempt admission commit: base DELETE journal fsyncs+unlink, ending ~10.4 ms before clone (then 8 journal stat
probes from read-only validation); cand one -wal fsync (0.920 ms) ending 1.95 ms before clone. No COMMIT/fsync between.

## 2. perf from child birth (system-wide sched_*, page_fault_user, raw_syscalls; perf-*.script.txt, analysis.json)
| run | clone dur | clone ret→first syscall | of which runnable | on-CPU | faults before 1st syscall | faults 1st syscall→execve |
|---|---|---|---|---|---|---|
| perf base | 0.142 | 10.784 | 10.770 | 0.015 | 1 | 28 |
| perf cand | 0.175 | 6.599 | 6.586 | 0.014 | 1 | 25 |
| perf+strace base | 0.149 | 17.542 | 17.461 | 0.025 (+0.062 ptrace stop) | 1 | 26 |
| perf+strace cand | 0.146 | 15.400 | 15.354 | 0.018 (+0.035 ptrace stop) | 1 | 26 |
Child pre-exec syscalls identical in all runs: set_robust_list, chdir, dup2 x3, setpgid, execve.
During the runnable interval both CPUs were occupied by the load loops (`sh`), plus perf/python/strace-launcher.
page_fault_user gives counts, not durations; a fault runs on the faulting task's CPU time, so child fault time before the
first syscall is bounded by its on-CPU time (<=0.025 ms). Fork page-table copy happens inside clone (0.13–0.18 ms).

## 3. Host memory just before spawn (held at prepared_before_handoff by --test-before-launch-delay-ms 400; ../launch-mem)
base: VmPTE 88 kB, 36 VMAs, VmRSS 8028 kB (anon 1688, file 6340, shmem 0), VmSize 246668 kB.
cand: VmPTE 88 kB, 36 VMAs, VmRSS 8364 kB (anon 1796, file 6568, shmem 0), VmSize 246720 kB.
In-connection PRAGMA diagnostic (Host's own, via session inspect; no outside reader): both cache_size -1024, mmap_size 0,
temp_store 1; base synchronous 3/journal delete, cand synchronous 2/journal wal. SQLite heap current 430 vs 536 KB.
No file mapping of the Store, -wal or -shm and no /dev/shm mapping in either arm (maps retained in base.json/cand.json).
Build: SQLITE_DEFAULT_MMAP_SIZE 0 in both.

## Findings
- The gap between clone return and the child's first syscall is runnable-but-not-scheduled time in every perf run
  (>=99.8%). The child is on CPU for <=0.025 ms in that interval; fault count before the first syscall is 1 in all runs.
- The candidate-slower direction does not reproduce consistently: strace-only cand +11.9 ms; perf-only cand −4.2 ms;
  perf+strace cand −2.1 ms. Single pairs follow scheduler placement under the load, not the arm.
- v2 did not enlarge page tables, VMAs, mappings, mmap or cache settings before spawn. RSS +336 kB.
## Limits
One launch per arm per observer. perf itself took up to 8 ms of CPU inside one runnable window; strace adds ptrace stops.
The earlier control-v2 +3.5 ms median (600 trials, not predeclared) remains unexplained by mechanism; these pairs show
scheduler wait, not a v2-specific cost. perf.data files (~500 MB) stay in this orb; hashes in perf-data.sha256.
