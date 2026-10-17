# Third-party notices

This file lists build-time and runtime-linked dependencies, evaluator-boundary test dependencies and measurement-only components distributed or used with Rui. Versions and source hashes are pinned in `build.zig.zon`; measurement-only Go modules are pinned in `tests/qualification/go.mod`.

## libvaxis 0.6.0 (commit d4c3b3666e0c090e2b5092ca09893c6db15e0b79)

The alternate-screen conversation frontend uses libvaxis for cell drawing and
terminal-sequence parsing. Rui retains terminal entry and restoration custody.
`src/prepare_vaxis.sh` copies the pinned source into generated build output and
applies `src/vaxis-parser.patch`; the dependency archive remains unchanged.
The patch retains fragmented APC terminators, checks CSI associated-text scratch
capacity before UTF-8 encoding, and propagates cell-allocation failures through
rendering instead of logging and continuing. Width accumulation saturates at the
public width type's maximum rather than overflowing, so Rui can reject clusters
outside its cell/window limit through the normal restored-error path. A failed render may leave partial
output and inaccurate cached terminal state. Rui restores the terminal and exits;
another render or `queueRefresh` is not a recovery operation.

- Source: `https://github.com/rockorager/libvaxis` at `d4c3b3666e0c090e2b5092ca09893c6db15e0b79`
- Zig package content hash: `vaxis-0.6.0-BWNV_O8ODQBFLRjA4D0q75pHPh63iPu_v0yhpCwsAMaM`
- License: MIT, reproduced in the source distribution's `LICENSE` file

Copyright (c) 2023 Tim Culverhouse

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## translate-c 2.0.1

The build uses the official translator at commit
`f978dca0f2b2a782d06591989e80aae7c74d0183` from its Zig 0.17 maintenance branch.
Generated bindings import its `c_builtins.zig` and `helpers.zig` support code.
Its pinned Aro C parser is build-time only.

- Source: `https://codeberg.org/ziglang/translate-c`
- Zig package content hash: `translate_c-2.0.1-Q_BUWmVOBwDWdxpDb7n6-LpMznKteZvXbL_4r6DxB2_d`
- Aro source: `https://codeberg.org/ziglang/arocc` at `ffddc972f7a208bd6e254c27465407270fd8b60c`
- Aro package content hash: `aro-0.0.0-JSD1QqKGNwALqBes402gHE7CP3Ga6xHS1J4mjThB3ro4`
- License: MIT for both packages. Aro's Unicode data has the Unicode License V3, reproduced in its source distribution.

Copyright (c) Zig contributors
Copyright (c) 2021 Veikka Tuominen

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
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

## QuickJS-NG (commit 1ab8676f4b6d6d669baeb5f21790fb9734636a20)

The packaged private evaluator child links this pinned QuickJS-NG source, its
Rui-maintained bounded string reader and a small evaluator-only compiler policy
for Workflow modules. The build applies `src/evaluator_policy.patch` to a
generated translation unit; the pinned dependency archive remains unchanged.
Public durable Workflows are not yet implemented.

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
