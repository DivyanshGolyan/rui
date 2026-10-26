#!/bin/sh
set -eu

openssl_source=$1
nghttp2_source=$2
prefix=$3
target=$4
zig=$5

case "$target" in
    aarch64-macos)
        openssl_target=darwin64-arm64-cc
        host=aarch64-apple-darwin
        openssl_dir="$prefix/ssl"
        sdk=$(xcrun --sdk macosx --show-sdk-path)
        cc="/usr/bin/clang -arch arm64 -isysroot $sdk -mmacosx-version-min=11.0"
        ;;
    x86_64-macos)
        openssl_target=darwin64-x86_64-cc
        host=x86_64-apple-darwin
        openssl_dir="$prefix/ssl"
        sdk=$(xcrun --sdk macosx --show-sdk-path)
        cc="/usr/bin/clang -arch x86_64 -isysroot $sdk -mmacosx-version-min=11.0"
        ;;
    aarch64-linux)
        openssl_target=linux-aarch64
        compiler_target=aarch64-linux-gnu
        host=aarch64-linux-gnu
        openssl_dir=/etc/ssl
        cc="$zig cc -target $compiler_target"
        ;;
    x86_64-linux)
        openssl_target=linux-x86_64
        compiler_target=x86_64-linux-gnu
        host=x86_64-linux-gnu
        openssl_dir=/etc/ssl
        cc="$zig cc -target $compiler_target"
        ;;
    *)
        echo "unsupported pinned transport target: $target" >&2
        exit 1
        ;;
esac

build_root=$(mktemp -d "${TMPDIR:-/tmp}/rui-transport.XXXXXX")
openssl_build="$build_root/openssl"
nghttp2_build="$build_root/nghttp2"
log="$build_root/build.log"

cleanup() {
    rm -rf "$build_root"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

mkdir -p "$openssl_build" "$nghttp2_build" "$prefix"
: >"$log"

if [ "${sdk:-}" ]; then
    mkdir -p "$prefix/sdk/System/Library" "$prefix/sdk/usr"
    rm -f \
        "$prefix/sdk/System/Library/Frameworks" \
        "$prefix/sdk/usr/include" \
        "$prefix/sdk/usr/lib"
    ln -s "$sdk/System/Library/Frameworks" "$prefix/sdk/System/Library/Frameworks"
    ln -s "$sdk/usr/include" "$prefix/sdk/usr/include"
    ln -s "$sdk/usr/lib" "$prefix/sdk/usr/lib"
fi

printf 'Building pinned OpenSSL ...\n' >&2
(
    cd "$openssl_build"
    CC="$cc" AR="$zig ar" RANLIB="$zig ranlib" \
    perl "$openssl_source/Configure" "$openssl_target" \
        no-shared no-tests no-apps no-docs \
        --prefix="$prefix" --openssldir="$openssl_dir" --libdir=lib
    make -j4 build_sw
    make install_sw
) >>"$log" 2>&1 || {
    tail -100 "$log" >&2
    exit 1
}

printf 'Building pinned nghttp2 ...\n' >&2
(
    cd "$nghttp2_build"
    CC="$cc" AR="$zig ar" RANLIB="$zig ranlib" \
    sh "$nghttp2_source/configure" --host="$host" \
        --prefix="$prefix" --enable-lib-only --disable-shared --enable-static
    # The pinned release includes generated Autotools files. Archive extraction
    # can reorder mtimes and spuriously request a local aclocal/automake.
    make -j4 ACLOCAL=true AUTOMAKE=true AUTOCONF=true AUTOHEADER=true
    make install ACLOCAL=true AUTOMAKE=true AUTOCONF=true AUTOHEADER=true
) >>"$log" 2>&1 || {
    tail -100 "$log" >&2
    exit 1
}

grep '^# *define OPENSSL_VERSION_STR "3.6.3"' "$prefix/include/openssl/opensslv.h" >/dev/null
grep '^#define NGHTTP2_VERSION "1.70.0"' "$prefix/include/nghttp2/nghttp2ver.h" >/dev/null
test -f "$prefix/lib/libnghttp2.a"
test -f "$prefix/lib/libssl.a"
test -f "$prefix/lib/libcrypto.a"
