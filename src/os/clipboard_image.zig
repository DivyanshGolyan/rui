const std = @import("std");
const builtin = @import("builtin");
const input_media = @import("../input_media.zig");

pub const max_bytes = 16 * 1024 * 1024;
const allocator = std.heap.page_allocator;

pub const command_key = builtin.os.tag == .macos;

/// Reads a local clipboard image. The caller frees returned bytes with the page allocator.
/// Returns null if no supported image or usable local clipboard is available.
pub fn read(io: std.Io, environment: *const std.process.Environ.Map) !?[]u8 {
    for ([_][]const u8{ "SSH_CONNECTION", "SSH_CLIENT", "SSH_TTY" }) |name| {
        if (environment.contains(name)) return null;
    }

    return switch (builtin.os.tag) {
        .macos => blk: {
            var result: MacResult = null;
            rui_clipboard_macos_read(max_bytes, &result, receiveMacImage);
            break :blk result;
        },
        .linux => readLinux(io, environment),
        else => null,
    };
}

const MacResult = std.mem.Allocator.Error!?[]u8;
extern fn rui_clipboard_macos_read(
    limit: usize,
    context: *MacResult,
    receive: *const fn (*MacResult, [*]const u8, usize) callconv(.c) bool,
) void;

fn receiveMacImage(result: *MacResult, data: [*]const u8, length: usize) callconv(.c) bool {
    if (length == 0 or length > max_bytes) return false;
    const bytes = data[0..length];
    if (!validImage(bytes)) return false;
    result.* = allocator.dupe(u8, bytes) catch |err| err;
    return true;
}

fn validImage(bytes: []const u8) bool {
    var scanner = input_media.Scanner.init(bytes.len, null, .{ .max_bytes = max_bytes }) catch return false;
    var allowance = bytes.len;
    _ = scanner.advance(bytes, &allowance) catch return false;
    _ = scanner.finish() catch return false;
    return true;
}

fn readLinux(io: std.Io, environment: *const std.process.Environ.Map) !?[]u8 {
    const wayland = environment.contains("WAYLAND_DISPLAY");
    const x11 = environment.contains("DISPLAY");
    if (!wayland and !x11) return null;

    const Result = union(enum) { read: anyerror!?[]u8, deadline: std.Io.Cancelable!void };
    var storage: [2]Result = undefined;
    var pending = std.Io.Select(Result).init(io, &storage);
    // The deadline covers both clipboard transfers and helper exit after EOF.
    defer while (pending.cancel()) |result| switch (result) {
        .read => |outcome| if (outcome catch null) |bytes| allocator.free(bytes),
        .deadline => {},
    };
    try pending.concurrent(.read, readLinuxDisplays, .{ io, environment, wayland, x11 });
    try pending.concurrent(.deadline, std.Io.sleep, .{ io, .fromMilliseconds(1000), .awake });
    return switch (try pending.await()) {
        .read => |outcome| outcome,
        .deadline => null,
    };
}

fn readLinuxDisplays(io: std.Io, environment: *const std.process.Environ.Map, wayland: bool, x11: bool) !?[]u8 {
    const formats: []const input_media.Format = &.{ .png, .jpeg };
    if (wayland) for (formats) |format| {
        if (try runClipboard(io, environment, &.{ "wl-paste", "--no-newline", "--type", format.mime() })) |bytes| return bytes;
    };
    if (x11) for (formats) |format| {
        if (try runClipboard(io, environment, &.{ "xclip", "-selection", "clipboard", "-out", "-target", format.mime() })) |bytes| return bytes;
    };
    return null;
}

fn runClipboard(io: std.Io, environment: *const std.process.Environ.Map, argv: []const []const u8) !?[]u8 {
    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .environ_map = environment,
        .stdout_limit = .limited(max_bytes),
        .stderr_limit = .limited(8192),
    }) catch |err| switch (err) {
        error.FileNotFound, error.StreamTooLong => return null,
        else => return err,
    };
    defer allocator.free(result.stderr);
    if (result.term == .exited and result.term.exited == 0 and validImage(result.stdout)) return result.stdout;
    allocator.free(result.stdout);
    return null;
}

test "clipboard image refuses SSH sessions even with local display variables" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("WAYLAND_DISPLAY", "wayland-0");
    try environment.put("DISPLAY", ":0");
    for ([_][]const u8{ "SSH_CONNECTION", "SSH_CLIENT", "SSH_TTY" }) |name| {
        try environment.put(name, "set");
        try std.testing.expectEqual(null, try read(std.testing.io, &environment));
        _ = environment.swapRemove(name);
    }
}

test "Linux clipboard image returns null without a local display" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try std.testing.expectEqual(null, try read(std.testing.io, &environment));
}

// The clipboard process receives its own environment, and PATH lookup uses the Io's environment.
test "Linux clipboard image finds a supported local representation and preserves its bytes" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const testing = std.testing;
    var fixture = testing.tmpDir(.{});
    defer fixture.cleanup();
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = path[0..try fixture.dir.realPath(testing.io, &path)];
    var environment = std.process.Environ.Map.init(testing.allocator);
    defer environment.deinit();
    try environment.put("PATH", root);
    try environment.put("WAYLAND_DISPLAY", "wayland-fixture");
    try environment.put("DISPLAY", ":0");
    const block = try environment.createPosixBlock(testing.allocator, .{});
    defer block.deinit(testing.allocator);
    var threaded = std.Io.Threaded.init(testing.allocator, .{ .environ = .{ .block = block } });
    defer threaded.deinit();
    const io = threaded.io();

    const png = @embedFile("../codecs/fixtures/image-input/pixel.png");
    const jpeg = @embedFile("../testing/fixtures/input-baseline.jpg");
    const x11_png = @embedFile("../codecs/fixtures/image-input/pixel-multi-window.png");
    try fixture.dir.writeFile(io, .{ .sub_path = "image.png", .data = png });
    try fixture.dir.writeFile(io, .{ .sub_path = "image.jpg", .data = jpeg });
    try fixture.dir.writeFile(io, .{ .sub_path = "x11.png", .data = x11_png });
    try fixture.dir.writeFile(io, .{
        .sub_path = "wl-paste",
        .data =
        \\#!/bin/sh
        \\case "$FIXTURE_FORMAT:$*" in
        \\  png:--no-newline\ --type\ image/png) exec /bin/cat "$PATH/image.png" ;;
        \\  jpeg:--no-newline\ --type\ image/jpeg) exec /bin/cat "$PATH/image.jpg" ;;
        \\  *) exit 1 ;;
        \\esac
        ,
        .flags = .{ .permissions = .fromMode(0o700) },
    });
    try fixture.dir.writeFile(io, .{
        .sub_path = "xclip",
        .data =
        \\#!/bin/sh
        \\[ "$*" = '-selection clipboard -out -target image/png' ] || exit 1
        \\exec /bin/cat "$PATH/x11.png"
        ,
        .flags = .{ .permissions = .fromMode(0o700) },
    });

    for ([_]struct { format: []const u8, bytes: []const u8 }{
        .{ .format = "png", .bytes = png },
        .{ .format = "jpeg", .bytes = jpeg },
        .{ .format = "x11", .bytes = x11_png },
    }) |case| {
        try environment.put("FIXTURE_FORMAT", case.format);
        const bytes = (try read(io, &environment)) orelse return error.TestUnexpectedResult;
        defer allocator.free(bytes);
        try testing.expectEqualSlices(u8, case.bytes, bytes);
    }
    try fixture.dir.deleteFile(io, "wl-paste");
    try fixture.dir.deleteFile(io, "xclip");
    try testing.expectEqual(null, try read(io, &environment));
}
