//! Native Action offer and decision owner. The caller runs `read` in its
//! existing read worker, then installs the result only after that worker joins.
//! The caller owns the rendered sink and must discard it when install fails.
const std = @import("std");
const client = @import("client.zig");
const protocol = @import("protocol.zig");
const View = @import("session_view.zig");
const observations = @import("NativeObservations.zig");
const Self = @This();

pub const Session = [protocol.session_id_bytes]u8;
pub const Ticket = struct { session: Session, generation: u64 };
pub const Offer = struct { ticket: Ticket, instance: protocol.InstanceId, action: u64, summary: View.ActionSummary };
pub const Observation = struct { ticket: Ticket, instance: protocol.InstanceId, offer: ?Offer };

// No Action content or IO handle is retained by this owner.
generation: u64 = 0,
session: ?Session = null,
offer: ?Offer = null,
choice: ?protocol.PermissionDecision = null,

fn advance(self: *Self) void {
    self.generation = std.math.add(u64, self.generation, 1) catch @panic("Action generation exhausted");
}

/// Call on navigation, before abandoning or cancelling any read. Tickets from
/// an earlier navigation can never install a result or authorize a gesture.
pub fn navigate(self: *Self, session: ?Session) void {
    self.advance();
    self.session = session;
    self.offer = null;
    self.choice = null;
}

pub fn ticket(self: *const Self) ?Ticket {
    return .{ .session = self.session orelse return null, .generation = self.generation };
}

/// Reads and renders the exact first Action from one Current capture. A null
/// offer means no actionable target, not permission to select a successor.
/// `scratch` and `sink` are borrowed exclusively for the duration of the job.
pub fn read(requests: client.Requests, store: []const u8, target: Ticket, scratch: std.Io.File, sink: anytype, colour: bool) !Observation {
    const instance = switch (client.hostStatus(requests.io, store)) {
        .ready => |ready| ready.instance,
        else => return error.HostUnavailable,
    };
    var fenced = requests;
    fenced.host_instance = &instance;
    const current = try View.current(fenced, store, &target.session, scratch);
    const offer: ?Offer = offer: {
        const action = if (current.work.first_action) |id| id.value else break :offer null;
        const tool = try View.actionToolFromCapture(&current, requests.io, scratch, action) orelse break :offer null;
        const summary = try View.permissionForTool(fenced, store, &target.session, action, scratch, sink, colour, &tool);
        break :offer .{ .ticket = target, .instance = instance, .action = action, .summary = summary };
    };
    try observations.ensureServing(requests.io, store, instance);
    return .{ .ticket = target, .instance = instance, .offer = offer };
}

fn same(a: Ticket, b: Ticket) bool {
    return a.generation == b.generation and std.mem.eql(u8, &a.session, &b.session);
}

/// Preserve a fresh choice only while the identical Action remains offered.
/// The caller must order reads: never install an older observation after a newer one.
/// After installation, bind gestures to `self.offer.?.ticket`, not the read
/// ticket: a changed Action receives a fresh incarnation.
pub fn install(self: *Self, observation: Observation) bool {
    const current = self.ticket() orelse return false;
    if (!same(current, observation.ticket)) return false;
    if (observation.offer) |next| {
        if (!same(next.ticket, current) or !std.mem.eql(u8, &next.instance, &observation.instance)) return false;
    }
    const previous = if (self.offer) |value| value.action else null;
    const next = if (observation.offer) |value| value.action else null;
    const changed_host = if (self.offer) |value| !std.mem.eql(u8, &value.instance, &observation.instance) else false;
    if (previous != next or changed_host) {
        self.advance();
        self.choice = null;
    }
    self.offer = observation.offer;
    if (self.offer) |*offer| offer.ticket = self.ticket().?;
    return true;
}

/// A gesture must name the displayed offer and must not come from paste.
pub fn choose(self: *Self, target: Ticket, action: u64, decision: protocol.PermissionDecision, pasted: bool) bool {
    const offer = self.offer orelse return false;
    if (pasted or !same(target, offer.ticket) or action != offer.action) return false;
    self.choice = decision;
    return true;
}

/// On a failed read the caller revokes only the still-current ticket; a late
/// failure must not erase a later offer. Discard the matching rendered sink.
pub fn readFailed(self: *Self, target: Ticket) void {
    const current = self.ticket() orelse return;
    if (!same(current, target)) return;
    self.advance();
    self.offer = null;
    self.choice = null;
}

/// A confirmed choice is handed immediately to the sole Submission owner.
/// The caller must check Submission is idle before confirming, bind its stable
/// Session, then call beginObservedDecision without storing or queueing this
/// value. That owner freezes it before fallible reservation or launch.
pub const Decision = struct {
    action: u64,
    decision: protocol.PermissionDecision,
    observed_instance: protocol.InstanceId,
};

pub fn confirm(self: *Self, target: Ticket, action: u64, pasted: bool) ?Decision {
    const offer = self.offer orelse return null;
    const decision = self.choice orelse return null;
    if (pasted or !same(target, offer.ticket) or action != offer.action) return null;
    self.advance();
    self.choice = null;
    self.offer = null;
    return .{ .action = action, .decision = decision, .observed_instance = offer.instance };
}

const test_instance: protocol.InstanceId = @splat(1);

test "Action choice is explicit and bound to the exact displayed offer" {
    var owner: Self = .{};
    owner.navigate("k7m2qx".*);
    const initial = owner.ticket().?;
    try std.testing.expect(owner.install(.{ .ticket = initial, .instance = test_instance, .offer = .{ .ticket = initial, .instance = test_instance, .action = 19, .summary = .{} } }));
    const t = owner.ticket().?;
    const one: Offer = .{ .ticket = t, .instance = test_instance, .action = 19, .summary = .{} };
    try std.testing.expect(!owner.choose(t, 19, .allow_once, true));
    try std.testing.expect(!owner.choose(t, 20, .allow_once, false));
    try std.testing.expect(owner.choice == null);
    try std.testing.expect(owner.choose(t, 19, .deny, false));
    try std.testing.expect(owner.install(.{ .ticket = t, .instance = test_instance, .offer = one }));
    try std.testing.expectEqual(protocol.PermissionDecision.deny, owner.choice.?);
    try std.testing.expect(owner.install(.{ .ticket = t, .instance = test_instance, .offer = .{ .ticket = t, .instance = test_instance, .action = 20, .summary = .{} } }));
    try std.testing.expect(owner.choice == null);
    try std.testing.expect(!owner.choose(t, 20, .allow_once, false));
    try std.testing.expect(!owner.choose(t, 19, .allow_once, false));
    const replacement = owner.ticket().?;
    try std.testing.expect(owner.choose(replacement, 20, .allow_once, false));
    try std.testing.expect(owner.install(.{ .ticket = replacement, .instance = test_instance, .offer = null }));
    try std.testing.expect(!owner.install(.{ .ticket = replacement, .instance = test_instance, .offer = .{ .ticket = replacement, .instance = test_instance, .action = 20, .summary = .{} } }));
    owner.navigate("p33rs1".*);
    try std.testing.expect(!owner.install(.{ .ticket = t, .instance = test_instance, .offer = one }));
    try std.testing.expect(!owner.choose(t, 19, .allow_once, false));
}

test "confirmation requires a fresh choice and preserves its Host" {
    var owner: Self = .{};
    owner.navigate("k7m2qx".*);
    const initial = owner.ticket().?;
    try std.testing.expect(owner.install(.{ .ticket = initial, .instance = test_instance, .offer = .{ .ticket = initial, .instance = test_instance, .action = 19, .summary = .{} } }));
    const ticket = owner.ticket().?;
    try std.testing.expect(owner.confirm(ticket, 19, false) == null);
    try std.testing.expect(owner.choose(ticket, 19, .deny, false));
    try std.testing.expect(owner.confirm(ticket, 19, true) == null);
    try std.testing.expect(owner.confirm(ticket, 20, false) == null);
    const decision = owner.confirm(ticket, 19, false).?;
    try std.testing.expectEqual(@as(u64, 19), decision.action);
    try std.testing.expectEqual(protocol.PermissionDecision.deny, decision.decision);
    try std.testing.expectEqualSlices(u8, &test_instance, &decision.observed_instance);
    try std.testing.expect(owner.confirm(ticket, 19, false) == null);
    const late: Observation = .{ .ticket = ticket, .instance = test_instance, .offer = .{ .ticket = ticket, .instance = test_instance, .action = 19, .summary = .{} } };
    try std.testing.expect(!owner.install(late));
    const fresh = owner.ticket().?;
    try std.testing.expect(owner.install(.{ .ticket = fresh, .instance = test_instance, .offer = .{ .ticket = fresh, .instance = test_instance, .action = 19, .summary = .{} } }));
    try std.testing.expect(!owner.choose(ticket, 19, .allow_once, false));
    try std.testing.expect(owner.choose(owner.ticket().?, 19, .allow_once, false));
}

test "Host replacement or read failure revokes choice and old gestures" {
    var owner: Self = .{};
    owner.navigate("k7m2qx".*);
    const first = owner.ticket().?;
    try std.testing.expect(owner.install(.{ .ticket = first, .instance = test_instance, .offer = .{ .ticket = first, .instance = test_instance, .action = 19, .summary = .{} } }));
    const old = owner.ticket().?;
    try std.testing.expect(owner.choose(old, 19, .allow_once, false));
    const changed: protocol.InstanceId = @splat(2);
    try std.testing.expect(owner.install(.{ .ticket = old, .instance = changed, .offer = .{ .ticket = old, .instance = changed, .action = 19, .summary = .{} } }));
    try std.testing.expect(owner.choice == null);
    try std.testing.expect(!owner.choose(old, 19, .allow_once, false));
    const current = owner.ticket().?;
    try std.testing.expect(owner.choose(current, 19, .deny, false));
    owner.readFailed(old);
    try std.testing.expect(owner.choice != null);
    owner.readFailed(current);
    try std.testing.expect(owner.offer == null and owner.choice == null);
    try std.testing.expect(!owner.choose(current, 19, .deny, false));
}
