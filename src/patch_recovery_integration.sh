set -eu

fixture=$1
root=$(mktemp -d "${TMPDIR:-/tmp}/onepage-patch-recovery.XXXXXX")
trap 'rm -rf "$root"' EXIT
root=$(cd "$root" && pwd -P)

prepare_case() {
    case_name=$1
    mkdir -p "$root/$case_name/state" "$root/$case_name/repo"
    git -C "$root/$case_name/repo" init -q
    printf 'old\n' > "$root/$case_name/repo/note.txt"
    git -C "$root/$case_name/repo" add note.txt
}

prepare_case attempt
attempt_session=$($fixture start-attempt "$root/attempt/state" "$root/attempt/repo")
test "$(cat "$root/attempt/repo/note.txt")" = old
test "$($fixture resume-applied "$root/attempt/state" "$root/attempt/repo" "$attempt_session")" = finished
test "$(cat "$root/attempt/repo/note.txt")" = new
test "$($fixture resume-finished "$root/attempt/state" "$root/attempt/repo" "$attempt_session")" = finished
test "$(cat "$root/attempt/repo/note.txt")" = new

prepare_case authorization
authorization_session=$($fixture start-authorization "$root/authorization/state" "$root/authorization/repo")
printf 'mine\n' > "$root/authorization/repo/note.txt"
test "$($fixture resume-stale "$root/authorization/state" "$root/authorization/repo" "$authorization_session")" = finished
test "$(cat "$root/authorization/repo/note.txt")" = mine

prepare_case mutation
mutation_session=$($fixture start-mutation "$root/mutation/state" "$root/mutation/repo")
test "$(cat "$root/mutation/repo/note.txt")" = new
test "$($fixture resume-applied "$root/mutation/state" "$root/mutation/repo" "$mutation_session")" = finished
test "$(cat "$root/mutation/repo/note.txt")" = new

prepare_case divergence
divergence_session=$($fixture start-attempt "$root/divergence/state" "$root/divergence/repo")
printf 'mine\n' > "$root/divergence/repo/note.txt"
test "$($fixture resume-indeterminate "$root/divergence/state" "$root/divergence/repo" "$divergence_session")" = finished
test "$(cat "$root/divergence/repo/note.txt")" = mine
