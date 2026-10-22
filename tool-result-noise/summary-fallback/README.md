# Summary fallback fix (c149d1b3), review T-01a163d1 P2

Real Host, command `printf 'useful diagnostic B'; printf '\n' >&2; exit 7`, tmux 100x20 TUI.
`repro_tui.sh LABEL BINARY OUT`: live summary, then a fresh `rui session resume` (reopened history).
- bad-*: ReleaseSafe build of 068b1d0c. No output line under the failed heading, live or reopened.
- fixed-*: ReleaseSafe build of c149d1b3's tree. `useful diagnostic B` shows in both.
- *-model-outputs.json: function_call_output bytes are identical before and after.
logs/: selected gates on c149d1b3's tree, all exit 0.
