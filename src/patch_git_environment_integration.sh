set -eu

fixture=$1
root=$(mktemp -d "${TMPDIR:-/tmp}/onepage-patch-git-environment.XXXXXX")
trap 'rm -rf "$root"' EXIT

mkdir -p "$root/actual" "$root/hostile"
git -C "$root/actual" init -q
printf 'old\n' > "$root/actual/note.txt"
git -C "$root/hostile" init -q
printf 'old\n' > "$root/hostile/note.txt"
git -C "$root/hostile" add note.txt

actual=$(cd "$root/actual" && pwd -P)
hostile=$(cd "$root/hostile" && pwd -P)

GIT_DIR="$hostile/.git" \
GIT_WORK_TREE="$hostile" \
GIT_INDEX_FILE="$hostile/.git/index" \
GIT_CONFIG_GLOBAL="$hostile/global-config" \
"$fixture" "$actual"

test "$(cat "$root/actual/note.txt")" = old
