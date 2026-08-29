#!/bin/sh
set -eu

onepage_binary=$1
live_root=$(mktemp -d "${TMPDIR:-/tmp}/onepage-codex-live.XXXXXX")
cleanup() {
  status=$?
  trap - EXIT HUP INT TERM
  if test "$status" -eq 0; then
    rm -rf "$live_root"
  else
    printf 'Failed live fixture preserved at: %s\n' "$live_root" >&2
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
repo_dir="$live_root/repo"
mkdir "$repo_dir"

git -C "$repo_dir" init -q
git -C "$repo_dir" config user.email onepage-live@example.invalid
git -C "$repo_dir" config user.name "OnePage live fixture"
printf '%s\n' broken > "$repo_dir/status.txt"
printf '%s\n' '#!/bin/sh' 'test "$(cat status.txt)" = fixed' > "$repo_dir/test.sh"
chmod +x "$repo_dir/test.sh"
git -C "$repo_dir" add status.txt test.sh
git -C "$repo_dir" commit -qm fixture

set +e
"$onepage_binary" \
  --state "$live_root/state" \
  --repo "$repo_dir" \
  --model codex:gpt-5.6-sol \
  --dangerously-bypass-permissions \
  "Run ./test.sh, diagnose the failure, change only status.txt so the test passes, run ./test.sh again, and finish with a concise summary." \
  > "$live_root/output.txt" 2>&1
onepage_status=$?
set -e

cat "$live_root/output.txt"
if test "$onepage_status" -ne 0; then
  exit "$onepage_status"
fi
grep -q '^Final Answer:$' "$live_root/output.txt"
test "$(cat "$repo_dir/status.txt")" = fixed
(cd "$repo_dir" && ./test.sh)
test "$(git -C "$repo_dir" diff --name-only)" = status.txt
