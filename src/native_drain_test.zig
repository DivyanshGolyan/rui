//! Noninstalled owner-boundary caller: coordinated native drain completion,
//! UI interruption and independent Admission failure through Frontend.run.
const std = @import("std");
const Frontend = @import("SessionFrontend.zig");
const Task = @import("ClientTask.zig");
const protocol = @import("protocol.zig");

extern fn drain_probe_service() void;
extern fn drain_probe_admission() void;
extern fn drain_probe_restored() c_int;
extern fn drain_probe_joined() c_int;
extern fn drain_probe_admission_joined() c_int;
var canonical_ui = false;
var canonical_admission = false;
var admission_finished = false;

fn pump(_: *anyopaque, _: std.Io, _: i32) !void {
    drain_probe_service(); // Worker has returned, publishing its actual result.
    return if (canonical_ui) error.CanonicalStoreFailure else error.InteractiveInterrupted;
}

fn admission(_: *anyopaque, _: *Task) !void {
    drain_probe_admission(); // Do not complete before direct drain restoration.
    admission_finished = true;
    return error.CanonicalStoreFailure;
}

fn prepare(self: *Frontend) !bool {
    try self.write("Exact choice: a/d/l\n");
    return true;
}

fn pick(self: *Frontend) !?protocol.Bounded(protocol.max_session_bytes) {
    self.terminal.pump = .{ .context = self, .service = pump };
    if (canonical_admission) {
        for ("original") |byte| _ = self.input.feed(byte);
        self.ticket = self.input.feed('\r').message;
        const Capture = struct {
            pub fn capture(_: @This(), _: []const u8) !void {}
        };
        try self.input.capture(self.ticket.?, Capture{});
        // Real owned descriptor, closed by Frontend.run after Admission joins.
        self.captured = .{ .file = try std.Io.Dir.cwd().openFile(self.init.io, "/dev/null", .{}), .length = 0, .saved = .{}, .target = .{ .message = .{ .bytes = 8, .digest = protocol.contentDigest("original") } } };
        try self.captured.?.saved.store.set("original/store");
        try self.captured.?.saved.session.set("original/session");
        try self.captured.?.saved.key.set("original/key");
        try self.captured.?.saved.kind.set("message");
        try self.admission.start(self.init.io, self, admission);
    }
    var buffer: [64]u8 = undefined;
    _ = try self.choose(&buffer, prepare, .{});
    return error.UnexpectedChoice;
}

fn unusedParse(_: []u8, _: [][]const u8) !usize {
    return error.UnexpectedCommand;
}
fn unusedRun(_: *Frontend, _: []const []const u8) !void {
    return error.UnexpectedCommand;
}

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(std.heap.c_allocator);
    defer std.heap.c_allocator.free(args);
    canonical_ui = std.mem.eql(u8, args[1], "canonical-ui");
    canonical_admission = std.mem.eql(u8, args[1], "restore-admission");
    const outcome = Frontend.run(init, "original/store", null, "/tmp", undefined, .{ .parse = unusedParse, .run = unusedRun, .pick = pick });
    // These are lifetime facts after the real Frontend unwind, not results
    // manufactured by the fixture to stand in for owned worker completion.
    if (drain_probe_joined() != 1 or drain_probe_restored() != 1 or
        (canonical_admission and (!admission_finished or drain_probe_admission_joined() != 1))) return error.CustodyNotSettled;
    std.debug.print("custody: drain joined once, restoration attempted once, Admission {s}\n", .{if (canonical_admission) "failed canonically and joined once" else "absent"});
    try outcome;
    return 0;
}
