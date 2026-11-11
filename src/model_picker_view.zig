//! Value decisions for the overview's /model picker. The screen owns the
//! Menu and draft; selection stores only an index into that Menu.
const std = @import("std");
const model_catalog = @import("model_catalog.zig");
const gwidth = @import("terminal_width");
const picker = @import("model_picker.zig");
const capability = @import("model_capability.zig");
const product_defaults = @import("product_defaults.zig");
const overview = @import("overview_style.zig");

pub const Choice = struct {
    index: usize,
    row: picker.Row,
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

const Columns = struct { context: bool = true, all_sign_ins: bool = true, other_effort: bool = true };

/// A frame's row plan. Text and segments are allocated only when a row is drawn.
pub const Rows = struct {
    menu: *const picker.Menu,
    query: picker.Query,
    defaults: picker.Defaults,
    choice: ?Choice,
    widest: usize,
    columns: Columns,
    method: gwidth.Method,
    unicode: bool,
    read: Read,
    count: usize,
    selected: ?u32,

    pub fn row(self: Rows, arena: std.mem.Allocator, wanted: usize) !Line {
        var at: usize = 0;
        if (readMessage(self.read, self.menu, self.unicode)) |message| {
            if (at == wanted) return simpleLine(arena, message, false);
            at += 1;
        }
        if (self.read == .read and self.menu.sources.get(picker.Provider.onlyWith(.sign_in)) == null) {
            if (at == wanted) return simpleLine(arena, (comptime picker.Provider.onlyWith(.sign_in).signIn()) ++ ": run " ++ (comptime picker.Provider.onlyWith(.sign_in).login()) ++ " in your shell", false);
            at += 1;
        }
        var previous_group: ?bool = null;
        for (self.menu.entries, 0..) |entry, index| {
            const base = self.query.row(entry, self.defaults) orelse continue;
            if (previous_group == null or previous_group.? != entry.known) {
                if (at == wanted) return simpleLine(arena, if (entry.known) "Known to Rui" else if (self.unicode) "From your API key · default limits" else "From your API key - default limits", true);
                at += 1;
                previous_group = entry.known;
            }
            if (at == wanted) {
                const highlighted = if (self.choice) |c| c.index == index else false;
                const selected_row = if (highlighted) self.choice.?.row else base;
                const buffer = try arena.alloc(u8, @max(entry.id.len, self.widest) + 256);
                const formatted = format(buffer, entry, selected_row, highlighted, self.widest, self.columns, self.method, self.unicode);
                const text = try arena.dupe(u8, formatted.text);
                return .{ .text = text, .segments = try segments(arena, text, formatted), .model = index };
            }
            at += 1;
        }
        if (sourceMessage(self.menu, self.read, self.unicode)) |message| {
            if (previous_group == null or previous_group.?) {
                if (at == wanted) return simpleLine(arena, if (self.unicode) "From your API key · default limits" else "From your API key - default limits", true);
                at += 1;
            }
            if (at == wanted) return simpleLine(arena, message, false);
        }
        unreachable;
    }
};

fn readMessage(read: Read, menu: *const picker.Menu, unicode: bool) ?[]const u8 {
    const kept = menu.entries.len != 0 or for (menu.sources.values) |source| {
        if (source != null) break true;
    } else false;
    return switch (read) {
        .read => null,
        .unread => if (unicode) "Loading models…" else "Loading models...",
        .unanswered => if (kept) "The Host did not answer; this is the last list" else "Models unavailable: the Host did not answer",
        .invalid => if (kept) "The Host's model list was not valid; this is the last list" else "Models unavailable: the Host's list was not valid",
    };
}

fn sourceMessage(menu: *const picker.Menu, read: Read, unicode: bool) ?[]const u8 {
    const source = menu.sources.get(picker.Provider.onlyLiveList()) orelse return if (read == .read) "API key: run " ++ (comptime picker.Provider.onlyLiveList().login()) ++ " in your shell" else null;
    return switch (source) {
        .pending => if (unicode) "API key: loading its models…" else "API key: loading its models...",
        .catalog_fallback => "API key: couldn't fetch its list; showing Rui's catalog",
        .catalog, .live => null,
    };
}

/// The plan borrows menu and words for the frame; only width scratch uses arena.
pub fn rows(arena: std.mem.Allocator, menu: *const picker.Menu, words: []const u8, defaults: picker.Defaults, choice: ?Choice, width: usize, method: gwidth.Method, unicode: bool, read: Read) !Rows {
    const query = picker.Query.parse(words);
    var widest: usize = 0;
    for (menu.entries) |entry| {
        if (query.row(entry, defaults) != null) widest = @max(widest, entry.id.len);
    }
    // Model IDs are printable ASCII, and may be as long as the live-list
    // limit. Allocate scratch for the actual menu rather than a fixed buffer.
    const buffer = try arena.alloc(u8, widest + 256);
    var columns: Columns = .{};
    if (needed(buffer, menu, query, defaults, choice, widest, columns, method, unicode) > width) columns.context = false;
    if (needed(buffer, menu, query, defaults, choice, widest, columns, method, unicode) > width) columns.all_sign_ins = false;
    if (needed(buffer, menu, query, defaults, choice, widest, columns, method, unicode) > width) columns.other_effort = false;
    widest = @min(widest, width -| needed(buffer, menu, query, defaults, choice, 0, columns, method, unicode));

    var count: usize = @intFromBool(readMessage(read, menu, unicode) != null) + @intFromBool(read == .read and menu.sources.get(picker.Provider.onlyWith(.sign_in)) == null);
    var selected: ?u32 = null;
    var previous_group: ?bool = null;
    for (menu.entries, 0..) |entry, index| {
        _ = query.row(entry, defaults) orelse continue;
        const highlighted = if (choice) |c| c.index == index else false;
        if (previous_group == null or previous_group.? != entry.known) {
            count += 1;
            previous_group = entry.known;
        }
        if (highlighted) selected = @intCast(count);
        count += 1;
    }
    if (sourceMessage(menu, read, unicode) != null) {
        if (previous_group == null or previous_group.?) count += 1;
        count += 1;
    }
    return .{ .menu = menu, .query = query, .defaults = defaults, .choice = choice, .widest = widest, .columns = columns, .method = method, .unicode = unicode, .read = read, .count = count, .selected = selected };
}

/// Materialize values for the value-core tests.
fn lines(arena: std.mem.Allocator, menu: *const picker.Menu, words: []const u8, defaults: picker.Defaults, choice: ?Choice, width: usize) !Lines {
    const plan = try rows(arena, menu, words, defaults, choice, width, .unicode, true, .read);
    const result = try arena.alloc(Line, plan.count);
    for (result, 0..) |*line, index| line.* = try plan.row(arena, index);
    return .{ .rows = result, .selected = plan.selected };
}

fn needed(buffer: []u8, menu: *const picker.Menu, query: picker.Query, defaults: picker.Defaults, choice: ?Choice, id_width: usize, columns: Columns, method: gwidth.Method, unicode: bool) usize {
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
        const window = if (entry.known) capability.contextWindow(model_catalog.shipped, entry.id) else product_defaults.unlisted_context_window;
        const start = gwidth.gwidth(out.buffered(), method);
        if (window >= 1_000_000) {
            const hundredths = (window + 5_000) / 10_000;
            out.print("  {d}.{d:0>2}M", .{ hundredths / 100, hundredths % 100 }) catch unreachable;
        } else out.print("  {d}K", .{window / 1_000}) catch unreachable;
        while (gwidth.gwidth(out.buffered(), method) - start < 7) out.writeByte(' ') catch unreachable;
    }
    if (columns.other_effort or (highlighted and row.effort != null)) {
        const start = gwidth.gwidth(out.buffered(), method);
        if (row.effort) |effort| {
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
    var offered = row.providers.iterator();
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
    return null;
}

/// Retain controls that the refreshed row still offers.
pub fn retain(choice: Choice, previous: Choice) Choice {
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
        if (click.index >= menu.entries.len) return null;
        const row = query.row(menu.entries[click.index], defaults) orelse return null;
        if (choice.* == null or choice.*.?.index != click.index) choice.* = .{ .index = click.index, .row = row };
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
        .save => return .{ .model = menu.entries[current.index].id, .effort = current.row.effort, .provider = current.row.provider },
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
    try std.testing.expect(select(&menu, "no-such-model", defaults, null) == null);
}

test "model picker view shows grouped rows and drops columns before the ID" {
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
    try std.testing.expectEqualStrings("Known to Rui", wide.rows[0].text);
    try std.testing.expectEqualStrings("   gpt-6.1-terra  1.05M  ‹ high ›   [ChatGPT]  API key", wide.rows[1].text);
    try std.testing.expectEqual(@as(?u32, 1), wide.selected);
    const no_context = try lines(arena.allocator(), &menu, "terra", defaults, selected, 47);
    try std.testing.expectEqualStrings("   gpt-6.1-terra  ‹ high ›   [ChatGPT]  API key", no_context.rows[1].text);
    const one_sign_in = try lines(arena.allocator(), &menu, "terra", defaults, selected, 38);
    try std.testing.expectEqualStrings("   gpt-6.1-terra  ‹ high ›   [ChatGPT]", one_sign_in.rows[1].text);
    const truncated = try lines(arena.allocator(), &menu, "terra", defaults, selected, 31);
    try std.testing.expectEqualStrings("   gpt-6…  ‹ high ›   [ChatGPT]", truncated.rows[1].text);
    const all = try lines(arena.allocator(), &menu, "custom", defaults, select(&menu, "custom", defaults, null), 100);
    try std.testing.expectEqualStrings("From your API key · default limits", all.rows[0].text);
    try std.testing.expect(all.rows[0].heading);
    try std.testing.expect(!all.rows[1].heading);
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
    for (shown.rows[1].segments) |segment| {
        if (std.mem.eql(u8, segment.text, "✓")) mark = segment.style.colour == .mark;
        if (std.mem.eql(u8, segment.text, "‹ high ›")) effort = segment.style.bold;
        if (std.mem.eql(u8, segment.text, "[ChatGPT]")) sign_in = segment.style.bold;
    }
    try std.testing.expect(mark and effort and sign_in);
}

test "model picker view reports list loading and failure without selectable status rows" {
    var menu = try picker.testMenu(&.{.{ .provider = .openai, .list = .pending }});
    defer menu.deinit(std.testing.allocator);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const pending = try lines(arena.allocator(), &menu, "no-match", .{}, null, 80);
    try std.testing.expectEqualStrings("From your API key · default limits", pending.rows[1].text);
    try std.testing.expectEqualStrings("API key: loading its models…", pending.rows[2].text);
    try std.testing.expect(pending.rows[2].model == null);
    menu.sources.set(.openai, .catalog_fallback);
    const failed = try lines(arena.allocator(), &menu, "no-match", .{}, null, 80);
    try std.testing.expectEqualStrings("API key: couldn't fetch its list; showing Rui's catalog", failed.rows[2].text);
}

test "model picker status and truncated rows use ASCII in an ASCII locale" {
    var menu = try picker.testMenu(&.{.{ .provider = .openai, .list = .pending }});
    defer menu.deinit(std.testing.allocator);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const loading = try rows(arena.allocator(), &menu, "no-match", .{}, null, 80, .unicode, false, .unread);
    try std.testing.expectEqualStrings("Loading models...", (try loading.row(arena.allocator(), 0)).text);
    const failed = try rows(arena.allocator(), &menu, "no-match", .{}, null, 80, .unicode, false, .unanswered);
    try std.testing.expectEqualStrings("The Host did not answer; this is the last list", (try failed.row(arena.allocator(), 0)).text);
    var id: [128]u8 = @splat('a');
    var providers: picker.Providers = .empty;
    providers.insert(.openai);
    const entries = [_]picker.Entry{.{ .id = &id, .known = false, .catalogued = false, .providers = providers }};
    const long: picker.Menu = .{ .entries = &entries };
    const choice = select(&long, "", .{}, null);
    const truncated = try rows(arena.allocator(), &long, "", .{}, choice, 30, .unicode, false, .read);
    try std.testing.expectEqualStrings("From your API key - default limits", (try truncated.row(arena.allocator(), truncated.selected.? - 1)).text);
    const row = try truncated.row(arena.allocator(), truncated.selected.?);
    try std.testing.expect(std.mem.indexOfScalar(u8, row.text, '.') != null);
    for (row.text) |byte| try std.testing.expect(byte < 128);
}

test "model picker view explains both missing sign-ins" {
    var menu = try picker.testMenu(&.{});
    defer menu.deinit(std.testing.allocator);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const shown = try lines(arena.allocator(), &menu, "", .{}, null, 80);
    var codex = false;
    var openai = false;
    for (shown.rows) |row| {
        codex = codex or std.mem.indexOf(u8, row.text, picker.Provider.codex.login()) != null;
        openai = openai or std.mem.indexOf(u8, row.text, picker.Provider.openai.login()) != null;
    }
    try std.testing.expect(codex and openai);
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
    try std.testing.expect(std.mem.indexOf(u8, selected.text, "API key") != null);
}

test "model picker view drops other efforts without losing the selected model" {
    var menu = try picker.testMenu(&.{.{ .provider = .openai, .list = .{ .live = .{ .bytes = "gpt-6.1-sol\nopenai/whisper-1\n" } } }});
    defer menu.deinit(std.testing.allocator);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const selected = select(&menu, "", .{}, menu.find("openai/whisper-1")).?;
    const narrow = try lines(arena.allocator(), &menu, "", .{}, selected, 30);
    var selected_visible = false;
    for (narrow.rows) |line| if (line.model) |index| {
        if (index == selected.index) {
            try std.testing.expect(std.mem.indexOf(u8, line.text, "openai/whisper-1") != null);
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
    var expected: [32]u8 = undefined;
    const limit = try std.fmt.bufPrint(&expected, "{d}K", .{product_defaults.unlisted_context_window / 1000});
    try std.testing.expect(std.mem.indexOf(u8, shown.rows[shown.selected.?].text, limit) != null);
}

test "model picker view moves only among matching models and keeps single choices unchanged" {
    var menu = try picker.testMenu(&.{.{ .provider = .openai, .list = .{ .live = .{ .bytes = "gpt-6.1-sol\nazure/gpt-5-pro\nopenai/whisper-1\n" } } }});
    defer menu.deinit(std.testing.allocator);
    var choice = select(&menu, "", .{}, menu.find("azure/gpt-5-pro"));
    const initial = choice.?.row;
    _ = step(&menu, "", .{}, &choice, .higher_effort);
    _ = step(&menu, "", .{}, &choice, .next_sign_in);
    try std.testing.expectEqual(initial.effort, choice.?.row.effort);
    try std.testing.expectEqual(initial.provider, choice.?.row.provider);
    _ = step(&menu, "", .{}, &choice, .next);
    try std.testing.expect(choice.?.index > menu.find("azure/gpt-5-pro").?);
    _ = step(&menu, "", .{}, &choice, .previous);
    try std.testing.expectEqual(menu.find("azure/gpt-5-pro").?, choice.?.index);
    choice = select(&menu, "whisper", .{}, choice.?.index);
    try std.testing.expectEqual(menu.find("openai/whisper-1").?, choice.?.index);
    try std.testing.expect(choice.?.row.effort == null);
    _ = step(&menu, "whisper", .{}, &choice, .lower_effort);
    try std.testing.expect(choice.?.row.effort == null);
}
