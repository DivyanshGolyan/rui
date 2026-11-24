//! Heap allocation that leaves its bytes unwritten until the producer fills them.

const std = @import("std");

/// One `T` on the heap whose bytes stay unwritten until its initializer or
/// producer fills them. `Allocator.create` would first write 0xAA over every
/// byte in ReleaseSafe. Freed with `allocator.destroy`.
pub fn createUnfilled(allocator: std.mem.Allocator, comptime T: type) error{OutOfMemory}!*T {
    const bytes = allocator.rawAlloc(@sizeOf(T), .of(T), @returnAddress()) orelse return error.OutOfMemory;
    return @ptrCast(@alignCast(bytes));
}
