#!/bin/sh
# The pinned OpenSSL and nghttp2 public headers for a target, without
# building either library: enough to type-check the HTTP/2 client for a
# target whose transport is not built here (macOS from Linux).
set -eu

openssl_source=$1
nghttp2_source=$2
prefix=$3
target=$4

case "$target" in
    aarch64-macos) openssl_target=darwin64-arm64-cc ;;
    x86_64-macos) openssl_target=darwin64-x86_64-cc ;;
    *)
        echo "unsupported transport headers target: $target" >&2
        exit 1
        ;;
esac

build_root=$(mktemp -d "${TMPDIR:-/tmp}/rui-transport-headers.XXXXXX")
log="$build_root/build.log"
cleanup() {
    rm -rf "$build_root"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

# Configure plus only the public headers that OpenSSL generates from .in
# templates, with build_transport.sh's options.
generated=$(cd "$openssl_source" && for template in include/openssl/*.h.in; do
    printf '%s ' "${template%.in}"
done)
(
    cd "$build_root"
    perl "$openssl_source/Configure" "$openssl_target" \
        no-shared no-tests no-apps no-docs
    # shellcheck disable=SC2086 # one word per header
    make $generated
) >>"$log" 2>&1 || {
    tail -100 "$log" >&2
    exit 1
}

mkdir -p "$prefix/include/openssl" "$prefix/include/nghttp2"
cp "$openssl_source"/include/openssl/*.h "$prefix/include/openssl/"
cp "$build_root"/include/openssl/*.h "$prefix/include/openssl/"
cp "$nghttp2_source"/lib/includes/nghttp2/*.h "$prefix/include/nghttp2/"

grep '^# *define OPENSSL_VERSION_STR "3.6.3"' "$prefix/include/openssl/opensslv.h" >/dev/null
grep '^#define NGHTTP2_VERSION "1.70.0"' "$prefix/include/nghttp2/nghttp2ver.h" >/dev/null
