//! The permission card owns its selection and the request it last drew.
//! The Host revalidates every decision. Drawing is not a flush receipt.
const std = @import("std");
const policy = @import("session_consent.zig");
const Self = @This();

request: ?u64 = null,
drawn: ?u64 = null,
highlight: policy.Choice = .allow_once,
pressed: ?policy.Decision = null,
row: policy.Row = .selector,

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

/// Input policy is independent of rendering and of whether the kept draft is empty.
pub const RowKey = enum { printable, paste, escape, enter, arrows, screen, other };
pub const Route = enum { selector, draft, screen, blocked };
pub const RowStep = struct { row: policy.Row, route: Route };

pub fn rowStep(row: policy.Row, key: RowKey) RowStep {
    // The editor, not the choice's key classification, owns every draft key
    // except returning to the choice and refusing to send while it waits.
    if (row == .draft) return switch (key) {
        .escape => .{ .row = .selector, .route = .blocked },
        .enter => .{ .row = .draft, .route = .blocked },
        else => .{ .row = .draft, .route = .draft },
    };
    return switch (key) {
        .printable, .paste => .{ .row = .draft, .route = .draft },
        .escape, .screen => .{ .row = .selector, .route = .screen },
        .enter, .arrows, .other => .{ .row = .selector, .route = .selector },
    };
}

pub fn route(self: *Self, key: RowKey) Route {
    const step = rowStep(self.row, key);
    if (step.row != self.row) self.pressed = null;
    self.row = step.row;
    return step.route;
}

pub fn adopt(self: *Self, action: u64) void {
    if (self.request == action) return;
    self.request = action;
    self.drawn = null;
    self.highlight = .allow_once;
    self.pressed = null;
    self.row = .selector;
}

pub fn withdraw(self: *Self) void {
    self.request = null;
    self.drawn = null;
    self.highlight = .allow_once;
    self.pressed = null;
    self.row = .selector;
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
    if (pasting or self.row != .selector) return null;
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

test "Action consent row policy covers every key and kept draft state" {
    const Case = struct { key: RowKey, choice: RowStep, draft: RowStep };
    const cases = [_]Case{
        .{ .key = .printable, .choice = .{ .row = .draft, .route = .draft }, .draft = .{ .row = .draft, .route = .draft } },
        .{ .key = .paste, .choice = .{ .row = .draft, .route = .draft }, .draft = .{ .row = .draft, .route = .draft } },
        .{ .key = .escape, .choice = .{ .row = .selector, .route = .screen }, .draft = .{ .row = .selector, .route = .blocked } },
        .{ .key = .enter, .choice = .{ .row = .selector, .route = .selector }, .draft = .{ .row = .draft, .route = .blocked } },
        .{ .key = .arrows, .choice = .{ .row = .selector, .route = .selector }, .draft = .{ .row = .draft, .route = .draft } },
        .{ .key = .screen, .choice = .{ .row = .selector, .route = .screen }, .draft = .{ .row = .draft, .route = .draft } },
        .{ .key = .other, .choice = .{ .row = .selector, .route = .selector }, .draft = .{ .row = .draft, .route = .draft } },
    };
    for ([_][]const u8{ "", "kept draft", "first line\nsecond line" }) |draft| {
        for ([_]policy.Row{ .selector, .draft }) |row| for (cases) |case| {
            errdefer std.debug.print("row={s}, key={s}, kept draft={s}\n", .{ @tagName(row), @tagName(case.key), draft });
            var consent: Self = .{};
            consent.adopt(17);
            consent.row = row;
            const expected = if (row == .selector) case.choice else case.draft;
            const step = rowStep(row, case.key);
            try std.testing.expectEqual(expected.row, step.row);
            try std.testing.expectEqual(expected.route, step.route);
            try std.testing.expectEqual(expected.route, consent.route(case.key));
            try std.testing.expectEqual(expected.row, consent.row);
            // Arrival always shows the selector, regardless of a kept draft.
            consent.adopt(29);
            try std.testing.expectEqual(policy.Row.selector, consent.row);
        };
    }
}
