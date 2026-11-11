//! The frontend's fold lifecycle. Requested identities are not open rows.
//! Only shown identities survive a text-window rebuild; terminal outcomes
//! release their identity immediately. The one in-flight receipt carries no
//! output and cannot authorize a later request for the same Reference.
const std = @import("std");
const fold = @import("tool_fold.zig");
const reading = @import("session_reading.zig");

pub const State = enum { requested, shown, failed, cancelled, closed };
pub const Request = struct {
    target: fold.Reference,
    ticket: u64,
    asked: reading.Asked,
};

pub fn Sized(comptime maximum: usize) type {
    return struct {
        const Owner = @This();
        const Entry = struct { reference: fold.Reference, ticket: u64, state: State };
        entries: std.ArrayList(Entry) = .empty,
        serial: u64 = 0,
        in_flight: ?Request = null,

        pub fn deinit(self: *Owner, gpa: std.mem.Allocator) void {
            self.entries.deinit(gpa);
            self.* = .{};
        }

        fn index(self: *const Owner, reference: fold.Reference) ?usize {
            for (self.entries.items, 0..) |entry, at| if (std.meta.eql(entry.reference, reference)) return at;
            return null;
        }

        pub fn contains(self: *const Owner, reference: fold.Reference) bool {
            return self.index(reference) != null;
        }

        pub fn state(self: *const Owner, reference: fold.Reference) State {
            return if (self.index(reference)) |at| self.entries.items[at].state else .closed;
        }

        pub fn pending(self: *const Owner) bool {
            for (self.entries.items) |entry| if (entry.state == .requested) return true;
            return false;
        }

        fn ticket(self: *Owner) u64 {
            self.serial += 1;
            return self.serial;
        }

        pub fn request(self: *Owner, gpa: std.mem.Allocator, reference: fold.Reference) !void {
            if (self.contains(reference)) return;
            if (self.entries.items.len == maximum) return error.ToolFoldViewFull;
            if (self.entries.items.len == self.entries.capacity)
                try self.entries.ensureTotalCapacityPrecise(gpa, @min(maximum, @max(4, 2 * self.entries.capacity)));
            self.entries.appendAssumeCapacity(.{ .reference = reference, .ticket = self.ticket(), .state = .requested });
        }

        fn terminal(self: *Owner, gpa: std.mem.Allocator, at: usize, outcome: State) void {
            std.debug.assert(outcome == .failed or outcome == .cancelled or outcome == .closed);
            self.entries.items[at].state = outcome;
            _ = self.entries.swapRemove(at);
            if (self.entries.items.len == 0) {
                self.entries.deinit(gpa);
                self.entries = .empty;
                // Do not reset serial or the outstanding receipt: an old
                // completion must not match a close-and-reopen of this row.
            }
        }

        pub fn close(self: *Owner, gpa: std.mem.Allocator, reference: fold.Reference) void {
            if (self.index(reference)) |at| self.terminal(gpa, at, .closed);
        }

        /// Esc, a send or a newer expansion supersedes only requests, never
        /// a row the person already opened. The actual reader still joins.
        pub fn cancelNext(self: *Owner, gpa: std.mem.Allocator) ?fold.Reference {
            for (self.entries.items, 0..) |entry, at| if (entry.state == .requested) {
                self.terminal(gpa, at, .cancelled);
                return entry.reference;
            };
            return null;
        }

        /// Borrowed identity facts from the rebuilt document, not old byte
        /// positions. The existing authenticated read restores each shown row.
        pub fn rebuild(self: *Owner, document: anytype) void {
            for (self.entries.items) |*entry| {
                if (entry.state != .shown) continue;
                const row = document.findTool(entry.reference) orelse continue;
                if (document.toolIsOpen(row)) continue;
                entry.state = .requested;
                entry.ticket = self.ticket();
            }
        }

        pub fn start(self: *Owner, asked: reading.Asked) ?Request {
            if (self.in_flight != null) return null;
            for (self.entries.items) |entry| if (entry.state == .requested) {
                const request_: Request = .{ .target = entry.reference, .ticket = entry.ticket, .asked = asked };
                self.in_flight = request_;
                return request_;
            };
            return null;
        }

        pub fn accepts(self: *const Owner, request_: Request) bool {
            const at = self.index(request_.target) orelse return false;
            const entry = self.entries.items[at];
            return entry.state == .requested and entry.ticket == request_.ticket;
        }

        /// Every joined read, including stale and refused insertions, ends
        /// here. A request becomes shown only after the visible edit succeeds.
        pub fn finish(self: *Owner, gpa: std.mem.Allocator, request_: Request, outcome: State) void {
            std.debug.assert(outcome != .requested);
            if (self.in_flight) |active| {
                if (active.ticket == request_.ticket) self.in_flight = null;
            }
            if (!self.accepts(request_)) return;
            const at = self.index(request_.target).?;
            if (outcome == .shown) self.entries.items[at].state = .shown else self.terminal(gpa, at, outcome);
        }
    };
}

test "fold owner reconciles success failure cancellation supersession refusal and rebuilt identities" {
    const gpa = std.testing.allocator;
    const first: fold.Reference = .{ .source = .activity, .position = 1, .ordinal = 0, .content = .{ .length = 0, .digest = @splat(0) } };
    var second = first;
    second.content.digest[0] = 1;
    const asked: reading.Asked = .{ .place = .live, .sent = 0, .generation = 0 };
    const Document = struct {
        reference: fold.Reference,
        open: bool = false,
        offset: usize = 73,
        pub fn findTool(self: @This(), reference: fold.Reference) ?usize {
            return if (std.meta.eql(reference, self.reference)) self.offset else null;
        }
        pub fn toolIsOpen(self: @This(), _: usize) bool {
            return self.open;
        }
    };
    for ([_]State{ .shown, .failed, .cancelled, .closed }) |outcome| {
        var owner: Sized(2) = .{};
        defer owner.deinit(gpa);
        try owner.request(gpa, first);
        try std.testing.expectEqual(State.requested, owner.state(first));
        const request_ = owner.start(asked).?;
        try std.testing.expect(owner.start(asked) == null);
        owner.finish(gpa, request_, outcome);
        try std.testing.expect(owner.in_flight == null);
        if (outcome == .shown) {
            try std.testing.expectEqual(State.shown, owner.state(first));
            owner.rebuild(Document{ .reference = second });
            try std.testing.expect(!owner.pending());
            owner.rebuild(Document{ .reference = first, .open = true });
            try std.testing.expect(!owner.pending());
            owner.rebuild(Document{ .reference = first, .offset = 999 });
            const restored = owner.start(asked).?;
            try std.testing.expectEqualDeep(first, restored.target);
            try std.testing.expect(restored.ticket != request_.ticket);
            owner.finish(gpa, request_, .shown); // A previous completion has no authority.
            try std.testing.expectEqual(State.requested, owner.state(first));
            owner.finish(gpa, restored, .shown);
            owner.close(gpa, first);
        } else {
            try std.testing.expectEqual(State.closed, owner.state(first));
            // The very next toggle retries, rather than closing ghost intent.
            try owner.request(gpa, first);
            const retry = owner.start(asked).?;
            owner.finish(gpa, retry, .shown);
            owner.close(gpa, first);
        }
        try std.testing.expectEqual(@as(usize, 0), owner.entries.capacity);
    }
    var owner: Sized(2) = .{};
    defer owner.deinit(gpa);
    try owner.request(gpa, first);
    const old = owner.start(asked).?;
    while (owner.cancelNext(gpa)) |_| {}
    try owner.request(gpa, first);
    owner.finish(gpa, old, .shown); // Closing and reopening cannot reuse a receipt.
    try std.testing.expectEqual(State.requested, owner.state(first));
    const newer = owner.start(asked).?;
    owner.finish(gpa, newer, .shown);
    try owner.request(gpa, second);
    while (owner.cancelNext(gpa)) |_| {}
    try std.testing.expectEqual(State.shown, owner.state(first));
    try std.testing.expectEqual(State.closed, owner.state(second));
}

test "fold owner keys every Reference field and bounds identity allocation" {
    const first: fold.Reference = .{ .source = .activity, .position = 7, .ordinal = 2, .content = .{ .length = 8, .digest = @splat(0) } };
    var owner: Sized(2) = .{};
    defer owner.deinit(std.testing.allocator);
    try owner.request(std.testing.allocator, first);
    try owner.request(std.testing.allocator, first);
    try std.testing.expectEqual(@as(usize, 1), owner.entries.items.len);
    var changed: [5]fold.Reference = @splat(first);
    changed[0].source = .conversation;
    changed[1].position += 1;
    changed[2].ordinal += 1;
    changed[3].content.length += 1;
    changed[4].content.digest[0] ^= 1;
    for (changed) |reference| try std.testing.expect(!owner.contains(reference));
    try owner.request(std.testing.allocator, changed[0]);
    try std.testing.expectError(error.ToolFoldViewFull, owner.request(std.testing.allocator, changed[1]));
    owner.close(std.testing.allocator, first);
    owner.close(std.testing.allocator, changed[0]);
    try std.testing.expectEqual(@as(usize, 0), owner.entries.capacity);
}
