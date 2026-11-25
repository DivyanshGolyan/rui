#!/usr/bin/env bash
# The policy checks, in one owner for both callers: the policy job runs them in the
# foreground through action.yml; check.yml's single PR job runs them beside its compile.
# Every check runs, concurrently, even after another fails, so one run reports every policy failure.
# Input: SKIPS, the JSON list of policy self-checks whose inputs are unchanged.
# Needs the job's infrastructure steps first: pinned packages, Node, the pinned workflow linter.
set -uo pipefail
logs=$(mktemp -d "${RUNNER_TEMP:-/tmp}/policy-checks.XXXXXX")
names=()
pids=()

# Starts one check in the background with its own log; report waits for every check and
# prints the logs in the order the checks were started.
check() {
  local index=${#names[@]}
  names+=("$1")
  shift
  (
    started=$SECONDS
    "$@"
    status=$?
    echo "$((SECONDS - started))" > "$logs/$index.seconds"
    exit "$status"
  ) > "$logs/$index" 2>&1 &
  pids+=("$!")
}

report() {
  local failed=() index status
  for index in "${!names[@]}"; do
    wait "${pids[$index]}"
    status=$?
    echo "::group::${names[$index]}"
    cat "$logs/$index"
    echo "::endgroup::"
    if [ "$status" -ne 0 ]; then
      echo "::error::${names[$index]} failed (exit $status)"
      failed+=("${names[$index]}")
    fi
    echo "${names[$index]}: exit $status after $(cat "$logs/$index.seconds" 2>/dev/null || echo '?') s"
  done
  rm -rf "$logs"
  if [ "${#failed[@]}" -ne 0 ]; then
    printf 'Policy checks failed: %s\n' "${failed[@]}"
    exit 1
  fi
}

typescript_client() (
  set -euo pipefail
  cd clients/ts
  # The single PR job's setup already installed these from the same lockfile, and its
  # ts-client fixture may be using them while policy runs.
  [ -d node_modules ] || npm ci --ignore-scripts --no-audit --no-fund
  npm run check
  npm test
)

workflows() (
  set -euo pipefail
  for workflow in .github/workflows/*.yml; do
    ignores=()
    # 1.7.7 predates GitHub's server-enforced cache policy key.
    case "$workflow" in
      .github/workflows/qualify-macos.yml|.github/workflows/previous-release-upgrade.yml|.github/workflows/release.yml|.github/workflows/release-build.yml|.github/workflows/race-sweep.yml|.github/workflows/statement-table.yml)
        ignores+=(-ignore '^unexpected key "cache-mode" for "workflow" section\.') ;;
    esac
    # 1.7.7 predates GitHub's bounded concurrency queue option.
    if [ "$workflow" = .github/workflows/screens-comment.yml ]; then
      ignores+=(-ignore '^unexpected key "queue" for "concurrency" section\.')
    fi
    "$RUNNER_TEMP/actionlint/actionlint" -shellcheck= "${ignores[@]}" "$workflow"
  done
)

check "Check caller error coverage and shrink-only pending causes" python3 -B tests/ci/caller_errors.py
check "Check flake sources and shrink-only allowances" python3 -B tests/ci/flake_sources.py
check "Check client locality and shrink-only exceptions" python3 -B tests/ci/client_locality.py
check "Check the deep-modules allowance does not grow past trusted main" python3 -B tests/ci/deep_modules_allowance.py
check "Check the Store statement table was generated from the current inputs" python3 -B tests/ci/rsql_table.py fingerprint
check "Check the build's link table was generated from the current build inputs" python3 -B tests/ci/link_table.py fingerprint
check "Run tests/ci, less self-checks whose inputs are unchanged" python3 -B tests/ci/policy_suite.py --skips "$SKIPS"
# ruff is pinned in tests/ci/requirements.txt, which the pre-push hook installs too.
check "Reject undefined fixture names before native builds" python3 -m ruff check --select F821 tests
check "Check the TypeScript client's generated wire types and type-check it" typescript_client
check "Validate workflows with pinned-linter compatibility exceptions" workflows

report
