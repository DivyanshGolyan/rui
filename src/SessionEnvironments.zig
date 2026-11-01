//! The Host's register of each Session's client environment: the
//! environment Bash starts from. It lives only in memory, never in the
//! Store, so intake installs an environment beside the Message's admission
//! and execution copies it at launch.
//!
//! An entry keeps the highest-ranked environment offered for its Session
//! (`environment.Rank`), so the result depends only on which Messages the
//! Store admitted, never on which intake worker ran first. Equal
//! environments share one interned value, freed when no entry names it.
//! The table holds at most `max_sessions` entries and `max_values` values of
//! at most `max_value_bytes` in total, and replaces the least recently used
//! Session; a replaced Session's Bash falls back to the system PATH, as after
//! a restart.
//!
//! One leaf mutex guards the table. The Store lock may be held while it is
//! taken, never the reverse. No allocation or free happens under it.
const SessionEnvironments = @This();

const std = @import("std");
const environment = @import("environment.zig");
const pages = @import("os/pages.zig");
const protocol = @import("protocol.zig");

pub const max_sessions = 4096;
pub const max_values = 128;
pub const max_value_bytes = 1024 * 1024;

const Session = [protocol.session_id_bytes]u8;

/// A Session's environment. All zero bytes are an unused entry, so entries
/// come from zero-mapped pages that become resident only as the table fills.
const Entry = struct {
    session: Session,
    value: u8,
    origin: environment.Rank.Origin,
    admission: u64,
    used: u64,

    fn rank(self: *const Entry) environment.Rank {
        return .{ .origin = self.origin, .admission = self.admission };
    }

    fn unused(self: *const Entry) bool {
        return self.session[0] == 0;
    }
};

/// One environment's bytes, which follow this header in one allocation.
const Interned = struct {
    refs: u32 = 0,
    len: u32,
    /// Links values an offer released, for the caller to free.
    next: ?*Interned = null,

    fn bytes(self: *Interned) []u8 {
        const base: [*]u8 = @ptrCast(self);
        return base[@sizeOf(Interned)..][0..self.len];
    }

    fn allocation(self: *Interned) []align(@alignOf(Interned)) u8 {
        const base: [*]align(@alignOf(Interned)) u8 = @ptrCast(self);
        return base[0 .. @sizeOf(Interned) + self.len];
    }
};

io: std.Io,
allocator: std.mem.Allocator,
mutex: std.Io.Mutex = .init,
/// `max_sessions` entries; those at and past `len` were never written.
entries: []Entry,
len: usize = 0,
values: [max_values]?*Interned = @splat(null),
value_count: usize = 0,
value_bytes: usize = 0,
uses: u64 = 0,

pub fn init(self: *SessionEnvironments, io: std.Io, allocator: std.mem.Allocator) !void {
    self.* = .{ .io = io, .allocator = allocator, .entries = try pages.mapZeroed(Entry, max_sessions) };
}

pub fn deinit(self: *SessionEnvironments) void {
    for (self.values) |value| if (value) |held| self.allocator.free(held.allocation());
    pages.unmapZeroed(self.entries);
    self.* = undefined;
}

/// An environment ready to offer: a candidate value allocated before the
/// mutex is taken, and the values the offer released, freed after it is
/// dropped. `finish` frees both.
pub const Offer = struct {
    candidate: ?*Interned,
    released: ?*Interned = null,
};

pub fn prepare(self: *SessionEnvironments, value: environment.Value) error{OutOfMemory}!Offer {
    std.debug.assert(value.len <= protocol.max_environment_bytes);
    const bytes = try self.allocator.alignedAlloc(u8, .of(Interned), @sizeOf(Interned) + value.len);
    const interned: *Interned = @ptrCast(bytes.ptr);
    interned.* = .{ .len = @intCast(value.len) };
    @memcpy(interned.bytes(), value);
    return .{ .candidate = interned };
}

/// Keeps `prepared`'s environment for `session` unless the Session holds a
/// higher-ranked one.
pub fn offer(self: *SessionEnvironments, session: []const u8, rank: environment.Rank, prepared: *Offer) void {
    std.debug.assert(protocol.validSessionId(session));
    const candidate = prepared.candidate.?;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const found = self.find(session);
    if (found) |index| if (!rank.outranks(self.entries[index].rank())) return;
    self.uses += 1;
    // Hold an equal value before anything is released, so it survives.
    var value = self.equalValue(candidate.bytes());
    if (value) |index| self.values[index].?.refs += 1;
    const place = if (found) |index| blk: {
        self.release(self.entries[index].value, prepared);
        break :blk index;
    } else self.freePlace(prepared);
    // Until it is written, `place` names no value and is never a victim.
    self.entries[place] = std.mem.zeroes(Entry);
    if (value == null) {
        while (self.value_count == max_values or self.value_bytes + candidate.len > max_value_bytes) {
            const victim = self.oldest().?;
            self.release(self.entries[victim].value, prepared);
            self.entries[victim] = std.mem.zeroes(Entry);
        }
        const index = std.mem.indexOfScalar(?*Interned, &self.values, null).?;
        candidate.refs = 1;
        self.values[index] = candidate;
        self.value_count += 1;
        self.value_bytes += candidate.len;
        prepared.candidate = null;
        value = index;
    }
    self.entries[place] = .{
        .session = session[0..protocol.session_id_bytes].*,
        .value = @intCast(value.?),
        .origin = rank.origin,
        .admission = rank.admission,
        .used = self.uses,
    };
}

/// Frees what the offer did not keep and what it released.
pub fn finish(self: *SessionEnvironments, prepared: *Offer) void {
    if (prepared.candidate) |candidate| self.allocator.free(candidate.allocation());
    var next = prepared.released;
    while (next) |value| {
        next = value.next;
        self.allocator.free(value.allocation());
    }
    prepared.* = .{ .candidate = null };
}

/// The Session's environment, owned by the caller through `allocator`, or
/// null when the table holds none for it.
pub fn copy(self: *SessionEnvironments, session: []const u8, allocator: std.mem.Allocator) error{OutOfMemory}!?[]u8 {
    var buffer: []u8 = &.{};
    while (true) {
        const length = blk: {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const index = self.find(session) orelse break :blk null;
            const bytes = self.values[self.entries[index].value].?.bytes();
            if (bytes.len != buffer.len) break :blk bytes.len;
            @memcpy(buffer, bytes);
            self.uses += 1;
            self.entries[index].used = self.uses;
            return buffer;
        };
        // Allocate outside the mutex, then look again: the value may change.
        allocator.free(buffer);
        buffer = &.{};
        buffer = try allocator.alloc(u8, length orelse return null);
    }
}

fn find(self: *const SessionEnvironments, session: []const u8) ?usize {
    for (self.entries[0..self.len], 0..) |*entry, index| {
        if (std.mem.eql(u8, &entry.session, session)) return index;
    }
    return null;
}

fn equalValue(self: *const SessionEnvironments, bytes: []const u8) ?usize {
    for (self.values, 0..) |value, index| if (value) |held| {
        if (std.mem.eql(u8, held.bytes(), bytes)) return index;
    };
    return null;
}

/// An unused entry, or the least recently used one, emptied.
fn freePlace(self: *SessionEnvironments, prepared: *Offer) usize {
    for (self.entries[0..self.len], 0..) |*entry, index| if (entry.unused()) return index;
    if (self.len < self.entries.len) {
        self.len += 1;
        return self.len - 1;
    }
    const victim = self.oldest().?;
    self.release(self.entries[victim].value, prepared);
    return victim;
}

fn oldest(self: *const SessionEnvironments) ?usize {
    var result: ?usize = null;
    for (self.entries[0..self.len], 0..) |*entry, index| {
        if (entry.unused()) continue;
        if (result == null or entry.used < self.entries[result.?].used) result = index;
    }
    return result;
}

/// Drops one entry's reference; a value no entry names joins `released`.
fn release(self: *SessionEnvironments, index: u8, prepared: *Offer) void {
    const value = self.values[index].?;
    value.refs -= 1;
    if (value.refs != 0) return;
    self.values[index] = null;
    self.value_count -= 1;
    self.value_bytes -= value.len;
    value.next = prepared.released;
    prepared.released = value;
}

fn testingSession(buffer: *Session, number: usize) []const u8 {
    for (buffer, 0..) |*byte, place| byte.* = protocol.session_alphabet[(number >> @intCast(5 * place)) & 31];
    return buffer;
}

fn testingOffer(table: *SessionEnvironments, session: []const u8, rank: environment.Rank, value: environment.Value) !void {
    var prepared = try table.prepare(value);
    defer table.finish(&prepared);
    table.offer(session, rank, &prepared);
}

fn expectCopy(table: *SessionEnvironments, session: []const u8, expected: ?[]const u8) !void {
    const copied = try table.copy(session, std.testing.allocator);
    defer if (copied) |bytes| std.testing.allocator.free(bytes);
    if (expected) |bytes| {
        try std.testing.expectEqualStrings(bytes, copied orelse return error.TestExpectedCopy);
    } else try std.testing.expectEqual(null, copied);
}

test "every order of offers keeps each Session's highest rank" {
    const Offered = struct { session: usize, rank: environment.Rank, value: []const u8 };
    const offers = [_]Offered{
        .{ .session = 0, .rank = .{ .origin = .peer, .admission = 9 }, .value = "WHO=peer-late\x00" },
        .{ .session = 0, .rank = .{ .origin = .person, .admission = 2 }, .value = "WHO=person-early\x00" },
        .{ .session = 0, .rank = .{ .origin = .person, .admission = 5 }, .value = "WHO=person-late\x00" },
        .{ .session = 1, .rank = .{ .origin = .peer, .admission = 3 }, .value = "WHO=person-late\x00" },
    };
    // The winners, read from the rule rather than from the table.
    const expected = [_][]const u8{ "WHO=person-late\x00", "WHO=person-late\x00" };
    var order = [_]usize{ 0, 1, 2, 3 };
    var permutations: usize = 0;
    while (true) {
        var table: SessionEnvironments = undefined;
        try table.init(std.testing.io, std.testing.allocator);
        defer table.deinit();
        var names: [2]Session = undefined;
        for (order) |index| {
            const item = offers[index];
            try testingOffer(&table, testingSession(&names[item.session], item.session), item.rank, item.value);
        }
        for (expected, 0..) |value, session| try expectCopy(&table, testingSession(&names[session], session), value);
        // Both Sessions name one interned value.
        try std.testing.expectEqual(@as(usize, 1), table.value_count);
        permutations += 1;
        // Next permutation in lexicographic order.
        var pivot: usize = order.len - 1;
        while (pivot > 0 and order[pivot - 1] >= order[pivot]) pivot -= 1;
        if (pivot == 0) break;
        var swap: usize = order.len - 1;
        while (order[swap] <= order[pivot - 1]) swap -= 1;
        std.mem.swap(usize, &order[pivot - 1], &order[swap]);
        std.mem.reverse(usize, order[pivot..]);
    }
    try std.testing.expectEqual(@as(usize, 24), permutations);
}

test "the table holds at most its Sessions and value bytes and replaces the least recently used" {
    var table: SessionEnvironments = undefined;
    try table.init(std.testing.io, std.testing.allocator);
    defer table.deinit();
    var name: Session = undefined;
    // One value shared by every Session: the entry bound applies.
    for (0..max_sessions + 1) |number| try testingOffer(&table, testingSession(&name, number), .{ .origin = .person, .admission = number + 1 }, "A=1\x00");
    try std.testing.expectEqual(@as(usize, max_sessions), table.len);
    try expectCopy(&table, testingSession(&name, 0), null);
    try expectCopy(&table, testingSession(&name, 1), "A=1\x00");
    try expectCopy(&table, testingSession(&name, max_sessions), "A=1\x00");
    // Session 1 was just used, so session 2 is replaced next.
    try testingOffer(&table, testingSession(&name, max_sessions + 1), .{ .origin = .person, .admission = 1 }, "A=1\x00");
    try expectCopy(&table, testingSession(&name, 1), "A=1\x00");
    try expectCopy(&table, testingSession(&name, 2), null);
    try std.testing.expectEqual(@as(usize, 1), table.value_count);

    // Distinct largest values: the byte bound applies.
    const large = try std.testing.allocator.alloc(u8, protocol.max_environment_bytes);
    defer std.testing.allocator.free(large);
    @memset(large, 'x');
    @memcpy(large[0..2], "V=");
    large[large.len - 1] = 0;
    const fit = max_value_bytes / large.len;
    const base = max_sessions + 2;
    for (0..fit + 1) |number| {
        large[2] = protocol.session_alphabet[number];
        try testingOffer(&table, testingSession(&name, base + number), .{ .origin = .person, .admission = 1 }, large);
        try std.testing.expect(table.value_bytes <= max_value_bytes);
    }
    try std.testing.expectEqual(fit, table.value_count);
    try expectCopy(&table, testingSession(&name, base), null);
    large[2] = protocol.session_alphabet[fit];
    try expectCopy(&table, testingSession(&name, base + fit), large);
}

test "the table holds at most its values" {
    var table: SessionEnvironments = undefined;
    try table.init(std.testing.io, std.testing.allocator);
    defer table.deinit();
    var name: Session = undefined;
    var value: [8]u8 = undefined;
    for (0..max_values + 1) |number| {
        try testingOffer(&table, testingSession(&name, number), .{ .origin = .person, .admission = 1 }, try std.fmt.bufPrint(&value, "N={d:0>4}\x00", .{number}));
    }
    try std.testing.expectEqual(@as(usize, max_values), table.value_count);
    try expectCopy(&table, testingSession(&name, 0), null);
    try expectCopy(&table, testingSession(&name, max_values), "N=0128\x00");
}

test "a value is freed exactly when no entry names it" {
    var table: SessionEnvironments = undefined;
    try table.init(std.testing.io, std.testing.allocator);
    defer table.deinit();
    var first: Session = undefined;
    var second: Session = undefined;
    _ = testingSession(&first, 1);
    _ = testingSession(&second, 2);
    try testingOffer(&table, &first, .{ .origin = .person, .admission = 1 }, "A=1\x00");
    try testingOffer(&table, &second, .{ .origin = .person, .admission = 2 }, "A=1\x00");
    try std.testing.expectEqual(@as(usize, 1), table.value_count);
    // The shared value stays while the second Session names it.
    try testingOffer(&table, &first, .{ .origin = .person, .admission = 3 }, "B=2\x00");
    try std.testing.expectEqual(@as(usize, 2), table.value_count);
    try expectCopy(&table, &second, "A=1\x00");
    // An equal value replacing itself keeps one copy.
    try testingOffer(&table, &first, .{ .origin = .person, .admission = 4 }, "B=2\x00");
    try std.testing.expectEqual(@as(usize, 2), table.value_count);
    try testingOffer(&table, &second, .{ .origin = .person, .admission = 5 }, "B=2\x00");
    try std.testing.expectEqual(@as(usize, 1), table.value_count);
    try std.testing.expectEqual(@as(usize, 4), table.value_bytes);
    // An outranked offer keeps nothing.
    try testingOffer(&table, &second, .{ .origin = .peer, .admission = 9 }, "C=3\x00");
    try std.testing.expectEqual(@as(usize, 1), table.value_count);
    try expectCopy(&table, &second, "B=2\x00");
    // An empty environment is a value too.
    var third: Session = undefined;
    try testingOffer(&table, testingSession(&third, 3), .{ .origin = .peer, .admission = 1 }, "");
    try expectCopy(&table, &third, "");
    try std.testing.expectEqual(@as(usize, 2), table.value_count);
}
