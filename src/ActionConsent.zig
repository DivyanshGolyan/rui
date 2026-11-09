//! The permission card owns its selection and the request it last drew.
//! The Host revalidates every decision. Drawing is not a flush receipt.
const std = @import("std");
const policy = @import("session_consent.zig");
const Self = @This();

request: ?u64 = null,
drawn: ?u64 = null,
highlight: policy.Choice = .allow_once,
pasting: bool = false,

pub const Input = union(enum) {
    left,
    right,
    enter,
    click: policy.Choice,
    other,
    invalid,
    paste_start,
    paste_end,
};

pub fn adopt(self: *Self, action: u64) void {
    if (self.request == action) return;
    self.request = action;
    self.drawn = null;
    self.highlight = .allow_once;
}

pub fn withdraw(self: *Self) void {
    self.request = null;
    self.drawn = null;
    self.highlight = .allow_once;
}

/// Called when the card draws the current request. Authorization is immediate;
/// a true result schedules the test readiness notification on the next tick.
pub fn draw(self: *Self) bool {
    const changed = self.drawn != self.request;
    self.drawn = self.request;
    return changed and self.drawn != null;
}

pub fn handle(self: *Self, input: Input) ?policy.Decision {
    switch (input) {
        .paste_start => {
            self.pasting = true;
            return null;
        },
        .paste_end => {
            self.pasting = false;
            return null;
        },
        else => {},
    }
    if (self.pasting) return null;
    const request = self.request orelse return null;
    if (self.drawn != request) return null;
    const choice: policy.Choice = switch (input) {
        .left => {
            self.highlight = .allow_once;
            return null;
        },
        .right => {
            self.highlight = .deny;
            return null;
        },
        .enter => self.highlight,
        .click => |choice| choice,
        .other, .invalid => return null,
        .paste_start, .paste_end => unreachable,
    };
    const decision: policy.Decision = .{ .action = self.drawn.?, .choice = choice };
    self.withdraw();
    return decision;
}

test "Action consent decides only the request the card drew" {
    var consent: Self = .{};
    consent.adopt(41);
    try std.testing.expectEqual(null, consent.handle(.enter));
    try std.testing.expect(consent.draw());
    try std.testing.expect(!consent.draw());
    consent.adopt(52);
    try std.testing.expectEqual(null, consent.handle(.enter));
    try std.testing.expectEqual(null, consent.handle(.{ .click = .deny }));
    try std.testing.expect(consent.draw());
    try std.testing.expectEqual(policy.Decision{ .action = 52, .choice = .allow_once }, consent.handle(.enter).?);
    try std.testing.expectEqual(null, consent.handle(.enter));
}

test "Action consent ignores typing and defaults each request to Allow once" {
    var consent: Self = .{};
    consent.adopt(17);
    _ = consent.draw();
    try std.testing.expectEqual(null, consent.handle(.right));
    consent.adopt(17);
    for ([_]Input{ .other, .invalid }) |input| try std.testing.expectEqual(null, consent.handle(input));
    try std.testing.expectEqual(policy.Decision{ .action = 17, .choice = .deny }, consent.handle(.enter).?);
    consent.adopt(29);
    _ = consent.draw();
    _ = consent.handle(.right);
    _ = consent.handle(.left);
    try std.testing.expectEqual(policy.Decision{ .action = 29, .choice = .allow_once }, consent.handle(.enter).?);
    consent.adopt(31);
    _ = consent.draw();
    try std.testing.expectEqual(policy.Choice.allow_once, consent.highlight);
    try std.testing.expectEqual(policy.Decision{ .action = 31, .choice = .deny }, consent.handle(.{ .click = .deny }).?);
}

test "Action consent marked paste never chooses even across request replacement" {
    var consent: Self = .{};
    consent.adopt(17);
    _ = consent.draw();
    _ = consent.handle(.paste_start);
    consent.withdraw();
    consent.adopt(29);
    _ = consent.draw();
    for ([_]Input{ .left, .right, .enter, .{ .click = .deny }, .other, .invalid }) |input|
        try std.testing.expectEqual(null, consent.handle(input));
    _ = consent.handle(.paste_end);
    try std.testing.expectEqual(policy.Decision{ .action = 29, .choice = .allow_once }, consent.handle(.enter).?);
}
