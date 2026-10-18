//! Source check for functional cores: decisions over values.
//!
//! A core may name only the `std` members below, and may import only `std`,
//! `builtin` and other cores. It may not reach C or assembly, alias `std`, or
//! name a clock method. The check reads tokens to catch accidental effects.
//! Effects reached by reflection (a computed `@field` name) or through an
//! injected context, such as an `anytype` or a `*std.Io.Writer` that drains to
//! a file, are left to review.
const std = @import("std");

pub const Violation = struct {
    line: usize,
    text: []const u8,
};

/// `std` members a core may name, with everything beneath them. The rest of
/// `std` is an effect or reaches one.
const allowed_std = [_][]const u8{
    "std.ascii",               "std.base64",                     "std.enums",
    "std.fmt",                 "std.json",                       "std.math",
    "std.mem",                 "std.meta",                       "std.Target",
    "std.crypto.secureZero",   "std.debug.assert",               "std.heap.FixedBufferAllocator",
    "std.heap.ArenaAllocator", "std.Io.Writer",                  "std.Io.Timestamp",
    "std.Io.Clock.Timestamp",  "std.testing.allocator",          "std.testing.expect",
    "std.testing.expectEqual", "std.testing.expectEqualStrings", "std.testing.expectEqualSlices",
    "std.testing.expectError",
};

/// Allowed only inside `test` declarations, for failure diagnostics.
const test_only_std = [_][]const u8{"std.debug.print"};

/// Clock methods: every public function of a time value a core can hold that
/// takes an `Io`, so it reads or waits on a clock. A member with one of these
/// names reads as a clock call; give a received time another name. `Clock`
/// itself adds only `now`, already here, and `resolution`, a common name for
/// a decision's outcome.
const clock_methods = ioMethods(time_types);

/// Time types a core can hold: the allowed `std.Io` members, with their
/// paths, and the durations they return. The test below requires every other
/// allowed `std.Io` member to be `Writer`.
const time_types = .{
    .{ "std.Io.Timestamp", std.Io.Timestamp },
    .{ "std.Io.Clock.Timestamp", std.Io.Clock.Timestamp },
    .{ "", std.Io.Duration },
    .{ "", std.Io.Clock.Duration },
};

fn ioMethods(comptime types: anytype) []const []const u8 {
    comptime {
        var names: []const []const u8 = &.{};
        for (types) |entry| for (std.meta.declarations(entry[1])) |name| {
            const T = entry[1];
            const info = @typeInfo(@TypeOf(@field(T, name)));
            if (info != .@"fn") continue;
            for (info.@"fn".param_types) |param| if (param == std.Io) {
                if (!contains(names, name)) names = names ++ .{@as([]const u8, name)};
                break;
            };
        };
        return names;
    }
}

/// Returns the first violation in `source`, or null. `cores` lists the file
/// names a core may import besides `std` and `builtin`.
pub fn check(source: [:0]const u8, cores: []const []const u8) ?Violation {
    const found = scan(source, cores) orelse return null;
    return .{ .line = 1 + std.mem.count(u8, source[0..found.offset], "\n"), .text = found.text };
}

const Found = struct { offset: usize, text: []const u8 };

fn scan(source: [:0]const u8, cores: []const []const u8) ?Found {
    var tokens = std.zig.Tokenizer.init(source);
    // The three tokens before the current one, most recent first.
    const blank: std.zig.Token = .{ .tag = .invalid, .loc = .{ .start = 0, .end = 0 } };
    var before = [3]std.zig.Token{ blank, blank, blank };
    var depth: usize = 0;
    // Brace depth inside the current `test` declaration's body, if any.
    var test_depth: ?usize = null;
    var test_pending = false;
    while (true) {
        const token = tokens.next();
        if (token.tag == .eof) return null;
        defer {
            // Copy first: the new array would otherwise alias the old one.
            const shifted = [3]std.zig.Token{ token, before[0], before[1] };
            before = shifted;
        }
        const text = source[token.loc.start..token.loc.end];
        switch (token.tag) {
            .keyword_test => test_pending = true,
            .l_brace => {
                depth += 1;
                if (test_pending) test_depth = depth;
                test_pending = false;
            },
            .r_brace => {
                if (test_depth == depth) test_depth = null;
                depth -|= 1;
            },
            else => {},
        }
        const at: Found = .{ .offset = token.loc.start, .text = text };
        switch (token.tag) {
            // Escapes would hide the name from every comparison below.
            .identifier => if (std.mem.indexOfScalar(u8, text, '\\') != null) {
                return at;
            } else if (before[0].tag == .period) {
                // A member access follows an expression; `.wait` alone is an
                // enum literal or field name. `x.std` reaches std another way.
                const member = switch (before[1].tag) {
                    .identifier, .r_paren, .r_bracket, .question_mark, .period_asterisk => true,
                    else => false,
                };
                if (member and (contains(clock_methods, unquoted(text)) or std.mem.eql(u8, unquoted(text), "std"))) return at;
            } else if (std.mem.eql(u8, unquoted(text), "std")) {
                var buffer: [256]u8 = undefined;
                const end = tokens.index;
                const path = dottedPath(source, &tokens, token, &buffer) orelse return at;
                if (std.mem.eql(u8, path, "std")) {
                    // `std` stands alone only where `const std = @import("std");` declares it.
                    if (before[0].tag != .keyword_const) return at;
                } else if (!allowedStd(path) and !(test_depth != null and contains(&test_only_std, path))) return .{ .offset = at.offset, .text = std.mem.trim(u8, source[token.loc.start..@max(end, tokens.index)], " \n") };
            },
            .builtin => if (std.mem.eql(u8, text, "@import")) {
                const name = importName(source, &tokens) orelse return at;
                if (std.mem.eql(u8, name, "std")) {
                    // Every other spelling would bypass the member allowlist.
                    const declared = before[0].tag == .equal and before[1].tag == .identifier and
                        std.mem.eql(u8, source[before[1].loc.start..before[1].loc.end], "std") and before[2].tag == .keyword_const;
                    if (!declared or peek(&tokens).tag != .semicolon) return .{ .offset = at.offset, .text = name };
                } else if (!std.mem.eql(u8, name, "builtin") and !contains(cores, name)) return .{ .offset = at.offset, .text = name };
            } else if (std.mem.eql(u8, text, "@field")) {
                // `@field(T, "now")` names a clock method or `std` by string;
                // a name built from literals would hide it.
                if (fieldName(source, &tokens)) |field| switch (field) {
                    .literal => |name| if (contains(clock_methods, name) or
                        std.mem.eql(u8, name, "std") or std.mem.indexOfScalar(u8, name, '\\') != null)
                        return .{ .offset = at.offset, .text = name },
                    .built => |name| return .{ .offset = at.offset, .text = name },
                };
            } else if (contains(&.{ "@cImport", "@cInclude", "@extern", "@export" }, text)) {
                return at;
            },
            .keyword_export, .keyword_asm => return at,
            .keyword_extern => switch (peek(&tokens).tag) {
                .keyword_fn, .string_literal, .keyword_var, .keyword_const => return at,
                else => {},
            },
            else => {},
        }
    }
}

fn peek(tokens: *const std.zig.Tokenizer) std.zig.Token {
    var ahead = tokens.*;
    return ahead.next();
}

/// Consumes `.name` pairs after `first` and returns the names joined by
/// periods, such as `std.Io.Writer`, whatever the spacing; null if the path
/// outgrows `buffer`.
fn dottedPath(source: []const u8, tokens: *std.zig.Tokenizer, first: std.zig.Token, buffer: []u8) ?[]const u8 {
    var path = std.Io.Writer.fixed(buffer);
    path.writeAll(unquoted(source[first.loc.start..first.loc.end])) catch return null;
    while (true) {
        var ahead = tokens.*;
        if (ahead.next().tag != .period) break;
        const member = ahead.next();
        if (member.tag != .identifier) break;
        tokens.* = ahead;
        path.print(".{s}", .{unquoted(source[member.loc.start..member.loc.end])}) catch return null;
    }
    return path.buffered();
}

/// An identifier's name, without `@"` quoting.
fn unquoted(identifier: []const u8) []const u8 {
    if (std.mem.startsWith(u8, identifier, "@\"") and identifier.len >= 3) return identifier[2 .. identifier.len - 1];
    return identifier;
}

/// The member name of a `@field(object, name)` call when it starts with a
/// string literal: `.literal` alone, `.built` when more follows it.
fn fieldName(source: []const u8, tokens: *const std.zig.Tokenizer) ?union(enum) { literal: []const u8, built: []const u8 } {
    var ahead = tokens.*;
    if (ahead.next().tag != .l_paren) return null;
    var parens: usize = 1;
    var second = false;
    // The second argument: its first token, its token count, its end, and
    // whether a string literal appears anywhere in it.
    var first: ?std.zig.Token = null;
    var count: usize = 0;
    var end: usize = 0;
    var literal = false;
    while (true) {
        const token = ahead.next();
        switch (token.tag) {
            .eof => return null,
            .l_paren => parens += 1,
            .r_paren => {
                parens -= 1;
                if (parens == 0) break;
            },
            .comma => if (parens == 1) {
                if (second) continue; // a trailing comma
                second = true;
                continue;
            },
            else => {},
        }
        if (!second) continue;
        if (first == null) first = token;
        count += 1;
        end = token.loc.end;
        if (token.tag == .string_literal or token.tag == .multiline_string_literal_line) literal = true;
    }
    const start = first orelse return null;
    if (count == 1 and start.tag == .string_literal) return .{ .literal = source[start.loc.start + 1 .. start.loc.end - 1] };
    // A name built, wrapped or written across lines from literals would hide
    // it; a lone computed name is left to review.
    if (literal) return .{ .built = source[start.loc.start..end] };
    return null;
}

fn allowedStd(path: []const u8) bool {
    var names = std.mem.splitScalar(u8, path, '.');
    while (names.next()) |member| if (contains(clock_methods, member)) return false;
    for (allowed_std) |allowed| if (within(path, allowed)) return true;
    return false;
}

fn within(path: []const u8, member: []const u8) bool {
    return std.mem.startsWith(u8, path, member) and (path.len == member.len or path[member.len] == '.');
}

fn importName(source: []const u8, tokens: *std.zig.Tokenizer) ?[]const u8 {
    if (tokens.next().tag != .l_paren) return null;
    const literal = tokens.next();
    if (literal.tag != .string_literal or tokens.next().tag != .r_paren) return null;
    return source[literal.loc.start + 1 .. literal.loc.end - 1];
}

fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| if (std.mem.eql(u8, candidate, name)) return true;
    return false;
}

test "the boundary check reads names, not comments or strings" {
    const cores = [_][]const u8{"other.zig"};
    const pure =
        \\const std = @import("std");
        \\const builtin = @import("builtin");
        \\const other = @import("other.zig");
        \\const field = @import("other.zig").value;
        \\// std.posix.read in a comment
        \\const url = "https://std.fs.example/now()";
        \\const quote = '"';
        \\fn f(out: *std.Io.Writer, at: std.Io.Clock.Timestamp, list: std.Io.Writer.Allocating) void { _ = .{ out, at, list }; }
        \\var buffer: std.heap.FixedBufferAllocator = undefined;
        \\const os = builtin.os.tag;
        \\const S = extern struct { a: u8 };
        \\pub const reexport = self.mystd.posix;
        \\test { _ = std.testing.allocator; errdefer std.debug.print("context", .{}); }
        \\const e = @field(anyerror, "AccountMismatch");
        \\const Phase = enum { wait, done }; const waiting = phase == .wait; const v = .{ .now = 1 };
        \\const eql = std . mem . eql;
        \\const tag = @import("builtin").os.tag;
        \\const lines =
    ++ "\n    \\\\std.posix \"quoted\" // not a comment\n;\n";
    try std.testing.expectEqual(@as(?Violation, null), check(pure, &cores));
    inline for (.{
        .{ "const p = std.posix;", "std.posix" },
        .{ "fn f(io: std.Io) void {}", "std.Io" },
        .{ "const Io = std.Io;", "std.Io" },
        .{ "fn f(d: std.Io.Dir) void {}", "std.Io.Dir" },
        .{ "const c = std.c;", "std.c" },
        .{ "const a = std.heap.page_allocator;", "std.heap.page_allocator" },
        .{ "const a = std.heap.c_allocator;", "std.heap.c_allocator" },
        .{ "const log = std.log.scoped(.x);", "std.log.scoped" },
        .{ "const m: std.Thread.Mutex = .{};", "std.Thread.Mutex" },
        .{ "const f = std.fs.cwd();", "std.fs.cwd" },
        .{ "test { var t = std.testing.tmpDir(.{}); }", "std.testing.tmpDir" },
        .{ "const t = clock.now(io);", "now" },
        .{ "const t = std.Io.Clock.Timestamp.now(io, .awake);", "std.Io.Clock.Timestamp.now" },
        .{ "const f = @call(.auto, std.Io.Clock.Timestamp.now, .{});", "std.Io.Clock.Timestamp.now" },
        .{ "const d = start.untilNow(io);", "untilNow" },
        .{ "try deadline.wait(io);", "wait" },
        .{ "const t = clocks[0].now(io);", "now" },
        .{ "const t = context().now(io);", "now" },
        .{ "const z = @import(\"std\"); const p = z.posix;", "std" },
        .{ "const s = std; const p = s.posix;", "std" },
        .{ "const v = asm volatile (\"syscall\");", "asm" },
        .{ "test { const io = std.testing.io_instance.io(); }", "std.testing.io_instance.io" },
        .{ "const h = std.debug.attachSegfaultHandler;", "std.debug.attachSegfaultHandler" },
        .{ "const b = std.crypto.Certificate.Bundle;", "std.crypto.Certificate.Bundle" },
        .{ "const c = @cImport({});", "@cImport" },
        .{ "const p = @\"std\".posix;", "@\"std\".posix" },
        .{ "const p = @This().std.posix;", "std" },
        .{ "const t = @field(std.Io.Timestamp, \"now\");", "now" },
        .{ "const t = at.toClock(io, .real);", "toClock" },
        .{ "const t = std.Io.Clock.Timestamp.toClock;", "std.Io.Clock.Timestamp.toClock" },
        .{ "const t = at.clock.now(io);", "now" },
        .{ "const t = @field(at, \"n\" ++ \"ow\");", "\"n\" ++ \"ow\"" },
        .{ "const t = @field(std.Io.Clock.Timestamp, (\"now\"))(io, .awake);", "(\"now\")" },
        .{ "const p = @field(@This(), (\"std\")).posix;", "(\"std\")" },
        .{ "const t = @field(T,\n    \\\\now\n);", "\\\\now" },
        .{ "const t = @field(T, \"now\",);", "now" },
        .{ "const p = @field(@This(), \"std\").posix;", "std" },
        .{ "const p = @\"\\x73td\".posix;", "@\"\\x73td\"" },
        // A path too long to compare fails closed.
        .{ "const p = std.mem.member00.member01.member02.member03.member04.member05.member06.member07.member08.member09.member10.member11.member12.member13.member14.member15.member16.member17.member18.member19.member20.member21.member22.member23.member24.member25.member26.member27.member28.member29;", "std" },
        .{ "comptime { @export(&f, .{ .name = \"read\" }); }", "@export" },
        .{ "fn f() void { std.debug.print(\"x\", .{}); }", "std.debug.print" },
        .{ "extern fn read() void;", "extern" },
        .{ "export fn f() void {}", "export" },
        .{ "const s = @import(\"store.zig\");", "store.zig" },
        .{ "const p = @import(\"std\").posix;", "std" },
    }) |case| {
        const found = check(case[0], &cores) orelse return error.TestExpectedViolation;
        try std.testing.expectEqualStrings(case[1], found.text);
    }
    try std.testing.expectEqual(@as(usize, 2), check("const std = @import(\"std\");\nconst p = std.posix;", &cores).?.line);
}

test "clock methods are reflected from every time type a core may hold" {
    for ([_][]const u8{ "now", "wait", "sleep", "fromNow", "untilNow", "durationFromNow", "toClock" }) |name|
        try std.testing.expect(contains(clock_methods, name));
    const paths = comptime blk: {
        var list: [time_types.len][]const u8 = undefined;
        for (time_types, 0..) |entry, index| list[index] = entry[0];
        break :blk list;
    };
    for (allowed_std) |allowed| if (within(allowed, "std.Io"))
        try std.testing.expect(contains(&paths, allowed) or within(allowed, "std.Io.Writer"));
}
