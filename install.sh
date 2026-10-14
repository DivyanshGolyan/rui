#!/usr/bin/env bash
set -euo pipefail

if [[ $# == 1 && ( $1 == --help || $1 == -h ) ]]; then
    printf '%s\n' 'Usage: ./install.sh' \
        'Build this checkout and install Rui in ~/.local/bin.' \
        'Requires the Zig version in build.zig.zon and the native build prerequisites.' \
        'Preserves Stores, credentials, shell profiles and running Hosts.' \
        'Respects ZIG_GLOBAL_CACHE_DIR and XDG_CACHE_HOME.'
    exit 0
fi
if (( $# != 0 )); then
    printf 'Usage: ./install.sh [--help]\n' >&2
    exit 1
fi

repo=$(cd -- "$(dirname -- "$0")" && pwd)
cd "$repo"
for tool in zig python3 git make perl patch cc curl; do
    if ! command -v "$tool" >/dev/null; then
        printf 'Missing prerequisite: %s. See README.md, Build from source.\n' "$tool" >&2
        exit 1
    fi
done
case "$(uname -s)/$(uname -m)" in
    Darwin/arm64) xcrun --sdk macosx --show-sdk-path >/dev/null ;;
    Linux/x86_64) ;;
    *) printf 'Supported platforms: macOS Apple Silicon and Linux x86-64.\n' >&2; exit 1 ;;
esac
expected_zig=$(sed -n 's/.*\.minimum_zig_version = "\([^"]*\)".*/\1/p' build.zig.zon)
actual_zig=$(zig version)
if [[ -z $expected_zig || $actual_zig != "$expected_zig" ]]; then
    printf 'Zig %s is required; found %s. No installation changed.\n' "$expected_zig" "$actual_zig" >&2
    exit 1
fi

prefix="$HOME/.local"
for name in rui rui-evaluator; do
    if [[ -d "$prefix/bin/$name" ]]; then
        printf 'Cannot replace directory: %s\n' "$prefix/bin/$name" >&2
        exit 1
    fi
done
cache=${ZIG_GLOBAL_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/zig}
mkdir -p "$cache/tmp" "$prefix/lib/rui" "$prefix/bin"
cache=$(cd "$cache" && pwd)
export ZIG_GLOBAL_CACHE_DIR="$cache"
release=$(mktemp -d "$prefix/lib/rui/install.XXXXXX")
published=0
cleanup() {
    status=$?
    if (( published == 0 )); then
        if ! rm -rf "$release"; then
            printf 'Could not remove unfinished build: %s\n' "$release" >&2
            if (( status == 0 )); then status=1; fi
        fi
    elif (( status != 0 )); then
        printf 'Installation did not finish. Built files retained at %s.\n' "$release" >&2
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

revision='source archive'
if [[ $(git rev-parse --show-toplevel 2>/dev/null) == "$repo" ]]; then
    revision=$(git rev-parse --short HEAD)
    if [[ $(git status --porcelain --untracked-files=normal) ]]; then
        revision="$revision (local changes)"
    fi
fi
printf 'Building %s with Zig %s.\n' "$revision" "$actual_zig"
printf 'Preparing dependencies in %s ...\n' "$cache"
bash src/fetch_dependencies.sh
printf 'Building Rui and its native dependencies. A first build can take several minutes.\n'
python3 - "$release" <<'PY'
import signal
import subprocess
import sys
import time

started = time.monotonic()
with subprocess.Popen(["zig", "build", "-Doptimize=ReleaseSafe",
                       "--prefix", sys.argv[1], "--summary", "all"]) as build:
    for number in (signal.SIGINT, signal.SIGTERM):
        signal.signal(number, lambda number, frame: build.send_signal(number))
    while True:
        try:
            status = build.wait(timeout=15)
            sys.exit(status if status >= 0 else 128 - status)
        except subprocess.TimeoutExpired:
            print(f"Build still running ({int(time.monotonic() - started)} seconds elapsed).", flush=True)
PY
printf 'Checking the built command ...\n'
"$release/bin/rui" --help >/dev/null
test -x "$release/bin/rui-evaluator"
test -f "$release/THIRD_PARTY_NOTICES.md"
printf '%s\n' "$revision" >"$release/revision"

# Keep each complete build: running processes may still use its sibling helper.
# Publish with rename rather than modifying an executable already in use.
published=1
python3 - "$release" "$prefix/bin" <<'PY'
import os
import pathlib
import sys
import tempfile

release, destination = map(pathlib.Path, sys.argv[1:])
with tempfile.TemporaryDirectory(prefix=".rui-install.", dir=destination) as temporary:
    for name in ("rui-evaluator", "rui"):
        link = pathlib.Path(temporary) / name
        link.symlink_to(release / "bin" / name)
        os.replace(link, destination / name)
PY
printf '\nInstalled %s at %s/bin/rui.\n' "$revision" "$prefix"
printf 'Previous builds, Stores and credentials were preserved.\n'
resolved=$(command -v rui || true)
if [[ $resolved != "$prefix/bin/rui" ]]; then
    printf 'Your PATH currently selects: %s\n' "${resolved:-no rui command}"
    printf 'For this shell, run: export PATH="$HOME/.local/bin:$PATH"\n'
fi
printf 'If an open shell still selects an older command, run hash -r (Bash) or rehash (Zsh).\n'
printf '\nSelected Store status (read only):\n'
if ! "$prefix/bin/rui" host status; then
    printf 'Host status could not be checked; the installation succeeded.\n' >&2
fi
printf 'A running Host keeps its old executable. After its work finishes, use rui host stop.\n'
printf 'Start with: "%s/bin/rui"\n' "$prefix"
