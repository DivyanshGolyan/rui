#!/bin/sh
set -eu

openssl_source=$1
curl_source=$2
prefix=$3

build_root="$prefix-build"
openssl_build="$build_root/openssl"
curl_build="$build_root/curl"
log="$build_root/build.log"

mkdir -p "$openssl_build" "$curl_build" "$prefix"
: >"$log"

(
    cd "$openssl_build"
    perl "$openssl_source/Configure" darwin64-arm64-cc \
        no-shared no-tests no-apps no-docs \
        --prefix="$prefix" --openssldir="$prefix/ssl"
    make -j4 build_sw
    make install_sw
) >>"$log" 2>&1 || {
    tail -100 "$log" >&2
    exit 1
}

(
    cd "$curl_build"
    PKG_CONFIG_PATH="$prefix/lib/pkgconfig" sh "$curl_source/configure" \
        --prefix="$prefix" \
        --with-openssl="$prefix" \
        --with-apple-sectrust \
        --enable-threaded-resolver \
        --disable-shared --enable-static --enable-http \
        --disable-ftp --disable-file --disable-ipfs --disable-ldap --disable-ldaps \
        --disable-rtsp --disable-proxy --disable-dict --disable-telnet --disable-tftp \
        --disable-pop3 --disable-imap --disable-smb --disable-smtp --disable-gopher \
        --disable-mqtt --without-zlib --without-brotli --without-zstd --without-libpsl \
        --without-libidn2 \
        --disable-docs --disable-manual --disable-libcurl-option --disable-dependency-tracking
    make -j4
    make install
) >>"$log" 2>&1 || {
    tail -100 "$log" >&2
    exit 1
}

test "$("$prefix/bin/curl" --version | sed -n '1s/^curl \([^ ]*\).*/\1/p')" = "8.22.0"
"$prefix/bin/openssl" version 2>/dev/null | grep '^OpenSSL 3.6.3 ' >/dev/null || \
    grep '^# *define OPENSSL_VERSION_STR "3.6.3"' "$prefix/include/openssl/opensslv.h" >/dev/null
test -f "$prefix/lib/libcurl.a"
test -f "$prefix/lib/libssl.a"
test -f "$prefix/lib/libcrypto.a"
