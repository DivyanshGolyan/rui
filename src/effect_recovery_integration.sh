set -eu

fixture=$1
root=$(mktemp -d "${TMPDIR:-/tmp}/onepage-effect-recovery.XXXXXX")
trap 'rm -rf "$root"' EXIT
root=$(cd "$root" && pwd -P)

mkdir -p "$root/prepublication/state" "$root/prepublication/repo"
git -C "$root/prepublication/repo" init -q
set +e
prepublication_session=$($fixture crash-prepublication-model "$root/prepublication/state" "$root/prepublication/repo")
crash_status=$?
set -e
test "$crash_status" -eq 86
test "$($fixture recover-prepublication-model "$root/prepublication/state" "$prepublication_session")" = finished

mkdir -p "$root/transaction-crash/state" "$root/transaction-crash/repo"
git -C "$root/transaction-crash/repo" init -q
set +e
transaction_crash_session=$($fixture crash-transaction-model "$root/transaction-crash/state" "$root/transaction-crash/repo")
transaction_crash_status=$?
set -e
test "$transaction_crash_status" -eq 88
test "$($fixture recover-prepublication-model "$root/transaction-crash/state" "$transaction_crash_session")" = finished

mkdir -p "$root/published-completion/state" "$root/published-completion/repo"
git -C "$root/published-completion/repo" init -q
set +e
published_session=$($fixture crash-published-model "$root/published-completion/state" "$root/published-completion/repo")
completion_crash_status=$?
set -e
test "$completion_crash_status" -eq 87
test "$($fixture recover-published-model "$root/published-completion/state" "$published_session")" = finished

mkdir -p "$root/model/state" "$root/model/repo"
git -C "$root/model/repo" init -q
model_session=$($fixture start-model "$root/model/state" "$root/model/repo")
test "$($fixture finish-model "$root/model/state" "$model_session")" = finished
test "$($fixture late-model "$root/model/state" "$model_session")" = audited

mkdir -p "$root/exhaustion/state" "$root/exhaustion/repo"
git -C "$root/exhaustion/repo" init -q
exhaustion_session=$($fixture start-model "$root/exhaustion/state" "$root/exhaustion/repo")
retry=1
while test "$retry" -lt 8; do
    test "$($fixture retry-model "$root/exhaustion/state" "$exhaustion_session")" = dispatched
    retry=$((retry + 1))
done
test "$($fixture exhaust-model "$root/exhaustion/state" "$exhaustion_session")" = failed

mkdir -p "$root/bash/state" "$root/bash/repo"
git -C "$root/bash/repo" init -q
bash_session=$($fixture start-bash "$root/bash/state" "$root/bash/repo")
test "$(cat "$root/bash/repo/uncertain.txt")" = x
test "$($fixture resume-bash "$root/bash/state" "$bash_session")" = indeterminate
test "$($fixture resume-bash "$root/bash/state" "$bash_session")" = indeterminate
test "$(cat "$root/bash/repo/uncertain.txt")" = x
