//! Shared model-picker values. Every selection owns its model ID, whether
//! listed or typed; neither menu replacement nor composer edits invalidate it.
const std = @import("std");
const model_catalog = @import("model_catalog.zig");
const gwidth = @import("terminal_width");
const picker = @import("model_picker.zig");
const Bounded = @import("bounded.zig").Bounded;
const overview = @import("overview_style.zig");

pub const Choice = struct {
    id: Bounded(model_catalog.max_model_bytes),
    row: picker.Row,

    fn of(entry_: picker.Entry, row: picker.Row) Choice {
        std.debug.assert(model_catalog.validModelSyntax(entry_.id));
        var id: Bounded(model_catalog.max_model_bytes) = .{ .len = 0 };
        id.set(entry_.id) catch unreachable;
        return .{ .id = id, .row = row };
    }

    /// A frame's menu position, or its synthetic-row sentinel. Not identity.
    pub fn index(self: *const Choice, menu: *const picker.Menu) usize {
        return menu.find(self.id.slice()) orelse menu.entries.len;
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

/// A row for GroupedList owns the model identity and controls it drew.
/// Prose is not selectable.
pub const Control = struct { start: u16, end: u16, target: Click.Target };
pub const Line = struct { text: []const u8, segments: []const overview.Segment, model: ?Choice = null, heading: bool = false, controls: []const Control = &.{} };
pub const Lines = struct { rows: []Line, selected: ?u32 };
pub const Read = enum { unread, read, unanswered, invalid };

const Columns = struct { context: bool = true, sign_ins: bool = false, all_sign_ins: bool = true, mark_gap: usize = 2 };

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
    typed_row: bool,

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
        if (self.typed_row) return self.modelLine(arena, typedEntry(self.menu, self.query.words, self.defaults), self.menu.entries.len);
        var at: usize = 0;
        for (self.menu.entries, 0..) |entry, index| {
            _ = self.query.row(entry, self.defaults) orelse continue;
            if (at == ordinal) return self.modelLine(arena, entry, index);
            at += 1;
        }
        unreachable;
    }

    fn modelLine(self: Rows, arena: std.mem.Allocator, entry: picker.Entry, index: usize) !Line {
        const synthetic = index == self.menu.entries.len;
        const highlighted = if (self.choice) |c| c.id.eql(entry.id) else synthetic;
        const base = if (synthetic) self.query.typed(entry, self.defaults) else self.query.row(entry, self.defaults).?;
        const selected_row = if (highlighted and self.choice != null) self.choice.?.row else base;
        const buffer = try arena.alloc(u8, @max(entry.id.len, self.widest) + 256);
        const formatted = format(buffer, entry, selected_row, highlighted, self.widest, self.columns, self.method, self.unicode);
        const text = try arena.dupe(u8, formatted.text);
        return .{ .text = text, .segments = try segments(arena, text, formatted), .model = Choice.of(entry, selected_row), .controls = try arena.dupe(Control, formatted.controls[0..formatted.control_count]) };
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
    return .{ .id = words, .known = false, .catalogued = false, .providers = providers };
}

/// Multiword filters may narrow real rows, but only a valid model ID can
/// become a typed row. Invalid unmatched words leave the full chat list.
/// Every row reads the menu's query, so each offers only `Menu.offered`.
fn matchingQuery(menu: *const picker.Menu, words: []const u8, defaults: picker.Defaults) picker.Query {
    const query = menu.query(words, defaults);
    if (model_catalog.validModelSyntax(words)) return query;
    for (menu.entries) |entry| if (query.row(entry, defaults) != null) return query;
    return menu.query("", defaults);
}

/// Build an unbounded plan; the shell applies the actual list viewport.
pub fn rows(arena: std.mem.Allocator, menu: *const picker.Menu, words: []const u8, defaults: picker.Defaults, choice: ?Choice, width: usize, method: gwidth.Method, unicode: bool, read: Read) !Rows {
    _ = read; // Transport/list state is not a model choice or a prose row.
    const query = matchingQuery(menu, words, defaults);
    var widest: usize = 0;
    var count: usize = 0;
    var selected: ?u32 = null;
    var providers: picker.Providers = .empty;
    for (menu.entries) |entry| {
        const row = query.row(entry, defaults) orelse continue;
        widest = @max(widest, entry.id.len);
        providers.setUnion(row.providers);
        if (choice) |c| if (c.id.eql(entry.id)) {
            selected = @intCast(count);
        };
        count += 1;
    }
    // A typed ID is a fallback, never an extra row beside listed matches.
    const typed_row = count == 0 and model_catalog.validModelSyntax(query.words);
    if (typed_row) {
        const entry = typedEntry(menu, query.words, defaults);
        widest = @max(widest, entry.id.len);
        providers.setUnion(query.typed(entry, defaults).providers);
        count += 1;
        selected = 0;
    }
    const buffer = try arena.alloc(u8, widest + 256);
    var columns: Columns = .{ .sign_ins = providers.count() > 1 };
    if (needed(buffer, menu, query, defaults, choice, widest, columns, method, unicode, typed_row) > width) columns.context = false;
    if (needed(buffer, menu, query, defaults, choice, widest, columns, method, unicode, typed_row) > width) columns.all_sign_ins = false;
    widest = @min(widest, width -| needed(buffer, menu, query, defaults, choice, 0, columns, method, unicode, typed_row));
    return .{ .menu = menu, .query = query, .defaults = defaults, .choice = choice, .widest = widest, .columns = columns, .method = method, .unicode = unicode, .count = count, .selected = selected, .total = count, .end = count, .typed_row = typed_row };
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

/// A field choice uses the picker's model row without its overview status
/// sentences or effort/sign-in controls. Width is the full field-choice width.
pub fn modelLine(arena: std.mem.Allocator, entry: picker.Entry, row: picker.Row, id_width: usize, width: usize, unicode: bool) !Line {
    const buffer = try arena.alloc(u8, @max(entry.id.len, id_width) + 256);
    var columns: Columns = .{ .mark_gap = 1 };
    if (cells(format(buffer, entry, row, false, id_width, columns, .unicode, unicode).text) > width) columns.context = false;
    if (cells(format(buffer, entry, row, false, id_width, columns, .unicode, unicode).text) > width) columns.all_sign_ins = false;
    const reserved = cells(format(buffer, entry, row, false, 0, columns, .unicode, unicode).text);
    const formatted = format(buffer, entry, row, false, @min(id_width, width -| reserved), columns, .unicode, unicode);
    const text = try arena.dupe(u8, formatted.text);
    return .{ .text = text, .segments = try segments(arena, text, formatted) };
}

fn needed(buffer: []u8, menu: *const picker.Menu, query: picker.Query, defaults: picker.Defaults, choice: ?Choice, id_width: usize, columns: Columns, method: gwidth.Method, unicode: bool, typed_row: bool) usize {
    if (typed_row) {
        const entry = typedEntry(menu, query.words, defaults);
        const row = if (choice) |c| if (c.id.eql(entry.id)) c.row else query.typed(entry, defaults) else query.typed(entry, defaults);
        return gwidth.gwidth(format(buffer, entry, row, true, id_width, columns, method, unicode).text, method);
    }
    var max: usize = 0;
    for (menu.entries) |entry| {
        const base = query.row(entry, defaults) orelse continue;
        const highlighted = if (choice) |c| c.id.eql(entry.id) else false;
        const row = if (highlighted) choice.?.row else base;
        max = @max(max, gwidth.gwidth(format(buffer, entry, row, highlighted, id_width, columns, method, unicode).text, method));
    }
    return max;
}

fn cells(text: []const u8) usize {
    return gwidth.gwidth(text, .unicode);
}

const Range = struct { start: usize, end: usize, style: overview.Style };
/// The effort arrows and one sign-in per provider a row can offer.
const max_controls = 2 + @typeInfo(picker.Provider).@"enum".field_names.len;
const Formatted = struct { text: []const u8, ranges: [3]?Range = @splat(null), controls: [max_controls]Control = undefined, control_count: usize = 0 };

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
    var controls: [max_controls]Control = undefined;
    var control_count: usize = 0;
    const mark = if (unicode) "✓" else "+";
    out.writeAll(if (row.current) mark else " ") catch unreachable;
    for (0..columns.mark_gap) |_| out.writeByte(' ') catch unreachable;
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
                const start_col: u16 = @intCast(gwidth.gwidth(out.buffered()[0..control_start], method));
                const end_col: u16 = @intCast(gwidth.gwidth(out.buffered(), method));
                controls[control_count] = .{ .start = start_col, .end = start_col + 1, .target = .lower_effort };
                controls[control_count + 1] = .{ .start = end_col - 1, .end = end_col, .target = .higher_effort };
                control_count += 2;
            } else out.print("  {s}", .{@tagName(effort)}) catch unreachable;
        }
        while (gwidth.gwidth(out.buffered(), method) - start < 11) out.writeByte(' ') catch unreachable;
    }
    var offered = (if (columns.sign_ins) row.providers else picker.Providers.empty).iterator();
    while (offered.next()) |provider| {
        if (!columns.all_sign_ins and provider != row.provider) continue;
        const control_start_col = gwidth.gwidth(out.buffered(), method) + 2;
        const boxed = highlighted and row.providers.count() > 1 and provider == row.provider;
        if (boxed) {
            out.writeAll("  ") catch unreachable;
            const control_start = out.buffered().len;
            out.print("[{s}]", .{provider.signIn()}) catch unreachable;
            ranges[2] = .{ .start = control_start, .end = out.buffered().len, .style = .{ .colour = .strong, .bold = true } };
        } else out.print("  {s}", .{provider.signIn()}) catch unreachable;
        if (row.providers.count() > 1) {
            controls[control_count] = .{ .start = @intCast(control_start_col), .end = @intCast(gwidth.gwidth(out.buffered(), method)), .target = .{ .sign_in = provider } };
            control_count += 1;
        }
    }
    return .{ .text = out.buffered(), .ranges = ranges, .controls = controls, .control_count = control_count };
}

/// Opening highlights the saved default when offered and matching, without
/// moving it out of its group. Otherwise it selects the first matching row.
pub fn open(menu: *const picker.Menu, words: []const u8, defaults: picker.Defaults) ?Choice {
    return select(menu, words, defaults, null);
}

/// Select after a draft edit or menu reply. Keep a matching highlighted ID,
/// then prefer the matching default, otherwise the first listed match.
/// Only when none match may the words themselves become a typed choice.
pub fn select(menu: *const picker.Menu, words: []const u8, defaults: picker.Defaults, wanted: ?usize) ?Choice {
    const query = matchingQuery(menu, words, defaults);
    const saved = if (defaults.model) |id| menu.find(id) else null;
    for ([_]?usize{ wanted, saved }) |candidate| if (candidate) |index| {
        if (index < menu.entries.len) if (query.row(menu.entries[index], defaults)) |row| return Choice.of(menu.entries[index], row);
    };
    for (menu.entries) |entry| {
        if (query.row(entry, defaults)) |row| return Choice.of(entry, row);
    }
    const entry = typedEntry(menu, query.words, defaults);
    if (!model_catalog.validModelSyntax(entry.id)) return null;
    return Choice.of(entry, query.typed(entry, defaults));
}

/// Retain controls that the refreshed row still offers.
pub fn retain(choice: Choice, previous: Choice) Choice {
    if (!choice.id.eql(previous.id.slice())) return choice;
    var kept = choice;
    if (previous.row.effort) |effort| {
        if (kept.row.efforts.contains(effort)) kept.row.effort = effort;
    }
    if (kept.row.providers.contains(previous.row.provider)) kept.row.provider = previous.row.provider;
    return kept;
}

/// Apply a key or a hit-tested click. A save borrows the choice's model ID.
pub fn step(menu: *const picker.Menu, words: []const u8, defaults: picker.Defaults, choice: *?Choice, action: Action) ?Saved {
    const query = matchingQuery(menu, words, defaults);
    if (action == .click) {
        const click = action.click;
        if (click.index >= menu.entries.len) {
            if (click.index != menu.entries.len or choice.* == null) return null;
            const listed = choice.*.?.index(menu);
            if (listed < menu.entries.len and query.row(menu.entries[listed], defaults) != null) return null;
        } else {
            const row = query.row(menu.entries[click.index], defaults) orelse return null;
            if (choice.* == null or !choice.*.?.id.eql(menu.entries[click.index].id)) choice.* = Choice.of(menu.entries[click.index], row);
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
            var index = current.index(menu);
            if (index == menu.entries.len) return null;
            while (index > 0) {
                index -= 1;
                if (query.row(menu.entries[index], defaults)) |row| {
                    choice.* = Choice.of(menu.entries[index], row);
                    break;
                }
            }
        },
        .next => {
            const listed = current.index(menu);
            var index = if (listed == menu.entries.len) 0 else listed + 1;
            while (index < menu.entries.len) : (index += 1) {
                if (query.row(menu.entries[index], defaults)) |row| {
                    choice.* = Choice.of(menu.entries[index], row);
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
                choice.* = Choice.of(menu.entries[index], row);
            };
        },
        .click => unreachable,
        .save => return .{ .model = choice.*.?.id.slice(), .effort = current.row.effort, .provider = current.row.provider },
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
        try std.testing.expectEqualStrings(id, menu.entries[choice.?.index(&menu)].id);
        try std.testing.expectEqualStrings(id, step(&menu, "", defaults, &choice, .save).?.model);
        const shown = try lines(arena.allocator(), &menu, "", defaults, choice, 100);
        var previous: ?usize = null;
        for (shown.rows) |line| if (line.model) |model| {
            const index = model.index(&menu);
            if (previous) |old| try std.testing.expect(old < index);
            previous = index;
        };
        choice = select(&menu, "", defaults, choice.?.index(&menu));
        try std.testing.expectEqualStrings(id, menu.entries[choice.?.index(&menu)].id);
        choice = select(&menu, "sol", defaults, choice.?.index(&menu));
        try std.testing.expectEqualStrings("gpt-6.1-sol", menu.entries[choice.?.index(&menu)].id);
    }
    const missing = open(&menu, "", .{ .model = "not-offered" });
    try std.testing.expectEqual(@as(usize, 0), missing.?.index(&menu));
    const unmatched = open(&menu, "sol", .{ .model = "gpt-6.1-terra" });
    try std.testing.expectEqualStrings("gpt-6.1-sol", menu.entries[unmatched.?.index(&menu)].id);
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
    try std.testing.expectEqualStrings("gpt-6.1-terra", menu.entries[selected.?.index(&menu)].id);
    const saved = step(&menu, "terra low api", defaults, &selected, .save).?;
    try std.testing.expectEqualStrings("gpt-6.1-terra", saved.model);
    try std.testing.expectEqual(picker.ReasoningEffort.low, saved.effort.?);
    try std.testing.expectEqual(picker.Provider.openai, saved.provider);
    _ = step(&menu, "terra low api", defaults, &selected, .next_sign_in);
    try std.testing.expectEqual(picker.Provider.codex, selected.?.row.provider);
    const index = selected.?.index(&menu);
    _ = step(&menu, "terra low api", defaults, &selected, .{ .click = .{ .index = index, .target = .{ .sign_in = .openai } } });
    const clicked = step(&menu, "terra low api", defaults, &selected, .{ .click = .{ .index = index, .target = .model } }).?;
    try std.testing.expectEqual(picker.Provider.openai, clicked.provider);
    _ = step(&menu, "terra low api", defaults, &selected, .higher_effort);
    try std.testing.expectEqual(picker.ReasoningEffort.medium, selected.?.row.effort.?);
    _ = step(&menu, "terra low api", defaults, &selected, .{ .click = .{ .index = index, .target = .lower_effort } });
    try std.testing.expectEqual(picker.ReasoningEffort.low, selected.?.row.effort.?);
    selected = select(&menu, "sol", defaults, selected.?.index(&menu));
    try std.testing.expectEqualStrings("gpt-6.1-sol", menu.entries[selected.?.index(&menu)].id);
    try std.testing.expectEqualStrings("no-such-model", select(&menu, "no-such-model", defaults, null).?.id.slice());
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

test "model picker view offers one ChatGPT, the saved way in, and keeps it whole in the overview's 40-column list pane" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // The overview draws the picker in its Session list pane, 40 columns
    // wide however wide the terminal is.
    const pane = 40;
    const Case = struct { saved: picker.Provider, hidden: picker.Provider, kept_only: []const u8, hidden_only: []const u8, wide: []const u8, after_tab: []const u8 };
    for ([_]bool{ false, true }) |with_openai| {
        const lists = [_]@import("model_list.zig").Entry{
            .{ .provider = .codex, .list = .{ .live = .{ .bytes = "gpt-6.1-sol\ngpt-6.1-terra\ndevice-only\n" } } },
            .{ .provider = .chatgpt, .list = .{ .live = .{ .bytes = "gpt-6.1-sol\ngpt-6.1-terra\nbrowser-only\n" } } },
            .{ .provider = .openai, .list = .{ .live = .{ .bytes = "gpt-6.1-sol\ngpt-6.1-terra\n" } } },
        };
        var menu = try picker.testMenu(lists[0..if (with_openai) @as(usize, 3) else 2]);
        defer menu.deinit(std.testing.allocator);
        for ([_]Case{
            .{ .saved = .codex, .hidden = .chatgpt, .kept_only = "device-only", .hidden_only = "browser-only", .wide = "✓  gpt-6.1-sol  1M     ‹ high ›   [ChatGPT]  API key", .after_tab = "✓  gpt-6.1-sol  ‹ high ›   [API key]" },
            .{ .saved = .chatgpt, .hidden = .codex, .kept_only = "browser-only", .hidden_only = "device-only", .wide = "✓  gpt-6.1-sol  1M     ‹ high ›   API key  [ChatGPT]", .after_tab = "✓  gpt-6.1-sol  ‹ high ›   [API key]" },
        }) |case| {
            const defaults: picker.Defaults = .{ .model = "gpt-6.1-sol", .provider = case.saved, .effort = .high };
            // Every row, at any width, names ChatGPT at most once, and a
            // model only the hidden way in lists has no row.
            for ([_]usize{ pane, 120 }) |width| {
                const all = try lines(arena.allocator(), &menu, "", defaults, open(&menu, "", defaults), width);
                var kept_shown = false;
                for (all.rows) |line| {
                    try std.testing.expect(std.mem.count(u8, line.text, "ChatGPT") <= 1);
                    try std.testing.expect(std.ascii.findIgnoreCase(line.text, "codex") == null);
                    const id = line.model.?.id.slice();
                    try std.testing.expect(!std.mem.eql(u8, id, case.hidden_only));
                    kept_shown = kept_shown or std.mem.eql(u8, id, case.kept_only);
                }
                try std.testing.expect(kept_shown);
            }
            // Either ChatGPT word chooses the saved way in, and the pane
            // keeps a 13-character ID whole beside it as well as the saved one.
            for ([_][]const u8{ "chatgpt", "codex", "api" }) |word| {
                if (std.mem.eql(u8, word, "api") and !with_openai) continue;
                const chosen: picker.Provider = if (std.mem.eql(u8, word, "api")) .openai else case.saved;
                for ([_][2][]const u8{ .{ "sol", "✓  gpt-6.1-sol  " }, .{ "terra", "   gpt-6.1-terra  " } }) |id| {
                    var buffer: [64]u8 = undefined;
                    const typed = try std.fmt.bufPrint(&buffer, "{s} {s}", .{ id[0], word });
                    const choice = select(&menu, typed, defaults, null);
                    try std.testing.expectEqual(chosen, choice.?.row.provider);
                    const shown = try lines(arena.allocator(), &menu, typed, defaults, choice, pane);
                    try std.testing.expectEqual(@as(usize, 1), shown.rows.len);
                    try std.testing.expect(std.mem.startsWith(u8, shown.rows[0].text, id[1]));
                    try std.testing.expect(std.mem.indexOf(u8, shown.rows[0].text, "…") == null);
                    if (with_openai) try std.testing.expect(std.mem.indexOf(u8, shown.rows[0].text, if (chosen == .openai) "[API key]" else "[ChatGPT]") != null);
                }
            }
            var choice = select(&menu, "sol", defaults, null);
            if (!with_openai) {
                // One sign-in offered: no sign-in column at all.
                try std.testing.expectEqualStrings("✓  gpt-6.1-sol  1M     ‹ high › ", (try lines(arena.allocator(), &menu, "sol", defaults, choice, 120)).rows[0].text);
                try std.testing.expectEqual(case.saved, choice.?.row.nextSignIn().provider);
                continue;
            }
            try std.testing.expectEqualStrings("✓  gpt-6.1-sol  ‹ high ›   [ChatGPT]", (try lines(arena.allocator(), &menu, "sol", defaults, choice, pane)).rows[0].text);
            // Wide, every sign-in the row offers shows beside the chosen one.
            try std.testing.expectEqualStrings(case.wide, (try lines(arena.allocator(), &menu, "sol", defaults, choice, 120)).rows[0].text);
            _ = step(&menu, "sol", defaults, &choice, .next_sign_in);
            try std.testing.expectEqualStrings(case.after_tab, (try lines(arena.allocator(), &menu, "sol", defaults, choice, pane)).rows[0].text);
            // Tab goes round the offered sign-ins and never lands on the
            // hidden way in.
            for (0..4) |_| {
                _ = step(&menu, "sol", defaults, &choice, .next_sign_in);
                try std.testing.expect(choice.?.row.provider != case.hidden);
            }
        }
    }
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
    var id: [model_catalog.max_model_bytes]u8 = @splat('a');
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
    for (narrow.rows) |line| if (line.model) |model| {
        if (model.index(&menu) == selected.index(&menu)) {
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
    try std.testing.expect(choice.?.index(&menu) > menu.find("openai/gpt-4.1").?);
    _ = step(&menu, "", .{}, &choice, .previous);
    try std.testing.expectEqual(menu.find("openai/gpt-4.1").?, choice.?.index(&menu));
    choice = select(&menu, "openai/gpt-4.1", .{}, choice.?.index(&menu));
    try std.testing.expectEqual(menu.find("openai/gpt-4.1").?, choice.?.index(&menu));
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
        .{ "unmatched words", 3, "gpt-6.1-sol" },
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

/// Exercise admission through the same select, row and save path as typed input.
fn expectTypedAdmission(menu: *const picker.Menu, words: []const u8, admitted: bool) !void {
    const defaults: picker.Defaults = .{ .model = "gpt-6.1-sol", .provider = .codex, .effort = .low };
    var choice = open(menu, words, defaults);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const plan = try rows(arena.allocator(), menu, words, defaults, choice, 100, .unicode, true, .read);
    try std.testing.expectEqual(if (admitted) @as(usize, 1) else menu.entries.len, plan.count);
    try std.testing.expectEqual(admitted, plan.typed_row);
    for (0..plan.count) |at| {
        const line = try plan.row(arena.allocator(), at);
        try std.testing.expectEqual(admitted, line.model.?.index(menu) == menu.entries.len);
    }
    const selected = try plan.row(arena.allocator(), plan.selected.?);
    try std.testing.expectEqual(admitted, selected.model.?.index(menu) == menu.entries.len);
    const saved = step(menu, words, defaults, &choice, .save).?;
    try std.testing.expectEqualStrings(if (admitted) words else "gpt-6.1-sol", saved.model);
    try std.testing.expect(model_catalog.validModelSyntax(saved.model));
    // Hit testing and keyboard actions consume the same effective query.
    const clicked = step(menu, words, defaults, &choice, .{ .click = .{ .index = selected.model.?.index(menu), .target = .model } }).?;
    try std.testing.expectEqualStrings(saved.model, clicked.model);
    _ = step(menu, words, defaults, &choice, .next);
    try std.testing.expectEqualStrings(if (admitted) words else "gpt-6.1-terra", choice.?.id.slice());
}

test "model picker typed choice admission spans bytes whitespace Unicode and length boundaries" {
    var menu = try picker.testMenu(&.{.{ .provider = .codex, .list = .{ .live = .{ .bytes = "gpt-6.1-sol\ngpt-6.1-terra\n" } } }});
    defer menu.deinit(std.testing.allocator);
    // An independent byte-domain oracle, including every control and high byte.
    var words = "missing-model-x".*;
    for (0..256) |byte| {
        words[words.len - 1] = @intCast(byte);
        try expectTypedAdmission(&menu, &words, byte >= 0x21 and byte <= 0x7e);
    }
    for ([_][]const u8{ "missing words", " missing", "missing ", " ", "\t", "missing\n", "missing\r", "missing-λ", "模型", "missing-\xff" }) |invalid| {
        try expectTypedAdmission(&menu, invalid, false);
    }
    const long: [model_catalog.max_model_bytes + 1]u8 = @splat('z');
    const cases = [_]struct { length: usize, admitted: bool }{
        .{ .length = 0, .admitted = false },
        .{ .length = 1, .admitted = true },
        .{ .length = model_catalog.max_model_bytes - 1, .admitted = true },
        .{ .length = model_catalog.max_model_bytes, .admitted = true },
        .{ .length = model_catalog.max_model_bytes + 1, .admitted = false },
    };
    for (cases) |case| try expectTypedAdmission(&menu, long[0..case.length], case.admitted);
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
                try std.testing.expectEqual(selected, shown.model.?.index(&menu));
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
            const id = row.model.?.id.slice();
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

test "model picker shared ASCII model rows preserve compact mark gap and truncation" {
    const entry: picker.Entry = .{ .id = "gpt-6.1-sol", .known = true, .catalogued = true, .providers = .initOne(.codex) };
    const row = picker.Query.parse("").row(entry, .{ .model = entry.id, .provider = .codex }).?;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for (0..100) |width| {
        const line = try modelLine(arena.allocator(), entry, row, entry.id.len, width, false);
        for (line.text) |byte| try std.testing.expect(byte < 0x80);
        try std.testing.expect(std.mem.startsWith(u8, line.text, "+ "));
    }
    const unicode = try modelLine(arena.allocator(), entry, row, entry.id.len, 99, true);
    try std.testing.expect(std.mem.startsWith(u8, unicode.text, "✓ gpt-6.1-sol"));
    const ascii = try modelLine(arena.allocator(), entry, row, entry.id.len, 99, false);
    try std.testing.expect(std.mem.startsWith(u8, ascii.text, "+ gpt-6.1-sol"));
}

test "model picker controls use printed cell columns for effort and every offered sign-in" {
    var menu = try picker.testMenu(&.{
        .{ .provider = .codex, .list = .{ .live = .{ .bytes = "gpt-6.1-sol\n" } } },
        .{ .provider = .openai, .list = .{ .live = .{ .bytes = "gpt-6.1-sol\n" } } },
    });
    defer menu.deinit(std.testing.allocator);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const defaults: picker.Defaults = .{ .provider = .codex, .effort = .high };
    const choice = open(&menu, "", defaults);
    for ([_]bool{ true, false }) |unicode| {
        const plan = try rows(arena.allocator(), &menu, "", defaults, choice, 100, .unicode, unicode, .read);
        const line = try plan.row(arena.allocator(), 0);
        try std.testing.expectEqual(@as(usize, 4), line.controls.len);
        const lower_byte = std.mem.indexOf(u8, line.text, if (unicode) "‹" else "<").?;
        const higher_byte = std.mem.indexOf(u8, line.text, if (unicode) "›" else ">").?;
        try std.testing.expectEqual(Control{ .start = @intCast(cells(line.text[0..lower_byte])), .end = @intCast(cells(line.text[0..lower_byte]) + 1), .target = .lower_effort }, line.controls[0]);
        try std.testing.expectEqual(Control{ .start = @intCast(cells(line.text[0..higher_byte])), .end = @intCast(cells(line.text[0..higher_byte]) + 1), .target = .higher_effort }, line.controls[1]);
        const chat = std.mem.indexOf(u8, line.text, "[ChatGPT]").?;
        const api = std.mem.indexOf(u8, line.text, "API key").?;
        try std.testing.expectEqual(Control{ .start = @intCast(cells(line.text[0..chat])), .end = @intCast(cells(line.text[0..chat]) + 9), .target = .{ .sign_in = .codex } }, line.controls[2]);
        try std.testing.expectEqual(Control{ .start = @intCast(cells(line.text[0..api])), .end = @intCast(cells(line.text[0..api]) + 7), .target = .{ .sign_in = .openai } }, line.controls[3]);
    }
}

test "model picker dropped columns keep remaining control hits on their printed labels" {
    var menu = try picker.testMenu(&.{
        .{ .provider = .codex, .list = .{ .live = .{ .bytes = "gpt-6.1-sol\n" } } },
        .{ .provider = .openai, .list = .{ .live = .{ .bytes = "gpt-6.1-sol\n" } } },
    });
    defer menu.deinit(std.testing.allocator);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const defaults: picker.Defaults = .{ .provider = .codex, .effort = .high };
    const choice = open(&menu, "", defaults);
    for ([_]usize{ 12, 32, 46, 80 }) |width| {
        const plan = try rows(arena.allocator(), &menu, "", defaults, choice, width, .unicode, true, .read);
        const line = try plan.row(arena.allocator(), 0);
        for (line.controls) |control| {
            const label: []const u8 = switch (control.target) {
                .model => return error.TestUnexpectedResult,
                .lower_effort => "‹",
                .higher_effort => "›",
                .sign_in => |provider| if (provider == .codex) "[ChatGPT]" else "API key",
            };
            const byte = std.mem.indexOf(u8, line.text, label).?;
            const column = cells(line.text[0..byte]);
            try std.testing.expectEqual(@as(u16, @intCast(column)), control.start);
            try std.testing.expectEqual(@as(u16, @intCast(column + cells(label))), control.end);
        }
        if (!plan.columns.all_sign_ins) for (line.controls) |control| {
            if (control.target == .sign_in) try std.testing.expectEqual(picker.Provider.codex, control.target.sign_in);
        };
    }
}
