# Third-party notices

This file lists runtime-linked dependencies, evaluator-boundary test dependencies and measurement-only components distributed or used with Rui. Versions and source hashes are pinned in `build.zig.zon`; measurement-only Go modules are pinned in `tests/qualification/go.mod`.

## QuickJS-NG (commit 1ab8676f4b6d6d669baeb5f21790fb9734636a20)

The `workflow-check` evaluator worker links this pinned QuickJS-NG source. It
is not installed with Rui until the Host owns a complete Workflow lifecycle.

- Source: `https://github.com/quickjs-ng/quickjs/archive/1ab8676f4b6d6d669baeb5f21790fb9734636a20.tar.gz`
- Archive SHA-256: `c788fe4f65c95ecfa4055c8778e7cb221f68fcc3315686627b0856da5c38514e`
- Zig package content hash: `N-V-__8AAC-eRACa__taXkae9pRIZde7nn8oQSxb9n9rhkFp`
- License: MIT, reproduced in the source archive's `LICENSE` file

The MIT License (MIT)

Copyright (c) 2017-2026 Fabrice Bellard
Copyright (c) 2017-2024 Charlie Gordon
Copyright (c) 2023-2026 Ben Noordhuis
Copyright (c) 2023-2026 Saúl Ibarra Corretgé

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

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

## utf8proc 2.11.3

The interactive CLI uses utf8proc's stateful Unicode grapheme boundaries.

- Source: `https://github.com/JuliaStrings/utf8proc/archive/refs/tags/v2.11.3.tar.gz`
- Zig package content hash: `N-V-__8AACywKABFCj0r_Y-jIWsk9ahy10zlk78hjn6S-39g`
- License: MIT for the code; Unicode data license. The complete upstream
  `LICENSE.md` is distributed alongside the source archive.

Copyright (c) 2014-2021 by Steven G. Johnson, Jiahao Chen, Tony Kelman,
Jonas Fonseca, and other contributors listed in the git history.
Copyright (c) 2009, 2013 Public Software Group e. V., Berlin, Germany.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is furnished
to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

The generated `utf8proc_data.c` is derived from Unicode data. Copyright (c)
1991-2007 Unicode, Inc. All rights reserved. Distributed under the Terms of
Use at `http://www.unicode.org/copyright.html`.

Permission is hereby granted, free of charge, to any person obtaining a copy
of the Unicode data files and any associated documentation (the "Data Files")
or Unicode software and any associated documentation (the "Software") to deal
in the Data Files or Software without restriction, including without limitation
the rights to use, copy, modify, merge, publish, distribute, and/or sell copies
of the Data Files or Software, and to permit persons to whom the Data Files or
Software are furnished to do so, provided that (a) the above copyright notice(s)
and this permission notice appear with all copies of the Data Files or Software,
(b) both the above copyright notice(s) and this permission notice appear in
associated documentation, and (c) there is clear notice in each modified Data
File or in the Software as well as in the documentation associated with the
Data File(s) or Software that the data or software has been modified.

THE DATA FILES AND SOFTWARE ARE PROVIDED "AS IS", WITHOUT WARRANTY OF ANY
KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF
THIRD PARTY RIGHTS. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR HOLDERS
INCLUDED IN THIS NOTICE BE LIABLE FOR ANY CLAIM, OR ANY SPECIAL INDIRECT OR
CONSEQUENTIAL DAMAGES, OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF
USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER
TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE
OF THE DATA FILES OR SOFTWARE.

Except as contained in this notice, the name of a copyright holder shall not
be used in advertising or otherwise to promote the sale, use or other dealings
in these Data Files or Software without prior written authorization of the
copyright holder.

Unicode and the Unicode logo are trademarks of Unicode, Inc., and may be
registered in some jurisdictions. All other trademarks and registered
trademarks mentioned herein are the property of their respective owners.

## curl 8.22.0

Rui builds a pinned static curl 8.22.0 with HTTP/2 via nghttp2, OpenSSL, Apple
SecTrust on macOS and the supported threaded asynchronous resolver. The build
patches curl's automatic zero-response reused-connection POST retry and POST
HTTP/2-to-HTTP/1.1 downgrade so an ambiguous POST is not silently replayed. It
also caps H2 per-stream receive credit at 16 KiB to limit paused-capture buffering.

- Source: `https://curl.se/download/curl-8.22.0.tar.xz`
- Zig package content hash: `N-V-__8AALJXUwHr71AwttzhEqqYTvFb_jz0EQ5Ou3OWpHBM`
- License: curl license, reproduced in the source archive's `COPYING` file

Copyright (c) Daniel Stenberg and contributors. Permission to use, copy,
modify and distribute the software for any purpose with or without fee is
granted under the conditions in that notice. The software is provided
without warranty.

## nghttp2 1.70.0

Rui links the pinned static nghttp2 library for HTTP/2 framing; HTTP/3/QUIC is
not built.

- Source: `https://github.com/nghttp2/nghttp2/releases/download/v1.70.0/nghttp2-1.70.0.tar.xz`
- Archive SHA-256: `e05cb1388eaca3830aded4ccf20044b6e1ac1a61411dcca11b0437c4285c8bc2`
- Zig package content hash: `N-V-__8AACay2gDbHrByjNGWvyH8G9Gp30uRgZqobYOF1nhb`
- License: MIT, reproduced in the source archive's `COPYING` file

Copyright (c) 2012, 2014, 2015, 2016 Tatsuhiro Tsujikawa and nghttp2
contributors. Permission is granted, free of
charge, to use, copy, modify, merge, publish, distribute, sublicense and/or
sell copies under the conditions in `COPYING`. The software is provided
without warranty.

## OpenSSL 3.6.3

Rui builds pinned static OpenSSL 3.6.3 as curl's TLS implementation.

- Source: `https://github.com/openssl/openssl/releases/download/openssl-3.6.3/openssl-3.6.3.tar.gz`
- Zig package content hash: `N-V-__8AAJgLCgiTl2NEdxbc2QusROj0-GIN3jrv7BgQDGwM`
- License: Apache License 2.0, reproduced in the source archive's `LICENSE.txt`

Copyright (c) 1998-2026 The OpenSSL Project Authors and copyright holders
identified in the source. Licensed under the Apache License, Version 2.0;
the license is available at `https://www.apache.org/licenses/LICENSE-2.0`.
