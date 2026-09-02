#!/bin/zsh
set -euo pipefail

artifact_dir="${0:A:h}"
probe_root="$(mktemp -d /tmp/onepage-diskfull.XXXXXX)"
image_path="$probe_root/scratch.dmg"
mount_path="$probe_root/mount"
binary="$probe_root/integrated_capacity"
device=""
mkdir "$mount_path"

cleanup() {
  if [[ -n "$device" ]]; then hdiutil detach -quiet "$device" 2>/dev/null || true; fi
}
trap cleanup EXIT INT TERM

clang -O2 -std=c11 -Wall -Wextra -Werror \
  "$artifact_dir/integrated_capacity.c" -o "$binary" \
  -lcurl -lsqlite3 -lpthread

hdiutil create -quiet -size 5m -fs HFS+ -volname OnePageScratch "$image_path"
attach_output="$(hdiutil attach -nobrowse -mountpoint "$mount_path" "$image_path")"
device="$(print -r -- "$attach_output" | awk '/Apple_HFS/ {print $1; exit}')"
[[ -n "$device" ]]

# Leave only a small tail for two output spools so a real filesystem write,
# rather than a synthetic counter, reaches ENOSPC.
mkfile 4800k "$mount_path/fill"
client_json="$("$binary" integrated 1 unused unused "$mount_path" \
  "$probe_root/proof.sqlite3" lane 10 bash-only normal)"

jq -e '
  .settled == 1 and .resolution_rows == 1 and
  .completion_classes.local_resource_failure == 1 and .artifact_rows == 0 and
  .bash_evidence.reaped == 1 and .scratch_logical_final == 0 and
  .closed.fds == .unopened.fds' <<< "$client_json" >/dev/null

print -r -- "$client_json"
