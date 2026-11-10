//! The search words supplied to a find-tools call.
pub const FindTools = struct {
    words: [8][]const u8 = @splat(""),
    count: usize = 0,
};
