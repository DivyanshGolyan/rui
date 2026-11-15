pub const Capacity = packed struct(u3) {
    credit: enum(u2) { none, foreground, background },
    mcp: bool,

    pub fn fromFree(free: usize, mcp_available: bool) Capacity {
        return .{ .credit = if (free == 0) .none else if (free == 1) .foreground else .background, .mcp = mcp_available };
    }

    pub fn foreground(self: Capacity) bool {
        return self.credit != .none;
    }

    pub fn background(self: Capacity) bool {
        return self.credit == .background;
    }
};
