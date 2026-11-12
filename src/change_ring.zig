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

/// The Sessions one entry point changed, each with its Workspace's key. A
/// Message to a peer touches two.
pub const Touched = struct {
    pub const max = 4;

    entries: [max]Entry = undefined,
    /// At most `max`; a byte keeps the Store within its size bound.
    count: u8 = 0,
    /// Too many, an ID that is not a Session's, or a change that rolled
    /// back: every Session may have changed.
    everything: bool = false,

    /// Whether touching `id` needs a new entry: false when it has one, or
    /// when it touches everything (a fifth Session, or not a Session ID).
    pub fn needsEntry(self: *Touched, id: []const u8) bool {
        if (self.everything or self.contains(id)) return false;
        if (id.len != id_bytes or self.count == max) {
            self.everything = true;
            return false;
        }
        return true;
    }

    /// Adds the entry `needsEntry` asked for.
    pub fn add(self: *Touched, entry: Entry) void {
        std.debug.assert(self.count < max and !self.contains(&entry.session));
        self.entries[self.count] = entry;
        self.count += 1;
    }

    pub fn contains(self: *const Touched, id: []const u8) bool {
        for (self.entries[0..self.count]) |*entry| if (std.mem.eql(u8, &entry.session, id)) return true;
        return false;
    }
};

/// One changed Session. `workspace` is the key the Store gives its
/// Workspace, so a scoped reader skips other Workspaces without reading them.
pub const Entry = struct { session: Id, workspace: u64 };

pub const Ring = struct {
    // One column per field: an Entry array would pad each to 16 bytes.
    generations: [capacity]u64 = @splat(0),
    sessions: [capacity]Id = undefined,
    workspaces: [capacity]u64 = undefined,
    /// The slot the next entry takes.
    next: usize = 0,
    len: usize = 0,
    /// A change at or below this generation may have been overwritten.
    forgotten_through: u64 = 0,

    /// Records the Sessions one commit changed, under its generation.
    pub fn record(self: *Ring, generation: u64, touched: *const Touched) void {
        if (touched.everything) return self.forget(generation);
        for (touched.entries[0..touched.count]) |entry| self.push(generation, entry);
    }

    fn push(self: *Ring, generation: u64, entry: Entry) void {
        if (self.len == capacity) {
            self.forget(self.generations[self.next]);
        } else self.len += 1;
        self.generations[self.next] = generation;
        self.sessions[self.next] = entry.session;
        self.workspaces[self.next] = entry.workspace;
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

    /// Whether this Session may have changed in (since, through]. Walk only
    /// entries newer than `since`, newest first; uncovered history is unknown.
    pub fn mayHaveChanged(self: *const Ring, session: *const Id, since: u64, through: u64) bool {
        if (!self.covers(since)) return true;
        var index = self.next;
        for (0..self.len) |_| {
            index = (index + capacity - 1) % capacity;
            const generation = self.generations[index];
            if (generation <= since) break;
            if (generation <= through and std.mem.eql(u8, &self.sessions[index], session)) return true;
        }
        return false;
    }

    /// The first `out.len` distinct Sessions after `after`, in ID order,
    /// changed in (since, through] in `workspace`, or in any Workspace when
    /// null. Fewer means there are no more.
    pub fn changed(self: *const Ring, since: u64, through: u64, workspace: ?u64, after: ?*const Id, out: []Id) []Id {
        var count: usize = 0;
        for (self.generations[0..self.len], self.sessions[0..self.len], self.workspaces[0..self.len]) |generation, *id, entry_workspace| {
            if (generation <= since or generation > through) continue;
            if (workspace) |key| if (entry_workspace != key) continue;
            if (after) |previous| if (std.mem.order(u8, id, previous) != .gt) continue;
            // Insert into the sorted prefix, keeping the smallest IDs.
            if (count == out.len and std.mem.order(u8, id, &out[count - 1]) != .lt) continue;
            var index: usize = 0;
            while (index < count and std.mem.order(u8, &out[index], id) == .lt) index += 1;
            if (index < count and std.mem.eql(u8, &out[index], id)) continue;
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

/// Opaque per-Session observation hint: "<32 hex instance>.<generation>.<session>".
/// Like Token, it is neither stored nor meaningful across Host openings.
pub const SessionToken = struct {
    instance: [16]u8,
    generation: u64,
    session: Id,

    pub const max_bytes = Token.max_bytes + 1 + id_bytes;

    pub fn format(self: SessionToken, buffer: *[max_bytes]u8) []const u8 {
        const token: Token = .{ .instance = self.instance, .generation = self.generation };
        const prefix = token.format(buffer[0..Token.max_bytes]);
        buffer[prefix.len] = '.';
        buffer[prefix.len + 1 ..][0..id_bytes].* = self.session;
        return buffer[0 .. prefix.len + 1 + id_bytes];
    }

    pub fn parse(text: []const u8) error{InvalidSince}!SessionToken {
        if (text.len < 34 + 1 + id_bytes) return error.InvalidSince;
        const separator = text.len - id_bytes - 1;
        if (text[separator] != '.' or !@import("session_id.zig").valid(text[separator + 1 ..])) return error.InvalidSince;
        const token = try Token.parse(text[0..separator]);
        return .{ .instance = token.instance, .generation = token.generation, .session = text[separator + 1 ..][0..id_bytes].* };
    }

    /// Advances a scope whose unchanged state the caller has proved.
    pub fn at(self: SessionToken, generation: u64) SessionToken {
        return .{ .instance = self.instance, .generation = generation, .session = self.session };
    }
};

fn touchedOf(workspace: u64, ids: []const []const u8) Touched {
    var result: Touched = .{};
    for (ids) |id| if (result.needsEntry(id)) result.add(.{ .session = id[0..id_bytes].*, .workspace = workspace });
    return result;
}

fn recordAll(ring: *Ring, generation: u64, workspace: u64, ids: []const []const u8) void {
    ring.record(generation, &touchedOf(workspace, ids));
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
    // A smaller ID recorded after a page fills still displaces the largest.
    var late: Ring = .{};
    recordAll(&late, 1, 1, &.{ "zzzzzz", "yyyyyy", "a00000" });
    const smallest = late.changed(0, 1, null, null, &two);
    try std.testing.expectEqualStrings("a00000", &smallest[0]);
    try std.testing.expectEqualStrings("yyyyyy", &smallest[1]);
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
    for ([_][]const u8{ "000001", "000002", "000003", "000004", "000005" }) |id| if (many.needsEntry(id)) many.add(.{ .session = id[0..id_bytes].*, .workspace = 1 });
    try std.testing.expect(many.everything);
    try std.testing.expect(touchedOf(1, &.{"short"}).everything);
    // The same Session twice is one touch.
    try std.testing.expectEqual(@as(u8, 1), touchedOf(1, &.{ "k7m2qx", "k7m2qx" }).count);
    // Recording everything stops covering the generations before it.
    var ring: Ring = .{};
    recordAll(&ring, 1, 1, &.{"k7m2qx"});
    ring.record(5, &many);
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

test "a Session token reuses canonical instance and generation and validates its scope" {
    const token: SessionToken = .{ .instance = @splat(0xab), .generation = 42, .session = "k7m2qx".* };
    var buffer: [SessionToken.max_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("abababababababababababababababab.42.k7m2qx", token.format(&buffer));
    const parsed = try SessionToken.parse(token.format(&buffer));
    try std.testing.expectEqualSlices(u8, &token.instance, &parsed.instance);
    try std.testing.expectEqual(token.generation, parsed.generation);
    try std.testing.expectEqualSlices(u8, &token.session, &parsed.session);
    const advanced = token.at(std.math.maxInt(u64));
    try std.testing.expectEqual(SessionToken.max_bytes, advanced.format(&buffer).len);
    const parsed_advanced = try SessionToken.parse(advanced.format(&buffer));
    try std.testing.expectEqualSlices(u8, &advanced.instance, &parsed_advanced.instance);
    try std.testing.expectEqual(advanced.generation, parsed_advanced.generation);
    try std.testing.expectEqualSlices(u8, &advanced.session, &parsed_advanced.session);
    const zero = token.at(0);
    const parsed_zero = try SessionToken.parse("abababababababababababababababab.0.k7m2qx");
    try std.testing.expectEqualSlices(u8, &zero.instance, &parsed_zero.instance);
    try std.testing.expectEqual(zero.generation, parsed_zero.generation);
    try std.testing.expectEqualSlices(u8, &zero.session, &parsed_zero.session);
    for ([_][]const u8{
        "",                                            "abababababababababababababababab.42",        "abababababababababababababababab.42.k7m2q",
        "abababababababababababababababab.42.k7m2qxx", "abababababababababababababababab.42.K7m2qx", "abababababababababababababababab.42.k7m2qi",
        "abababababababababababababababab.42.k7m2ql",  "abababababababababababababababab.42.k7m2qo", "abababababababababababababababab.42.k7m2qu",
        "abababababababababababababababab.042.k7m2qx", "abababababababababababababababab.-1.k7m2qx", "abababababababababababababababab.18446744073709551616.k7m2qx",
        "ABABABABABABABABABABABABABABABAB.42.k7m2qx",  "abababababababababababababababab..k7m2qx",   "abababababababababababababababab.42.k7m2qx ",
    }) |invalid| try std.testing.expectError(error.InvalidSince, SessionToken.parse(invalid));
}

test "Session change hints distinguish sibling changes and covered interval boundaries" {
    var ring: Ring = .{};
    const session: Id = "k7m2qx".*;
    try std.testing.expect(!ring.mayHaveChanged(&session, 0, 0));
    recordAll(&ring, 1, 1, &.{&session});
    recordAll(&ring, 2, 2, &.{"a00000"});
    recordAll(&ring, 3, 1, &.{ "a00000", &session });
    try std.testing.expect(ring.mayHaveChanged(&session, 0, 1));
    try std.testing.expect(!ring.mayHaveChanged(&session, 1, 2));
    try std.testing.expect(ring.mayHaveChanged(&session, 2, 3));
    try std.testing.expect(!ring.mayHaveChanged(&session, 3, 3));
    ring.forget(4);
    try std.testing.expect(ring.mayHaveChanged(&session, 3, 4));
    try std.testing.expect(!ring.mayHaveChanged(&session, 4, 4));
}

test "Session change hints walk wrapped entries and conservatively report uncovered history" {
    var ring: Ring = .{};
    const session: Id = "k7m2qx".*;
    recordAll(&ring, 1, 1, &.{&session});
    for (2..capacity + 2) |generation| recordAll(&ring, generation, 2, &.{"a00000"});
    try std.testing.expect(ring.mayHaveChanged(&session, 0, capacity + 1));
    try std.testing.expect(!ring.mayHaveChanged(&session, 1, capacity + 1));
    recordAll(&ring, capacity + 2, 1, &.{&session});
    try std.testing.expect(ring.mayHaveChanged(&session, capacity, capacity + 2));
    try std.testing.expect(!ring.mayHaveChanged(&session, capacity, capacity + 1));
    try std.testing.expect(!ring.mayHaveChanged(&session, capacity + 2, capacity + 2));
}
