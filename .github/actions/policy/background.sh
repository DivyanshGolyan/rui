#!/usr/bin/env bash
# Runs checks.sh beside check.yml's single PR job compile, then reports it after the tests.
#   start:  launch checks.sh in the background; its exit status always reaches
#           $RUNNER_TEMP/policy.status, also when it fails or the launcher is signalled.
#   report: wait for that status, print the policy log and exit with the status; a
#           launcher that died without one fails at once, named, instead of waiting.
set -euo pipefail
dir=${RUNNER_TEMP:?}
case "${1:-}" in
  start)
    rm -f "$dir/policy.status" "$dir/policy.log" "$dir/policy.pid"
    (
      trap 'echo 143 > "$dir/policy.status"; exit 143' HUP INT TERM
      # The conditional keeps set -e from ending this subshell before it records a failure.
      if nice -n 10 bash .github/actions/policy/checks.sh > "$dir/policy.log" 2>&1; then
        status=0
      else
        status=$?
      fi
      echo "$status" > "$dir/policy.status"
    ) &
    echo $! > "$dir/policy.pid"
    ;;
  report)
    pid=$(cat "$dir/policy.pid" 2>/dev/null || true)
    while [ ! -s "$dir/policy.status" ]; do
      if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
        # The launcher may have written its status just before exiting.
        [ -s "$dir/policy.status" ] && break
        cat "$dir/policy.log" 2>/dev/null || true
        echo "::error::The policy checks stopped without a result (launcher ${pid:-never started})"
        exit 1
      fi
      sleep 1
    done
    cat "$dir/policy.log"
    status=$(cat "$dir/policy.status")
    if [ "$status" != 0 ]; then
      echo "::error::Policy checks failed (exit $status)"
    fi
    exit "$status"
    ;;
  *)
    echo "usage: $0 start|report" >&2
    exit 2
    ;;
esac
