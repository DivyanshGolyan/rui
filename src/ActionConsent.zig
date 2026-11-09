//! The permission card owns its selection and the request it last drew.
//! The Host revalidates every decision. Drawing is not a flush receipt.
const std = @import("std");
const policy = @import("session_consent.zig");
const Self = @This();

request: ?u64 = null,
drawn: ?u64 = null,
highlight: policy.Choice = .allow_once,
pressed: ?policy.Decision = null,

pub const Input = union(enum) {
    left,
    right,
    enter,
    press: ?policy.Choice,
    release: ?policy.Choice,
    cancel,
    other,
    invalid,
};

pub fn adopt(self: *Self, action: u64) void {
    if (self.request == action) return;
    self.request = action;
    self.drawn = null;
    self.highlight = .allow_once;
    self.pressed = null;
}

pub fn withdraw(self: *Self) void {
    self.request = null;
    self.drawn = null;
    self.highlight = .allow_once;
    self.pressed = null;
}

/// Called when the card draws the current request. Authorization is immediate;
/// a true result schedules the test readiness notification on the next tick.
pub fn draw(self: *Self) bool {
    const changed = self.drawn != self.request;
    self.drawn = self.request;
    return changed and self.drawn != null;
}

pub fn handle(self: *Self, input: Input, pasting: bool) ?policy.Decision {
    const pressed = self.pressed;
    self.pressed = null;
    if (pasting) return null;
    const request = self.request orelse return null;
    if (self.drawn != request) return null;
    const choice: policy.Choice = switch (input) {
        .press => |choice| {
            if (choice) |value| self.pressed = .{ .action = request, .choice = value };
            return null;
        },
        .release => |choice| release: {
            const held = pressed orelse return null;
            if (held.action != request or choice != held.choice) return null;
            break :release held.choice;
        },
        .left => {
            self.highlight = .allow_once;
            return null;
        },
        .right => {
            self.highlight = .deny;
            return null;
        },
        .enter => self.highlight,
        .other, .invalid, .cancel => return null,
    };
    const decision: policy.Decision = .{ .action = self.drawn.?, .choice = choice };
    self.withdraw();
    return decision;
}

test "Action consent decides only the request the card drew" {
    var consent: Self = .{};
    consent.adopt(41);
    try std.testing.expectEqual(null, consent.handle(.enter, false));
    try std.testing.expect(consent.draw());
    try std.testing.expect(!consent.draw());
    consent.adopt(52);
    try std.testing.expectEqual(null, consent.handle(.enter, false));
    try std.testing.expectEqual(null, consent.handle(.{ .press = .deny }, false));
    try std.testing.expectEqual(null, consent.handle(.{ .release = .deny }, false));
    try std.testing.expect(consent.draw());
    try std.testing.expectEqual(policy.Decision{ .action = 52, .choice = .allow_once }, consent.handle(.enter, false).?);
    try std.testing.expectEqual(null, consent.handle(.enter, false));
}

test "Action consent ignores typing and defaults each request to Allow once" {
    var consent: Self = .{};
    consent.adopt(17);
    _ = consent.draw();
    try std.testing.expectEqual(null, consent.handle(.right, false));
    consent.adopt(17);
    for ([_]Input{ .other, .invalid }) |input| try std.testing.expectEqual(null, consent.handle(input, false));
    try std.testing.expectEqual(policy.Decision{ .action = 17, .choice = .deny }, consent.handle(.enter, false).?);
    consent.adopt(29);
    _ = consent.draw();
    _ = consent.handle(.right, false);
    _ = consent.handle(.left, false);
    try std.testing.expectEqual(policy.Decision{ .action = 29, .choice = .allow_once }, consent.handle(.enter, false).?);
    consent.adopt(31);
    _ = consent.draw();
    try std.testing.expectEqual(policy.Choice.allow_once, consent.highlight);
    try std.testing.expectEqual(null, consent.handle(.{ .press = .deny }, false));
    try std.testing.expectEqual(policy.Decision{ .action = 31, .choice = .deny }, consent.handle(.{ .release = .deny }, false).?);
}

test "Action consent marked paste never chooses even across request replacement" {
    var consent: Self = .{};
    consent.adopt(17);
    _ = consent.draw();
    consent.withdraw();
    consent.adopt(29);
    _ = consent.draw();
    for ([_]Input{ .left, .right, .enter, .{ .press = .deny }, .{ .release = .deny }, .other, .invalid }) |input|
        try std.testing.expectEqual(null, consent.handle(input, true));
    try std.testing.expectEqual(policy.Decision{ .action = 29, .choice = .allow_once }, consent.handle(.enter, false).?);
}
