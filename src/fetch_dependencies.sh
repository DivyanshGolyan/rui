#!/usr/bin/env bash
set -euo pipefail

repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
packages=${ZIG_LOCAL_PKG_DIR:-$repo/zig-pkg}
mkdir -p "$packages"
packages=$(cd -- "$packages" && pwd)
export ZIG_LOCAL_PKG_DIR="$packages"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/rui-dependencies.XXXXXX")
cleanup() {
    status=$?
    if ! rm -rf "$scratch"; then
        printf 'Could not remove dependency scratch: %s\n' "$scratch" >&2
        if (( status == 0 )); then status=1; fi
    fi
    exit "$status"
}
trap cleanup EXIT
cp "$repo/build.zig" "$scratch/build.zig"

# Stock Zig 0.17 no-save fetch caches the archive's outer directory and ignores
# --pkg-dir. Save into a disposable manifest to install correctly rooted trees.
# Prepare transitive packages too: Zig's resolver cannot parse some orb DNS configs.
prepared=' '
prepare_dependencies() {
    local manifest=$1 name url expected archive actual revision remote
    local names
    names=$(sed -n '/^    \.dependencies = /,/^    },/s/^        \.\([[:alnum:]_]*\) = .{/\1/p' "$manifest")
    for name in $names; do
        url=$(sed -n "/\.$name = /,/},/s/.*\.url = \"\([^\"]*\)\".*/\1/p" "$manifest")
        expected=$(sed -n "/\.$name = /,/},/s/.*\.hash = \"\([^\"]*\)\".*/\1/p" "$manifest")
        [[ -n $url && -n $expected ]]
        case "$url" in
            git+https://codeberg.org/*|git+https://github.com/*)
                revision=${url#*#}
                if [[ ! $revision =~ ^[[:xdigit:]]{40}$ ]]; then
                    printf 'Pinned %s Git dependency in %s requires # followed by a full 40-character hexadecimal commit ID.\n' "$name" "$manifest" >&2
                    exit 1
                fi
                remote=${url#git+}
                remote=${remote%%#*}
                remote=${remote%%\?*}
                url="${remote%.git}/archive/$revision.tar.gz"
                ;;
        esac
        case "$prepared" in *" $expected "*) continue ;; esac
        if [[ ! -d "$packages/$expected" ]]; then
            archive="$scratch/${url##*/}"
            printf 'Preparing pinned %s dependency ...\n' "$name"
            curl --fail --location --show-error --connect-timeout 10 --max-time 90 \
                --retry 2 --retry-all-errors --retry-max-time 200 "$url" -o "$archive"
            cp "$manifest" "$scratch/build.zig.zon"
            (cd -- "$scratch" && zig fetch --pkg-dir "$packages" "--save=$name" "$archive")
            actual=$(sed -n "/\.$name = /,/},/s/.*\.hash = \"\([^\"]*\)\".*/\1/p" "$scratch/build.zig.zon")
            if [[ $actual != "$expected" ]]; then
                printf 'Pinned %s dependency hash mismatch. Source manifest unchanged.\n' "$name" >&2
                exit 1
            fi
            test -d "$packages/$expected"
        fi
        prepared+="$expected "
        if [[ -f "$packages/$expected/build.zig.zon" ]]; then
            prepare_dependencies "$packages/$expected/build.zig.zon"
        fi
    done
}
prepare_dependencies "$repo/build.zig.zon"

# Keep the complete graph authoritative, including translate-c and its parser.
(cd -- "$repo" && zig build --fetch=all)
