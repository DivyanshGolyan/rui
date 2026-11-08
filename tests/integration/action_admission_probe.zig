//! Test-only driver for the actual Action submission owner. Parent controls
//! each gate and sets a bounded process deadline; no UI or production caller.
const std = @import("std");
const Submission = @import("rui_submission");

fn emit(io: std.Io, comptime format: []const u8, args: anytype) !void {
    var buffer: [512]u8 = undefined;
    try std.Io.File.stdout().writeStreamingAll(io, try std.fmt.bufPrint(&buffer, format, args));
}
fn gate(io: std.Io, expected: u8) !void {
    var value: [1]u8 = undefined;
    const count = try std.Io.File.stdin().readStreaming(io, &.{&value});
    if (count != 1 or value[0] != expected) return error.InvalidGate;
}
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(std.heap.c_allocator);
    defer std.heap.c_allocator.free(args);
    if (args.len != 6) return error.InvalidArguments;
    var owner: Submission = .{ .io = init.io, .store = args[1], .session = args[2], .directory = args[3], .environment = .empty };
    defer { owner.cancel(); _ = owner.join(); owner.close(); }
    if (args[5].len != 32) return error.InvalidInstanceId;
    var instance: [16]u8 = undefined;
    if ((try std.fmt.hexToBytes(&instance, args[5])).len != instance.len) return error.InvalidInstanceId;
    try owner.beginObservedDecision(.{ .action = try std.fmt.parseInt(u64, args[4], 10), .decision = .allow_once, .observed_instance = instance });
    const key = owner.key;
    const prequeued = if (owner.requestRecovery(&key)) |_| "unexpected_accepted" else |err| @errorName(err);
    try emit(init.io, "START key={s} early={s}\n", .{ &key, prequeued });
    try gate(init.io, 'J');
    const first = owner.join();
    try emit(init.io, "JOIN result={s} error={s} state={s} key={s}\n", .{ @tagName(first), if (first == .failed) @errorName(first.failed.err) else "none", if (owner.view()) |v| @tagName(v.state) else "released", &key });
    try gate(init.io, 'R');
    try owner.requestRecovery(&key);
    const launch = try owner.advance();
    if (launch != .absent) return error.UnexpectedRetryOutcome;
    try emit(init.io, "RETRY key={s}\n", .{&key});
    const second = owner.join();
    try emit(init.io, "RESULT result={s} error={s} state={s} key={s}\n", .{ @tagName(second), if (second == .failed) @errorName(second.failed.err) else "none", if (owner.view()) |v| @tagName(v.state) else "released", &key });
}
