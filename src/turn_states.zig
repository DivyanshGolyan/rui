//! Per-Turn sticky routing for the Turns this Host runs, for any provider.
//! A codec names the response header that carries a Turn's routing value
//! (`codec_abi.ObservedHeaders.turn_state`). The first value in a Turn's
//! successful answer is sent back unchanged on every later request of that
//! Turn (retries, replacement Attempts, tool continuations and in-Turn
//! compaction), and no other Turn ever sends it. A provider that never sends
//! the header never stores or receives one, so nothing here asks which
//! provider it is.
//!
//! Process memory only: a fresh Host starts each Turn without it, and the
//! Store never holds it. Each value belongs to the owner that received it,
//! an opaque digest of the credential's identity (`providers.routingOwner`).
//! Another owner drops every value of that provider and retires outstanding
//! captures from the previous epoch. Each table is bounded by execution
//! capacity and replaces the least recently used Turn; a dropped value only
//! loses stickiness, since every request carries full input.
const std = @import("std");
const protocol = @import("protocol.zig");
const provider = @import("provider.zig");

/// One table per provider, so Turns of two served providers never retire
/// each other's values by alternating owners. Execution-thread-owned.
pub const PerProvider = struct {
    tables: std.EnumArray(protocol.Provider, TurnStates) = .initFill(.{}),

    /// Each table takes `per_table` of `entries`, which the caller maps
    /// zeroed and unmaps after `deinit`.
    pub fn init(entries: []TurnStates.Entry) PerProvider {
        const providers = std.enums.values(protocol.Provider).len;
        std.debug.assert(entries.len % providers == 0);
        const per_table = entries.len / providers;
        var self: PerProvider = .{};
        for (&self.tables.values, 0..) |*table, index| table.* = .{ .entries = entries[index * per_table ..][0..per_table] };
        return self;
    }

    pub fn get(self: *PerProvider, served: protocol.Provider) *TurnStates {
        return self.tables.getPtr(served);
    }

    /// Every transfer's header callback delivers its value straight here,
    /// keyed by its provider, Turn and the epoch its launch selected.
    pub fn sink(self: *PerProvider) provider.TurnStateSink {
        return .{ .context = self, .capture = observe };
    }

    fn observe(context: *anyopaque, key: provider.TurnStateKey, value: []const u8) void {
        const self: *PerProvider = @ptrCast(@alignCast(context));
        self.get(key.provider).capture(key.turn_id, key.epoch, value);
    }

    pub fn deinit(self: *PerProvider) void {
        for (&self.tables.values) |*table| table.deinit();
        self.* = undefined;
    }
};

/// One provider's table: at most one value per Turn, for one owner at a time.
pub const TurnStates = struct {
    entries: []Entry = &.{},
    owner: ?Owner = null,
    epoch: u64 = 0,
    uses: u64 = 0,

    pub const Owner = [32]u8;
    pub const Replay = struct {
        epoch: u64,
        /// Borrowed until the next mutation of this table.
        value: []const u8,
    };
    /// Zero bytes are an empty entry. A held value is malloc'd at its real
    /// length, so the table costs a few words per unit of capacity and a
    /// Turn's value costs its own bytes.
    pub const Entry = struct {
        held: ?Held = null,
        used: u64 = 0,
    };
    pub const Held = struct {
        turn_id: u64,
        value: []const u8,
    };

    /// Select the launch owner and return this Turn's value and capture
    /// epoch. An observed owner change invalidates every cached Turn.
    pub fn replay(self: *TurnStates, turn_id: u64, owner: Owner) Replay {
        if (self.owner == null or !std.mem.eql(u8, &self.owner.?, &owner)) {
            // Only occupied entries are reset, so an unused entry stays untouched.
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

    /// Record a transport-validated value from the selected launch epoch;
    /// the Turn's first one wins. A late completion cannot revive old state,
    /// including after the same owner has returned in a new epoch.
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
        // Without memory the value is dropped, which only loses stickiness.
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

    /// An emptied entry also forgets its recency, so capture fills it
    /// before evicting any held Turn.
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
    // The same owner's next launch, as after a credential refresh (a refresh
    // keeps the owner: see providers.zig), keeps the epoch and the first value.
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

    // Turn 8 is least recently used, so Turn 9 replaces it, not Turn 7.
    states.capture(9, launch.epoch, "nine");
    try std.testing.expectEqualStrings("", states.replay(8, account).value);
    try std.testing.expectEqualStrings("first", states.replay(7, account).value);
    try std.testing.expectEqualStrings("nine", states.replay(9, account).value);

    // After a binding change the emptied entries take new Turns before any
    // held Turn is evicted, whatever their recency before the change.
    const other: TurnStates.Owner = @splat(2);
    const rebound = states.replay(10, other);
    states.capture(10, rebound.epoch, "ten");
    states.capture(11, rebound.epoch, "eleven");
    try std.testing.expectEqualStrings("ten", states.replay(10, other).value);
    try std.testing.expectEqualStrings("eleven", states.replay(11, other).value);

    // Another owner never receives the value, and the original owner does
    // not regain it after the change.
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
            // A Turn untouched during A -> B must not resurrect A's hint
            // when A returns, including an A completion delivered under B.
            const returned = states.replay(1, account);
            try std.testing.expectEqualStrings("", returned.value);
            // A completion from the original A epoch is stale even after
            // another request has observed B -> A.
            states.capture(1, original.epoch, "late-original-a");
            states.capture(2, replacement.epoch, "late-b");
            try std.testing.expectEqualStrings("", states.replay(1, account).value);
            try std.testing.expectEqualStrings("", states.replay(2, account).value);
            states.capture(1, returned.epoch, "fresh-a");
            try std.testing.expectEqualStrings("fresh-a", states.replay(1, account).value);
        }
    }
}

test "two providers' Turns keep their values while their different owners launch in turn" {
    var storage: [2 * std.enums.values(protocol.Provider).len]TurnStates.Entry = @splat(.{});
    var states: PerProvider = .init(&storage);
    defer states.deinit();
    const chatgpt: TurnStates.Owner = @splat(1);
    const key: TurnStates.Owner = @splat(0);
    const sink = states.sink();
    const first = states.get(.codex).replay(1, chatgpt);
    sink.capture(sink.context, .{ .provider = .codex, .turn_id = 1, .epoch = first.epoch }, "sticky");
    // A key's launch is another owner, but of another provider's table.
    const keyed = states.get(.openai).replay(2, key);
    try std.testing.expectEqualStrings("", keyed.value);
    sink.capture(sink.context, .{ .provider = .openai, .turn_id = 2, .epoch = keyed.epoch }, "proxy-sticky");
    try std.testing.expectEqualStrings("sticky", states.get(.codex).replay(1, chatgpt).value);
    try std.testing.expectEqualStrings("proxy-sticky", states.get(.openai).replay(2, key).value);
    // Each table holds only its own Turns.
    try std.testing.expectEqualStrings("", states.get(.openai).replay(1, key).value);
}
