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

/// Clipboards a Linux process can read, from its environment. Under WSL the Windows clipboard is the user's
/// clipboard: WSLg hands its images to Wayland only as BMP, and Windows Terminal keeps Ctrl+V for text.
const Sources = struct {
    windows: bool,
    wayland: bool,
    x11: bool,

    fn of(environment: *const std.process.Environ.Map) Sources {
        return .{
            .windows = environment.contains("WSL_INTEROP") or environment.contains("WSL_DISTRO_NAME"),
            .wayland = environment.contains("WAYLAND_DISPLAY"),
            .x11 = environment.contains("DISPLAY"),
        };
    }

    fn any(self: Sources) bool {
        return self.windows or self.wayland or self.x11;
    }

    /// A cold powershell.exe start from WSL takes over a second.
    fn deadline(self: Sources) std.Io.Duration {
        return .fromMilliseconds(if (self.windows) 5000 else 1000);
    }
};

/// Writes the Windows clipboard's image, or its one copied file, to stdout as raw bytes; the caller validates them.
const windows_clipboard_script =
    "Add-Type -AssemblyName System.Windows.Forms,System.Drawing;" ++
    "$o=[Console]::OpenStandardOutput();" ++
    "$i=[Windows.Forms.Clipboard]::GetImage();" ++
    "if($i){$m=[IO.MemoryStream]::new();$i.Save($m,[Drawing.Imaging.ImageFormat]::Png);$o.Write($m.ToArray(),0,$m.Length);$o.Flush();exit 0};" ++
    "$f=[Windows.Forms.Clipboard]::GetFileDropList();" ++
    "if($f.Count -eq 1){$b=[IO.File]::ReadAllBytes($f[0]);$o.Write($b,0,$b.Length);$o.Flush();exit 0};" ++
    "exit 1";
const windows_argv = [_][]const u8{ "powershell.exe", "-NoProfile", "-NonInteractive", "-STA", "-Command", windows_clipboard_script };

fn readLinux(io: std.Io, environment: *const std.process.Environ.Map) !?[]u8 {
    const sources = Sources.of(environment);
    if (!sources.any()) return null;

    const Result = union(enum) { read: anyerror!?[]u8, deadline: std.Io.Cancelable!void };
    var storage: [2]Result = undefined;
    var pending = std.Io.Select(Result).init(io, &storage);
    // The deadline covers both clipboard transfers and helper exit after EOF.
    defer while (pending.cancel()) |result| switch (result) {
        .read => |outcome| if (outcome catch null) |bytes| allocator.free(bytes),
        .deadline => {},
    };
    try pending.concurrent(.read, readLinuxSources, .{ io, environment, sources });
    try pending.concurrent(.deadline, std.Io.sleep, .{ io, sources.deadline(), .awake });
    return switch (try pending.await()) {
        .read => |outcome| outcome,
        .deadline => null,
    };
}

fn readLinuxSources(io: std.Io, environment: *const std.process.Environ.Map, sources: Sources) !?[]u8 {
    const formats: []const input_media.Format = &.{ .png, .jpeg };
    if (sources.windows) if (try runClipboard(io, environment, &windows_argv)) |bytes| return bytes;
    if (sources.wayland) for (formats) |format| {
        if (try runClipboard(io, environment, &.{ "wl-paste", "--no-newline", "--type", format.mime() })) |bytes| return bytes;
    };
    if (sources.x11) for (formats) |format| {
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

test "SUI-119 clipboard image reads the supported local clipboard" {
    {
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
    if (builtin.os.tag == .linux) {
        var environment = std.process.Environ.Map.init(std.testing.allocator);
        defer environment.deinit();
        try std.testing.expectEqual(null, try read(std.testing.io, &environment));
    }
    if (builtin.os.tag == .linux) {
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
}

test "SUI-119 clipboard image under WSL reads the Windows clipboard before the WSLg displays" {
    if (builtin.os.tag != .linux) return;
    const testing = std.testing;
    var fixture = testing.tmpDir(.{});
    defer fixture.cleanup();
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = path[0..try fixture.dir.realPath(testing.io, &path)];
    var environment = std.process.Environ.Map.init(testing.allocator);
    defer environment.deinit();
    try environment.put("PATH", root);
    const block = try environment.createPosixBlock(testing.allocator, .{});
    defer block.deinit(testing.allocator);
    var threaded = std.Io.Threaded.init(testing.allocator, .{ .environ = .{ .block = block } });
    defer threaded.deinit();
    const io = threaded.io();

    const png = @embedFile("../codecs/fixtures/image-input/pixel.png");
    const wayland_png = @embedFile("../codecs/fixtures/image-input/pixel-multi-window.png");
    try fixture.dir.writeFile(io, .{ .sub_path = "windows.png", .data = png });
    try fixture.dir.writeFile(io, .{ .sub_path = "wayland.png", .data = wayland_png });
    try fixture.dir.writeFile(io, .{
        .sub_path = "powershell.exe",
        .data =
        \\#!/bin/sh
        \\[ "$1 $2 $3 $4" = '-NoProfile -NonInteractive -STA -Command' ] || exit 2
        \\case "$5" in *GetImage*GetFileDropList*) ;; *) exit 2 ;; esac
        \\case "$FIXTURE_WINDOWS" in
        \\  image) exec /bin/cat "$PATH/windows.png" ;;
        \\  text) printf 'not an image' ;;
        \\esac
        \\exit 1
        ,
        .flags = .{ .permissions = .fromMode(0o700) },
    });
    try fixture.dir.writeFile(io, .{
        .sub_path = "wl-paste",
        .data =
        \\#!/bin/sh
        \\[ "$*" = '--no-newline --type image/png' ] || exit 1
        \\exec /bin/cat "$PATH/wayland.png"
        ,
        .flags = .{ .permissions = .fromMode(0o700) },
    });

    // Each WSL marker alone, with no display, reaches the Windows clipboard.
    try environment.put("FIXTURE_WINDOWS", "image");
    for ([_][]const u8{ "WSL_DISTRO_NAME", "WSL_INTEROP" }) |name| {
        try environment.put(name, "set");
        const bytes = (try read(io, &environment)) orelse return error.TestUnexpectedResult;
        defer allocator.free(bytes);
        try testing.expectEqualSlices(u8, png, bytes);
        _ = environment.swapRemove(name);
    }
    try testing.expectEqual(null, try read(io, &environment));

    // Under WSLg the Windows clipboard wins; an empty or non-image one falls back to the display.
    try environment.put("WSL_DISTRO_NAME", "Ubuntu");
    try environment.put("WAYLAND_DISPLAY", "wayland-0");
    for ([_]struct { windows: []const u8, bytes: []const u8 }{
        .{ .windows = "image", .bytes = png },
        .{ .windows = "text", .bytes = wayland_png },
        .{ .windows = "empty", .bytes = wayland_png },
    }) |case| {
        try environment.put("FIXTURE_WINDOWS", case.windows);
        const bytes = (try read(io, &environment)) orelse return error.TestUnexpectedResult;
        defer allocator.free(bytes);
        try testing.expectEqualSlices(u8, case.bytes, bytes);
    }
    // Without powershell.exe (interop off) only the display remains.
    try fixture.dir.deleteFile(io, "powershell.exe");
    try environment.put("FIXTURE_WINDOWS", "image");
    {
        const bytes = (try read(io, &environment)) orelse return error.TestUnexpectedResult;
        defer allocator.free(bytes);
        try testing.expectEqualSlices(u8, wayland_png, bytes);
    }
    try fixture.dir.deleteFile(io, "wl-paste");
    try testing.expectEqual(null, try read(io, &environment));
}
