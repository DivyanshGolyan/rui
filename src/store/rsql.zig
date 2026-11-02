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
// rendered at comptime and checked against its `Args` and `Row`.
//
// What the check covers, and nothing more:
// - Args fields bind ?1..?N in field order. SQL parameters carry no names,
//   so only the count is checked: the text uses exactly ?1..?N.
// - A read's Row fields carry, in order, the names of the columns its
//   SELECT returns: the alias after AS, or a bare or qualified column's
//   own name. Any other column needs an AS. A SessionHead field takes the
//   three columns `session_ref,workspace_key,next_position`, and a Row
//   holds at most one, so no two fields of one type can trade places.
// - A write to a table that carries Sessions names one Session, with the
//   marker `@session(?k)` on its session_ref (see `sessionError`).

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
/// next_position`. A write names its Session with one, through the marker
/// `@session(?k)`, which binds its reference; the Access that queues the
/// write records the touch from it without a read.
pub const SessionHead = struct {
    ref: change_ring.Id,
    workspace_key: Positive,
    next_position: Positive,
};

/// How many rows a read returns. Nothing is unbounded. A row past the
/// first is looked for only when its keys do not already rule it out
/// (`pinsOneRow`).
pub const Cardinality = union(enum) {
    /// Exactly one; none, or a second, is `CorruptStore`.
    one,
    /// None or one; a second is `CorruptStore`.
    optional,
    /// Up to this many; one more is `CorruptStore`.
    at_most: u16,
    /// Each row in turn to the visitor of `Access.readEach`, which steps
    /// at most the limit it is given. The bound is not a `LIMIT ?k`: a
    /// bound LIMIT would make SQLite re-prepare the statement on every use.
    each,
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
        // `.one` and `.at_most` decode in place; an `.optional` or `.each` Row is copied.
        if ((spec.cardinality == .optional or spec.cardinality == .each) and @sizeOf(spec.Row) > 1024)
            @compileError("rsql: a Row over 1 KiB is never copied; read it .one or .at_most(1): " ++ spec.sql);
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
            .each => void,
        };
        pub const sql = renderStatement(spec.sql, fieldCount(Args));
        pub const uses_now = usesNow(spec.sql);
        /// Whether the text alone limits the result to one row
        /// (`returnsOneRow`), so a read need not step again to prove there
        /// is no second.
        pub const single_row = returnsOneRow(spec.sql);
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
        /// The Args field `@session` binds, when the write names a Session.
        pub const session_field: ?[]const u8 = sessionField(Args);
    };
}

pub const StatementKind = enum { read, write };

/// Why a typed statement's text disagrees with its types, or null.
pub fn statementError(comptime kind: StatementKind, comptime sql: []const u8, comptime Args: type, comptime Row: type) ?[]const u8 {
    comptime {
        @setEvalBranchQuota(400 * sql.len + 10_000);
        if (portabilityError(sql, typed_rules)) |message| return message;
        const tokens = tokenize(sql);
        switch (kind) {
            .read => if (!isWord(tokens, 0, "SELECT")) return "rsql: a read starts with SELECT",
            .write => if (targetTable(tokens) == null) return "rsql: a write starts with INSERT INTO, UPDATE or DELETE FROM",
        }
        const arguments = fieldCount(Args);
        const uses = parameterUses(sql);
        var highest: usize = 0;
        for (uses, 1..) |count, number| {
            if (count != 0) highest = number;
        }
        if (highest != arguments) return std.fmt.comptimePrint("rsql: Args has {d} fields but the text binds up to ?{d}", .{ arguments, highest });
        for (uses[0..highest], 1..) |count, number| if (count == 0) return std.fmt.comptimePrint("rsql: ?{d} is never used", .{number});
        return switch (kind) {
            .read => if (sessionField(Args) != null) "rsql: a read binds no SessionHead; it names a Session by its reference text" else rowError(tokens, Row),
            .write => sessionError(tokens, Args, uses),
        };
    }
}

/// A token of Rui SQL, at the parenthesis depth it starts in: a marker
/// with its arguments is one token.
const Token = struct {
    kind: enum { word, parameter, number, literal, marker, symbol },
    text: []const u8,
    depth: usize,

    fn is(token: Token, word: []const u8) bool {
        return token.kind == .word and std.ascii.eqlIgnoreCase(token.text, word);
    }

    fn isSymbol(token: Token, symbol: u8) bool {
        return token.kind == .symbol and token.text[0] == symbol;
    }

    /// A marker's name: `session` for `@session(?2)`.
    fn markerName(token: Token) []const u8 {
        return token.text[1..wordEnd(token.text, 1)];
    }

    /// The text inside a marker's parentheses.
    fn markerArgument(token: Token) []const u8 {
        const open = wordEnd(token.text, 1);
        if (open == token.text.len) return "";
        return std.mem.trim(u8, token.text[open + 1 .. token.text.len - 1], " \n");
    }
};

/// `sql` as tokens. String literals and markers are single tokens, so no
/// check reads inside a literal.
fn tokenize(comptime sql: []const u8) []const Token {
    comptime {
        var tokens: []const Token = &.{};
        var depth: usize = 0;
        var index: usize = 0;
        while (index < sql.len) {
            const byte = sql[index];
            if (std.ascii.isWhitespace(byte)) {
                index += 1;
                continue;
            }
            const start = index;
            var kind: @FieldType(Token, "kind") = .symbol;
            if (byte == '\'') {
                kind = .literal;
                index = literalEnd(sql, index);
            } else if (isWordStart(byte)) {
                kind = .word;
                index = wordEnd(sql, index);
            } else if (byte == '?') {
                kind = .parameter;
                index = wordEnd(sql, index + 1);
            } else if (std.ascii.isDigit(byte)) {
                kind = .number;
                index = wordEnd(sql, index);
            } else if (byte == '@') {
                kind = .marker;
                index = wordEnd(sql, index + 1);
                if (index < sql.len and sql[index] == '(') index = closingParenthesis(sql, index) + 1;
            } else {
                index += 1;
                if (byte == ')') depth -|= 1;
            }
            tokens = tokens ++ .{Token{ .kind = kind, .text = sql[start..index], .depth = depth }};
            if (kind == .symbol and byte == '(') depth += 1;
        }
        return tokens;
    }
}

fn isWord(comptime tokens: []const Token, comptime index: usize, comptime word: []const u8) bool {
    return index < tokens.len and tokens[index].is(word);
}

/// How many times the text uses each of ?1..?64, string literals skipped
/// and markers' arguments included.
fn parameterUses(comptime sql: []const u8) [64]usize {
    comptime {
        var uses: [64]usize = @splat(0);
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
            const number = std.fmt.parseInt(usize, sql[index + 1 .. end], 10) catch @compileError("rsql: write parameters as ?N: " ++ sql);
            if (number == 0 or number > uses.len) @compileError("rsql: a parameter is ?1 to ?64: " ++ sql);
            uses[number - 1] += 1;
            index = end;
        }
        return uses;
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

/// The table after INSERT INTO, UPDATE or DELETE FROM, or null.
fn targetTable(comptime tokens: []const Token) ?[]const u8 {
    const at: usize = if (isWord(tokens, 0, "UPDATE"))
        1
    else if ((isWord(tokens, 0, "INSERT") and isWord(tokens, 1, "INTO")) or (isWord(tokens, 0, "DELETE") and isWord(tokens, 1, "FROM")))
        2
    else
        return null;
    return if (at < tokens.len and tokens[at].kind == .word) tokens[at].text else null;
}

/// Why `Row` does not name the SELECT's columns in order, or null.
fn rowError(comptime tokens: []const Token, comptime Row: type) ?[]const u8 {
    comptime {
        var expected: []const []const u8 = &.{};
        var heads: usize = 0;
        const info = @typeInfo(Row).@"struct";
        for (info.field_names, info.field_types) |name, Field| {
            if (Field == SessionHead) {
                heads += 1;
                expected = expected ++ .{ "session_ref", "workspace_key", "next_position" };
            } else expected = expected ++ .{name};
        }
        if (heads > 1) return "rsql: a Row holds at most one SessionHead";
        const columns = selectColumns(tokens);
        if (columns.len != expected.len) return std.fmt.comptimePrint("rsql: the text selects {d} columns but Row has {d}", .{ columns.len, expected.len });
        for (columns, expected, 1..) |column, field, number| {
            const name = columnName(column) orelse return std.fmt.comptimePrint("rsql: name column {d} with AS", .{number});
            if (!std.mem.eql(u8, name, field)) return std.fmt.comptimePrint("rsql: column {d} is {s} but Row's field is {s}", .{ number, name, field });
        }
        return null;
    }
}

/// The result columns of a SELECT, each as its tokens: split at commas at
/// depth 0 before its FROM.
fn selectColumns(comptime tokens: []const Token) []const []const Token {
    comptime {
        var columns: []const []const Token = &.{};
        var start: usize = 1;
        var index: usize = 1;
        while (index < tokens.len and !(tokens[index].depth == 0 and tokens[index].is("FROM"))) : (index += 1) {
            if (tokens[index].depth == 0 and tokens[index].isSymbol(',')) {
                columns = columns ++ .{tokens[start..index]};
                start = index + 1;
            }
        }
        return columns ++ .{tokens[start..index]};
    }
}

/// A result column's name: its alias after AS, or the name of a bare or
/// qualified column. Null for an expression without an alias.
fn columnName(comptime column: []const Token) ?[]const u8 {
    const n = column.len;
    if (n >= 3 and column[n - 2].is("AS") and column[n - 1].kind == .word) return column[n - 1].text;
    if (n == 1 and column[0].kind == .word) return column[0].text;
    if (n == 3 and column[0].kind == .word and column[1].isSymbol('.') and column[2].kind == .word) return column[2].text;
    return null;
}

/// Why a write's Session is unnamed or named anywhere but on its table's
/// own `session_ref`, or null. A write to a table that carries Sessions
/// (`schema.carriesSessions`) carries exactly one marker `@session(?k)`, where ?k is a SessionHead
/// field used nowhere else, and:
/// - an INSERT of one row gives it as the `session_ref` value;
/// - an UPDATE or DELETE has the conjunct `session_ref=@session(?k)`
///   directly after WHERE or AND and before AND or the end, in a WHERE
///   with no OR or BETWEEN outside parentheses, and names `session_ref`
///   nowhere else outside parentheses.
/// So every row it writes belongs to the Session that ?k's head names. A
/// write to any other table binds no SessionHead and writes no marker.
///
/// A table with a second Session column (message_admission and
/// sent_rejection's `sender_session_ref`) is refused here until PR 5
/// converts its writers: the marker extends to it as a second
/// `@session(?j)` on that column, and the Access touches both heads.
fn sessionError(comptime tokens: []const Token, comptime Args: type, comptime uses: [64]usize) ?[]const u8 {
    comptime {
        const table = targetTable(tokens).?;
        if (schema.hasColumn(table, "sender_session_ref")) return "rsql: " ++ table ++ " names a second Session; its typed writes come with PR 5";
        var markers: []const usize = &.{};
        for (tokens, 0..) |token, index| {
            if (token.kind == .marker and std.mem.eql(u8, token.markerName(), "session")) markers = markers ++ .{index};
        }
        const fields = @typeInfo(Args).@"struct".field_types;
        if (!schema.carriesSessions(table)) {
            if (markers.len != 0) return "rsql: " ++ table ++ " carries no Sessions; write no @session";
            for (fields) |Field| if (Field == SessionHead) return "rsql: " ++ table ++ " carries no Sessions; bind no SessionHead";
            return null;
        }
        if (markers.len != 1) return "rsql: a write to " ++ table ++ " names its Session exactly once, as @session(?k)";
        const marker_token = tokens[markers[0]];
        const argument = marker_token.markerArgument();
        if (argument.len < 2 or argument[0] != '?') return "rsql: @session takes one parameter, ?k";
        const k = std.fmt.parseInt(usize, argument[1..], 10) catch return "rsql: @session takes one parameter, ?k";
        if (k == 0 or k > fields.len or fields[k - 1] != SessionHead) return "rsql: @session(?k) binds a SessionHead field of Args";
        if (uses[k - 1] != 1) return "rsql: the SessionHead ?k binds is used only in @session(?k)";
        return if (tokens[0].is("INSERT")) insertSessionError(tokens, markers[0]) else whereSessionError(tokens, markers[0]);
    }
}

fn insertSessionError(comptime tokens: []const Token, comptime marker_index: usize) ?[]const u8 {
    comptime {
        const misplaced = "rsql: an INSERT names its Session as the session_ref value of one VALUES row";
        if (!(tokens.len > 4 and tokens[3].isSymbol('('))) return misplaced;
        var column: ?usize = null;
        var count: usize = 0;
        var index: usize = 4;
        while (index < tokens.len and !(tokens[index].depth == 0 and tokens[index].isSymbol(')'))) : (index += 1) {
            if (tokens[index].depth != 1) continue;
            if (tokens[index].isSymbol(',')) count += 1 else if (tokens[index].is("session_ref")) column = count;
        }
        if (!isWord(tokens, index + 1, "VALUES") or !(index + 2 < tokens.len and tokens[index + 2].isSymbol('('))) return misplaced;
        // The value at `column`'s place: a lone token between depth-1 commas.
        var found = false;
        var value: usize = 0;
        var start = index + 3;
        index = start;
        while (index < tokens.len and !(tokens[index].depth == 0 and tokens[index].isSymbol(')'))) : (index += 1) {
            if (tokens[index].depth == 1 and tokens[index].isSymbol(',')) {
                value += 1;
                start = index + 1;
            } else if (index == marker_index) {
                const end = index + 1 < tokens.len and tokens[index + 1].depth <= 1 and (tokens[index + 1].isSymbol(',') or tokens[index + 1].isSymbol(')'));
                if (column == null or value != column.? or start != index or !end) return misplaced;
                found = true;
            }
        }
        if (!found or index + 1 != tokens.len) return misplaced;
        if (value != count) return "rsql: an INSERT gives one value per column";
        return null;
    }
}

fn whereSessionError(comptime tokens: []const Token, comptime marker_index: usize) ?[]const u8 {
    comptime {
        const misplaced = "rsql: an UPDATE or DELETE names its Session as the conjunct session_ref=@session(?k) of its WHERE";
        var where: ?usize = null;
        for (tokens, 0..) |token, index| {
            if (token.depth != 0) continue;
            if (token.is("WHERE")) where = index;
            if (where != null and (token.is("OR") or token.is("BETWEEN"))) return "rsql: a WHERE that names a Session joins its terms with AND only, outside parentheses";
        }
        const at = where orelse return misplaced;
        if (marker_index < at + 3 or !tokens[marker_index - 2].is("session_ref") or !tokens[marker_index - 1].isSymbol('=') or tokens[marker_index].depth != 0) return misplaced;
        const before = tokens[marker_index - 3];
        if (!(before.depth == 0 and (before.is("WHERE") or before.is("AND")))) return misplaced;
        if (marker_index + 1 < tokens.len and !(tokens[marker_index + 1].depth == 0 and tokens[marker_index + 1].is("AND"))) return misplaced;
        for (tokens, 0..) |token, index| {
            if (token.depth == 0 and token.is("session_ref") and index != marker_index - 2) return misplaced;
        }
        return null;
    }
}

/// Whether a SELECT returns at most one row: it ends in `LIMIT 1`, or its
/// keys pin it (`pinsOneRow`).
fn returnsOneRow(comptime sql: []const u8) bool {
    comptime {
        @setEvalBranchQuota(400 * sql.len + 10_000);
        const tokens = tokenize(sql);
        const n = tokens.len;
        const limited = n >= 2 and tokens[n - 2].depth == 0 and tokens[n - 2].is("LIMIT") and
            tokens[n - 1].kind == .number and std.mem.eql(u8, tokens[n - 1].text, "1");
        return limited or pinsOneRow(sql);
    }
}

/// Whether a SELECT returns at most one row because of keys alone: every
/// table in its FROM is pinned, on all columns of one of its `schema.keys`,
/// by `=` terms to a parameter, a constant, or a column of a table already
/// pinned. The terms counted are an ON clause's and the WHERE's, each split
/// at AND outside parentheses; a condition with OR or BETWEEN outside
/// parentheses counts none. A bare column counts only with one table.
fn pinsOneRow(comptime sql: []const u8) bool {
    comptime {
        @setEvalBranchQuota(2000 * sql.len + 10_000);
        const tokens = tokenize(sql);
        const Source = struct { alias: []const u8, table: []const u8 };
        var sources: []const Source = &.{};
        var terms: []const []const Token = &.{};
        var index: usize = for (tokens, 0..) |token, at| {
            if (token.depth == 0 and token.is("FROM")) break at + 1;
        } else return false;
        while (true) {
            // A table, then its alias, with or without AS.
            if (index >= tokens.len or tokens[index].kind != .word) return false;
            const table = tokens[index].text;
            index += 1;
            while (index < tokens.len and tokens[index].kind == .marker) index += 1;
            if (isWord(tokens, index, "AS")) index += 1;
            var alias = table;
            if (index < tokens.len and tokens[index].kind == .word and !isClauseWord(tokens[index])) {
                alias = tokens[index].text;
                index += 1;
            }
            sources = sources ++ .{Source{ .alias = alias, .table = table }};
            if (isWord(tokens, index, "ON")) {
                const end = clauseEnd(tokens, index + 1);
                terms = terms ++ conjuncts(tokens[index + 1 .. end]);
                index = end;
            }
            if (index < tokens.len and tokens[index].isSymbol(',')) {
                index += 1;
                continue;
            }
            while (index < tokens.len and (tokens[index].is("INNER") or tokens[index].is("LEFT") or tokens[index].is("OUTER") or tokens[index].is("CROSS"))) index += 1;
            if (isWord(tokens, index, "JOIN")) {
                index += 1;
                continue;
            }
            break;
        }
        if (isWord(tokens, index, "WHERE")) terms = terms ++ conjuncts(tokens[index + 1 .. clauseEnd(tokens, index + 1)]);
        var pinned: [sources.len]bool = @splat(false);
        var changed = true;
        while (changed) {
            changed = false;
            for (sources, &pinned) |source, *done| {
                if (done.*) continue;
                done.* = for (schema.keys(source.table)) |key| {
                    const all = for (key) |column| {
                        const fixed = for (terms) |term| {
                            if (fixes(term, sources, &pinned, source.alias, column)) break true;
                        } else false;
                        if (!fixed) break false;
                    } else true;
                    if (all) break true;
                } else false;
                changed = changed or done.*;
            }
        }
        return for (pinned) |done| {
            if (!done) break false;
        } else true;
    }
}

/// A word that ends a FROM item: never an alias.
fn isClauseWord(comptime token: Token) bool {
    for ([_][]const u8{ "ON", "JOIN", "INNER", "LEFT", "OUTER", "CROSS", "WHERE", "GROUP", "ORDER", "LIMIT", "HAVING", "UNION" }) |word| {
        if (token.is(word)) return true;
    }
    return false;
}

/// The index of the first clause word at depth 0 from `start`, or the end.
fn clauseEnd(comptime tokens: []const Token, comptime start: usize) usize {
    var index = start;
    while (index < tokens.len) : (index += 1) {
        if (tokens[index].depth == 0 and (isClauseWord(tokens[index]) or tokens[index].isSymbol(','))) return index;
    }
    return index;
}

/// A condition's terms: split at AND outside parentheses, or none when OR
/// or BETWEEN stands outside parentheses.
fn conjuncts(comptime tokens: []const Token) []const []const Token {
    comptime {
        if (tokens.len == 0) return &.{};
        const depth = tokens[0].depth;
        for (tokens) |token| {
            if (token.depth == depth and (token.is("OR") or token.is("BETWEEN"))) return &.{};
        }
        var terms: []const []const Token = &.{};
        var start: usize = 0;
        for (tokens, 0..) |token, index| {
            if (token.depth == depth and token.is("AND")) {
                terms = terms ++ .{tokens[start..index]};
                start = index + 1;
            }
        }
        return terms ++ .{tokens[start..]};
    }
}

/// Whether `term` is `alias.column = value` (either way round), where the
/// value is a parameter, a constant, or a column of a pinned table.
fn fixes(comptime term: []const Token, comptime sources: anytype, comptime pinned: anytype, comptime alias: []const u8, comptime column: []const u8) bool {
    const equals = for (term, 0..) |token, at| {
        if (token.isSymbol('=')) break at;
    } else return false;
    if (equals == 0 or equals + 1 == term.len) return false;
    const sides = [2][]const Token{ term[0..equals], term[equals + 1 ..] };
    for (sides, 0..) |side, which| {
        const other = sides[1 - which];
        if (!names(side, sources, alias, column)) continue;
        if (other.len == 1 and (other[0].kind == .parameter or other[0].kind == .number or other[0].kind == .literal)) return true;
        if (other.len == 1 and other[0].kind == .marker and std.mem.eql(u8, other[0].markerName(), "session")) return true;
        for (sources, pinned) |source, done| {
            if (!done or std.mem.eql(u8, source.alias, alias)) continue;
            for (schema.columnsOf(source.table)) |candidate| {
                if (names(other, sources, source.alias, candidate)) return true;
            }
        }
    }
    return false;
}

/// Whether `side` is exactly the column `alias.column`: qualified, or bare
/// when the FROM has one table.
fn names(comptime side: []const Token, comptime sources: anytype, comptime alias: []const u8, comptime column: []const u8) bool {
    if (side.len == 3 and side[0].kind == .word and side[1].isSymbol('.') and side[2].kind == .word)
        return std.mem.eql(u8, side[0].text, alias) and std.mem.eql(u8, side[2].text, column);
    return side.len == 1 and side[0].kind == .word and sources.len == 1 and std.mem.eql(u8, side[0].text, column);
}

fn usesNow(comptime sql: []const u8) bool {
    comptime {
        @setEvalBranchQuota(400 * sql.len + 10_000);
        for (tokenize(sql)) |token| {
            if (token.kind == .marker and std.mem.eql(u8, token.markerName(), "now")) return true;
        }
        return false;
    }
}

/// Typed statement text in SQLite's spelling: `@now` binds the Access's
/// second as the parameter after Args, `@session(?k)` is `?k`,
/// `@index(name)` is `INDEXED BY name` for an index the schema has, and
/// the other markers as `render`.
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
                index = name_end;
                start = index;
                continue;
            }
            if (!std.mem.eql(u8, name, "index") and !std.mem.eql(u8, name, "session")) {
                index = name_end;
                continue;
            }
            if (name_end >= sql.len or sql[name_end] != '(') @compileError("rsql: @" ++ name ++ " needs its argument in parentheses: " ++ sql);
            const close = closingParenthesis(sql, name_end);
            const argument = std.mem.trim(u8, sql[name_end + 1 .. close], " \n");
            if (std.mem.eql(u8, name, "index")) {
                if (!schema.hasIndex(argument)) @compileError("rsql: no index named " ++ argument ++ " in the schema: " ++ sql);
                out = out ++ sql[start..index] ++ "INDEXED BY " ++ argument;
            } else out = out ++ sql[start..index] ++ argument;
            index = close + 1;
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

test "a typed statement renders @now after its Args, @session as its parameter and @index as INDEXED BY" {
    const S = Read(.{
        .sql = "SELECT action_id FROM action_operation @index(action_operation_executable) WHERE action_id>?1 AND attempt_at<=@now",
        .Args = struct { after: u64 },
        .Row = struct { action_id: Positive },
        .cardinality = .optional,
    });
    try std.testing.expectEqualStrings("SELECT action_id FROM action_operation INDEXED BY action_operation_executable WHERE action_id>?1 AND attempt_at<=?2", S.sql);
    try std.testing.expect(S.uses_now);
    const W = Write(.{
        .sql = "UPDATE turn SET outcome_at=@now WHERE turn_id=?1 AND session_ref=@session(?2)",
        .Args = struct { turn_id: u64, session: SessionHead },
        .expect = .{ .at_most = 1 },
    });
    try std.testing.expectEqualStrings("UPDATE turn SET outcome_at=?3 WHERE turn_id=?1 AND session_ref=?2", W.sql);
    try std.testing.expectEqualStrings("session", W.session_field.?);
}

test "@now inside a string literal is text, not the Host's second" {
    const S = Read(.{
        .sql = "SELECT content_id FROM content WHERE content_id=?1 AND CAST(payload AS TEXT)<>'@now'",
        .Args = struct { content_id: u64 },
        .Row = struct { content_id: Positive },
        .cardinality = .optional,
    });
    try std.testing.expect(!S.uses_now);
    try std.testing.expectEqualStrings("SELECT content_id FROM content WHERE content_id=?1 AND CAST(payload AS TEXT)<>'@now'", S.sql);
}

test "a typed statement's text must agree with its Args and Row" {
    const One = struct { a: u64 };
    const Two = struct { a: u64, b: u64 };
    try std.testing.expectEqualStrings("rsql: Args has 2 fields but the text binds up to ?1", comptime statementError(.read, "SELECT 1 FROM content WHERE content_id=?1", Two, One).?);
    try std.testing.expectEqualStrings("rsql: ?1 is never used", comptime statementError(.read, "SELECT 1 FROM content WHERE content_id=?2", Two, One).?);
    try std.testing.expectEqualStrings("rsql: the text selects 2 columns but Row has 1", comptime statementError(.read, "SELECT content_id,(SELECT max(a,b) FROM x) FROM content WHERE content_id=?1", One, One).?);
    try std.testing.expectEqualStrings("rsql: the text selects 3 columns but Row has 1", comptime statementError(.read, "SELECT session_ref,workspace_key,next_position FROM session WHERE created_seq=?1", One, One).?);
    try std.testing.expectEqual(@as(?[]const u8, null), comptime statementError(.read, "SELECT s.session_ref,s.workspace_key,s.next_position FROM session s WHERE created_seq=?1", One, struct { head: SessionHead }));
    try std.testing.expectEqualStrings("rsql: a read starts with SELECT", comptime statementError(.read, "UPDATE content SET private=0", struct {}, One).?);
}

test "a Row's fields are the SELECT's column names, in order" {
    const Id = struct { turn_id: u64 };
    const sql = "SELECT turn_id,operation_id FROM turn WHERE turn_id=?1";
    try std.testing.expectEqual(@as(?[]const u8, null), comptime statementError(.read, sql, Id, struct { turn_id: u64, operation_id: u64 }));
    try std.testing.expectEqualStrings("rsql: column 1 is turn_id but Row's field is operation_id", comptime statementError(.read, sql, Id, struct { operation_id: u64, turn_id: u64 }).?);
    try std.testing.expectEqualStrings("rsql: name column 1 with AS", comptime statementError(.read, "SELECT count(*) FROM turn WHERE turn_id=?1", Id, struct { total: u64 }).?);
    try std.testing.expectEqual(@as(?[]const u8, null), comptime statementError(.read, "SELECT count(*) AS total FROM turn WHERE turn_id=?1", Id, struct { total: u64 }));
    try std.testing.expectEqualStrings("rsql: column 2 is next_position but Row's field is workspace_key", comptime statementError(.read, "SELECT session_ref,next_position,workspace_key FROM session WHERE created_seq=?1", Id, struct { head: SessionHead }).?);
    try std.testing.expectEqualStrings("rsql: a Row holds at most one SessionHead", comptime statementError(.read, "SELECT session_ref,workspace_key,next_position,session_ref,workspace_key,next_position FROM session WHERE created_seq=?1", Id, struct { a: SessionHead, b: SessionHead }).?);
}

test "a write names its Session with @session on its table's own session_ref" {
    const Turn = struct { turn_id: u64, session: SessionHead };
    const once = "rsql: a write to turn names its Session exactly once, as @session(?k)";
    const misplaced = "rsql: an UPDATE or DELETE names its Session as the conjunct session_ref=@session(?k) of its WHERE";
    // The review's input: a head is bound, but nothing ties it to the row.
    try std.testing.expectEqualStrings(once, comptime statementError(.write, "UPDATE turn SET outcome_at=@now WHERE turn_id=?1 AND ?2 IS NOT NULL", Turn, void).?);
    try std.testing.expectEqualStrings("rsql: the SessionHead ?k binds is used only in @session(?k)", comptime statementError(.write, "UPDATE turn SET outcome_at=@now WHERE turn_id=?1 AND session_ref=@session(?2) AND ?2 IS NOT NULL", Turn, void).?);
    try std.testing.expectEqualStrings("rsql: a WHERE that names a Session joins its terms with AND only, outside parentheses", comptime statementError(.write, "UPDATE turn SET outcome_at=1 WHERE turn_id=?1 OR session_ref=@session(?2)", Turn, void).?);
    try std.testing.expectEqualStrings(misplaced, comptime statementError(.write, "UPDATE turn SET outcome_at=1 WHERE turn_id=?1 AND NOT session_ref=@session(?2)", Turn, void).?);
    try std.testing.expectEqualStrings(misplaced, comptime statementError(.write, "UPDATE turn SET outcome_at=1 WHERE turn_id=?1 AND session_ref<>@session(?2)", Turn, void).?);
    try std.testing.expectEqualStrings(misplaced, comptime statementError(.write, "UPDATE turn SET outcome_at=1 WHERE turn_id=?1 AND operation_id IN (SELECT operation_id FROM model_operation WHERE session_ref=@session(?2))", Turn, void).?);
    try std.testing.expectEqualStrings(misplaced, comptime statementError(.write, "UPDATE turn SET session_ref=@session(?2) WHERE turn_id=?1", Turn, void).?);
    try std.testing.expectEqualStrings(misplaced, comptime statementError(.write, "UPDATE turn SET session_ref='x' WHERE turn_id=?1 AND session_ref=@session(?2)", Turn, void).?);
    try std.testing.expectEqualStrings("rsql: @session(?k) binds a SessionHead field of Args", comptime statementError(.write, "UPDATE turn SET outcome_at=1 WHERE session_ref=@session(?1) AND turn_id=?2", struct { turn_id: u64, session: SessionHead }, void).?);
    try std.testing.expectEqual(@as(?[]const u8, null), comptime statementError(.write, "UPDATE turn SET outcome_at=@now WHERE turn_id=?1 AND session_ref=@session(?2) AND (outcome_code IS NULL OR outcome_code='x')", Turn, void));
    try std.testing.expectEqual(@as(?[]const u8, null), comptime statementError(.write, "DELETE FROM turn WHERE session_ref=@session(?2) AND turn_id=?1", Turn, void));

    const Stop = struct { key: []const u8, session: SessionHead, turn_id: u64 };
    const inserted = "rsql: an INSERT names its Session as the session_ref value of one VALUES row";
    try std.testing.expectEqual(@as(?[]const u8, null), comptime statementError(.write, "INSERT INTO session_stop(command_key,session_ref,selected_turn_id,admission_cutoff,stopped_at) VALUES(?1,@session(?2),?3,0,@now)", Stop, void));
    try std.testing.expectEqualStrings(inserted, comptime statementError(.write, "INSERT INTO session_stop(session_ref,command_key,selected_turn_id,admission_cutoff,stopped_at) VALUES(?1,@session(?2),?3,0,@now)", Stop, void).?);
    try std.testing.expectEqualStrings(inserted, comptime statementError(.write, "INSERT INTO session_stop(command_key,session_ref,selected_turn_id,admission_cutoff,stopped_at) VALUES(?1,coalesce(@session(?2),'x'),?3,0,@now)", Stop, void).?);
    try std.testing.expectEqualStrings(inserted, comptime statementError(.write, "INSERT INTO session_stop(command_key,session_ref,selected_turn_id,admission_cutoff,stopped_at) SELECT ?1,@session(?2),?3,0,@now", Stop, void).?);
    try std.testing.expectEqualStrings(inserted, comptime statementError(.write, "INSERT INTO session_stop(command_key,session_ref,selected_turn_id,admission_cutoff,stopped_at) VALUES(?1,@session(?2),?3,0,@now),(?1,'other',?3,0,@now)", Stop, void).?);
}

test "a write to a table that carries no Sessions names no Session" {
    try std.testing.expectEqualStrings("rsql: content carries no Sessions; bind no SessionHead", comptime statementError(.write, "DELETE FROM content WHERE content_id=?1 AND ?2 IS NOT NULL", struct { id: u64, session: SessionHead }, void).?);
    try std.testing.expectEqualStrings("rsql: sent_rejection names a second Session; its typed writes come with PR 5", comptime statementError(.write, "DELETE FROM sent_rejection WHERE sender_session_ref=?1", struct { ref: []const u8 }, void).?);
    try std.testing.expectEqual(@as(?[]const u8, null), comptime statementError(.write, "INSERT INTO content(content_id) VALUES(?1)", struct { turn_id: u64 }, void));
    // A command's target text, which need not name a Session.
    try std.testing.expectEqual(@as(?[]const u8, null), comptime statementError(.write, "DELETE FROM model_interruption_command WHERE session_ref=?1", struct { target: []const u8 }, void));
}

test "typed statements are held to the dialect rules" {
    const None = struct {};
    try std.testing.expectEqualStrings("rsql: 'INDEXED' is not portable; write @index(name)", comptime statementError(.read, "SELECT 1 FROM turn INDEXED BY turn_unpositioned", None, struct { a: u64 }).?);
    try std.testing.expectEqualStrings("rsql: 'RETURNING' is not portable; the Host allocates identities; read facts in an earlier round", comptime statementError(.write, "DELETE FROM content RETURNING content_id", None, void).?);
    try std.testing.expectEqualStrings("rsql: 'unixepoch' is not portable; write @now, the Host's second", comptime statementError(.write, "UPDATE content SET private=unixepoch()", None, void).?);
    try std.testing.expectEqualStrings("rsql: 'INSERT OR' is not portable; read in an earlier round, then guard the write", comptime statementError(.write, "INSERT OR IGNORE INTO content(content_id) VALUES(1)", None, void).?);
    try std.testing.expectEqualStrings("rsql: 'IS' compares only with NULL; write @same(a,b) or @distinct(a,b)", comptime statementError(.write, "UPDATE content SET private=1 WHERE private IS 0", None, void).?);
}

test "a read is keyed to one row only when keys pin every table it reads" {
    try std.testing.expect(comptime pinsOneRow("SELECT content_id FROM content WHERE digest=?1 AND byte_length=?2 AND private=?3"));
    try std.testing.expect(comptime pinsOneRow("SELECT s.session_ref FROM turn t JOIN session s ON s.session_ref=t.session_ref WHERE t.turn_id=?1 AND (?2 IS NULL OR t.operation_id=?2)"));
    try std.testing.expect(comptime pinsOneRow("SELECT o.turn_id FROM action_operation a JOIN model_operation o ON o.operation_id=a.parent_operation_id WHERE a.action_id=?1"));
    // Not every column of a key, a key column compared with <, an OR, a
    // partial unique index, a bare column among two tables, an unpinned join.
    try std.testing.expect(!comptime pinsOneRow("SELECT content_id FROM content WHERE digest=?1 AND byte_length=?2"));
    try std.testing.expect(!comptime pinsOneRow("SELECT turn_id FROM turn WHERE turn_id<=?1"));
    try std.testing.expect(!comptime pinsOneRow("SELECT turn_id FROM turn WHERE turn_id=?1 OR turn_id=?2"));
    try std.testing.expect(!comptime pinsOneRow("SELECT turn_id FROM turn WHERE session_ref=?1 AND outcome_code IS NULL"));
    try std.testing.expect(!comptime pinsOneRow("SELECT o.turn_id FROM action_operation a JOIN model_operation o ON o.operation_id=a.parent_operation_id WHERE action_id=?1"));
    try std.testing.expect(!comptime pinsOneRow("SELECT a.action_id FROM model_operation o JOIN action_operation a ON a.parent_operation_id=o.operation_id WHERE o.operation_id=?1"));
    try std.testing.expect(comptime returnsOneRow("SELECT turn_id FROM turn WHERE turn_id<=?1 ORDER BY turn_id LIMIT 1"));
    try std.testing.expect(!comptime returnsOneRow("SELECT turn_id FROM turn WHERE turn_id<=?1 ORDER BY turn_id LIMIT 2"));
    try std.testing.expect(!comptime returnsOneRow("SELECT turn_id FROM turn WHERE turn_id IN (SELECT turn_id FROM turn LIMIT 1)"));
}
