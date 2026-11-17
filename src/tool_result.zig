const InputCapture = @import("InputCapture.zig");

pub const Value = union(enum) { text: []const u8, parts: InputCapture.Loan };
