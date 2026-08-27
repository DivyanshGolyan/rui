set -eu

fixture=$1
root=$(mktemp -d "${TMPDIR:-/tmp}/onepage-effect-recovery.XXXXXX")
trap 'rm -rf "$root"' EXIT
root=$(cd "$root" && pwd -P)

mkdir -p "$root/model/state" "$root/model/repo"
git -C "$root/model/repo" init -q
model_session=$($fixture start-model "$root/model/state" "$root/model/repo")
test "$($fixture finish-model "$root/model/state" "$model_session")" = finished

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
