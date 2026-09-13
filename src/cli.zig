const std = @import("std");
const client = @import("client.zig");
const server = @import("server.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len < 2) return usage();
    const command = args[1];
    if (std.mem.eql(u8, command, "serve")) return serve(init.io, args[2..]);
    if (std.mem.eql(u8, command, "configure")) return configure(init.io, args[2..]);
    if (std.mem.eql(u8, command, "message")) return message(init.io, args[2..]);
    if (std.mem.eql(u8, command, "retry")) return retry(init.io, args[2..]);
    if (std.mem.eql(u8, command, "observe-command")) return observe(init.io, args[2..]);
    if (std.mem.eql(u8, command, "inspect-session")) return inspect(init.io, args[2..]);
    return usage();
}

fn serve(io: std.Io, args: []const []const u8) !void {
    var store_path: ?[]const u8 = null;
    var active_capacity: usize = server.default_active_capacity;
    var faults: server.Faults = .{};
    var index: usize = 0;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--store")) {
            store_path = try takeValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--active-capacity")) {
            active_capacity = try std.fmt.parseInt(usize, try takeValue(args, &index), 10);
        } else if (std.mem.eql(u8, arg, "--fault")) {
            const fault = try takeValue(args, &index);
            if (std.mem.eql(u8, fault, "content-write")) faults.content_write = true else if (std.mem.eql(u8, fault, "content-read")) faults.content_read = true else if (std.mem.eql(u8, fault, "before-commit")) faults.before_commit = true else if (std.mem.eql(u8, fault, "startup-cleanup")) faults.startup_cleanup = true else return error.UnknownFault;
        } else return error.UnknownArgument;
        index += 1;
    }
    return server.serve(io, std.heap.c_allocator, store_path orelse return usage(), active_capacity, faults);
}

fn configure(io: std.Io, args: []const []const u8) !void {
    var input = client.ConfigureInput{
        .store = "",
        .record = "",
        .key = "",
        .session = "",
    };
    var key_seen = false;
    var index: usize = 0;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--store")) input.store = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--record")) input.record = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--key")) {
            input.key = try takeValue(args, &index);
            key_seen = true;
        } else if (std.mem.eql(u8, arg, "--session")) input.session = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--workspace")) input.workspace = .{ .present = true, .value = try takeValue(args, &index) } else if (std.mem.eql(u8, arg, "--model")) input.model = .{ .present = true, .value = try takeValue(args, &index) } else if (std.mem.eql(u8, arg, "--instructions")) input.instructions = .{ .state = .value, .path = try takeValue(args, &index) } else if (std.mem.eql(u8, arg, "--tools")) input.tools = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--permission-mode")) input.permission_mode = .{ .present = true, .value = try takeValue(args, &index) } else if (std.mem.eql(u8, arg, "--output-schema")) input.output_schema = .{ .state = .value, .path = try takeValue(args, &index) } else if (std.mem.eql(u8, arg, "--text-output")) input.output_schema = .{ .state = .explicit_null } else if (std.mem.eql(u8, arg, "--test-drop-reply")) input.drop_reply = try takeValue(args, &index) else return error.UnknownArgument;
        index += 1;
    }
    if (input.store.len == 0 or input.record.len == 0 or input.session.len == 0 or !key_seen) return usage();
    const status = try client.configure(io, input);
    if (status != 200 and status != 409) return error.HostInvocationFailed;
}

fn message(io: std.Io, args: []const []const u8) !void {
    var input = client.MessageInput{ .store = "", .record = "", .key = "", .session = "", .text_path = "" };
    var key_seen = false;
    var index: usize = 0;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--store")) input.store = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--record")) input.record = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--key")) {
            input.key = try takeValue(args, &index);
            key_seen = true;
        } else if (std.mem.eql(u8, arg, "--session")) input.session = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--text")) input.text_path = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--test-drop-reply")) input.drop_reply = try takeValue(args, &index) else return error.UnknownArgument;
        index += 1;
    }
    if (input.store.len == 0 or input.record.len == 0 or input.session.len == 0 or input.text_path.len == 0 or !key_seen) return usage();
    const status = try client.message(io, input);
    if (status != 200 and status != 409) return error.HostInvocationFailed;
}

fn retry(io: std.Io, args: []const []const u8) !void {
    var store_path: ?[]const u8 = null;
    var record: ?[]const u8 = null;
    var kind: ?[]const u8 = null;
    var index: usize = 0;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--store")) store_path = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--record")) record = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--kind")) kind = try takeValue(args, &index) else return error.UnknownArgument;
        index += 1;
    }
    const status = try client.retry(io, store_path orelse return usage(), record orelse return usage(), kind orelse return usage());
    if (status != 200 and status != 409) return error.HostInvocationFailed;
}

fn observe(io: std.Io, args: []const []const u8) !void {
    var store_path: ?[]const u8 = null;
    var key: ?[]const u8 = null;
    var index: usize = 0;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--store")) store_path = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--key")) key = try takeValue(args, &index) else return error.UnknownArgument;
        index += 1;
    }
    const status = try client.observeCommand(io, store_path orelse return usage(), key orelse return usage());
    if (status != 200) return error.HostInvocationFailed;
}

fn inspect(io: std.Io, args: []const []const u8) !void {
    var store_path: ?[]const u8 = null;
    var session: ?[]const u8 = null;
    var index: usize = 0;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--store")) store_path = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--session")) session = try takeValue(args, &index) else return error.UnknownArgument;
        index += 1;
    }
    const status = try client.inspectSession(io, store_path orelse return usage(), session orelse return usage());
    if (status != 200) return error.HostInvocationFailed;
}

fn takeValue(args: []const []const u8, index: *usize) ![]const u8 {
    index.* += 1;
    if (index.* >= args.len) return error.MissingArgumentValue;
    return args[index.*];
}

fn usage() error{InvalidArguments} {
    std.debug.print(
        \\usage:
        \\  latifa serve --store PATH [--active-capacity N] [--fault NAME]
        \\  latifa configure --store PATH --record FILE --key KEY --session REF [settings]
        \\  latifa message --store PATH --record FILE --key KEY --session REF --text FILE|-
        \\  latifa retry --store PATH --record FILE --kind configure|message
        \\  latifa observe-command --store PATH --key KEY
        \\  latifa inspect-session --store PATH --session REF
        \\
    , .{});
    return error.InvalidArguments;
}
