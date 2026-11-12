#!/usr/bin/env bash
set -euo pipefail

repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
packages=${1:-$repo/screen-emulator/zig-pkg}
mkdir -p "$packages"
packages=$(cd -- "$packages" && pwd)
manifest="$repo/screen-emulator/build.zig.zon"
fetch() { env -u ZIG_LOCAL_PKG_DIR bash "$repo/src/fetch_dependencies.sh" "$@"; }
fetch "$manifest" "$packages"
ghostty=$(sed -n '/\.ghostty_vt = /,/},/s/.*\.hash = "\([^"]*\)".*/\1/p' "$manifest")
test -n "$ghostty"
fetch "$packages/$ghostty/build.zig.zon" "$packages" uucode
fetch "$packages/$ghostty/build.zig.zon" "$packages" aro
fetch "$packages/$ghostty/pkg/translate-c/build.zig.zon" "$packages" translate_c
# Zig 0.17.1's build maker crashes downloading these lazy packages.
for dependency in wuffs highway; do
    fetch "$packages/$ghostty/pkg/$dependency/build.zig.zon" "$packages" "$dependency"
done
