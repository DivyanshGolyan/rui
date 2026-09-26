const std = @import("std");
const evaluator = @import("evaluator");
const c = @cImport({
    @cInclude("unistd.h");
});

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.ExpectedEvaluatorPath;
    var random: u64 = undefined;
    io.random(@ptrCast(&random));
    var name_buffer: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buffer, ".zig-cache/evaluator-host-{x}", .{random});
    try std.Io.Dir.cwd().createDirPath(io, name);
    defer std.Io.Dir.cwd().deleteTree(io, name) catch {};
    var scratch = try std.Io.Dir.cwd().openDir(io, name, .{ .iterate = true });
    defer scratch.close(io);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try scratch.realPath(io, &path_buffer);
    var used: std.atomic.Value(u64) = .init(0);
    var owner = evaluator.Owner.init(io, path_buffer[0..length], .{ .used = &used, .limit = 32 * 1024 * 1024 });
    const executable_dir = std.fs.path.dirname(args[1]) orelse ".";
    var dir = try std.Io.Dir.cwd().openDir(io, executable_dir, .{});
    defer dir.close(io);
    var executable_path: [std.fs.max_path_bytes]u8 = undefined;
    const executable_length = try dir.realPath(io, &executable_path);
    owner.child_name = try std.fs.path.join(init.arena.allocator(), &.{
        executable_path[0..executable_length], std.fs.path.basename(args[1]),
    });

    var writer = try scratch.createFile(io, "source", .{});
    try writer.writeStreamingAll(io, "export default async function workflow(_, input) { return input; }");
    writer.close(io);
    const source = try scratch.openFile(io, "source", .{});
    defer source.close(io);
    var diagnostic = evaluator.Diagnostic{};
    try owner.validate(source, evaluator.Cancellation.never(), &diagnostic);
    if (diagnostic.text().len != 0) return error.UnexpectedCompilerDiagnostic;
    var missing_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const missing = try std.fmt.bufPrint(&missing_buffer, "{s}/unavailable", .{owner.scratch_path});
    const scratch_path = owner.scratch_path;
    owner.scratch_path = missing;
    owner.output_removal = .injected_failure;
    try owner.validate(source, evaluator.Cancellation.never(), &diagnostic);
    try owner.finish();
    if (used.load(.acquire) != 0) return error.CompileOnlyScratchCharged;
    owner.scratch_path = scratch_path;
    owner.output_removal = .native;

    writer = try scratch.createFile(io, "prepared", .{});
    try writer.writeStreamingAll(io, &.{ 5, 1, 0, 0, 0, 2 });
    writer.close(io);
    const prepared = try scratch.openFile(io, "prepared", .{});
    defer prepared.close(io);
    var observation = struct { io: std.Io, called: bool = false }{ .io = io };
    try owner.evaluate(source, prepared, evaluator.Cancellation.never(), &observation, struct {
        fn consume(observed: *@TypeOf(observation), output: *std.Io.File) !void {
            if (c.write(output.handle, "!", 1) != -1) return error.WritableEvaluatorResult;
            var bytes: [4]u8 = undefined;
            if (try output.readPositionalAll(observed.io, &bytes, 0) != 4 or
                !std.mem.eql(u8, &bytes, "true")) return error.UnexpectedEvaluatorOutput;
            observed.called = true;
        }
    }.consume);
    if (!observation.called or used.load(.acquire) != 0) return error.EvaluatorOwnerLeaked;
    try owner.finish();
}
