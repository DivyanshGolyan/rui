#!/bin/sh
# Install a published Rui release in ~/.local without building it.
# Release publication replaces the version and archive digests below; the
# repository copy is a template, not an installer.
set -eu

version='@VERSION@'
digest_darwin_arm64='@SHA256_DARWIN_ARM64@'
digest_linux_x86_64='@SHA256_LINUX_X86_64@'
repository='DivyanshGolyan/rui'

if [ $# = 1 ] && { [ "$1" = --help ] || [ "$1" = -h ]; }; then
    printf '%s\n' "Usage: install.sh" \
        "Download Rui $version for this platform and install it in ~/.local/bin." \
        'Preserves Stores, credentials, shell profiles, running Hosts and earlier builds.'
    exit 0
fi
if [ $# != 0 ]; then
    printf 'Usage: install.sh [--help]\n' >&2
    exit 1
fi
case $version in
    @*) printf 'This is the unpublished installer template. Use the install.sh attached to a release.\n' >&2; exit 1 ;;
esac

case "$(uname -s)/$(uname -m)" in
    Darwin/arm64) platform=darwin-arm64; expected=$digest_darwin_arm64 ;;
    Linux/x86_64) platform=linux-x86_64; expected=$digest_linux_x86_64 ;;
    *) printf 'Supported platforms: macOS Apple Silicon and Linux x86-64.\n' >&2; exit 1 ;;
esac
for tool in curl tar uname; do
    if ! command -v "$tool" >/dev/null; then
        printf 'Missing prerequisite: %s\n' "$tool" >&2
        exit 1
    fi
done
if command -v sha256sum >/dev/null; then
    digest() { sha256sum "$1" | cut -d ' ' -f 1; }
elif command -v shasum >/dev/null; then
    digest() { shasum -a 256 "$1" | cut -d ' ' -f 1; }
else
    printf 'Missing prerequisite: sha256sum or shasum\n' >&2
    exit 1
fi

prefix="$HOME/.local"
if [ -d "$prefix/bin/rui" ]; then
    printf 'Cannot replace directory: %s\n' "$prefix/bin/rui" >&2
    exit 1
fi
mkdir -p "$prefix/lib/rui" "$prefix/bin"
release=$(mktemp -d "$prefix/lib/rui/install.XXXXXX")
links=
published=0
cleanup() {
    status=$?
    if [ -n "$links" ]; then rm -rf "$links"; fi
    if [ "$published" = 0 ] && ! rm -rf "$release"; then
        printf 'Could not remove unfinished installation: %s\n' "$release" >&2
        if [ "$status" = 0 ]; then status=1; fi
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

archive="rui-$version-$platform.tar.gz"
printf 'Downloading Rui %s for %s ...\n' "$version" "$platform"
curl --fail --location --show-error --silent --connect-timeout 10 --max-time 300 \
    --retry 2 --retry-delay 1 \
    "https://github.com/$repository/releases/download/v$version/$archive" -o "$release/$archive"
actual=$(digest "$release/$archive")
if [ "$actual" != "$expected" ]; then
    printf 'Downloaded archive digest %s does not match %s. No installation changed.\n' "$actual" "$expected" >&2
    exit 1
fi
tar -xzf "$release/$archive" -C "$release" --strip-components=1
rm "$release/$archive"
printf 'Checking the downloaded command ...\n'
reported=$("$release/bin/rui" --version)
case $reported in
    "rui $version ("*) ;;
    *) printf 'Downloaded command reports %s, not Rui %s. No installation changed.\n' "$reported" "$version" >&2; exit 1 ;;
esac
test -f "$release/THIRD_PARTY_NOTICES.md"

# Keep each complete build: running processes may still use its files.
# Publish with rename rather than modifying an executable already in use.
published=1
links=$(mktemp -d "$prefix/bin/.rui-install.XXXXXX")
ln -s "$release/bin/rui" "$links/rui"
mv -f "$links/rui" "$prefix/bin/rui"
printf '\nInstalled %s at %s/bin/rui.\n' "$reported" "$prefix"
printf 'Previous builds, Stores and credentials were preserved.\n'
resolved=$(command -v rui || true)
if [ "$resolved" != "$prefix/bin/rui" ]; then
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
