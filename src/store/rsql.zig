//! Rui SQL: Store SQL text written once for every engine. Source text is SQLite
//! SQL restricted to a portable subset, plus markers that each engine renders
//! in its own spelling. The schema's checks and index predicates use it today.

const std = @import("std");

pub const Dialect = enum { sqlite };

/// Whether table, column and index names must avoid every engine's reserved
/// words, and text must not name `rowid`. Today's format names a column
/// `key`; this turns on with the format that renames it.
pub const reserved_names_checked = false;

/// Words reserved in at least one engine (SQLite 3.53, Postgres 17, MySQL 8.4).
const reserved_names = [_][]const u8{
    "key",  "keys",      "call",     "groups",    "rank",   "row",    "rows",   "window",  "range",
    "user", "lead",      "lag",      "order",     "limit",  "offset", "system", "lateral", "cube",
    "of",   "recursive", "interval", "condition", "signal",
};

/// Words some engine lacks or reads differently, each with the portable form.
const forbidden_words = [_]struct { word: []const u8, fix: []const u8 }{
    .{ .word = "GLOB", .fix = "write @charset(column,'set') or @initial(column,'set')" },
    .{ .word = "typeof", .fix = "test IS NULL or IS NOT NULL" },
    .{ .word = "unixepoch", .fix = "bind the Host's time as a parameter" },
};

/// Why `text` is not portable Rui SQL, or null. With `reserved` set, `rowid`
/// is rejected too. String literals are not inspected; comments and quoted
/// identifiers are refused, so nothing else escapes the scan.
pub fn portabilityError(comptime text: []const u8, comptime reserved: bool) ?[]const u8 {
    comptime {
        @setEvalBranchQuota(100 * text.len + 1000);
        var index: usize = 0;
        while (index < text.len) {
            const byte = text[index];
            const pair: []const u8 = text[index..@min(index + 2, text.len)];
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
                if (reserved and std.ascii.eqlIgnoreCase(word, "rowid")) return "rsql: 'rowid' is SQLite's hidden key; name an explicit INTEGER key column";
                if (std.ascii.eqlIgnoreCase(word, "IS")) {
                    var next_start = skipSpace(text, index);
                    var next: []const u8 = text[next_start..wordEnd(text, next_start)];
                    if (std.ascii.eqlIgnoreCase(next, "NOT")) {
                        next_start = skipSpace(text, next_start + next.len);
                        next = text[next_start..wordEnd(text, next_start)];
                    }
                    if (!std.ascii.eqlIgnoreCase(next, "NULL")) return "rsql: 'IS' compares only with NULL; write @same(a,b) or @distinct(a,b)";
                }
            } else if (byte == '@' or std.ascii.isDigit(byte)) {
                index = wordEnd(text, index + 1);
            } else {
                index += 1;
            }
        }
        return null;
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
///   @charset(c,'set')    only these characters: `c NOT GLOB '*[^set]*'`
///   @initial(c,'set')    first character in the set: `c GLOB '[set]*'`
///   @same(a,b)           null-safe equality: `(a IS b)`
///   @distinct(a,b)       its negation: `(a IS NOT b)`
pub fn render(comptime dialect: Dialect, comptime text: []const u8) []const u8 {
    comptime {
        if (portabilityError(text, reserved_names_checked)) |message| @compileError(message ++ ": " ++ text);
        return switch (dialect) {
            .sqlite => renderSqlite(text),
        };
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
        .charset => first ++ " NOT GLOB '*[^" ++ characterSet(arguments[1], text) ++ "]*'",
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
    try std.testing.expectEqualStrings("provider NOT GLOB '*[^a-z0-9_-]*'", comptime render(.sqlite, "@charset(provider,'a-z0-9_-')"));
    try std.testing.expectEqualStrings("provider GLOB '[a-z]*'", comptime render(.sqlite, "@initial(provider,'a-z')"));
    try std.testing.expectEqualStrings("(action_kind IS 1)", comptime render(.sqlite, "@same(action_kind,1)"));
    try std.testing.expectEqualStrings("(resolution_code IS NOT 'denied')", comptime render(.sqlite, "@distinct(resolution_code,'denied')"));
}

test "markers nest, and text outside them is copied" {
    try std.testing.expectEqualStrings(
        "x IS NULL OR (length(CAST(x AS BLOB))=6 AND x NOT GLOB '*[^a-f]*') AND '@octets(y)'='@'",
        comptime render(.sqlite, "x IS NULL OR (@octets(x)=6 AND @charset(x,'a-f')) AND '@octets(y)'='@'"),
    );
    try std.testing.expectEqualStrings("(length(CAST(a AS BLOB)) IS b)", comptime render(.sqlite, "@same(@octets(a), b)"));
}

test "non-portable text names its fix" {
    try std.testing.expectEqualStrings("rsql: 'GLOB' is not portable; write @charset(column,'set') or @initial(column,'set')", comptime portabilityError("x NOT GLOB '*[^a]*'", false).?);
    try std.testing.expectEqualStrings("rsql: 'typeof' is not portable; test IS NULL or IS NOT NULL", comptime portabilityError("typeof(x)='blob'", false).?);
    try std.testing.expectEqualStrings("rsql: 'unixepoch' is not portable; bind the Host's time as a parameter", comptime portabilityError("at<=unixepoch()", false).?);
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
