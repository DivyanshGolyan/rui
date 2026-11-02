//! Rui SQL: Store SQL text written once for every engine. Source text is SQLite
//! SQL restricted to a portable subset, plus markers that each engine renders
//! in its own spelling. The schema's checks and index predicates use it today;
//! every statement the Store caches passes the checks its rules enable.

const std = @import("std");
const change_ring = @import("../change_ring.zig");
const schema = @import("schema.zig");

pub const Dialect = enum { sqlite };

/// Which rule groups a check applies. Comments and double quotes are
/// always refused: they would hide text from the other rules.
pub const Rules = struct {
    /// Reserved names and `rowid`: `reserved_names_checked`.
    names: bool,
    /// Words, `||` and `IS` that some engine reads differently.
    dialect: bool,
};

/// A reserved word is a name, and refused, everywhere except the keyword
/// places in `keywords`; text never names `rowid`. The schema's names,
/// checks and predicates and every statement are held to this.
pub const reserved_names_checked = true;

pub const schema_rules: Rules = .{ .names = reserved_names_checked, .dialect = true };
/// The `cached`/`execute` statements, which still use `unixepoch`, `GLOB`,
/// `||` and `IS` comparisons. Typed statements (`Read`, `Write`) are held
/// to `typed_rules`.
pub const statement_rules: Rules = .{ .names = reserved_names_checked, .dialect = false };
pub const typed_rules: Rules = .{ .names = reserved_names_checked, .dialect = true };

/// Words reserved in at least one engine (SQLite 3.53, Postgres 17, MySQL 8.4).
const reserved_names = [_][]const u8{
    "key",  "keys",      "call",     "groups",    "rank",   "row",    "rows",   "window",  "range",
    "user", "lead",      "lag",      "order",     "limit",  "offset", "system", "lateral", "cube",
    "of",   "recursive", "interval", "condition", "signal",
};

/// Where a reserved word is a keyword rather than a name.
const Place = enum {
    /// Directly before `BY`.
    before_by,
    /// Directly before a parameter or a number.
    before_count,
    /// Directly after `WITH`.
    after_with,
    /// Directly before `(`: a window function's call.
    call,
    /// Directly inside the parentheses after `OVER`: a frame's unit.
    window,
};

/// The reserved words text may use as keywords, each in its one place.
/// `of` has none: no checked text uses it.
const keywords = [_]struct { word: []const u8, place: Place }{
    .{ .word = "order", .place = .before_by },
    .{ .word = "limit", .place = .before_count },
    .{ .word = "offset", .place = .before_count },
    .{ .word = "recursive", .place = .after_with },
    .{ .word = "lead", .place = .call },
    .{ .word = "lag", .place = .call },
    .{ .word = "rank", .place = .call },
    .{ .word = "rows", .place = .window },
    .{ .word = "range", .place = .window },
};

/// Words some engine lacks or reads differently, each with the portable form.
const forbidden_words = [_]struct { word: []const u8, fix: []const u8 }{
    .{ .word = "GLOB", .fix = "write @charset(column,'set') or @initial(column,'set')" },
    .{ .word = "typeof", .fix = "test IS NULL or IS NOT NULL" },
    .{ .word = "unixepoch", .fix = "write @now, the Host's second" },
    .{ .word = "INDEXED", .fix = "write @index(name)" },
    .{ .word = "RETURNING", .fix = "the Host allocates identities; read facts in an earlier round" },
    .{ .word = "last_insert_rowid", .fix = "take the identity from the Store" },
    .{ .word = "CONFLICT", .fix = "read in an earlier round, then guard the write" },
    .{ .word = "MATERIALIZED", .fix = "MySQL cannot update a table its CTE reads; key the writes from Zig" },
    .{ .word = "DEFERRABLE", .fix = "keys are checked as each row is written; write parents first" },
    .{ .word = "BEGIN", .fix = "the Access opens the transaction" },
    .{ .word = "COMMIT", .fix = "call Access.commit" },
    .{ .word = "ROLLBACK", .fix = "return the error; the entry point rolls back" },
};

/// Why `text` is not portable Rui SQL under `rules`, or null. String
/// literals are not inspected; comments and quoted identifiers are refused,
/// so nothing else escapes the scan.
pub fn portabilityError(comptime text: []const u8, comptime rules: Rules) ?[]const u8 {
    comptime {
        @setEvalBranchQuota(100 * text.len + 1000);
        var index: usize = 0;
        // The word just scanned, or "" after any other token.
        var previous: []const u8 = "";
        var depth: usize = 0;
        // The depth of the open `OVER (` group, if any.
        var window_depth: ?usize = null;
        while (index < text.len) {
            const byte = text[index];
            const pair: []const u8 = text[index..@min(index + 2, text.len)];
            if (std.ascii.isWhitespace(byte)) {
                index += 1;
                continue;
            }
            if (byte == '\'') {
                index = literalEnd(text, index);
            } else if (rules.dialect and std.mem.eql(u8, pair, "||")) {
                return "rsql: '||' is OR on MySQL; compute the text in Zig";
            } else if (std.mem.eql(u8, pair, "--") or std.mem.eql(u8, pair, "/*")) {
                return "rsql: '" ++ pair ++ "' comments hide text from this check; write the note as a Zig comment";
            } else if (byte == '"') {
                return "rsql: '\"' quotes a name on Postgres but a string on MySQL; write names bare and strings in single quotes";
            } else if (isWordStart(byte)) {
                const word = text[index..wordEnd(text, index)];
                index += word.len;
                if (rules.dialect) {
                    for (forbidden_words) |forbidden| {
                        if (std.ascii.eqlIgnoreCase(word, forbidden.word)) return "rsql: '" ++ word ++ "' is not portable; " ++ forbidden.fix;
                    }
                    if (std.ascii.eqlIgnoreCase(previous, "INSERT") and std.ascii.eqlIgnoreCase(word, "OR"))
                        return "rsql: 'INSERT OR' is not portable; read in an earlier round, then guard the write";
                }
                if (rules.names) {
                    if (std.ascii.eqlIgnoreCase(word, "rowid")) return "rsql: 'rowid' is SQLite's hidden key; name an explicit INTEGER key column";
                    if (identifierError(word, true)) |message| {
                        if (!isKeyword(text, word, index, previous, window_depth != null and window_depth.? == depth)) return message;
                    }
                }
                if (rules.dialect and std.ascii.eqlIgnoreCase(word, "IS")) {
                    var next = nextWord(text, index);
                    if (std.ascii.eqlIgnoreCase(next, "NOT")) next = nextWord(text, skipSpace(text, index) + next.len);
                    if (!std.ascii.eqlIgnoreCase(next, "NULL")) return "rsql: 'IS' compares only with NULL; write @same(a,b) or @distinct(a,b)";
                }
                previous = word;
                continue;
            } else if (byte == '@' or std.ascii.isDigit(byte)) {
                index = wordEnd(text, index + 1);
            } else {
                if (byte == '(') {
                    depth += 1;
                    if (std.ascii.eqlIgnoreCase(previous, "OVER")) window_depth = depth;
                } else if (byte == ')') {
                    if (window_depth != null and window_depth.? == depth) window_depth = null;
                    depth -|= 1;
                }
                index += 1;
            }
            previous = "";
        }
        return null;
    }
}

/// Whether reserved `word`, which ends at `end`, stands in its keyword place.
fn isKeyword(comptime text: []const u8, comptime word: []const u8, comptime end: usize, comptime previous: []const u8, comptime in_window: bool) bool {
    for (keywords) |keyword| {
        if (!std.ascii.eqlIgnoreCase(word, keyword.word)) continue;
        const next = skipSpace(text, end);
        return switch (keyword.place) {
            .before_by => std.ascii.eqlIgnoreCase(nextWord(text, end), "BY"),
            .before_count => next < text.len and (text[next] == '?' or std.ascii.isDigit(text[next])),
            .after_with => std.ascii.eqlIgnoreCase(previous, "WITH"),
            .call => end < text.len and text[end] == '(',
            .window => in_window,
        };
    }
    return false;
}

/// The word after any space from `from`, or "" when a non-word follows.
fn nextWord(comptime text: []const u8, comptime from: usize) []const u8 {
    const start = skipSpace(text, from);
    return text[start..wordEnd(text, start)];
}

/// Fails the build on a statement that breaks `statement_rules`.
pub fn checkStatement(comptime sql: []const u8) void {
    comptime {
        if (portabilityError(sql, statement_rules)) |message| @compileError(message ++ ": " ++ sql);
    }
}

/// Why `name` cannot name a table, column or index on every engine, or null.
pub fn identifierError(comptime name: []const u8, comptime reserved: bool) ?[]const u8 {
    if (!reserved) return null;
    for (reserved_names) |word| {
        if (std.ascii.eqlIgnoreCase(name, word)) return "rsql: '" ++ name ++ "' is reserved on some engine; rename it";
    }
    return null;
}

/// `text` in `dialect`'s spelling. Fails the build on text that is not
/// portable or on an unknown or malformed marker:
///
///   @octets(x)           bytes in x: `length(CAST(x AS BLOB))`
///   @charset(c,'set')    only these characters: `(c NOT GLOB '*[^set]*' AND
///                        length(c)=length(CAST(c AS BLOB)))`. GLOB stops
///                        at a NUL; the set is ASCII, so characters equal
///                        bytes exactly when no NUL hides the rest
///   @initial(c,'set')    first character in the set: `c GLOB '[set]*'`
///   @same(a,b)           null-safe equality: `(a IS b)`
///   @distinct(a,b)       its negation: `(a IS NOT b)`
pub fn render(comptime dialect: Dialect, comptime text: []const u8) []const u8 {
    comptime {
        if (portabilityError(text, schema_rules)) |message| @compileError(message ++ ": " ++ text);
        return switch (dialect) {
            .sqlite => renderSqlite(text),
        };
    }
}

// Typed statements. Each is a type made by `Read` or `Write`: its Rui SQL
// rendered at comptime, its `Args` (field order is ?1..?N) and its `Row`
// (field order is column order), each checked against the text.

/// A stored integer that is never 0 or negative: an id or a position.
pub const Positive = enum(u64) {
    _,

    pub fn of(value: u64) Positive {
        std.debug.assert(value > 0 and value <= std.math.maxInt(i64));
        return @fromBackingInt(@intCast(value));
    }

    pub fn get(self: Positive) u64 {
        return @backingInt(self);
    }
};

/// A Session as a round loaded it: its reference, its Workspace's key and
/// its next position, from the columns `session_ref,workspace_key,
/// next_position`. As an argument it binds the reference. A write to a
/// table that carries Sessions binds exactly one, so the Access that queues
/// it records the touch without a read.
pub const SessionHead = struct {
    ref: change_ring.Id,
    workspace_key: Positive,
    next_position: Positive,
};

/// How many rows a read returns. Nothing is unbounded.
pub const Cardinality = union(enum) {
    /// Exactly one; none, or a second, is `CorruptStore`.
    one,
    /// None or one; a second is `CorruptStore`.
    optional,
    /// Up to this many; one more is `CorruptStore`.
    at_most: u16,
};

pub fn Rows(comptime Row: type, comptime max: u16) type {
    return struct {
        items: [max]Row = undefined,
        len: u16 = 0,

        pub fn slice(self: *const @This()) []const Row {
            return self.items[0..self.len];
        }
    };
}

/// The rows a write must change, or its round fails before COMMIT.
pub const Expect = union(enum) {
    exact: struct { rows: u32, otherwise: anyerror },
    /// More is `CorruptStore`.
    at_most: u32,
};

pub const ReadSpec = struct { sql: []const u8, Args: type, Row: type, cardinality: Cardinality };
pub const WriteSpec = struct { sql: []const u8, Args: type, expect: Expect };

pub fn Read(comptime spec: ReadSpec) type {
    comptime {
        if (statementError(.read, spec.sql, spec.Args, spec.Row)) |message| @compileError(message ++ ": " ++ spec.sql);
    }
    return struct {
        pub const kind: StatementKind = .read;
        pub const Args = spec.Args;
        pub const Row = spec.Row;
        pub const cardinality = spec.cardinality;
        pub const Result = switch (spec.cardinality) {
            .one => Row,
            .optional => ?Row,
            .at_most => |max| Rows(Row, max),
        };
        pub const sql = renderStatement(spec.sql, fieldCount(Args));
        pub const uses_now = usesNow(spec.sql);
    };
}

pub fn Write(comptime spec: WriteSpec) type {
    comptime {
        if (statementError(.write, spec.sql, spec.Args, void)) |message| @compileError(message ++ ": " ++ spec.sql);
    }
    return struct {
        pub const kind: StatementKind = .write;
        pub const Args = spec.Args;
        pub const expect = spec.expect;
        pub const sql = renderStatement(spec.sql, fieldCount(Args));
        pub const uses_now = usesNow(spec.sql);
        /// The Args field naming the Session this write changes, when its
        /// table carries Sessions.
        pub const session_field: ?[]const u8 = sessionField(Args);
    };
}

pub const StatementKind = enum { read, write };

/// Why a typed statement's text disagrees with its types, or null.
pub fn statementError(comptime kind: StatementKind, comptime sql: []const u8, comptime Args: type, comptime Row: type) ?[]const u8 {
    comptime {
        @setEvalBranchQuota(200 * sql.len + 10_000);
        if (portabilityError(sql, typed_rules)) |message| return message;
        const first = nextWord(sql, 0);
        switch (kind) {
            .read => if (!std.ascii.eqlIgnoreCase(first, "SELECT")) return "rsql: a read starts with SELECT",
            .write => if (targetTable(sql) == null) return "rsql: a write starts with INSERT INTO, UPDATE or DELETE FROM",
        }
        const arguments = fieldCount(Args);
        var bound: [64]bool = @splat(false);
        var highest: usize = 0;
        var index: usize = 0;
        while (index < sql.len) {
            if (sql[index] == '\'') {
                index = literalEnd(sql, index);
                continue;
            }
            if (sql[index] != '?') {
                index += 1;
                continue;
            }
            const end = wordEnd(sql, index + 1);
            const number = std.fmt.parseInt(usize, sql[index + 1 .. end], 10) catch return "rsql: write parameters as ?N";
            if (number == 0 or number > bound.len) return "rsql: a parameter is ?1 to ?64";
            bound[number - 1] = true;
            highest = @max(highest, number);
            index = end;
        }
        if (highest != arguments) return std.fmt.comptimePrint("rsql: Args has {d} fields but the text binds up to ?{d}", .{ arguments, highest });
        for (bound[0..highest], 1..) |used, number| if (!used) return std.fmt.comptimePrint("rsql: ?{d} is never used", .{number});

        switch (kind) {
            .read => {
                const columns = selectColumns(sql);
                var expected: usize = 0;
                for (@typeInfo(Row).@"struct".field_types) |Field| expected += columnsOf(Field);
                if (columns != expected) return std.fmt.comptimePrint("rsql: the text selects {d} columns but Row has {d}", .{ columns, expected });
            },
            .write => {
                var heads: usize = 0;
                for (@typeInfo(Args).@"struct".field_types) |Field| heads += @intFromBool(Field == SessionHead);
                const table = targetTable(sql).?;
                if (schema.carriesSessions(table)) {
                    if (heads != 1) return "rsql: a write to " ++ table ++ ", which carries Sessions, binds exactly one SessionHead";
                } else if (heads != 0) return "rsql: " ++ table ++ " carries no Sessions; bind no SessionHead";
            },
        }
        return null;
    }
}

fn fieldCount(comptime T: type) usize {
    return @typeInfo(T).@"struct".field_names.len;
}

fn sessionField(comptime Args: type) ?[]const u8 {
    const info = @typeInfo(Args).@"struct";
    for (info.field_names, info.field_types) |name, Field| if (Field == SessionHead) return name;
    return null;
}

/// The columns a value of `T` reads: a SessionHead three, any other one.
fn columnsOf(comptime T: type) usize {
    return if (T == SessionHead) 3 else 1;
}

/// The table after INSERT INTO, UPDATE or DELETE FROM, or null.
fn targetTable(comptime sql: []const u8) ?[]const u8 {
    const first = nextWord(sql, 0);
    var after = skipSpace(sql, 0) + first.len;
    if (std.ascii.eqlIgnoreCase(first, "INSERT") or std.ascii.eqlIgnoreCase(first, "DELETE")) {
        const second = nextWord(sql, after);
        const want = if (std.ascii.eqlIgnoreCase(first, "INSERT")) "INTO" else "FROM";
        if (!std.ascii.eqlIgnoreCase(second, want)) return null;
        after = skipSpace(sql, after) + second.len;
    } else if (!std.ascii.eqlIgnoreCase(first, "UPDATE")) return null;
    const table = nextWord(sql, after);
    return if (table.len == 0) null else table;
}

/// The result columns of a SELECT: commas at depth 0 before its FROM.
fn selectColumns(comptime sql: []const u8) usize {
    var columns: usize = 1;
    var depth: usize = 0;
    var index = skipSpace(sql, 0) + "SELECT".len;
    while (index < sql.len) {
        const byte = sql[index];
        if (byte == '\'') {
            index = literalEnd(sql, index);
            continue;
        }
        if (isWordStart(byte)) {
            const end = wordEnd(sql, index);
            if (depth == 0 and std.ascii.eqlIgnoreCase(sql[index..end], "FROM")) break;
            index = end;
            continue;
        }
        switch (byte) {
            '(' => depth += 1,
            ')' => depth -= 1,
            ',' => if (depth == 0) {
                columns += 1;
            },
            else => {},
        }
        index += 1;
    }
    return columns;
}

fn usesNow(comptime sql: []const u8) bool {
    @setEvalBranchQuota(20 * sql.len + 1000);
    return std.mem.indexOf(u8, sql, "@now") != null;
}

/// Typed statement text in SQLite's spelling: `@now` binds the Access's
/// second as the parameter after Args, `@index(name)` is `INDEXED BY name`
/// for an index the schema has, and the other markers as `render`.
fn renderStatement(comptime sql: []const u8, comptime arguments: usize) [:0]const u8 {
    comptime {
        @setEvalBranchQuota(200 * sql.len + 10_000);
        var out: []const u8 = "";
        var start: usize = 0;
        var index: usize = 0;
        while (index < sql.len) {
            if (sql[index] == '\'') {
                index = literalEnd(sql, index);
                continue;
            }
            if (sql[index] != '@') {
                index += 1;
                continue;
            }
            const name_end = wordEnd(sql, index + 1);
            const name = sql[index + 1 .. name_end];
            if (std.mem.eql(u8, name, "now")) {
                out = out ++ sql[start..index] ++ std.fmt.comptimePrint("?{d}", .{arguments + 1});
            } else if (std.mem.eql(u8, name, "index")) {
                if (name_end >= sql.len or sql[name_end] != '(') @compileError("rsql: @index needs a name in parentheses: " ++ sql);
                const close = closingParenthesis(sql, name_end);
                const index_name = std.mem.trim(u8, sql[name_end + 1 .. close], " ");
                if (!schema.hasIndex(index_name)) @compileError("rsql: no index named " ++ index_name ++ " in the schema: " ++ sql);
                out = out ++ sql[start..index] ++ "INDEXED BY " ++ index_name;
                index = close + 1;
                start = index;
                continue;
            } else {
                index = name_end;
                continue;
            }
            index = name_end;
            start = index;
        }
        const text = renderSqlite(out ++ sql[start..]) ++ "\x00";
        return text[0 .. text.len - 1 :0];
    }
}

fn renderSqlite(comptime text: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(100 * text.len + 1000);
        var out: []const u8 = "";
        var start: usize = 0;
        var index: usize = 0;
        while (index < text.len) {
            if (text[index] == '\'') {
                index = literalEnd(text, index);
                continue;
            }
            if (text[index] != '@') {
                index += 1;
                continue;
            }
            out = out ++ text[start..index];
            const name_end = wordEnd(text, index + 1);
            const name = text[index + 1 .. name_end];
            if (name_end >= text.len or text[name_end] != '(') @compileError("rsql: @" ++ name ++ " needs arguments in parentheses: " ++ text);
            const close = closingParenthesis(text, name_end);
            const arguments = splitArguments(text[name_end + 1 .. close]);
            out = out ++ marker(name, arguments, text);
            index = close + 1;
            start = index;
        }
        return out ++ text[start..];
    }
}

fn marker(comptime name: []const u8, comptime arguments: []const []const u8, comptime text: []const u8) []const u8 {
    const Marker = enum { octets, charset, initial, same, distinct };
    const kind = std.meta.stringToEnum(Marker, name) orelse @compileError("rsql: unknown marker @" ++ name ++ ": " ++ text);
    const arity: usize = if (kind == .octets) 1 else 2;
    if (arguments.len != arity) @compileError("rsql: @" ++ name ++ " takes " ++ std.fmt.comptimePrint("{d}", .{arity}) ++ " arguments: " ++ text);
    const first = renderSqlite(arguments[0]);
    return switch (kind) {
        .octets => "length(CAST(" ++ first ++ " AS BLOB))",
        .charset => "(" ++ first ++ " NOT GLOB '*[^" ++ characterSet(arguments[1], text) ++ "]*' AND length(" ++ first ++ ")=length(CAST(" ++ first ++ " AS BLOB)))",
        .initial => first ++ " GLOB '[" ++ characterSet(arguments[1], text) ++ "]*'",
        .same => "(" ++ first ++ " IS " ++ renderSqlite(arguments[1]) ++ ")",
        .distinct => "(" ++ first ++ " IS NOT " ++ renderSqlite(arguments[1]) ++ ")",
    };
}

/// The characters of a set literal such as 'a-z0-9_-': ranges and single
/// characters only, so every engine's bracket expression reads it alike.
fn characterSet(comptime literal: []const u8, comptime text: []const u8) []const u8 {
    if (literal.len < 3 or literal[0] != '\'' or literal[literal.len - 1] != '\'') @compileError("rsql: a character set is one quoted literal: " ++ text);
    const set = literal[1 .. literal.len - 1];
    for (set) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') @compileError("rsql: a character set holds letters, digits, '_' and ranges: " ++ text);
    }
    return set;
}

fn splitArguments(comptime inner: []const u8) []const []const u8 {
    comptime {
        var arguments: []const []const u8 = &.{};
        var depth: usize = 0;
        var start: usize = 0;
        var index: usize = 0;
        while (index < inner.len) {
            switch (inner[index]) {
                '\'' => {
                    index = literalEnd(inner, index);
                    continue;
                },
                '(' => depth += 1,
                ')' => depth -= 1,
                ',' => if (depth == 0) {
                    arguments = arguments ++ .{std.mem.trim(u8, inner[start..index], " \n")};
                    start = index + 1;
                },
                else => {},
            }
            index += 1;
        }
        return arguments ++ .{std.mem.trim(u8, inner[start..], " \n")};
    }
}

fn closingParenthesis(comptime text: []const u8, comptime open: usize) usize {
    var depth: usize = 0;
    var index = open;
    while (index < text.len) {
        switch (text[index]) {
            '\'' => {
                index = literalEnd(text, index);
                continue;
            },
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return index;
            },
            else => {},
        }
        index += 1;
    }
    @compileError("rsql: unclosed parenthesis: " ++ text);
}

/// The index just past the string literal opening at `open` ('' escapes a quote).
fn literalEnd(comptime text: []const u8, comptime open: usize) usize {
    var index = open + 1;
    while (index < text.len) : (index += 1) {
        if (text[index] != '\'') continue;
        if (index + 1 < text.len and text[index + 1] == '\'') {
            index += 1;
            continue;
        }
        return index + 1;
    }
    @compileError("rsql: unclosed string literal: " ++ text);
}

fn isWordStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_';
}

fn wordEnd(comptime text: []const u8, comptime start: usize) usize {
    var index = start;
    while (index < text.len and (std.ascii.isAlphanumeric(text[index]) or text[index] == '_')) index += 1;
    return index;
}

fn skipSpace(comptime text: []const u8, comptime from: usize) usize {
    var index = from;
    while (index < text.len and std.ascii.isWhitespace(text[index])) index += 1;
    return index;
}

test "each marker renders its SQLite spelling" {
    try std.testing.expectEqualStrings("length(CAST(workspace AS BLOB))<=4096", comptime render(.sqlite, "@octets(workspace)<=4096"));
    try std.testing.expectEqualStrings("(provider NOT GLOB '*[^a-z0-9_-]*' AND length(provider)=length(CAST(provider AS BLOB)))", comptime render(.sqlite, "@charset(provider,'a-z0-9_-')"));
    try std.testing.expectEqualStrings("provider GLOB '[a-z]*'", comptime render(.sqlite, "@initial(provider,'a-z')"));
    try std.testing.expectEqualStrings("(action_kind IS 1)", comptime render(.sqlite, "@same(action_kind,1)"));
    try std.testing.expectEqualStrings("(resolution_code IS NOT 'denied')", comptime render(.sqlite, "@distinct(resolution_code,'denied')"));
}

test "markers nest, and text outside them is copied" {
    try std.testing.expectEqualStrings(
        "x IS NULL OR (length(CAST(x AS BLOB))=6 AND (x NOT GLOB '*[^a-f]*' AND length(x)=length(CAST(x AS BLOB)))) AND '@octets(y)'='@'",
        comptime render(.sqlite, "x IS NULL OR (@octets(x)=6 AND @charset(x,'a-f')) AND '@octets(y)'='@'"),
    );
    try std.testing.expectEqualStrings("(length(CAST(a AS BLOB)) IS b)", comptime render(.sqlite, "@same(@octets(a), b)"));
}

test "non-portable text names its fix" {
    try std.testing.expectEqualStrings("rsql: 'GLOB' is not portable; write @charset(column,'set') or @initial(column,'set')", comptime portabilityError("x NOT GLOB '*[^a]*'", .{ .names = false, .dialect = true }).?);
    try std.testing.expectEqualStrings("rsql: 'typeof' is not portable; test IS NULL or IS NOT NULL", comptime portabilityError("typeof(x)='blob'", .{ .names = false, .dialect = true }).?);
    try std.testing.expectEqualStrings("rsql: 'unixepoch' is not portable; write @now, the Host's second", comptime portabilityError("at<=unixepoch()", .{ .names = false, .dialect = true }).?);
    try std.testing.expectEqualStrings("rsql: '||' is OR on MySQL; compute the text in Zig", comptime portabilityError("a||b='ab'", .{ .names = false, .dialect = true }).?);
    try std.testing.expectEqualStrings("rsql: 'IS' compares only with NULL; write @same(a,b) or @distinct(a,b)", comptime portabilityError("code IS 'x'", .{ .names = false, .dialect = true }).?);
    try std.testing.expectEqualStrings("rsql: 'IS' compares only with NULL; write @same(a,b) or @distinct(a,b)", comptime portabilityError("code IS NOT 1", .{ .names = false, .dialect = true }).?);
    try std.testing.expectEqualStrings("rsql: 'rowid' is SQLite's hidden key; name an explicit INTEGER key column", comptime portabilityError("rowid>1", .{ .names = true, .dialect = true }).?);
    try std.testing.expectEqual(@as(?[]const u8, null), comptime portabilityError("rowid>1", .{ .names = false, .dialect = true }));
    try std.testing.expectEqual(@as(?[]const u8, null), comptime portabilityError("a IS NULL AND b IS NOT NULL AND c='GLOB || IS 1' AND isolated=1", .{ .names = true, .dialect = true }));
    try std.testing.expectEqual(@as(?[]const u8, null), comptime portabilityError("a-1>0 AND b/2<3 AND c='-- /* \"'", .{ .names = true, .dialect = true }));
}

test "comments and double quotes cannot hide text from the check" {
    const comment = "rsql: '--' comments hide text from this check; write the note as a Zig comment";
    try std.testing.expectEqualStrings(comment, comptime portabilityError("a>0 -- it's\n AND b GLOB 'x'", .{ .names = false, .dialect = true }).?);
    try std.testing.expectEqualStrings(comment, comptime portabilityError("a>0 --", .{ .names = false, .dialect = true }).?);
    try std.testing.expectEqualStrings("rsql: '/*' comments hide text from this check; write the note as a Zig comment", comptime portabilityError("a>0 /* it's */ AND b GLOB 'x'", .{ .names = false, .dialect = true }).?);
    try std.testing.expectEqualStrings("rsql: '\"' quotes a name on Postgres but a string on MySQL; write names bare and strings in single quotes", comptime portabilityError("\"a'\" GLOB 'x'", .{ .names = false, .dialect = true }).?);
}

test "reserved names are refused once checked" {
    try std.testing.expectEqualStrings("rsql: 'key' is reserved on some engine; rename it", comptime identifierError("key", true).?);
    try std.testing.expectEqual(@as(?[]const u8, null), comptime identifierError("key", false));
    try std.testing.expectEqual(@as(?[]const u8, null), comptime identifierError("meta_key", true));
}

test "statements are held to reserved names and rowid, not yet to the dialect rules" {
    try std.testing.expectEqualStrings("rsql: 'call' is reserved on some engine; rename it", comptime portabilityError("SELECT call.x FROM model_tool_call call", statement_rules).?);
    try std.testing.expectEqualStrings("rsql: 'groups' is reserved on some engine; rename it", comptime portabilityError("WITH groups AS (SELECT 1) SELECT * FROM groups", statement_rules).?);
    try std.testing.expectEqualStrings("rsql: 'rowid' is SQLite's hidden key; name an explicit INTEGER key column", comptime portabilityError("SELECT max(rowid) FROM session", statement_rules).?);
    try std.testing.expectEqualStrings("rsql: '--' comments hide text from this check; write the note as a Zig comment", comptime portabilityError("SELECT 1 -- call", statement_rules).?);
    try std.testing.expectEqual(@as(?[]const u8, null), comptime portabilityError(
        "WITH RECURSIVE n(i) AS (SELECT 1) SELECT tool_call.x FROM n WHERE a GLOB 'call' AND b IS 1 ORDER BY i LIMIT 1 OFFSET 2",
        statement_rules,
    ));
}

test "a reserved word is a keyword only in its own place, and a name anywhere else" {
    const Case = struct { sql: []const u8, word: []const u8 };
    inline for ([_]Case{
        .{ .sql = "SELECT o.x FROM model_operation offset", .word = "offset" },
        .{ .sql = "SELECT 1 AS offset", .word = "offset" },
        .{ .sql = "SELECT o.offset FROM model_operation o", .word = "offset" },
        .{ .sql = "SELECT x FROM turn of", .word = "of" },
        .{ .sql = "SELECT x FROM turn order", .word = "order" },
        .{ .sql = "SELECT x FROM turn LIMIT x", .word = "LIMIT" },
        .{ .sql = "SELECT recursive FROM turn", .word = "recursive" },
        .{ .sql = "SELECT lead FROM turn", .word = "lead" },
        .{ .sql = "SELECT x AS rows FROM turn", .word = "rows" },
        .{ .sql = "SELECT sum(x) OVER (ORDER BY (SELECT range FROM t)) FROM turn", .word = "range" },
    }) |case| {
        try std.testing.expectEqualStrings("rsql: '" ++ case.word ++ "' is reserved on some engine; rename it", comptime portabilityError(case.sql, statement_rules).?);
    }
    inline for ([_][]const u8{
        "SELECT x FROM turn ORDER BY x LIMIT ?1 OFFSET ?2",
        "SELECT x FROM turn order\nby x limit 9",
        "WITH RECURSIVE n(i) AS (SELECT 1) SELECT i FROM n",
        "SELECT lead(x) OVER (PARTITION BY y ORDER BY z), lag(x,1) OVER (ORDER BY z), rank() OVER (ORDER BY z) FROM turn",
        "SELECT sum(x) OVER (ORDER BY z ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING) FROM turn",
        "SELECT sum(x) OVER (ORDER BY z RANGE BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) FROM turn",
    }) |sql| {
        try std.testing.expectEqual(@as(?[]const u8, null), comptime portabilityError(sql, statement_rules));
    }
}

test "a typed statement renders @now after its Args and @index as INDEXED BY" {
    const S = Read(.{
        .sql = "SELECT action_id FROM action_operation @index(action_operation_executable) WHERE action_id>?1 AND attempt_at<=@now",
        .Args = struct { after: u64 },
        .Row = struct { action_id: Positive },
        .cardinality = .optional,
    });
    try std.testing.expectEqualStrings("SELECT action_id FROM action_operation INDEXED BY action_operation_executable WHERE action_id>?1 AND attempt_at<=?2", S.sql);
    try std.testing.expect(S.uses_now);
    const W = Write(.{
        .sql = "UPDATE turn SET outcome_at=@now WHERE turn_id=?1 AND session_ref=?2",
        .Args = struct { turn_id: u64, session: SessionHead },
        .expect = .{ .at_most = 1 },
    });
    try std.testing.expectEqualStrings("session", W.session_field.?);
}

test "a typed statement's text must agree with its Args and Row" {
    const One = struct { a: u64 };
    const Two = struct { a: u64, b: u64 };
    try std.testing.expectEqualStrings("rsql: Args has 2 fields but the text binds up to ?1", comptime statementError(.read, "SELECT 1 FROM content WHERE content_id=?1", Two, One).?);
    try std.testing.expectEqualStrings("rsql: ?1 is never used", comptime statementError(.read, "SELECT 1 FROM content WHERE content_id=?2", Two, One).?);
    try std.testing.expectEqualStrings("rsql: the text selects 2 columns but Row has 1", comptime statementError(.read, "SELECT content_id,(SELECT max(a,b) FROM x) FROM content WHERE content_id=?1", One, One).?);
    try std.testing.expectEqualStrings("rsql: the text selects 3 columns but Row has 1", comptime statementError(.read, "SELECT session_ref,workspace_key,next_position FROM session WHERE created_seq=?1", One, One).?);
    try std.testing.expectEqual(@as(?[]const u8, null), comptime statementError(.read, "SELECT session_ref,workspace_key,next_position FROM session WHERE created_seq=?1", One, struct { head: SessionHead }));
    try std.testing.expectEqualStrings("rsql: a read starts with SELECT", comptime statementError(.read, "UPDATE content SET private=0", struct {}, One).?);
}

test "a write to a table that carries Sessions binds exactly one SessionHead" {
    const Turn = struct { turn_id: u64 };
    try std.testing.expectEqualStrings("rsql: a write to turn, which carries Sessions, binds exactly one SessionHead", comptime statementError(.write, "UPDATE turn SET outcome_at=1 WHERE turn_id=?1", Turn, void).?);
    try std.testing.expectEqualStrings("rsql: content carries no Sessions; bind no SessionHead", comptime statementError(.write, "DELETE FROM content WHERE content_id=?1 AND ?2 IS NOT NULL", struct { id: u64, session: SessionHead }, void).?);
    try std.testing.expectEqual(@as(?[]const u8, null), comptime statementError(.write, "INSERT INTO content(content_id) VALUES(?1)", Turn, void));
}

test "typed statements are held to the dialect rules" {
    const None = struct {};
    try std.testing.expectEqualStrings("rsql: 'INDEXED' is not portable; write @index(name)", comptime statementError(.read, "SELECT 1 FROM turn INDEXED BY turn_unpositioned", None, struct { a: u64 }).?);
    try std.testing.expectEqualStrings("rsql: 'RETURNING' is not portable; the Host allocates identities; read facts in an earlier round", comptime statementError(.write, "DELETE FROM content RETURNING content_id", None, void).?);
    try std.testing.expectEqualStrings("rsql: 'unixepoch' is not portable; write @now, the Host's second", comptime statementError(.write, "UPDATE content SET private=unixepoch()", None, void).?);
    try std.testing.expectEqualStrings("rsql: 'INSERT OR' is not portable; read in an earlier round, then guard the write", comptime statementError(.write, "INSERT OR IGNORE INTO content(content_id) VALUES(1)", None, void).?);
    try std.testing.expectEqualStrings("rsql: 'IS' compares only with NULL; write @same(a,b) or @distinct(a,b)", comptime statementError(.write, "UPDATE content SET private=1 WHERE private IS 0", None, void).?);
}

test "the tables that carry Sessions are the ones the touch oracle watches" {
    inline for (.{ "session", "session_revision", "message_admission", "sent_rejection", "turn", "session_stop", "model_operation", "action_operation", "conversation_entry", "model_output_item" }) |table| {
        try std.testing.expect(comptime schema.carriesSessions(table));
    }
    inline for (.{ "content", "core_command", "model_tool_call" }) |table| try std.testing.expect(!comptime schema.carriesSessions(table));
}
