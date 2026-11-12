#!/usr/bin/env bash
set -euo pipefail

repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
if (( $# != 0 && $# != 2 && $# != 3 )); then
    echo "Usage: $0 [MANIFEST PACKAGE_DIR [DEPENDENCY]]" >&2
    exit 2
fi
packages=${2:-${ZIG_LOCAL_PKG_DIR:-$repo/zig-pkg}}
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

# Anonymous github.com downloads time out when GitHub sheds anonymous load; the
# API serves the same release asset or archive to a token. CI sets GH_TOKEN;
# failed API requests fall back to anonymous downloads. The pinned hash checks all sources.
download() {
    local url=$1 archive=$2 path owner name rest tag
    if [[ -n ${GH_TOKEN:-} && $url == https://github.com/* ]]; then
        path=${url#https://github.com/}
        owner=${path%%/*}; rest=${path#*/}
        name=${rest%%/*}; rest=${rest#*/}
        case "$rest" in
            releases/download/*)
                tag=${rest#releases/download/}
                if gh release download "${tag%/*}" --repo "$owner/$name" --pattern "${tag##*/}" --output "$archive"; then return 0; fi ;;
            archive/*.tar.gz)
                rest=${rest#archive/}
                local api="https://api.github.com/repos/$owner/$name/tarball/${rest%.tar.gz}"
                if curl --fail --location --show-error --connect-timeout 10 --max-time 90 \
                    --retry 2 --retry-all-errors --retry-max-time 200 \
                    --header "Authorization: Bearer $GH_TOKEN" "$api" -o "$archive"; then return 0; fi ;;
        esac
    fi
    curl --fail --location --show-error --connect-timeout 10 --max-time 90 \
        --retry 2 --retry-all-errors --retry-max-time 200 "$url" -o "$archive"
}

# Stock Zig 0.17 no-save fetch caches the archive's outer directory and ignores
# --pkg-dir. Save into a disposable manifest to install correctly rooted trees.
# Prepare transitive packages too: Zig's resolver cannot parse some orb DNS configs.
# Download a manifest's archives before importing any of them: the first zig fetch
# compiles Zig's build runner, and orb setup overlaps that compile with these downloads.
prepared=' '
prepare_dependencies() {
    local manifest=$1 name url expected archive actual revision remote index git_remote git_revision
    local names fetch_names=() fetch_hashes=() fetch_archives=()
    names=$(sed -n '/^    \.dependencies = /,/^    },/s/^        \.\([[:alnum:]_]*\) = .{/\1/p' "$manifest")
    if [[ -n ${3:-} ]]; then names=$3; fi
    for name in $names; do
        url=$(sed -n "/\.$name = /,/},/s/.*\.url = \"\([^\"]*\)\".*/\1/p" "$manifest")
        expected=$(sed -n "/\.$name = /,/},/s/.*\.hash = \"\([^\"]*\)\".*/\1/p" "$manifest")
        [[ -n $url && -n $expected ]]
        git_remote= git_revision=
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
                [[ $remote == https://github.com/* ]] && { git_remote=$remote; git_revision=$revision; }
                url="${remote%.git}/archive/$revision.tar.gz"
                ;;
        esac
        if [[ -z $git_remote && $url == https://github.com/*/archive/refs/tags/*.tar.gz ]]; then
            git_remote=${url%%/archive/*}
            git_revision=${url#*/archive/}; git_revision=${git_revision%.tar.gz}
        fi
        case "$prepared" in *" $expected "*) continue ;; esac
        archive=
        if [[ ! -d "$packages/$expected" ]]; then
            archive="$scratch/$expected/${url##*/}"
            mkdir -p "${archive%/*}"
            printf 'Preparing pinned %s dependency ...\n' "$name"
            if ! download "$url" "$archive"; then
                [[ -n $git_remote ]] || return 1
                printf "Falling back to git for %s ...\n" "$name"
                git init -q "$scratch/$expected/repo"
                git -C "$scratch/$expected/repo" fetch --depth 1 "$git_remote" "$git_revision"
                archive="$scratch/$expected/export"
                mkdir -p "$archive"
                git -C "$scratch/$expected/repo" archive FETCH_HEAD | tar -x -C "$archive"
            fi
        fi
        fetch_names+=("$name")
        fetch_hashes+=("$expected")
        fetch_archives+=("$archive")
    done
    for ((index = 0; index < ${#fetch_names[@]}; index++)); do
        name=${fetch_names[index]}
        expected=${fetch_hashes[index]}
        archive=${fetch_archives[index]}
        case "$prepared" in *" $expected "*) continue ;; esac
        if [[ ! -d "$packages/$expected" ]]; then
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
        if (( $# == 1 )) && [[ -f "$packages/$expected/build.zig.zon" ]]; then
            prepare_dependencies "$packages/$expected/build.zig.zon"
        fi
    done
}
if (( $# >= 2 )); then
    prepare_dependencies "$1" nonrecursive "${3:-}"
    exit
fi
prepare_dependencies "$repo/build.zig.zon"

# Keep the complete graph authoritative, including translate-c and its parser.
(cd -- "$repo" && zig build --fetch=all)
