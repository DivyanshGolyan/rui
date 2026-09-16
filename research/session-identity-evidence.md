# Session identity source evidence

Primary-source reading on 2026-09-11; no runtime measurements or qualification. [ARCHITECTURE.md](../ARCHITECTURE.md#workflow-identity-and-saved-calls) owns Rui identity behavior.

## Integer storage IDs

SQLite `INTEGER PRIMARY KEY` is a signed 64-bit row ID and already allocates an unused integer when omitted on insertion. The `AUTOINCREMENT` keyword specifically prevents automatically allocated IDs from reusing previously committed IDs after deletion; it adds sequence bookkeeping and overhead. Rolled-back IDs may be reused, gaps remain possible, and exhausting the signed positive range causes `SQLITE_FULL` with `AUTOINCREMENT`. [SQLite: Autoincrement](https://www.sqlite.org/autoinc.html)


## JavaScript representation

The safe JavaScript Number integer range ends at `2^53 - 1`; SQLite's positive signed-64 range is larger. A decimal string can preserve an integer identity across JS/JSON without numeric rounding. BigInt can represent larger integers, but ordinary JSON serialization throws for a BigInt unless custom conversion intervenes. [ECMAScript: Number.MAX_SAFE_INTEGER](https://tc39.es/ecma262/multipage/numbers-and-dates.html#sec-number.max_safe_integer), [ECMAScript: SerializeJSONProperty](https://tc39.es/ecma262/multipage/structured-data.html#sec-serializejsonproperty)
