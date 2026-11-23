#!/usr/bin/env bash
# Usage: beside.sh -- COMMAND...
# Runs the policy checks (checks.sh, at lower priority) as a background child of this shell
# while COMMAND runs in the foreground, then waits for them, prints their log and reports.
# It exits with COMMAND's status, so a policy failure never stops the steps after it (except a
# stale Store table, which build_artifact.py refuses before compiling); the
# policy result goes to the step output `policy` (success or failure) for the job's last step.
# `wait` returns the child's own status, including death by a signal (128 + its number).
set -uo pipefail
if [ "${1:-}" = -- ]; then shift; fi
log=$(mktemp "${RUNNER_TEMP:-/tmp}/policy.XXXXXX")
nice -n 10 bash .github/actions/policy/checks.sh > "$log" 2>&1 &
checks=$!
"$@"
command=$?
wait "$checks"
policy=$?
echo "::group::Policy checks, run beside: $*"
cat "$log"
echo "::endgroup::"
if [ "$policy" -ne 0 ]; then
  echo "::error::Policy checks failed (exit $policy)"
  echo "policy=failure" >> "${GITHUB_OUTPUT:-/dev/null}"
else
  echo "policy=success" >> "${GITHUB_OUTPUT:-/dev/null}"
fi
if [ "$command" -ne 0 ]; then
  echo "::error::The command beside the policy checks failed (exit $command): $*"
fi
exit "$command"
