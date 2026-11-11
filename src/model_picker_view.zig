//! Shared model-picker values. A selection names a menu entry or owns a
//! typed, unlisted ID; it never borrows mutable composer storage.
const std = @import("std");
const model_catalog = @import("model_catalog.zig");
const gwidth = @import("terminal_width");
const picker = @import("model_picker.zig");
const Bounded = @import("bounded.zig").Bounded;
const overview = @import("overview_style.zig");

pub const Choice = struct {
    index: usize,
    row: picker.Row,
    typed: Bounded(model_catalog.max_model_bytes) = .{ .len = 0 },

    /// The selected model, including an ID absent from the live list.
    pub fn entry(self: *const Choice, menu: *const picker.Menu) picker.Entry {
        if (self.typed.len == 0) return menu.entries[self.index];
        return .{ .id = self.typed.slice(), .known = false, .catalogued = false, .providers = self.row.providers };
    }
};

pub const Click = struct {
    pub const Target = union(enum) { model, lower_effort, higher_effort, sign_in: picker.Provider };
    index: usize,
    target: Target,
};

pub const Action = union(enum) {
    previous,
    next,
    lower_effort,
    higher_effort,
    next_sign_in,
    choose_sign_in: picker.Provider,
    select: usize,
    click: Click,
    save,
};

pub const Saved = struct {
    model: []const u8,
    effort: ?picker.ReasoningEffort,
    provider: picker.Provider,
};

/// A row for GroupedList. Model indices refer to the borrowed Menu, not the
/// position in this list; headings and status rows cannot be selected.
pub const Line = struct { text: []const u8, segments: []const overview.Segment, model: ?usize = null, heading: bool = false };
pub const Lines = struct { rows: []Line, selected: ?u32 };
pub const Read = enum { unread, read, unanswered, invalid };

const Columns = struct { context: bool = true, sign_ins: bool = false, all_sign_ins: bool = true };

/// A frame's row plan. Only visible rows allocate text and spans.
pub const Rows = struct {
    menu: *const picker.Menu,
    query: picker.Query,
    defaults: picker.Defaults,
    choice: ?Choice,
    widest: usize,
    columns: Columns,
    method: gwidth.Method,
    unicode: bool,
    count: usize,
    selected: ?u32,
    total: usize,
    first: usize = 0,
    end: usize,
    fallback: bool,

    /// Keep the selection visible and account for every hidden model.
    pub fn viewport(self: Rows, height: usize) Rows {
        var plan = self;
        if (self.total <= height) return plan;
        if (height == 0) {
            plan.count = 0;
            plan.selected = null;
            return plan;
        }
        const selected = self.selected orelse 0;
        const capacity = @max(1, height -| 2);
        plan.first = selected -| (capacity / 2);
        plan.end = @min(self.total, plan.first + capacity);
        if (plan.first == 0) plan.end = @min(self.total, @max(1, height -| 1));
        if (plan.end == self.total) plan.first = self.total -| @max(1, height -| 1);
        plan.count = plan.end - plan.first + @intFromBool(plan.first != 0) + @intFromBool(plan.end != self.total);
        plan.selected = @intCast(selected - plan.first + @intFromBool(plan.first != 0));
        // With fewer than three cells high, the selected model wins. Two
        // rows can still report both hidden ends in one quiet row.
        if (height < 3) {
            plan.first = selected;
            plan.end = selected + 1;
            plan.count = height;
            plan.selected = 0;
        }
        return plan;
    }

    pub fn row(self: Rows, arena: std.mem.Allocator, wanted: usize) !Line {
        if (self.count <= 2 and self.total > self.count and self.selected == 0) {
            if (wanted != 0) return simpleLine(arena, try std.fmt.allocPrint(arena, "{s} {d} more  {s} {d} more", .{ if (self.unicode) "↑" else "^", self.first, if (self.unicode) "↓" else "v", self.total - self.end }), false);
        } else {
            if (self.first != 0 and wanted == 0) return simpleLine(arena, try std.fmt.allocPrint(arena, "{s} {d} more", .{ if (self.unicode) "↑" else "^", self.first }), false);
            if (self.end != self.total and wanted == self.count - 1) return simpleLine(arena, try std.fmt.allocPrint(arena, "{s} {d} more", .{ if (self.unicode) "↓" else "v", self.total - self.end }), false);
        }
        const ordinal = self.first + wanted - @as(usize, @intFromBool(self.first != 0 and self.selected != 0));
        if (self.fallback) return self.modelLine(arena, typedEntry(self.menu, self.query.words, self.defaults), self.menu.entries.len);
        var at: usize = 0;
        for (self.menu.entries, 0..) |entry, index| {
            _ = self.query.row(entry, self.defaults) orelse continue;
            if (at == ordinal) return self.modelLine(arena, entry, index);
            at += 1;
        }
        unreachable;
    }

    fn modelLine(self: Rows, arena: std.mem.Allocator, entry: picker.Entry, index: usize) !Line {
        const highlighted = if (self.choice) |c| c.index == index else self.fallback;
        const base = if (self.fallback) self.query.typed(entry, self.defaults) else self.query.row(entry, self.defaults).?;
        const selected_row = if (highlighted and self.choice != null) self.choice.?.row else base;
        const buffer = try arena.alloc(u8, @max(entry.id.len, self.widest) + 256);
        const formatted = format(buffer, entry, selected_row, highlighted, self.widest, self.columns, self.method, self.unicode);
        const text = try arena.dupe(u8, formatted.text);
        return .{ .text = text, .segments = try segments(arena, text, formatted), .model = index };
    }
};

/// Unlisted typed IDs use the served sign-ins, or the current binding while
/// no sign-in has answered. The provider remains the availability authority.
fn typedEntry(menu: *const picker.Menu, words: []const u8, defaults: picker.Defaults) picker.Entry {
    var providers: picker.Providers = .empty;
    for (std.enums.values(picker.Provider)) |provider| if (menu.sources.get(provider) != null) {
        providers.insert(provider);
    };
    if (providers.count() == 0) providers.insert(defaults.provider orelse comptime std.meta.stringToEnum(picker.Provider, @import("product_defaults.zig").provider).?);
    return .{ .id = std.mem.trim(u8, words, " "), .known = false, .catalogued = false, .providers = providers };
}

/// Build an unbounded plan; the shell applies the actual list viewport.
pub fn rows(arena: std.mem.Allocator, menu: *const picker.Menu, words: []const u8, defaults: picker.Defaults, choice: ?Choice, width: usize, method: gwidth.Method, unicode: bool, read: Read) !Rows {
    _ = read; // Transport/list state is not a model choice or a prose row.
    const query = picker.Query.parse(words);
    var widest: usize = 0;
    var count: usize = 0;
    var selected: ?u32 = null;
    var providers: picker.Providers = .empty;
    for (menu.entries, 0..) |entry, index| {
        if (query.row(entry, defaults) == null) continue;
        widest = @max(widest, entry.id.len);
        providers.setUnion(entry.providers);
        if (choice) |c| if (c.index == index) {
            selected = @intCast(count);
        };
        count += 1;
    }
    const fallback = count == 0 and std.mem.trim(u8, words, " ").len != 0;
    if (fallback) {
        const entry = typedEntry(menu, words, defaults);
        widest = entry.id.len;
        providers = entry.providers;
        count = 1;
        selected = 0;
    }
    const buffer = try arena.alloc(u8, widest + 256);
    var columns: Columns = .{ .sign_ins = providers.count() > 1 };
    if (needed(buffer, menu, query, defaults, choice, widest, columns, method, unicode, fallback) > width) columns.context = false;
    if (needed(buffer, menu, query, defaults, choice, widest, columns, method, unicode, fallback) > width) columns.all_sign_ins = false;
    widest = @min(widest, width -| needed(buffer, menu, query, defaults, choice, 0, columns, method, unicode, fallback));
    return .{ .menu = menu, .query = query, .defaults = defaults, .choice = choice, .widest = widest, .columns = columns, .method = method, .unicode = unicode, .count = count, .selected = selected, .total = count, .end = count, .fallback = fallback };
}

/// Apply the shell's available height without changing the model selection.
pub fn rowsIn(arena: std.mem.Allocator, menu: *const picker.Menu, words: []const u8, defaults: picker.Defaults, choice: ?Choice, width: usize, height: usize, method: gwidth.Method, unicode: bool, read: Read) !Rows {
    return (try rows(arena, menu, words, defaults, choice, width, method, unicode, read)).viewport(height);
}

fn lines(arena: std.mem.Allocator, menu: *const picker.Menu, words: []const u8, defaults: picker.Defaults, choice: ?Choice, width: usize) !Lines {
    const plan = try rows(arena, menu, words, defaults, choice, width, .unicode, true, .read);
    const result = try arena.alloc(Line, plan.count);
    for (result, 0..) |*line, index| line.* = try plan.row(arena, index);
    return .{ .rows = result, .selected = plan.selected };
}

fn needed(buffer: []u8, menu: *const picker.Menu, query: picker.Query, defaults: picker.Defaults, choice: ?Choice, id_width: usize, columns: Columns, method: gwidth.Method, unicode: bool, fallback: bool) usize {
    if (fallback) {
        const entry = typedEntry(menu, query.words, defaults);
        const row = if (choice) |c| c.row else query.typed(entry, defaults);
        return gwidth.gwidth(format(buffer, entry, row, true, id_width, columns, method, unicode).text, method);
    }
    var max: usize = 0;
    for (menu.entries, 0..) |entry, index| {
        const base = query.row(entry, defaults) orelse continue;
        const highlighted = if (choice) |c| c.index == index else false;
        const row = if (highlighted) choice.?.row else base;
        max = @max(max, gwidth.gwidth(format(buffer, entry, row, highlighted, id_width, columns, method, unicode).text, method));
    }
    return max;
}

fn cells(text: []const u8) usize {
    return gwidth.gwidth(text, .unicode);
}

const Range = struct { start: usize, end: usize, style: overview.Style };
const Formatted = struct { text: []const u8, ranges: [3]?Range = @splat(null) };

fn simpleLine(arena: std.mem.Allocator, text: []const u8, heading: bool) !Line {
    const spans = try arena.alloc(overview.Segment, 1);
    spans[0] = .{ .text = text, .style = if (heading) .{ .colour = .ink, .bold = true } else .{ .colour = .quiet } };
    return .{ .text = text, .segments = spans, .heading = heading };
}

fn segments(arena: std.mem.Allocator, text: []const u8, formatted: Formatted) ![]const overview.Segment {
    const spans = try arena.alloc(overview.Segment, 7);
    var count: usize = 0;
    var offset: usize = 0;
    for (formatted.ranges) |maybe| if (maybe) |range| {
        if (offset < range.start) {
            spans[count] = .{ .text = text[offset..range.start], .style = .{} };
            count += 1;
        }
        spans[count] = .{ .text = text[range.start..range.end], .style = range.style };
        count += 1;
        offset = range.end;
    };
    if (offset < text.len) {
        spans[count] = .{ .text = text[offset..], .style = .{} };
        count += 1;
    }
    return spans[0..count];
}

fn format(buffer: []u8, entry: picker.Entry, row: picker.Row, highlighted: bool, id_width: usize, columns: Columns, method: gwidth.Method, unicode: bool) Formatted {
    var out: std.Io.Writer = .fixed(buffer);
    var ranges: [3]?Range = @splat(null);
    const mark = if (unicode) "✓" else "+";
    out.writeAll(if (row.current) mark else " ") catch unreachable;
    out.writeAll("  ") catch unreachable;
    if (row.current) ranges[0] = .{ .start = 0, .end = mark.len, .style = .{ .colour = .mark, .bold = true } };
    if (entry.id.len > id_width) {
        if (id_width > 0) {
            out.writeAll(entry.id[0 .. id_width - 1]) catch unreachable;
            out.writeAll(if (unicode) "…" else ".") catch unreachable;
        }
    } else {
        out.writeAll(entry.id) catch unreachable;
        for (entry.id.len..id_width) |_| out.writeByte(' ') catch unreachable;
    }
    if (columns.context) {
        const fact = if (entry.known) model_catalog.find(model_catalog.shipped, entry.id) else null;
        const window = if (fact) |known| known.context_window else null;
        const start = gwidth.gwidth(out.buffered(), method);
        if (window) |limit| {
            if (limit >= 1_000_000) {
                out.print("  {d}M", .{limit / 1_000_000}) catch unreachable;
            } else out.print("  {d}K", .{limit / 1_000}) catch unreachable;
        }
        while (gwidth.gwidth(out.buffered(), method) - start < 7) out.writeByte(' ') catch unreachable;
    }
    if ((highlighted and row.effort != null) or columns.sign_ins) {
        const start = gwidth.gwidth(out.buffered(), method);
        if (if (highlighted) row.effort else null) |effort| {
            const adjustable = highlighted and row.efforts.count() > 1;
            if (adjustable) {
                out.writeAll("  ") catch unreachable;
                const control_start = out.buffered().len;
                if (unicode) out.print("‹ {s} ›", .{@tagName(effort)}) catch unreachable else out.print("< {s} >", .{@tagName(effort)}) catch unreachable;
                ranges[1] = .{ .start = control_start, .end = out.buffered().len, .style = .{ .colour = .strong, .bold = true } };
            } else out.print("  {s}", .{@tagName(effort)}) catch unreachable;
        }
        while (gwidth.gwidth(out.buffered(), method) - start < 11) out.writeByte(' ') catch unreachable;
    }
    var offered = (if (columns.sign_ins) row.providers else picker.Providers.empty).iterator();
    while (offered.next()) |provider| {
        if (!columns.all_sign_ins and provider != row.provider) continue;
        const boxed = highlighted and row.providers.count() > 1 and provider == row.provider;
        if (boxed) {
            out.writeAll("  ") catch unreachable;
            const control_start = out.buffered().len;
            out.print("[{s}]", .{provider.signIn()}) catch unreachable;
            ranges[2] = .{ .start = control_start, .end = out.buffered().len, .style = .{ .colour = .strong, .bold = true } };
        } else out.print("  {s}", .{provider.signIn()}) catch unreachable;
    }
    return .{ .text = out.buffered(), .ranges = ranges };
}

/// Opening highlights the saved default when offered and matching, without
/// moving it out of its group. Otherwise it selects the first matching row.
pub fn open(menu: *const picker.Menu, words: []const u8, defaults: picker.Defaults) ?Choice {
    const wanted = if (defaults.model) |id| menu.find(id) else null;
    return select(menu, words, defaults, wanted);
}

/// Reconcile a selection after a draft edit or menu replacement. Keep the
/// highlighted row if it still matches, otherwise select the first match.
pub fn select(menu: *const picker.Menu, words: []const u8, defaults: picker.Defaults, wanted: ?usize) ?Choice {
    const query = picker.Query.parse(words);
    if (wanted) |index| if (index < menu.entries.len) {
        if (query.row(menu.entries[index], defaults)) |row| return .{ .index = index, .row = row };
    };
    for (menu.entries, 0..) |entry, index| {
        if (query.row(entry, defaults)) |row| return .{ .index = index, .row = row };
    }
    const entry = typedEntry(menu, words, defaults);
    if (entry.id.len == 0 or entry.id.len > model_catalog.max_model_bytes or !std.unicode.utf8ValidateSlice(entry.id)) return null;
    var typed: Bounded(model_catalog.max_model_bytes) = .{ .len = entry.id.len };
    @memcpy(typed.bytes[0..entry.id.len], entry.id);
    return .{ .index = menu.entries.len, .row = query.typed(entry, defaults), .typed = typed };
}

/// Retain controls that the refreshed row still offers.
pub fn retain(choice: Choice, previous: Choice) Choice {
    if (choice.typed.len != 0 and previous.typed.len != 0 and !choice.typed.eql(previous.typed.slice())) return choice;
    var kept = choice;
    if (previous.row.effort) |effort| {
        if (kept.row.efforts.contains(effort)) kept.row.effort = effort;
    }
    if (kept.row.providers.contains(previous.row.provider)) kept.row.provider = previous.row.provider;
    return kept;
}

/// Apply a key or a hit-tested click. A save borrows the Menu's model ID.
pub fn step(menu: *const picker.Menu, words: []const u8, defaults: picker.Defaults, choice: *?Choice, action: Action) ?Saved {
    const query = picker.Query.parse(words);
    if (action == .click) {
        const click = action.click;
        if (click.index >= menu.entries.len) {
            if (click.index != menu.entries.len or choice.* == null or choice.*.?.typed.len == 0) return null;
        } else {
            const row = query.row(menu.entries[click.index], defaults) orelse return null;
            if (choice.* == null or choice.*.?.index != click.index) choice.* = .{ .index = click.index, .row = row };
        }
        return switch (click.target) {
            .model => step(menu, words, defaults, choice, .save),
            .lower_effort => step(menu, words, defaults, choice, .lower_effort),
            .higher_effort => step(menu, words, defaults, choice, .higher_effort),
            .sign_in => |provider| step(menu, words, defaults, choice, .{ .choose_sign_in = provider }),
        };
    }
    const current = choice.* orelse return null;
    switch (action) {
        .previous => {
            if (current.typed.len != 0) return null;
            var index = current.index;
            while (index > 0) {
                index -= 1;
                if (query.row(menu.entries[index], defaults)) |row| {
                    choice.* = .{ .index = index, .row = row };
                    break;
                }
            }
        },
        .next => {
            var index = current.index + 1;
            while (index < menu.entries.len) : (index += 1) {
                if (query.row(menu.entries[index], defaults)) |row| {
                    choice.* = .{ .index = index, .row = row };
                    break;
                }
            }
        },
        .lower_effort => choice.*.?.row = current.row.stepEffort(.lower),
        .higher_effort => choice.*.?.row = current.row.stepEffort(.higher),
        .next_sign_in => choice.*.?.row = current.row.nextSignIn(),
        .choose_sign_in => |provider| if (current.row.providers.contains(provider)) {
            choice.*.?.row.provider = provider;
        },
        .select => |index| {
            if (index < menu.entries.len) if (query.row(menu.entries[index], defaults)) |row| {
                choice.* = .{ .index = index, .row = row };
            };
        },
        .click => unreachable,
        .save => return .{ .model = choice.*.?.entry(menu).id, .effort = current.row.effort, .provider = current.row.provider },
    }
    return null;
}

test "model picker view opens on the saved default without changing row order" {
    var menu = try picker.testMenu(&.{.{ .provider = .openai, .list = .{ .live = .{ .bytes = "gpt-6.1-sol\ngpt-6.1-terra\nft:custom\n" } } }});
    defer menu.deinit(std.testing.allocator);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "gpt-6.1-terra", "ft:custom" }) |id| {
        const defaults: picker.Defaults = .{ .model = id };
        var choice = open(&menu, "", defaults);
        try std.testing.expectEqualStrings(id, menu.entries[choice.?.index].id);
        try std.testing.expectEqualStrings(id, step(&menu, "", defaults, &choice, .save).?.model);
        const shown = try lines(arena.allocator(), &menu, "", defaults, choice, 100);
        var previous: ?usize = null;
        for (shown.rows) |line| if (line.model) |index| {
            if (previous) |old| try std.testing.expect(old < index);
            previous = index;
        };
        choice = select(&menu, "", defaults, choice.?.index);
        try std.testing.expectEqualStrings(id, menu.entries[choice.?.index].id);
        choice = select(&menu, "sol", defaults, choice.?.index);
        try std.testing.expectEqualStrings("gpt-6.1-sol", menu.entries[choice.?.index].id);
    }
    const missing = open(&menu, "", .{ .model = "not-offered" });
    try std.testing.expectEqual(@as(usize, 0), missing.?.index);
    const unmatched = open(&menu, "sol", .{ .model = "gpt-6.1-terra" });
    try std.testing.expectEqualStrings("gpt-6.1-sol", menu.entries[unmatched.?.index].id);
}

test "model picker view filters and saves the selected row's controls" {
    var menu = try picker.testMenu(&.{
        .{ .provider = .codex, .list = .{ .live = .{ .bytes = "gpt-6.1-sol\ngpt-6.1-terra\n" } } },
        .{ .provider = .openai, .list = .{ .live = .{ .bytes = "gpt-6.1-sol\ngpt-6.1-terra\n" } } },
    });
    defer menu.deinit(std.testing.allocator);
    const defaults: picker.Defaults = .{ .model = "gpt-6.1-sol", .provider = .codex, .effort = .high };
    var selected = select(&menu, "terra low api", defaults, null);
    try std.testing.expect(selected != null);
    try std.testing.expectEqualStrings("gpt-6.1-terra", menu.entries[selected.?.index].id);
    const saved = step(&menu, "terra low api", defaults, &selected, .save).?;
    try std.testing.expectEqualStrings("gpt-6.1-terra", saved.model);
    try std.testing.expectEqual(picker.ReasoningEffort.low, saved.effort.?);
    try std.testing.expectEqual(picker.Provider.openai, saved.provider);
    _ = step(&menu, "terra low api", defaults, &selected, .next_sign_in);
    try std.testing.expectEqual(picker.Provider.codex, selected.?.row.provider);
    const index = selected.?.index;
    _ = step(&menu, "terra low api", defaults, &selected, .{ .click = .{ .index = index, .target = .{ .sign_in = .openai } } });
    const clicked = step(&menu, "terra low api", defaults, &selected, .{ .click = .{ .index = index, .target = .model } }).?;
    try std.testing.expectEqual(picker.Provider.openai, clicked.provider);
    _ = step(&menu, "terra low api", defaults, &selected, .higher_effort);
    try std.testing.expectEqual(picker.ReasoningEffort.medium, selected.?.row.effort.?);
    _ = step(&menu, "terra low api", defaults, &selected, .{ .click = .{ .index = index, .target = .lower_effort } });
    try std.testing.expectEqual(picker.ReasoningEffort.low, selected.?.row.effort.?);
    selected = select(&menu, "sol", defaults, selected.?.index);
    try std.testing.expectEqualStrings("gpt-6.1-sol", menu.entries[selected.?.index].id);
    try std.testing.expectEqualStrings("no-such-model", select(&menu, "no-such-model", defaults, null).?.entry(&menu).id);
}

test "model picker view drops columns before the ID without prose rows" {
    var menu = try picker.testMenu(&.{
        .{ .provider = .codex, .list = .{ .live = .{ .bytes = "gpt-6.1-terra\ngpt-6.1-sol\n" } } },
        .{ .provider = .openai, .list = .{ .live = .{ .bytes = "gpt-6.1-terra\ngpt-6.1-sol\nft:custom\n" } } },
    });
    defer menu.deinit(std.testing.allocator);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const defaults: picker.Defaults = .{ .model = "gpt-6.1-sol", .provider = .codex, .effort = .high };
    const selected = select(&menu, "terra", defaults, null).?;
    const wide = try lines(arena.allocator(), &menu, "terra", defaults, selected, 100);
    try std.testing.expectEqualStrings("   gpt-6.1-terra  1M     ‹ high ›   [ChatGPT]  API key", wide.rows[0].text);
    try std.testing.expectEqual(@as(?u32, 0), wide.selected);
    const no_context = try lines(arena.allocator(), &menu, "terra", defaults, selected, 47);
    try std.testing.expectEqualStrings("   gpt-6.1-terra  ‹ high ›   [ChatGPT]  API key", no_context.rows[0].text);
    const one_sign_in = try lines(arena.allocator(), &menu, "terra", defaults, selected, 38);
    try std.testing.expectEqualStrings("   gpt-6.1-terra  ‹ high ›   [ChatGPT]", one_sign_in.rows[0].text);
    const truncated = try lines(arena.allocator(), &menu, "terra", defaults, selected, 31);
    try std.testing.expectEqualStrings("   gpt-6…  ‹ high ›   [ChatGPT]", truncated.rows[0].text);
    const all = try lines(arena.allocator(), &menu, "custom", defaults, select(&menu, "custom", defaults, null), 100);
    try std.testing.expectEqual(@as(usize, 1), all.rows.len);
    try std.testing.expect(!all.rows[0].heading);
    try std.testing.expect(std.mem.indexOf(u8, all.rows[0].text, "API key") == null);
}

test "model picker view separates the saved mark and highlighted controls" {
    var menu = try picker.testMenu(&.{
        .{ .provider = .codex, .list = .{ .live = .{ .bytes = "gpt-6.1-sol\n" } } },
        .{ .provider = .openai, .list = .{ .live = .{ .bytes = "gpt-6.1-sol\n" } } },
    });
    defer menu.deinit(std.testing.allocator);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const defaults: picker.Defaults = .{ .model = "gpt-6.1-sol", .provider = .codex, .effort = .high };
    const shown = try lines(arena.allocator(), &menu, "", defaults, open(&menu, "", defaults), 80);
    var mark = false;
    var effort = false;
    var sign_in = false;
    for (shown.rows[0].segments) |segment| {
        if (std.mem.eql(u8, segment.text, "✓")) mark = segment.style.colour == .mark;
        if (std.mem.eql(u8, segment.text, "‹ high ›")) effort = segment.style.bold;
        if (std.mem.eql(u8, segment.text, "[ChatGPT]")) sign_in = segment.style.bold;
    }
    try std.testing.expect(mark and effort and sign_in);
}

test "model picker view has only choices for every read and sign-in state" {
    var menu = try picker.testMenu(&.{.{ .provider = .openai, .list = .pending }});
    defer menu.deinit(std.testing.allocator);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for (std.enums.values(Read)) |read| {
        for (std.enums.values(@import("model_list.zig").Source)) |source| {
            menu.sources.set(.openai, source);
            const plan = try rows(arena.allocator(), &menu, "no-match", .{}, null, 80, .unicode, true, read);
            try std.testing.expectEqual(@as(usize, 1), plan.count);
            const row = try plan.row(arena.allocator(), 0);
            try std.testing.expect(row.model != null and !row.heading);
            try std.testing.expect(std.mem.indexOf(u8, row.text, "no-match") != null);
            try std.testing.expect(std.mem.indexOf(u8, row.text, "API key") == null);
        }
    }
    const empty: picker.Menu = .{};
    for (std.enums.values(Read)) |read| {
        const plan = try rows(arena.allocator(), &empty, "", .{}, null, 80, .unicode, true, read);
        try std.testing.expectEqual(@as(usize, 0), plan.count);
        var choice = select(&empty, "my-unlisted-model", .{}, null);
        const saved = step(&empty, "my-unlisted-model", .{}, &choice, .save).?;
        try std.testing.expectEqualStrings("my-unlisted-model", saved.model);
    }
}

test "model picker truncated rows and overflow use ASCII in an ASCII locale" {
    var id: [128]u8 = @splat('a');
    const entries = [_]picker.Entry{.{ .id = &id, .known = false, .catalogued = false, .providers = .initOne(.openai) }};
    const menu: picker.Menu = .{ .entries = &entries };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const plan = try rows(arena.allocator(), &menu, "", .{}, open(&menu, "", .{}), 30, .unicode, false, .read);
    const row = try plan.row(arena.allocator(), plan.selected.?);
    try std.testing.expect(std.mem.indexOfScalar(u8, row.text, '.') != null);
    for (row.text) |byte| try std.testing.expect(byte < 128);
}

test "model picker view truncates long live model IDs without losing controls" {
    var id: [2048]u8 = @splat('a');
    var providers: picker.Providers = .empty;
    providers.insert(.openai);
    const entries = [_]picker.Entry{.{ .id = &id, .known = false, .catalogued = false, .providers = providers }};
    const menu: picker.Menu = .{ .entries = &entries };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const choice = select(&menu, "", .{}, null);
    const shown = try lines(arena.allocator(), &menu, "", .{}, choice, 30);
    const selected = shown.rows[shown.selected.?];
    try std.testing.expect(cells(selected.text) <= 30);
    try std.testing.expect(std.mem.indexOf(u8, selected.text, "…") != null);
    try std.testing.expect(std.mem.indexOf(u8, selected.text, "API key") == null);
}

test "model picker view drops other efforts without losing the selected model" {
    var menu = try picker.testMenu(&.{.{ .provider = .openai, .list = .{ .live = .{ .bytes = "gpt-6.1-sol\nopenai/gpt-4.1\n" } } }});
    defer menu.deinit(std.testing.allocator);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const selected = select(&menu, "", .{}, menu.find("openai/gpt-4.1")).?;
    const narrow = try lines(arena.allocator(), &menu, "", .{}, selected, 30);
    var selected_visible = false;
    for (narrow.rows) |line| if (line.model) |index| {
        if (index == selected.index) {
            try std.testing.expect(std.mem.indexOf(u8, line.text, "openai/gpt-4.1") != null);
            selected_visible = true;
        } else try std.testing.expect(std.mem.indexOf(u8, line.text, "low") == null);
    };
    try std.testing.expect(selected_visible);
}

test "model picker view uses the Host's known flag for the displayed limit" {
    var menu = try picker.testMenu(&.{.{ .provider = .openai, .list = .{ .live = .{ .bytes = "gpt-6.1-sol\n" } } }});
    defer menu.deinit(std.testing.allocator);
    var entries = [_]picker.Entry{menu.entries[0]};
    entries[0].known = false;
    const host_menu: picker.Menu = .{ .entries = &entries };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const shown = try lines(arena.allocator(), &host_menu, "", .{}, select(&host_menu, "", .{}, null), 100);
    const text = shown.rows[shown.selected.?].text;
    try std.testing.expect(std.mem.indexOf(u8, text, "1M") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "K") == null);
}

test "model picker view moves only among matching models and keeps single choices unchanged" {
    var menu = try picker.testMenu(&.{.{ .provider = .openai, .list = .{ .live = .{ .bytes = "gpt-6.1-sol\nopenai/gpt-4.1\nchat-model\n" } } }});
    defer menu.deinit(std.testing.allocator);
    var choice = select(&menu, "", .{}, menu.find("openai/gpt-4.1"));
    const initial = choice.?.row;
    _ = step(&menu, "", .{}, &choice, .higher_effort);
    _ = step(&menu, "", .{}, &choice, .next_sign_in);
    try std.testing.expectEqual(initial.effort, choice.?.row.effort);
    try std.testing.expectEqual(initial.provider, choice.?.row.provider);
    _ = step(&menu, "", .{}, &choice, .next);
    try std.testing.expect(choice.?.index > menu.find("openai/gpt-4.1").?);
    _ = step(&menu, "", .{}, &choice, .previous);
    try std.testing.expectEqual(menu.find("openai/gpt-4.1").?, choice.?.index);
    choice = select(&menu, "openai/gpt-4.1", .{}, choice.?.index);
    try std.testing.expectEqual(menu.find("openai/gpt-4.1").?, choice.?.index);
    try std.testing.expect(choice.?.row.effort == null);
    _ = step(&menu, "openai/gpt-4.1", .{}, &choice, .lower_effort);
    try std.testing.expect(choice.?.row.effort == null);
}

test "model picker domain narrows several one none and saves an owned typed choice" {
    var menu = try picker.testMenu(&.{
        .{ .provider = .codex, .list = .{ .live = .{ .bytes = "gpt-6.1-sol\ngpt-6.1-terra\n" } } },
        .{ .provider = .openai, .list = .{ .live = .{ .bytes = "gpt-6.1-sol\ngpt-6.1-terra\nprivate-chat\n" } } },
    });
    defer menu.deinit(std.testing.allocator);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const defaults: picker.Defaults = .{ .model = "gpt-6.1-sol", .provider = .codex, .effort = .low };
    const cases = .{
        .{ "gpt-6.1", 2, "gpt-6.1-sol" },
        .{ "terra low api", 1, "gpt-6.1-terra" },
        .{ "private-chat", 1, "private-chat" },
        .{ "not-yet-listed", 1, "not-yet-listed" },
        .{ "unmatched words", 1, "unmatched words" },
    };
    inline for (cases) |case| {
        var choice = open(&menu, case[0], defaults);
        const plan = try rows(arena.allocator(), &menu, case[0], defaults, choice, 100, .unicode, true, .read);
        try std.testing.expectEqual(@as(usize, case[1]), plan.count);
        const selected = try plan.row(arena.allocator(), plan.selected.?);
        try std.testing.expect(selected.model != null and !selected.heading);
        try std.testing.expect(std.mem.indexOf(u8, selected.text, case[2]) != null);
        try std.testing.expect(std.mem.indexOf(u8, selected.text, "‹ low ›") != null);
        const saved = step(&menu, case[0], defaults, &choice, .save).?;
        try std.testing.expectEqualStrings(case[2], saved.model);
        if (std.mem.eql(u8, case[0], "terra low api")) try std.testing.expectEqual(picker.Provider.openai, saved.provider);
        _ = step(&menu, case[0], defaults, &choice, .next);
        _ = step(&menu, case[0], defaults, &choice, .previous);
    }
    // A composer edit cannot rewrite an already selected typed ID.
    var words = "typed-custom".*;
    var typed = select(&menu, &words, defaults, null);
    @memset(&words, 'x');
    try std.testing.expectEqualStrings("typed-custom", step(&menu, "typed-custom", defaults, &typed, .save).?.model);
    _ = step(&menu, "typed-custom", defaults, &typed, .higher_effort);
    try std.testing.expectEqual(picker.ReasoningEffort.medium, typed.?.row.effort.?);
    _ = step(&menu, "typed-custom", defaults, &typed, .next_sign_in);
    try std.testing.expectEqual(picker.Provider.openai, typed.?.row.provider);
    const clicked = step(&menu, "typed-custom", defaults, &typed, .{ .click = .{ .index = menu.entries.len, .target = .model } }).?;
    try std.testing.expectEqualStrings("typed-custom", clicked.model);
}

test "model picker domain accounts for overflow at every selection height and width" {
    var menu = try picker.testMenu(&.{.{ .provider = .openai, .list = .{ .live = .{ .bytes = "chat-a\nchat-b\nchat-c\nchat-d\nchat-e\nchat-f\nchat-g\nchat-h\nchat-i\nchat-j\n" } } }});
    defer menu.deinit(std.testing.allocator);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for (menu.entries, 0..) |entry, selected| {
        for (0..14) |height| {
            for ([_]usize{ 10, 40, 100 }) |width| {
                const choice = select(&menu, "", .{}, selected);
                const plan = try rowsIn(arena.allocator(), &menu, "", .{}, choice, width, height, .unicode, true, .read);
                try std.testing.expect(plan.count <= height);
                if (height == 0) {
                    try std.testing.expect(plan.selected == null);
                    continue;
                }
                const shown = try plan.row(arena.allocator(), plan.selected.?);
                try std.testing.expectEqual(@as(?usize, selected), shown.model);
                if (width >= 40) try std.testing.expect(std.mem.indexOf(u8, shown.text, entry.id) != null);
                if (height < 3) continue;
                var visible: usize = 0;
                for (0..plan.count) |at| {
                    const row = try plan.row(arena.allocator(), at);
                    if (row.model != null) {
                        visible += 1;
                    } else {
                        for (row.segments) |segment| try std.testing.expectEqual(overview.Colour.quiet, segment.style.colour);
                        var buffer: [40]u8 = undefined;
                        const expected = if (at == 0)
                            try std.fmt.bufPrint(&buffer, "↑ {d} more", .{plan.first})
                        else
                            try std.fmt.bufPrint(&buffer, "↓ {d} more", .{menu.entries.len - plan.end});
                        try std.testing.expectEqualStrings(expected, row.text);
                    }
                }
                try std.testing.expectEqual(menu.entries.len, plan.first + visible + menu.entries.len - plan.end);
            }
        }
    }
    const top = try rowsIn(arena.allocator(), &menu, "", .{}, select(&menu, "", .{}, 0), 80, 7, .unicode, true, .read);
    try std.testing.expectEqualStrings("↓ 4 more", (try top.row(arena.allocator(), 6)).text);
    const bottom = try rowsIn(arena.allocator(), &menu, "", .{}, select(&menu, "", .{}, 9), 80, 7, .unicode, true, .read);
    try std.testing.expectEqualStrings("↑ 4 more", (try bottom.row(arena.allocator(), 0)).text);
}

test "model picker domain shows provider columns only across sign-ins and short known contexts" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_]bool{ false, true }) |both| {
        const lists = [_]@import("model_list.zig").Entry{
            .{ .provider = .openai, .list = .{ .live = .{ .bytes = "gpt-6.1-sol\ngpt-5.3-codex\nprivate-chat\n" } } },
            .{ .provider = .codex, .list = .{ .live = .{ .bytes = "gpt-6.1-sol\n" } } },
        };
        var menu = try picker.testMenu(lists[0..if (both) @as(usize, 2) else 1]);
        defer menu.deinit(std.testing.allocator);
        const plan = try rows(arena.allocator(), &menu, "", .{}, open(&menu, "", .{}), 100, .unicode, true, .read);
        for (0..plan.count) |at| {
            const row = try plan.row(arena.allocator(), at);
            const id = menu.entries[row.model.?].id;
            const provider_shown = std.mem.indexOf(u8, row.text, "API key") != null or std.mem.indexOf(u8, row.text, "ChatGPT") != null;
            try std.testing.expectEqual(both, provider_shown);
            const limit: ?[]const u8 = if (std.mem.eql(u8, id, "gpt-6.1-sol")) "1M" else if (std.mem.eql(u8, id, "gpt-5.3-codex")) "400K" else null;
            if (limit) |text| {
                try std.testing.expect(std.mem.indexOf(u8, row.text, text) != null);
            } else {
                try std.testing.expect(std.mem.indexOf(u8, row.text, "K") == null);
                try std.testing.expect(std.mem.indexOf(u8, row.text, "M") == null);
            }
        }
        const private = try rows(arena.allocator(), &menu, "private-chat", .{}, open(&menu, "private-chat", .{}), 100, .unicode, true, .read);
        const row = try private.row(arena.allocator(), 0);
        try std.testing.expect(std.mem.indexOf(u8, row.text, "API key") == null);
    }
}
