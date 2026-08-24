pub const Fence = struct {
    context: *anyopaque,
    authorize: *const fn (*anyopaque) anyerror!void,
};
