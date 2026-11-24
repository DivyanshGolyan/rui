//! One private saved Host document reader. Callers supply the canonical Host
//! directory; selector policy, placement derivation and secret resolution live
//! with their own owners. Scratch and parsed JSON belong to the wiping caller.
const std = @import("std");
const hs = @import("host_settings.zig");
const start_report = @import("start_report.zig");
const private_file = @import("private_file.zig");
const core_tools = @import("core_tools.zig");
const wire_request = @import("wire_request.zig");

pub fn checkPreset(gpa: std.mem.Allocator, spec: std.json.ObjectMap) error{OutOfMemory}!?[]const u8 {
    const configuration = try gpa.create(wire_request.Configuration);
    defer {
        std.crypto.secureZero(u8, std.mem.asBytes(configuration));
        gpa.destroy(configuration);
    }
    configuration.* = .{};
    return switch (try core_tools.parseAgentSpec(gpa, spec, configuration)) {
        .accepted => null,
        .rejected => |reason| reason,
    };
}

pub fn read(io: std.Io, settings_gpa: std.mem.Allocator, scratch: std.mem.Allocator, host: []const u8, settings: *hs.Settings, checks: hs.Checks, failure: *start_report.Failure) !std.json.Value {
    const path = try std.fs.path.join(scratch, &.{ host, "host.json" });
    // Absence is not a private-file admission. Legacy or not-yet-created Host
    // directories need no settings permissions until a document exists.
    _ = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return .{ .object = .{} },
        else => return unreadable(failure),
    };
    const buffer = try scratch.alloc(u8, hs.max_document_bytes + 1);
    defer {
        std.crypto.secureZero(u8, buffer);
        scratch.free(buffer);
    }
    const bytes = private_file.read(io, path, buffer) catch return unreadable(failure);
    if (bytes) |document| {
        try hs.apply(settings, settings_gpa, document, .file, checks, failure);
        return std.json.parseFromSliceLeaky(std.json.Value, scratch, document, .{ .allocate = .alloc_always, .parse_numbers = false }) catch |err| {
            if (err == error.OutOfMemory) return err;
            failure.* = .init(.settings_invalid, "settings: must be a JSON document");
            return error.SettingsInvalid;
        };
    }
    return .{ .object = .{} };
}

fn unreadable(failure: *start_report.Failure) error{SettingsInvalid} {
    failure.* = .init(.settings_invalid, "settings: host.json must be a readable private file within the document byte bound");
    return error.SettingsInvalid;
}
