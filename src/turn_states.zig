const std = @import("std");
const connection = @import("connection.zig");
const connection_names = @import("connection_names.zig");
const provider = @import("provider.zig");

/// One TurnStates table per served connection name, keyed by name through the
/// served set's table. Each name's table takes an equal share of the entries.
pub const PerConnection = struct {
    tables: connection_names.NameArray(TurnStates) = .{},

    /// Initializes in place: the value is over 1 KiB and has one address on a Host thread.
    pub fn init(self: *PerConnection, names: []const connection.Name, entries: []TurnStates.Entry) void {
        std.debug.assert(names.len <= connection.max_served);
        std.debug.assert(if (names.len == 0) entries.len == 0 else entries.len % names.len == 0);
        const per_table = if (names.len == 0) 0 else entries.len / names.len;
        self.tables = .{};
        for (names, 0..) |name, index| {
            self.tables.set(name, .{ .entries = entries[index * per_table ..][0..per_table] }) catch unreachable;
        }
    }

    /// The table of a served name; a name the served set does not hold has none.
    pub fn get(self: *PerConnection, name: connection.Name) *TurnStates {
        return self.tables.findMut(name).?;
    }

    pub fn sink(self: *PerConnection) provider.TurnStateSink {
        return .{ .context = self, .capture = observe, .replay = replayFor };
    }

    fn observe(context: *anyopaque, key: provider.TurnStateKey, value: []const u8) void {
        const self: *PerConnection = @ptrCast(@alignCast(context));
        self.get(key.provider).capture(key.turn_id, key.epoch, value);
    }

    fn replayFor(context: *anyopaque, served: connection.Name, turn_id: u64, owner: TurnStates.Owner) provider.TurnStateSink.Replay {
        const self: *PerConnection = @ptrCast(@alignCast(context));
        const replayed = self.get(served).replay(turn_id, owner);
        return .{ .epoch = replayed.epoch, .value = replayed.value };
    }

    pub fn deinit(self: *PerConnection) void {
        for (self.tables.values[0..self.tables.len]) |*table| table.deinit();
        self.* = undefined;
    }
};

pub const TurnStates = struct {
    entries: []Entry = &.{},
    owner: ?Owner = null,
    epoch: u64 = 0,
    uses: u64 = 0,

    pub const Owner = provider.RoutingOwner;
    pub const Replay = struct {
        epoch: u64,
        value: []const u8,
    };
    pub const Entry = struct {
        held: ?Held = null,
        used: u64 = 0,
    };
    pub const Held = struct {
        turn_id: u64,
        value: []const u8,
    };

    pub fn replay(self: *TurnStates, turn_id: u64, owner: Owner) Replay {
        if (self.owner == null or !std.mem.eql(u8, &self.owner.?, &owner)) {
            for (self.entries) |*entry| if (entry.held != null) release(entry);
            self.owner = owner;
            self.epoch += 1;
            self.uses = 0;
        }
        const entry = self.find(turn_id) orelse return .{ .epoch = self.epoch, .value = "" };
        self.uses += 1;
        entry.used = self.uses;
        return .{ .epoch = self.epoch, .value = entry.held.?.value };
    }

    pub fn capture(self: *TurnStates, turn_id: u64, epoch: u64, value: []const u8) void {
        if (epoch != self.epoch or self.owner == null or value.len == 0 or self.entries.len == 0) return;
        const target = self.find(turn_id) orelse lru: {
            var oldest = &self.entries[0];
            for (self.entries) |*entry| if (entry.used < oldest.used) {
                oldest = entry;
            };
            break :lru oldest;
        };
        if (target.held != null and target.held.?.turn_id == turn_id) return;
        std.debug.assert(value.len <= provider.max_turn_state_bytes);
        const owned = std.heap.c_allocator.dupe(u8, value) catch return;
        if (target.held != null) release(target);
        self.uses += 1;
        target.held = .{ .turn_id = turn_id, .value = owned };
        target.used = self.uses;
    }

    pub fn deinit(self: *TurnStates) void {
        for (self.entries) |*entry| if (entry.held != null) release(entry);
        self.* = undefined;
    }

    fn release(entry: *Entry) void {
        std.heap.c_allocator.free(entry.held.?.value);
        entry.* = .{};
    }

    fn find(self: *TurnStates, turn_id: u64) ?*Entry {
        for (self.entries) |*entry| if (entry.held != null and entry.held.?.turn_id == turn_id) return entry;
        return null;
    }
};

test "a routing value replays one Turn's first value and never another Turn's" {
    var storage: [2]TurnStates.Entry = @splat(.{});
    var states: TurnStates = .{ .entries = &storage };
    defer states.deinit();
    const account: TurnStates.Owner = @splat(1);
    const refreshed = account;
    const launch = states.replay(7, account);
    try std.testing.expectEqualStrings("", launch.value);
    states.capture(7, launch.epoch, "");
    try std.testing.expectEqualStrings("", states.replay(7, account).value);
    states.capture(7, launch.epoch, "first");
    const refresh = states.replay(7, refreshed);
    try std.testing.expectEqual(launch.epoch, refresh.epoch);
    states.capture(7, refresh.epoch, "second");
    try std.testing.expectEqualStrings("first", states.replay(7, refreshed).value);
    try std.testing.expectEqualStrings("first", states.replay(7, account).value);
    try std.testing.expectEqualStrings("", states.replay(8, account).value);
    states.capture(8, launch.epoch, "eight");
    try std.testing.expectEqualStrings("eight", states.replay(8, account).value);
    try std.testing.expectEqualStrings("first", states.replay(7, account).value);

    states.capture(9, launch.epoch, "nine");
    try std.testing.expectEqualStrings("", states.replay(8, account).value);
    try std.testing.expectEqualStrings("first", states.replay(7, account).value);
    try std.testing.expectEqualStrings("nine", states.replay(9, account).value);

    const other: TurnStates.Owner = @splat(2);
    const rebound = states.replay(10, other);
    states.capture(10, rebound.epoch, "ten");
    states.capture(11, rebound.epoch, "eleven");
    try std.testing.expectEqualStrings("ten", states.replay(10, other).value);
    try std.testing.expectEqualStrings("eleven", states.replay(11, other).value);

    for ([_]TurnStates.Owner{ @splat(2), @splat(3) }) |changed| {
        var owned: [1]TurnStates.Entry = @splat(.{});
        var isolated: TurnStates = .{ .entries = &owned };
        defer isolated.deinit();
        const original = isolated.replay(5, account);
        isolated.capture(5, original.epoch, "acct-value");
        try std.testing.expect(!std.mem.eql(u8, &account, &changed));
        try std.testing.expectEqualStrings("", isolated.replay(5, changed).value);
        try std.testing.expectEqualStrings("", isolated.replay(5, account).value);
        const replacement = isolated.replay(5, changed);
        isolated.capture(5, replacement.epoch, "changed-value");
        try std.testing.expectEqualStrings("changed-value", isolated.replay(5, changed).value);
        try std.testing.expectEqualStrings("", isolated.replay(5, account).value);
    }

    var unused: TurnStates = .{};
    defer unused.deinit();
    const ignored = unused.replay(1, account);
    unused.capture(1, ignored.epoch, "value");
    try std.testing.expectEqualStrings("", unused.replay(1, account).value);
}

test "owner changes invalidate paused Turns and stale completions" {
    const account: TurnStates.Owner = @splat(1);
    for ([_]TurnStates.Owner{ @splat(2), @splat(3) }) |changed| {
        for ([_]bool{ false, true }) |late_completion| {
            var storage: [2]TurnStates.Entry = @splat(.{});
            var states: TurnStates = .{ .entries = &storage };
            defer states.deinit();
            const original = states.replay(1, account);
            try std.testing.expectEqualStrings("", original.value);
            if (!late_completion) states.capture(1, original.epoch, "paused-a");
            try std.testing.expectEqualStrings("", states.replay(2, account).value);
            states.capture(2, original.epoch, "active-a");
            const replacement = states.replay(2, changed);
            try std.testing.expectEqualStrings("", replacement.value);
            states.capture(2, replacement.epoch, "active-b");
            if (late_completion) states.capture(1, original.epoch, "late-a");
            const returned = states.replay(1, account);
            try std.testing.expectEqualStrings("", returned.value);
            states.capture(1, original.epoch, "late-original-a");
            states.capture(2, replacement.epoch, "late-b");
            try std.testing.expectEqualStrings("", states.replay(1, account).value);
            try std.testing.expectEqualStrings("", states.replay(2, account).value);
            states.capture(1, returned.epoch, "fresh-a");
            try std.testing.expectEqualStrings("fresh-a", states.replay(1, account).value);
        }
    }
}

test "two connections' Turns keep their values while their different owners launch in turn" {
    const names = [_]connection.Name{ connection.Name.parse("codex").?, connection.Name.parse("openai").?, connection.Name.parse("alpha").? };
    var storage: [2 * names.len]TurnStates.Entry = @splat(.{});
    var states: PerConnection = undefined;
    states.init(&names, &storage);
    defer states.deinit();
    const chatgpt: TurnStates.Owner = @splat(1);
    const key: TurnStates.Owner = @splat(0);
    const sink = states.sink();
    const codex = names[0];
    const openai = names[1];
    const first = states.get(codex).replay(1, chatgpt);
    sink.capture(sink.context, .{ .provider = codex, .turn_id = 1, .epoch = first.epoch }, "sticky");
    const keyed = states.get(openai).replay(2, key);
    try std.testing.expectEqualStrings("", keyed.value);
    sink.capture(sink.context, .{ .provider = openai, .turn_id = 2, .epoch = keyed.epoch }, "proxy-sticky");
    try std.testing.expectEqualStrings("sticky", states.get(codex).replay(1, chatgpt).value);
    try std.testing.expectEqualStrings("proxy-sticky", states.get(openai).replay(2, key).value);
    try std.testing.expectEqualStrings("", states.get(openai).replay(1, key).value);
    // A custom name has its own table: the built-in codex Turn's value is not replayed to it.
    try std.testing.expectEqualStrings("", states.get(names[2]).replay(1, chatgpt).value);
}
