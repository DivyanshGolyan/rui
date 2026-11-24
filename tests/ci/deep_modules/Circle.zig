//! The report that module-cycle and tangle share (deep-modules U12 and U13, deslop's
//! `circle_report`, `shortest_circle` and `grouped`). A tie is the references by which one
//! member of a circle knows another. A circle is reported from its cheapest tie: a note per
//! tie, and a picture of the shortest circle through the cheapest one.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Diagnostic = @import("Diagnostic.zig");
const Components = @import("Components.zig");
const Items = @import("Items.zig");
const References = @import("References.zig");
const Sources = @import("Sources.zig");

const Location = Diagnostic.Location;
const ItemId = Items.ItemId;
const held_in_mind = Diagnostic.held_in_mind;

/// The references by which one member of a circle knows another.
pub const Tie = struct {
    /// The items the references name.
    items: std.AutoArrayHashMapUnmanaged(ItemId, void) = .empty,
    /// The items whose code holds them.
    holders: std.AutoArrayHashMapUnmanaged(ItemId, void) = .empty,
    /// The earliest site of any reference.
    first: ?Location = null,
    /// By each module the references are written in: its earliest site there.
    written: std.ArrayList(Written) = .empty,

    pub const Written = struct { module: Sources.NodeId, site: Location };

    /// Adds a reference to `item`, held by `holder`, written at `site` in `module`.
    pub fn add(self: *Tie, arena: Allocator, item: ItemId, holder: ItemId, at: Location, module: Sources.NodeId) Allocator.Error!void {
        try self.items.put(arena, item, {});
        try self.holders.put(arena, holder, {});
        if (self.first == null or earlier(at, self.first.?)) self.first = at;
        for (self.written.items) |*entry| {
            if (entry.module != module) continue;
            if (earlier(at, entry.site)) entry.site = at;
            return;
        }
        try self.written.append(arena, .{ .module = module, .site = at });
    }

    /// How many items the tie ties by: what cutting it takes.
    pub fn cost(self: *const Tie) usize {
        return self.items.count();
    }

    /// The earliest site of the tie. A tie has at least one reference.
    pub fn site(self: *const Tie) Location {
        return self.first.?;
    }
};

/// One tie of a circle, by the names of the two members it ties.
pub const Named = struct { user: []const u8, used: []const u8, tie: *const Tie };

/// A tie by the names of its two members, for `shortestCircle`.
pub const Report = struct {
    location: ?Location,
    notes: []const []const u8,
    picture: Diagnostic.Picture,
};

/// The report of a circle of `members` `noun`s, given its ties. The ties are sorted in
/// place: the cheapest first. `verb` is what a note says a member does with the next.
pub fn report(arena: Allocator, items: *const Items.Items, verb: []const u8, noun: []const u8, members: usize, ties: []Named) Allocator.Error!Report {
    std.debug.assert(ties.len > 0);
    std.mem.sort(Named, ties, {}, lessNamed);
    var notes: std.ArrayList([]const u8) = .empty;
    for (ties[0..@min(ties.len, held_in_mind)]) |named| try notes.append(arena, try note(arena, items, verb, named));
    if (ties.len > held_in_mind) {
        const more = try counted(arena, ties.len - held_in_mind, "more tie");
        try notes.append(arena, try std.fmt.allocPrint(arena, "and {s}", .{more}));
    }

    const edges = try arena.alloc(Components.Edge, ties.len);
    for (ties, edges) |named, *pair| pair.* = .{ .user = named.user, .used = named.used };
    const circle = try Components.shortestCircle(arena, edges);
    const steps = try arena.alloc(Diagnostic.Step, circle.len);
    for (circle, steps) |index, *slot| slot.* = try step(arena, items, ties[index].tie, ties[index].user);

    var left: std.ArrayList([]const u8) = .empty;
    if (members > circle.len) {
        const noun_more = try std.fmt.allocPrint(arena, "more {s}", .{noun});
        try left.append(arena, try counted(arena, members - circle.len, noun_more));
    }
    if (ties.len > circle.len) try left.append(arena, try counted(arena, ties.len - circle.len, "more tie"));
    const rest: ?[]const u8 = if (left.items.len == 0) null else try std.fmt.allocPrint(arena, "not drawn: {s}", .{try std.mem.join(arena, ", ", left.items)});

    return .{
        .location = ties[0].tie.site(),
        .notes = notes.items,
        .picture = .{ .circle = .{ .steps = steps, .rest = rest } },
    };
}

fn lessNamed(_: void, a: Named, b: Named) bool {
    if (a.tie.cost() != b.tie.cost()) return a.tie.cost() < b.tie.cost();
    const user = std.mem.order(u8, a.user, b.user);
    if (user != .eq) return user == .lt;
    return std.mem.order(u8, a.used, b.used) == .lt;
}

/// `src/kinds.zig:2:1: `kinds` uses `socket` by 1 item: LIMIT`, and the first site in each
/// other module the tie is written in.
fn note(arena: Allocator, items: *const Items.Items, verb: []const u8, named: Named) Allocator.Error![]const u8 {
    const tie = named.tie;
    const at = tie.site();
    var elsewhere: std.ArrayList([]const u8) = .empty;
    var sites: std.ArrayList(Location) = .empty;
    for (tie.written.items) |entry| {
        if (!sameSite(entry.site, at)) try sites.append(arena, entry.site);
    }
    std.mem.sort(Location, sites.items, {}, earlierSite);
    for (sites.items) |site| try elsewhere.append(arena, try clickable(arena, site));
    const also = if (elsewhere.items.len == 0)
        ""
    else
        try std.fmt.allocPrint(arena, "; also at {s}", .{try listed(arena, elsewhere.items)});
    const names = try listed(arena, try itemNames(arena, items, tie.items.keys()));
    return std.fmt.allocPrint(arena, "{s}: `{s}` {s} `{s}` by {s}: {s}{s}", .{
        try clickable(arena, at),
        named.user,
        verb,
        named.used,
        try counted(arena, tie.items.count(), "item"),
        names,
        also,
    });
}

/// The step of a circle from `member`, whose code the tie is in: what it uses of the next,
/// and the item whose code does, when that is one.
fn step(arena: Allocator, items: *const Items.Items, tie: *const Tie, member: []const u8) Allocator.Error!Diagnostic.Step {
    const shown = try grouped(arena, try itemNames(arena, items, tie.items.keys()));
    const holders = try itemNames(arena, items, tie.holders.keys());
    const uses = if (holders.len == 1)
        try std.fmt.allocPrint(arena, "{s} uses {s}", .{ holders[0], shown })
    else
        try std.fmt.allocPrint(arena, "uses {s}", .{shown});
    return .{ .member = member, .site = tie.site(), .uses = uses };
}

/// `Stream.{self, new, Kind.Ready}, LIMIT`: names under one head written once, as a `use`
/// declaration writes them.
pub fn grouped(arena: Allocator, names: []const []const u8) Allocator.Error![]const u8 {
    const Group = struct { head: []const u8, tails: std.ArrayList([]const u8) };
    var groups: std.ArrayList(Group) = .empty;
    for (names) |name| {
        const dot = std.mem.indexOfScalar(u8, name, '.');
        const head = if (dot) |at| name[0..at] else name;
        const tail = if (dot) |at| name[at + 1 ..] else "self";
        var found: ?usize = null;
        for (groups.items, 0..) |group, index| {
            if (std.mem.eql(u8, group.head, head)) found = index;
        }
        if (found == null) {
            try groups.append(arena, .{ .head = head, .tails = .empty });
            found = groups.items.len - 1;
        }
        try groups.items[found.?].tails.append(arena, tail);
    }
    const written = try arena.alloc([]const u8, groups.items.len);
    for (groups.items, written) |group, *slot| {
        const tails = group.tails.items;
        slot.* = if (tails.len == 1 and std.mem.eql(u8, tails[0], "self"))
            group.head
        else if (tails.len == 1)
            try std.fmt.allocPrint(arena, "{s}.{s}", .{ group.head, tails[0] })
        else
            try std.fmt.allocPrint(arena, "{s}.{{{s}}}", .{ group.head, try listed(arena, tails) });
    }
    return listed(arena, written);
}

/// `Holder.make`: an item's name, qualified by the types it is written in, without its file.
pub fn itemName(arena: Allocator, items: *const Items.Items, id: ItemId) Allocator.Error![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var current = id;
    while (items.get(current).parent) |parent| {
        try parts.append(arena, items.get(current).name);
        current = parent;
    }
    if (parts.items.len == 0) return items.get(id).name;
    std.mem.reverse([]const u8, parts.items);
    return std.mem.join(arena, ".", parts.items);
}

/// The names of `ids`, in the order of their ItemIds.
pub fn itemNames(arena: Allocator, items: *const Items.Items, ids: []const ItemId) Allocator.Error![]const []const u8 {
    const sorted = try arena.dupe(ItemId, ids);
    std.mem.sort(ItemId, sorted, {}, lessItem);
    const names = try arena.alloc([]const u8, sorted.len);
    for (sorted, names) |id, *slot| slot.* = try itemName(arena, items, id);
    return names;
}

/// A module's name in a report: its path under the root, or the root's own name.
pub fn moduleLabel(sources: *const Sources, node: Sources.NodeId) []const u8 {
    const path = sources.display(node);
    return if (path.len == 0) sources.nodes[@backingInt(node)].name else path;
}

/// The site of a reference, as an editor links it.
pub fn siteOf(sources: *const Sources, reference: References.Reference) Location {
    const file = &sources.files[@backingInt(reference.file)];
    const at = file.ast.tokenLocation(0, reference.token);
    return .{ .file = file.path, .line = @intCast(at.line + 1), .column = @intCast(at.column + 1) };
}

/// `a, b, c, +2 more`: at most seven of `names`, as `Diagnostic.listed` writes them.
pub fn listed(arena: Allocator, names: []const []const u8) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    Diagnostic.listed(&out.writer, names) catch return error.OutOfMemory;
    return out.written();
}

/// `1 module`, `2 modules`.
pub fn counted(arena: Allocator, count: usize, noun: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{d} {s}{s}", .{ count, noun, if (count == 1) "" else "s" });
}

/// `file:line:column`, the shape an editor links.
pub fn clickable(arena: Allocator, at: Location) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}:{d}:{d}", .{ at.file, at.line, at.column });
}

pub fn lessText(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn lessItem(_: void, a: ItemId, b: ItemId) bool {
    return @backingInt(a) < @backingInt(b);
}

fn earlierSite(_: void, a: Location, b: Location) bool {
    return earlier(a, b);
}

fn earlier(a: Location, b: Location) bool {
    if (!std.mem.eql(u8, a.file, b.file)) return std.mem.lessThan(u8, a.file, b.file);
    if (a.line != b.line) return a.line < b.line;
    return a.column < b.column;
}

fn sameSite(a: Location, b: Location) bool {
    return std.mem.eql(u8, a.file, b.file) and a.line == b.line and a.column == b.column;
}

const testing = std.testing;

test "grouped writes names under one head once, as a use declaration does" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("LIMIT", try grouped(a, &.{"LIMIT"}));
    try testing.expectEqualStrings("Stream.new", try grouped(a, &.{"Stream.new"}));
    try testing.expectEqualStrings(
        "Stream.{self, new, Kind.Ready}, LIMIT",
        try grouped(a, &.{ "Stream", "LIMIT", "Stream.new", "Stream.Kind.Ready" }),
    );
}
