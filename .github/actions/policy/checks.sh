#!/usr/bin/env bash
# The policy checks, in one owner for both callers: the policy job runs them in the
# foreground through action.yml; check.yml's single PR job runs them beside its compile.
# Every check runs even after another fails, so one run reports every policy failure.
# Input: SKIPS, the JSON list of policy self-checks whose inputs are unchanged.
# Needs the job's infrastructure steps first: pinned packages, Node, the pinned workflow linter.
set -uo pipefail
failed=()

check() {
  local name=$1
  shift
  echo "::group::$name"
  local started=$SECONDS
  "$@"
  local status=$?
  echo "::endgroup::"
  if [ "$status" -ne 0 ]; then
    echo "::error::$name failed (exit $status)"
    failed+=("$name")
  fi
  echo "$name: exit $status after $((SECONDS - started)) s"
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
      .github/workflows/qualify-macos.yml|.github/workflows/previous-release-upgrade.yml|.github/workflows/release.yml|.github/workflows/release-build.yml)
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
check "Run tests/ci, less self-checks whose inputs are unchanged" python3 -B tests/ci/policy_suite.py --skips "$SKIPS"
# ruff is pinned in tests/ci/requirements.txt, which the pre-push hook installs too.
check "Reject undefined fixture names before native builds" python3 -m ruff check --select F821 tests
check "Check the TypeScript client's generated wire types and type-check it" typescript_client
check "Validate workflows with pinned-linter compatibility exceptions" workflows

if [ "${#failed[@]}" -ne 0 ]; then
  printf 'Policy checks failed: %s\n' "${failed[@]}"
  exit 1
fi
