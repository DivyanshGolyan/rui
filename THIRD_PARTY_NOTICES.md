# Third-party notices

## gopsutil v4.26.7

Only the opt-in Go measurement runners use gopsutil, for Host CPU, memory,
thread, descendant and Darwin disk-I/O counters; the runtime does not link it.

- Source: `https://github.com/shirou/gopsutil/releases/tag/v4.26.7`
- Go module: `github.com/shirou/gopsutil/v4 v4.26.7`
- License: MIT

Copyright (c) 2014-2017 shirou. Permission is granted, free of charge, to use,
copy, modify, merge, publish, distribute, sublicense and/or sell copies under
the conditions in the source distribution's `LICENSE` file. The software is
provided without warranty.

## SQLite 3.53.4

Rui compiles the pinned SQLite 3.53.4 amalgamation from Fossil check-in
`bf7c7f30031888f4e796e429ab3978879485`.

- Source: `https://www.sqlite.org/2026/sqlite-amalgamation-3530400.zip`
- Zig package content hash: `N-V-__8AAGVtrgCcOcmjrOJnagmnRyMrcKaOo09KbU-vu8w8`
- License: public domain

The author disclaims copyright to this source code. In place of a legal
notice, SQLite includes this blessing:

> May you do good and not evil.
> May you find forgiveness for yourself and forgive others.
> May you share freely, never taking more than you give.

## curl 8.22.0

Rui builds a pinned static curl 8.22.0 with HTTP, OpenSSL, Apple SecTrust on
macOS and the supported threaded asynchronous resolver.

- Source: `https://curl.se/download/curl-8.22.0.tar.xz`
- Zig package content hash: `N-V-__8AALJXUwHr71AwttzhEqqYTvFb_jz0EQ5Ou3OWpHBM`
- License: curl license, reproduced in the source archive's `COPYING` file

Copyright (c) Daniel Stenberg and contributors. Permission to use, copy,
modify and distribute the software for any purpose with or without fee is
granted under the conditions in that notice. The software is provided
without warranty.

## OpenSSL 3.6.3

Rui builds pinned static OpenSSL 3.6.3 as curl's TLS implementation.

- Source: `https://github.com/openssl/openssl/releases/download/openssl-3.6.3/openssl-3.6.3.tar.gz`
- Zig package content hash: `N-V-__8AAJgLCgiTl2NEdxbc2QusROj0-GIN3jrv7BgQDGwM`
- License: Apache License 2.0, reproduced in the source archive's `LICENSE.txt`

Copyright (c) 1998-2026 The OpenSSL Project Authors and copyright holders
identified in the source. Licensed under the Apache License, Version 2.0;
the license is available at `https://www.apache.org/licenses/LICENSE-2.0`.
