//! Pure layout decisions for ordered text runs and images.
const std = @import("std");
const media = @import("input_media.zig");
const input_parts = @import("input_parts.zig");

pub const Layout = struct {
    /// Closed text runs and committed images. The current run is not counted.
    parts: u32 = 0,
    /// Includes pending excerpt notes as well as buffered text.
    run_open: bool = false,
    image_bytes: u64 = 0,
    /// Once the part cap forces a diagnostic, later images join the suffix.
    suffix: bool = false,

    pub const Image = struct {
        length: u64,
        /// No more content follows this image, including content that could be rejected.
        last: bool,
        /// A footer will be emitted even if this is the last content item.
        footer_pending: bool,
    };
    pub const Decision = union(enum) { commit, refuse: []const u8 };

    /// A part-limit refusal locks the final slot for the diagnostic suffix.
    /// The caller adds each refusal diagnostic to the current text run and
    /// commits accepted images only after intake succeeds.
    pub fn image(self: *Layout, it: Image, limits: media.Limits) Decision {
        if (self.image_bytes > limits.max_bytes or it.length > limits.max_bytes - self.image_bytes)
            return .{ .refuse = "image resource limit" };
        const needed: u64 = @as(u64, self.parts) + @intFromBool(self.run_open) + 1 +
            @intFromBool(!it.last or it.footer_pending);
        if (self.suffix or needed > input_parts.max_parts) {
            self.suffix = true;
            return .{ .refuse = "image part limit" };
        }
        return .commit;
    }

    /// Call after the run, if any, and the image have been successfully captured.
    pub fn committed(self: *Layout, length: u64) void {
        self.parts += @as(u32, @intFromBool(self.run_open)) + 1;
        self.run_open = false;
        self.image_bytes += length;
        std.debug.assert(self.parts <= input_parts.max_parts);
    }
};

test "layout reserves a trailing run at the part limit" {
    const limits: media.Limits = .{};
    for ([_]u32{ 1497, 1498, 1499 }) |parts| {
        for ([_]bool{ false, true }) |run| {
            for ([_]bool{ false, true }) |last| {
                for ([_]bool{ false, true }) |footer| {
                    var layout: Layout = .{ .parts = parts, .run_open = run };
                    const expected = @as(u64, parts) + @intFromBool(run) + 1 + @intFromBool(!last or footer) <= input_parts.max_parts;
                    const decision = layout.image(.{ .length = 1, .last = last, .footer_pending = footer }, limits);
                    try std.testing.expectEqual(expected, decision == .commit);
                    if (decision == .refuse) try std.testing.expectEqualStrings("image part limit", decision.refuse);
                }
            }
        }
    }
}

test "layout merges text and notes and commits only successful images" {
    var layout: Layout = .{ .run_open = true };
    const limits: media.Limits = .{ .max_bytes = 10 };
    try std.testing.expect(layout.image(.{ .length = 4, .last = false, .footer_pending = false }, limits) == .commit);
    // A check does not change the layout when image intake subsequently rejects it.
    try std.testing.expectEqual(@as(u32, 0), layout.parts);
    try std.testing.expect(layout.run_open);
    layout.committed(4);
    try std.testing.expectEqual(@as(u32, 2), layout.parts);
    try std.testing.expect(!layout.run_open);
    try std.testing.expectEqual(@as(u64, 4), layout.image_bytes);
    layout.run_open = true;
    layout.committed(6);
    try std.testing.expectEqual(@as(u32, 4), layout.parts);
    try std.testing.expectEqual(@as(u64, 10), layout.image_bytes);
}

test "layout checks aggregate image bytes including overflow and exact fit" {
    const limits: media.Limits = .{ .max_bytes = 10 };
    var layout: Layout = .{ .image_bytes = 6 };
    try std.testing.expect(layout.image(.{ .length = 4, .last = true, .footer_pending = false }, limits) == .commit);
    const too_large = layout.image(.{ .length = 5, .last = true, .footer_pending = false }, limits);
    try std.testing.expectEqualStrings("image resource limit", too_large.refuse);
    const overflow = layout.image(.{ .length = std.math.maxInt(u64), .last = true, .footer_pending = false }, .{ .max_bytes = std.math.maxInt(u64) });
    try std.testing.expectEqualStrings("image resource limit", overflow.refuse);
    var exceeded: Layout = .{ .image_bytes = 11 };
    try std.testing.expect(exceeded.image(.{ .length = 0, .last = true, .footer_pending = false }, limits) == .refuse);
}

test "part refusal locks suffix but resource refusal permits smaller image" {
    const limits: media.Limits = .{ .max_bytes = 10 };
    var suffix: Layout = .{ .parts = input_parts.max_parts - 1 };
    const first = suffix.image(.{ .length = 1, .last = false, .footer_pending = false }, limits);
    try std.testing.expectEqualStrings("image part limit", first.refuse);
    try std.testing.expect(suffix.suffix);
    // Even if no diagnostic bytes fit the excerpt, its omission note shares
    // the reserved suffix; a later last image must not consume that slot.
    const later = suffix.image(.{ .length = 1, .last = true, .footer_pending = false }, limits);
    try std.testing.expectEqualStrings("image part limit", later.refuse);
    try std.testing.expectEqual(input_parts.max_parts - 1, suffix.parts);

    var bytes: Layout = .{ .image_bytes = 6 };
    const large = bytes.image(.{ .length = 5, .last = false, .footer_pending = false }, limits);
    try std.testing.expectEqualStrings("image resource limit", large.refuse);
    try std.testing.expect(!bytes.suffix);
    bytes.run_open = true; // the resource diagnostic precedes the smaller image
    try std.testing.expect(bytes.image(.{ .length = 4, .last = true, .footer_pending = false }, limits) == .commit);
    bytes.committed(4);
    try std.testing.expectEqual(@as(u32, 2), bytes.parts);
}
