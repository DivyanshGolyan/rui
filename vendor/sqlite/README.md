# SQLite amalgamation

OnePage compiles the official SQLite 3.53.4 amalgamation directly into its native artifacts.

- Source: `https://www.sqlite.org/2026/sqlite-amalgamation-3530400.zip`
- Archive SHA3-256: `628a44cfe82c66aed1ccbbe85a562d2e33ebe64b3288981ed76285612227934e`
- `sqlite3.c` SHA3-256: `67f423e9ebbbdc473cbc4772c872ee6b89f31fde4ed0279a5c25d5f65c043a16`

The compile-time profile is defined once in `build.zig`. Runtime hardening and limits belong to the
Storage Owner in `src/host_store.zig`.
