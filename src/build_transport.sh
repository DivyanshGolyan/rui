#!/bin/sh
set -eu

openssl_source=$1
curl_source=$2
prefix=$3
target=$4
zig=$5

case "$target" in
    aarch64-macos)
        openssl_target=darwin64-arm64-cc
        curl_host=aarch64-apple-darwin
        openssl_dir="$prefix/ssl"
        curl_trust=--with-apple-sectrust
        sdk=$(xcrun --sdk macosx --show-sdk-path)
        cc="/usr/bin/clang -arch arm64 -isysroot $sdk -mmacosx-version-min=11.0"
        ;;
    x86_64-macos)
        openssl_target=darwin64-x86_64-cc
        curl_host=x86_64-apple-darwin
        openssl_dir="$prefix/ssl"
        curl_trust=--with-apple-sectrust
        sdk=$(xcrun --sdk macosx --show-sdk-path)
        cc="/usr/bin/clang -arch x86_64 -isysroot $sdk -mmacosx-version-min=11.0"
        ;;
    aarch64-linux)
        openssl_target=linux-aarch64
        compiler_target=aarch64-linux-gnu
        curl_host=aarch64-linux-gnu
        openssl_dir=/etc/ssl
        curl_trust=--without-secure-transport
        cc="$zig cc -target $compiler_target"
        ;;
    x86_64-linux)
        openssl_target=linux-x86_64
        compiler_target=x86_64-linux-gnu
        curl_host=x86_64-linux-gnu
        openssl_dir=/etc/ssl
        curl_trust=--without-secure-transport
        cc="$zig cc -target $compiler_target"
        ;;
    *)
        echo "unsupported pinned transport target: $target" >&2
        exit 1
        ;;
esac

build_root="$prefix-build"
openssl_build="$build_root/openssl"
curl_build="$build_root/curl"
log="$build_root/build.log"

mkdir -p "$openssl_build" "$curl_build" "$prefix"
: >"$log"

if [ "${sdk:-}" ]; then
    mkdir -p "$prefix/sdk/System/Library" "$prefix/sdk/usr"
    ln -s "$sdk/System/Library/Frameworks" "$prefix/sdk/System/Library/Frameworks"
    ln -s "$sdk/usr/include" "$prefix/sdk/usr/include"
    ln -s "$sdk/usr/lib" "$prefix/sdk/usr/lib"
fi

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

(
    cd "$curl_build"
    CC="$cc" AR="$zig ar" RANLIB="$zig ranlib" \
    PKG_CONFIG_PATH="$prefix/lib/pkgconfig" sh "$curl_source/configure" \
        --host="$curl_host" \
        --prefix="$prefix" \
        --with-openssl="$prefix" \
        "$curl_trust" \
        --enable-threaded-resolver \
        --disable-shared --enable-static --enable-http \
        --disable-ftp --disable-file --disable-ipfs --disable-ldap --disable-ldaps \
        --disable-rtsp --disable-proxy --disable-dict --disable-telnet --disable-tftp \
        --disable-pop3 --disable-imap --disable-smb --disable-smtp --disable-gopher \
        --disable-mqtt --without-zlib --without-brotli --without-zstd --without-libpsl \
        --without-libidn2 \
        --disable-docs --disable-manual --disable-libcurl-option --disable-dependency-tracking
    make -C lib -j4
    mkdir -p "$prefix/include/curl" "$prefix/lib"
    cp "$curl_source"/include/curl/*.h "$prefix/include/curl/"
    cp lib/.libs/libcurl.a "$prefix/lib/libcurl.a"
    "$zig" ranlib "$prefix/lib/libcurl.a"
) >>"$log" 2>&1 || {
    tail -100 "$log" >&2
    exit 1
}

grep '^#define LIBCURL_VERSION "8.22.0"' "$prefix/include/curl/curlver.h" >/dev/null
grep '^# *define OPENSSL_VERSION_STR "3.6.3"' "$prefix/include/openssl/opensslv.h" >/dev/null
test -f "$prefix/lib/libcurl.a"
test -f "$prefix/lib/libssl.a"
test -f "$prefix/lib/libcrypto.a"
