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

// Typed statements. Each is a type made by `Read` or `Write`. Its Rui SQL is
// parsed at comptime (`Parser`) in the grammar Rui writes, and text outside
// that grammar is refused, so no rule meets a shape it was not written for.
// The rules then read the parsed tree, each doc saying exactly what it checks:
// - `parameterError`: Args fields bind ?1..?N, in field order;
// - `rowError`: a read's Row fields name the columns it returns, in order;
// - `sessionError`: a write names its Session on its table's own session_ref;
// - `compoundError`: a compound SELECT stands only where `.compound` says so;
// - `returnsOneRow`: when a read needs no step to rule out a second row;
// - the markers, as they are parsed (`Parser.marker`, `Parser.source`).

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
/// first is looked for only when the text does not already rule it out
/// (`returnsOneRow`).
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

pub const ReadSpec = struct {
    sql: []const u8,
    Args: type,
    Row: type,
    cardinality: Cardinality,
    /// Whether the text holds a compound SELECT (UNION, INTERSECT or
    /// EXCEPT); such a read never counts as one row.
    compound: bool = false,
};
pub const WriteSpec = struct { sql: []const u8, Args: type, expect: Expect };

pub fn Read(comptime spec: ReadSpec) type {
    const parsed = comptime accepted(.read, spec.sql, spec.Args, spec.Row, spec.compound);
    comptime {
        // `.one` and `.at_most` decode in place; an `.each` Row is decoded
        // into the round's frame. `Access.read` refuses a big `.optional`.
        if (spec.cardinality == .each and @sizeOf(spec.Row) > 1024)
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
        pub const uses_now = parsed.uses_now;
        /// Whether the text alone limits the result to one row
        /// (`returnsOneRow`), so a read need not step again to prove there
        /// is no second.
        pub const single_row = returnsOneRow(parsed.statement.select);
    };
}

pub fn Write(comptime spec: WriteSpec) type {
    const parsed = comptime accepted(.write, spec.sql, spec.Args, void, false);
    return struct {
        pub const kind: StatementKind = .write;
        pub const Args = spec.Args;
        pub const expect = spec.expect;
        pub const sql = renderStatement(spec.sql, fieldCount(Args));
        pub const uses_now = parsed.uses_now;
        /// The Args field `@session` binds, when the write names a Session.
        pub const session_field: ?[]const u8 = sessionField(Args);
    };
}

pub const StatementKind = enum { read, write };

/// Why a typed statement's text is refused, or null.
pub fn statementError(comptime kind: StatementKind, comptime sql: []const u8, comptime Args: type, comptime Row: type) ?[]const u8 {
    return switch (check(kind, sql, Args, Row, false)) {
        .refused => |message| message,
        .accepted => null,
    };
}

const Checked = union(enum) { refused: []const u8, accepted: Parsed };

fn accepted(comptime kind: StatementKind, comptime sql: []const u8, comptime Args: type, comptime Row: type, comptime compound: bool) Parsed {
    return switch (check(kind, sql, Args, Row, compound)) {
        .refused => |message| @compileError(message ++ ": " ++ sql),
        .accepted => |parsed| parsed,
    };
}

/// Parses a typed statement, then holds it to every rule.
fn check(comptime kind: StatementKind, comptime sql: []const u8, comptime Args: type, comptime Row: type, comptime compound: bool) Checked {
    comptime {
        @setEvalBranchQuota(1000 * sql.len + 20_000);
        if (portabilityError(sql, typed_rules)) |message| return .{ .refused = message };
        const parsed = switch (parse(sql)) {
            .refused => |message| return .{ .refused = message },
            .accepted => |parsed| parsed,
        };
        if (kind == .read and parsed.statement != .select) return .{ .refused = "rsql: a read is a SELECT" };
        if (kind == .write and parsed.statement == .select) return .{ .refused = "rsql: a write is an INSERT, UPDATE or DELETE" };
        if (compoundError(kind, parsed, compound)) |message| return .{ .refused = message };
        if (parameterError(parsed.uses, Args)) |message| return .{ .refused = message };
        const refusal = switch (kind) {
            .read => if (readSessionError(parsed, Args)) |message| message else rowError(parsed.statement.select.first, Row),
            .write => sessionError(parsed, Args),
        };
        if (refusal) |message| return .{ .refused = message };
        return .{ .accepted = parsed };
    }
}

fn parse(comptime sql: []const u8) Checked {
    comptime {
        @setEvalBranchQuota(1000 * sql.len + 20_000);
        var p: Parser = .{ .tokens = tokenize(sql) };
        const statement = p.statement() catch return .{ .refused = p.message };
        return .{ .accepted = .{
            .statement = statement,
            .uses = p.uses,
            .sessions = p.sessions,
            .uses_now = p.uses_now,
            .compounds = p.compounds,
        } };
    }
}

/// A typed statement as the rules read it, and what its parse counted.
const Parsed = struct {
    statement: Statement,
    /// How many times the text uses each of ?1..?64, markers included.
    uses: [64]usize,
    /// The k of each `@session(?k)`, wherever it stands.
    sessions: []const usize,
    uses_now: bool,
    /// The compound SELECTs anywhere in the text, subqueries included.
    compounds: usize,
};

const Statement = union(enum) {
    select: Select,
    insert: struct {
        table: []const u8,
        columns: []const []const u8,
        values: union(enum) { row: []const Expr, select: Select },
    },
    update: struct { table: []const u8, assigned: []const []const u8, where: Expr },
    delete: struct { table: []const u8, where: Expr },
};

const Select = struct {
    /// The first SELECT of a compound, whose names the result takes.
    first: Core,
    compound: bool,
    /// Whether it ends in `LIMIT 1`.
    limit_one: bool,
};

const Core = struct { results: []const Result, sources: []const Source, where: ?Expr };

const Result = struct { value: Expr, alias: ?[]const u8 };

const Source = struct {
    table: []const u8,
    /// The table's own name when it has no alias.
    alias: []const u8,
    /// A name a WITH defined, never a table's (`Parser.select`).
    defined: bool,
    /// Joined with LEFT JOIN: its ON chooses only its own rows, and every
    /// row on its left stays.
    outer: bool,
    on: ?Expr,
};

const Column = struct { table: ?[]const u8, name: []const u8 };

/// An expression as the rules read it. Parts no rule reads are parsed in
/// full (their parameters, markers and subqueries count) and kept as
/// `other`; parentheses leave no node.
const Expr = union(enum) {
    column: Column,
    parameter: usize,
    /// A number, a string literal or NULL, as written.
    constant: []const u8,
    /// `@session(?k)`: k.
    session: usize,
    /// `a AND b AND ...`, nested ANDs flattened.
    conjunction: []const Expr,
    /// `a = b`.
    equality: *const [2]Expr,
    other,
};

/// A lexical token. A marker is its `@name`; its arguments follow as
/// tokens of their own. String literals are single tokens, so nothing
/// reads inside one.
const Token = struct {
    kind: enum { word, parameter, number, literal, marker, symbol, end },
    text: []const u8,

    fn is(token: Token, word: []const u8) bool {
        return token.kind == .word and std.ascii.eqlIgnoreCase(token.text, word);
    }

    fn isSymbol(token: Token, symbol: []const u8) bool {
        return token.kind == .symbol and std.mem.eql(u8, token.text, symbol);
    }
};

const two_byte_symbols = [_][]const u8{ "<=", ">=", "<>", "!=", "==", "||" };

fn tokenize(comptime sql: []const u8) []const Token {
    comptime {
        @setEvalBranchQuota(100 * sql.len + 1000);
        var tokens: []const Token = &.{};
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
            } else if (byte == '@' and index + 1 < sql.len and isWordStart(sql[index + 1])) {
                kind = .marker;
                index = wordEnd(sql, index + 1);
            } else {
                index += 1;
                for (two_byte_symbols) |symbol| {
                    if (std.mem.startsWith(u8, sql[start..], symbol)) index = start + 2;
                }
            }
            tokens = tokens ++ .{Token{ .kind = kind, .text = sql[start..index] }};
        }
        return tokens;
    }
}

/// The words the grammar reads as keywords; none of them is a name.
const grammar_words = [_][]const u8{
    "SELECT", "DISTINCT", "ALL",    "FROM",  "WHERE",   "GROUP",     "BY",      "HAVING",    "ORDER", "ASC",
    "DESC",   "LIMIT",    "OFFSET", "UNION", "EXCEPT",  "INTERSECT", "WITH",    "AS",        "JOIN",  "LEFT",
    "OUTER",  "INNER",    "CROSS",  "ON",    "AND",     "OR",        "NOT",     "IN",        "IS",    "NULL",
    "EXISTS", "CASE",     "WHEN",   "THEN",  "ELSE",    "END",       "CAST",    "INSERT",    "INTO",  "VALUES",
    "UPDATE", "SET",      "DELETE", "LIKE",  "BETWEEN", "ESCAPE",    "COLLATE", "RECURSIVE",
};

fn isGrammarWord(text: []const u8) bool {
    for (grammar_words) |word| if (std.ascii.eqlIgnoreCase(text, word)) return true;
    return false;
}

fn isTable(name: []const u8) bool {
    for (schema.tables) |table| if (std.mem.eql(u8, table.name, name)) return true;
    return false;
}

fn isIndexOf(table: []const u8, name: []const u8) bool {
    for (schema.indexes) |index| if (std.mem.eql(u8, index.name, name) and std.mem.eql(u8, index.table, table)) return true;
    return false;
}

const Refused = error{Refused};

/// A recursive descent parser for the SQL Rui writes, run at comptime:
///
///   statement := select | insert | update | delete
///   select    := [WITH [RECURSIVE] name [(names)] AS (select), ...]
///                core {UNION [ALL] | INTERSECT | EXCEPT core}
///                [ORDER BY expr [ASC|DESC], ...] [LIMIT expr [OFFSET expr]]
///   core      := SELECT [DISTINCT|ALL] expr [AS name], ... [FROM source
///                {[LEFT [OUTER] | INNER | CROSS] JOIN source}]
///                [WHERE expr] [GROUP BY expr, ... [HAVING expr]]
///   source    := table [@index(name)] [[AS] alias] [ON expr]
///   insert    := INSERT INTO table (names) (VALUES (expr, ...) | select)
///   update    := UPDATE table SET name=expr, ... WHERE expr
///   delete    := DELETE FROM table WHERE expr
///
/// Expressions take OR, AND, NOT, the comparisons (`=`, `==`, `<>`, `!=`,
/// `<`, `<=`, `>`, `>=`, IS [NOT] NULL, [NOT] IN (list or select)), `+`,
/// `-`, `*`, `/`, `%`, unary `-` and `+`, at SQLite's precedence; and as
/// operands columns, `?N`, numbers, string literals, NULL, markers,
/// function calls, CAST, CASE, EXISTS and parenthesized expressions or
/// subqueries. Anything else (a named parameter, `*` as a column, a
/// comma join, an unknown table, LIKE, BETWEEN, COLLATE, a window) is
/// refused with the token it stopped at.
const Parser = struct {
    tokens: []const Token,
    at: usize = 0,
    message: []const u8 = "",
    uses: [64]usize = @splat(0),
    sessions: []const usize = &.{},
    uses_now: bool = false,
    compounds: usize = 0,
    /// The names WITH clauses define for the select being parsed.
    defined: []const []const u8 = &.{},

    fn peek(p: *const Parser) Token {
        return p.peekAt(0);
    }

    fn peekAt(p: *const Parser, offset: usize) Token {
        return if (p.at + offset < p.tokens.len) p.tokens[p.at + offset] else .{ .kind = .end, .text = "" };
    }

    fn next(p: *Parser) Token {
        const token = p.peek();
        if (token.kind != .end) p.at += 1;
        return token;
    }

    fn accept(p: *Parser, word: []const u8) bool {
        if (!p.peek().is(word)) return false;
        p.at += 1;
        return true;
    }

    fn acceptSymbol(p: *Parser, symbol: []const u8) bool {
        if (!p.peek().isSymbol(symbol)) return false;
        p.at += 1;
        return true;
    }

    fn expect(p: *Parser, word: []const u8) Refused!void {
        if (!p.accept(word)) return p.refuse(word);
    }

    fn expectSymbol(p: *Parser, symbol: []const u8) Refused!void {
        if (!p.acceptSymbol(symbol)) return p.refuse("'" ++ symbol ++ "'");
    }

    /// Refuses the text at the next token, where `wanted` should stand.
    fn refuse(p: *Parser, wanted: []const u8) error{Refused} {
        const token = p.peek();
        return p.refuseWith("rsql: expected " ++ wanted ++ (if (token.kind == .end) " at the end" else " at '" ++ token.text ++ "'"));
    }

    fn refuseWith(p: *Parser, message: []const u8) error{Refused} {
        p.message = message;
        return error.Refused;
    }

    fn name(p: *Parser) Refused![]const u8 {
        const token = p.peek();
        if (token.kind != .word or isGrammarWord(token.text)) return p.refuse("a name");
        p.at += 1;
        return token.text;
    }

    fn nameList(p: *Parser) Refused![]const []const u8 {
        var written: []const []const u8 = &.{try p.name()};
        while (p.acceptSymbol(",")) written = written ++ .{try p.name()};
        return written;
    }

    fn expressions(p: *Parser) Refused![]const Expr {
        var values: []const Expr = &.{try p.expr()};
        while (p.acceptSymbol(",")) values = values ++ .{try p.expr()};
        return values;
    }

    fn startsSelect(p: *const Parser) bool {
        return p.peek().is("SELECT") or p.peek().is("WITH");
    }

    fn statement(p: *Parser) Refused!Statement {
        const parsed: Statement = if (p.startsSelect())
            .{ .select = try p.select() }
        else if (p.accept("INSERT"))
            try p.insert()
        else if (p.accept("UPDATE")) update: {
            const target = try p.tableName();
            try p.expect("SET");
            var assigned: []const []const u8 = &.{};
            while (true) {
                assigned = assigned ++ .{try p.name()};
                try p.expectSymbol("=");
                _ = try p.expr();
                if (!p.acceptSymbol(",")) break;
            }
            try p.expect("WHERE");
            break :update .{ .update = .{ .table = target, .assigned = assigned, .where = try p.expr() } };
        } else if (p.accept("DELETE")) delete: {
            try p.expect("FROM");
            const target = try p.tableName();
            try p.expect("WHERE");
            break :delete .{ .delete = .{ .table = target, .where = try p.expr() } };
        } else return p.refuse("SELECT, WITH, INSERT, UPDATE or DELETE");
        if (p.peek().kind != .end) return p.refuse("the end");
        return parsed;
    }

    fn tableName(p: *Parser) Refused![]const u8 {
        const written = try p.name();
        if (!isTable(written)) return p.refuseWith("rsql: no table named " ++ written);
        return written;
    }

    fn insert(p: *Parser) Refused!Statement {
        try p.expect("INTO");
        const table_name = try p.tableName();
        try p.expectSymbol("(");
        const columns = try p.nameList();
        try p.expectSymbol(")");
        if (p.accept("VALUES")) {
            try p.expectSymbol("(");
            const row = try p.expressions();
            try p.expectSymbol(")");
            if (p.peek().isSymbol(",")) return p.refuseWith("rsql: an INSERT writes one VALUES row");
            return .{ .insert = .{ .table = table_name, .columns = columns, .values = .{ .row = row } } };
        }
        if (!p.startsSelect()) return p.refuse("VALUES or SELECT");
        return .{ .insert = .{ .table = table_name, .columns = columns, .values = .{ .select = try p.select() } } };
    }

    /// A WITH name is visible to the rest of its select, subqueries
    /// included, and is never a table's name, so a source names one or
    /// the other.
    fn select(p: *Parser) Refused!Select {
        const outer_defined = p.defined;
        if (p.accept("WITH")) {
            _ = p.accept("RECURSIVE");
            while (true) {
                const defined = try p.name();
                if (isTable(defined)) return p.refuseWith("rsql: a WITH name is never a table's: " ++ defined);
                p.defined = p.defined ++ .{defined};
                if (p.acceptSymbol("(")) {
                    _ = try p.nameList();
                    try p.expectSymbol(")");
                }
                try p.expect("AS");
                try p.subquery();
                if (!p.acceptSymbol(",")) break;
            }
        }
        const first = try p.core();
        var compound = false;
        while (p.peek().is("UNION") or p.peek().is("INTERSECT") or p.peek().is("EXCEPT")) {
            if (p.accept("UNION")) _ = p.accept("ALL") else p.at += 1;
            _ = try p.core();
            compound = true;
        }
        if (compound) p.compounds += 1;
        if (p.accept("ORDER")) {
            try p.expect("BY");
            while (true) {
                _ = try p.expr();
                if (!p.accept("ASC")) _ = p.accept("DESC");
                if (!p.acceptSymbol(",")) break;
            }
        }
        var limit_one = false;
        if (p.accept("LIMIT")) {
            const limit = try p.expr();
            limit_one = limit == .constant and std.mem.eql(u8, limit.constant, "1");
            if (p.accept("OFFSET")) _ = try p.expr();
        }
        p.defined = outer_defined;
        return .{ .first = first, .compound = compound, .limit_one = limit_one };
    }

    /// `( select )`, parsed and counted, its tree dropped.
    fn subquery(p: *Parser) Refused!void {
        try p.expectSymbol("(");
        _ = try p.select();
        try p.expectSymbol(")");
    }

    fn core(p: *Parser) Refused!Core {
        try p.expect("SELECT");
        if (!p.accept("DISTINCT")) _ = p.accept("ALL");
        var results: []const Result = &.{};
        while (true) {
            const value = try p.expr();
            const alias: ?[]const u8 = if (p.accept("AS")) try p.name() else null;
            results = results ++ .{Result{ .value = value, .alias = alias }};
            if (!p.acceptSymbol(",")) break;
        }
        var sources: []const Source = &.{};
        if (p.accept("FROM")) {
            sources = sources ++ .{try p.source(false)};
            while (p.peek().is("JOIN") or p.peek().is("LEFT") or p.peek().is("INNER") or p.peek().is("CROSS")) {
                const outer = p.accept("LEFT");
                if (outer) _ = p.accept("OUTER") else if (!p.accept("INNER")) _ = p.accept("CROSS");
                try p.expect("JOIN");
                sources = sources ++ .{try p.source(outer)};
            }
        }
        const where: ?Expr = if (p.accept("WHERE")) try p.expr() else null;
        if (p.accept("GROUP")) {
            try p.expect("BY");
            _ = try p.expressions();
            if (p.accept("HAVING")) _ = try p.expr();
        }
        return .{ .results = results, .sources = sources, .where = where };
    }

    /// A table or WITH name. The only marker that may follow it is
    /// `@index(name)`, naming an index of that same table.
    fn source(p: *Parser, outer: bool) Refused!Source {
        const written = try p.name();
        const defined = for (p.defined) |each| {
            if (std.mem.eql(u8, each, written)) break true;
        } else false;
        if (!defined and !isTable(written)) return p.refuseWith("rsql: no table named " ++ written);
        if (p.peek().kind == .marker) {
            if (!std.mem.eql(u8, p.next().text, "@index")) return p.refuseWith("rsql: only @index(name) follows a table");
            try p.expectSymbol("(");
            const index = try p.name();
            try p.expectSymbol(")");
            if (defined or !isIndexOf(written, index)) return p.refuseWith("rsql: @index names an index of its own table, and " ++ written ++ " has no index " ++ index);
        }
        const alias = if (p.accept("AS")) try p.name() else if (p.peek().kind == .word and !isGrammarWord(p.peek().text)) p.next().text else written;
        const on: ?Expr = if (p.accept("ON")) try p.expr() else null;
        return .{ .table = written, .alias = alias, .defined = defined, .outer = outer, .on = on };
    }

    fn expr(p: *Parser) Refused!Expr {
        const first = try p.conjunction();
        if (!p.peek().is("OR")) return first;
        while (p.accept("OR")) _ = try p.conjunction();
        return .other;
    }

    fn conjunction(p: *Parser) Refused!Expr {
        var terms: []const Expr = &.{};
        while (true) {
            const term = try p.negation();
            if (term == .conjunction) terms = terms ++ term.conjunction else terms = terms ++ .{term};
            if (!p.accept("AND")) break;
        }
        return if (terms.len == 1) terms[0] else .{ .conjunction = terms };
    }

    fn negation(p: *Parser) Refused!Expr {
        if (!p.accept("NOT")) return p.comparison();
        _ = try p.negation();
        return .other;
    }

    fn comparison(p: *Parser) Refused!Expr {
        var left = try p.relation();
        while (true) {
            if (p.acceptSymbol("=") or p.acceptSymbol("==")) {
                const pair: [2]Expr = .{ left, try p.relation() };
                left = .{ .equality = &pair };
            } else if (p.acceptSymbol("<>") or p.acceptSymbol("!=")) {
                _ = try p.relation();
                left = .other;
            } else if (p.accept("IS")) {
                _ = p.accept("NOT");
                try p.expect("NULL");
                left = .other;
            } else if (p.peek().is("IN") or (p.peek().is("NOT") and p.peekAt(1).is("IN"))) {
                if (p.accept("NOT")) {}
                try p.expect("IN");
                try p.expectSymbol("(");
                if (p.startsSelect()) _ = try p.select() else _ = try p.expressions();
                try p.expectSymbol(")");
                left = .other;
            } else return left;
        }
    }

    fn relation(p: *Parser) Refused!Expr {
        const left = try p.sum();
        var related = false;
        while (p.acceptSymbol("<") or p.acceptSymbol("<=") or p.acceptSymbol(">") or p.acceptSymbol(">=")) {
            _ = try p.sum();
            related = true;
        }
        return if (related) .other else left;
    }

    fn sum(p: *Parser) Refused!Expr {
        const left = try p.product();
        var summed = false;
        while (p.acceptSymbol("+") or p.acceptSymbol("-")) {
            _ = try p.product();
            summed = true;
        }
        return if (summed) .other else left;
    }

    fn product(p: *Parser) Refused!Expr {
        const left = try p.unary();
        var multiplied = false;
        while (p.acceptSymbol("*") or p.acceptSymbol("/") or p.acceptSymbol("%")) {
            _ = try p.unary();
            multiplied = true;
        }
        return if (multiplied) .other else left;
    }

    fn unary(p: *Parser) Refused!Expr {
        if (!p.acceptSymbol("-") and !p.acceptSymbol("+")) return p.operand();
        _ = try p.unary();
        return .other;
    }

    fn operand(p: *Parser) Refused!Expr {
        const token = p.peek();
        switch (token.kind) {
            .parameter => {
                p.at += 1;
                return .{ .parameter = try p.parameter(token) };
            },
            .number, .literal => {
                p.at += 1;
                return .{ .constant = token.text };
            },
            .marker => return p.marker(),
            .word => {},
            .symbol, .end => {
                if (!p.acceptSymbol("(")) return p.refuse("an expression");
                if (p.startsSelect()) {
                    _ = try p.select();
                    try p.expectSymbol(")");
                    return .other;
                }
                const inner = try p.expr();
                try p.expectSymbol(")");
                return inner;
            },
        }
        if (p.accept("NULL")) return .{ .constant = "NULL" };
        if (p.accept("EXISTS")) {
            try p.subquery();
            return .other;
        }
        if (p.accept("CASE")) {
            if (!p.peek().is("WHEN")) _ = try p.expr();
            try p.expect("WHEN");
            while (true) {
                _ = try p.expr();
                try p.expect("THEN");
                _ = try p.expr();
                if (!p.accept("WHEN")) break;
            }
            if (p.accept("ELSE")) _ = try p.expr();
            try p.expect("END");
            return .other;
        }
        if (p.accept("CAST")) {
            try p.expectSymbol("(");
            _ = try p.expr();
            try p.expect("AS");
            _ = try p.name();
            try p.expectSymbol(")");
            return .other;
        }
        const first = try p.name();
        if (p.acceptSymbol("(")) {
            if (!p.acceptSymbol("*") and !p.peek().isSymbol(")")) {
                _ = p.accept("DISTINCT");
                _ = try p.expressions();
            }
            try p.expectSymbol(")");
            return .other;
        }
        if (p.acceptSymbol(".")) return .{ .column = .{ .table = first, .name = try p.name() } };
        return .{ .column = .{ .table = null, .name = first } };
    }

    /// `?N`, N from 1 to 64; SQLite's other forms (`?`, `:name`, `@name`,
    /// `$name`) are refused, so every parameter is counted.
    fn parameter(p: *Parser, token: Token) Refused!usize {
        const number = std.fmt.parseInt(usize, token.text[1..], 10) catch return p.refuseWith("rsql: write parameters as ?N");
        if (number == 0 or number > p.uses.len) return p.refuseWith("rsql: a parameter is ?1 to ?64");
        p.uses[number - 1] += 1;
        return number;
    }

    /// A marker in an expression: `@now` takes no arguments; `@session`
    /// takes one parameter ?k; `@octets` one expression; `@charset`,
    /// `@initial`, `@same` and `@distinct` two. `@index` stands only after
    /// a table (`source`), and any other name is refused.
    fn marker(p: *Parser) Refused!Expr {
        const written = p.next().text;
        const marker_name = written[1..];
        if (std.mem.eql(u8, marker_name, "now")) {
            if (p.peek().isSymbol("(")) return p.refuseWith("rsql: @now takes no arguments");
            p.uses_now = true;
            return .other;
        }
        if (std.mem.eql(u8, marker_name, "index")) return p.refuseWith("rsql: @index(name) stands only after its table");
        if (std.mem.eql(u8, marker_name, "session")) {
            try p.expectSymbol("(");
            const token = p.next();
            if (token.kind != .parameter) return p.refuseWith("rsql: @session takes one parameter, ?k");
            const k = try p.parameter(token);
            try p.expectSymbol(")");
            p.sessions = p.sessions ++ .{k};
            return .{ .session = k };
        }
        const arity: usize = if (std.mem.eql(u8, marker_name, "octets")) 1 else for ([_][]const u8{ "charset", "initial", "same", "distinct" }) |binary| {
            if (std.mem.eql(u8, marker_name, binary)) break 2;
        } else return p.refuseWith("rsql: unknown marker " ++ written);
        try p.expectSymbol("(");
        const arguments = try p.expressions();
        try p.expectSymbol(")");
        if (arguments.len != arity) return p.refuseWith(std.fmt.comptimePrint("rsql: {s} takes {d} arguments", .{ written, arity }));
        return .other;
    }
};

fn fieldCount(comptime T: type) usize {
    return @typeInfo(T).@"struct".field_names.len;
}

fn sessionField(comptime Args: type) ?[]const u8 {
    const info = @typeInfo(Args).@"struct";
    for (info.field_names, info.field_types) |name, Field| if (Field == SessionHead) return name;
    return null;
}

/// A compound SELECT (UNION, INTERSECT or EXCEPT), anywhere in the text,
/// stands only in a read that declares `.compound = true`, and that
/// declaration only with one. A write holds none.
fn compoundError(comptime kind: StatementKind, comptime parsed: Parsed, comptime compound: bool) ?[]const u8 {
    if (parsed.compounds == 0) return if (compound) "rsql: .compound = true, but the text has no compound SELECT" else null;
    if (kind == .write) return "rsql: a write holds no compound SELECT";
    return if (compound) null else "rsql: a read with a compound SELECT declares .compound = true";
}

/// Args fields bind ?1..?N in field order. Parameters carry no names, so
/// what is checked is the count: the text uses each of ?1..?N, N being
/// Args' field count, and no higher. The parser admits no other
/// parameter form.
fn parameterError(comptime uses: [64]usize, comptime Args: type) ?[]const u8 {
    const arguments = fieldCount(Args);
    var highest: usize = 0;
    for (uses, 1..) |count, number| {
        if (count != 0) highest = number;
    }
    if (highest != arguments) return std.fmt.comptimePrint("rsql: Args has {d} fields but the text binds up to ?{d}", .{ arguments, highest });
    for (uses[0..highest], 1..) |count, number| if (count == 0) return std.fmt.comptimePrint("rsql: ?{d} is never used", .{number});
    return null;
}

/// A read binds no SessionHead and writes no `@session`: it names a
/// Session by its reference text.
fn readSessionError(comptime parsed: Parsed, comptime Args: type) ?[]const u8 {
    if (sessionField(Args) != null or parsed.sessions.len != 0) return "rsql: a read binds no SessionHead; it names a Session by its reference text";
    return null;
}

/// Why `Row` does not name, in order, the columns the first SELECT of
/// `core`'s statement returns, or null. A column's name is its alias after
/// AS, or a bare or qualified column's own name; any other column needs an
/// AS. A SessionHead field takes the three columns `session_ref,
/// workspace_key,next_position`, and a Row holds at most one, so no two
/// fields of one type can trade places. Types are not compared with the
/// schema's; `sqlite.decodeRow` refuses a value its field cannot hold.
fn rowError(comptime core: Core, comptime Row: type) ?[]const u8 {
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
        if (core.results.len != expected.len) return std.fmt.comptimePrint("rsql: the text selects {d} columns but Row has {d}", .{ core.results.len, expected.len });
        for (core.results, expected, 1..) |result, field, number| {
            const name = result.alias orelse switch (result.value) {
                .column => |column| column.name,
                else => return std.fmt.comptimePrint("rsql: name column {d} with AS", .{number}),
            };
            if (!std.mem.eql(u8, name, field)) return std.fmt.comptimePrint("rsql: column {d} is {s} but Row's field is {s}", .{ number, name, field });
        }
        return null;
    }
}

/// Why a write's Session is unnamed, or named anywhere but on its table's
/// own `session_ref`, or null. A write to a table that carries Sessions
/// (`schema.carriesSessions`) binds exactly one SessionHead, as ?k, and its
/// text holds exactly one `@session(?k)` and uses ?k nowhere else; and:
/// - an INSERT ... VALUES gives `@session(?k)` as its session_ref value;
/// - an INSERT ... SELECT copies the bare `session_ref` FROM session alone,
///   unaliased and unjoined, as its session_ref value, and its WHERE has
///   the top-level conjunct `session_ref=@session(?k)` (`copyError`);
/// - an UPDATE or DELETE has that conjunct in its WHERE, and an UPDATE
///   sets no session_ref.
/// A conjunct is a term of the WHERE's AND chain, parentheses dropped, so
/// it holds of every row written. No write holds a compound SELECT
/// (`compoundError`). So every row it writes belongs to the Session that
/// ?k's head names. A write to any other table binds no SessionHead and
/// writes no marker.
///
/// A table with a second Session column (message_admission and
/// sent_rejection's `sender_session_ref`) is refused here until PR 5
/// converts its writers: the marker extends to it as a second
/// `@session(?j)` on that column, and the Access touches both heads.
fn sessionError(comptime parsed: Parsed, comptime Args: type) ?[]const u8 {
    comptime {
        const table = switch (parsed.statement) {
            .select => unreachable,
            inline else => |written| written.table,
        };
        if (schema.hasColumn(table, "sender_session_ref")) return "rsql: " ++ table ++ " names a second Session; its typed writes come with PR 5";
        const fields = @typeInfo(Args).@"struct".field_types;
        var heads: usize = 0;
        for (fields) |Field| heads += @intFromBool(Field == SessionHead);
        if (!schema.carriesSessions(table)) {
            if (parsed.sessions.len != 0) return "rsql: " ++ table ++ " carries no Sessions; write no @session";
            if (heads != 0) return "rsql: " ++ table ++ " carries no Sessions; bind no SessionHead";
            return null;
        }
        if (parsed.sessions.len != 1) return "rsql: a write to " ++ table ++ " names its Session exactly once, as @session(?k)";
        const k = parsed.sessions[0];
        if (k > fields.len or fields[k - 1] != SessionHead or heads != 1) return "rsql: @session(?k) binds the one SessionHead field of Args";
        if (parsed.uses[k - 1] != 1) return "rsql: the SessionHead ?k binds is used only in @session(?k)";
        const misplaced = "rsql: an UPDATE or DELETE names its Session as the conjunct session_ref=@session(?k) of its WHERE";
        switch (parsed.statement) {
            .select => unreachable,
            .insert => |insert| {
                const inserted = "rsql: an INSERT names its Session as the session_ref value of its VALUES row";
                var column: ?usize = null;
                for (insert.columns, 0..) |name, index| if (std.mem.eql(u8, name, "session_ref")) {
                    if (column != null) return inserted;
                    column = index;
                };
                const at = column orelse return inserted;
                return switch (insert.values) {
                    .row => |row| if (row.len != insert.columns.len)
                        "rsql: an INSERT gives one value per column"
                    else if (row[at] != .session) inserted else null,
                    .select => |select| copyError(select, at, insert.columns.len),
                };
            },
            .update => |update| {
                for (update.assigned) |name| if (std.mem.eql(u8, name, "session_ref")) return misplaced;
                return if (ties(update.where, table)) null else misplaced;
            },
            .delete => |delete| return if (ties(delete.where, table)) null else misplaced,
        }
    }
}

/// See `sessionError`: the copy's one source is the `session` row its
/// WHERE pins by key.
fn copyError(comptime select: Select, comptime column: usize, comptime columns: usize) ?[]const u8 {
    const copied = "rsql: an INSERT ... SELECT names its Session by copying session_ref FROM session alone, WHERE session_ref=@session(?k)";
    const core = select.first;
    if (core.sources.len != 1 or !std.mem.eql(u8, core.sources[0].table, "session") or !std.mem.eql(u8, core.sources[0].alias, "session")) return copied;
    if (core.results.len != columns) return "rsql: an INSERT gives one value per column";
    const value = core.results[column].value;
    if (value != .column or !std.mem.eql(u8, value.column.name, "session_ref") or
        (value.column.table != null and !std.mem.eql(u8, value.column.table.?, "session"))) return copied;
    const where = core.where orelse return copied;
    return if (ties(where, "session")) null else copied;
}

/// Whether `where` has the conjunct `session_ref=@session(?k)`, its column
/// bare or qualified by `table`.
fn ties(comptime where: Expr, comptime table: []const u8) bool {
    for (conjuncts(where)) |term| {
        if (term != .equality) continue;
        const column = term.equality[0];
        if (column == .column and std.mem.eql(u8, column.column.name, "session_ref") and
            (column.column.table == null or std.mem.eql(u8, column.column.table.?, table)) and term.equality[1] == .session) return true;
    }
    return false;
}

fn conjuncts(comptime condition: Expr) []const Expr {
    return if (condition == .conjunction) condition.conjunction else &[1]Expr{condition};
}

/// Whether a SELECT returns at most one row: it is not compound, and it
/// ends in `LIMIT 1`, or it has no FROM, or its keys pin it (`pinsOneRow`).
fn returnsOneRow(comptime select: Select) bool {
    comptime {
        if (select.compound) return false;
        return select.limit_one or select.first.sources.len == 0 or pinsOneRow(select.first);
    }
}

/// Whether a SELECT core returns at most one row because of keys alone:
/// every source is a table pinned, on all columns of one of its
/// `schema.keys`, by `=` conjuncts to a parameter, a constant, or a
/// column of another source already pinned. A conjunct of the WHERE or of
/// an inner join's ON may pin any source; a LEFT JOIN's ON pins only its
/// own, since every row on its left stays. A bare column counts only with
/// one source. A WITH name is never pinned.
fn pinsOneRow(comptime core: Core) bool {
    comptime {
        @setEvalBranchQuota(100_000);
        const Term = struct { condition: Expr, only: ?usize };
        var terms: []const Term = &.{};
        for (core.sources, 0..) |source, index| if (source.on) |on| {
            for (conjuncts(on)) |condition| terms = terms ++ .{Term{ .condition = condition, .only = if (source.outer) index else null }};
        };
        if (core.where) |where| for (conjuncts(where)) |condition| {
            terms = terms ++ .{Term{ .condition = condition, .only = null }};
        };
        var pinned: [core.sources.len]bool = @splat(false);
        var changed = true;
        while (changed) {
            changed = false;
            for (core.sources, &pinned, 0..) |source, *done, index| {
                if (done.* or source.defined) continue;
                done.* = for (schema.keys(source.table)) |key| {
                    const all = for (key) |column| {
                        const fixed = for (terms) |term| {
                            if ((term.only == null or term.only.? == index) and fixes(term.condition, core.sources, &pinned, index, column)) break true;
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

/// Whether `condition` is `column = value` (either way round) for source
/// `index`'s `column`, where the value is a parameter, a constant, or a
/// column of another pinned source.
fn fixes(comptime condition: Expr, comptime sources: []const Source, comptime pinned: []const bool, comptime index: usize, comptime column: []const u8) bool {
    if (condition != .equality) return false;
    const sides = condition.equality.*;
    for (sides, 0..) |side, which| {
        if (!names(side, sources, index, column)) continue;
        switch (sides[1 - which]) {
            .parameter, .constant => return true,
            .column => |other| for (sources, pinned, 0..) |source, done, at| {
                if (done and at != index and other.table != null and std.mem.eql(u8, other.table.?, source.alias)) return true;
            },
            else => {},
        }
    }
    return false;
}

/// Whether `side` is exactly source `index`'s `column`: qualified by its
/// alias, or bare when it is the only source.
fn names(comptime side: Expr, comptime sources: []const Source, comptime index: usize, comptime column: []const u8) bool {
    if (side != .column or !std.mem.eql(u8, side.column.name, column)) return false;
    return if (side.column.table) |table| std.mem.eql(u8, table, sources[index].alias) else sources.len == 1;
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
    try std.testing.expectEqualStrings("rsql: the text selects 2 columns but Row has 1", comptime statementError(.read, "SELECT content_id,(SELECT max(a,b) FROM turn) FROM content WHERE content_id=?1", One, One).?);
    try std.testing.expectEqualStrings("rsql: the text selects 3 columns but Row has 1", comptime statementError(.read, "SELECT session_ref,workspace_key,next_position FROM session WHERE created_seq=?1", One, One).?);
    try std.testing.expectEqual(@as(?[]const u8, null), comptime statementError(.read, "SELECT s.session_ref,s.workspace_key,s.next_position FROM session s WHERE created_seq=?1", One, struct { head: SessionHead }));
    try std.testing.expectEqualStrings("rsql: a read is a SELECT", comptime statementError(.read, "UPDATE content SET private=0 WHERE content_id=1", struct {}, One).?);
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
    try std.testing.expectEqualStrings(misplaced, comptime statementError(.write, "UPDATE turn SET outcome_at=1 WHERE turn_id=?1 OR session_ref=@session(?2)", Turn, void).?);
    try std.testing.expectEqualStrings(misplaced, comptime statementError(.write, "UPDATE turn SET outcome_at=1 WHERE turn_id=?1 AND NOT session_ref=@session(?2)", Turn, void).?);
    try std.testing.expectEqualStrings(misplaced, comptime statementError(.write, "UPDATE turn SET outcome_at=1 WHERE turn_id=?1 AND session_ref<>@session(?2)", Turn, void).?);
    try std.testing.expectEqualStrings(misplaced, comptime statementError(.write, "UPDATE turn SET outcome_at=1 WHERE turn_id=?1 AND operation_id IN (SELECT operation_id FROM model_operation WHERE session_ref=@session(?2))", Turn, void).?);
    try std.testing.expectEqualStrings(misplaced, comptime statementError(.write, "UPDATE turn SET session_ref=@session(?2) WHERE turn_id=?1", Turn, void).?);
    try std.testing.expectEqualStrings(misplaced, comptime statementError(.write, "UPDATE turn SET session_ref='x' WHERE turn_id=?1 AND session_ref=@session(?2)", Turn, void).?);
    try std.testing.expectEqualStrings("rsql: @session(?k) binds the one SessionHead field of Args", comptime statementError(.write, "UPDATE turn SET outcome_at=1 WHERE session_ref=@session(?1) AND turn_id=?2", struct { turn_id: u64, session: SessionHead }, void).?);
    try std.testing.expectEqual(@as(?[]const u8, null), comptime statementError(.write, "UPDATE turn SET outcome_at=@now WHERE turn_id=?1 AND session_ref=@session(?2) AND (outcome_code IS NULL OR outcome_code='x')", Turn, void));
    try std.testing.expectEqual(@as(?[]const u8, null), comptime statementError(.write, "DELETE FROM turn WHERE session_ref=@session(?2) AND turn_id=?1", Turn, void));

    const Stop = struct { key: []const u8, session: SessionHead, turn_id: u64 };
    const inserted = "rsql: an INSERT names its Session as the session_ref value of its VALUES row";
    try std.testing.expectEqual(@as(?[]const u8, null), comptime statementError(.write, "INSERT INTO session_stop(command_key,session_ref,selected_turn_id,admission_cutoff,stopped_at) VALUES(?1,@session(?2),?3,0,@now)", Stop, void));
    try std.testing.expectEqualStrings(inserted, comptime statementError(.write, "INSERT INTO session_stop(session_ref,command_key,selected_turn_id,admission_cutoff,stopped_at) VALUES(?1,@session(?2),?3,0,@now)", Stop, void).?);
    try std.testing.expectEqualStrings(inserted, comptime statementError(.write, "INSERT INTO session_stop(command_key,session_ref,selected_turn_id,admission_cutoff,stopped_at) VALUES(?1,coalesce(@session(?2),'x'),?3,0,@now)", Stop, void).?);
    const copied = "rsql: an INSERT ... SELECT names its Session by copying session_ref FROM session alone, WHERE session_ref=@session(?k)";
    try std.testing.expectEqualStrings(copied, comptime statementError(.write, "INSERT INTO session_stop(command_key,session_ref,selected_turn_id,admission_cutoff,stopped_at) SELECT ?1,@session(?2),?3,0,@now", Stop, void).?);

    // A copy of one Session's row: its key pins the row the WHERE names.
    const Copy = struct { session: SessionHead, key: []const u8 };
    try std.testing.expectEqual(@as(?[]const u8, null), comptime statementError(.write, "INSERT INTO session_revision(session_ref,revision,command_key) SELECT session_ref,revision,?2 FROM session WHERE session_ref=@session(?1)", Copy, void));
    try std.testing.expectEqualStrings(copied, comptime statementError(.write, "INSERT INTO session_revision(session_ref,revision,command_key) SELECT ?2,revision,?2 FROM session WHERE session_ref=@session(?1)", Copy, void).?);
    try std.testing.expectEqualStrings(copied, comptime statementError(.write, "INSERT INTO session_revision(session_ref,revision,command_key) SELECT s.session_ref,revision,?2 FROM session s WHERE session_ref=@session(?1)", Copy, void).?);
    try std.testing.expectEqualStrings(copied, comptime statementError(.write, "INSERT INTO session_revision(session_ref,revision,command_key) SELECT session_ref,revision,?2 FROM turn WHERE session_ref=@session(?1)", Copy, void).?);
    try std.testing.expectEqualStrings(copied, comptime statementError(.write, "INSERT INTO session_revision(session_ref,revision,command_key) SELECT session_ref,revision,?2 FROM session JOIN turn ON turn.session_ref=session.session_ref WHERE session_ref=@session(?1)", Copy, void).?);
    try std.testing.expectEqualStrings(copied, comptime statementError(.write, "INSERT INTO session_revision(session_ref,revision,command_key) SELECT session_ref,revision,?2 FROM session WHERE session_ref=@session(?1) OR revision=1", Copy, void).?);
    try std.testing.expectEqualStrings("rsql: an INSERT gives one value per column", comptime statementError(.write, "INSERT INTO session_revision(session_ref,revision,command_key) SELECT session_ref,revision FROM session WHERE session_ref=@session(?1) AND ?2 IS NOT NULL", Copy, void).?);
    try std.testing.expectEqualStrings("rsql: an INSERT writes one VALUES row", comptime statementError(.write, "INSERT INTO session_stop(command_key,session_ref,selected_turn_id,admission_cutoff,stopped_at) VALUES(?1,@session(?2),?3,0,@now),(?1,'other',?3,0,@now)", Stop, void).?);
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

/// Whether the read `sql`, parsed, counts as one row.
fn oneRow(comptime sql: []const u8) bool {
    return returnsOneRow(parse(sql).accepted.statement.select);
}

test "a read is keyed to one row only when keys pin every table it reads" {
    try std.testing.expect(comptime oneRow("SELECT content_id FROM content WHERE digest=?1 AND byte_length=?2 AND private=?3"));
    try std.testing.expect(comptime oneRow("SELECT s.session_ref FROM turn t JOIN session s ON s.session_ref=t.session_ref WHERE t.turn_id=?1 AND (?2 IS NULL OR t.operation_id=?2)"));
    try std.testing.expect(comptime oneRow("SELECT o.turn_id FROM action_operation a JOIN model_operation o ON o.operation_id=a.parent_operation_id WHERE a.action_id=?1"));
    try std.testing.expect(comptime oneRow("SELECT a.action_id FROM action_operation a LEFT JOIN turn t ON t.turn_id=?2 WHERE (a.action_id=?1)"));
    // Not every column of a key, a key column compared with <, an OR, a
    // partial unique index, a bare column among two tables, an unpinned join.
    try std.testing.expect(!comptime oneRow("SELECT content_id FROM content WHERE digest=?1 AND byte_length=?2"));
    try std.testing.expect(!comptime oneRow("SELECT turn_id FROM turn WHERE turn_id<=?1"));
    try std.testing.expect(!comptime oneRow("SELECT turn_id FROM turn WHERE turn_id=?1 OR turn_id=?2"));
    try std.testing.expect(!comptime oneRow("SELECT turn_id FROM turn WHERE session_ref=?1 AND outcome_code IS NULL"));
    try std.testing.expect(!comptime oneRow("SELECT o.turn_id FROM action_operation a JOIN model_operation o ON o.operation_id=a.parent_operation_id WHERE action_id=?1"));
    try std.testing.expect(!comptime oneRow("SELECT a.action_id FROM model_operation o JOIN action_operation a ON a.parent_operation_id=o.operation_id WHERE o.operation_id=?1"));
    try std.testing.expect(comptime oneRow("SELECT turn_id FROM turn WHERE turn_id<=?1 ORDER BY turn_id LIMIT 1"));
    try std.testing.expect(!comptime oneRow("SELECT turn_id FROM turn WHERE turn_id<=?1 ORDER BY turn_id LIMIT 2"));
    try std.testing.expect(!comptime oneRow("SELECT turn_id FROM turn WHERE turn_id IN (SELECT turn_id FROM turn LIMIT 1)"));
    try std.testing.expect(comptime oneRow("SELECT EXISTS(SELECT 1 FROM session WHERE session_ref=?1) AS taken"));
}

test "the review's two inputs are refused" {
    // A compound read as .one stepped once and never saw its second row.
    try std.testing.expectEqualStrings("rsql: a read with a compound SELECT declares .compound = true", comptime statementError(.read, "SELECT 1 AS a UNION ALL SELECT 2 AS a", struct {}, struct { a: u64 }).?);
    // A compound copy wrote a row for a Session the write never touched.
    try std.testing.expectEqualStrings("rsql: a write holds no compound SELECT", comptime statementError(
        .write,
        "INSERT INTO session_revision(session_ref,revision,command_key) SELECT session_ref,revision,?2 FROM session WHERE session_ref=@session(?1) AND 1 UNION ALL SELECT 'zzzzzz',1,?2",
        struct { session: SessionHead, key: []const u8 },
        void,
    ).?);
}

test "a compound SELECT stands only where the read declares it, and never counts as one row" {
    const Compound = Read(.{ .sql = "SELECT 1 AS a UNION ALL SELECT 2 AS a", .Args = struct {}, .Row = struct { a: u64 }, .cardinality = .{ .at_most = 2 }, .compound = true });
    try std.testing.expect(!Compound.single_row);
    try std.testing.expectEqualStrings("rsql: .compound = true, but the text has no compound SELECT", comptime check(.read, "SELECT 1 AS a", struct {}, struct { a: u64 }, true).refused);
    try std.testing.expectEqualStrings("rsql: a read with a compound SELECT declares .compound = true", comptime statementError(.read, "SELECT turn_id FROM turn WHERE turn_id IN (SELECT 1 UNION SELECT 2)", struct {}, struct { turn_id: u64 }).?);
}

// The first input of each test below passed the token checks the parser
// replaced (a probe against them showed it; see PR #807); each rule now
// refuses it.

test "the Session tie reads the WHERE's conjuncts, not the tokens around the marker" {
    // Every Session but ?2's matches the CASE's ELSE.
    try std.testing.expectEqualStrings(
        "rsql: an UPDATE or DELETE names its Session as the conjunct session_ref=@session(?k) of its WHERE",
        comptime statementError(.write, "UPDATE turn SET outcome_at=1 WHERE CASE WHEN turn_id=?1 AND session_ref=@session(?2) AND outcome_code IS NULL THEN 0 ELSE 1 END", struct { turn_id: u64, session: SessionHead }, void).?,
    );
}

test "a copy's SELECT is one Session's row" {
    const copied = "rsql: an INSERT ... SELECT names its Session by copying session_ref FROM session alone, WHERE session_ref=@session(?k)";
    const Copy = struct { session: SessionHead, key: []const u8 };
    try std.testing.expectEqualStrings(copied, comptime statementError(.write, "INSERT INTO session_revision(session_ref,revision,command_key) SELECT session_ref,revision,?2 FROM session WHERE CASE WHEN revision=0 AND session_ref=@session(?1) AND revision=0 THEN 0 ELSE 1 END", Copy, void).?);
}

test "a LEFT JOIN's ON pins only its own table" {
    // Every action row stays, whatever the ON says of it.
    try std.testing.expect(!comptime oneRow("SELECT a.action_id FROM action_operation a LEFT JOIN turn t ON a.action_id=?1 AND t.turn_id=?2"));
    try std.testing.expect(comptime oneRow("SELECT a.action_id FROM action_operation a LEFT JOIN turn t ON t.turn_id=a.action_id WHERE a.action_id=?1"));
    try std.testing.expect(!comptime oneRow("SELECT 1 AS a UNION ALL SELECT 2 AS a"));
}

test "a compound's column names are its first SELECT's" {
    try std.testing.expectEqualStrings("rsql: column 1 is b but Row's field is a", comptime check(.read, "SELECT 1 AS b UNION ALL SELECT 2 AS a", struct {}, struct { a: u64 }, true).refused);
}

test "every parameter is ?N, so the count sees each one" {
    // SQLite would number :x after ?1, where @now binds.
    try std.testing.expectEqualStrings("rsql: expected an expression at ':'", comptime statementError(.read, "SELECT turn_id FROM turn WHERE turn_id=?1 AND operation_id=:x", struct { id: u64 }, struct { turn_id: u64 }).?);
    try std.testing.expectEqualStrings("rsql: write parameters as ?N", comptime statementError(.read, "SELECT turn_id FROM turn WHERE turn_id=?", struct { id: u64 }, struct { turn_id: u64 }).?);
}

test "a marker stands only where it means something" {
    try std.testing.expectEqualStrings("rsql: @now takes no arguments", comptime statementError(.write, "UPDATE content SET private=@now(1) WHERE content_id=?1", struct { id: u64 }, void).?);
    try std.testing.expectEqualStrings(
        "rsql: @index names an index of its own table, and turn has no index action_operation_executable",
        comptime statementError(.read, "SELECT turn_id FROM turn @index(action_operation_executable) WHERE turn_id=?1", struct { id: u64 }, struct { turn_id: u64 }).?,
    );
    try std.testing.expectEqualStrings("rsql: @index(name) stands only after its table", comptime statementError(.read, "SELECT turn_id FROM turn WHERE turn_id=?1 AND @index(turn_unpositioned) IS NULL", struct { id: u64 }, struct { turn_id: u64 }).?);
    try std.testing.expectEqualStrings("rsql: unknown marker @nope", comptime statementError(.read, "SELECT turn_id FROM turn WHERE turn_id=@nope(?1)", struct { id: u64 }, struct { turn_id: u64 }).?);
    try std.testing.expectEqualStrings("rsql: @same takes 2 arguments", comptime statementError(.read, "SELECT turn_id FROM turn WHERE @same(turn_id)", struct {}, struct { turn_id: u64 }).?);
}

test "text outside the grammar is refused at the token the parser stopped at" {
    const Id = struct { id: u64 };
    const Turn = struct { turn_id: u64 };
    try std.testing.expectEqualStrings("rsql: expected an expression at '*'", comptime statementError(.read, "SELECT * FROM turn WHERE turn_id=?1", Id, Turn).?);
    try std.testing.expectEqualStrings("rsql: expected the end at ','", comptime statementError(.read, "SELECT t.turn_id FROM turn t, session s WHERE t.turn_id=?1", Id, Turn).?);
    try std.testing.expectEqualStrings("rsql: no table named turns", comptime statementError(.read, "SELECT turn_id FROM turns WHERE turn_id=?1", Id, Turn).?);
    try std.testing.expectEqualStrings("rsql: expected WHERE at the end", comptime statementError(.write, "DELETE FROM content", struct {}, void).?);
    try std.testing.expectEqualStrings("rsql: expected the end at 'turn_id'", comptime statementError(.read, "SELECT turn_id FROM turn t turn_id", struct {}, Turn).?);
    try std.testing.expectEqualStrings("rsql: a WITH name is never a table's: session", comptime statementError(.read, "WITH session AS (SELECT 1 AS turn_id) SELECT turn_id FROM session", struct {}, Turn).?);
    try std.testing.expectEqual(@as(?[]const u8, null), comptime statementError(.read, "WITH recent(turn_id) AS (SELECT turn_id FROM turn) SELECT turn_id FROM recent WHERE turn_id=?1", Id, Turn));
}
