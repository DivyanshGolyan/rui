#!/bin/sh
set -eu

onepage_binary=$1
live_root=$(mktemp -d "${TMPDIR:-/tmp}/onepage-codex-live.XXXXXX")
trap 'rm -rf "$live_root"' EXIT HUP INT TERM
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

"$onepage_binary" \
  --state "$live_root/state" \
  --repo "$repo_dir" \
  --model codex:gpt-5.3-codex \
  --dangerously-bypass-permissions \
  "Run ./test.sh, diagnose the failure, change only status.txt so the test passes, run ./test.sh again, and finish with a concise summary." \
  > "$live_root/output.txt"

cat "$live_root/output.txt"
grep -q '^Final Answer:$' "$live_root/output.txt"
test "$(cat "$repo_dir/status.txt")" = fixed
(cd "$repo_dir" && ./test.sh)
test "$(git -C "$repo_dir" diff --name-only)" = status.txt
