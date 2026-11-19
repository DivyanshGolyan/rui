const std = @import("std");
const change_ring = @import("../change_ring.zig");
const schema = @import("schema.zig");
const provider_name = @import("../provider_name.zig");

pub const Dialect = enum { sqlite, mysql };

pub const reserved_names_checked = true;

const reserved_names = blk: {
    @setEvalBranchQuota(100_000);
    var words: []const []const u8 = &other_reserved;
    for (mysql_reserved) |word| {
        if (!isGrammarWord(word) or hasPlace(word)) words = words ++ .{word};
    }
    break :blk words;
};

const reserved_lookup = blk: {
    @setEvalBranchQuota(100_000);
    var pairs: [reserved_names.len]struct { []const u8 } = undefined;
    for (reserved_names, &pairs) |word, *pair| pair.* = .{word};
    break :blk std.StaticStringMapWithEql(void, std.static_string_map.eqlAsciiIgnoreCase).initComptime(pairs);
};

const other_reserved = [_][]const u8{ "user", "offset" };

const mysql_reserved = [_][]const u8{
    "accessible",     "add",                 "all",                "alter",              "analyze",       "and",           "as",             "asc",
    "asensitive",     "before",              "between",            "bigint",             "binary",        "blob",          "both",           "by",
    "call",           "cascade",             "case",               "change",             "char",          "character",     "check",          "collate",
    "column",         "condition",           "constraint",         "continue",           "convert",       "create",        "cross",          "cube",
    "cume_dist",      "current_date",        "current_time",       "current_timestamp",  "current_user",  "cursor",        "database",       "databases",
    "day_hour",       "day_microsecond",     "day_minute",         "day_second",         "dec",           "decimal",       "declare",        "default",
    "delayed",        "delete",              "dense_rank",         "desc",               "describe",      "deterministic", "distinct",       "distinctrow",
    "div",            "double",              "drop",               "dual",               "each",          "else",          "elseif",         "empty",
    "enclosed",       "escaped",             "except",             "exists",             "exit",          "explain",       "false",          "fetch",
    "first_value",    "float",               "float4",             "float8",             "for",           "force",         "foreign",        "from",
    "fulltext",       "function",            "generated",          "get",                "grant",         "group",         "grouping",       "groups",
    "having",         "high_priority",       "hour_microsecond",   "hour_minute",        "hour_second",   "if",            "ignore",         "in",
    "index",          "infile",              "inner",              "inout",              "insensitive",   "insert",        "int",            "int1",
    "int2",           "int3",                "int4",               "int8",               "integer",       "intersect",     "interval",       "into",
    "io_after_gtids", "io_before_gtids",     "is",                 "iterate",            "join",          "json_table",    "key",            "keys",
    "kill",           "lag",                 "last_value",         "lateral",            "lead",          "leading",       "leave",          "left",
    "like",           "limit",               "linear",             "lines",              "load",          "localtime",     "localtimestamp", "lock",
    "long",           "longblob",            "longtext",           "loop",               "low_priority",  "match",         "maxvalue",       "mediumblob",
    "mediumint",      "mediumtext",          "middleint",          "minute_microsecond", "minute_second", "mod",           "modifies",       "natural",
    "not",            "no_write_to_binlog",  "nth_value",          "ntile",              "null",          "numeric",       "of",             "on",
    "optimize",       "optimizer_costs",     "option",             "optionally",         "or",            "order",         "out",            "outer",
    "outfile",        "over",                "partition",          "percent_rank",       "precision",     "primary",       "procedure",      "purge",
    "qualify",        "range",               "rank",               "read",               "reads",         "read_write",    "real",           "recursive",
    "references",     "regexp",              "release",            "rename",             "repeat",        "replace",       "require",        "resignal",
    "restrict",       "return",              "revoke",             "right",              "rlike",         "row",           "rows",           "row_number",
    "schema",         "schemas",             "second_microsecond", "select",             "sensitive",     "separator",     "set",            "show",
    "signal",         "smallint",            "spatial",            "specific",           "sql",           "sqlexception",  "sqlstate",       "sqlwarning",
    "sql_big_result", "sql_calc_found_rows", "sql_small_result",   "ssl",                "starting",      "stored",        "straight_join",  "system",
    "table",          "tablesample",         "terminated",         "then",               "tinyblob",      "tinyint",       "tinytext",       "to",
    "trailing",       "trigger",             "true",               "undo",               "union",         "unique",        "unlock",         "unsigned",
    "update",         "usage",               "use",                "using",              "utc_date",      "utc_time",      "utc_timestamp",  "values",
    "varbinary",      "varchar",             "varcharacter",       "varying",            "virtual",       "when",          "where",          "while",
    "window",         "with",                "write",              "xor",                "year_month",    "zerofill",
};

fn hasPlace(word: []const u8) bool {
    for (keywords) |keyword| if (std.ascii.eqlIgnoreCase(word, keyword.word)) return true;
    return false;
}

const Place = enum {
    before_by,
    before_count,
    after_with,
    call,
    window,
    cast_type,
};

const keywords = [_]struct { word: []const u8, place: Place }{
    .{ .word = "order", .place = .before_by },
    .{ .word = "limit", .place = .before_count },
    .{ .word = "offset", .place = .before_count },
    .{ .word = "recursive", .place = .after_with },
    .{ .word = "lead", .place = .call },
    .{ .word = "lag", .place = .call },
    .{ .word = "rank", .place = .call },
    .{ .word = "row_number", .place = .call },
    .{ .word = "rows", .place = .window },
    .{ .word = "range", .place = .window },
    .{ .word = "partition", .place = .before_by },
    .{ .word = "blob", .place = .cast_type },
    .{ .word = "integer", .place = .cast_type },
};

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
    .{ .word = "printf", .fix = "format the text in Zig" },
    .{ .word = "randomblob", .fix = "draw the bytes in Zig" },
    .{ .word = "strftime", .fix = "write @now, the Host's second" },
    .{ .word = "julianday", .fix = "write @now, the Host's second" },
    .{ .word = "iif", .fix = "write CASE WHEN ... THEN ... ELSE ... END" },
};

pub fn portabilityError(comptime text: []const u8, comptime reserved: bool) ?[]const u8 {
    comptime {
        @setEvalBranchQuota(500 * text.len + 1000);
        var index: usize = 0;
        var previous: []const u8 = "";
        var depth: usize = 0;
        var window_depth: ?usize = null;
        var cast_depth: ?usize = null;
        var leading_with = false;
        var first_word = true;
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
                if (first_word) leading_with = std.ascii.eqlIgnoreCase(word, "WITH");
                first_word = false;
                if (leading_with and depth == 0) {
                    if (std.ascii.eqlIgnoreCase(word, "INSERT") or std.ascii.eqlIgnoreCase(word, "REPLACE"))
                        return "rsql: MySQL takes WITH only after INSERT INTO t(columns); write INSERT INTO t(columns) WITH ... SELECT";
                    if (std.ascii.eqlIgnoreCase(word, "SELECT") or std.ascii.eqlIgnoreCase(word, "UPDATE") or std.ascii.eqlIgnoreCase(word, "DELETE"))
                        leading_with = false;
                }
                for (forbidden_words) |forbidden| {
                    if (std.ascii.eqlIgnoreCase(word, forbidden.word)) return "rsql: '" ++ word ++ "' is not portable; " ++ forbidden.fix;
                }
                if (std.ascii.eqlIgnoreCase(previous, "INSERT") and std.ascii.eqlIgnoreCase(word, "OR"))
                    return "rsql: 'INSERT OR' is not portable; read in an earlier round, then guard the write";
                if (reserved) {
                    if (std.ascii.eqlIgnoreCase(word, "rowid")) return "rsql: 'rowid' is SQLite's hidden key; name an explicit INTEGER key column";
                    if (identifierError(word, true)) |message| {
                        const in_window = window_depth != null and window_depth.? == depth;
                        const in_cast = cast_depth != null and cast_depth.? == depth;
                        if (!isKeyword(text, word, index, previous, in_window, in_cast)) return message;
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
                    if (std.ascii.eqlIgnoreCase(previous, "CAST")) cast_depth = depth;
                } else if (byte == ')') {
                    if (window_depth != null and window_depth.? == depth) window_depth = null;
                    if (cast_depth != null and cast_depth.? == depth) cast_depth = null;
                    depth -|= 1;
                }
                index += 1;
            }
            previous = "";
        }
        return null;
    }
}

fn isKeyword(comptime text: []const u8, comptime word: []const u8, comptime end: usize, comptime previous: []const u8, comptime in_window: bool, comptime in_cast: bool) bool {
    for (keywords) |keyword| {
        if (!std.ascii.eqlIgnoreCase(word, keyword.word)) continue;
        const next = skipSpace(text, end);
        return switch (keyword.place) {
            .before_by => std.ascii.eqlIgnoreCase(nextWord(text, end), "BY"),
            .before_count => next < text.len and (text[next] == '?' or std.ascii.isDigit(text[next])),
            .after_with => std.ascii.eqlIgnoreCase(previous, "WITH"),
            .call => end < text.len and text[end] == '(',
            .window => in_window,
            .cast_type => in_cast and std.ascii.eqlIgnoreCase(previous, "AS"),
        };
    }
    return false;
}

fn nextWord(comptime text: []const u8, comptime from: usize) []const u8 {
    const start = skipSpace(text, from);
    return text[start..wordEnd(text, start)];
}

pub fn identifierError(comptime name: []const u8, comptime reserved: bool) ?[]const u8 {
    if (!reserved) return null;
    if (reserved_lookup.has(name)) return "rsql: '" ++ name ++ "' is reserved on some engine; rename it";
    return null;
}

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

pub const Bytes = struct { bytes: []const u8 };

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

pub fn isBlob(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "blob_capacity") and T == Blob(T.blob_capacity);
}

pub const Positive = enum(u64) {
    _,

    pub fn of(value: u64) Positive {
        std.debug.assert(value > 0 and value <= std.math.maxInt(i64));
        return @fromBackingInt(@intCast(value));
    }

    pub fn get(self: Positive) u64 {
        return @backingInt(self);
    }

    pub fn optional(value: ?Positive) ?u64 {
        return if (value) |positive| positive.get() else null;
    }
};

pub const session_head_columns = "s.session_ref,s.workspace_key,s.next_position";

pub const SessionHead = struct {
    ref: change_ring.Id,
    workspace_key: Positive,
    next_position: Positive,
};

pub const Cardinality = union(enum) {
    one,
    optional,
    at_most: u16,
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

pub const Expect = union(enum) {
    exact: struct { rows: u32, otherwise: anyerror },
    at_most: u32,
    counted: struct { otherwise: anyerror },
};

pub const ReadSpec = struct {
    sql: []const u8,
    Args: type,
    Row: type,
    cardinality: Cardinality,
    compound: bool = false,
};
pub const WriteSpec = struct { sql: []const u8, Args: type, expect: Expect };

pub fn Read(comptime spec: ReadSpec) type {
    return ReadFrom(statement_table, spec);
}

pub fn Write(comptime spec: WriteSpec) type {
    return WriteFrom(statement_table, spec);
}

fn ReadFrom(comptime table: type, comptime spec: ReadSpec) type {
    const hit = comptime tableHit(table, .read, spec.sql, spec.Args, spec.Row, spec.compound);
    const facts: Facts = comptime if (hit) |found| found.facts else factsOf(accepted(.read, spec.sql, spec.Args, spec.Row, spec.compound));
    comptime {
        if (fillsInPlace(spec.Row) and spec.cardinality != .optional and spec.cardinality != .each)
            @compileError("rsql: a Row that points into its caller's memory is read .optional, with Access.readInto, or .each into its visitor's decoded row: " ++ spec.sql);
    }
    const Made = struct {
        pub const kind: StatementKind = .read;
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
        pub const sql = if (hit) |found| found.sqlite else renderStatement(spec.sql, fieldCount(Args));
        pub const mysql: Template = if (hit) |found| found.mysql else mysqlTemplate(spec.sql);
        pub const uses_now = facts.uses_now;
        pub const single_row = facts.single_row;
    };
    if (collecting()) collect(.read, spec.sql, signature(.read, spec.Args, spec.Row, spec.compound), Made.sql, Made.mysql, facts);
    return Made;
}

fn WriteFrom(comptime table: type, comptime spec: WriteSpec) type {
    const hit = comptime tableHit(table, .write, spec.sql, spec.Args, void, false);
    const facts: Facts = comptime if (hit) |found| found.facts else factsOf(accepted(.write, spec.sql, spec.Args, void, false));
    comptime if (shapeExpectError(facts.shape, spec.expect)) |message| @compileError(message ++ ": " ++ spec.sql);
    comptime if (shapeDeleteError(facts.shape, @import("builtin").is_test)) |message| @compileError(message ++ ": " ++ spec.sql);
    const Made = struct {
        pub const kind: StatementKind = .write;
        pub const made_from = spec;
        pub const Args = spec.Args;
        pub const expect = spec.expect;
        pub const guarded = facts.shape != .insert_row;
        pub const sql = if (hit) |found| found.sqlite else renderStatement(spec.sql, fieldCount(Args));
        pub const mysql: Template = if (hit) |found| found.mysql else mysqlTemplate(spec.sql);
        pub const uses_now = facts.uses_now;
        pub const session_fields: []const []const u8 = sessionFields(Args);
    };
    if (collecting()) collect(.write, spec.sql, signature(.write, spec.Args, void, false), Made.sql, Made.mysql, facts);
    return Made;
}

// The statement table (rsql_table.zig, generated by tests/ci/rsql_table.py) holds what the comptime
// path above produces for every statement the build declares: the SQLite text per checked signature,
// the MySQL template and the facts Read and Write expose. A statement serves its entry only when its
// text, its signature and the table's input fingerprint all match; anything else takes the comptime
// path, so the table changes how fast a statement compiles and never what it renders.

const statement_table = @import("rsql_table.zig");

pub const Shape = enum { select, select_one, insert_row, insert_select_one, insert_select_many, update, delete };

pub const Facts = struct {
    uses_now: bool,
    shape: Shape,
    single_row: bool = false,
};

pub const TableVariant = struct { signature: []const u8, sqlite: [:0]const u8 };

pub const TableEntry = struct {
    variants: []const TableVariant,
    mysql: Template,
    facts: Facts,
};

const Hit = struct { sqlite: [:0]const u8, mysql: Template, facts: Facts };

/// The build's fingerprint of the files the comptime path reads (build/product.zig owns the list).
fn inputs() []const u8 {
    return @import("build_options").rsql_inputs;
}

/// A collect build (-Drsql-collect=true) serves no entry and exports every statement's values.
pub fn collecting() bool {
    return @import("build_options").rsql_collect;
}

fn tableHit(comptime table: type, comptime kind: StatementKind, comptime sql: []const u8, comptime Args: type, comptime Row: type, comptime compound: bool) ?Hit {
    comptime {
        if (collecting() or !std.mem.eql(u8, table.inputs, inputs()) or !@hasDecl(table.entries, sql)) return null;
        const entry: TableEntry = @field(table.entries, sql);
        const wanted = signature(kind, Args, Row, compound);
        for (entry.variants) |variant| {
            if (std.mem.eql(u8, variant.signature, wanted)) return .{ .sqlite = variant.sqlite, .mysql = entry.mysql, .facts = entry.facts };
        }
        return null;
    }
}

/// The schema's generated values (objects, DDL, MySQL migrations, bootstrap digest) while the
/// table's inputs match the build; null in a collect build or with a stale table.
pub fn generatedSchema() ?type {
    return generatedSchemaFrom(statement_table);
}

fn generatedSchemaFrom(comptime table: type) ?type {
    if (collecting() or !@hasDecl(table, "schema") or !std.mem.eql(u8, table.inputs, inputs())) return null;
    return table.schema;
}

/// In a collect build, exports one of schema.zig's generated values for the table generator.
pub fn collectSchema(comptime name: []const u8, comptime payload: []const u8) void {
    if (!collecting()) return;
    comptime {
        const record = "schema\x1f" ++ name ++ "\x1f" ++ payload ++ "\x1f" ++ inputs() ++ "\x1c";
        const bytes: [record.len]u8 = record[0..record.len].*;
        @export(&bytes, .{ .name = "rsqlstmt_schema_" ++ name });
    }
}

/// Everything the statement checks read from Args and Row: the kind, .compound, each Args field's
/// SessionHead-ness (and so their count), and each Row field's name or SessionHead-ness.
fn signature(comptime kind: StatementKind, comptime Args: type, comptime Row: type, comptime compound: bool) []const u8 {
    comptime {
        var text: []const u8 = (if (kind == .read) "r" else "w") ++ (if (compound) "1" else "0") ++ ":";
        for (@typeInfo(Args).@"struct".field_types) |Field| text = text ++ (if (Field == SessionHead) "H" else ".");
        if (Row != void) {
            text = text ++ ":";
            const info = @typeInfo(Row).@"struct";
            for (info.field_names, info.field_types) |name, Field| text = text ++ (if (Field == SessionHead) "*H" else name) ++ ",";
        }
        return text;
    }
}

fn factsOf(comptime parsed: Parsed) Facts {
    const shape = shapeOf(parsed.statement);
    return .{ .uses_now = parsed.uses_now, .shape = shape, .single_row = shape == .select_one };
}

fn shapeOf(comptime statement: Statement) Shape {
    return switch (statement) {
        .select => |select| if (returnsOneRow(select)) .select_one else .select,
        .insert => |insert| switch (insert.values) {
            .row => .insert_row,
            .select => |select| if (returnsOneRow(select)) .insert_select_one else .insert_select_many,
        },
        .update => .update,
        .delete => .delete,
    };
}

fn shapeExpectError(comptime shape: Shape, comptime expect: Expect) ?[]const u8 {
    switch (shape) {
        .insert_row => return switch (expect) {
            .exact => |guard| if (guard.rows > 1) values_message else null,
            .at_most => null,
            .counted => values_message,
        },
        .insert_select_one, .insert_select_many => {
            const declares_one = switch (expect) {
                .exact => |guard| guard.rows == 1,
                .at_most => |rows| rows == 1,
                .counted => false,
            };
            if (shape == .insert_select_one) {
                if (!declares_one) return "rsql: an INSERT ... SELECT of at most one row declares .exact or .at_most 1";
            } else if (expect != .counted) return "rsql: an INSERT ... SELECT of more than one row declares .counted, so its caller states the count";
            return null;
        },
        else => return null,
    }
}

fn Exported(comptime record: []const u8) type {
    return struct {
        comptime {
            @setEvalBranchQuota(100 * record.len + 100_000);
            const bytes: [record.len]u8 = record[0..record.len].*;
            @export(&bytes, .{ .name = std.fmt.comptimePrint("rsqlstmt_{x}_{d}", .{ std.hash.Wyhash.hash(0, record), record.len }) });
        }
    };
}

/// One record per statement for the table generator: kind, text, signature, SQLite text, MySQL parts
/// (0x1e between them), slots, uses_now, shape, then the inputs fingerprint; fields end in 0x1f, the
/// record in 0x1c.
fn collect(
    comptime kind: StatementKind,
    comptime sql: []const u8,
    comptime checked: []const u8,
    comptime sqlite: []const u8,
    comptime mysql: Template,
    comptime facts: Facts,
) void {
    comptime {
        @setEvalBranchQuota(100 * (sql.len + sqlite.len) + 1_000_000);
        _ = Exported(@tagName(kind) ++ "\x1f" ++ sql ++ "\x1f" ++ checked ++ "\x1f" ++ sqlite ++ "\x1f" ++ templateRecord(mysql) ++ "\x1f" ++
            (if (facts.uses_now) "1" else "0") ++ "\x1f" ++ @tagName(facts.shape) ++ "\x1f" ++ inputs() ++ "\x1c");
    }
}

/// A Store test fixture's text (store_testing.exec, queryU64, withoutForeignKeys) as MySQL renders it,
/// after fixtureRendering's checks. The table's `fixtures` serve it on a text and inputs match, which
/// means those checks passed under the same inputs; any other text is checked and rendered here.
pub fn fixtureTemplate(comptime text: []const u8) Template {
    return switch (comptime fixtureFrom(statement_table, text)) {
        .refused => |message| @compileError(message ++ ": " ++ text),
        .rendered => |template| template,
    };
}

/// The MySQL rendering of a text mysql_testing sends: the table's fixture entry for it, else
/// mysqlRendering. An entry holds what mysqlRendering produced under the same inputs.
pub fn sentTemplate(comptime text: []const u8) Template {
    return comptime servedFixture(statement_table, text) orelse mysqlTemplate(text);
}

fn servedFixture(comptime table: type, comptime text: []const u8) ?Template {
    comptime {
        if (collecting() or !std.mem.eql(u8, table.inputs, inputs()) or !@hasDecl(table.fixtures, text)) return null;
        return @field(table.fixtures, text);
    }
}

fn fixtureFrom(comptime table: type, comptime text: []const u8) MysqlRendering {
    comptime {
        if (servedFixture(table, text)) |template| return .{ .rendered = template };
        const rendering = fixtureRendering(text);
        if (collecting() and rendering == .rendered) _ = Exported("fixture\x1f" ++ text ++ "\x1f" ++ templateRecord(rendering.rendered) ++ "\x1f" ++ inputs() ++ "\x1c");
        return rendering;
    }
}

/// Every rule a fixture text meets, in order: portable Rui SQL naming no SQLite mechanism, each
/// statement parsing as the Store's own grammar, and a MySQL rendering.
pub fn fixtureRendering(comptime text: []const u8) MysqlRendering {
    comptime {
        if (fixtureTextError(text)) |message| return .{ .refused = message };
        if (fixtureError(text)) |message| return .{ .refused = "fixture: " ++ message };
        return switch (mysqlRendering(text)) {
            .refused => |message| .{ .refused = "fixture: MySQL rendering refuses it: " ++ message },
            .rendered => |template| .{ .rendered = template },
        };
    }
}

/// A template's MySQL parts (0x1e between them), 0x1f, then its slots.
fn templateRecord(comptime mysql: Template) []const u8 {
    comptime {
        @setEvalBranchQuota(1_000_000);
        var parts: []const u8 = "";
        for (mysql.parts, 0..) |part, i| parts = parts ++ (if (i == 0) "" else "\x1e") ++ part;
        var slots: []const u8 = "";
        for (mysql.slots) |slot| slots = slots ++ switch (slot) {
            .argument => |n| std.fmt.comptimePrint("a{d},", .{n}),
            .now => "n,",
            .served => |provider| "s" ++ @tagName(provider) ++ ",",
        };
        return parts ++ "\x1f" ++ slots;
    }
}

pub const StatementKind = enum { read, write };

pub const ObligationProjectionSpec = struct { sql: []const u8, Args: type };
pub fn ObligationProjection(comptime spec: ObligationProjectionSpec) type {
    const R = Read(.{
        .sql = spec.sql,
        .Args = spec.Args,
        .Row = struct { session_ref: @import("../bounded.zig").Bounded(change_ring.id_bytes), saved_since: ?Positive, owed_since: ?Positive },
        .cardinality = .each,
        .compound = true,
    });
    const projected = "SELECT session_ref,min(saved_since) AS saved_since,min(owed_since) AS owed_since FROM (" ++ spec.sql ++ ") obligation_values GROUP BY session_ref";
    const text = "UPDATE session SET obligation_since=(SELECT owed_since FROM (" ++ projected ++ ") obligation_new WHERE obligation_new.session_ref=session.session_ref) " ++
        "WHERE session_ref IN (SELECT session_ref FROM (" ++ projected ++ ") obligation_changed WHERE @distinct(owed_since,saved_since))";
    const mysql_text = "UPDATE session JOIN (" ++ projected ++ ") obligation_new ON obligation_new.session_ref=session.session_ref " ++
        "SET session.obligation_since=obligation_new.owed_since WHERE @distinct(obligation_new.owed_since,obligation_new.saved_since)";
    return struct {
        pub const kind: StatementKind = .write;
        pub const made_from = spec;
        pub const Args = spec.Args;
        pub const expect: Expect = .{ .at_most = std.math.maxInt(u32) };
        pub const guarded = true;
        pub const sql = renderStatement(text, fieldCount(Args));
        pub const mysql: Template = mysqlTemplate(mysql_text);
        pub const uses_now = R.uses_now;
        pub const session_fields: []const []const u8 = &.{};
    };
}

pub fn isStatement(comptime S: type) bool {
    comptime {
        if (@typeInfo(S) != .@"struct" or !@hasDecl(S, "kind") or !@hasDecl(S, "made_from")) return false;
        if (@TypeOf(S.kind) != StatementKind) return false;
        return switch (S.kind) {
            .read => if (@TypeOf(S.made_from) == ReadSpec) S == Read(S.made_from) else @TypeOf(S.made_from) == PageSpec and S == Page(S.made_from),
            .write => if (@TypeOf(S.made_from) == WriteSpec) S == Write(S.made_from) else @TypeOf(S.made_from) == ObligationProjectionSpec and S == ObligationProjection(S.made_from),
        };
    }
}

pub fn fillsInPlace(comptime Row: type) bool {
    comptime {
        for (@typeInfo(Row).@"struct".field_types) |Field| if (@typeInfo(Field) == .pointer) return true;
        return false;
    }
}

pub fn statementError(comptime kind: StatementKind, comptime sql: []const u8, comptime Args: type, comptime Row: type) ?[]const u8 {
    return switch (check(kind, sql, Args, Row, false)) {
        .refused => |message| message,
        .accepted => null,
    };
}

fn writeError(comptime sql: []const u8, comptime Args: type, comptime expect: Expect) ?[]const u8 {
    return switch (check(.write, sql, Args, void, false)) {
        .refused => |message| message,
        .accepted => |parsed| expectError(parsed.statement, expect),
    };
}

fn expectError(comptime statement: Statement, comptime expect: Expect) ?[]const u8 {
    return shapeExpectError(shapeOf(statement), expect);
}

fn deleteError(comptime statement: Statement, comptime is_test: bool) ?[]const u8 {
    return shapeDeleteError(shapeOf(statement), is_test);
}

fn shapeDeleteError(comptime shape: Shape, comptime is_test: bool) ?[]const u8 {
    if (shape != .delete or is_test) return null;
    return delete_message;
}

const delete_message = "rsql: the Store's MySQL login may not DELETE (D202); only tests delete";

const values_message = "rsql: an INSERT ... VALUES writes one row; it declares .at_most, or .exact of at most 1, never .counted";

const Checked = union(enum) { refused: []const u8, accepted: Parsed };

fn accepted(comptime kind: StatementKind, comptime sql: []const u8, comptime Args: type, comptime Row: type, comptime compound: bool) Parsed {
    return switch (check(kind, sql, Args, Row, compound)) {
        .refused => |message| @compileError(message ++ ": " ++ sql),
        .accepted => |parsed| parsed,
    };
}

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
    return parseAs(sql, false);
}

fn parseAs(comptime sql: []const u8, comptime fixture: bool) Checked {
    comptime {
        @setEvalBranchQuota(1000 * sql.len + 20_000);
        var p: Parser = .{ .tokens = tokenize(sql), .fixture = fixture };
        const statement = p.statement() catch return .{ .refused = p.message };
        if (readsWrittenTable(statement, p.queries)) return .{ .refused = written_read_message };
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

const written_read_message = "rsql: MySQL refuses a write whose subquery reads the table it writes (error 1093); read the value first and bind it";

fn readsWrittenTable(comptime statement: Statement, comptime queries: []const Query) bool {
    const table: []const u8, const own: ?usize = switch (statement) {
        .select => return false,
        .insert => |insert| switch (insert.values) {
            .row => .{ insert.table, null },
            .select => return false,
        },
        .update => |update| .{ update.table, update.query },
        .delete => |delete| .{ delete.table, delete.query },
    };
    for (queries) |query| {
        if (own != null and query.id == own.?) continue;
        for (query.sources) |read| if (!read.defined and std.ascii.eqlIgnoreCase(read.table, table)) return true;
    }
    return false;
}

pub fn fixtureError(comptime text: []const u8) ?[]const u8 {
    comptime {
        @setEvalBranchQuota(1000 * text.len + 20_000);
        if (portabilityError(text, reserved_names_checked)) |message| return message;
        var start: usize = 0;
        var index: usize = 0;
        while (index <= text.len) {
            if (index < text.len and text[index] == '\'') {
                index = literalEnd(text, index);
                continue;
            }
            if (index == text.len or text[index] == ';') {
                const statement = std.mem.trim(u8, text[start..index], &std.ascii.whitespace);
                if (statement.len != 0) switch (parseAs(statement, true)) {
                    .refused => |message| return message,
                    .accepted => {},
                };
                start = index + 1;
            }
            index += 1;
        }
        return null;
    }
}

pub const fixture_sqlite_words = [_][]const u8{
    "PRAGMA", "temp",      "CREATE", "ALTER",  "DROP",     "TRIGGER", "VIEW",
    "ATTACH", "SAVEPOINT", "BEGIN",  "COMMIT", "ROLLBACK", "VACUUM",
};

pub const fixture_sqlite_prefixes = [_][]const u8{ "sqlite_", "pragma_" };

pub fn fixtureTextError(comptime text: []const u8) ?[]const u8 {
    comptime {
        @setEvalBranchQuota(1000 * text.len + 10000);
        if (portabilityError(text, reserved_names_checked)) |message| return message;
        var index: usize = 0;
        var previous: []const u8 = "";
        while (index < text.len) {
            if (text[index] == '\'') {
                index += 1;
                while (index < text.len) : (index += 1) {
                    if (text[index] != '\'') continue;
                    if (index + 1 < text.len and text[index + 1] == '\'') {
                        index += 1;
                        continue;
                    }
                    break;
                }
                index += 1;
                previous = "";
                continue;
            }
            if (!isFixtureWordByte(text[index])) {
                if (!std.ascii.isWhitespace(text[index])) previous = "";
                index += 1;
                continue;
            }
            var end = index;
            while (end < text.len and isFixtureWordByte(text[end])) end += 1;
            const word = text[index..end];
            index = end;
            for (fixture_sqlite_words) |sqlite_word| {
                if (std.ascii.eqlIgnoreCase(word, sqlite_word)) return "fixture: '" ++ word ++ "' is a SQLite mechanism; write the test under sqlite_tests/";
            }
            for (fixture_sqlite_prefixes) |prefix| {
                if (std.ascii.startsWithIgnoreCase(word, prefix)) return "fixture: '" ++ word ++ "' is a SQLite mechanism; write the test under sqlite_tests/";
            }
            if (std.ascii.eqlIgnoreCase(previous, "AS") and std.ascii.eqlIgnoreCase(word, "TEXT"))
                return "fixture: 'AS TEXT' is not a MySQL cast; compare the bytes another way";
            previous = word;
        }
        return null;
    }
}

fn isFixtureWordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

pub const max_parameters = 65;

const Parsed = struct {
    statement: Statement,
    uses: [max_parameters]usize,
    sessions: []const usize,
    uses_now: bool,
    compounds: usize,
    queries: []const Query,
};

const Query = struct { id: usize, parent: ?usize, sources: []const Source, where: ?Expr };

const Statement = union(enum) {
    select: Select,
    insert: struct {
        table: []const u8,
        columns: []const []const u8,
        values: union(enum) { row: []const Expr, select: Select },
    },
    update: struct { table: []const u8, assigned: []const []const u8, where: Expr, query: usize },
    delete: struct { table: []const u8, where: Expr, query: usize },
};

const Select = struct {
    first: Core,
    compound: bool,
    limit_one: bool,
};

const Core = struct { results: []const Result, sources: []const Source, where: ?Expr, query: usize };

const Result = struct { value: Expr, alias: ?[]const u8 };

const Join = enum { first, left, inner, cross };

const Source = struct {
    table: []const u8,
    alias: []const u8,
    defined: bool,
    join: Join,
    index: ?[]const u8 = null,
    on: ?Expr,
};

const Column = struct { table: ?[]const u8, name: []const u8 };

const Expr = union(enum) {
    column: Column,
    parameter: usize,
    constant: []const u8,
    session: usize,
    conjunction: []const Expr,
    equality: *const [2]Expr,
    is_null: Column,
    after: struct { columns: []const Column, parameters: []const usize },
    other,
};

const Token = struct {
    kind: enum { word, parameter, number, literal, marker, symbol, end },
    text: []const u8,
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

fn bytesColumns(comptime name: []const u8) []const []const u8 {
    var bytes: []const []const u8 = &.{};
    for (schema.tables) |table| if (std.mem.eql(u8, table.name, name)) {
        for (table.columns) |column| if (column.type == .bytes) {
            bytes = bytes ++ .{column.name};
        };
    };
    return bytes;
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

const Parser = struct {
    tokens: []const Token,
    at: usize = 0,
    message: []const u8 = "",
    uses: [max_parameters]usize = @splat(0),
    sessions: []const usize = &.{},
    uses_now: bool = false,
    compounds: usize = 0,
    defined: []const []const u8 = &.{},
    queries: []const Query = &.{},
    scope: ?usize = null,
    next_query: usize = 0,
    columns: []const Column = &.{},
    bytes_columns: []const []const u8 = &.{},
    fixture: bool = false,

    const Opened = struct { id: usize, parent: ?usize };

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

    fn writtenTable(table: []const u8) []const Source {
        return &.{Source{ .table = table, .alias = table, .defined = false, .join = .first, .on = null }};
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
            if (p.fixture) p.bytes_columns = bytesColumns(target);
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
            const where = try p.writtenWhere();
            p.close(opened, writtenTable(target), where);
            break :update .{ .update = .{ .table = target, .assigned = assigned, .where = where, .query = opened.id } };
        } else if (p.accept("DELETE")) delete: {
            try p.expect("FROM");
            const target = try p.tableName();
            const opened = p.open();
            const where = try p.writtenWhere();
            p.close(opened, writtenTable(target), where);
            break :delete .{ .delete = .{ .table = target, .where = where, .query = opened.id } };
        } else return p.refuse("SELECT, WITH, INSERT, UPDATE or DELETE");
        if (p.peek().kind != .end) return p.refuse("the end");
        return parsed;
    }

    fn writtenWhere(p: *Parser) Refused!Expr {
        if (p.fixture and p.peek().kind == .end) return .other;
        try p.expect("WHERE");
        return p.expr();
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
            sources = sources ++ .{try p.source(.first)};
            while (p.peek().is("JOIN") or p.peek().is("LEFT") or p.peek().is("INNER") or p.peek().is("CROSS")) {
                const join: Join = if (p.accept("LEFT")) left: {
                    _ = p.accept("OUTER");
                    break :left .left;
                } else if (p.accept("CROSS")) .cross else inner: {
                    _ = p.accept("INNER");
                    break :inner .inner;
                };
                try p.expect("JOIN");
                sources = sources ++ .{try p.source(join)};
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

    fn source(p: *Parser, join: Join) Refused!Source {
        const written = try p.name();
        const defined = for (p.defined) |each| {
            if (std.mem.eql(u8, each, written)) break true;
        } else false;
        if (!defined and !isTable(written)) return p.refuseWith("rsql: no table named " ++ written);
        const alias = if (p.accept("AS")) try p.name() else if (p.peek().kind == .word and !isGrammarWord(p.peek().text)) p.next().text else written;
        var index: ?[]const u8 = null;
        if (p.peek().kind == .marker) {
            if (!std.mem.eql(u8, p.next().text, "@index")) return p.refuseWith("rsql: only @index(name) follows a table");
            try p.expectSymbol("(");
            const named = try p.name();
            try p.expectSymbol(")");
            if (defined or !isIndexOf(written, named)) return p.refuseWith("rsql: @index names an index of its own table, and " ++ written ++ " has no index " ++ named);
            index = named;
        }
        const on: ?Expr = if (p.accept("ON")) try p.expr() else null;
        return .{ .table = written, .alias = alias, .defined = defined, .join = join, .index = index, .on = on };
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
            } else if (p.peek().is("BETWEEN") or (p.peek().is("NOT") and p.peekAt(1).is("BETWEEN"))) {
                _ = p.accept("NOT");
                try p.expect("BETWEEN");
                _ = try p.relation();
                try p.expect("AND");
                _ = try p.relation();
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
                if (p.peek().isSymbol(",")) return p.refuseWith(row_value_message);
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
        if (p.peek().is("CAST")) return p.refuseWith(cast_message);
        const quoted = p.peekAt(1);
        if (token.is("X") and quoted.kind == .literal and quoted.start == token.start + 1) {
            const digits = quoted.text[1 .. quoted.text.len - 1];
            for (digits) |digit| if (!std.ascii.isHex(digit)) return p.refuseWith("rsql: X'...' holds only hex digits");
            if (digits.len % 2 != 0) return p.refuseWith("rsql: X'...' holds an even count of hex digits");
            p.at += 2;
            return .other;
        }
        const first = try p.name();
        if (p.acceptSymbol("(")) {
            var values: []const Expr = &.{};
            const count: usize = if (p.acceptSymbol("*")) 1 else if (p.peek().isSymbol(")")) 0 else count: {
                _ = p.accept("DISTINCT");
                values = try p.expressions();
                break :count values.len;
            };
            try p.expectSymbol(")");
            if (std.ascii.eqlIgnoreCase(first, "length") and !p.lengthOfBytes(values)) return p.refuseWith(length_message);
            if (p.accept("OVER")) {
                try p.window(std.ascii.eqlIgnoreCase(first, "row_number") and count == 0);
            } else if (knownFunction(first, count) == null) return p.refuseWith(functionMessage(first, count));
            return .other;
        }
        const column: Column = if (p.acceptSymbol(".")) .{ .table = first, .name = try p.name() } else .{ .table = null, .name = first };
        p.columns = p.columns ++ .{column};
        return .{ .column = column };
    }

    fn lengthOfBytes(p: *const Parser, values: []const Expr) bool {
        if (values.len != 1 or values[0] != .column or values[0].column.table != null) return false;
        for (p.bytes_columns) |bytes_column| if (std.mem.eql(u8, bytes_column, values[0].column.name)) return true;
        return false;
    }

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

    fn parameter(p: *Parser, token: Token) Refused!usize {
        const number = std.fmt.parseInt(usize, token.text[1..], 10) catch return p.refuseWith("rsql: write parameters as ?N");
        if (number == 0 or number > p.uses.len) return p.refuseWith(std.fmt.comptimePrint("rsql: a parameter is ?1 to ?{d}", .{max_parameters}));
        p.uses[number - 1] += 1;
        return number;
    }

    fn marker(p: *Parser) Refused!Expr {
        const written = p.next().text;
        const marker_name = written[1..];
        if (std.mem.eql(u8, marker_name, "now")) {
            if (p.peek().isSymbol("(")) return p.refuseWith("rsql: @now takes no arguments");
            p.uses_now = true;
            return .other;
        }
        if (std.mem.eql(u8, marker_name, "index")) return p.refuseWith("rsql: @index(name) stands only after its table");
        if (std.mem.eql(u8, marker_name, "after")) return p.after();
        if (std.mem.eql(u8, marker_name, "in_index")) {
            try p.expectSymbol("(");
            const alias = p.next();
            try p.expectSymbol(",");
            const index = p.next();
            try p.expectSymbol(")");
            if (alias.kind != .word or index.kind != .word) return p.refuseWith("rsql: @in_index takes an alias and an index name");
            if (schema.partialIndex(index.text) == null) return p.refuseWith("rsql: @in_index names no partial index " ++ index.text);
            return .other;
        }
        if (std.mem.eql(u8, marker_name, "session")) {
            try p.expectSymbol("(");
            const token = p.next();
            if (token.kind != .parameter) return p.refuseWith("rsql: @session takes one parameter, ?k");
            const k = try p.parameter(token);
            try p.expectSymbol(")");
            p.sessions = p.sessions ++ .{k};
            return .{ .session = k };
        }
        const arity = (expressionMarker(marker_name) orelse return p.refuseWith("rsql: unknown marker " ++ written)).arity;
        try p.expectSymbol("(");
        const arguments = try p.expressions();
        try p.expectSymbol(")");
        if (arguments.len != arity) return p.refuseWith(std.fmt.comptimePrint("rsql: {s} takes {d} arguments", .{ written, arity }));
        return .other;
    }

    fn after(p: *Parser) Refused!Expr {
        const refused = "rsql: @after takes k qualified columns, then k parameters ?N";
        try p.expectSymbol("(");
        var columns: []const Column = &.{};
        var parameters: []const usize = &.{};
        while (true) {
            const token = p.next();
            if (token.kind == .parameter) {
                parameters = parameters ++ .{try p.parameter(token)};
            } else {
                if (token.kind != .word or isGrammarWord(token.text) or parameters.len != 0 or !p.acceptSymbol(".")) return p.refuseWith(refused);
                columns = columns ++ .{Column{ .table = token.text, .name = try p.name() }};
            }
            if (!p.acceptSymbol(",")) break;
        }
        try p.expectSymbol(")");
        if (columns.len == 0 or columns.len != parameters.len) return p.refuseWith(refused);
        return .{ .after = .{ .columns = columns, .parameters = parameters } };
    }
};

fn readsAssigned(comptime read: []const Column, comptime table: []const u8, comptime assigned: []const []const u8) ?[]const u8 {
    for (read) |column| {
        if (column.table) |qualifier| if (!std.mem.eql(u8, qualifier, table)) continue;
        for (assigned) |name| if (std.mem.eql(u8, name, column.name)) return name;
    }
    return null;
}

const row_value_message = "rsql: a row value is outside the grammar; write a keyset as an rsql.Page, with @after";

fn fieldCount(comptime T: type) usize {
    return @typeInfo(T).@"struct".field_names.len;
}

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

fn compoundError(comptime kind: StatementKind, comptime parsed: Parsed, comptime compound: bool) ?[]const u8 {
    if (parsed.compounds == 0) return if (compound) "rsql: .compound = true, but the text has no compound SELECT" else null;
    if (kind == .write) return "rsql: a write holds no compound SELECT";
    return if (compound) null else "rsql: a read with a compound SELECT declares .compound = true";
}

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

fn readSessionError(comptime parsed: Parsed, comptime Args: type) ?[]const u8 {
    if (sessionFields(Args).len != 0 or parsed.sessions.len != 0) return "rsql: a read binds no SessionHead; it names a Session by its reference text";
    return null;
}

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

fn sessionSlot(comptime listed: []const []const u8, comptime column: []const u8) error{Twice}!?usize {
    var slot: ?usize = null;
    for (listed, 0..) |name, index| if (std.mem.eql(u8, name, column)) {
        if (slot != null) return error.Twice;
        slot = index;
    };
    return slot;
}

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

const Ref = struct { query: usize, source: usize };

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

fn resolve(comptime queries: []const Query, comptime q: usize, comptime column: Column) ?Ref {
    const qualifier = column.table orelse return if (queries[q].sources.len == 1) .{ .query = q, .source = 0 } else null;
    var at: ?usize = q;
    while (at) |index| {
        for (queries[index].sources, 0..) |source, s| if (std.mem.eql(u8, source.alias, qualifier)) return .{ .query = index, .source = s };
        at = if (queries[index].parent) |parent| queryAt(queries, parent) else null;
    }
    return null;
}

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

fn tiesRef(comptime queries: []const Query, comptime refs: []const Ref, comptime tied: []const bool, comptime ref: Ref) bool {
    const query = queries[ref.query];
    for (query.sources, 0..) |source, s| if (source.on) |on| if (source.join != .left or s == ref.source) {
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

fn ties(comptime where: Expr, comptime table: []const u8, comptime column: []const u8) bool {
    for (conjuncts(where)) |term| {
        if (term != .equality) continue;
        const named = term.equality[0];
        if (named == .column and std.mem.eql(u8, named.column.name, column) and
            (named.column.table == null or std.mem.eql(u8, named.column.table.?, table)) and term.equality[1] == .session) return true;
    }
    return false;
}

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

fn returnsOneRow(comptime select: Select) bool {
    comptime {
        if (select.compound) return false;
        return select.limit_one or select.first.sources.len == 0 or pinsOneRow(select.first);
    }
}

fn pinsOneRow(comptime core: Core) bool {
    comptime {
        @setEvalBranchQuota(100_000);
        const Term = struct { condition: Expr, only: ?usize };
        var terms: []const Term = &.{};
        for (core.sources, 0..) |source, index| if (source.on) |on| {
            for (conjuncts(on)) |condition| terms = terms ++ .{Term{ .condition = condition, .only = if (source.join == .left) index else null }};
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

fn names(comptime side: Expr, comptime sources: []const Source, comptime index: usize, comptime column: []const u8) bool {
    if (side != .column or !std.mem.eql(u8, side.column.name, column)) return false;
    return if (side.column.table) |table| std.mem.eql(u8, table, sources[index].alias) else sources.len == 1;
}

fn renderStatement(comptime sql: []const u8, comptime arguments: usize) [:0]const u8 {
    comptime {
        @setEvalBranchQuota(200 * sql.len + 10_000 + schema.objects_quota);
        // Each marker adds at most three pieces: the text before it, a fixed
        // word and its argument.
        var pieces: [3 * std.mem.countScalar(u8, sql, '@') + 1][]const u8 = undefined;
        var count: usize = 0;
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
                pieces[count..][0..2].* = .{ sql[start..index], std.fmt.comptimePrint("?{d}", .{arguments + 1}) };
                count += 2;
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
                pieces[count..][0..3].* = .{ sql[start..index], "INDEXED BY ", argument };
                count += 3;
            } else {
                pieces[count..][0..2].* = .{ sql[start..index], argument };
                count += 2;
            }
            index = close + 1;
            start = index;
        }
        pieces[count] = sql[start..];
        count += 1;
        const text = renderSqlite(joinPieces(pieces[0..count])) ++ "\x00";
        return text[0 .. text.len - 1 :0];
    }
}

fn renderSqlite(comptime text: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(100 * text.len + 1000);
        var pieces: [2 * std.mem.countScalar(u8, text, '@') + 1][]const u8 = undefined;
        var count: usize = 0;
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
            pieces[count] = text[start..index];
            count += 1;
            const name_end = wordEnd(text, index + 1);
            const name = text[index + 1 .. name_end];
            if (name_end >= text.len or text[name_end] != '(') @compileError("rsql: @" ++ name ++ " needs arguments in parentheses: " ++ text);
            const close = closingParenthesis(text, name_end);
            const arguments = splitArguments(text[name_end + 1 .. close]);
            pieces[count] = marker(name, arguments, text);
            count += 1;
            index = close + 1;
            start = index;
        }
        pieces[count] = text[start..];
        count += 1;
        return joinPieces(pieces[0..count]);
    }
}

const ExpressionMarker = struct { name: []const u8, arity: usize, sqlite: []const u8, mysql: []const u8 };
const arg_a = "\x01";
const arg_b = "\x02";
const arg_set = "\x03";
const served_slots = "\x04";
const expression_markers = [_]ExpressionMarker{
    .{ .name = "bytes", .arity = 1, .sqlite = "CAST(" ++ arg_a ++ " AS BLOB)", .mysql = "CAST(" ++ arg_a ++ " AS BINARY)" },
    .{ .name = "octets", .arity = 1, .sqlite = "length(CAST(" ++ arg_a ++ " AS BLOB))", .mysql = "OCTET_LENGTH(" ++ arg_a ++ ")" },
    .{
        .name = "charset",
        .arity = 2,
        .sqlite = "(" ++ arg_a ++ " NOT GLOB '*[^" ++ arg_set ++ "]*' AND length(" ++ arg_a ++ ")=length(CAST(" ++ arg_a ++ " AS BLOB)))",
        .mysql = "(NOT REGEXP_LIKE(" ++ arg_a ++ ",'[^" ++ arg_set ++ "]','c'))",
    },
    .{ .name = "initial", .arity = 2, .sqlite = arg_a ++ " GLOB '[" ++ arg_set ++ "]*'", .mysql = "REGEXP_LIKE(" ++ arg_a ++ ",'^[" ++ arg_set ++ "]','c')" },
    .{ .name = "same", .arity = 2, .sqlite = "(" ++ arg_a ++ " IS " ++ arg_b ++ ")", .mysql = "(" ++ arg_a ++ " <=> " ++ arg_b ++ ")" },
    .{ .name = "distinct", .arity = 2, .sqlite = "(" ++ arg_a ++ " IS NOT " ++ arg_b ++ ")", .mysql = "(NOT (" ++ arg_a ++ " <=> " ++ arg_b ++ "))" },
    .{ .name = "count_where", .arity = 1, .sqlite = "count(*) FILTER (WHERE " ++ arg_a ++ ")", .mysql = "count(CASE WHEN " ++ arg_a ++ " THEN 1 END)" },
    .{ .name = "max_where", .arity = 2, .sqlite = "max(" ++ arg_a ++ ") FILTER (WHERE " ++ arg_b ++ ")", .mysql = "max(CASE WHEN " ++ arg_b ++ " THEN " ++ arg_a ++ " END)" },
    .{ .name = "list", .arity = 1, .sqlite = "group_concat(" ++ arg_a ++ ",',')", .mysql = "GROUP_CONCAT(" ++ arg_a ++ " SEPARATOR ',')" },
    .{ .name = "served", .arity = 1, .sqlite = "rui_served(" ++ arg_a ++ ")", .mysql = "(" ++ arg_a ++ " IN (" ++ served_slots ++ "))" },
    .{
        .name = "payload",
        .arity = 1,
        .sqlite = arg_a ++ ".payload",
        .mysql = "coalesce((SELECT bytes FROM content_chunk WHERE content_chunk.content_id=" ++ arg_a ++ ".content_id AND content_chunk.chunk_index=0),X'')",
    },
};

fn expressionMarker(comptime name: []const u8) ?ExpressionMarker {
    for (expression_markers) |each| if (std.mem.eql(u8, each.name, name)) return each;
    return null;
}

fn marker(comptime name: []const u8, comptime arguments: []const []const u8, comptime text: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "after")) return renderAfterSqlite(arguments, text);
    if (std.mem.eql(u8, name, "in_index")) {
        const index = comptime schema.partialIndex(arguments[1]) orelse @compileError("rsql: @in_index names no partial index: " ++ text);
        return "(" ++ qualify(arguments[0], index.table, index.where.?) ++ ")";
    }
    const kind = expressionMarker(name) orelse @compileError("rsql: unknown marker @" ++ name ++ ": " ++ text);
    if (arguments.len != kind.arity) @compileError("rsql: @" ++ name ++ " takes " ++ std.fmt.comptimePrint("{d}", .{kind.arity}) ++ " arguments: " ++ text);
    var pieces: [2 * kind.sqlite.len + 1][]const u8 = undefined;
    var count: usize = 0;
    var from: usize = 0;
    for (kind.sqlite, 0..) |byte, index| {
        if (byte > arg_set[0]) continue;
        pieces[count..][0..2].* = .{ kind.sqlite[from..index], switch (byte) {
            arg_a[0] => renderSqlite(arguments[0]),
            arg_b[0] => renderSqlite(arguments[1]),
            arg_set[0] => characterSet(arguments[1], text),
            else => unreachable,
        } };
        count += 2;
        from = index + 1;
    }
    pieces[count] = kind.sqlite[from..];
    count += 1;
    return joinPieces(pieces[0..count]);
}

/// Concatenates `pieces` in halves, so each byte is copied once per level:
/// appending piece by piece to one slice copies the whole prefix every time.
fn joinPieces(comptime pieces: []const []const u8) []const u8 {
    comptime {
        return switch (pieces.len) {
            0 => "",
            1 => pieces[0],
            else => joinPieces(pieces[0 .. pieces.len / 2]) ++ joinPieces(pieces[pieces.len / 2 ..]),
        };
    }
}

/// A comptime list that doubles its storage when full, so n appends copy
/// O(n) items in all; `list = list ++ .{item}` copies the whole list each time.
fn ComptimeList(comptime T: type) type {
    return struct {
        storage: []T = &.{},
        len: usize = 0,

        fn append(list: *@This(), item: T) void {
            if (list.len == list.storage.len) {
                var grown: [@max(8, 2 * list.storage.len)]T = undefined;
                @memcpy(grown[0..list.len], list.storage);
                list.storage = &grown;
            }
            list.storage[list.len] = item;
            list.len += 1;
        }

        fn items(list: *const @This()) []const T {
            return list.storage[0..list.len];
        }

        fn finish(list: *const @This()) []const T {
            const final = list.storage[0..list.len].*;
            return &final;
        }
    };
}

pub const Slot = union(enum) {
    argument: usize,
    now,
    served: provider_name.Provider,
};

pub fn servedBinding(provider: provider_name.Provider, served: bool) []const u8 {
    return if (served) @tagName(provider) else "";
}

pub const Template = struct {
    parts: []const []const u8,
    slots: []const Slot,

    pub fn prepared(comptime template: Template) [:0]const u8 {
        comptime {
            var pieces: [2 * template.parts.len][]const u8 = undefined;
            for (template.parts, 0..) |part, index| pieces[2 * index ..][0..2].* = .{ if (index == 0) "" else "?", part };
            const text = joinPieces(&pieces);
            const terminated = text ++ "\x00";
            return terminated[0..text.len :0];
        }
    }
};

pub const MysqlRendering = union(enum) { refused: []const u8, rendered: Template };

fn mysqlTemplate(comptime text: []const u8) Template {
    return switch (comptime mysqlRendering(text)) {
        .refused => |message| @compileError(message ++ ": " ++ text),
        .rendered => |template| template,
    };
}

pub fn mysqlRendering(comptime text: []const u8) MysqlRendering {
    comptime {
        @setEvalBranchQuota(200 * text.len + 10_000);
        if (portabilityError(text, reserved_names_checked)) |message| return .{ .refused = message };
        const tokens = tokenize(text);
        const skips = switch (lackedByMysql(tokens)) {
            .refused => |message| return .{ .refused = message },
            .skips => |found| found,
        };
        var renderer: MysqlRenderer = .{ .text = text, .tokens = tokens, .skips = skips };
        renderer.range(0, tokens.len) catch return .{ .refused = renderer.message };
        renderer.endPart();
        return .{ .rendered = .{ .parts = renderer.parts.finish(), .slots = renderer.slots.finish() } };
    }
}

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
    .{ .name = "substr", .arguments = 3, .mysql = "SUBSTRING" },
    .{ .name = "zeroblob", .arguments = 1, .mysql = "REPEAT", .leading = "X'00'," },
};

const Function = @typeInfo(@TypeOf(functions)).array.child;

fn knownFunction(comptime name: []const u8, comptime count: usize) ?Function {
    for (functions) |function| {
        if (!std.ascii.eqlIgnoreCase(function.name, name)) continue;
        if (function.arguments) |arguments| if (arguments != count) continue;
        return function;
    }
    return null;
}

fn functionMessage(comptime name: []const u8, comptime count: usize) []const u8 {
    return std.fmt.comptimePrint("rsql: no function {s} of {d} arguments; Rui SQL calls only `functions`", .{ name, count });
}

const cast_message = "rsql: CAST converts differently on each engine";
const length_message = "rsql: length() counts characters of text on SQLite and bytes on MySQL; write @octets(x)";

pub fn expressionError(comptime text: []const u8, comptime bytes_columns: []const []const u8) ?[]const u8 {
    comptime {
        @setEvalBranchQuota(1000 * text.len + 20_000);
        if (portabilityError(text, reserved_names_checked)) |message| return message;
        var p: Parser = .{ .tokens = tokenize(text), .bytes_columns = bytes_columns };
        _ = p.expr() catch return p.message;
        if (p.peek().kind != .end) return switch (p.refuse("the end")) {
            error.Refused => p.message,
        };
        return null;
    }
}

fn lackedByMysql(comptime tokens: []const Token) union(enum) { refused: []const u8, skips: []const [2]usize } {
    comptime {
        if (tokens.len < 4 or !tokens[0].is("INSERT") or !tokens[1].is("INTO") or !tokens[3].isSymbol("(")) return .{ .skips = &.{} };
        const close = closingToken(tokens, 3, tokens.len) orelse return .{ .skips = &.{} };
        const columns = argumentRanges(tokens, 3, close);
        var lacked: []const usize = &.{};
        for (columns, 0..) |column, position| {
            if (column[1] == column[0] + 1 and schema.lacks(.mysql, tokens[2].text, tokens[column[0]].text)) lacked = lacked ++ .{position};
        }
        if (lacked.len == 0) return .{ .skips = &.{} };
        const refused = "rsql: an INSERT names a column MySQL's schema lacks, so it writes one row of VALUES";
        if (close + 2 >= tokens.len or !tokens[close + 1].is("VALUES") or !tokens[close + 2].isSymbol("(")) return .{ .refused = refused };
        const values_close = closingToken(tokens, close + 2, tokens.len) orelse return .{ .refused = refused };
        if (values_close != tokens.len - 1) return .{ .refused = refused };
        const values = argumentRanges(tokens, close + 2, values_close);
        if (values.len != columns.len) return .{ .refused = refused };
        if (lacked[0] == 0) return .{ .refused = "rsql: an INSERT's first column is on every engine" };
        var skips: []const [2]usize = &.{};
        for ([_][]const [2]usize{ columns, values }) |ranges| for (lacked) |position| {
            skips = skips ++ .{[2]usize{ ranges[position][0] - 1, ranges[position][1] }};
        };
        return .{ .skips = skips };
    }
}

/// The rows of the partial index `index` as MySQL states them for the row aliased `alias`: a seek on its
/// `_lead` column when it has one, otherwise its key part (`.unique_when`), otherwise its predicate.
fn inIndexMysql(comptime alias: []const u8, comptime index: schema.Index) []const u8 {
    comptime {
        const predicate = render(.mysql, qualify(alias, index.table, index.where.?));
        return switch (schema.mysqlIndexForm(index).?) {
            .leading => alias ++ "." ++ schema.leadingColumnName(index) ++ " IS NOT NULL",
            .unique_when => schema.mysqlKeyPart(predicate, alias ++ "." ++ columnName(index.columns[0])) ++ " IS NOT NULL",
            .plain_unique => "(" ++ predicate ++ ")",
        };
    }
}

fn columnName(comptime column: []const u8) []const u8 {
    return column[0 .. std.mem.indexOfScalar(u8, column, ' ') orelse column.len];
}

const MysqlRenderer = struct {
    text: []const u8,
    tokens: []const Token,
    skips: []const [2]usize = &.{},
    // The pieces of the part being rendered, joined once when a slot ends it.
    current: ComptimeList([]const u8) = .{},
    parts: ComptimeList([]const u8) = .{},
    slots: ComptimeList(Slot) = .{},
    message: []const u8 = "",

    fn emit(r: *MysqlRenderer, text: []const u8) void {
        if (text.len != 0) r.current.append(text);
    }

    fn endPart(r: *MysqlRenderer) void {
        r.parts.append(joinPieces(r.current.items()));
        r.current.len = 0;
    }

    fn slot(r: *MysqlRenderer, which: Slot) void {
        r.endPart();
        r.slots.append(which);
    }

    fn refuse(r: *MysqlRenderer, message: []const u8) error{Refused} {
        r.message = message;
        return error.Refused;
    }

    fn skipped(r: *const MysqlRenderer, at: usize) ?usize {
        for (r.skips) |skip| if (skip[0] == at) return skip[1];
        return null;
    }

    fn range(r: *MysqlRenderer, from: usize, to: usize) Refused!void {
        var at = from;
        while (at < to) {
            if (r.skipped(at)) |end| {
                at = end;
                continue;
            }
            if (at > from) {
                const previous = r.tokens[at - 1];
                r.emit(r.text[previous.start + previous.text.len .. r.tokens[at].start]);
            }
            at = try r.token(at, to);
        }
    }

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
                if (isCall(r.tokens, at, to)) {
                    const arguments = argumentRanges(r.tokens, at + 1, closingToken(r.tokens, at + 1, to).?).len;
                    const function = knownFunction(current.text, arguments) orelse return r.refuse(functionMessage(current.text, arguments));
                    r.emit(function.mysql ++ "(" ++ function.leading);
                    return at + 2;
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
        const arguments = argumentRanges(r.tokens, at + 1, end);
        if (std.mem.eql(u8, name, "in_index")) {
            if (arguments.len != 2 or arguments[0][1] != arguments[0][0] + 1 or arguments[1][1] != arguments[1][0] + 1) return r.refuse("rsql: @in_index takes an alias and an index name");
            const index = schema.partialIndex(r.tokens[arguments[1][0]].text) orelse return r.refuse("rsql: @in_index names no partial index " ++ r.tokens[arguments[1][0]].text);
            r.emit(comptime inIndexMysql(r.tokens[arguments[0][0]].text, index));
            return end + 1;
        }
        if (std.mem.eql(u8, name, "index") or std.mem.eql(u8, name, "session")) {
            if (arguments.len != 1) return r.refuse("rsql: @" ++ name ++ " takes 1 arguments");
            if (std.mem.eql(u8, name, "session")) try r.range(arguments[0][0], arguments[0][1]);
            if (std.mem.eql(u8, name, "index")) {
                if (arguments[0][1] != arguments[0][0] + 1 or r.tokens[arguments[0][0]].kind != .word) return r.refuse("rsql: @index takes one index name");
                const index_name = r.tokens[arguments[0][0]].text;
                if (schema.mysqlCanForceIndex(index_name)) r.emit("FORCE INDEX (" ++ index_name ++ ")");
            }
            return end + 1;
        }
        if (std.mem.eql(u8, name, "after")) {
            try r.after(arguments);
            return end + 1;
        }
        const kind = expressionMarker(name) orelse return r.refuse("rsql: unknown marker @" ++ name);
        if (arguments.len != kind.arity) return r.refuse(std.fmt.comptimePrint("rsql: @{s} takes {d} arguments", .{ name, kind.arity }));
        var from: usize = 0;
        for (kind.mysql, 0..) |byte, index| {
            if (byte > served_slots[0]) continue;
            r.emit(kind.mysql[from..index]);
            from = index + 1;
            switch (byte) {
                arg_a[0] => try r.range(arguments[0][0], arguments[0][1]),
                arg_b[0] => try r.range(arguments[1][0], arguments[1][1]),
                arg_set[0] => r.emit(try r.set(arguments[1])),
                served_slots[0] => for (std.enums.values(provider_name.Provider), 0..) |provider, position| {
                    if (position != 0) r.emit(",");
                    r.slot(.{ .served = provider });
                },
                else => unreachable,
            }
        }
        r.emit(kind.mysql[from..]);
        return end + 1;
    }

    fn after(r: *MysqlRenderer, arguments: []const [2]usize) Refused!void {
        if (arguments.len < 2 or arguments.len % 2 != 0) return r.refuse("rsql: @after takes k columns, then k parameters");
        const k = arguments.len / 2;
        if (k > 1) r.emit("(");
        for (0..k) |last| {
            if (last != 0) r.emit(" OR ");
            if (k > 1 and last != 0) r.emit("(");
            for (0..last) |i| {
                try r.range(arguments[i][0], arguments[i][1]);
                r.emit("=");
                try r.range(arguments[k + i][0], arguments[k + i][1]);
                r.emit(" AND ");
            }
            try r.range(arguments[last][0], arguments[last][1]);
            r.emit(">");
            try r.range(arguments[k + last][0], arguments[k + last][1]);
            if (k > 1 and last != 0) r.emit(")");
        }
        if (k > 1) r.emit(")");
    }

    fn set(r: *MysqlRenderer, argument: [2]usize) Refused![]const u8 {
        if (argument[1] != argument[0] + 1 or r.tokens[argument[0]].kind != .literal) return r.refuse("rsql: a character set is one quoted literal");
        return characterSet(r.tokens[argument[0]].text, r.text);
    }
};

fn isCall(comptime tokens: []const Token, comptime at: usize, comptime to: usize) bool {
    const word = tokens[at];
    if (word.kind != .word or isGrammarWord(word.text)) return false;
    if (at + 1 >= to or !tokens[at + 1].isSymbol("(")) return false;
    if (at > 0 and tokens[at - 1].is("INTO")) return false;
    const close = closingToken(tokens, at + 1, to) orelse return false;
    return !(close + 2 < to and tokens[close + 1].is("AS") and tokens[close + 2].isSymbol("("));
}

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

fn renderAfterSqlite(comptime arguments: []const []const u8, comptime text: []const u8) []const u8 {
    comptime {
        if (arguments.len < 2 or arguments.len % 2 != 0) @compileError("rsql: @after takes k columns, then k parameters: " ++ text);
        const k = arguments.len / 2;
        if (k == 1) return arguments[0] ++ ">" ++ arguments[1];
        var columns: []const u8 = "";
        var parameters: []const u8 = "";
        for (0..k) |i| {
            columns = columns ++ (if (i == 0) "" else ",") ++ arguments[i];
            parameters = parameters ++ (if (i == 0) "" else ",") ++ arguments[k + i];
        }
        return "(" ++ columns ++ ")>(" ++ parameters ++ ")";
    }
}

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

pub const Ordered = union(enum) {
    index: []const u8,
    primary_key: []const u8,
};

pub const Fixed = struct { column: []const u8, value: []const u8 };

pub const Arm = struct {
    on: Ordered,
    alias: []const u8,
    fixed: []const Fixed = &.{},
    columns: []const u8,
    joins: []const u8 = "",
};

pub const PageSpec = struct {
    arms: []const Arm,
    Row: type,
    take: u16,
};

pub const Walk = struct {
    pub const Arm = struct {
        table: []const u8,
        alias: []const u8,
        index: ?[]const u8,
        prefix: []const []const u8,
        key: []const []const u8,
        backward: bool,
    };
    names: []const []const u8,
    arms: []const Walk.Arm,
};

pub fn Page(comptime spec: PageSpec) type {
    const walk = comptime switch (keysetOf(spec)) {
        .refused => |message| @compileError(message),
        .walk => |walk| walk,
    };
    const text = comptime pageText(spec, walk);
    comptime if (pageError(text, walk)) |message| @compileError(message ++ ": " ++ text);
    const R = Read(.{
        .sql = text,
        .Args = KeyArgs(walk.names),
        .Row = spec.Row,
        .cardinality = .each,
        .compound = spec.arms.len > 1,
    });
    return struct {
        pub const kind = R.kind;
        pub const made_from = spec;
        pub const Args = R.Args;
        pub const Row = R.Row;
        pub const cardinality = R.cardinality;
        pub const Result = R.Result;
        pub const sql = R.sql;
        pub const mysql = R.mysql;
        pub const uses_now = R.uses_now;
        pub const single_row = R.single_row;

        pub const page_walk: Walk = walk;
        pub const take: u16 = spec.take;
        pub const limit: u16 = spec.take + 1;

        pub fn next(after: Args, row: *const Row) ?Args {
            var result: Args = .{ .session = after.session };
            var order: std.math.Order = .eq;
            inline for (walk.names) |name| {
                const value = keyValue(@field(row.*, name));
                @field(result, name) = value;
                if (order == .eq) order = std.math.order(value, @field(after, name));
            }
            return if (order == .gt) result else null;
        }
    };
}

fn keyValue(value: anytype) u64 {
    return if (@TypeOf(value) == Positive) value.get() else value;
}

pub fn pageSpecError(comptime spec: PageSpec) ?[]const u8 {
    comptime {
        const walk = switch (keysetOf(spec)) {
            .refused => |message| return message,
            .walk => |walk| walk,
        };
        const text = pageText(spec, walk);
        if (pageError(text, walk)) |message| return message;
        return switch (check(.read, text, KeyArgs(walk.names), spec.Row, spec.arms.len > 1)) {
            .refused => |message| message,
            .accepted => null,
        };
    }
}

const Keyset = union(enum) { refused: []const u8, walk: Walk };

const Walked = struct { table: []const u8, index: ?[]const u8, columns: []const []const u8, where: ?[]const u8 };

fn walkedBy(comptime on: Ordered) union(enum) { refused: []const u8, walked: Walked } {
    switch (on) {
        .index => |name| {
            for (schema.indexes) |index| if (std.mem.eql(u8, index.name, name))
                return .{ .walked = .{ .table = index.table, .index = name, .columns = index.columns, .where = index.where } };
            return .{ .refused = "rsql: a Page walks an index of the schema, and there is none named " ++ name };
        },
        .primary_key => |name| {
            for (schema.tables) |table| if (std.mem.eql(u8, table.name, name)) {
                if (!table.without_rowid) return .{ .refused = "rsql: a Page walks the primary key only of a WITHOUT ROWID table, and " ++ name ++ " has rowids" };
                return .{ .walked = .{ .table = name, .index = null, .columns = table.primary_key, .where = null } };
            };
            return .{ .refused = "rsql: no table named " ++ name };
        },
    }
}

fn schemaColumn(comptime table: []const u8, comptime name: []const u8) ?schema.Column {
    for (schema.tables) |candidate| if (std.mem.eql(u8, candidate.name, table)) {
        for (candidate.columns) |column| if (std.mem.eql(u8, column.name, name)) return column;
    };
    return null;
}

fn states(comptime predicate: ?[]const u8, comptime term: []const u8) bool {
    var terms = std.mem.splitSequence(u8, predicate orelse return false, " AND ");
    while (terms.next()) |conjunct| if (std.mem.eql(u8, std.mem.trim(u8, conjunct, " "), term)) return true;
    return false;
}

fn keysetOf(comptime spec: PageSpec) Keyset {
    comptime {
        @setEvalBranchQuota(100_000);
        if (spec.arms.len == 0) return .{ .refused = "rsql: a Page has at least one arm" };
        if (spec.take == 0) return .{ .refused = "rsql: a Page takes at least one row" };
        var arms: []const Walk.Arm = &.{};
        for (spec.arms) |arm| {
            const walked = switch (walkedBy(arm.on)) {
                .refused => |message| return .{ .refused = message },
                .walked => |walked| walked,
            };
            const after_prefix = 1 + arm.fixed.len;
            if (walked.columns.len <= after_prefix) return .{ .refused = "rsql: a Page's index has key columns after its Session column and fixed columns: " ++ (walked.index orelse walked.table) };
            for (arm.fixed, 1..) |fixed, i| if (!std.mem.eql(u8, fixed.column, walked.columns[i]))
                return .{ .refused = "rsql: a Page's fixed columns are its index's columns after the first, in order, and " ++ fixed.column ++ " is not" };
            var key: []const []const u8 = &.{};
            var descending: ?bool = null;
            for (walked.columns[after_prefix..], 0..) |written, k| {
                const desc = std.mem.endsWith(u8, written, " DESC");
                const name = if (desc) written[0 .. written.len - " DESC".len] else written;
                if (descending) |previous| if (previous != desc) return .{ .refused = "rsql: a Page's key is all ascending or all descending" };
                descending = desc;
                const column = schemaColumn(walked.table, name) orelse return .{ .refused = "rsql: no column " ++ name ++ " in " ++ walked.table };
                if (column.type != .int) return .{ .refused = "rsql: a Page's key columns are integers, and " ++ name ++ " is not" };
                if (k > 0 and column.nullable and !states(walked.where, name ++ " IS NOT NULL"))
                    return .{ .refused = "rsql: a Page's key column after the first is NOT NULL, or its index's predicate states it, and " ++ name ++ " is neither" };
                key = key ++ .{name};
            }
            if (arms.len > 0 and key.len != arms[0].key.len) return .{ .refused = "rsql: every arm of a Page has a key of one length" };
            arms = arms ++ .{Walk.Arm{
                .table = walked.table,
                .alias = arm.alias,
                .index = walked.index,
                .prefix = walked.columns[0..after_prefix],
                .key = key,
                .backward = descending.?,
            }};
        }
        const key_names = arms[0].key;
        const info = @typeInfo(spec.Row).@"struct";
        if (info.field_types.len < key_names.len) return .{ .refused = "rsql: a Page's Row starts with its key" };
        for (info.field_types[0..key_names.len], 0..) |Field, k| {
            if (k == 0 and Field != Positive) return .{ .refused = "rsql: a Page's Row starts with its first key column, a Positive, so the zero key is before every row" };
            if (Field != Positive and Field != u64) return .{ .refused = "rsql: a Page's key fields are Positive or u64" };
        }
        return .{ .walk = .{ .names = key_names, .arms = arms } };
    }
}

fn pageText(comptime spec: PageSpec, comptime walk: Walk) []const u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        var text: []const u8 = "";
        for (spec.arms, walk.arms, 0..) |arm, path, i| {
            const a = arm.alias;
            text = text ++ (if (i == 0) "SELECT " else " UNION ALL SELECT ");
            for (path.key, walk.names, 0..) |column, name, k| text = text ++ (if (k == 0) "" else ",") ++ a ++ "." ++ column ++ " AS " ++ name;
            if (arm.columns.len != 0) text = text ++ "," ++ arm.columns;
            text = text ++ " FROM " ++ path.table ++ " " ++ a;
            if (path.index) |index| text = text ++ " @index(" ++ index ++ ")";
            const joins = std.mem.trim(u8, arm.joins, " ");
            if (joins.len != 0) text = text ++ " " ++ joins;
            text = text ++ " WHERE " ++ a ++ "." ++ path.prefix[0] ++ "=?1";
            for (arm.fixed) |fixed| text = text ++ " AND " ++ a ++ "." ++ fixed.column ++ "=" ++ fixed.value;
            const walked = walkedBy(arm.on).walked;
            if (walked.where) |where| text = text ++ " AND " ++ qualify(a, path.table, where);
            text = text ++ " AND @after(";
            for (path.key) |column| text = text ++ a ++ "." ++ column ++ ",";
            for (1..path.key.len + 1) |k| text = text ++ std.fmt.comptimePrint("?{d}", .{k + 1}) ++ (if (k == path.key.len) ")" else ",");
        }
        text = text ++ " ORDER BY ";
        for (walk.names, 0..) |name, k| text = text ++ (if (k == 0) "" else ",") ++ name;
        return text ++ std.fmt.comptimePrint(" LIMIT {d}", .{@as(u32, spec.take) + 1});
    }
}

fn qualify(comptime alias: []const u8, comptime table: []const u8, comptime predicate: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(100 * predicate.len + 10_000);
        var out: []const u8 = "";
        var start: usize = 0;
        var index: usize = 0;
        var any_or = false;
        while (index < predicate.len) {
            const byte = predicate[index];
            if (byte == '\'') {
                index = literalEnd(predicate, index);
                continue;
            }
            if (std.ascii.isDigit(byte)) {
                index = wordEnd(predicate, index);
                continue;
            }
            if (!isWordStart(byte)) {
                index += 1;
                continue;
            }
            const end = wordEnd(predicate, index);
            const word = predicate[index..end];
            if (std.ascii.eqlIgnoreCase(word, "OR")) any_or = true;
            const after_dot_or_marker = index > 0 and (predicate[index - 1] == '.' or predicate[index - 1] == '@');
            const called = end < predicate.len and (predicate[end] == '(' or predicate[end] == '.');
            if (!after_dot_or_marker and !called and schema.hasColumn(table, word)) {
                out = out ++ predicate[start..index] ++ alias ++ "." ++ word;
                start = end;
            }
            index = end;
        }
        const qualified = out ++ predicate[start..];
        return if (any_or) "(" ++ qualified ++ ")" else qualified;
    }
}

fn KeyArgs(comptime key: []const []const u8) type {
    var field_names: [key.len + 1][]const u8 = undefined;
    var types: [key.len + 1]type = undefined;
    var attrs: [key.len + 1]std.lang.Type.Struct.FieldAttributes = @splat(.{});
    field_names[0] = "session";
    types[0] = []const u8;
    const zero: u64 = 0;
    for (key, 1..) |name, i| {
        field_names[i] = name;
        types[i] = u64;
        attrs[i] = .{ .default_value_ptr = &zero };
    }
    return @Struct(.auto, null, &field_names, &types, &attrs);
}

fn pageError(comptime text: []const u8, comptime walk: Walk) ?[]const u8 {
    comptime {
        const parsed = switch (parse(text)) {
            .refused => |message| return message,
            .accepted => |parsed| parsed,
        };
        var arm: usize = 0;
        for (parsed.queries) |query| if (query.parent == null) {
            if (arm == walk.arms.len) return "rsql: a Page's text has a SELECT for each arm, and no more";
            const path = walk.arms[arm];
            const first = query.sources[0];
            const same_index = if (path.index) |index| first.index != null and std.mem.eql(u8, first.index.?, index) else first.index == null;
            if (!std.mem.eql(u8, first.table, path.table) or !std.mem.eql(u8, first.alias, path.alias) or !same_index)
                return "rsql: a Page's arm reads its walked table first, under its walked index";
            for (query.sources[1..]) |source| if (source.join != .left)
                return "rsql: a Page's joins are LEFT JOINs, so every row of its walked range is a row of the list";
            arm += 1;
        };
        if (arm != walk.arms.len) return "rsql: a Page's text has a SELECT for each arm";
        return null;
    }
}

test "each marker renders its SQLite spelling" {
    try std.testing.expectEqualStrings("length(CAST(workspace AS BLOB))<=4096", comptime render(.sqlite, "@octets(workspace)<=4096"));
    try std.testing.expectEqualStrings("(provider NOT GLOB '*[^a-z0-9_-]*' AND length(provider)=length(CAST(provider AS BLOB)))", comptime render(.sqlite, "@charset(provider,'a-z0-9_-')"));
    try std.testing.expectEqualStrings("provider GLOB '[a-z]*'", comptime render(.sqlite, "@initial(provider,'a-z')"));
    try std.testing.expectEqualStrings("(action_kind IS 1)", comptime render(.sqlite, "@same(action_kind,1)"));
    try std.testing.expectEqualStrings("(resolution_code IS NOT 'denied')", comptime render(.sqlite, "@distinct(resolution_code,'denied')"));
    try std.testing.expectEqualStrings("count(*) FILTER (WHERE a.authorized=0 AND (x IS 1))", comptime render(.sqlite, "@count_where(a.authorized=0 AND @same(x,1))"));
    try std.testing.expectEqualStrings("max(a.decided_at) FILTER (WHERE r.permission_mode=0)", comptime render(.sqlite, "@max_where(a.decided_at,r.permission_mode=0)"));
    try std.testing.expectEqualStrings("group_concat(tool.name,',')", comptime render(.sqlite, "@list(tool.name)"));
}

test "canonical form classification keeps filtered count portable inside an aggregate case" {
    const text = "SELECT CASE WHEN @count_where(c.form<>0)=0 THEN coalesce(sum(c.byte_length),0) END AS bytes FROM content c";
    try std.testing.expectEqual(@as(?[]const u8, null), comptime statementError(.read, text, struct {}, struct { bytes: ?u64 }));
    try std.testing.expectEqualStrings(
        "SELECT CASE WHEN count(*) FILTER (WHERE c.form<>0)=0 THEN coalesce(sum(c.byte_length),0) END AS bytes FROM content c",
        comptime render(.sqlite, text),
    );
    try std.testing.expectEqualStrings(
        "SELECT CASE WHEN count(CASE WHEN c.form<>0 THEN 1 END)=0 THEN coalesce(sum(c.byte_length),0) END AS bytes FROM content c",
        comptime render(.mysql, text),
    );
}

fn repeated(comptime text: []const u8, comptime times: usize) []const u8 {
    comptime {
        var out: [text.len * times]u8 = undefined;
        for (0..times) |index| @memcpy(out[index * text.len ..][0..text.len], text);
        const final = out;
        return &final;
    }
}

test "SH-90 a statement renders the same SQLite and MySQL text whatever its pieces" {
    const Reordered = Write(.{
        .sql = "UPDATE turn SET outcome_at=@now WHERE turn_id=?2 AND session_ref=@session(?1) AND operation_id>?2",
        .Args = struct { session: SessionHead, turn_id: u64 },
        .expect = .{ .at_most = 1 },
    });
    const Indexed = Read(.{
        .sql = "SELECT action_id FROM action_operation @index(action_operation_executable) WHERE action_id>?1",
        .Args = struct { after: u64 },
        .Row = struct { action_id: Positive },
        .cardinality = .optional,
    });
    const Quoted = Read(.{
        .sql = "SELECT content_id FROM content WHERE content_id=?1 AND digest<>'@now @octets(x) ?2'",
        .Args = struct { content_id: u64 },
        .Row = struct { content_id: Positive },
        .cardinality = .optional,
    });
    const nested = "x IS NULL OR (@same(@octets(x),6) AND @count_where(@charset(x,'a-f'))=1) AND '@octets(y)'='@'";
    const long_text = "@same(a,1)" ++ comptime repeated(" OR @same(a,1)", 80);
    const Case = struct { sqlite: []const u8, mysql: []const u8, slots: []const Slot, want_sqlite: []const u8, want_mysql: []const u8, want_slots: []const Slot };
    const cases = [_]Case{
        // Repeated and reordered parameters, @now after the Args, @session as its parameter.
        .{
            .sqlite = Reordered.sql,
            .mysql = comptime Reordered.mysql.prepared(),
            .slots = Reordered.mysql.slots,
            .want_sqlite = "UPDATE turn SET outcome_at=?3 WHERE turn_id=?2 AND session_ref=?1 AND operation_id>?2",
            .want_mysql = "UPDATE turn SET outcome_at=? WHERE turn_id=? AND session_ref=? AND operation_id>?",
            .want_slots = &.{ .now, .{ .argument = 1 }, .{ .argument = 0 }, .{ .argument = 1 } },
        },
        // @index is INDEXED BY on SQLite; MySQL drops an index it cannot force.
        .{
            .sqlite = Indexed.sql,
            .mysql = comptime Indexed.mysql.prepared(),
            .slots = Indexed.mysql.slots,
            .want_sqlite = "SELECT action_id FROM action_operation INDEXED BY action_operation_executable WHERE action_id>?1",
            .want_mysql = "SELECT action_id FROM action_operation  WHERE action_id>?",
            .want_slots = &.{.{ .argument = 0 }},
        },
        // Marker and parameter text inside a string literal stays text.
        .{
            .sqlite = Quoted.sql,
            .mysql = comptime Quoted.mysql.prepared(),
            .slots = Quoted.mysql.slots,
            .want_sqlite = "SELECT content_id FROM content WHERE content_id=?1 AND digest<>'@now @octets(x) ?2'",
            .want_mysql = "SELECT content_id FROM content WHERE content_id=? AND digest<>'@now @octets(x) ?2'",
            .want_slots = &.{.{ .argument = 0 }},
        },
        // Nested markers beside text and a quoted marker, which are copied.
        .{
            .sqlite = comptime render(.sqlite, nested),
            .mysql = comptime render(.mysql, nested),
            .slots = &.{},
            .want_sqlite = "x IS NULL OR ((length(CAST(x AS BLOB)) IS 6) AND count(*) FILTER (WHERE (x NOT GLOB '*[^a-f]*' AND length(x)=length(CAST(x AS BLOB))))=1) AND '@octets(y)'='@'",
            .want_mysql = "x IS NULL OR ((OCTET_LENGTH(x) <=> 6) AND count(CASE WHEN (NOT REGEXP_LIKE(x,'[^a-f]','c')) THEN 1 END)=1) AND '@octets(y)'='@'",
            .want_slots = &.{},
        },
        // The empty text.
        .{ .sqlite = comptime render(.sqlite, ""), .mysql = comptime render(.mysql, ""), .slots = &.{}, .want_sqlite = "", .want_mysql = "", .want_slots = &.{} },
        // A text over 1 KB of markers.
        .{
            .sqlite = comptime render(.sqlite, long_text),
            .mysql = comptime render(.mysql, long_text),
            .slots = &.{},
            .want_sqlite = "(a IS 1)" ++ comptime repeated(" OR (a IS 1)", 80),
            .want_mysql = "(a <=> 1)" ++ comptime repeated(" OR (a <=> 1)", 80),
            .want_slots = &.{},
        },
    };
    for (cases) |case| {
        try std.testing.expectEqualStrings(case.want_sqlite, case.sqlite);
        try std.testing.expectEqualStrings(case.want_mysql, case.mysql);
        try std.testing.expectEqualDeep(case.want_slots, case.slots);
    }
}

test "each marker renders its MySQL spelling" {
    try std.testing.expectEqualStrings("OCTET_LENGTH(workspace)<=4096", comptime render(.mysql, "@octets(workspace)<=4096"));
    try std.testing.expectEqualStrings("(NOT REGEXP_LIKE(provider,'[^a-z0-9_-]','c'))", comptime render(.mysql, "@charset(provider,'a-z0-9_-')"));
    try std.testing.expectEqualStrings("REGEXP_LIKE(provider,'^[a-z]','c')", comptime render(.mysql, "@initial(provider,'a-z')"));
    try std.testing.expectEqualStrings("(action_kind <=> 1)", comptime render(.mysql, "@same(action_kind,1)"));
    try std.testing.expectEqualStrings("(NOT (resolution_code <=> 'denied'))", comptime render(.mysql, "@distinct(resolution_code,'denied')"));
    try std.testing.expectEqualStrings("count(CASE WHEN a.authorized=0 AND (x <=> 1) THEN 1 END)", comptime render(.mysql, "@count_where(a.authorized=0 AND @same(x,1))"));
    try std.testing.expectEqualStrings("max(CASE WHEN r.permission_mode=0 THEN a.decided_at END)", comptime render(.mysql, "@max_where(a.decided_at,r.permission_mode=0)"));
    try std.testing.expectEqualStrings("GROUP_CONCAT(tool.name SEPARATOR ',')", comptime render(.mysql, "@list(tool.name)"));
    try std.testing.expectEqualStrings("GREATEST(a, b)>LEAST(c,d) AND max(e)=1 AND f='@octets(g)'", comptime render(.mysql, "max(a, b)>min(c,d) AND max(e)==1 AND f='@octets(g)'"));
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

test "@payload is content's payload on SQLite and its one chunk on MySQL" {
    const S = Read(.{
        .sql = "SELECT (SELECT @payload(content) FROM content WHERE content_id=t.outcome_content_id AND byte_length<=512) AS bytes FROM turn t WHERE t.turn_id=?1",
        .Args = struct { turn_id: u64 },
        .Row = struct { bytes: ?Blob(512) },
        .cardinality = .optional,
    });
    try std.testing.expectEqualStrings("SELECT (SELECT content.payload FROM content WHERE content_id=t.outcome_content_id AND byte_length<=512) AS bytes FROM turn t WHERE t.turn_id=?1", S.sql);
    try std.testing.expectEqualStrings(
        "SELECT (SELECT coalesce((SELECT bytes FROM content_chunk WHERE content_chunk.content_id=content.content_id AND content_chunk.chunk_index=0),X'') " ++
            "FROM content WHERE content_id=t.outcome_content_id AND byte_length<=512) AS bytes FROM turn t WHERE t.turn_id=?",
        comptime S.mysql.prepared(),
    );
}

test "MySQL's INSERT leaves out the columns only other engines have, with their values" {
    const W = Write(.{
        .sql = "INSERT INTO content(content_id,digest,byte_length,payload,private) VALUES(?1,?2,?3,zeroblob(?3),?4)",
        .Args = struct { content_id: u64, digest: [32]u8, length: u64, private: bool },
        .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
    });
    try std.testing.expectEqualStrings("INSERT INTO content(content_id,digest,byte_length,payload,private) VALUES(?1,?2,?3,zeroblob(?3),?4)", W.sql);
    try std.testing.expectEqualStrings("INSERT INTO content(content_id,digest,byte_length,private) VALUES(?,?,?,?)", comptime W.mysql.prepared());
    try std.testing.expectEqualDeep(@as([]const Slot, &.{ .{ .argument = 0 }, .{ .argument = 1 }, .{ .argument = 2 }, .{ .argument = 3 } }), W.mysql.slots);
    try std.testing.expectEqualStrings("INSERT INTO content(content_id,private) VALUES(1,0)", comptime mysqlRendering("INSERT INTO content(content_id,payload,private) VALUES(1,X'00',0)").rendered.parts[0]);
    try std.testing.expectEqualStrings("INSERT INTO content(content_id) VALUES(1)", comptime mysqlRendering("INSERT INTO content(content_id,payload) VALUES(1,X'')").rendered.parts[0]);
    try std.testing.expectEqualStrings(
        "rsql: an INSERT names a column MySQL's schema lacks, so it writes one row of VALUES",
        comptime mysqlRendering("INSERT INTO content(content_id,payload) SELECT content_id,X'' FROM content").refused,
    );
    try std.testing.expectEqualStrings("rsql: an INSERT's first column is on every engine", comptime mysqlRendering("INSERT INTO content(payload,content_id) VALUES(X'',1)").refused);
}

test "a typed DELETE builds only into tests (D202)" {
    const parsed = comptime accepted(.write, "DELETE FROM content WHERE content_id=?1", struct { content_id: u64 }, void, false);
    try std.testing.expectEqualStrings("rsql: the Store's MySQL login may not DELETE (D202); only tests delete", comptime deleteError(parsed.statement, false).?);
    try std.testing.expectEqual(@as(?[]const u8, null), comptime deleteError(parsed.statement, true));
    const update = comptime accepted(.write, "UPDATE content SET private=1 WHERE content_id=?1", struct { content_id: u64 }, void, false);
    try std.testing.expectEqual(@as(?[]const u8, null), comptime deleteError(update.statement, false));
}

test "a statement calls only the functions every engine spells, by argument count, and no CAST" {
    const Seq = struct { created_seq: u64 };
    try std.testing.expectEqualStrings(
        "rsql: no function rui_served of 1 arguments; Rui SQL calls only `functions`",
        comptime statementError(.read, "SELECT created_seq FROM session WHERE rui_served(provider)=1", struct {}, Seq).?,
    );
    try std.testing.expectEqualStrings(
        "rsql: no function max of 3 arguments; Rui SQL calls only `functions`",
        comptime statementError(.read, "SELECT created_seq FROM session WHERE max(created_seq,1,2)>0", struct {}, Seq).?,
    );
    try std.testing.expectEqualStrings(
        "rsql: CAST converts differently on each engine",
        comptime statementError(.read, "SELECT created_seq FROM session WHERE CAST(provider AS BLOB)=1", struct {}, Seq).?,
    );
    try std.testing.expectEqual(@as(?[]const u8, null), comptime statementError(.read, "SELECT created_seq FROM session WHERE created_seq BETWEEN 1 AND 2", struct {}, Seq));
    try std.testing.expectEqualStrings("payload=REPEAT(X'00',byte_length)", comptime render(.mysql, "payload=zeroblob(byte_length)"));
    try std.testing.expectEqualStrings("substr(content.payload,1,1024)", comptime render(.sqlite, "substr(@payload(content),1,1024)"));
    try std.testing.expectEqualStrings("SUBSTRING(coalesce((SELECT bytes FROM content_chunk WHERE content_chunk.content_id=content.content_id AND content_chunk.chunk_index=0),X''),1,1024)", comptime render(.mysql, "substr(@payload(content),1,1024)"));
    const text = "INSERT INTO turn(turn_id) WITH recent(turn_id) AS (SELECT count(*) AS n FROM turn) SELECT turn_id FROM recent";
    try std.testing.expectEqualStrings(text, comptime mysqlRendering(text).rendered.parts[0]);
}

test "SH-92: a statement or fixture serves its table entry only while its text, signature and the table's inputs all match" {
    const text = "SELECT next_position FROM session WHERE session_ref=?1";
    const written = "UPDATE session SET prefix_seal=?2 WHERE session_ref=@session(?1)";
    const Args = struct { session: []const u8 };
    const Row = struct { next_position: Positive };
    const WriteArgs = struct { session: SessionHead, position: u64 };
    const entry = struct {
        fn of(comptime checked: []const u8, comptime shape: Shape) TableEntry {
            return .{
                .variants = &.{.{ .signature = checked, .sqlite = "SERVED FROM THE TABLE" }},
                .mysql = .{ .parts = &.{ "SERVED", "FROM THE TABLE" }, .slots = &.{.now} },
                .facts = .{ .uses_now = true, .shape = shape, .single_row = shape == .select_one },
            };
        }
    };
    const Table = struct {
        fn of(comptime fingerprint: []const u8, comptime read_signature: []const u8, comptime write_signature: []const u8) type {
            return struct {
                pub const inputs = fingerprint;
                pub const entries = struct {
                    pub const @"SELECT next_position FROM session WHERE session_ref=?1": TableEntry = entry.of(read_signature, .select);
                    pub const @"UPDATE session SET prefix_seal=?2 WHERE session_ref=@session(?1)": TableEntry = entry.of(write_signature, .insert_row);
                };
                pub const fixtures = struct {
                    pub const @"UPDATE session SET next_position=?1 WHERE session_ref=?2": Template = .{ .parts = &.{ "SERVED", "FROM THE TABLE" }, .slots = &.{.now} };
                };
            };
        }
    };
    const current = @import("build_options").rsql_inputs;
    const Schema = struct {};
    const schema_tables = .{
        .{ struct {
            pub const inputs = current;
            pub const schema = Schema;
        }, true },
        .{ struct {
            pub const inputs = current ++ "0";
            pub const schema = Schema;
        }, false },
        .{ struct {
            pub const inputs = current;
        }, false },
    };
    inline for (schema_tables) |case| {
        const served = comptime generatedSchemaFrom(case[0]);
        if (case[1]) {
            try std.testing.expect(served != null);
            try std.testing.expect(served.? == Schema);
        } else {
            try std.testing.expect(served == null);
        }
    }
    const cases = .{
        // table, statements served, fixture served (a fixture has no signature: text and inputs decide)
        .{ Table.of(current, "r0:.:next_position,", "w0:H."), true, true },
        .{ Table.of(current ++ "0", "r0:.:next_position,", "w0:H."), false, false },
        .{ Table.of(current, "r0:.:other,", "w0:.."), false, true },
        .{ Table.of(current, "r1:.:next_position,", "w0:H"), false, true },
        .{ struct {
            pub const inputs = current;
            pub const entries = struct {};
            pub const fixtures = struct {
                pub const @"UPDATE session SET next_position=?1 WHERE session_ref=?3": Template = .{ .parts = &.{ "SERVED", "FROM THE TABLE" }, .slots = &.{.now} };
            };
        }, false, false },
    };
    inline for (cases) |case| {
        const R = ReadFrom(case[0], .{ .sql = text, .Args = Args, .Row = Row, .cardinality = .optional });
        const W = WriteFrom(case[0], .{ .sql = written, .Args = WriteArgs, .expect = .{ .at_most = 1 } });
        const fixture = comptime fixtureFrom(case[0], "UPDATE session SET next_position=?1 WHERE session_ref=?2").rendered;
        if (case[1]) {
            try std.testing.expectEqualStrings("SERVED FROM THE TABLE", R.sql);
            try std.testing.expectEqualStrings("SERVED?FROM THE TABLE", comptime R.mysql.prepared());
            try std.testing.expect(R.uses_now and !R.single_row);
            try std.testing.expectEqualStrings("SERVED FROM THE TABLE", W.sql);
            try std.testing.expect(W.uses_now and !W.guarded);
        } else {
            try std.testing.expectEqualStrings("SELECT next_position FROM session WHERE session_ref=?1", R.sql);
            try std.testing.expectEqualStrings("SELECT next_position FROM session WHERE session_ref=?", comptime R.mysql.prepared());
            try std.testing.expect(!R.uses_now and R.single_row);
            try std.testing.expectEqualStrings("UPDATE session SET prefix_seal=?2 WHERE session_ref=?1", W.sql);
            try std.testing.expect(!W.uses_now and W.guarded);
        }
        try std.testing.expectEqualStrings(if (case[2]) "SERVED?FROM THE TABLE" else "UPDATE session SET next_position=? WHERE session_ref=?", comptime fixture.prepared());
    }
}

test "fixture SQL meets the Store's own grammar, so MySQL takes what the build takes" {
    const written_read = "rsql: MySQL refuses a write whose subquery reads the table it writes (error 1093); read the value first and bind it";
    try std.testing.expectEqualStrings(written_read, comptime fixtureError("UPDATE session SET loaded_tool_set_id=(SELECT tool_set_id FROM session WHERE session_ref=?1) WHERE session_ref=?2").?);
    try std.testing.expectEqualStrings(written_read, comptime fixtureError("UPDATE message_admission SET admitted_at=2000 WHERE admission_id=(SELECT max(admission_id) FROM message_admission)").?);
    try std.testing.expectEqualStrings(written_read, comptime fixtureError("INSERT INTO core_command(command_key,command_seq) VALUES(?1,(SELECT coalesce(max(command_seq),0)+1 FROM core_command))").?);
    try std.testing.expectEqualStrings(written_read, comptime fixtureError("DELETE FROM turn WHERE turn_id IN (SELECT turn_id FROM turn)").?);
    try std.testing.expectEqualStrings(
        "rsql: MySQL takes WITH only after INSERT INTO t(columns); write INSERT INTO t(columns) WITH ... SELECT",
        comptime fixtureError("WITH RECURSIVE sequence(value) AS (SELECT 1 UNION ALL SELECT value+1 FROM sequence WHERE value<2) INSERT INTO turn(turn_id) SELECT value FROM sequence").?,
    );
    try std.testing.expectEqualStrings("rsql: CAST converts differently on each engine", comptime fixtureError("SELECT CAST(meta_value AS INTEGER) FROM store_meta WHERE meta_key='format'").?);
    try std.testing.expectEqualStrings("rsql: expected SELECT at 'VALUES'", comptime fixtureError("WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<2) SELECT value FROM sequence").?);
    try std.testing.expectEqualStrings("rsql: X'...' holds an even count of hex digits", comptime fixtureError("SELECT count(*) FROM content WHERE payload=X'ABC'").?);
    try std.testing.expectEqual(@as(?[]const u8, null), comptime fixtureError("INSERT INTO turn(turn_id) WITH RECURSIVE sequence(value) AS (SELECT 1 UNION ALL SELECT value+1 FROM sequence WHERE value<2) SELECT value FROM sequence"));
    try std.testing.expectEqual(@as(?[]const u8, null), comptime fixtureError("INSERT INTO model_operation(operation_id,turn_id) SELECT 100+operation_id,turn_id FROM model_operation WHERE operation_id=?1"));
    try std.testing.expectEqual(@as(?[]const u8, null), comptime fixtureError("UPDATE session SET next_position=next_position+1; DELETE FROM action_operation"));
    try std.testing.expectEqual(@as(?[]const u8, null), comptime fixtureError("UPDATE content_chunk SET bytes=zeroblob(length(bytes)) WHERE content_id=1"));
    try std.testing.expectEqual(@as(?[]const u8, null), comptime fixtureError("SELECT count(*) FROM content WHERE payload=X'0A0b'"));
    try std.testing.expectEqualStrings(length_message, comptime fixtureError("UPDATE session SET workspace=zeroblob(length(workspace))").?);
}

test "a served slot never binds NULL, so NOT @served(x) agrees with rui_served" {
    const sqlite = @import("sqlite.zig");
    const c = sqlite.c;
    const text = comptime mysqlRendering("SELECT NOT @served(?1)").rendered.prepared();
    comptime var list: []const u8 = "?";
    inline for (std.enums.values(provider_name.Provider)[1..]) |_| list = list ++ ",?";
    try std.testing.expectEqualStrings("SELECT NOT (? IN (" ++ list ++ "))", text);
    var database: ?*c.sqlite3 = null;
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_open(":memory:", &database));
    defer _ = c.sqlite3_close(database);
    const statement = try sqlite.prepare(database.?, text);
    defer _ = c.sqlite3_finalize(statement);
    const providers = comptime std.enums.values(provider_name.Provider);
    for (providers) |served_one| for (providers) |x| {
        _ = c.sqlite3_reset(statement);
        try sqlite.bindText(statement, 1, @tagName(x));
        for (providers, 2..) |provider, index| try sqlite.bindText(statement, @intCast(index), servedBinding(provider, provider == served_one));
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(statement));
        try std.testing.expectEqual(c.SQLITE_INTEGER, c.sqlite3_column_type(statement, 0));
        try std.testing.expectEqual(@as(i64, @intFromBool(x != served_one)), c.sqlite3_column_int64(statement, 0));
    };
    _ = c.sqlite3_reset(statement);
    try sqlite.bindText(statement, 1, @tagName(providers[0]));
    for (2..providers.len + 2) |index| _ = c.sqlite3_bind_null(statement, @intCast(index));
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(statement));
    try std.testing.expectEqual(c.SQLITE_NULL, c.sqlite3_column_type(statement, 0));
}

test "MySQL expands @after, since it seeks only a row value's equality prefix" {
    try std.testing.expectEqualStrings("SELECT 1 WHERE c.a>?", comptime mysqlRendering("SELECT 1 WHERE @after(c.a,?2)").rendered.prepared());
    try std.testing.expectEqualStrings("SELECT 1 WHERE (c.a>? OR (c.a=? AND c.b>?))", comptime mysqlRendering("SELECT 1 WHERE @after(c.a,c.b,?2,?3)").rendered.prepared());
    const three = comptime mysqlRendering("SELECT 1 WHERE @after(a,b,c,?1,?2,?3)").rendered;
    try std.testing.expectEqualStrings("SELECT 1 WHERE (a>? OR (a=? AND b>?) OR (a=? AND b=? AND c>?))", comptime three.prepared());
    var arguments: [6]usize = undefined;
    var count: usize = 0;
    for (three.slots) |slot| switch (slot) {
        .argument => |k| {
            arguments[count] = k;
            count += 1;
        },
        else => unreachable,
    };
    try std.testing.expectEqualSlices(usize, &.{ 0, 0, 1, 0, 1, 2 }, arguments[0..count]);
}

test "MySQL rendering divides integers with DIV" {
    try std.testing.expectEqualStrings("(mask DIV 2)%2=1", comptime render(.mysql, "(mask/2)%2=1"));
}

test "a schema expression meets a statement's rules, and length() counts only a .bytes column" {
    const bytes: []const []const u8 = &.{"payload"};
    try std.testing.expectEqual(@as(?[]const u8, null), comptime expressionError("length(payload)=byte_length AND kind BETWEEN 1 AND 5", bytes));
    try std.testing.expectEqualStrings("rsql: length() counts characters of text on SQLite and bytes on MySQL; write @octets(x)", comptime expressionError("length(label)<=8", bytes).?);
    try std.testing.expectEqualStrings("rsql: no function ifnull of 2 arguments; Rui SQL calls only `functions`", comptime expressionError("ifnull(label,'')<>''", bytes).?);
    try std.testing.expectEqualStrings("rsql: CAST converts differently on each engine", comptime expressionError("CAST(label AS BLOB)=x", bytes).?);
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

test "only a type Read, Write or Page made counts as a typed statement" {
    const Real = Read(.{ .sql = "SELECT content_id FROM content WHERE content_id=?1", .Args = struct { content_id: u64 }, .Row = struct { content_id: Positive }, .cardinality = .optional });
    const Written = Write(.{ .sql = "UPDATE turn SET outcome_at=@now WHERE turn_id=?1 AND session_ref=@session(?2)", .Args = struct { turn_id: u64, session: SessionHead }, .expect = .{ .at_most = 1 } });
    try std.testing.expect(comptime isStatement(Real));
    try std.testing.expect(comptime isStatement(Written));
    try std.testing.expect(comptime isStatement(TestCalls));
    const Projection = ObligationProjection(.{
        .sql = "SELECT session_ref,obligation_since AS saved_since,obligation_since AS owed_since FROM session WHERE session_ref=?1 UNION SELECT session_ref,obligation_since AS saved_since,obligation_since AS owed_since FROM session WHERE session_ref=?1",
        .Args = struct { session: []const u8 },
    });
    try std.testing.expect(comptime isStatement(Projection));
    try std.testing.expect(std.mem.startsWith(u8, Projection.sql, "UPDATE session SET obligation_since="));
    try std.testing.expect(std.mem.indexOf(u8, Projection.sql, "IS NOT") != null);
    try std.testing.expectEqual(@as(usize, 0), Projection.session_fields.len);
    try std.testing.expect(!comptime isStatement(struct {
        pub const kind = Projection.kind;
        pub const made_from = Projection.made_from;
        pub const sql: [:0]const u8 = "UPDATE session SET parent_ref=NULL";
    }));
    try std.testing.expect(!comptime isStatement(struct {
        pub const kind: StatementKind = .write;
        pub const sql: [:0]const u8 = "ROLLBACK";
    }));
    try std.testing.expect(!comptime isStatement(struct {
        pub const kind = Real.kind;
        pub const made_from = Real.made_from;
        pub const Args = Real.Args;
        pub const Row = Real.Row;
        pub const sql: [:0]const u8 = "DELETE FROM session";
    }));
    try std.testing.expect(!comptime isStatement(struct {}));
}

test "every word MySQL 8.4 reserves is a name Rui SQL refuses, unless the grammar reads it as a keyword" {
    try std.testing.expectEqualStrings("rsql: 'usage' is reserved on some engine; rename it", comptime portabilityError("WITH usage AS (SELECT 1 AS x) SELECT x FROM usage", reserved_names_checked).?);
    try std.testing.expectEqualStrings("rsql: 'match' is reserved on some engine; rename it", comptime portabilityError("SELECT x AS match FROM turn", reserved_names_checked).?);
    inline for (mysql_reserved) |word| {
        try std.testing.expectEqual(!isGrammarWord(word) or hasPlace(word), comptime identifierError(word, true) != null);
    }
}

test "a reserved word is a keyword only in its own place, and a name anywhere else" {
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
        .sql = "SELECT content_id FROM content WHERE content_id=?1 AND digest<>'@now'",
        .Args = struct { content_id: u64 },
        .Row = struct { content_id: Positive },
        .cardinality = .optional,
    });
    try std.testing.expect(!S.uses_now);
    try std.testing.expectEqualStrings("SELECT content_id FROM content WHERE content_id=?1 AND digest<>'@now'", S.sql);
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

    const Copy = struct { session: SessionHead, key: []const u8 };
    try std.testing.expectEqual(@as(?[]const u8, null), comptime statementError(.write, "INSERT INTO session_revision(session_ref,revision,command_key) SELECT session_ref,revision,?2 FROM session WHERE session_ref=@session(?1)", Copy, void));
    try std.testing.expectEqualStrings(copied, comptime statementError(.write, "INSERT INTO session_revision(session_ref,revision,command_key) SELECT ?2,revision,?2 FROM session WHERE session_ref=@session(?1)", Copy, void).?);
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

    const sender = "rsql: an INSERT names its Session as the sender_session_ref value of its VALUES row";
    try std.testing.expectEqualStrings("rsql: every SessionHead of Args is bound by its own @session(?k)", comptime statementError(.write, columns ++ "VALUES(?1,@session(?2),?3,?4,?5,@now,?6,?7)", Sent, void).?);
    try std.testing.expectEqualStrings(sender, comptime statementError(.write, columns ++ "VALUES(?1,@session(?2),?3,?4,?5,@now,?7,@session(?6))", Sent, void).?);
    try std.testing.expectEqualStrings(sender, comptime statementError(.write, columns ++ "VALUES(?1,@session(?2),?3,?4,?5,@now,coalesce(@session(?6),NULL),?7)", Sent, void).?);
    try std.testing.expectEqualStrings("rsql: an INSERT names its Session as the session_ref value of its VALUES row", comptime statementError(.write, columns ++ "VALUES(?1,NULL,?3,?4,?5,@now,@session(?2),NULL)", Person, void).?);
    try std.testing.expectEqualStrings("rsql: an INSERT names each of its Sessions with its own SessionHead", comptime statementError(.write, columns ++ "VALUES(?1,@session(?2),?3,?4,?5,@now,@session(?2),?5)", Person, void).?);
    try std.testing.expectEqualStrings("rsql: an INSERT gives each SessionHead as a Session column's value", comptime statementError(.write, columns ++ "VALUES(?1,@session(?2),?3,@session(?4),?5,@now,NULL,NULL)", struct { id: u64, session: SessionHead, key: []const u8, sender: SessionHead, position: u64 }, void).?);
    try std.testing.expectEqualStrings("rsql: a write to message_admission names each of its Sessions at most once, and one at least, as @session(?k)", comptime statementError(.write, columns ++ "VALUES(?1,?2,?3,?4,?5,@now,NULL,NULL)", struct { id: u64, session: []const u8, key: []const u8, content_id: u64, position: u64 }, void).?);
    try std.testing.expectEqualStrings("rsql: an INSERT ... SELECT copies one Session's row; message_admission names its Sessions otherwise", comptime statementError(.write, "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,admitted_at) SELECT ?1,session_ref,?3,?4,@now FROM session WHERE session_ref=@session(?2)", struct { id: u64, session: SessionHead, key: []const u8, content_id: u64 }, void).?);

    const Update = struct { turn_id: u64, session: SessionHead };
    const tie = "rsql: an UPDATE or DELETE names its Session as the conjunct session_ref=@session(?k) of its WHERE";
    try std.testing.expectEqual(@as(?[]const u8, null), comptime statementError(.write, "UPDATE message_admission SET turn_id=?1 WHERE session_ref=@session(?2) AND turn_id IS NULL", Update, void));
    try std.testing.expectEqualStrings(tie, comptime statementError(.write, "UPDATE message_admission SET turn_id=?1 WHERE sender_session_ref=@session(?2)", Update, void).?);
    try std.testing.expectEqualStrings(tie, comptime statementError(.write, "UPDATE message_admission SET sender_session_ref=NULL,turn_id=?1 WHERE session_ref=@session(?2)", Update, void).?);
    try std.testing.expectEqualStrings("rsql: expected a name at '('", comptime statementError(.write, "UPDATE message_admission SET (sender_session_ref,turn_id)=(NULL,?1) WHERE session_ref=@session(?2)", Update, void).?);
    try std.testing.expectEqual(@as(?[]const u8, null), comptime statementError(.write, "UPDATE message_admission SET turn_id=?1 WHERE session_ref=@session(?2) AND sender_session_ref IS NULL", Update, void));
    try std.testing.expectEqualStrings("rsql: a DELETE from message_admission would drop two Sessions' facts; no writer deletes them", comptime statementError(.write, "DELETE FROM message_admission WHERE session_ref=@session(?2) AND turn_id=?1", Update, void).?);
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

    const Rejected = struct { key: []const u8, sender: SessionHead, position: u64 };
    try std.testing.expectEqual(@as(?[]const u8, null), comptime statementError(.write, "INSERT INTO sent_rejection(command_key,sender_session_ref,sender_position,rejected_at) VALUES(?1,@session(?2),?3,@now)", Rejected, void));
    try std.testing.expectEqualStrings("rsql: an INSERT names its Session as the sender_session_ref value of its VALUES row", comptime statementError(.write, "INSERT INTO sent_rejection(command_key,sender_session_ref,sender_position,rejected_at) VALUES(?1,NULL,?3,@session(?2))", Rejected, void).?);
    try std.testing.expectEqualStrings("rsql: an INSERT names its Session as the sender_session_ref value of its VALUES row", comptime statementError(.write, "INSERT INTO sent_rejection(command_key,sender_session_ref,sender_position,rejected_at) VALUES(?1,?3,@session(?2),@now)", Rejected, void).?);
}

test "a write to a table that carries no Sessions names no Session" {
    try std.testing.expectEqualStrings("rsql: content carries no Sessions; bind no SessionHead", comptime statementError(.write, "DELETE FROM content WHERE content_id=?1 AND ?2 IS NOT NULL", struct { id: u64, session: SessionHead }, void).?);
    try std.testing.expectEqualStrings("rsql: a write to sent_rejection names its Session exactly once, as @session(?k)", comptime statementError(.write, "DELETE FROM sent_rejection WHERE sender_session_ref=?1", struct { ref: []const u8 }, void).?);
    try std.testing.expectEqual(@as(?[]const u8, null), comptime statementError(.write, "INSERT INTO content(content_id) VALUES(?1)", struct { turn_id: u64 }, void));
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

fn oneRow(comptime sql: []const u8) bool {
    return returnsOneRow(parse(sql).accepted.statement.select);
}

test "a read is keyed to one row only when keys pin every table it reads" {
    try std.testing.expect(comptime oneRow("SELECT content_id FROM content WHERE digest=?1 AND byte_length=?2 AND private=?3"));
    try std.testing.expect(comptime oneRow("SELECT s.session_ref FROM turn t JOIN session s ON s.session_ref=t.session_ref WHERE t.turn_id=?1 AND (?2 IS NULL OR t.operation_id=?2)"));
    try std.testing.expect(comptime oneRow("SELECT o.turn_id FROM action_operation a JOIN model_operation o ON o.operation_id=a.parent_operation_id WHERE a.action_id=?1"));
    try std.testing.expect(comptime oneRow("SELECT a.action_id FROM action_operation a LEFT JOIN turn t ON t.turn_id=?2 WHERE (a.action_id=?1)"));
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
    const copy = "INSERT INTO session_revision(session_ref,revision,command_key) SELECT session_ref,revision,?2 FROM session WHERE session_ref=@session(?1)";
    try std.testing.expect(comptime returnsOneRow(parse(copy).accepted.statement.insert.values.select));
    const turns = "INSERT INTO session_revision(session_ref,revision,command_key) SELECT session_ref,turn_id,?2 FROM turn WHERE session_ref=@session(?1)";
    try std.testing.expect(!comptime returnsOneRow(parse(turns).accepted.statement.insert.values.select));
}

test "the review's two inputs are refused" {
    try std.testing.expectEqualStrings("rsql: a read with a compound SELECT declares .compound = true", comptime statementError(.read, "SELECT 1 AS a UNION ALL SELECT 2 AS a", struct {}, struct { a: u64 }).?);
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

test "the Session tie reads the WHERE's conjuncts, not the tokens around the marker" {
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
    try std.testing.expect(!comptime oneRow("SELECT a.action_id FROM action_operation a LEFT JOIN turn t ON a.action_id=?1 AND t.turn_id=?2"));
    try std.testing.expect(comptime oneRow("SELECT a.action_id FROM action_operation a LEFT JOIN turn t ON t.turn_id=a.action_id WHERE a.action_id=?1"));
    try std.testing.expect(!comptime oneRow("SELECT 1 AS a UNION ALL SELECT 2 AS a"));
}

test "a compound's column names are its first SELECT's" {
    try std.testing.expectEqualStrings("rsql: column 1 is b but Row's field is a", comptime check(.read, "SELECT 1 AS b UNION ALL SELECT 2 AS a", struct {}, struct { a: u64 }, true).refused);
}

test "every parameter is ?N, so the count sees each one" {
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

test "@after is one comparison for one key column, and a row value for more" {
    try std.testing.expectEqualStrings("t.turn_id>?2", comptime render(.sqlite, "@after(t.turn_id,?2)"));
    try std.testing.expectEqualStrings("(c.operation_id,c.call_ordinal)>(?2,?3)", comptime render(.sqlite, "@after(c.operation_id,c.call_ordinal,?2,?3)"));
    const Turn = struct { turn_id: u64 };
    const Two = struct { session: []const u8, a: u64, b: u64 };
    try std.testing.expectEqualStrings(
        "rsql: @after takes k qualified columns, then k parameters ?N",
        comptime statementError(.read, "SELECT t.turn_id FROM turn t WHERE t.session_ref=?1 AND @after(t.turn_id,?2,?3)", Two, Turn).?,
    );
    try std.testing.expectEqualStrings(
        "rsql: @after takes k qualified columns, then k parameters ?N",
        comptime statementError(.read, "SELECT t.turn_id FROM turn t WHERE t.session_ref=?1 AND @after(turn_id,?2)", struct { session: []const u8, a: u64 }, Turn).?,
    );
    try std.testing.expectEqualStrings(row_value_message, comptime statementError(.read, "SELECT turn_id FROM turn WHERE session_ref=?1 AND (turn_id,input_cutoff)>(?2,?3)", Two, Turn).?);
}

const TestCalls = Page(.{
    .arms = &.{.{ .on = .{ .index = "model_tool_call_session_order" }, .alias = "tool_call", .columns = "tool_call.item_ordinal" }},
    .Row = struct { operation_id: Positive, call_ordinal: u64, item_ordinal: u64 },
    .take = 8,
});

test "a Page derives its text, Args and next keyset from the index it walks" {
    try std.testing.expectEqualStrings(
        "SELECT tool_call.operation_id AS operation_id,tool_call.call_ordinal AS call_ordinal,tool_call.item_ordinal " ++
            "FROM model_tool_call tool_call INDEXED BY model_tool_call_session_order " ++
            "WHERE tool_call.session_ref=?1 AND (tool_call.operation_id,tool_call.call_ordinal)>(?2,?3) ORDER BY operation_id,call_ordinal LIMIT 9",
        TestCalls.sql,
    );
    try std.testing.expectEqual(@as(u16, 9), TestCalls.limit);
    const Results = Page(.{
        .arms = &.{
            .{ .on = .{ .index = "model_tool_call_session_results" }, .alias = "tool_call", .columns = "tool_call.call_ordinal" },
            .{ .on = .{ .index = "action_operation_session_results" }, .alias = "action", .columns = "action.call_ordinal" },
        },
        .Row = struct { operation_id: Positive, acceptance_position: Positive, call_ordinal: u64 },
        .take = 8,
    });
    try std.testing.expectEqualStrings(
        "SELECT tool_call.operation_id AS operation_id,tool_call.acceptance_position AS acceptance_position,tool_call.call_ordinal " ++
            "FROM model_tool_call tool_call INDEXED BY model_tool_call_session_results " ++
            "WHERE tool_call.session_ref=?1 AND tool_call.acceptance_position IS NOT NULL AND (tool_call.operation_id,tool_call.acceptance_position)>(?2,?3) " ++
            "UNION ALL SELECT action.parent_operation_id AS operation_id,action.acceptance_position AS acceptance_position,action.call_ordinal " ++
            "FROM action_operation action INDEXED BY action_operation_session_results " ++
            "WHERE action.session_ref=?1 AND action.acceptance_position IS NOT NULL AND action.background_position IS NULL AND (action.parent_operation_id,action.acceptance_position)>(?2,?3) " ++
            "ORDER BY operation_id,acceptance_position LIMIT 9",
        Results.sql,
    );
    const Interruptions = Page(.{
        .arms = &.{.{ .on = .{ .index = "core_command_target_order" }, .alias = "command", .fixed = &.{.{ .column = "kind", .value = "4" }}, .columns = "command.accepted" }},
        .Row = struct { command_seq: Positive, accepted: bool },
        .take = 256,
    });
    try std.testing.expectEqualStrings(
        "SELECT command.command_seq AS command_seq,command.accepted FROM core_command command INDEXED BY core_command_target_order " ++
            "WHERE command.target=?1 AND command.kind=4 AND command.command_seq>?2 ORDER BY command_seq LIMIT 257",
        Interruptions.sql,
    );
    try std.testing.expect(Interruptions.page_walk.arms[0].prefix.len == 2);
}

test "a Page's next keyset is the row's key, and a row not after the last is refused" {
    const after: TestCalls.Args = .{ .session = "s", .operation_id = 4, .call_ordinal = 2 };
    const next = TestCalls.next(after, &.{ .operation_id = .of(4), .call_ordinal = 3, .item_ordinal = 0 }).?;
    try std.testing.expectEqualStrings("s", next.session);
    try std.testing.expectEqual(@as(u64, 4), next.operation_id);
    try std.testing.expectEqual(@as(u64, 3), next.call_ordinal);
    try std.testing.expectEqual(@as(u64, 0), TestCalls.next(.{ .session = "s" }, &.{ .operation_id = .of(5), .call_ordinal = 0, .item_ordinal = 0 }).?.call_ordinal);
    try std.testing.expect(TestCalls.next(after, &.{ .operation_id = .of(5), .call_ordinal = 0, .item_ordinal = 0 }) != null);
    try std.testing.expect(TestCalls.next(after, &.{ .operation_id = .of(4), .call_ordinal = 2, .item_ordinal = 0 }) == null);
    try std.testing.expect(TestCalls.next(after, &.{ .operation_id = .of(3), .call_ordinal = 9, .item_ordinal = 0 }) == null);
}

test "a Page refuses a key or a join that would let a chunk read rows it does not take" {
    const CallKey = struct { operation_id: Positive, call_ordinal: u64 };
    const calls: Ordered = .{ .index = "model_tool_call_session_order" };
    try std.testing.expectEqualStrings("rsql: a Page's joins are LEFT JOINs, so every row of its walked range is a row of the list", comptime pageSpecError(.{
        .arms = &.{.{ .on = calls, .alias = "tool_call", .columns = "", .joins = "CROSS JOIN content name_content ON name_content.content_id=tool_call.name_content_id" }},
        .Row = CallKey,
        .take = 8,
    }).?);
    try std.testing.expectEqualStrings("rsql: expected the end at 'WHERE'", comptime pageSpecError(.{
        .arms = &.{.{ .on = calls, .alias = "tool_call", .columns = "", .joins = "LEFT JOIN content name_content ON name_content.content_id=tool_call.name_content_id WHERE name_content.private=0" }},
        .Row = CallKey,
        .take = 8,
    }).?);
    try std.testing.expectEqualStrings("rsql: a Page's Row starts with its first key column, a Positive, so the zero key is before every row", comptime pageSpecError(.{
        .arms = &.{.{ .on = calls, .alias = "tool_call", .columns = "" }},
        .Row = struct { operation_id: u64, call_ordinal: u64 },
        .take = 8,
    }).?);
    try std.testing.expectEqualStrings("rsql: a Page's key column after the first is NOT NULL, or its index's predicate states it, and position is neither", comptime pageSpecError(.{
        .arms = &.{.{ .on = .{ .index = "session_stop_exclusion" }, .alias = "stop", .columns = "" }},
        .Row = struct { admission_cutoff: Positive, position: u64 },
        .take = 8,
    }).?);
    try std.testing.expectEqualStrings("rsql: a Page's fixed columns are its index's columns after the first, in order, and command_seq is not", comptime pageSpecError(.{
        .arms = &.{.{ .on = .{ .index = "core_command_target_order" }, .alias = "command", .fixed = &.{.{ .column = "command_seq", .value = "1" }}, .columns = "" }},
        .Row = struct { kind: Positive },
        .take = 8,
    }).?);
    try std.testing.expectEqualStrings("rsql: every arm of a Page has a key of one length", comptime pageSpecError(.{
        .arms = &.{ .{ .on = calls, .alias = "tool_call", .columns = "" }, .{ .on = .{ .index = "action_operation_session_order" }, .alias = "action", .columns = "" } },
        .Row = CallKey,
        .take = 8,
    }).?);
    try std.testing.expectEqual(@as(?[]const u8, null), comptime pageSpecError(.{
        .arms = &.{.{ .on = calls, .alias = "tool_call", .columns = "", .joins = "LEFT JOIN content name_content ON name_content.content_id=tool_call.name_content_id" }},
        .Row = CallKey,
        .take = 8,
    }));
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

fn messagesWithContent(comptime content: []const u8, comptime source: []const u8) []const u8 {
    return comptime entry_columns ++ "SELECT session_ref,?3+row_number() OVER (ORDER BY admission_id),?4+row_number() OVER (ORDER BY admission_id)-1,1,?2,admission_id,NULL,NULL," ++
        content ++ ",@now " ++ source;
}

const SessionCase = struct { name: []const u8, rule: []const u8, legal: []const u8, refused: []const u8, Args: type, expect: Expect, message: []const u8 };

const session_cases = [_]SessionCase{
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

fn messagesSelectJoin(comptime select: []const u8, comptime join: []const u8) []const u8 {
    return comptime messagesCopy(select, "FROM message_admission m JOIN " ++ join ++ " WHERE m.session_ref=@session(?1) AND m.turn_id=?2 AND m.admission_id>=?5");
}

test "a copy takes session_ref from a table its SELECT reads, and every table a write reads is tied to its Session" {
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
    try std.testing.expectEqualStrings("rsql: a write holds no compound SELECT", comptime writeError(messagesCopy("session_ref", tied ++ " UNION ALL SELECT 'zzzzzz',1,1,1,?2,1,NULL,NULL,1,1"), MessagesCopy, counted_copy).?);
    try std.testing.expectEqualStrings("rsql: an INSERT ... SELECT copies one Session's row; message_admission names its Sessions otherwise", comptime writeError(
        "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,admitted_at) SELECT ?1,session_ref,?3,?4,@now FROM message_admission WHERE session_ref=@session(?2)",
        struct { id: u64, session: SessionHead, key: []const u8, content_id: u64 },
        counted_copy,
    ).?);
    try std.testing.expectEqualStrings("rsql: the SessionHead ?k binds is used only in @session(?k)", comptime writeError(
        entry_columns ++ "SELECT session_ref,coalesce((SELECT max(entry_ordinal) FROM conversation_entry WHERE session_ref=?1),0)+row_number() OVER (ORDER BY admission_id)," ++
            "?3+row_number() OVER (ORDER BY admission_id)-1,1,?2,admission_id,NULL,NULL,content_id,@now FROM message_admission WHERE session_ref=@session(?1) AND turn_id=?2 AND admission_id>=?4",
        struct { session: SessionHead, turn_id: u64, position_base: u64, first_admission: u64 },
        counted_copy,
    ).?);
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
    try std.testing.expectEqualStrings("rsql: an INSERT ... SELECT of more than one row declares .counted, so its caller states the count", comptime writeError(messagesCopy("session_ref", tied), MessagesCopy, .{ .exact = .{ .rows = 1, .otherwise = error.ProjectionFailed } }).?);
    try std.testing.expectEqualStrings("rsql: an INSERT ... SELECT of at most one row declares .exact or .at_most 1", comptime writeError(
        "INSERT INTO session_revision(session_ref,revision,command_key) SELECT session_ref,revision,?2 FROM session WHERE session_ref=@session(?1)",
        struct { session: SessionHead, key: []const u8 },
        counted_copy,
    ).?);
    const Stop = struct { key: []const u8, session: SessionHead, turn_id: u64 };
    const stop = "INSERT INTO session_stop(command_key,session_ref,selected_turn_id,admission_cutoff,stopped_at) VALUES(?1,@session(?2),?3,0,@now)";
    try std.testing.expectEqual(@as(?[]const u8, null), comptime writeError(stop, Stop, one_copy));
    try std.testing.expectEqual(@as(?[]const u8, null), comptime writeError(stop, Stop, .{ .at_most = 1 }));
    try std.testing.expectEqualStrings(values_message, comptime writeError(stop, Stop, .{ .counted = .{ .otherwise = error.CorruptStore } }).?);
    try std.testing.expectEqualStrings(values_message, comptime writeError(stop, Stop, .{ .exact = .{ .rows = 2, .otherwise = error.CorruptStore } }).?);
    const Bind = struct { turn_id: u64, session: SessionHead };
    const counted_bind: Expect = .{ .counted = .{ .otherwise = error.SelectionChanged } };
    try std.testing.expectEqual(@as(?[]const u8, null), comptime writeError("UPDATE message_admission SET turn_id=?1 WHERE session_ref=@session(?2) AND turn_id IS NULL", Bind, counted_bind));
    try std.testing.expectEqualStrings(
        "rsql: message_admission.admitted_at is read by its sender too; an UPDATE of it has the conjunct sender_session_ref=@session(?j) or sender_session_ref IS NULL",
        comptime writeError("UPDATE message_admission SET turn_id=?1,admitted_at=@now WHERE session_ref=@session(?2) AND turn_id IS NULL", Bind, counted_bind).?,
    );
}

test "SQLite-only spellings MySQL would refuse at PREPARE are refused at build time" {
    const with_insert = "rsql: MySQL takes WITH only after INSERT INTO t(columns); write INSERT INTO t(columns) WITH ... SELECT";
    try std.testing.expectEqualStrings(with_insert, comptime portabilityError("WITH n(v) AS (SELECT 1) INSERT INTO turn(turn_id) SELECT v FROM n", false).?);
    try std.testing.expectEqualStrings(with_insert, comptime portabilityError("with a AS (SELECT (1)), b AS (SELECT 2) insert INTO turn(turn_id) SELECT 1", false).?);
    try std.testing.expectEqual(@as(?[]const u8, null), comptime portabilityError("INSERT INTO turn(turn_id) WITH n(v) AS (SELECT 1) SELECT v FROM n", false));
    try std.testing.expectEqual(@as(?[]const u8, null), comptime portabilityError("WITH n(v) AS (SELECT 1) UPDATE turn SET turn_id=(SELECT v FROM n)", false));
    try std.testing.expectEqual(@as(?[]const u8, null), comptime portabilityError("WITH n(v) AS (SELECT 1) SELECT v FROM n", false));
    inline for (.{ "printf('%d',1)", "randomblob(8)", "strftime('%s','now')", "julianday('now')", "iif(1,2,3)" }) |call| {
        try std.testing.expect(comptime std.mem.indexOf(u8, portabilityError("SELECT " ++ call, false).?, "is not portable") != null);
    }
}

test "bytes marker compares text with content payload across dialects" {
    try std.testing.expectEqualStrings("CAST(tool.name AS BLOB)=name.payload", comptime render(.sqlite, "@bytes(tool.name)=@payload(name)"));
    try std.testing.expectEqualStrings(
        "CAST(tool.name AS BINARY)=coalesce((SELECT bytes FROM content_chunk WHERE content_chunk.content_id=name.content_id AND content_chunk.chunk_index=0),X'')",
        comptime render(.mysql, "@bytes(tool.name)=@payload(name)"),
    );
}

test "@index forces only named real-column MySQL indexes, after the table or alias" {
    inline for (.{
        .{ "SELECT revision FROM session_revision @index(session_revision_instructions) WHERE session_ref=?1 AND instructions_content_id=?2", "SELECT revision FROM session_revision FORCE INDEX (session_revision_instructions) WHERE session_ref=? AND instructions_content_id=?" },
        .{ "SELECT r.revision FROM session_revision r @index(session_revision_output_schema) WHERE r.session_ref=?1 AND r.output_schema_content_id=?2", "SELECT r.revision FROM session_revision r FORCE INDEX (session_revision_output_schema) WHERE r.session_ref=? AND r.output_schema_content_id=?" },
        .{ "SELECT m.admission_id FROM message_admission AS m @index(message_admission_sent) WHERE m.sender_session_ref=?1 AND m.sender_position>?2", "SELECT m.admission_id FROM message_admission AS m FORCE INDEX (message_admission_sent) WHERE m.sender_session_ref=? AND m.sender_position>?" },
        .{ "SELECT a.action_id FROM action_operation a @index(action_operation_executable) WHERE a.action_id>?1 AND a.attempt_at<=?2", "SELECT a.action_id FROM action_operation a  WHERE a.action_id>? AND a.attempt_at<=?" },
        .{ "SELECT t.turn_id FROM turn t @index(turn_one_active_per_session) WHERE t.session_ref=?1 AND t.turn_id>?2 AND t.outcome_code IS NULL", "SELECT t.turn_id FROM turn t  WHERE t.session_ref=? AND t.turn_id>? AND t.outcome_code IS NULL" },
    }) |case| {
        const actual = comptime mysqlRendering(case[0]).rendered;
        try std.testing.expectEqualStrings(case[1], comptime actual.prepared());
        try std.testing.expectEqualDeep(@as([]const Slot, &.{ .{ .argument = 0 }, .{ .argument = 1 } }), actual.slots);
    }
}

test "a MySQL index hint is one name, not an expression" {
    try std.testing.expectEqualStrings(
        "rsql: @index takes one index name",
        comptime mysqlRendering("SELECT revision FROM session_revision @index(session_revision_instructions + bogus)").refused,
    );
}

test "@in_index states a partial index's rows: its predicate on SQLite, its seek column or key part on MySQL" {
    try std.testing.expectEqualStrings(
        "SELECT t.turn_id FROM turn t WHERE (t.outcome_code IS NULL)",
        comptime render(.sqlite, "SELECT t.turn_id FROM turn t WHERE @in_index(t, turn_one_active_per_session)"),
    );
    // A `.leading` index: the generated `_lead` column is NULL exactly when the predicate is false.
    try std.testing.expectEqualStrings(
        "SELECT u.session_ref FROM turn u  WHERE u.turn_unpositioned_lead IS NOT NULL",
        comptime mysqlRendering("SELECT u.session_ref FROM turn u @index(turn_unpositioned) WHERE @in_index(u, turn_unpositioned)").rendered.prepared(),
    );
    // A `.unique_when` index: its first key part, which is NULL exactly when the predicate is false.
    try std.testing.expectEqualStrings(
        "SELECT t.turn_id FROM turn t WHERE (CASE WHEN t.outcome_code IS NULL THEN t.session_ref END) IS NOT NULL",
        comptime mysqlRendering("SELECT t.turn_id FROM turn t WHERE @in_index(t, turn_one_active_per_session)").rendered.prepared(),
    );
    // A `.plain_unique` index: its predicate, qualified.
    try std.testing.expectEqualStrings(
        "SELECT a.action_id FROM action_operation a WHERE (a.sender_handle IS NOT NULL)",
        comptime mysqlRendering("SELECT a.action_id FROM action_operation a WHERE @in_index(a, action_operation_sender_handle)").rendered.prepared(),
    );
    try std.testing.expectEqualStrings(
        "rsql: @in_index names no partial index turn_session_latest",
        comptime statementError(.read, "SELECT t.turn_id FROM turn t WHERE @in_index(t, turn_session_latest)", struct { id: u64 }, struct { turn_id: u64 }).?,
    );
}

test "a real-column index keeps its SQLite spelling and does not add MySQL slots" {
    const S = Read(.{
        .sql = "SELECT revision FROM session_revision @index(session_revision_instructions) WHERE session_ref=?1 AND instructions_content_id=?2",
        .cardinality = .each,
        .Args = struct { session: []const u8, content: u64 },
        .Row = struct { revision: u64 },
    });
    try std.testing.expectEqualStrings("SELECT revision FROM session_revision INDEXED BY session_revision_instructions WHERE session_ref=?1 AND instructions_content_id=?2", S.sql);
    try std.testing.expectEqualStrings("SELECT revision FROM session_revision FORCE INDEX (session_revision_instructions) WHERE session_ref=? AND instructions_content_id=?", comptime S.mysql.prepared());
    try std.testing.expectEqualDeep(@as([]const Slot, &.{ .{ .argument = 0 }, .{ .argument = 1 } }), S.mysql.slots);
}
