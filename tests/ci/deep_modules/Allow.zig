//! The allow file: diagnostics a tree keeps for now, and the rules that judge a run against it.
//! Pure: it reads no file and runs no git. The caller passes the text and the trusted base in.

const std = @import("std");
const dg = @import("Diagnostic.zig");

const Allocator = std.mem.Allocator;
const Lint = dg.Lint;
const Diagnostic = dg.Diagnostic;

pub const Entry = struct {
    lint: Lint,
    key: []const u8,
};

/// The entries of an allow file, sorted by lint and then key, each once.
pub const AllowList = struct {
    entries: []const Entry,
};

pub const Parsed = union(enum) {
    entries: AllowList,
    /// The 1-based number of the first line that is not `<lint> <key>`.
    invalid: usize,
};

/// Parses `text`, allocating from `a`. Blank lines and `#` comments are skipped.
pub fn parse(a: Allocator, text: []const u8) Allocator.Error!Parsed {
    var list: std.ArrayList(Entry) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var number: usize = 0;
    while (lines.next()) |raw| {
        number += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const split = std.mem.indexOfScalar(u8, line, ' ') orelse return .{ .invalid = number };
        const lint = Lint.parse(line[0..split]) orelse return .{ .invalid = number };
        const key = std.mem.trim(u8, line[split + 1 ..], " \t");
        if (key.len == 0) return .{ .invalid = number };
        try list.append(a, .{ .lint = lint, .key = key });
    }
    std.mem.sort(Entry, list.items, {}, lessThan);
    var kept: usize = 0;
    for (list.items) |entry| {
        if (kept > 0 and sameEntry(list.items[kept - 1], entry)) continue;
        list.items[kept] = entry;
        kept += 1;
    }
    return .{ .entries = .{ .entries = list.items[0..kept] } };
}

/// Whether `entry` allows `d`: the same lint and key, or, for a circle, a key whose members are all among
/// the entry's. Shrinking an allowed circle stays allowed.
pub fn covers(entry: Entry, d: Diagnostic) bool {
    return allows(entry, d.lint, d.key);
}

pub const Verdict = struct {
    /// Diagnostics that no entry covers.
    new: []const Diagnostic,
    /// Entries that cover no current diagnostic.
    stale: []const Entry,
    /// Entries that the trusted base does not cover: the file grew.
    grown: []const Entry,
};

/// Judges `current` against `allowed`. `trusted` is the allow file at the merge base, or null when the file
/// is absent there (the bootstrap run), which skips the growth check.
pub fn judge(a: Allocator, current: []const Diagnostic, allowed: AllowList, trusted: ?AllowList) Allocator.Error!Verdict {
    var new: std.ArrayList(Diagnostic) = .empty;
    for (current) |d| {
        if (!anyEntryAllows(allowed.entries, d.lint, d.key)) try new.append(a, d);
    }
    var stale: std.ArrayList(Entry) = .empty;
    for (allowed.entries) |entry| {
        if (!anyDiagnosticAllowed(entry, current)) try stale.append(a, entry);
    }
    var grown: std.ArrayList(Entry) = .empty;
    if (trusted) |base| {
        for (allowed.entries) |entry| {
            if (!anyEntryAllows(base.entries, entry.lint, entry.key)) try grown.append(a, entry);
        }
    }
    return .{
        .new = try new.toOwnedSlice(a),
        .stale = try stale.toOwnedSlice(a),
        .grown = try grown.toOwnedSlice(a),
    };
}

/// The allow file text for `current`: a header, then one `<lint> <key>` line per distinct diagnostic.
pub fn write(a: Allocator, current: []const Diagnostic) Allocator.Error![]const u8 {
    const entries = try a.alloc(Entry, current.len);
    for (current, entries) |d, *entry| entry.* = .{ .lint = d.lint, .key = d.key };
    std.mem.sort(Entry, entries, {}, lessThan);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, header);
    for (entries, 0..) |entry, index| {
        if (index > 0 and sameEntry(entries[index - 1], entry)) continue;
        try out.appendSlice(a, try std.fmt.allocPrint(a, "{s} {s}\n", .{ entry.lint.name(), entry.key }));
    }
    return out.toOwnedSlice(a);
}

const header =
    \\# Existing deep-modules diagnostics this tree allows. Regenerate with:
    \\#   zig build deep-modules -- --update-allow
    \\# An entry whose diagnostic is gone is stale and fails; a diagnostic not listed here fails.
    \\
;

fn allows(entry: Entry, lint: Lint, key: []const u8) bool {
    if (entry.lint != lint) return false;
    if (std.mem.eql(u8, entry.key, key)) return true;
    if (lint != .tangle and lint != .@"module-cycle") return false;
    var members = std.mem.splitScalar(u8, key, ',');
    while (members.next()) |member| {
        if (!hasMember(entry.key, member)) return false;
    }
    return true;
}

fn hasMember(list: []const u8, member: []const u8) bool {
    var members = std.mem.splitScalar(u8, list, ',');
    while (members.next()) |other| {
        if (std.mem.eql(u8, other, member)) return true;
    }
    return false;
}

fn anyEntryAllows(entries: []const Entry, lint: Lint, key: []const u8) bool {
    for (entries) |entry| {
        if (allows(entry, lint, key)) return true;
    }
    return false;
}

fn anyDiagnosticAllowed(entry: Entry, current: []const Diagnostic) bool {
    for (current) |d| {
        if (covers(entry, d)) return true;
    }
    return false;
}

fn sameEntry(a: Entry, b: Entry) bool {
    return a.lint == b.lint and std.mem.eql(u8, a.key, b.key);
}

fn lessThan(_: void, a: Entry, b: Entry) bool {
    if (a.lint != b.lint) return @backingInt(a.lint) < @backingInt(b.lint);
    return std.mem.lessThan(u8, a.key, b.key);
}

fn diag(lint: Lint, key: []const u8) Diagnostic {
    return .{
        .lint = lint,
        .key = key,
        .message = "",
        .location = null,
        .notes = &.{},
        .picture = .{ .lists = .{ .shown = 0, .hidden = 0, .lists = &.{} } },
    };
}

fn mustParse(a: Allocator, text: []const u8) !AllowList {
    return switch (try parse(a, text)) {
        .entries => |list| list,
        .invalid => error.UnexpectedInvalid,
    };
}

test "parse reads entries sorted, once each, and skips comments and blank lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const list = try mustParse(arena.allocator(),
        \\# header
        \\
        \\tangle b,c
        \\field-leak T.x
        \\  module-cycle a,b
        \\tangle b,c
        \\
    );
    const want = [_]Entry{
        .{ .lint = .@"module-cycle", .key = "a,b" },
        .{ .lint = .tangle, .key = "b,c" },
        .{ .lint = .@"field-leak", .key = "T.x" },
    };
    try std.testing.expectEqual(want.len, list.entries.len);
    for (want, list.entries) |w, got| try std.testing.expect(sameEntry(w, got));
}

test "parse reports the 1-based line of each invalid entry" {
    const cases = [_]struct { text: []const u8, line: usize }{
        .{ .text = "tangle a,b\ntangle\n", .line = 2 },
        .{ .text = "chatty-seam a -> b\n", .line = 1 },
        .{ .text = "# c\n\nfield-leak \n", .line = 3 },
        .{ .text = "field-leak T.x\n\nwide-directory src\n", .line = 3 },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (cases) |case| {
        const got = try parse(arena.allocator(), case.text);
        try std.testing.expectEqual(case.line, got.invalid);
    }
}

test "covers: a circle covers its subsets, other lints need the same key" {
    const cases = [_]struct { entry: Entry, lint: Lint, key: []const u8, want: bool }{
        .{ .entry = .{ .lint = .tangle, .key = "a,b,c" }, .lint = .tangle, .key = "a,b,c", .want = true },
        .{ .entry = .{ .lint = .tangle, .key = "a,b,c" }, .lint = .tangle, .key = "a,c", .want = true },
        .{ .entry = .{ .lint = .tangle, .key = "a,b,c" }, .lint = .tangle, .key = "a,d", .want = false },
        .{ .entry = .{ .lint = .tangle, .key = "a,b" }, .lint = .tangle, .key = "a,b,c", .want = false },
        .{ .entry = .{ .lint = .tangle, .key = "a,b" }, .lint = .@"module-cycle", .key = "a,b", .want = false },
        .{ .entry = .{ .lint = .@"module-cycle", .key = "x/y,a" }, .lint = .@"module-cycle", .key = "a", .want = true },
        .{ .entry = .{ .lint = .@"field-leak", .key = "T.x" }, .lint = .@"field-leak", .key = "T.x", .want = true },
        .{ .entry = .{ .lint = .@"field-leak", .key = "T.x" }, .lint = .@"field-leak", .key = "T.xy", .want = false },
        .{ .entry = .{ .lint = .@"shallow-module", .key = "a,b" }, .lint = .@"shallow-module", .key = "a", .want = false },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.want, covers(case.entry, diag(case.lint, case.key)));
    }
}

test "judge: new, stale, grown, and the bootstrap run" {
    const Row = struct {
        allowed: []const u8,
        trusted: ?[]const u8,
        current: []const Entry,
        new: usize,
        stale: usize,
        grown: usize,
    };
    const rows = [_]Row{
        .{ .allowed = "", .trusted = null, .current = &.{.{ .lint = .tangle, .key = "a,b" }}, .new = 1, .stale = 0, .grown = 0 },
        .{ .allowed = "tangle a,b", .trusted = null, .current = &.{}, .new = 0, .stale = 1, .grown = 0 },
        .{ .allowed = "tangle a,b", .trusted = null, .current = &.{.{ .lint = .tangle, .key = "a,b" }}, .new = 0, .stale = 0, .grown = 0 },
        .{ .allowed = "tangle a,b,c", .trusted = "tangle a,b,c", .current = &.{.{ .lint = .tangle, .key = "a,b" }}, .new = 0, .stale = 0, .grown = 0 },
        .{ .allowed = "tangle a,b", .trusted = "tangle a,b,c", .current = &.{.{ .lint = .tangle, .key = "a,b" }}, .new = 0, .stale = 0, .grown = 0 },
        .{ .allowed = "tangle a,b,c", .trusted = "tangle a,b", .current = &.{.{ .lint = .tangle, .key = "a,b,c" }}, .new = 0, .stale = 0, .grown = 1 },
        .{ .allowed = "tangle a,b,c", .trusted = "tangle a,b", .current = &.{.{ .lint = .tangle, .key = "a,b,c,d" }}, .new = 1, .stale = 1, .grown = 1 },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (rows) |row| {
        const trusted = if (row.trusted) |text| try mustParse(a, text) else null;
        const diagnostics = try a.alloc(Diagnostic, row.current.len);
        for (row.current, diagnostics) |entry, *d| d.* = diag(entry.lint, entry.key);
        const verdict = try judge(a, diagnostics, try mustParse(a, row.allowed), trusted);
        try std.testing.expectEqual(row.new, verdict.new.len);
        try std.testing.expectEqual(row.stale, verdict.stale.len);
        try std.testing.expectEqual(row.grown, verdict.grown.len);
    }
}

test "write then parse gives the same entries back, sorted and once each" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const current = [_]Diagnostic{
        diag(.@"field-leak", "T.x"),
        diag(.tangle, "b,c"),
        diag(.@"module-cycle", "x/y,a"),
        diag(.tangle, "b,c"),
    };
    const text = try write(a, &current);
    const want_text = header ++
        "module-cycle x/y,a\n" ++
        "tangle b,c\n" ++
        "field-leak T.x\n";
    try std.testing.expectEqualStrings(want_text, text);
    const list = try mustParse(a, text);
    try std.testing.expectEqual(@as(usize, 3), list.entries.len);
    try std.testing.expectEqualStrings("x/y,a", list.entries[0].key);
    try std.testing.expectEqualStrings("b,c", list.entries[1].key);
    try std.testing.expectEqualStrings("T.x", list.entries[2].key);
}
