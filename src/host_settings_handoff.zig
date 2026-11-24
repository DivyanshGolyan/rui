//! A private, source-only detached admission. Public source argv is provenance;
//! only this checked frame is authoritative for the child being launched.
const std = @import("std");
const hs = @import("host_settings.zig");
const protocol = @import("protocol.zig");
const start_report = @import("start_report.zig");
const secret_value = @import("secret_value.zig");
pub const ProviderIntent = enum(u8) { automatic = 0, explicit = 1 };
pub const input_option = "settings-handoff-input-v1";
pub const check_option = "settings-handoff-check-v1";
pub const child_descriptor = 5;
const magic = "rui-host-settings-v1\n";
const prefix_bytes = magic.len + 1 + 4 + 8;
pub const max_bytes = prefix_bytes + protocol.max_store_bytes + hs.max_composed_document_bytes;

pub const View = struct { directory: []const u8, intent: ProviderIntent, document: []const u8 };
pub const Owned = struct {
    bytes: []u8,
    pub fn deinit(self: *Owned, gpa: std.mem.Allocator) void {
        secret_value.wipeAndFree(gpa, self.bytes, .of(u8), @returnAddress());
        self.* = undefined;
    }
};

/// A Host's `settings_digest`: the SHA-256 of the whole frozen frame. The wire spells it in lowercase hex.
pub const Digest = [std.crypto.hash.sha2.Sha256.digest_length]u8;

/// The digest a Host with these frozen bytes reports. Equal frames, which
/// `freeze` makes deterministic, have equal digests.
pub fn digest(bytes: []const u8) Digest {
    var hash: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return hash;
}

/// Opaque custody admission for the coordinator; schema decoding stays target-local.
pub fn accept(bytes: []const u8) error{SettingsInvalid}!void {
    _ = try inspect(bytes);
}

pub fn inspect(bytes: []const u8) error{SettingsInvalid}!View {
    if (bytes.len < prefix_bytes or bytes.len > max_bytes or !std.mem.eql(u8, bytes[0..magic.len], magic)) return error.SettingsInvalid;
    const intent = std.enums.fromInt(ProviderIntent, bytes[magic.len]) orelse return error.SettingsInvalid;
    const directory_len = std.mem.readInt(u32, bytes[magic.len + 1 ..][0..4], .little);
    const document_len = std.mem.readInt(u64, bytes[magic.len + 5 ..][0..8], .little);
    if (directory_len == 0 or directory_len > protocol.max_store_bytes or document_len > hs.max_composed_document_bytes) return error.SettingsInvalid;
    if (prefix_bytes + @as(u64, directory_len) + document_len != bytes.len) return error.SettingsInvalid;
    const directory = bytes[prefix_bytes..][0..directory_len];
    if (!std.fs.path.isAbsolute(directory) or std.mem.indexOfScalar(u8, directory, 0) != null) return error.SettingsInvalid;
    return .{ .directory = directory, .intent = intent, .document = bytes[prefix_bytes + directory_len ..] };
}

/// Count before allocating/launching. The schema owner proves this cannot
/// export resolved credentials or a parsed MySQL value; write is NOT an export.
pub fn freeze(gpa: std.mem.Allocator, directory: []const u8, settings: *const hs.Settings, intent: ProviderIntent, failure: *start_report.Failure) !Owned {
    if (!hs.unresolved(settings)) return invalid(failure, "private launch requires unresolved secret sources and no parsed MySQL value");
    if (directory.len == 0 or directory.len > protocol.max_store_bytes or !std.fs.path.isAbsolute(directory) or std.mem.indexOfScalar(u8, directory, 0) != null) return invalid(failure, "private launch requires a canonical Host directory");
    var counter: std.Io.Writer.Discarding = .init(&.{});
    hs.write(settings, &counter.writer) catch return invalid(failure, "cannot count private launch settings");
    const document_len = counter.fullCount();
    if (document_len > hs.max_composed_document_bytes) return invalid(failure, "composed launch settings exceed the private frame byte bound");
    const bytes = try gpa.alloc(u8, prefix_bytes + directory.len + @as(usize, @intCast(document_len)));
    errdefer secret_value.wipeAndFree(gpa, bytes, .of(u8), @returnAddress());
    @memcpy(bytes[0..magic.len], magic);
    bytes[magic.len] = @backingInt(intent);
    std.mem.writeInt(u32, bytes[magic.len + 1 ..][0..4], @intCast(directory.len), .little);
    std.mem.writeInt(u64, bytes[magic.len + 5 ..][0..8], document_len, .little);
    @memcpy(bytes[prefix_bytes..][0..directory.len], directory);
    var out: std.Io.Writer = .fixed(bytes[prefix_bytes + directory.len ..]);
    hs.write(settings, &out) catch return invalid(failure, "composed launch settings changed while freezing");
    if (out.end != document_len) return invalid(failure, "composed launch settings changed while freezing");
    return .{ .bytes = bytes };
}

pub fn decode(bytes: []const u8, selected: []const u8, settings: *hs.Settings, gpa: std.mem.Allocator, checks: hs.Checks, failure: *start_report.Failure) !ProviderIntent {
    const view = inspect(bytes) catch return invalid(failure, "missing, malformed or unsupported private settings handoff");
    if (!std.mem.eql(u8, view.directory, selected)) return invalid(failure, "private settings handoff names another Host directory");
    try hs.applyComposed(settings, gpa, view.document, checks, failure);
    if (!hs.unresolved(settings)) return invalid(failure, "private settings handoff must contain source descriptions only");
    return view.intent;
}

fn invalid(failure: *start_report.Failure, message: []const u8) error{SettingsInvalid} {
    failure.* = .init(.settings_invalid, message);
    return error.SettingsInvalid;
}

test "frozen settings handoff preserves OS-byte selector intent and file-origin schema without public sources" {
    const gpa = std.testing.allocator;
    const a = try gpa.create(hs.Settings);
    defer gpa.destroy(a);
    a.* = .{};
    defer a.deinit();
    const b = try gpa.create(hs.Settings);
    defer gpa.destroy(b);
    var failure: start_report.Failure = undefined;
    for (std.enums.values(ProviderIntent)) |intent| {
        var owned = try freeze(gpa, "/host-\xff", a, intent, &failure);
        defer owned.deinit(gpa);
        b.* = .{};
        defer b.deinit();
        const no_checks: hs.Checks = .{ .preset = struct {
            fn check(_: std.mem.Allocator, _: std.json.ObjectMap) error{OutOfMemory}!?[]const u8 {
                return null;
            }
        }.check, .host_field = struct {
            fn none(_: []const u8) bool {
                return false;
            }
        }.none };
        try std.testing.expectEqual(intent, try decode(owned.bytes, "/host-\xff", b, gpa, no_checks, &failure));
        try std.testing.expectError(error.SettingsInvalid, decode(owned.bytes, "/other", b, gpa, no_checks, &failure));
        try std.testing.expectError(error.SettingsInvalid, inspect(owned.bytes[0 .. owned.bytes.len - 1]));
        // Reject an over-bound declared composition without allocating or
        // beginning any launch. This bound belongs to the frame, not a layer.
        const length_bytes = owned.bytes[magic.len + 5 ..][0..8];
        const length = std.mem.readInt(u64, length_bytes, .little);
        std.mem.writeInt(u64, length_bytes, hs.max_composed_document_bytes + 1, .little);
        try std.testing.expectError(error.SettingsInvalid, inspect(owned.bytes));
        std.mem.writeInt(u64, length_bytes, length, .little);
        const tag = owned.bytes[0];
        owned.bytes[0] = '!';
        try std.testing.expectError(error.SettingsInvalid, inspect(owned.bytes));
        owned.bytes[0] = tag;
        owned.bytes[magic.len] = 255;
        try std.testing.expectError(error.SettingsInvalid, inspect(owned.bytes));
    }
}

test "settings digest is the SHA-256 of the frame and follows its settings" {
    const gpa = std.testing.allocator;
    const settings = try gpa.create(hs.Settings);
    defer gpa.destroy(settings);
    settings.* = .{};
    defer settings.deinit();
    var failure: start_report.Failure = undefined;
    var first = try freeze(gpa, "/host", settings, .automatic, &failure);
    defer first.deinit(gpa);
    var second = try freeze(gpa, "/host", settings, .automatic, &failure);
    defer second.deinit(gpa);
    const before = digest(first.bytes);
    try std.testing.expectEqualSlices(u8, &before, &digest(second.bytes));
    var expected: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(first.bytes, &expected, .{});
    try std.testing.expectEqualSlices(u8, &expected, &before);

    settings.execution.background_after_ms.value += 1;
    var changed = try freeze(gpa, "/host", settings, .automatic, &failure);
    defer changed.deinit(gpa);
    try std.testing.expect(!std.mem.eql(u8, &before, &digest(changed.bytes)));
}
