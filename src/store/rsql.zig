//! Rui SQL: Store SQL text written once for every engine. Source text is SQLite
//! SQL restricted to a portable subset, plus markers that each engine renders
//! in its own spelling. The schema's checks and index predicates and every
//! typed statement (`Read`, `Write`) pass its checks. `Store.cachedTyped`,
//! the one way a typed statement reaches SQLite, takes only a type `Read` or
//! `Write` made (`isStatement`). The Store prepares other text in three
//! places only: its transaction control (`Store.Control`), its test-only
//! fixtures, and, at open, PRAGMAs, schema bootstrap and one sweep held to
//! `portabilityError` alone.

const std = @import("std");
const change_ring = @import("../change_ring.zig");
const schema = @import("schema.zig");
const provider_name = @import("../provider_name.zig");

pub const Dialect = enum { sqlite, mysql };

/// A reserved word is a name, and refused, everywhere except the keyword
/// places in `keywords`; text never names `rowid`. The schema's names,
/// checks and predicates, every typed statement and opening's sweep are
/// held to this.
pub const reserved_names_checked = true;

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

/// Why `text` is not portable Rui SQL, or null; reserved names and
/// `rowid` count only when `reserved`. String literals are not inspected;
/// comments and quoted identifiers are refused, so nothing else escapes
/// the scan.
/// `reserved` mirrors `identifierError`'s on purpose: both take `reserved_names_checked`, one switch for names and text.
pub fn portabilityError(comptime text: []const u8, comptime reserved: bool) ?[]const u8 {
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
            } else if (std.mem.eql(u8, pair, "||")) {
                return "rsql: '||' is OR on MySQL; compute the text in Zig";
            } else if (std.mem.eql(u8, pair, "--") or std.mem.eql(u8, pair, "/*")) {
                return "rsql: '" ++ pair ++ "' comments hide text from this check; write the note as a Zig comment";
            } else if (byte == '"') {
                return "rsql: '\"' quotes a name on Postgres but a string on MySQL; write names bare and strings in single quotes";
            } else if (isWordStart(byte)) {
                const word = text[index..wordEnd(text, index)];
                index += word.len;
                for (forbidden_words) |forbidden| {
                    if (std.ascii.eqlIgnoreCase(word, forbidden.word)) return "rsql: '" ++ word ++ "' is not portable; " ++ forbidden.fix;
                }
                if (std.ascii.eqlIgnoreCase(previous, "INSERT") and std.ascii.eqlIgnoreCase(word, "OR"))
                    return "rsql: 'INSERT OR' is not portable; read in an earlier round, then guard the write";
                if (reserved) {
                    if (std.ascii.eqlIgnoreCase(word, "rowid")) return "rsql: 'rowid' is SQLite's hidden key; name an explicit INTEGER key column";
                    if (identifierError(word, true)) |message| {
                        if (!isKeyword(text, word, index, previous, window_depth != null and window_depth.? == depth)) return message;
                    }
                }
                if (std.ascii.eqlIgnoreCase(word, "IS")) {
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

/// Why `name` cannot name a table, column or index on every engine, or null.
pub fn identifierError(comptime name: []const u8, comptime reserved: bool) ?[]const u8 {
    if (!reserved) return null;
    for (reserved_names) |word| {
        if (std.ascii.eqlIgnoreCase(name, word)) return "rsql: '" ++ name ++ "' is reserved on some engine; rename it";
    }
    return null;
}

/// `text` in `dialect`'s spelling. Fails the build on text that is not
/// portable or on an unknown or malformed marker. SQLite's spelling of
/// each marker:
///
///   @octets(x)           bytes in x: `length(CAST(x AS BLOB))`
///   @charset(c,'set')    only these characters: `(c NOT GLOB '*[^set]*' AND
///                        length(c)=length(CAST(c AS BLOB)))`. GLOB stops
///                        at a NUL; the set is ASCII, so characters equal
///                        bytes exactly when no NUL hides the rest
///   @initial(c,'set')    first character in the set: `c GLOB '[set]*'`
///   @same(a,b)           null-safe equality: `(a IS b)`
///   @distinct(a,b)       its negation: `(a IS NOT b)`
///   @count_where(c)      the rows where c holds: `count(*) FILTER (WHERE c)`
///   @max_where(x,c)      the greatest x of those rows: `max(x) FILTER (WHERE c)`
///   @served(x)           the opening serves provider x: `rui_served(x)`,
///                        the function each opening registers
///
/// MySQL's are `mysqlTemplate`'s. Text rendered here binds nothing, so
/// MySQL text with a slot fails the build too.
pub fn render(comptime dialect: Dialect, comptime text: []const u8) []const u8 {
    comptime {
        if (portabilityError(text, reserved_names_checked)) |message| @compileError(message ++ ": " ++ text);
        return switch (dialect) {
            .sqlite => renderSqlite(text),
            .mysql => {
                const template = mysqlTemplate(text);
                if (template.slots.len != 0) @compileError("rsql: this text binds nothing: " ++ text);
                return template.parts[0];
            },
        };
    }
}

// Typed statements. Each is a type made by `Read` or `Write`. Its Rui SQL is
// parsed at comptime (`Parser`) in the grammar Rui writes, and text outside
// that grammar is refused, so no rule meets a shape it was not written for.
// The rules then read the parsed tree, each doc saying exactly what it checks:
// - `parameterError`: Args fields bind ?1..?N, in field order;
// - `rowError`: a read's Row fields name the columns it returns, in order;
// - `sessionError`: a write names each Session it writes on that Session's
//   own column (`schema.sessionColumns`);
// - `compoundError`: a compound SELECT stands only where `.compound` says so;
// - `returnsOneRow`: when a read needs no step to rule out a second row;
// - the markers, as they are parsed (`Parser.marker`, `Parser.source`).

/// Bytes a statement binds as a blob, read in place like text.
pub const Bytes = struct { bytes: []const u8 };

/// A stored blob of at most `capacity` bytes, read by value. Unlike text
/// (`protocol.Bounded`), its bytes are not checked to be UTF-8; a value
/// that is not a blob, or is longer, is `CorruptStore`.
pub fn Blob(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = undefined,
        len: std.math.IntFittingRange(0, capacity) = 0,

        pub const blob_capacity = capacity;

        pub fn slice(self: *const @This()) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}

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
/// next_position`. A write names each Session it writes with one, through
/// the marker `@session(?k)`, which binds its reference; the Access that
/// queues the write records the touch from each without a read.
/// A SessionHead's columns, in order, from a read that joins `session s`.
pub const session_head_columns = "s.session_ref,s.workspace_key,s.next_position";

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
    /// Exactly the count its caller states when it queues the write
    /// (`Access.writeCount`), a count known only at run time; any other
    /// is `otherwise`.
    counted: struct { otherwise: anyerror },
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
        // `.one` and `.at_most` decode in place. `Access.readEach` refuses
        // an `.each` Row over 1 KiB unless its visitor owns the decoded row, and
        // `Access.read` a big `.optional`.
        if (fillsInPlace(spec.Row) and spec.cardinality != .optional)
            @compileError("rsql: a Row that points into its caller's memory is read .optional, with Access.readInto: " ++ spec.sql);
    }
    return struct {
        pub const kind: StatementKind = .read;
        /// What `isStatement` checks this type was made from.
        pub const made_from = spec;
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
        /// The text in MySQL's spelling (`mysqlRendering`), rendered only
        /// where something reads it: `Store.cachedTyped` in test builds.
        pub const mysql: Template = mysqlTemplate(spec.sql);
        pub const uses_now = parsed.uses_now;
        /// Whether the text alone limits the result to one row
        /// (`returnsOneRow`), so a read need not step again to prove there
        /// is no second.
        pub const single_row = returnsOneRow(parsed.statement.select);
    };
}

pub fn Write(comptime spec: WriteSpec) type {
    const parsed = comptime accepted(.write, spec.sql, spec.Args, void, false);
    comptime if (expectError(parsed.statement, spec.expect)) |message| @compileError(message ++ ": " ++ spec.sql);
    return struct {
        pub const kind: StatementKind = .write;
        /// What `isStatement` checks this type was made from.
        pub const made_from = spec;
        pub const Args = spec.Args;
        pub const expect = spec.expect;
        pub const sql = renderStatement(spec.sql, fieldCount(Args));
        /// The text in MySQL's spelling (`mysqlRendering`), rendered only
        /// where something reads it: `Store.cachedTyped` in test builds.
        pub const mysql: Template = mysqlTemplate(spec.sql);
        pub const uses_now = parsed.uses_now;
        /// The Args fields the write's `@session` markers bind, in Args'
        /// order: none, or one per Session it names.
        pub const session_fields: []const []const u8 = sessionFields(Args);
    };
}

pub const StatementKind = enum { read, write };

/// Whether `S` is the type `Read` or `Write` made, so its text passed every
/// check. A struct that copies a statement's declarations, `made_from`
/// included, is not: `S` must be the very type its spec makes.
pub fn isStatement(comptime S: type) bool {
    comptime {
        if (@typeInfo(S) != .@"struct" or !@hasDecl(S, "kind") or !@hasDecl(S, "made_from")) return false;
        if (@TypeOf(S.kind) != StatementKind) return false;
        return switch (S.kind) {
            .read => @TypeOf(S.made_from) == ReadSpec and S == Read(S.made_from),
            .write => @TypeOf(S.made_from) == WriteSpec and S == Write(S.made_from),
        };
    }
}

/// Whether a Row has a pointer field, which decodes into the caller's
/// memory it points to, so the caller's struct fills in place without a
/// copy. Its pointers must be set before the round runs: only
/// `Access.readInto` reads such a Row, from the caller's own Row.
pub fn fillsInPlace(comptime Row: type) bool {
    comptime {
        for (@typeInfo(Row).@"struct".field_types) |Field| if (@typeInfo(Field) == .pointer) return true;
        return false;
    }
}

/// Why a typed statement's text is refused, or null.
pub fn statementError(comptime kind: StatementKind, comptime sql: []const u8, comptime Args: type, comptime Row: type) ?[]const u8 {
    return switch (check(kind, sql, Args, Row, false)) {
        .refused => |message| message,
        .accepted => null,
    };
}

/// Why a write's text, or its `expect`, is refused, or null.
fn writeError(comptime sql: []const u8, comptime Args: type, comptime expect: Expect) ?[]const u8 {
    return switch (check(.write, sql, Args, void, false)) {
        .refused => |message| message,
        .accepted => |parsed| expectError(parsed.statement, expect),
    };
}

/// Why a write's `expect` does not fit its text, or null. An INSERT ...
/// VALUES writes one row: it declares `.at_most`, or `.exact` with at most
/// 1 row, never `.counted`. An INSERT ... SELECT inserts the rows its
/// SELECT returns: one whose SELECT returns at most one row
/// (`returnsOneRow`) declares `.exact` 1 or `.at_most` 1, and any other
/// declares `.counted`, so its caller states the count. An UPDATE or
/// DELETE may declare any Expect. The guard checks the count again when
/// the write runs.
fn expectError(comptime statement: Statement, comptime expect: Expect) ?[]const u8 {
    if (statement != .insert) return null;
    const select = switch (statement.insert.values) {
        .row => return switch (expect) {
            .exact => |guard| if (guard.rows > 1) values_message else null,
            .at_most => null,
            .counted => values_message,
        },
        .select => |select| select,
    };
    const declares_one = switch (expect) {
        .exact => |guard| guard.rows == 1,
        .at_most => |rows| rows == 1,
        .counted => false,
    };
    if (returnsOneRow(select)) {
        if (!declares_one) return "rsql: an INSERT ... SELECT of at most one row declares .exact or .at_most 1";
    } else if (expect != .counted) return "rsql: an INSERT ... SELECT of more than one row declares .counted, so its caller states the count";
    return null;
}

const values_message = "rsql: an INSERT ... VALUES writes one row; it declares .at_most, or .exact of at most 1, never .counted";

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
        if (portabilityError(sql, reserved_names_checked)) |message| return .{ .refused = message };
        const parsed = switch (parse(sql)) {
            .refused => |message| return .{ .refused = message },
            .accepted => |parsed| parsed,
        };
        if (kind == .read and parsed.statement != .select) return .{ .refused = "rsql: a read is a SELECT" };
        if (kind == .write and parsed.statement == .select) return .{ .refused = "rsql: a write is an INSERT, UPDATE or DELETE" };
        if (compoundError(kind, parsed, compound)) |message| return .{ .refused = message };
        if (parameterError(parsed.uses, Args)) |message| return .{ .refused = message };
        const refusal: ?[]const u8 = switch (kind) {
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
            .queries = p.queries,
        } };
    }
}

/// The most parameters a statement binds: the Store's
/// `SQLITE_LIMIT_VARIABLE_NUMBER` (`Store.open`), which a settlement's wide
/// duplicate read reaches, its Operation and 64 digests.
pub const max_parameters = 65;

/// A typed statement as the rules read it, and what its parse counted.
const Parsed = struct {
    statement: Statement,
    /// How many times the text uses each of ?1..?`max_parameters`,
    /// markers included.
    uses: [max_parameters]usize,
    /// The k of each `@session(?k)`, wherever it stands.
    sessions: []const usize,
    uses_now: bool,
    /// The compound SELECTs anywhere in the text, subqueries included.
    compounds: usize,
    /// Every query in the text (`Query`), in the order each ends.
    queries: []const Query,
};

/// One query of a statement: a SELECT core anywhere in the text (a
/// subquery, a WITH body, each core of a compound), or the table an UPDATE
/// or DELETE writes, with that statement's WHERE. `parent` is the query
/// whose text holds it, which its columns may name; the outermost has
/// none. An INSERT's VALUES row is no query, so a subquery there has none.
const Query = struct { id: usize, parent: ?usize, sources: []const Source, where: ?Expr };

const Statement = union(enum) {
    select: Select,
    insert: struct {
        table: []const u8,
        columns: []const []const u8,
        values: union(enum) { row: []const Expr, select: Select },
    },
    /// `query`: the id of the `Query` its own table stands in.
    update: struct { table: []const u8, assigned: []const []const u8, where: Expr, query: usize },
    delete: struct { table: []const u8, where: Expr, query: usize },
};

const Select = struct {
    /// The first SELECT of a compound, whose names the result takes.
    first: Core,
    compound: bool,
    /// Whether it ends in `LIMIT 1`.
    limit_one: bool,
};

/// `query`: the id of the `Query` it is.
const Core = struct { results: []const Result, sources: []const Source, where: ?Expr, query: usize };

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
    /// `column IS NULL`.
    is_null: Column,
    other,
};

/// A lexical token. A marker is its `@name`; its arguments follow as
/// tokens of their own. String literals are single tokens, so nothing
/// reads inside one.
const Token = struct {
    kind: enum { word, parameter, number, literal, marker, symbol, end },
    text: []const u8,
    /// Where `text` starts in the tokenized text.
    start: usize = 0,

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
            tokens = tokens ++ .{Token{ .kind = kind, .text = sql[start..index], .start = start }};
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
    "UPDATE", "SET",      "DELETE", "LIKE",  "BETWEEN", "ESCAPE",    "COLLATE", "RECURSIVE", "OVER",
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
///   source    := table [[AS] alias] [@index(name)] [ON expr]
///   insert    := INSERT INTO table (names) (VALUES (expr, ...) | select)
///   update    := UPDATE table SET name=expr, ... WHERE expr
///   delete    := DELETE FROM table WHERE expr
///
/// Expressions take OR, AND, NOT, the comparisons (`=`, `==`, `<>`, `!=`,
/// `<`, `<=`, `>`, `>=`, IS [NOT] NULL, [NOT] IN (list or select)), `+`,
/// `-`, `*`, `/`, `%`, unary `-` and `+`, at SQLite's precedence; and as
/// operands columns, `?N`, numbers, string literals, NULL, markers,
/// function calls, CAST, CASE, EXISTS and parenthesized expressions or
/// subqueries. The one window is `row_number() OVER (ORDER BY expr
/// [ASC|DESC], ...)`, which every engine runs. Anything else (a named
/// parameter, `*` as a column, a comma join, an unknown table, LIKE,
/// BETWEEN, COLLATE, another window) is refused with the token it stopped
/// at. Two more refusals hold on every dialect, for MySQL's sake: a call
/// to `length`, which counts characters there and bytes on MySQL; and an
/// UPDATE whose SET value reads a column an earlier assignment of the same
/// SET writes (`readsAssigned`), because MySQL reads the new value.
const Parser = struct {
    tokens: []const Token,
    at: usize = 0,
    message: []const u8 = "",
    uses: [max_parameters]usize = @splat(0),
    sessions: []const usize = &.{},
    uses_now: bool = false,
    compounds: usize = 0,
    /// The names WITH clauses define for the select being parsed.
    defined: []const []const u8 = &.{},
    queries: []const Query = &.{},
    /// The id of the query whose text is being parsed.
    scope: ?usize = null,
    next_query: usize = 0,
    /// Every column the text names as an operand, in order.
    columns: []const Column = &.{},

    const Opened = struct { id: usize, parent: ?usize };

    /// Starts a query: the text parsed until `close` stands in it.
    fn open(p: *Parser) Opened {
        const opened: Opened = .{ .id = p.next_query, .parent = p.scope };
        p.next_query += 1;
        p.scope = opened.id;
        return opened;
    }

    fn close(p: *Parser, opened: Opened, sources: []const Source, where: ?Expr) void {
        p.scope = opened.parent;
        p.queries = p.queries ++ .{Query{ .id = opened.id, .parent = opened.parent, .sources = sources, .where = where }};
    }

    /// The query an UPDATE or DELETE stands in: its own table, unaliased.
    fn writtenTable(table: []const u8) []const Source {
        return &.{Source{ .table = table, .alias = table, .defined = false, .outer = false, .on = null }};
    }

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
            const opened = p.open();
            try p.expect("SET");
            var assigned: []const []const u8 = &.{};
            while (true) {
                const column = try p.name();
                try p.expectSymbol("=");
                const read_from = p.columns.len;
                _ = try p.expr();
                if (readsAssigned(p.columns[read_from..], target, assigned)) |read|
                    return p.refuseWith("rsql: SET reads " ++ read ++ " after assigning it, and MySQL assigns left to right; read it before the write or assign it last");
                assigned = assigned ++ .{column};
                if (!p.acceptSymbol(",")) break;
            }
            try p.expect("WHERE");
            const where = try p.expr();
            p.close(opened, writtenTable(target), where);
            break :update .{ .update = .{ .table = target, .assigned = assigned, .where = where, .query = opened.id } };
        } else if (p.accept("DELETE")) delete: {
            try p.expect("FROM");
            const target = try p.tableName();
            const opened = p.open();
            try p.expect("WHERE");
            const where = try p.expr();
            p.close(opened, writtenTable(target), where);
            break :delete .{ .delete = .{ .table = target, .where = where, .query = opened.id } };
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
        const opened = p.open();
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
        p.close(opened, sources, where);
        return .{ .results = results, .sources = sources, .where = where, .query = opened.id };
    }

    /// A table or WITH name and its alias. The only marker that may
    /// follow them is `@index(name)`, naming an index of that same table.
    fn source(p: *Parser, outer: bool) Refused!Source {
        const written = try p.name();
        const defined = for (p.defined) |each| {
            if (std.mem.eql(u8, each, written)) break true;
        } else false;
        if (!defined and !isTable(written)) return p.refuseWith("rsql: no table named " ++ written);
        const alias = if (p.accept("AS")) try p.name() else if (p.peek().kind == .word and !isGrammarWord(p.peek().text)) p.next().text else written;
        if (p.peek().kind == .marker) {
            if (!std.mem.eql(u8, p.next().text, "@index")) return p.refuseWith("rsql: only @index(name) follows a table");
            try p.expectSymbol("(");
            const index = try p.name();
            try p.expectSymbol(")");
            if (defined or !isIndexOf(written, index)) return p.refuseWith("rsql: @index names an index of its own table, and " ++ written ++ " has no index " ++ index);
        }
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
                const negated = p.accept("NOT");
                try p.expect("NULL");
                const tested = left;
                left = if (!negated and tested == .column) .{ .is_null = tested.column } else .other;
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
            if (std.ascii.eqlIgnoreCase(first, "length"))
                return p.refuseWith("rsql: length() counts characters of text on SQLite and bytes on MySQL; write @octets(x)");
            const arguments = !p.peek().isSymbol(")");
            if (!p.acceptSymbol("*") and arguments) {
                _ = p.accept("DISTINCT");
                _ = try p.expressions();
            }
            try p.expectSymbol(")");
            if (p.accept("OVER")) try p.window(std.ascii.eqlIgnoreCase(first, "row_number") and !arguments);
            return .other;
        }
        const column: Column = if (p.acceptSymbol(".")) .{ .table = first, .name = try p.name() } else .{ .table = null, .name = first };
        p.columns = p.columns ++ .{column};
        return .{ .column = column };
    }

    /// The `(ORDER BY expr [ASC|DESC], ...)` after `OVER`, which only
    /// `row_number()` takes: no PARTITION BY, no frame.
    fn window(p: *Parser, row_number: bool) Refused!void {
        const refused = "rsql: the one window is row_number() OVER (ORDER BY ...), with no PARTITION BY or frame";
        if (!row_number) return p.refuseWith(refused);
        try p.expectSymbol("(");
        if (!p.accept("ORDER")) return p.refuseWith(refused);
        try p.expect("BY");
        while (true) {
            _ = try p.expr();
            if (!p.accept("ASC")) _ = p.accept("DESC");
            if (!p.acceptSymbol(",")) break;
        }
        if (!p.acceptSymbol(")")) return p.refuseWith(refused);
    }

    /// `?N`, N from 1 to 64; SQLite's other forms (`?`, `:name`, `@name`,
    /// `$name`) are refused, so every parameter is counted.
    fn parameter(p: *Parser, token: Token) Refused!usize {
        const number = std.fmt.parseInt(usize, token.text[1..], 10) catch return p.refuseWith("rsql: write parameters as ?N");
        if (number == 0 or number > p.uses.len) return p.refuseWith(std.fmt.comptimePrint("rsql: a parameter is ?1 to ?{d}", .{max_parameters}));
        p.uses[number - 1] += 1;
        return number;
    }

    /// A marker in an expression: `@now` takes no arguments; `@session`
    /// takes one parameter ?k; `@octets`, `@count_where` and `@served` one expression;
    /// `@charset`, `@initial`, `@same`, `@distinct` and `@max_where` two. `@index` stands only after
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
        const arity: usize = for ([_][]const u8{ "octets", "count_where", "served" }) |single| {
            if (std.mem.eql(u8, marker_name, single)) break 1;
        } else for ([_][]const u8{ "charset", "initial", "same", "distinct", "max_where" }) |binary| {
            if (std.mem.eql(u8, marker_name, binary)) break 2;
        } else return p.refuseWith("rsql: unknown marker " ++ written);
        try p.expectSymbol("(");
        const arguments = try p.expressions();
        try p.expectSymbol(")");
        if (arguments.len != arity) return p.refuseWith(std.fmt.comptimePrint("rsql: {s} takes {d} arguments", .{ written, arity }));
        return .other;
    }
};

/// The first of `read` that an UPDATE of `table` reads after an earlier
/// assignment of `assigned` wrote it, or null. It compares names: a column
/// read bare, or qualified by `table`, anywhere in the value, subqueries
/// included, so a subquery's own column of that name counts too.
fn readsAssigned(comptime read: []const Column, comptime table: []const u8, comptime assigned: []const []const u8) ?[]const u8 {
    for (read) |column| {
        if (column.table) |qualifier| if (!std.mem.eql(u8, qualifier, table)) continue;
        for (assigned) |name| if (std.mem.eql(u8, name, column.name)) return name;
    }
    return null;
}

fn fieldCount(comptime T: type) usize {
    return @typeInfo(T).@"struct".field_names.len;
}

/// The SessionHead fields of Args, in order.
fn sessionFields(comptime Args: type) []const []const u8 {
    comptime {
        var fields: []const []const u8 = &.{};
        const info = @typeInfo(Args).@"struct";
        for (info.field_names, info.field_types) |name, Field| if (Field == SessionHead) {
            fields = fields ++ .{name};
        };
        return fields;
    }
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
fn parameterError(comptime uses: [max_parameters]usize, comptime Args: type) ?[]const u8 {
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
    if (sessionFields(Args).len != 0 or parsed.sessions.len != 0) return "rsql: a read binds no SessionHead; it names a Session by its reference text";
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

/// Why a write's Sessions are unnamed, or named anywhere but on their own
/// columns, or a table it reads is not tied to them, or null. It checks
/// exactly this. A write to a table that carries no Sessions
/// (`schema.carriesSessions`) binds no SessionHead and writes no marker,
/// and nothing more is checked of it. A write to one that does:
/// - binds the k of each `@session(?k)` to a SessionHead field of Args,
///   uses ?k only in such markers, and binds every SessionHead field so;
///   its markers name at least one k, and at most one per column of
///   `schema.sessionColumns` (exactly one where it has one column);
/// - as an INSERT ... VALUES (`insertSessionError`), gives each Session
///   column a lone marker, or NULL (written, or by leaving the column out)
///   where the column is nullable, and gives each SessionHead as one
///   Session column's value;
/// - as an INSERT ... SELECT, writes to a table whose one Session column
///   is session_ref, NOT NULL, and copies it from a table its SELECT reads
///   (`copyError`);
/// - as an UPDATE, ties the table it writes (`tiedRefs`), which it can do
///   only by the top-level WHERE conjunct `c=@session(?k)` for that
///   table's first Session column `c`, and assigns no Session column. In
///   a table that names two Sessions, a second marker is the conjunct
///   `sender_session_ref=@session(?j)` (`ties`); and a column its sender
///   reads (`schema.ReadBy.both`) is assigned only under that conjunct or
///   the top-level conjunct `sender_session_ref IS NULL` (`nulls`);
/// - as a DELETE, ties its table so, and deletes from a table with one
///   Session column only;
/// - ties every reference to a table that carries Sessions anywhere in its
///   text (`tableRefs`, `tiedRefs`): FROM, JOIN, and every subquery.
/// A conjunct is a term of an AND chain, parentheses dropped, so it holds
/// of every row its query reads. No write holds a compound SELECT
/// (`compoundError`). So every row a write reads or inserts in a table
/// that carries Sessions belongs to a Session its heads name, an UPDATE or
/// DELETE changes only such rows, and an UPDATE changes only columns those
/// Sessions read; the Access that queues it touches each. `expectError`
/// holds a copy's Expect to its row count.
fn sessionError(comptime parsed: Parsed, comptime Args: type) ?[]const u8 {
    comptime {
        const table = switch (parsed.statement) {
            .select => unreachable,
            inline else => |written| written.table,
        };
        const fields = @typeInfo(Args).@"struct".field_types;
        const heads = sessionFields(Args).len;
        if (!schema.carriesSessions(table)) {
            if (parsed.sessions.len != 0) return "rsql: " ++ table ++ " carries no Sessions; write no @session";
            if (heads != 0) return "rsql: " ++ table ++ " carries no Sessions; bind no SessionHead";
            return null;
        }
        const columns = schema.sessionColumns(table);
        const named = distinct(parsed.sessions);
        if (named.len == 0 or named.len > columns.len) return if (columns.len == 1)
            "rsql: a write to " ++ table ++ " names its Session exactly once, as @session(?k)"
        else
            "rsql: a write to " ++ table ++ " names each of its Sessions at most once, and one at least, as @session(?k)";
        for (named) |k| {
            if (k > fields.len or fields[k - 1] != SessionHead or (columns.len == 1 and heads != 1))
                return if (columns.len == 1) "rsql: @session(?k) binds the one SessionHead field of Args" else "rsql: @session(?k) binds a SessionHead field of Args";
            if (parsed.uses[k - 1] != occurrences(parsed.sessions, k)) return "rsql: the SessionHead ?k binds is used only in @session(?k)";
        }
        // Each k binds its own head: equal counts leave none unbound.
        if (heads != named.len) return "rsql: every SessionHead of Args is bound by its own @session(?k)";
        const refs = tableRefs(parsed.queries);
        const tied = tiedRefs(parsed.queries);
        const misplaced = "rsql: an UPDATE or DELETE names its Session as the conjunct " ++ columns[0] ++ "=@session(?k) of its WHERE";
        const refusal: ?[]const u8 = switch (parsed.statement) {
            .select => unreachable,
            .insert => |insert| switch (insert.values) {
                .row => |row| insertSessionError(table, columns, insert.columns, row, named.len),
                .select => |select| copy: {
                    if (columns.len != 1 or !std.mem.eql(u8, columns[0], "session_ref") or schema.isNullable(table, "session_ref"))
                        break :copy "rsql: an INSERT ... SELECT copies one Session's row; " ++ table ++ " names its Sessions otherwise";
                    const at = (sessionSlot(insert.columns, "session_ref") catch break :copy copied_message) orelse break :copy copied_message;
                    break :copy copyError(parsed.queries, select, at, insert.columns.len);
                },
            },
            .update => |update| update: {
                for (update.assigned) |name| for (columns) |column| if (std.mem.eql(u8, name, column)) break :update misplaced;
                if (!tied[refIndex(refs, .{ .query = queryAt(parsed.queries, update.query), .source = 0 })]) break :update misplaced;
                if (columns.len == 1) break :update null;
                const sender_tied = ties(update.where, table, columns[1]);
                if (named.len == 2 and !sender_tied)
                    break :update "rsql: an UPDATE of " ++ table ++ " names its second Session as the conjunct " ++ columns[1] ++ "=@session(?j) of its WHERE";
                if (sender_tied or nulls(update.where, table, columns[1])) break :update null;
                for (update.assigned) |name| for (schema.readByBoth(table)) |both| if (std.mem.eql(u8, name, both))
                    break :update "rsql: " ++ table ++ "." ++ both ++ " is read by its sender too; an UPDATE of it has the conjunct " ++
                        columns[1] ++ "=@session(?j) or " ++ columns[1] ++ " IS NULL";
                break :update null;
            },
            .delete => |delete| delete: {
                if (columns.len > 1) break :delete "rsql: a DELETE from " ++ table ++ " would drop two Sessions' facts; no writer deletes them";
                break :delete if (tied[refIndex(refs, .{ .query = queryAt(parsed.queries, delete.query), .source = 0 })]) null else misplaced;
            },
        };
        if (refusal) |message| return message;
        for (refs, tied) |ref, done| {
            const source = parsed.queries[ref.query].sources[ref.source];
            if (!done and schema.carriesSessions(source.table)) return untiedMessage(source.table, source.alias);
        }
        return null;
    }
}

/// The k of each marker, once each, in the order first written.
fn distinct(comptime markers: []const usize) []const usize {
    comptime {
        var named: []const usize = &.{};
        for (markers) |k| if (occurrences(named, k) == 0) {
            named = named ++ .{k};
        };
        return named;
    }
}

fn occurrences(comptime markers: []const usize, comptime k: usize) usize {
    var count: usize = 0;
    for (markers) |each| count += @intFromBool(each == k);
    return count;
}

fn untiedMessage(comptime table: []const u8, comptime alias: []const u8) []const u8 {
    comptime {
        const column = schema.sessionColumns(table)[0];
        const named = if (std.mem.eql(u8, alias, table)) table else table ++ " " ++ alias;
        return "rsql: a write ties every table it reads to its Session; " ++ named ++ " needs, in its own query, the conjunct " ++
            alias ++ "." ++ column ++ "=@session(?k) or " ++ alias ++ "." ++ column ++ " equal to a tied table's Session column";
    }
}

/// The slot of `column` in an INSERT's column list, or null when it is not
/// listed; listed twice is an error.
fn sessionSlot(comptime listed: []const []const u8, comptime column: []const u8) error{Twice}!?usize {
    var slot: ?usize = null;
    for (listed, 0..) |name, index| if (std.mem.eql(u8, name, column)) {
        if (slot != null) return error.Twice;
        slot = index;
    };
    return slot;
}

/// See `sessionError`: an INSERT's one VALUES row gives one value per
/// listed column; each Session column's value is a lone `@session(?k)`, or
/// NULL (the constant, or the column left out) where `schema.isNullable`
/// says the column is; no two Session columns take the same k; and they
/// take all `heads` of Args. A marker elsewhere in the row (a subquery's
/// tie) is held to the walk (`tiedRefs`) like any other.
fn insertSessionError(
    comptime table: []const u8,
    comptime columns: []const []const u8,
    comptime listed: []const []const u8,
    comptime row: []const Expr,
    comptime heads: usize,
) ?[]const u8 {
    comptime {
        if (row.len != listed.len) return "rsql: an INSERT gives one value per column";
        var placed: []const usize = &.{};
        for (columns) |column| {
            const inserted = "rsql: an INSERT names its Session as the " ++ column ++ " value of its VALUES row";
            const slot = sessionSlot(listed, column) catch return inserted;
            if (slot) |at| switch (row[at]) {
                .session => |k| {
                    if (occurrences(placed, k) != 0) return "rsql: an INSERT names each of its Sessions with its own SessionHead";
                    placed = placed ++ .{k};
                },
                .constant => |text| if (!std.ascii.eqlIgnoreCase(text, "NULL") or !schema.isNullable(table, column)) return inserted,
                else => return inserted,
            } else if (!schema.isNullable(table, column)) return inserted;
        }
        if (placed.len != heads) return "rsql: an INSERT gives each SessionHead as a Session column's value";
        return null;
    }
}

const copied_message = "rsql: an INSERT ... SELECT copies session_ref as the session_ref column of a table its SELECT reads";

/// See `sessionError`: an INSERT ... SELECT whose target's one Session
/// column is session_ref. It checks exactly this: the SELECT gives one
/// value per listed column, and the value in session_ref's slot is a
/// column named session_ref of a source of the SELECT's first core (bare
/// where that core reads one source, or qualified by the source's alias)
/// that is a table carrying Sessions, not a WITH name. A table with a
/// session_ref column lists it first (`schema.sessionColumns`), so the
/// walk ties that column (`tiedRefs`) to the write's one Session, and
/// every copied value is the reference its head binds (a table without
/// it fails to prepare); a LEFT JOIN's or an aggregate's row with no source row copies
/// NULL, which session_ref refuses.
fn copyError(comptime queries: []const Query, comptime select: Select, comptime column: usize, comptime columns: usize) ?[]const u8 {
    const core = select.first;
    if (core.results.len != columns) return "rsql: an INSERT gives one value per column";
    const value = core.results[column].value;
    if (value != .column or !std.mem.eql(u8, value.column.name, "session_ref")) return copied_message;
    const at = queryAt(queries, core.query);
    const ref = resolve(queries, at, value.column) orelse return copied_message;
    const source = queries[ref.query].sources[ref.source];
    if (source.defined or !schema.carriesSessions(source.table)) return copied_message;
    return null;
}

/// One table reference: source `source` of query `query` (an index into
/// `Parsed.queries`).
const Ref = struct { query: usize, source: usize };

/// Every table reference of a statement, wherever it stands: each source
/// of each query (`Query`) that names a table, not a WITH name. The parser
/// records a query for every SELECT core (subqueries in any expression,
/// WITH bodies, IN lists) and for an UPDATE's or DELETE's own table, so
/// this is every table the text reads or writes.
fn tableRefs(comptime queries: []const Query) []const Ref {
    comptime {
        var refs: []const Ref = &.{};
        for (queries, 0..) |query, q| for (query.sources, 0..) |source, s| {
            if (!source.defined) refs = refs ++ .{Ref{ .query = q, .source = s }};
        };
        return refs;
    }
}

fn refIndex(comptime refs: []const Ref, comptime ref: Ref) usize {
    for (refs, 0..) |each, index| if (each.query == ref.query and each.source == ref.source) return index;
    unreachable;
}

fn queryAt(comptime queries: []const Query, comptime id: usize) usize {
    for (queries, 0..) |query, index| if (query.id == id) return index;
    unreachable;
}

/// The source `column` names from query `q`: a qualified column the
/// source with that alias in the innermost query, from q outward, that
/// has one; a bare column q's source when q reads one, and otherwise none.
fn resolve(comptime queries: []const Query, comptime q: usize, comptime column: Column) ?Ref {
    const qualifier = column.table orelse return if (queries[q].sources.len == 1) .{ .query = q, .source = 0 } else null;
    var at: ?usize = q;
    while (at) |index| {
        for (queries[index].sources, 0..) |source, s| if (std.mem.eql(u8, source.alias, qualifier)) return .{ .query = index, .source = s };
        at = if (queries[index].parent) |parent| queryAt(queries, parent) else null;
    }
    return null;
}

/// Which of `tableRefs(queries)` are tied to a Session the write names.
/// A reference r to a table that carries Sessions, standing in query q,
/// whose first Session column is c (`schema.sessionColumns`), is tied when
/// a conjunct of q's WHERE, of r's own ON, or of an inner join's ON in q
/// is `r.c=@session(?k)`, or `r.c=s.d` for another tied reference s that q
/// or a query holding q reads, d being s's first Session column (either
/// way round; columns name sources as `resolve` says). A reference to a
/// table without Sessions is never tied, and no rule asks it to be.
fn tiedRefs(comptime queries: []const Query) []const bool {
    comptime {
        @setEvalBranchQuota(1_000_000);
        const refs = tableRefs(queries);
        var tied: [refs.len]bool = @splat(false);
        var changed = true;
        while (changed) {
            changed = false;
            for (refs, &tied) |ref, *done| {
                if (done.* or !schema.carriesSessions(queries[ref.query].sources[ref.source].table)) continue;
                if (tiesRef(queries, refs, &tied, ref)) {
                    done.* = true;
                    changed = true;
                }
            }
        }
        const result = tied;
        return &result;
    }
}

/// See `tiedRefs`: whether a conjunct of `ref`'s query ties it.
fn tiesRef(comptime queries: []const Query, comptime refs: []const Ref, comptime tied: []const bool, comptime ref: Ref) bool {
    const query = queries[ref.query];
    for (query.sources, 0..) |source, s| if (source.on) |on| if (!source.outer or s == ref.source) {
        for (conjuncts(on)) |term| if (equates(queries, refs, tied, ref, term)) return true;
    };
    if (query.where) |where| for (conjuncts(where)) |term| if (equates(queries, refs, tied, ref, term)) return true;
    return false;
}

fn equates(comptime queries: []const Query, comptime refs: []const Ref, comptime tied: []const bool, comptime ref: Ref, comptime term: Expr) bool {
    if (term != .equality) return false;
    const column = schema.sessionColumns(queries[ref.query].sources[ref.source].table)[0];
    const sides = term.equality.*;
    for (sides, 0..) |side, which| {
        if (side != .column or !std.mem.eql(u8, side.column.name, column)) continue;
        const named = resolve(queries, ref.query, side.column) orelse continue;
        if (named.query != ref.query or named.source != ref.source) continue;
        switch (sides[1 - which]) {
            .session => return true,
            .column => |other| {
                const partner = resolve(queries, ref.query, other) orelse continue;
                if (partner.query == ref.query and partner.source == ref.source) continue;
                const source = queries[partner.query].sources[partner.source];
                if (source.defined or !schema.carriesSessions(source.table)) continue;
                if (std.mem.eql(u8, other.name, schema.sessionColumns(source.table)[0]) and tied[refIndex(refs, partner)]) return true;
            },
            else => {},
        }
    }
    return false;
}

/// Whether `where` has the conjunct `column=@session(?k)`, its column bare
/// or qualified by `table`, the written table's name.
fn ties(comptime where: Expr, comptime table: []const u8, comptime column: []const u8) bool {
    for (conjuncts(where)) |term| {
        if (term != .equality) continue;
        const named = term.equality[0];
        if (named == .column and std.mem.eql(u8, named.column.name, column) and
            (named.column.table == null or std.mem.eql(u8, named.column.table.?, table)) and term.equality[1] == .session) return true;
    }
    return false;
}

/// Whether `where` has the conjunct `column IS NULL`, its column bare or
/// qualified by `table`.
fn nulls(comptime where: Expr, comptime table: []const u8, comptime column: []const u8) bool {
    for (conjuncts(where)) |term| {
        if (term == .is_null and std.mem.eql(u8, term.is_null.name, column) and
            (term.is_null.table == null or std.mem.eql(u8, term.is_null.table.?, table))) return true;
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
/// `index`'s `column`, where the value is a parameter (`@session(?k)`
/// binds one), a constant, or a column of another pinned source.
fn fixes(comptime condition: Expr, comptime sources: []const Source, comptime pinned: []const bool, comptime index: usize, comptime column: []const u8) bool {
    if (condition != .equality) return false;
    const sides = condition.equality.*;
    for (sides, 0..) |side, which| {
        if (!names(side, sources, index, column)) continue;
        switch (sides[1 - which]) {
            .parameter, .session, .constant => return true,
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
        @setEvalBranchQuota(200 * sql.len + 10_000 + schema.objects_quota);
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
    const Marker = enum { octets, charset, initial, same, distinct, count_where, max_where, served };
    const kind = std.meta.stringToEnum(Marker, name) orelse @compileError("rsql: unknown marker @" ++ name ++ ": " ++ text);
    const arity: usize = if (kind == .octets or kind == .count_where or kind == .served) 1 else 2;
    if (arguments.len != arity) @compileError("rsql: @" ++ name ++ " takes " ++ std.fmt.comptimePrint("{d}", .{arity}) ++ " arguments: " ++ text);
    const first = renderSqlite(arguments[0]);
    return switch (kind) {
        .octets => "length(CAST(" ++ first ++ " AS BLOB))",
        .charset => "(" ++ first ++ " NOT GLOB '*[^" ++ characterSet(arguments[1], text) ++ "]*' AND length(" ++ first ++ ")=length(CAST(" ++ first ++ " AS BLOB)))",
        .initial => first ++ " GLOB '[" ++ characterSet(arguments[1], text) ++ "]*'",
        .same => "(" ++ first ++ " IS " ++ renderSqlite(arguments[1]) ++ ")",
        .distinct => "(" ++ first ++ " IS NOT " ++ renderSqlite(arguments[1]) ++ ")",
        .count_where => "count(*) FILTER (WHERE " ++ first ++ ")",
        .max_where => "max(" ++ first ++ ") FILTER (WHERE " ++ renderSqlite(arguments[1]) ++ ")",
        .served => "rui_served(" ++ first ++ ")",
    };
}

/// A place in MySQL text where PR 8's engine writes a literal, and where
/// PREPARE writes `?`.
pub const Slot = union(enum) {
    /// Args field k-1, for `?k` and for `@session(?k)`'s reference.
    argument: usize,
    /// The Access's second, for `@now`.
    now,
    /// This provider's place in `@served(x)`'s list.
    served: provider_name.Provider,
};

/// Text in MySQL 8.4's spelling, with a slot between each two parts.
pub const Template = struct {
    /// One more than `slots`.
    parts: []const []const u8,
    slots: []const Slot,

    /// The parts joined with `?`, the text MySQL PREPAREs.
    pub fn prepared(comptime template: Template) [:0]const u8 {
        comptime {
            var text: []const u8 = template.parts[0];
            for (template.parts[1..]) |part| text = text ++ "?" ++ part;
            const terminated = text ++ "\x00";
            return terminated[0..text.len :0];
        }
    }
};

pub const MysqlRendering = union(enum) { refused: []const u8, rendered: Template };

/// `text` in MySQL's spelling, failing the build where `mysqlRendering`
/// refuses it.
fn mysqlTemplate(comptime text: []const u8) Template {
    return switch (comptime mysqlRendering(text)) {
        .refused => |message| @compileError(message ++ ": " ++ text),
        .rendered => |template| template,
    };
}

/// Portable Rui SQL in MySQL 8.4's spelling, or why it has none. Text
/// between tokens is copied, and string literals are copied whole. It
/// replaces:
///
///   ?k, @session(?k)     a slot for Args field k-1
///   @now                 a slot for the Access's second
///   @index(name)         nothing: MySQL plans alone until PR 8 reads EXPLAIN
///   @served(x)           `(x IN (?,...))`, a slot per `provider_name.Provider`
///   @octets(x)           `OCTET_LENGTH(x)`
///   @charset(c,'set')    `(NOT REGEXP_LIKE(c,'[^set]','c'))`: no character
///                        outside the set; `'c'` compares case-sensitively
///   @initial(c,'set')    `REGEXP_LIKE(c,'^[set]','c')`
///   @same(a,b)           `(a <=> b)`
///   @distinct(a,b)       `(NOT (a <=> b))`
///   @count_where(c)      `count(CASE WHEN c THEN 1 END)`
///   @max_where(x,c)      `max(CASE WHEN c THEN x END)`
///   ==                   `=`
///   /                    ` DIV `: SQLite divides two integers to an integer,
///                        truncated, as DIV does, where MySQL's `/` gives a
///                        decimal. Rui SQL divides only integers: the grammar
///                        reads no decimal literal and the schema has no REAL
///                        column
///   a function call      its `functions` entry's MySQL name
///
/// It refuses text `portabilityError` refuses, a call no `functions` entry
/// names with that many arguments, CAST, and an unknown or malformed marker.
pub fn mysqlRendering(comptime text: []const u8) MysqlRendering {
    comptime {
        @setEvalBranchQuota(200 * text.len + 10_000);
        if (portabilityError(text, reserved_names_checked)) |message| return .{ .refused = message };
        const tokens = tokenize(text);
        var renderer: MysqlRenderer = .{ .text = text, .tokens = tokens };
        renderer.range(0, tokens.len) catch return .{ .refused = renderer.message };
        return .{ .rendered = .{ .parts = renderer.parts ++ .{renderer.current}, .slots = renderer.slots } };
    }
}

/// The functions Rui SQL may call, by name and argument count (null: any),
/// with each one's MySQL name and the arguments MySQL's takes before
/// Rui SQL's. MySQL rendering refuses any other call. `zeroblob(n)` is
/// `REPEAT(X'00',n)`, the same n zero bytes, built where SQLite reserves
/// them; PR 8 writes MySQL content in chunks instead.
/// `length` counts characters of text on SQLite and bytes on MySQL, so a
/// typed statement may not call it (`Parser.operand`); the schema's
/// `.bytes` bounds do.
const functions = [_]struct { name: []const u8, arguments: ?usize, mysql: []const u8, leading: []const u8 = "" }{
    .{ .name = "abs", .arguments = 1, .mysql = "abs" },
    .{ .name = "coalesce", .arguments = null, .mysql = "coalesce" },
    .{ .name = "count", .arguments = 1, .mysql = "count" },
    .{ .name = "length", .arguments = 1, .mysql = "length" },
    .{ .name = "max", .arguments = 1, .mysql = "max" },
    .{ .name = "max", .arguments = 2, .mysql = "GREATEST" },
    .{ .name = "min", .arguments = 1, .mysql = "min" },
    .{ .name = "min", .arguments = 2, .mysql = "LEAST" },
    .{ .name = "row_number", .arguments = 0, .mysql = "row_number" },
    .{ .name = "sum", .arguments = 1, .mysql = "sum" },
    .{ .name = "zeroblob", .arguments = 1, .mysql = "REPEAT", .leading = "X'00'," },
};

const MysqlRenderer = struct {
    text: []const u8,
    tokens: []const Token,
    parts: []const []const u8 = &.{},
    current: []const u8 = "",
    slots: []const Slot = &.{},
    message: []const u8 = "",

    fn emit(r: *MysqlRenderer, text: []const u8) void {
        r.current = r.current ++ text;
    }

    fn slot(r: *MysqlRenderer, which: Slot) void {
        r.parts = r.parts ++ .{r.current};
        r.current = "";
        r.slots = r.slots ++ .{which};
    }

    fn refuse(r: *MysqlRenderer, message: []const u8) error{Refused} {
        r.message = message;
        return error.Refused;
    }

    /// Renders `tokens[from..to]`, with the text between them copied.
    fn range(r: *MysqlRenderer, from: usize, to: usize) Refused!void {
        var at = from;
        while (at < to) {
            if (at > from) {
                const previous = r.tokens[at - 1];
                r.emit(r.text[previous.start + previous.text.len .. r.tokens[at].start]);
            }
            at = try r.token(at, to);
        }
    }

    /// Renders the token at `at` and any it governs; returns the index after them.
    fn token(r: *MysqlRenderer, at: usize, to: usize) Refused!usize {
        const current = r.tokens[at];
        switch (current.kind) {
            .parameter => {
                const number = std.fmt.parseInt(usize, current.text[1..], 10) catch return r.refuse("rsql: write parameters as ?N");
                if (number == 0) return r.refuse("rsql: write parameters as ?N");
                r.slot(.{ .argument = number - 1 });
                return at + 1;
            },
            .marker => return r.marker(at, to),
            .word => {
                if (current.is("CAST")) return r.refuse("rsql: CAST converts differently on each engine; MySQL rendering refuses it");
                if (isCall(r.tokens, at, to)) {
                    const arguments = argumentRanges(r.tokens, at + 1, closingToken(r.tokens, at + 1, to).?).len;
                    for (functions) |function| {
                        if (!std.ascii.eqlIgnoreCase(function.name, current.text)) continue;
                        if (function.arguments) |count| if (count != arguments) continue;
                        r.emit(function.mysql ++ "(" ++ function.leading);
                        return at + 2;
                    }
                    return r.refuse(std.fmt.comptimePrint("rsql: MySQL rendering knows no function {s} of {d} arguments", .{ current.text, arguments }));
                }
            },
            .symbol => {
                if (current.isSymbol("==")) {
                    r.emit("=");
                    return at + 1;
                }
                if (current.isSymbol("/")) {
                    r.emit(" DIV ");
                    return at + 1;
                }
            },
            .number, .literal, .end => {},
        }
        r.emit(current.text);
        return at + 1;
    }

    fn marker(r: *MysqlRenderer, at: usize, to: usize) Refused!usize {
        const name = r.tokens[at].text[1..];
        if (std.mem.eql(u8, name, "now")) {
            r.slot(.now);
            return at + 1;
        }
        const close = if (at + 1 < to and r.tokens[at + 1].isSymbol("(")) closingToken(r.tokens, at + 1, to) else null;
        const end = close orelse return r.refuse("rsql: @" ++ name ++ " needs its arguments in parentheses");
        const Marker = enum { index, session, served, octets, charset, initial, same, distinct, count_where, max_where };
        const kind = std.meta.stringToEnum(Marker, name) orelse return r.refuse("rsql: unknown marker @" ++ name);
        const arguments = argumentRanges(r.tokens, at + 1, end);
        const arity: usize = switch (kind) {
            .index, .session, .served, .octets, .count_where => 1,
            .charset, .initial, .same, .distinct, .max_where => 2,
        };
        if (arguments.len != arity) return r.refuse(std.fmt.comptimePrint("rsql: @{s} takes {d} arguments", .{ name, arity }));
        const a = arguments[0];
        switch (kind) {
            .index => {},
            .session => try r.range(a[0], a[1]),
            .served => {
                r.emit("(");
                try r.range(a[0], a[1]);
                r.emit(" IN (");
                for (std.enums.values(provider_name.Provider), 0..) |provider, index| {
                    if (index != 0) r.emit(",");
                    r.slot(.{ .served = provider });
                }
                r.emit("))");
            },
            .octets => try r.wrap("OCTET_LENGTH(", a, ")"),
            .charset => try r.wrap("(NOT REGEXP_LIKE(", a, ",'[^" ++ try r.set(arguments[1]) ++ "]','c'))"),
            .initial => try r.wrap("REGEXP_LIKE(", a, ",'^[" ++ try r.set(arguments[1]) ++ "]','c')"),
            .same, .distinct => {
                r.emit(if (kind == .same) "(" else "(NOT (");
                try r.range(a[0], a[1]);
                try r.wrap(" <=> ", arguments[1], if (kind == .same) ")" else "))");
            },
            .count_where => try r.wrap("count(CASE WHEN ", a, " THEN 1 END)"),
            .max_where => {
                try r.wrap("max(CASE WHEN ", arguments[1], " THEN ");
                try r.wrap("", a, " END)");
            },
        }
        return end + 1;
    }

    fn wrap(r: *MysqlRenderer, before: []const u8, argument: [2]usize, after: []const u8) Refused!void {
        r.emit(before);
        try r.range(argument[0], argument[1]);
        r.emit(after);
    }

    /// A character set argument: one literal, held to `characterSet`.
    fn set(r: *MysqlRenderer, argument: [2]usize) Refused![]const u8 {
        if (argument[1] != argument[0] + 1 or r.tokens[argument[0]].kind != .literal) return r.refuse("rsql: a character set is one quoted literal");
        return characterSet(r.tokens[argument[0]].text, r.text);
    }
};

/// Whether the word at `at` calls a function: a name that is no grammar
/// word, before `(`, and neither the table of `INTO table(` nor a WITH
/// name before its column list (`name(...) AS (`).
fn isCall(comptime tokens: []const Token, comptime at: usize, comptime to: usize) bool {
    const word = tokens[at];
    if (word.kind != .word or isGrammarWord(word.text)) return false;
    if (at + 1 >= to or !tokens[at + 1].isSymbol("(")) return false;
    if (at > 0 and tokens[at - 1].is("INTO")) return false;
    const close = closingToken(tokens, at + 1, to) orelse return false;
    return !(close + 2 < to and tokens[close + 1].is("AS") and tokens[close + 2].isSymbol("("));
}

/// The index of the `)` that closes the `(` at `open`, before `to`.
fn closingToken(comptime tokens: []const Token, comptime open: usize, comptime to: usize) ?usize {
    var depth: usize = 0;
    for (tokens[open..to], open..) |each, index| {
        if (each.isSymbol("(")) depth += 1;
        if (each.isSymbol(")")) {
            depth -= 1;
            if (depth == 0) return index;
        }
    }
    return null;
}

/// The token ranges of the arguments between `(` at `open` and `)` at
/// `close`, split at their own commas; none when nothing stands between.
fn argumentRanges(comptime tokens: []const Token, comptime open: usize, comptime close: usize) []const [2]usize {
    comptime {
        if (close == open + 1) return &.{};
        var ranges: []const [2]usize = &.{};
        var depth: usize = 0;
        var start = open + 1;
        for (tokens[open + 1 .. close], open + 1..) |each, index| {
            if (each.isSymbol("(")) depth += 1;
            if (each.isSymbol(")")) depth -= 1;
            if (depth == 0 and each.isSymbol(",")) {
                ranges = ranges ++ .{[2]usize{ start, index }};
                start = index + 1;
            }
        }
        return ranges ++ .{[2]usize{ start, close }};
    }
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
    try std.testing.expectEqualStrings("count(*) FILTER (WHERE a.authorized=0 AND (x IS 1))", comptime render(.sqlite, "@count_where(a.authorized=0 AND @same(x,1))"));
    try std.testing.expectEqualStrings("max(a.decided_at) FILTER (WHERE r.permission_mode=0)", comptime render(.sqlite, "@max_where(a.decided_at,r.permission_mode=0)"));
}

test "markers nest, and text outside them is copied" {
    try std.testing.expectEqualStrings(
        "x IS NULL OR (length(CAST(x AS BLOB))=6 AND (x NOT GLOB '*[^a-f]*' AND length(x)=length(CAST(x AS BLOB)))) AND '@octets(y)'='@'",
        comptime render(.sqlite, "x IS NULL OR (@octets(x)=6 AND @charset(x,'a-f')) AND '@octets(y)'='@'"),
    );
    try std.testing.expectEqualStrings("(length(CAST(a AS BLOB)) IS b)", comptime render(.sqlite, "@same(@octets(a), b)"));
}

test "each marker renders its MySQL spelling" {
    try std.testing.expectEqualStrings("OCTET_LENGTH(workspace)<=4096", comptime render(.mysql, "@octets(workspace)<=4096"));
    try std.testing.expectEqualStrings("(NOT REGEXP_LIKE(provider,'[^a-z0-9_-]','c'))", comptime render(.mysql, "@charset(provider,'a-z0-9_-')"));
    try std.testing.expectEqualStrings("REGEXP_LIKE(provider,'^[a-z]','c')", comptime render(.mysql, "@initial(provider,'a-z')"));
    try std.testing.expectEqualStrings("(action_kind <=> 1)", comptime render(.mysql, "@same(action_kind,1)"));
    try std.testing.expectEqualStrings("(NOT (resolution_code <=> 'denied'))", comptime render(.mysql, "@distinct(resolution_code,'denied')"));
    try std.testing.expectEqualStrings("count(CASE WHEN a.authorized=0 AND (x <=> 1) THEN 1 END)", comptime render(.mysql, "@count_where(a.authorized=0 AND @same(x,1))"));
    try std.testing.expectEqualStrings("max(CASE WHEN r.permission_mode=0 THEN a.decided_at END)", comptime render(.mysql, "@max_where(a.decided_at,r.permission_mode=0)"));
    try std.testing.expectEqualStrings("GREATEST(a, b)>LEAST(c,d) AND max(e)=1 AND f='@octets(g)'", comptime render(.mysql, "max(a, b)>min(c,d) AND max(e)==1 AND f='@octets(g)'"));
}

test "a statement's MySQL text has a slot for each parameter, @now and @session, and drops @index" {
    const W = Write(.{
        .sql = "UPDATE turn SET outcome_at=@now WHERE turn_id=?1 AND session_ref=@session(?2) AND operation_id>?1",
        .Args = struct { turn_id: u64, session: SessionHead },
        .expect = .{ .at_most = 1 },
    });
    try std.testing.expectEqualStrings("UPDATE turn SET outcome_at=? WHERE turn_id=? AND session_ref=? AND operation_id>?", comptime W.mysql.prepared());
    try std.testing.expectEqualDeep(@as([]const Slot, &.{ .now, .{ .argument = 0 }, .{ .argument = 1 }, .{ .argument = 0 } }), W.mysql.slots);
    const S = Read(.{
        .sql = "SELECT action_id FROM action_operation @index(action_operation_executable) WHERE action_id>?1",
        .Args = struct { after: u64 },
        .Row = struct { action_id: Positive },
        .cardinality = .optional,
    });
    try std.testing.expectEqualStrings("SELECT action_id FROM action_operation  WHERE action_id>?", comptime S.mysql.prepared());
}

test "@served is the opening's function on SQLite and a slot per provider on MySQL" {
    const S = Read(.{
        .sql = "SELECT created_seq FROM session WHERE @served(provider) AND created_seq>?1",
        .Args = struct { after: u64 },
        .Row = struct { created_seq: u64 },
        .cardinality = .optional,
    });
    try std.testing.expectEqualStrings("SELECT created_seq FROM session WHERE rui_served(provider) AND created_seq>?1", S.sql);
    const providers = comptime std.enums.values(provider_name.Provider);
    comptime var list: []const u8 = "";
    comptime var slots: []const Slot = &.{};
    inline for (providers, 0..) |provider, index| {
        list = list ++ (if (index == 0) "?" else ",?");
        slots = slots ++ .{Slot{ .served = provider }};
    }
    try std.testing.expectEqualStrings("SELECT created_seq FROM session WHERE (provider IN (" ++ list ++ ")) AND created_seq>?", comptime S.mysql.prepared());
    try std.testing.expectEqualDeep(slots ++ &[_]Slot{.{ .argument = 0 }}, S.mysql.slots);
}

test "MySQL rendering calls only the functions it knows, by argument count" {
    try std.testing.expectEqualStrings("rsql: MySQL rendering knows no function rui_served of 1 arguments", comptime mysqlRendering("rui_served(provider)=1").refused);
    try std.testing.expectEqualStrings("rsql: MySQL rendering knows no function max of 3 arguments", comptime mysqlRendering("max(a,b,c)>0").refused);
    try std.testing.expectEqualStrings("payload=REPEAT(X'00',byte_length)", comptime render(.mysql, "payload=zeroblob(byte_length)"));
    // Neither a WITH name's column list nor an INSERT's table is a call.
    const text = "WITH recent(turn_id) AS (SELECT count(*) AS n FROM turn) INSERT INTO turn(turn_id) SELECT turn_id FROM recent";
    try std.testing.expectEqualStrings(text, comptime mysqlRendering(text).rendered.parts[0]);
}

test "MySQL rendering refuses CAST and divides integers with DIV" {
    try std.testing.expectEqualStrings("rsql: CAST converts differently on each engine; MySQL rendering refuses it", comptime mysqlRendering("CAST(payload AS TEXT)='x'").refused);
    try std.testing.expectEqualStrings("(mask DIV 2)%2=1", comptime render(.mysql, "(mask/2)%2=1"));
}

test "length() and an UPDATE that reads what its SET already wrote are refused on every dialect" {
    const Id = struct { id: u64 };
    try std.testing.expectEqualStrings(
        "rsql: length() counts characters of text on SQLite and bytes on MySQL; write @octets(x)",
        comptime statementError(.read, "SELECT length(digest) AS n FROM content WHERE content_id=?1", Id, struct { n: u64 }).?,
    );
    const reads = "rsql: SET reads private after assigning it, and MySQL assigns left to right; read it before the write or assign it last";
    try std.testing.expectEqualStrings(reads, comptime statementError(.write, "UPDATE content SET private=1,byte_length=private WHERE content_id=?1", Id, void).?);
    try std.testing.expectEqualStrings(reads, comptime statementError(.write, "UPDATE content SET private=1,byte_length=(SELECT content.private) WHERE content_id=?1", Id, void).?);
    try std.testing.expectEqual(@as(?[]const u8, null), comptime statementError(.write, "UPDATE content SET byte_length=private,private=1 WHERE private=0 AND content_id=?1", Id, void));
}

test "non-portable text names its fix" {
    try std.testing.expectEqualStrings("rsql: 'GLOB' is not portable; write @charset(column,'set') or @initial(column,'set')", comptime portabilityError("x NOT GLOB '*[^a]*'", false).?);
    try std.testing.expectEqualStrings("rsql: 'typeof' is not portable; test IS NULL or IS NOT NULL", comptime portabilityError("typeof(x)='blob'", false).?);
    try std.testing.expectEqualStrings("rsql: 'unixepoch' is not portable; write @now, the Host's second", comptime portabilityError("at<=unixepoch()", false).?);
    try std.testing.expectEqualStrings("rsql: '||' is OR on MySQL; compute the text in Zig", comptime portabilityError("a||b='ab'", false).?);
    try std.testing.expectEqualStrings("rsql: 'IS' compares only with NULL; write @same(a,b) or @distinct(a,b)", comptime portabilityError("code IS 'x'", false).?);
    try std.testing.expectEqualStrings("rsql: 'IS' compares only with NULL; write @same(a,b) or @distinct(a,b)", comptime portabilityError("code IS NOT 1", false).?);
    try std.testing.expectEqualStrings("rsql: 'rowid' is SQLite's hidden key; name an explicit INTEGER key column", comptime portabilityError("rowid>1", true).?);
    try std.testing.expectEqual(@as(?[]const u8, null), comptime portabilityError("rowid>1", false));
    try std.testing.expectEqual(@as(?[]const u8, null), comptime portabilityError("a IS NULL AND b IS NOT NULL AND c='GLOB || IS 1' AND isolated=1", true));
    try std.testing.expectEqual(@as(?[]const u8, null), comptime portabilityError("a-1>0 AND b/2<3 AND c='-- /* \"'", true));
}

test "comments and double quotes cannot hide text from the check" {
    const comment = "rsql: '--' comments hide text from this check; write the note as a Zig comment";
    try std.testing.expectEqualStrings(comment, comptime portabilityError("a>0 -- it's\n AND b GLOB 'x'", false).?);
    try std.testing.expectEqualStrings(comment, comptime portabilityError("a>0 --", false).?);
    try std.testing.expectEqualStrings("rsql: '/*' comments hide text from this check; write the note as a Zig comment", comptime portabilityError("a>0 /* it's */ AND b GLOB 'x'", false).?);
    try std.testing.expectEqualStrings("rsql: '\"' quotes a name on Postgres but a string on MySQL; write names bare and strings in single quotes", comptime portabilityError("\"a'\" GLOB 'x'", false).?);
}

test "reserved names are refused once checked" {
    try std.testing.expectEqualStrings("rsql: 'key' is reserved on some engine; rename it", comptime identifierError("key", true).?);
    try std.testing.expectEqual(@as(?[]const u8, null), comptime identifierError("key", false));
    try std.testing.expectEqual(@as(?[]const u8, null), comptime identifierError("meta_key", true));
}

test "statements are held to reserved names, rowid and comments" {
    try std.testing.expectEqualStrings("rsql: 'call' is reserved on some engine; rename it", comptime portabilityError("SELECT call.x FROM model_tool_call call", reserved_names_checked).?);
    try std.testing.expectEqualStrings("rsql: 'groups' is reserved on some engine; rename it", comptime portabilityError("WITH groups AS (SELECT 1) SELECT * FROM groups", reserved_names_checked).?);
    try std.testing.expectEqualStrings("rsql: 'rowid' is SQLite's hidden key; name an explicit INTEGER key column", comptime portabilityError("SELECT max(rowid) FROM session", reserved_names_checked).?);
    try std.testing.expectEqualStrings("rsql: '--' comments hide text from this check; write the note as a Zig comment", comptime portabilityError("SELECT 1 -- call", reserved_names_checked).?);
}

test "only a type Read or Write made counts as a typed statement" {
    const Real = Read(.{ .sql = "SELECT content_id FROM content WHERE content_id=?1", .Args = struct { content_id: u64 }, .Row = struct { content_id: Positive }, .cardinality = .optional });
    const Written = Write(.{ .sql = "UPDATE turn SET outcome_at=@now WHERE turn_id=?1 AND session_ref=@session(?2)", .Args = struct { turn_id: u64, session: SessionHead }, .expect = .{ .at_most = 1 } });
    try std.testing.expect(comptime isStatement(Real));
    try std.testing.expect(comptime isStatement(Written));
    // Open text in a struct shaped like a statement.
    try std.testing.expect(!comptime isStatement(struct {
        pub const kind: StatementKind = .write;
        pub const sql: [:0]const u8 = "ROLLBACK";
    }));
    // A copy of a real statement's declarations around other text.
    try std.testing.expect(!comptime isStatement(struct {
        pub const kind = Real.kind;
        pub const made_from = Real.made_from;
        pub const Args = Real.Args;
        pub const Row = Real.Row;
        pub const sql: [:0]const u8 = "DELETE FROM session";
    }));
    try std.testing.expect(!comptime isStatement(struct {}));
}

test "a reserved word is a keyword only in its own place, and a name anywhere else" {
    // Its OVER texts scan past portabilityError's own quota of 100 per byte.
    @setEvalBranchQuota(20_000);
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
        try std.testing.expectEqualStrings("rsql: '" ++ case.word ++ "' is reserved on some engine; rename it", comptime portabilityError(case.sql, reserved_names_checked).?);
    }
    inline for ([_][]const u8{
        "SELECT x FROM turn ORDER BY x LIMIT ?1 OFFSET ?2",
        "SELECT x FROM turn order\nby x limit 9",
        "WITH RECURSIVE n(i) AS (SELECT 1) SELECT i FROM n",
        "SELECT lead(x) OVER (PARTITION BY y ORDER BY z), lag(x,1) OVER (ORDER BY z), rank() OVER (ORDER BY z) FROM turn",
        "SELECT sum(x) OVER (ORDER BY z ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING) FROM turn",
        "SELECT sum(x) OVER (ORDER BY z RANGE BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) FROM turn",
    }) |sql| {
        try std.testing.expectEqual(@as(?[]const u8, null), comptime portabilityError(sql, reserved_names_checked));
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
    try std.testing.expectEqualStrings("session", W.session_fields[0]);
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
    const copied = copied_message;
    try std.testing.expectEqualStrings(copied, comptime statementError(.write, "INSERT INTO session_stop(command_key,session_ref,selected_turn_id,admission_cutoff,stopped_at) SELECT ?1,@session(?2),?3,0,@now", Stop, void).?);

    // A copy of one Session's row: its key pins the row the WHERE names.
    const Copy = struct { session: SessionHead, key: []const u8 };
    try std.testing.expectEqual(@as(?[]const u8, null), comptime statementError(.write, "INSERT INTO session_revision(session_ref,revision,command_key) SELECT session_ref,revision,?2 FROM session WHERE session_ref=@session(?1)", Copy, void));
    try std.testing.expectEqualStrings(copied, comptime statementError(.write, "INSERT INTO session_revision(session_ref,revision,command_key) SELECT ?2,revision,?2 FROM session WHERE session_ref=@session(?1)", Copy, void).?);
    // The source's alias qualifies its columns.
    try std.testing.expectEqual(@as(?[]const u8, null), comptime statementError(.write, "INSERT INTO session_revision(session_ref,revision,command_key) SELECT s.session_ref,revision,?2 FROM session s WHERE session_ref=@session(?1)", Copy, void));
    try std.testing.expectEqualStrings(copied, comptime statementError(.write, "INSERT INTO session_revision(session_ref,revision,command_key) SELECT session_ref,revision,?2 FROM session JOIN turn ON turn.session_ref=session.session_ref WHERE session_ref=@session(?1)", Copy, void).?);
    try std.testing.expectEqualStrings(comptime untiedMessage("session", "session"), comptime statementError(.write, "INSERT INTO session_revision(session_ref,revision,command_key) SELECT session_ref,revision,?2 FROM session WHERE session_ref=@session(?1) OR revision=1", Copy, void).?);
    try std.testing.expectEqualStrings("rsql: an INSERT gives one value per column", comptime statementError(.write, "INSERT INTO session_revision(session_ref,revision,command_key) SELECT session_ref,revision FROM session WHERE session_ref=@session(?1) AND ?2 IS NOT NULL", Copy, void).?);
    try std.testing.expectEqualStrings("rsql: an INSERT writes one VALUES row", comptime statementError(.write, "INSERT INTO session_stop(command_key,session_ref,selected_turn_id,admission_cutoff,stopped_at) VALUES(?1,@session(?2),?3,0,@now),(?1,'other',?3,0,@now)", Stop, void).?);
}

test "a Message's write names its two Sessions, each on its own column" {
    const Sent = struct { id: u64, session: SessionHead, key: []const u8, content_id: u64, position: u64, sender: SessionHead, sender_position: u64 };
    const Person = struct { id: u64, session: SessionHead, key: []const u8, content_id: u64, position: u64 };
    const columns = "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,admission_position,admitted_at,sender_session_ref,sender_position) ";
    try std.testing.expectEqual(@as(?[]const u8, null), comptime statementError(.write, columns ++ "VALUES(?1,@session(?2),?3,?4,?5,@now,@session(?6),?7)", Sent, void));
    try std.testing.expectEqual(@as(?[]const u8, null), comptime statementError(.write, columns ++ "VALUES(?1,@session(?2),?3,?4,?5,@now,NULL,NULL)", Person, void));
    try std.testing.expectEqual(@as(?[]const u8, null), comptime statementError(.write, "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,admission_position,admitted_at) VALUES(?1,@session(?2),?3,?4,?5,@now)", Person, void));
    try std.testing.expectEqual(2, Write(.{ .sql = columns ++ "VALUES(?1,@session(?2),?3,?4,?5,@now,@session(?6),?7)", .Args = Sent, .expect = .{ .at_most = 1 } }).session_fields.len);

    // Wrong ties: a sender bound but written as text, a head moved to
    // another column or wrapped, one head for both, the target left NULL.
    const sender = "rsql: an INSERT names its Session as the sender_session_ref value of its VALUES row";
    try std.testing.expectEqualStrings("rsql: every SessionHead of Args is bound by its own @session(?k)", comptime statementError(.write, columns ++ "VALUES(?1,@session(?2),?3,?4,?5,@now,?6,?7)", Sent, void).?);
    try std.testing.expectEqualStrings(sender, comptime statementError(.write, columns ++ "VALUES(?1,@session(?2),?3,?4,?5,@now,?7,@session(?6))", Sent, void).?);
    try std.testing.expectEqualStrings(sender, comptime statementError(.write, columns ++ "VALUES(?1,@session(?2),?3,?4,?5,@now,coalesce(@session(?6),NULL),?7)", Sent, void).?);
    try std.testing.expectEqualStrings("rsql: an INSERT names its Session as the session_ref value of its VALUES row", comptime statementError(.write, columns ++ "VALUES(?1,NULL,?3,?4,?5,@now,@session(?2),NULL)", Person, void).?);
    try std.testing.expectEqualStrings("rsql: an INSERT names each of its Sessions with its own SessionHead", comptime statementError(.write, columns ++ "VALUES(?1,@session(?2),?3,?4,?5,@now,@session(?2),?5)", Person, void).?);
    try std.testing.expectEqualStrings("rsql: an INSERT gives each SessionHead as a Session column's value", comptime statementError(.write, columns ++ "VALUES(?1,@session(?2),?3,@session(?4),?5,@now,NULL,NULL)", struct { id: u64, session: SessionHead, key: []const u8, sender: SessionHead, position: u64 }, void).?);
    try std.testing.expectEqualStrings("rsql: a write to message_admission names each of its Sessions at most once, and one at least, as @session(?k)", comptime statementError(.write, columns ++ "VALUES(?1,?2,?3,?4,?5,@now,NULL,NULL)", struct { id: u64, session: []const u8, key: []const u8, content_id: u64, position: u64 }, void).?);
    try std.testing.expectEqualStrings("rsql: an INSERT ... SELECT copies one Session's row; message_admission names its Sessions otherwise", comptime statementError(.write, "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,admitted_at) SELECT ?1,session_ref,?3,?4,@now FROM session WHERE session_ref=@session(?2)", struct { id: u64, session: SessionHead, key: []const u8, content_id: u64 }, void).?);

    // An update names the admission's own Session, and never moves either.
    const Update = struct { turn_id: u64, session: SessionHead };
    const tie = "rsql: an UPDATE or DELETE names its Session as the conjunct session_ref=@session(?k) of its WHERE";
    try std.testing.expectEqual(@as(?[]const u8, null), comptime statementError(.write, "UPDATE message_admission SET turn_id=?1 WHERE session_ref=@session(?2) AND turn_id IS NULL", Update, void));
    try std.testing.expectEqualStrings(tie, comptime statementError(.write, "UPDATE message_admission SET turn_id=?1 WHERE sender_session_ref=@session(?2)", Update, void).?);
    try std.testing.expectEqualStrings(tie, comptime statementError(.write, "UPDATE message_admission SET sender_session_ref=NULL,turn_id=?1 WHERE session_ref=@session(?2)", Update, void).?);
    // A row-value SET is outside the grammar.
    try std.testing.expectEqualStrings("rsql: expected a name at '('", comptime statementError(.write, "UPDATE message_admission SET (sender_session_ref,turn_id)=(NULL,?1) WHERE session_ref=@session(?2)", Update, void).?);
    // A further conjunct on the sender's column only narrows the rows the tie holds of.
    try std.testing.expectEqual(@as(?[]const u8, null), comptime statementError(.write, "UPDATE message_admission SET turn_id=?1 WHERE session_ref=@session(?2) AND sender_session_ref IS NULL", Update, void));
    try std.testing.expectEqualStrings("rsql: a DELETE from message_admission would drop two Sessions' facts; no writer deletes them", comptime statementError(.write, "DELETE FROM message_admission WHERE session_ref=@session(?2) AND turn_id=?1", Update, void).?);
    // A column the sender reads: the review's input changes the sender's
    // page without touching the sender.
    const sender_reads = "rsql: message_admission.admitted_at is read by its sender too; an UPDATE of it has the conjunct sender_session_ref=@session(?j) or sender_session_ref IS NULL";
    try std.testing.expectEqualStrings(sender_reads, comptime statementError(.write, "UPDATE message_admission SET admitted_at=@now WHERE session_ref=@session(?1)", struct { session: SessionHead }, void).?);
    try std.testing.expectEqualStrings(sender_reads, comptime statementError(.write, "UPDATE message_admission SET admitted_at=@now WHERE session_ref=@session(?1) AND sender_session_ref IS NOT NULL", struct { session: SessionHead }, void).?);
    try std.testing.expectEqualStrings(sender_reads, comptime statementError(.write, "UPDATE message_admission SET admitted_at=@now WHERE session_ref=@session(?1) AND (sender_session_ref IS NULL OR turn_id=1)", struct { session: SessionHead }, void).?);
    const Both = struct { session: SessionHead, sender: SessionHead };
    try std.testing.expectEqual(@as(?[]const u8, null), comptime statementError(.write, "UPDATE message_admission SET admitted_at=@now WHERE session_ref=@session(?1) AND sender_session_ref=@session(?2)", Both, void));
    try std.testing.expectEqual(2, Write(.{ .sql = "UPDATE message_admission SET admitted_at=@now WHERE session_ref=@session(?1) AND sender_session_ref=@session(?2)", .Args = Both, .expect = .{ .at_most = 1 } }).session_fields.len);
    try std.testing.expectEqual(@as(?[]const u8, null), comptime statementError(.write, "UPDATE message_admission SET admitted_at=@now WHERE session_ref=@session(?1) AND sender_session_ref IS NULL", struct { session: SessionHead }, void));
    try std.testing.expectEqualStrings("rsql: an UPDATE of message_admission names its second Session as the conjunct sender_session_ref=@session(?j) of its WHERE", comptime statementError(.write, "UPDATE message_admission SET turn_id=?1 WHERE session_ref=@session(?2) AND turn_id IN (SELECT turn_id FROM turn WHERE session_ref=@session(?3))", struct { turn_id: u64, session: SessionHead, sender: SessionHead }, void).?);
    try std.testing.expectEqualStrings("rsql: an UPDATE or DELETE names its Session as the conjunct session_ref=@session(?k) of its WHERE", comptime statementError(.write, "UPDATE turn SET session_ref=(SELECT session_ref FROM session) WHERE turn_id=?1 AND session_ref=@session(?2)", Update, void).?);

    // A rejected send names only its sender, on its one Session column.
    const Rejected = struct { key: []const u8, sender: SessionHead, position: u64 };
    try std.testing.expectEqual(@as(?[]const u8, null), comptime statementError(.write, "INSERT INTO sent_rejection(command_key,sender_session_ref,sender_position,rejected_at) VALUES(?1,@session(?2),?3,@now)", Rejected, void));
    try std.testing.expectEqualStrings("rsql: an INSERT names its Session as the sender_session_ref value of its VALUES row", comptime statementError(.write, "INSERT INTO sent_rejection(command_key,sender_session_ref,sender_position,rejected_at) VALUES(?1,NULL,?3,@session(?2))", Rejected, void).?);
    try std.testing.expectEqualStrings("rsql: an INSERT names its Session as the sender_session_ref value of its VALUES row", comptime statementError(.write, "INSERT INTO sent_rejection(command_key,sender_session_ref,sender_position,rejected_at) VALUES(?1,?3,@session(?2),@now)", Rejected, void).?);
}

test "a write to a table that carries no Sessions names no Session" {
    try std.testing.expectEqualStrings("rsql: content carries no Sessions; bind no SessionHead", comptime statementError(.write, "DELETE FROM content WHERE content_id=?1 AND ?2 IS NOT NULL", struct { id: u64, session: SessionHead }, void).?);
    try std.testing.expectEqualStrings("rsql: a write to sent_rejection names its Session exactly once, as @session(?k)", comptime statementError(.write, "DELETE FROM sent_rejection WHERE sender_session_ref=?1", struct { ref: []const u8 }, void).?);
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

test "a copy's @session(?k) pins a key column as a parameter does" {
    // session_ref is session's key, so this copy is one row; before 5c-2 a
    // marker pinned nothing and the same text counted as many.
    const copy = "INSERT INTO session_revision(session_ref,revision,command_key) SELECT session_ref,revision,?2 FROM session WHERE session_ref=@session(?1)";
    try std.testing.expect(comptime returnsOneRow(parse(copy).accepted.statement.insert.values.select));
    // turn's key is turn_id; its unique index on session_ref is partial, so pins nothing.
    const turns = "INSERT INTO session_revision(session_ref,revision,command_key) SELECT session_ref,turn_id,?2 FROM turn WHERE session_ref=@session(?1)";
    try std.testing.expect(!comptime returnsOneRow(parse(turns).accepted.statement.insert.values.select));
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
    const Copy = struct { session: SessionHead, key: []const u8 };
    try std.testing.expectEqualStrings(comptime untiedMessage("session", "session"), comptime statementError(.write, "INSERT INTO session_revision(session_ref,revision,command_key) SELECT session_ref,revision,?2 FROM session WHERE CASE WHEN revision=0 AND session_ref=@session(?1) AND revision=0 THEN 0 ELSE 1 END", Copy, void).?);
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
    try std.testing.expectEqualStrings("rsql: @count_where takes 1 arguments", comptime statementError(.read, "SELECT @count_where(turn_id,1) AS n FROM turn", struct {}, struct { n: u64 }).?);
    try std.testing.expectEqualStrings("rsql: @max_where takes 2 arguments", comptime statementError(.read, "SELECT @max_where(turn_id) AS n FROM turn", struct {}, struct { n: u64 }).?);
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

test "row_number() OVER (ORDER BY ...) is the one window" {
    const Turn = struct { session: []const u8 };
    const Numbered = struct { turn_id: u64, n: u64 };
    try std.testing.expectEqual(@as(?[]const u8, null), comptime statementError(.read, "SELECT turn_id,row_number() OVER (ORDER BY turn_id DESC,operation_id) AS n FROM turn WHERE session_ref=?1", Turn, Numbered));
    const window = "rsql: the one window is row_number() OVER (ORDER BY ...), with no PARTITION BY or frame";
    try std.testing.expectEqualStrings(window, comptime statementError(.read, "SELECT turn_id,row_number() OVER (PARTITION BY session_ref ORDER BY turn_id) AS n FROM turn WHERE session_ref=?1", Turn, Numbered).?);
    try std.testing.expectEqualStrings(window, comptime statementError(.read, "SELECT turn_id,row_number() OVER (ORDER BY turn_id ROWS UNBOUNDED PRECEDING) AS n FROM turn WHERE session_ref=?1", Turn, Numbered).?);
    try std.testing.expectEqualStrings(window, comptime statementError(.read, "SELECT turn_id,rank() OVER (ORDER BY turn_id) AS n FROM turn WHERE session_ref=?1", Turn, Numbered).?);
    try std.testing.expectEqualStrings(window, comptime statementError(.read, "SELECT turn_id,row_number(turn_id) OVER (ORDER BY turn_id) AS n FROM turn WHERE session_ref=?1", Turn, Numbered).?);
    try std.testing.expectEqualStrings(window, comptime statementError(.read, "SELECT turn_id,row_number() OVER () AS n FROM turn WHERE session_ref=?1", Turn, Numbered).?);
}

/// The Messages projection's text, as admission writes it, with `select`
/// in place of its SELECT's session_ref value and `source` after its other
/// values.
fn messagesCopy(comptime select: []const u8, comptime source: []const u8) []const u8 {
    return comptime entry_columns ++ messagesSelect(select, source);
}

const entry_columns = "INSERT INTO conversation_entry(session_ref,entry_ordinal,session_position,entry_kind,turn_id,source_admission_id,source_revision,source_operation_id,content_id,recorded_at) ";

fn messagesSelect(comptime select: []const u8, comptime source: []const u8) []const u8 {
    return comptime "SELECT " ++ select ++ ",?3+row_number() OVER (ORDER BY admission_id),?4+row_number() OVER (ORDER BY admission_id)-1,1,?2,admission_id,NULL,NULL,content_id,@now " ++ source;
}

const MessagesCopy = struct { session: SessionHead, turn_id: u64, ordinal_base: u64, position_base: u64, first_admission: u64 };
const counted_copy: Expect = .{ .counted = .{ .otherwise = error.ProjectionFailed } };

const tied_messages = "FROM message_admission WHERE session_ref=@session(?1) AND turn_id=?2 AND admission_id>=?5";
const SessionCopy = struct { session: SessionHead, key: []const u8 };
const one_copy: Expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } };

/// The Messages projection with `content` as its content_id value.
fn messagesWithContent(comptime content: []const u8, comptime source: []const u8) []const u8 {
    return comptime entry_columns ++ "SELECT session_ref,?3+row_number() OVER (ORDER BY admission_id),?4+row_number() OVER (ORDER BY admission_id)-1,1,?2,admission_id,NULL,NULL," ++
        content ++ ",@now " ++ source;
}

/// A refused write and a legal one that differs from it only in the
/// property `rule` checks, with the message it is refused with.
const SessionCase = struct { name: []const u8, rule: []const u8, legal: []const u8, refused: []const u8, Args: type, expect: Expect, message: []const u8 };

/// Every refusal of the copy slot and the walk. The probe in PR 5c-2's
/// body runs each `refused` through rsql with its `rule` switched off.
const session_cases = [_]SessionCase{
    // The copy's session_ref slot (`copyError`).
    .{ .name = "1 a parameter in the slot", .rule = "slot", .legal = messagesCopy("session_ref", tied_messages), .refused = messagesCopy("?2", tied_messages), .Args = MessagesCopy, .expect = counted_copy, .message = copied_message },
    .{ .name = "2 the marker in the slot", .rule = "slot", .legal = messagesCopy("session_ref", tied_messages), .refused = messagesCopy("@session(?1)", tied_messages), .Args = MessagesCopy, .expect = counted_copy, .message = copied_message },
    .{ .name = "4 the sender's column in the slot", .rule = "slot", .legal = messagesCopy("session_ref", tied_messages), .refused = messagesCopy("sender_session_ref", tied_messages), .Args = MessagesCopy, .expect = counted_copy, .message = copied_message },
    .{
        .name = "11 a WITH name's column in the slot",
        .rule = "slot",
        .legal = entry_columns ++ "WITH m AS (SELECT session_ref,turn_id,admission_id,content_id FROM message_admission WHERE session_ref=@session(?1)) " ++
            messagesSelect("w.session_ref", "FROM m JOIN message_admission w ON w.admission_id=m.admission_id WHERE w.session_ref=@session(?1) AND m.turn_id=?2 AND m.admission_id>=?5"),
        .refused = entry_columns ++ "WITH m AS (SELECT session_ref,turn_id,admission_id,content_id FROM message_admission WHERE session_ref=@session(?1)) " ++
            messagesSelect("m.session_ref", "FROM m JOIN message_admission w ON w.admission_id=m.admission_id WHERE w.session_ref=@session(?1) AND m.turn_id=?2 AND m.admission_id>=?5"),
        .Args = MessagesCopy,
        .expect = counted_copy,
        .message = copied_message,
    },
    .{
        .name = "12 a column of a table without Sessions in the slot",
        .rule = "slot",
        .legal = messagesSelectJoin("m.session_ref", "model_interruption_command i ON i.session_ref=m.session_ref"),
        .refused = messagesSelectJoin("i.session_ref", "model_interruption_command i ON i.session_ref=m.session_ref"),
        .Args = MessagesCopy,
        .expect = counted_copy,
        .message = copied_message,
    },
    .{ .name = "14a a qualifier that names no source", .rule = "slot", .legal = messagesSelectJoin("m.session_ref", "turn t ON t.session_ref=m.session_ref"), .refused = messagesSelectJoin("x.session_ref", "turn t ON t.session_ref=m.session_ref"), .Args = MessagesCopy, .expect = counted_copy, .message = copied_message },
    .{ .name = "14b a bare column among two sources", .rule = "slot", .legal = messagesSelectJoin("m.session_ref", "turn t ON t.session_ref=m.session_ref"), .refused = messagesSelectJoin("session_ref", "turn t ON t.session_ref=m.session_ref"), .Args = MessagesCopy, .expect = counted_copy, .message = copied_message },
    .{ .name = "15a an expression of the column", .rule = "slot", .legal = messagesCopy("session_ref", tied_messages), .refused = messagesCopy("coalesce(session_ref,'x')", tied_messages), .Args = MessagesCopy, .expect = counted_copy, .message = copied_message },
    .{ .name = "15b an aggregate of the column", .rule = "slot", .legal = messagesCopy("session_ref", tied_messages), .refused = messagesCopy("max(session_ref)", tied_messages), .Args = MessagesCopy, .expect = counted_copy, .message = copied_message },
    // Every table the write reads is tied (`tiedRefs`).
    .{
        .name = "3 the tie on the sender's column",
        .rule = "walk",
        .legal = messagesCopy("session_ref", tied_messages),
        .refused = messagesCopy("session_ref", "FROM message_admission WHERE sender_session_ref=@session(?1) AND turn_id=?2 AND admission_id>=?5"),
        .Args = MessagesCopy,
        .expect = counted_copy,
        .message = untiedMessage("message_admission", "message_admission"),
    },
    .{ .name = "5a a joined table not tied", .rule = "walk", .legal = messagesSelectJoin("m.session_ref", "turn t ON t.session_ref=m.session_ref AND t.turn_id=m.turn_id"), .refused = messagesSelectJoin("m.session_ref", "turn t ON t.turn_id=m.turn_id"), .Args = MessagesCopy, .expect = counted_copy, .message = untiedMessage("turn", "t") },
    .{
        .name = "5b the copied table tied only through a join on another column",
        .rule = "walk",
        .legal = messagesCopy("m.session_ref", "FROM message_admission m JOIN turn t ON t.session_ref=m.session_ref WHERE t.session_ref=@session(?1) AND m.turn_id=?2 AND m.admission_id>=?5"),
        .refused = messagesCopy("m.session_ref", "FROM message_admission m JOIN turn t ON t.turn_id=m.turn_id WHERE t.session_ref=@session(?1) AND m.turn_id=?2 AND m.admission_id>=?5"),
        .Args = MessagesCopy,
        .expect = counted_copy,
        .message = untiedMessage("message_admission", "m"),
    },
    .{
        .name = "6 a tie in a LEFT JOIN's ON, which keeps every row on its left",
        .rule = "outer",
        .legal = messagesCopy("m.session_ref", "FROM message_admission m LEFT JOIN turn t ON t.session_ref=m.session_ref WHERE m.session_ref=@session(?1) AND m.turn_id=?2 AND m.admission_id>=?5"),
        .refused = messagesCopy("m.session_ref", "FROM message_admission m LEFT JOIN turn t ON t.session_ref=m.session_ref AND m.session_ref=@session(?1) WHERE m.turn_id=?2 AND m.admission_id>=?5"),
        .Args = MessagesCopy,
        .expect = counted_copy,
        .message = untiedMessage("message_admission", "m"),
    },
    .{
        .name = "7 the tie inside OR",
        .rule = "walk",
        .legal = messagesCopy("session_ref", tied_messages),
        .refused = messagesCopy("session_ref", "FROM message_admission WHERE session_ref=@session(?1) OR turn_id=?2 AND admission_id>=?5"),
        .Args = MessagesCopy,
        .expect = counted_copy,
        .message = untiedMessage("message_admission", "message_admission"),
    },
    .{
        .name = "8 the tie only inside a subquery",
        .rule = "walk",
        .legal = messagesCopy("session_ref", "FROM message_admission WHERE admission_id IN (SELECT admission_id FROM message_admission WHERE session_ref=@session(?1)) AND session_ref=@session(?1) AND turn_id=?2 AND admission_id>=?5"),
        .refused = messagesCopy("session_ref", "FROM message_admission WHERE admission_id IN (SELECT admission_id FROM message_admission WHERE session_ref=@session(?1)) AND turn_id=?2 AND admission_id>=?5"),
        .Args = MessagesCopy,
        .expect = counted_copy,
        .message = untiedMessage("message_admission", "message_admission"),
    },
    .{
        .name = "9 the tie under NOT",
        .rule = "walk",
        .legal = messagesCopy("session_ref", tied_messages),
        .refused = messagesCopy("session_ref", "FROM message_admission WHERE NOT (session_ref<>@session(?1)) AND turn_id=?2 AND admission_id>=?5"),
        .Args = MessagesCopy,
        .expect = counted_copy,
        .message = untiedMessage("message_admission", "message_admission"),
    },
    .{
        .name = "A a subquery that reads another Session's revisions",
        .rule = "walk",
        .legal = "INSERT INTO session_revision(session_ref,revision,command_key) SELECT session_ref,(SELECT max(r.revision) FROM session_revision r WHERE r.session_ref=session.session_ref),?2 FROM session WHERE session_ref=@session(?1) AND ?3 IS NOT NULL",
        .refused = "INSERT INTO session_revision(session_ref,revision,command_key) SELECT session_ref,(SELECT max(r.revision) FROM session_revision r WHERE r.session_ref=?3),?2 FROM session WHERE session_ref=@session(?1) AND ?3 IS NOT NULL",
        .Args = struct { session: SessionHead, key: []const u8, other: []const u8 },
        .expect = one_copy,
        .message = untiedMessage("session_revision", "r"),
    },
    .{
        .name = "B a subquery that reads another Session's Messages",
        .rule = "walk",
        .legal = messagesWithContent("(SELECT o.content_id FROM message_admission o WHERE o.session_ref=message_admission.session_ref AND ?6 IS NOT NULL LIMIT 1)", tied_messages),
        .refused = messagesWithContent("(SELECT o.content_id FROM message_admission o WHERE o.session_ref=?6 LIMIT 1)", tied_messages),
        .Args = struct { session: SessionHead, turn_id: u64, ordinal_base: u64, position_base: u64, first_admission: u64, other: []const u8 },
        .expect = counted_copy,
        .message = untiedMessage("message_admission", "o"),
    },
    .{
        .name = "C a subquery tied to the sender's column",
        .rule = "walk",
        .legal = messagesWithContent("(SELECT o.content_id FROM message_admission o WHERE o.session_ref=message_admission.session_ref LIMIT 1)", tied_messages),
        .refused = messagesWithContent("(SELECT o.content_id FROM message_admission o WHERE o.session_ref=message_admission.sender_session_ref LIMIT 1)", tied_messages),
        .Args = MessagesCopy,
        .expect = counted_copy,
        .message = untiedMessage("message_admission", "o"),
    },
    .{
        .name = "D an UPDATE's subquery not tied to the row it writes",
        .rule = "walk",
        .legal = "UPDATE message_admission SET turn_id=?1 WHERE session_ref=@session(?2) AND turn_id IS NULL AND NOT EXISTS(SELECT 1 FROM session_stop stopped " ++
            "WHERE stopped.session_ref=message_admission.session_ref AND message_admission.admission_id<=stopped.admission_cutoff)",
        .refused = "UPDATE message_admission SET turn_id=?1 WHERE session_ref=@session(?2) AND turn_id IS NULL AND NOT EXISTS(SELECT 1 FROM session_stop stopped " ++
            "WHERE stopped.command_key=message_admission.command_key AND message_admission.admission_id<=stopped.admission_cutoff)",
        .Args = struct { turn_id: u64, session: SessionHead },
        .expect = .{ .counted = .{ .otherwise = error.SelectionChanged } },
        .message = untiedMessage("session_stop", "stopped"),
    },
    .{
        .name = "E an INSERT's VALUES subquery not tied",
        .rule = "walk",
        .legal = "INSERT INTO session_stop(command_key,session_ref,selected_turn_id,admission_cutoff,stopped_at) VALUES(?1,@session(?2),(SELECT max(turn_id) FROM turn WHERE session_ref=@session(?2) AND operation_id=?3),0,@now)",
        .refused = "INSERT INTO session_stop(command_key,session_ref,selected_turn_id,admission_cutoff,stopped_at) VALUES(?1,@session(?2),(SELECT max(turn_id) FROM turn WHERE operation_id=?3),0,@now)",
        .Args = struct { key: []const u8, session: SessionHead, operation_id: u64 },
        .expect = one_copy,
        .message = untiedMessage("turn", "turn"),
    },
};

/// The Messages projection reading message_admission m joined with `join`.
fn messagesSelectJoin(comptime select: []const u8, comptime join: []const u8) []const u8 {
    return comptime messagesCopy(select, "FROM message_admission m JOIN " ++ join ++ " WHERE m.session_ref=@session(?1) AND m.turn_id=?2 AND m.admission_id>=?5");
}

test "a copy takes session_ref from a table its SELECT reads, and every table a write reads is tied to its Session" {
    // Admission's two projections, and the one-row copy.
    try std.testing.expectEqual(@as(?[]const u8, null), comptime writeError(messagesCopy("session_ref", tied_messages ++ " ORDER BY admission_id"), MessagesCopy, counted_copy));
    try std.testing.expectEqual(@as(?[]const u8, null), comptime writeError(
        entry_columns ++ "SELECT session_ref,?3+row_number() OVER (ORDER BY revision),?4+row_number() OVER (ORDER BY revision)-1,2,?2,NULL,revision,NULL,instructions_content_id,@now " ++
            "FROM session_revision WHERE session_ref=@session(?1) AND revision>?5 AND revision<=?6 AND instructions_updated=1 ORDER BY revision",
        struct { session: SessionHead, turn_id: u64, ordinal_base: u64, position_base: u64, frontier: u64, revision: u64 },
        .{ .counted = .{ .otherwise = error.InstructionSelectionFailed } },
    ));
    try std.testing.expectEqual(@as(?[]const u8, null), comptime writeError("INSERT INTO session_revision(session_ref,revision,command_key) SELECT s.session_ref,revision,?2 FROM session s WHERE s.session_ref=@session(?1)", SessionCopy, one_copy));
    inline for (session_cases) |case| {
        if (comptime writeError(case.legal, case.Args, case.expect)) |message| {
            std.debug.print("{s}: the legal twin is refused: {s}\n", .{ case.name, message });
            return error.TestUnexpectedResult;
        }
        try std.testing.expectEqualStrings(case.message, comptime writeError(case.refused, case.Args, case.expect) orelse "accepted");
    }
}

test "a copy's other refusals come from the rule that owns each" {
    const tied = "FROM message_admission WHERE session_ref=@session(?1) AND turn_id=?2 AND admission_id>=?5";
    // 10. A compound source, 5a's failing input.
    try std.testing.expectEqualStrings("rsql: a write holds no compound SELECT", comptime writeError(messagesCopy("session_ref", tied ++ " UNION ALL SELECT 'zzzzzz',1,1,1,?2,1,NULL,NULL,1,1"), MessagesCopy, counted_copy).?);
    // 13. A target with two Session columns.
    try std.testing.expectEqualStrings("rsql: an INSERT ... SELECT copies one Session's row; message_admission names its Sessions otherwise", comptime writeError(
        "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,admitted_at) SELECT ?1,session_ref,?3,?4,@now FROM message_admission WHERE session_ref=@session(?2)",
        struct { id: u64, session: SessionHead, key: []const u8, content_id: u64 },
        counted_copy,
    ).?);
    // 16. The head's reference reused where main read the ordinal base.
    try std.testing.expectEqualStrings("rsql: the SessionHead ?k binds is used only in @session(?k)", comptime writeError(
        entry_columns ++ "SELECT session_ref,coalesce((SELECT max(entry_ordinal) FROM conversation_entry WHERE session_ref=?1),0)+row_number() OVER (ORDER BY admission_id)," ++
            "?3+row_number() OVER (ORDER BY admission_id)-1,1,?2,admission_id,NULL,NULL,content_id,@now FROM message_admission WHERE session_ref=@session(?1) AND turn_id=?2 AND admission_id>=?4",
        struct { session: SessionHead, turn_id: u64, position_base: u64, first_admission: u64 },
        counted_copy,
    ).?);
    // 17. Another window: PARTITION BY, a frame, another function.
    const window = "rsql: the one window is row_number() OVER (ORDER BY ...), with no PARTITION BY or frame";
    inline for (comptime .{
        "row_number() OVER (PARTITION BY turn_id ORDER BY admission_id)",
        "row_number() OVER (ORDER BY admission_id ROWS UNBOUNDED PRECEDING)",
        "rank() OVER (ORDER BY admission_id)",
    }) |numbered| try std.testing.expectEqualStrings(window, comptime writeError(
        entry_columns ++ "SELECT session_ref,?3+" ++ numbered ++ ",?4,1,?2,admission_id,NULL,NULL,content_id,@now " ++ tied,
        MessagesCopy,
        counted_copy,
    ).?);
    // 18. A copy's Expect follows its row count.
    try std.testing.expectEqualStrings("rsql: an INSERT ... SELECT of more than one row declares .counted, so its caller states the count", comptime writeError(messagesCopy("session_ref", tied), MessagesCopy, .{ .exact = .{ .rows = 1, .otherwise = error.ProjectionFailed } }).?);
    try std.testing.expectEqualStrings("rsql: an INSERT ... SELECT of at most one row declares .exact or .at_most 1", comptime writeError(
        "INSERT INTO session_revision(session_ref,revision,command_key) SELECT session_ref,revision,?2 FROM session WHERE session_ref=@session(?1)",
        struct { session: SessionHead, key: []const u8 },
        counted_copy,
    ).?);
    // An INSERT ... VALUES writes one row.
    const Stop = struct { key: []const u8, session: SessionHead, turn_id: u64 };
    const stop = "INSERT INTO session_stop(command_key,session_ref,selected_turn_id,admission_cutoff,stopped_at) VALUES(?1,@session(?2),?3,0,@now)";
    try std.testing.expectEqual(@as(?[]const u8, null), comptime writeError(stop, Stop, one_copy));
    try std.testing.expectEqual(@as(?[]const u8, null), comptime writeError(stop, Stop, .{ .at_most = 1 }));
    try std.testing.expectEqualStrings(values_message, comptime writeError(stop, Stop, .{ .counted = .{ .otherwise = error.CorruptStore } }).?);
    try std.testing.expectEqualStrings(values_message, comptime writeError(stop, Stop, .{ .exact = .{ .rows = 2, .otherwise = error.CorruptStore } }).?);
    // 19. A counted bind that also assigns what the sender reads, with no sender tie.
    const Bind = struct { turn_id: u64, session: SessionHead };
    const counted_bind: Expect = .{ .counted = .{ .otherwise = error.SelectionChanged } };
    try std.testing.expectEqual(@as(?[]const u8, null), comptime writeError("UPDATE message_admission SET turn_id=?1 WHERE session_ref=@session(?2) AND turn_id IS NULL", Bind, counted_bind));
    try std.testing.expectEqualStrings(
        "rsql: message_admission.admitted_at is read by its sender too; an UPDATE of it has the conjunct sender_session_ref=@session(?j) or sender_session_ref IS NULL",
        comptime writeError("UPDATE message_admission SET turn_id=?1,admitted_at=@now WHERE session_ref=@session(?2) AND turn_id IS NULL", Bind, counted_bind).?,
    );
}
