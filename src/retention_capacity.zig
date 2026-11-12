//! Retention's fixed orchestration population and its value-only entry layout.
const Bounded = @import("bounded.zig").Bounded;

pub const orchestration_bytes: usize = 64 * 1024;
pub const State = enum(u8) { free, reserved, retained, evicting, failed };
pub const Entry = struct {
    state: State = .free,
    generation: u64 = 0,
    sequence: u64 = 0,
    name: Bounded(96) = .{},
    charged: u64 = 0,
};
pub const entries = orchestration_bytes / @sizeOf(Entry);
