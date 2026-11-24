//! Text for a reader: a diagnostic as rustc-style lines with its picture, and the summary line.

const std = @import("std");
const dg = @import("Diagnostic.zig");

const Writer = std.Io.Writer;
const Diagnostic = dg.Diagnostic;
const Step = dg.Step;
const Tally = dg.Tally;

/// The longest bar, in cells: a list's name and length then fit in 80 columns.
const bar_width = 40;
/// The column of the line a bar is measured against.
const line_at = dg.held_in_mind;

/// Writes `d` as `error[lint]: message`, its location, its notes and its picture.
pub fn render(writer: *Writer, d: Diagnostic) Writer.Error!void {
    try writer.print("error[{s}]: {s}\n", .{ d.lint.name(), d.message });
    if (d.location) |at| try writer.print("  --> {s}:{d}:{d}\n", .{ at.file, at.line, at.column });
    for (d.notes) |note| try writer.print("  = note: {s}\n", .{note});
    switch (d.picture) {
        .circle => |circle| try drawCircle(writer, circle.steps, circle.rest),
        .spread => |spread| try drawSpread(writer, spread.owner, spread.field, spread.modules, spread.others),
        .lists => |lists| try drawLists(writer, lists.shown, lists.hidden, lists.lists),
    }
}

/// Writes the last line of a run: the new errors, the allowed ones and the stale allowances.
pub fn summary(writer: *Writer, errors: usize, allowed: usize, stale: usize) Writer.Error!void {
    try writer.writeAll("deep-modules: ");
    try dg.counted(writer, errors, "error");
    try writer.print(" ({d} allowed, {d} stale)\n", .{ allowed, stale });
}

/// Writes one picture line, indented to sit under the notes.
fn line(writer: *Writer, comptime fmt: []const u8, args: anytype) Writer.Error!void {
    try writer.writeAll("    ");
    try writer.print(fmt ++ "\n", args);
}

fn repeat(writer: *Writer, text: []const u8, count: usize) Writer.Error!void {
    for (0..count) |_| try writer.writeAll(text);
}

fn digits(number: usize) usize {
    var rest = number;
    var count: usize = 1;
    while (rest >= 10) : (rest /= 10) count += 1;
    return count;
}

/// Each member under the last, the tie to the next between them, and the last tie back to the first.
/// The cheapest tie is heavy.
fn drawCircle(writer: *Writer, steps: []const Step, rest: ?[]const u8) Writer.Error!void {
    const common = commonDir(steps);
    const skip = if (common.len == 0) 0 else common.len + 1;
    var width: usize = 0;
    for (steps) |step| width = @max(width, siteLen(step.site, skip));
    for (steps, 0..) |step, index| {
        const cheapest = index == 0;
        try line(writer, "{s}{s}", .{ if (cheapest) "┌─▶ " else "│   ", step.member });
        try writer.writeAll("    │     ");
        try writer.writeAll(if (cheapest) "┃ " else "│ ");
        try writer.print("{s}:{d}", .{ step.site.file[skip..], step.site.line });
        try repeat(writer, " ", width - siteLen(step.site, skip));
        try writer.print("  {s}\n", .{step.uses});
        if (index + 1 < steps.len) try line(writer, "│     ▼", .{});
    }
    try line(writer, "└─────┘", .{});
    if (rest) |text| try line(writer, "{s}", .{text});
}

/// The directory all steps' files are in, cut from each site: `kinds.zig:10` for `src/kinds.zig:10`.
fn commonDir(steps: []const Step) []const u8 {
    if (steps.len == 0) return "";
    var common = dirOf(steps[0].site.file);
    for (steps[1..]) |step| common = sharedDir(common, dirOf(step.site.file));
    return common;
}

fn dirOf(file: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, file, '/')) |slash| file[0..slash] else "";
}

/// The longest prefix of two directories that ends on a `/` boundary in both.
fn sharedDir(a: []const u8, b: []const u8) []const u8 {
    var n: usize = 0;
    while (n < a.len and n < b.len and a[n] == b[n]) n += 1;
    while (n > 0 and !(segmentEnds(a, n) and segmentEnds(b, n))) n -= 1;
    return a[0..n];
}

fn segmentEnds(path: []const u8, n: usize) bool {
    return n == path.len or path[n] == '/';
}

fn siteLen(site: dg.Location, skip: usize) usize {
    return site.file.len - skip + 1 + digits(site.line);
}

/// The owner, then the field with an arm from each module that works on it, then its other facts.
/// Arms are aligned under the field's name.
fn drawSpread(writer: *Writer, owner: []const u8, field: []const u8, modules: []const Tally, others: []const []const u8) Writer.Error!void {
    try line(writer, "{s}", .{owner});
    var width: usize = 1;
    for (modules) |module| width = @max(width, digits(module.count));
    const under = field.len + 3;
    for (modules, 0..) |module, index| {
        const last = index + 1 == modules.len;
        try writer.writeAll("    ");
        if (index == 0) try writer.print("  {s} ", .{field}) else try repeat(writer, " ", under);
        const arm = if (modules.len == 1) "◀━━━" else if (index == 0) "◀━┳━" else if (last) "  ┗━" else "  ┣━";
        try writer.print("{s} ", .{arm});
        try repeat(writer, " ", width - digits(module.count));
        try writer.print("{d}  {s}\n", .{ module.count, module.name });
    }
    for (others) |other| try line(writer, "  {s}", .{other});
}

/// The functions a module shows and hides, as bars against a line at `held_in_mind`, then each list's length.
fn drawLists(writer: *Writer, shown: usize, hidden: usize, lists: []const Tally) Writer.Error!void {
    var width: usize = @max("shows".len, "hides".len);
    for (lists) |list| width = @max(width, list.name.len);
    try writer.writeAll("    ");
    try repeat(writer, " ", width + 2 + (line_at + 1) - digits(line_at));
    try writer.print("{d}\n", .{line_at});
    try drawBar(writer, "shows", width, shown);
    try drawBar(writer, "hides", width, hidden);
    for (lists) |list| try drawBar(writer, list.name, width, list.count);
}

/// One bar: filled to the line, then past it, cut short with `⋯` at the end of the bar.
fn drawBar(writer: *Writer, name: []const u8, width: usize, length: usize) Writer.Error!void {
    const room = bar_width - line_at;
    const inside = @min(length, line_at);
    const past = length - inside;
    try writer.print("    {s}", .{name});
    try repeat(writer, " ", width - name.len + 2);
    try repeat(writer, "█", inside);
    try repeat(writer, " ", line_at - inside);
    try writer.writeAll("│");
    try repeat(writer, "█", @min(past, room));
    if (past > room) try writer.writeAll("⋯");
    try writer.print(" {d}\n", .{length});
}

fn rendered(d: Diagnostic) ![]u8 {
    var out: Writer.Allocating = .init(std.testing.allocator);
    errdefer out.deinit();
    try render(&out.writer, d);
    return out.toOwnedSlice();
}

test "a circle draws its steps, the cheapest heavy, and what it leaves out" {
    const steps = [_]Step{
        .{ .member = "kinds", .site = .{ .file = "src/kinds.zig", .line = 10, .column = 1 }, .uses = "Stream.new uses LIMIT" },
        .{ .member = "socket", .site = .{ .file = "src/net/socket.zig", .line = 5, .column = 1 }, .uses = "listen uses Stream" },
    };
    const diagnostic: Diagnostic = .{
        .lint = .@"module-cycle",
        .key = "kinds,socket",
        .message = "2 modules in `src` use each other in a circle",
        .location = .{ .file = "src/kinds.zig", .line = 10, .column = 1 },
        .notes = &.{"src/kinds.zig:10:1: `kinds` uses `socket` by 1 item: LIMIT"},
        .picture = .{ .circle = .{ .steps = &steps, .rest = "not drawn: 1 more module" } },
    };
    const want =
        \\error[module-cycle]: 2 modules in `src` use each other in a circle
        \\  --> src/kinds.zig:10:1
        \\  = note: src/kinds.zig:10:1: `kinds` uses `socket` by 1 item: LIMIT
        \\    ┌─▶ kinds
        \\    │     ┃ kinds.zig:10      Stream.new uses LIMIT
        \\    │     ▼
        \\    │   socket
        \\    │     │ net/socket.zig:5  listen uses Stream
        \\    └─────┘
        \\    not drawn: 1 more module
        \\
    ;
    const got = try rendered(diagnostic);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(want, got);
}

test "a spread with one module draws a single arm" {
    const modules = [_]Tally{.{ .count = 1, .name = "app" }};
    const diagnostic: Diagnostic = .{
        .lint = .@"field-leak",
        .key = "RunQueue.items",
        .message = "`RunQueue.items` is known outside `RunQueue`: 1 place in 1 module",
        .location = .{ .file = "src/Composer.zig", .line = 47, .column = 28 },
        .notes = &.{"src/Composer.zig:47:28: `Composer.draw` borrows `items`"},
        .picture = .{ .spread = .{
            .owner = "RunQueue",
            .field = "items",
            .modules = &modules,
            .others = &.{"kept: limit"},
        } },
    };
    const want =
        \\error[field-leak]: `RunQueue.items` is known outside `RunQueue`: 1 place in 1 module
        \\  --> src/Composer.zig:47:28
        \\  = note: src/Composer.zig:47:28: `Composer.draw` borrows `items`
        \\    RunQueue
        \\      items ◀━━━ 1  app
        \\      kept: limit
        \\
    ;
    const got = try rendered(diagnostic);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(want, got);
}

test "a spread with several modules draws an arm from each, aligned under the field" {
    const modules = [_]Tally{
        .{ .count = 12, .name = "sched" },
        .{ .count = 3, .name = "app" },
        .{ .count = 2, .name = "in 2 more modules" },
    };
    const diagnostic: Diagnostic = .{
        .lint = .@"field-leak",
        .key = "RunQueue.items",
        .message = "`RunQueue.items` is known outside `RunQueue`: 17 places in 4 modules",
        .location = null,
        .notes = &.{},
        .picture = .{ .spread = .{
            .owner = "RunQueue",
            .field = "items",
            .modules = &modules,
            .others = &.{ "also known outside: head", "kept: limit" },
        } },
    };
    const want =
        \\error[field-leak]: `RunQueue.items` is known outside `RunQueue`: 17 places in 4 modules
        \\    RunQueue
        \\      items ◀━┳━ 12  sched
        \\              ┣━  3  app
        \\              ┗━  2  in 2 more modules
        \\      also known outside: head
        \\      kept: limit
        \\
    ;
    const got = try rendered(diagnostic);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(want, got);
}

test "lists draw bars against a line at seven, cut short past 40 cells" {
    const lists = [_]Tally{.{ .count = 9, .name = "Store" }};
    const diagnostic: Diagnostic = .{
        .lint = .@"shallow-module",
        .key = "store/wire",
        .message = "`store/wire` is shallow: it shows 50 of its 53 functions",
        .location = null,
        .notes = &.{"`Connection` shows 9 functions"},
        .picture = .{ .lists = .{ .shown = 50, .hidden = 3, .lists = &lists } },
    };
    const want =
        \\error[shallow-module]: `store/wire` is shallow: it shows 50 of its 53 functions
        \\  = note: `Connection` shows 9 functions
        \\                  7
        \\    shows  ███████│█████████████████████████████████⋯ 50
        \\    hides  ███    │ 3
        \\    Store  ███████│██ 9
        \\
    ;
    const got = try rendered(diagnostic);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(want, got);
}

test "a site is cut from the directory all steps share" {
    const cases = [_][3][]const u8{
        .{ "src/a", "src/a", "src/a" },
        .{ "src/a/x", "src/b", "src" },
        .{ "src", "src/x", "src" },
        .{ "ab", "a", "" },
        .{ "", "src", "" },
    };
    for (cases) |case| try std.testing.expectEqualStrings(case[2], sharedDir(case[0], case[1]));
}

test "the summary counts errors and names the allowed and stale" {
    const cases = [_]struct { errors: usize, allowed: usize, stale: usize, want: []const u8 }{
        .{ .errors = 4, .allowed = 12, .stale = 0, .want = "deep-modules: 4 errors (12 allowed, 0 stale)\n" },
        .{ .errors = 1, .allowed = 0, .stale = 2, .want = "deep-modules: 1 error (0 allowed, 2 stale)\n" },
    };
    for (cases) |case| {
        var out: Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        try summary(&out.writer, case.errors, case.allowed, case.stale);
        try std.testing.expectEqualStrings(case.want, out.written());
    }
}
