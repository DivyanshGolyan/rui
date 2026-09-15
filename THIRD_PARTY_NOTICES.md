# Third-party notices

## gopsutil v4.26.7

The opt-in Go measurement runners use gopsutil to read Host process CPU,
memory, thread, descendant and Darwin disk-I/O counters. It is not linked into
the Latifa runtime.

- Source: `https://github.com/shirou/gopsutil/releases/tag/v4.26.7`
- Go module: `github.com/shirou/gopsutil/v4 v4.26.7`
- License: MIT

Copyright (c) 2014-2017 shirou. Permission is granted, free of charge, to use,
copy, modify, merge, publish, distribute, sublicense and/or sell copies under
the conditions in the source distribution's `LICENSE` file. The software is
provided without warranty.

## SQLite 3.53.4

Latifa compiles the pinned SQLite 3.53.4 amalgamation from Fossil check-in
`bf7c7f30031888f4e796e429ab3978879485`.

- Source: `https://www.sqlite.org/2026/sqlite-amalgamation-3530400.zip`
- Zig package content hash: `N-V-__8AAGVtrgCcOcmjrOJnagmnRyMrcKaOo09KbU-vu8w8`
- License: public domain

The author disclaims copyright to this source code. In place of a legal
notice, SQLite includes this blessing:

> May you do good and not evil.
> May you find forgiveness for yourself and forgive others.
> May you share freely, never taking more than you give.
