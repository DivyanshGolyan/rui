//! Which Sessions may have changed since a commit generation: the fixed,
//! in-memory hint behind Session listing's `since`.
//!
//! Every entry point that changes rows records the Sessions it touched under
//! the generation its commit advanced to, each with its Workspace's key. A
//! reader asks for the Sessions changed in (since, through], in one Workspace
//! or any, in one pass over memory. The ring may name a Session that did not
//! change, but while it covers `since` it never omits one that did; once an
//! entry it needs is overwritten, `covers` says so and the reader traverses
//! everything instead. Nothing here is stored or survives the Host.
const std = @import("std");

/// Entries kept: the most recent (Session, generation) pairs.
pub const capacity = 4096;
pub const id_bytes = 6;
pub const Id = [id_bytes]u8;

/// The Sessions one entry point changed. A Message to a peer touches two.
pub const Touched = struct {
    pub const max = 4;

    ids: [max]Id = undefined,
    count: usize = 0,
    /// Too many, or an ID that is not a Session's: every Session may have
    /// changed.
    everything: bool = false,

    pub fn add(self: *Touched, id: []const u8) void {
        if (id.len != id_bytes) {
            self.everything = true;
            return;
        }
        if (self.contains(id)) return;
        if (self.count == max) {
            self.everything = true;
            return;
        }
        @memcpy(&self.ids[self.count], id);
        self.count += 1;
    }

    pub fn contains(self: *const Touched, id: []const u8) bool {
        for (self.ids[0..self.count]) |*touched| if (std.mem.eql(u8, touched, id)) return true;
        return false;
    }
};

/// One changed Session. `workspace` is the key the Store gives its
/// Workspace, so a scoped reader skips other Workspaces without reading them.
pub const Entry = struct { session: Id, workspace: u64 };

pub const Ring = struct {
    generations: [capacity]u64 = @splat(0),
    entries: [capacity]Entry = undefined,
    /// The slot the next entry takes.
    next: usize = 0,
    len: usize = 0,
    /// A change at or below this generation may have been overwritten.
    forgotten_through: u64 = 0,

    /// Records that one Session changed at `generation`.
    pub fn record(self: *Ring, generation: u64, entry: Entry) void {
        if (self.len == capacity) {
            self.forget(self.generations[self.next]);
        } else self.len += 1;
        self.generations[self.next] = generation;
        self.entries[self.next] = entry;
        self.next = (self.next + 1) % capacity;
    }

    /// Records that any Session may have changed at `generation`.
    pub fn forget(self: *Ring, generation: u64) void {
        self.forgotten_through = @max(self.forgotten_through, generation);
    }

    /// Whether every change after `since` is still recorded.
    pub fn covers(self: *const Ring, since: u64) bool {
        return since >= self.forgotten_through;
    }

    /// The first `out.len` distinct Sessions after `after`, in ID order,
    /// changed in (since, through] in `workspace`, or in any Workspace when
    /// null. Fewer means there are no more.
    pub fn changed(self: *const Ring, since: u64, through: u64, workspace: ?u64, after: ?*const Id, out: []Id) []Id {
        var count: usize = 0;
        for (self.generations[0..self.len], self.entries[0..self.len]) |generation, *entry| {
            if (generation <= since or generation > through) continue;
            if (workspace) |key| if (entry.workspace != key) continue;
            const id = &entry.session;
            if (after) |previous| if (std.mem.order(u8, id, previous) != .gt) continue;
            // Insert into the sorted prefix, keeping the smallest IDs.
            var index: usize = 0;
            while (index < count and std.mem.order(u8, &out[index], id) == .lt) index += 1;
            if (index < count and std.mem.eql(u8, &out[index], id)) continue;
            if (index == out.len) continue;
            const kept = @min(count, out.len - 1);
            var move = kept;
            while (move > index) : (move -= 1) out[move] = out[move - 1];
            out[index] = id.*;
            count = kept + 1;
        }
        return out[0..count];
    }
};

/// Opaque on the wire: "<32 hex instance>.<generation>". Not ordered across
/// instances, never stored, and not a revision any read can be asked for.
pub const Token = struct {
    instance: [16]u8,
    generation: u64,

    pub const max_bytes = 32 + 1 + 20;

    pub fn format(self: Token, buffer: *[max_bytes]u8) []const u8 {
        const hex = std.fmt.bytesToHex(self.instance, .lower);
        return std.fmt.bufPrint(buffer, "{s}.{d}", .{ &hex, self.generation }) catch unreachable;
    }

    pub fn parse(text: []const u8) error{InvalidSince}!Token {
        if (text.len < 34 or text[32] != '.') return error.InvalidSince;
        var token: Token = .{ .instance = undefined, .generation = 0 };
        for (text[0..32]) |byte| switch (byte) {
            '0'...'9', 'a'...'f' => {},
            else => return error.InvalidSince,
        };
        _ = std.fmt.hexToBytes(&token.instance, text[0..32]) catch return error.InvalidSince;
        const decimal = text[33..];
        if (decimal.len > 1 and decimal[0] == '0') return error.InvalidSince;
        for (decimal) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidSince;
        token.generation = std.fmt.parseInt(u64, decimal, 10) catch return error.InvalidSince;
        return token;
    }
};

fn touchedOf(ids: []const []const u8) Touched {
    var result: Touched = .{};
    for (ids) |id| result.add(id);
    return result;
}

fn recordAll(ring: *Ring, generation: u64, workspace: u64, ids: []const *const Id) void {
    for (ids) |id| ring.record(generation, .{ .session = id.*, .workspace = workspace });
}

test "a ring names each Session changed since a generation once, in ID order" {
    var ring: Ring = .{};
    recordAll(&ring, 1, 1, &.{"k7m2qx"});
    recordAll(&ring, 2, 2, &.{"a00000"});
    recordAll(&ring, 2, 1, &.{"k7m2qx"});
    recordAll(&ring, 3, 1, &.{"zzzzzz"});
    var out: [8]Id = undefined;
    const all = ring.changed(0, 3, null, null, &out);
    try std.testing.expectEqual(@as(usize, 3), all.len);
    try std.testing.expectEqualStrings("a00000", &all[0]);
    try std.testing.expectEqualStrings("k7m2qx", &all[1]);
    try std.testing.expectEqualStrings("zzzzzz", &all[2]);
    // Only changes in (since, through] count.
    const middle = ring.changed(1, 2, null, null, &out);
    try std.testing.expectEqual(@as(usize, 2), middle.len);
    try std.testing.expectEqualStrings("a00000", &middle[0]);
    try std.testing.expectEqual(@as(usize, 0), ring.changed(3, 3, null, null, &out).len);
    // Only the asked Workspace's changes count.
    const scoped = ring.changed(0, 3, 1, null, &out);
    try std.testing.expectEqual(@as(usize, 2), scoped.len);
    try std.testing.expectEqualStrings("k7m2qx", &scoped[0]);
    try std.testing.expectEqualStrings("a00000", &ring.changed(0, 3, 2, null, &out)[0]);
    try std.testing.expectEqual(@as(usize, 0), ring.changed(0, 3, 3, null, &out).len);
    // A continuation resumes after the last ID and pages by `out.len`.
    var two: [2]Id = undefined;
    const first = ring.changed(0, 3, null, null, &two);
    try std.testing.expectEqualStrings("k7m2qx", &first[1]);
    const rest = ring.changed(0, 3, null, &first[1], &two);
    try std.testing.expectEqual(@as(usize, 1), rest.len);
    try std.testing.expectEqualStrings("zzzzzz", &rest[0]);
}

test "an overwritten change stops the ring covering earlier generations" {
    var ring: Ring = .{};
    var id: Id = "000000".*;
    for (0..capacity) |index| {
        id[5] = "0123456789"[index % 10];
        recordAll(&ring, index + 1, 1, &.{&id});
    }
    try std.testing.expect(ring.covers(0));
    recordAll(&ring, capacity + 1, 1, &.{"k7m2qx"});
    try std.testing.expect(!ring.covers(0));
    try std.testing.expect(ring.covers(1));
    var out: [16]Id = undefined;
    // Everything after a covered generation is still named.
    const named = ring.changed(capacity - 1, capacity + 1, null, null, &out);
    try std.testing.expectEqual(@as(usize, 2), named.len);
}

test "touching too many Sessions, or a non-Session, touches everything" {
    var many: Touched = .{};
    for ([_][]const u8{ "000001", "000002", "000003", "000004", "000005" }) |id| many.add(id);
    try std.testing.expect(many.everything);
    try std.testing.expect(touchedOf(&.{"short"}).everything);
    // The same Session twice is one touch.
    try std.testing.expectEqual(@as(usize, 1), touchedOf(&.{ "k7m2qx", "k7m2qx" }).count);
    // Forgetting a generation stops covering the ones before it.
    var ring: Ring = .{};
    recordAll(&ring, 1, 1, &.{"k7m2qx"});
    ring.forget(5);
    try std.testing.expect(!ring.covers(4) and ring.covers(5));
}

test "a token is a lowercase instance and a canonical generation" {
    const token: Token = .{ .instance = @splat(0xab), .generation = 42 };
    var buffer: [Token.max_bytes]u8 = undefined;
    const text = token.format(&buffer);
    try std.testing.expectEqualStrings("abababababababababababababababab.42", text);
    const parsed = try Token.parse(text);
    try std.testing.expectEqualSlices(u8, &token.instance, &parsed.instance);
    try std.testing.expectEqual(@as(u64, 42), parsed.generation);
    try std.testing.expectEqual(@as(u64, 0), (try Token.parse("abababababababababababababababab.0")).generation);
    const longest: Token = .{ .instance = @splat(0xff), .generation = std.math.maxInt(u64) };
    try std.testing.expectEqual(Token.max_bytes, longest.format(&buffer).len);
    for ([_][]const u8{
        "",
        "abababababababababababababababab",
        "abababababababababababababababab.",
        "ABABABABABABABABABABABABABABABAB.1",
        "abababababababababababababababab.01",
        "abababababababababababababababab.-1",
        "abababababababababababababababab.18446744073709551616",
        "ababababababababababababababababa.1",
        "abababababababababababababababab.1 ",
    }) |invalid| try std.testing.expectError(error.InvalidSince, Token.parse(invalid));
}
