const std = @import("std");
const preferences = @import("preferences");

/// Native adapter for exercising the production preference owner independently
/// of the separately owned CLI integration. No credential/network effects.
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) return error.InvalidArguments;
    if (std.mem.eql(u8, args[1], "read")) {
        _ = try preferences.load(args[2]);
    } else if (std.mem.eql(u8, args[1], "login")) {
        _ = try preferences.fillProviderAfterLogin(args[2]);
    } else if (std.mem.eql(u8, args[1], "set") and args.len == 4) {
        _ = try preferences.update(args[2], .{ .provider = .{ .set = "codex" }, .model = .{ .set = args[3] } }, .missing);
    } else return error.InvalidArguments;
}
