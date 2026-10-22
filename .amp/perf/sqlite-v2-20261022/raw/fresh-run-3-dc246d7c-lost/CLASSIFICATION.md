# fresh-run-3 on dc246d7c (tree 8143507c): LOST, infrastructure, no result
- Started 14:38:40Z in tmux session `dev` (run.sh). Only `check` started; final.log has no `check EXIT=` line.
- check.log last written 14:50Z; it ends in the build phase (pinned transport). The trailing "failed command" line is the
  same transient line every earlier build in this orb printed before completing (raw/build-*.log); no compile error text,
  no integration fixture started, no assertion ran.
- At 15:21Z: tmux server absent ("no server running"), no zig/run.sh/check.sh process, orb not rebooted (btime 06:40:47Z).
  run.sh writes `check EXIT=` after zig returns; its absence means the shell itself was killed, i.e. the tmux server and
  its children were terminated externally (consistent with an Amp CLI restart killing processes in its cgroup; an
  executor connectivity loss was observed at ~15:03Z). Not a test failure; cause of the kill is not otherwise established.
- Correction: rerun as a supervised orb service (`amp orb service start`), which survives CLI restarts. One bounded rerun.
