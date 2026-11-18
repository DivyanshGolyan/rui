//! A private, source-only detached admission. Public source argv is provenance;
//! only this checked frame is authoritative for the child being launched.
const std = @import("std");
const hs = @import("host_settings.zig");
const protocol = @import("protocol.zig");
const start_report = @import("start_report.zig");
const secret_value = @import("secret_value.zig");
pub const ProviderIntent = enum(u8) { automatic = 0, explicit = 1 };
pub const input_option = "settings-handoff-input-v2";
pub const check_option = "settings-handoff-check-v2";
pub const child_descriptor = 5;
const magic = "rui-host-settings-v2\n";
pub const prefix_bytes = magic.len + 1 + 2 + 4 + 8;
pub const max_bytes = prefix_bytes + hs.MysqlDestination.encoded_max + protocol.max_store_bytes + hs.max_composed_document_bytes;

pub const Binding = union(enum) { none, mysql: hs.MysqlDestination };
pub const View = struct { directory: []const u8, intent: ProviderIntent, binding: Binding, document: []const u8 };
pub const Decoded = struct { intent: ProviderIntent, binding: Binding };
pub const Owned = struct {
    bytes: []u8,
    pub fn deinit(self: *Owned, gpa: std.mem.Allocator) void {
        secret_value.wipeAndFree(gpa, self.bytes, .of(u8), @returnAddress());
        self.* = undefined;
    }
};

/// Opaque custody admission for the coordinator; schema decoding stays target-local.
pub fn accept(bytes: []const u8) error{SettingsInvalid}!void {
    _ = try inspect(bytes);
}

pub fn inspect(bytes: []const u8) error{SettingsInvalid}!View {
    if (bytes.len < prefix_bytes or bytes.len > max_bytes or !std.mem.eql(u8, bytes[0..magic.len], magic)) return error.SettingsInvalid;
    const intent = std.enums.fromInt(ProviderIntent, bytes[magic.len]) orelse return error.SettingsInvalid;
    const binding_len = std.mem.readInt(u16, bytes[magic.len + 1 ..][0..2], .little);
    const directory_len = std.mem.readInt(u32, bytes[magic.len + 3 ..][0..4], .little);
    const document_len = std.mem.readInt(u64, bytes[magic.len + 7 ..][0..8], .little);
    if (binding_len > hs.MysqlDestination.encoded_max or directory_len == 0 or directory_len > protocol.max_store_bytes or document_len > hs.max_composed_document_bytes) return error.SettingsInvalid;
    if (prefix_bytes + @as(u64, binding_len) + directory_len + document_len != bytes.len) return error.SettingsInvalid;
    const binding: Binding = if (binding_len == 0) .none else .{ .mysql = hs.MysqlDestination.read(bytes[prefix_bytes..][0..binding_len]) catch return error.SettingsInvalid };
    const directory_start = prefix_bytes + binding_len;
    const directory = bytes[directory_start..][0..directory_len];
    if (!std.fs.path.isAbsolute(directory) or std.mem.indexOfScalar(u8, directory, 0) != null) return error.SettingsInvalid;
    return .{ .directory = directory, .intent = intent, .binding = binding, .document = bytes[directory_start + directory_len ..] };
}

/// Count before allocating/launching. The schema owner proves this cannot
/// export resolved credentials or a parsed MySQL value; write is NOT an export.
pub fn freeze(gpa: std.mem.Allocator, directory: []const u8, settings: *const hs.Settings, intent: ProviderIntent, binding: Binding, failure: *start_report.Failure) !Owned {
    if ((settings.store == .mysql) != (binding == .mysql)) return invalid(failure, "missing, malformed or unsupported private settings handoff");
    if (!hs.unresolved(settings)) return invalid(failure, "private launch requires unresolved secret sources and no parsed MySQL value");
    if (directory.len == 0 or directory.len > protocol.max_store_bytes or !std.fs.path.isAbsolute(directory) or std.mem.indexOfScalar(u8, directory, 0) != null) return invalid(failure, "private launch requires a canonical Host directory");
    var counter: std.Io.Writer.Discarding = .init(&.{});
    hs.write(settings, &counter.writer) catch return invalid(failure, "cannot count private launch settings");
    const document_len = counter.fullCount();
    if (document_len > hs.max_composed_document_bytes) return invalid(failure, "composed launch settings exceed the private frame byte bound");
    var binding_buffer: [hs.MysqlDestination.encoded_max]u8 = undefined;
    var binding_writer: std.Io.Writer = .fixed(&binding_buffer);
    if (binding == .mysql) try binding.mysql.write(&binding_writer);
    const binding_len = binding_writer.end;
    const bytes = try gpa.alloc(u8, prefix_bytes + binding_len + directory.len + @as(usize, @intCast(document_len)));
    errdefer secret_value.wipeAndFree(gpa, bytes, .of(u8), @returnAddress());
    @memcpy(bytes[0..magic.len], magic);
    bytes[magic.len] = @backingInt(intent);
    std.mem.writeInt(u16, bytes[magic.len + 1 ..][0..2], @intCast(binding_len), .little);
    std.mem.writeInt(u32, bytes[magic.len + 3 ..][0..4], @intCast(directory.len), .little);
    std.mem.writeInt(u64, bytes[magic.len + 7 ..][0..8], document_len, .little);
    @memcpy(bytes[prefix_bytes..][0..binding_len], binding_writer.buffered());
    @memcpy(bytes[prefix_bytes + binding_len ..][0..directory.len], directory);
    var out: std.Io.Writer = .fixed(bytes[prefix_bytes + binding_len + directory.len ..]);
    hs.write(settings, &out) catch return invalid(failure, "composed launch settings changed while freezing");
    if (out.end != document_len) return invalid(failure, "composed launch settings changed while freezing");
    return .{ .bytes = bytes };
}

pub fn decode(bytes: []const u8, selected: []const u8, settings: *hs.Settings, gpa: std.mem.Allocator, check: hs.PresetCheck, failure: *start_report.Failure) !Decoded {
    const view = inspect(bytes) catch return invalid(failure, "missing, malformed or unsupported private settings handoff");
    if (!std.mem.eql(u8, view.directory, selected)) return invalid(failure, "private settings handoff names another Host directory");
    const scratch = try gpa.create(hs.Settings);
    defer gpa.destroy(scratch);
    scratch.* = .{};
    defer scratch.deinit();
    hs.applyComposed(scratch, gpa, view.document, check, failure) catch |err| {
        if (err == error.OutOfMemory) return err;
        return invalid(failure, "missing, malformed or unsupported private settings handoff");
    };
    if ((scratch.store == .mysql) != (view.binding == .mysql) or !hs.unresolved(scratch)) return invalid(failure, "missing, malformed or unsupported private settings handoff");
    try hs.applyComposed(settings, gpa, view.document, check, failure);
    if (!hs.unresolved(settings)) return invalid(failure, "private settings handoff must contain source descriptions only");
    return .{ .intent = view.intent, .binding = view.binding };
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
        var owned = try freeze(gpa, "/host-\xff", a, intent, .none, &failure);
        defer owned.deinit(gpa);
        b.* = .{};
        defer b.deinit();
        try std.testing.expectEqual(intent, (try decode(owned.bytes, "/host-\xff", b, gpa, struct {
            fn check(_: std.mem.Allocator, _: std.json.ObjectMap) error{OutOfMemory}!?[]const u8 {
                return null;
            }
        }.check, &failure)).intent);
        try std.testing.expectError(error.SettingsInvalid, decode(owned.bytes, "/other", b, gpa, struct {
            fn check(_: std.mem.Allocator, _: std.json.ObjectMap) error{OutOfMemory}!?[]const u8 {
                return null;
            }
        }.check, &failure));
        try std.testing.expectError(error.SettingsInvalid, inspect(owned.bytes[0 .. owned.bytes.len - 1]));
        // Reject an over-bound declared composition without allocating or
        // beginning any launch. This bound belongs to the frame, not a layer.
        const length_bytes = owned.bytes[magic.len + 7 ..][0..8];
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

test "private settings v2 binds only the selected engine before caller mutation" {
    const gpa = std.testing.allocator;
    const check = struct {
        fn call(_: std.mem.Allocator, _: std.json.ObjectMap) error{OutOfMemory}!?[]const u8 { return null; }
    }.call;
    const mysql_value = @import("mysql_url_value.zig");
    var value: mysql_value.ValueWith(hs.max_path_bytes) = .{};
    defer value.wipe();
    try value.parse("mysql://user:password@host/db");
    const binding: Binding = .{ .mysql = hs.MysqlDestination.of(&value) };
    try std.testing.expectEqual(prefix_bytes + hs.MysqlDestination.encoded_max + protocol.max_store_bytes + hs.max_composed_document_bytes, max_bytes);
    const settings = try gpa.create(hs.Settings);
    defer gpa.destroy(settings);
    const output = try gpa.create(hs.Settings);
    defer gpa.destroy(output);
    var failure: start_report.Failure = undefined;
    for ([_]bool{ false, true }) |mysql| {
        for ([_]bool{ false, true }) |bound| {
            settings.* = .{};
            defer settings.deinit();
            if (mysql) settings.store = .{ .mysql = .{} };
            const selected: Binding = if (bound) binding else .none;
            if (mysql != bound) {
                try std.testing.expectError(error.SettingsInvalid, freeze(gpa, "/host", settings, .automatic, selected, &failure));
                continue;
            }
            var frame = try freeze(gpa, "/host", settings, .automatic, selected, &failure);
            defer frame.deinit(gpa);
            output.* = .{};
            defer output.deinit();
            const decoded = try decode(frame.bytes, "/host", output, gpa, check, &failure);
            try std.testing.expectEqual(bound, decoded.binding == .mysql);
            try std.testing.expectEqual(mysql, output.store == .mysql);
            frame.bytes[magic.len - 2] = '1';
            try std.testing.expectError(error.SettingsInvalid, decode(frame.bytes, "/host", output, gpa, check, &failure));
            try std.testing.expectEqualStrings("missing, malformed or unsupported private settings handoff", failure.message.slice());
        }
    }
}

test "private settings v2 rejects forged engine bindings and malformed lengths without caller effects" {
    const gpa = std.testing.allocator;
    const check = struct {
        fn call(_: std.mem.Allocator, _: std.json.ObjectMap) error{OutOfMemory}!?[]const u8 { return null; }
    }.call;
    const mysql_value = @import("mysql_url_value.zig");
    var value: mysql_value.ValueWith(hs.max_path_bytes) = .{};
    defer value.wipe();
    try value.parse("mysql://user:password@host/db");
    const binding: Binding = .{ .mysql = hs.MysqlDestination.of(&value) };
    const source = try gpa.create(hs.Settings);
    defer gpa.destroy(source);
    source.* = .{};
    defer source.deinit();
    const target = try gpa.create(hs.Settings);
    defer gpa.destroy(target);
    var failure: start_report.Failure = undefined;
    var sqlite = try freeze(gpa, "/host", source, .automatic, .none, &failure);
    defer sqlite.deinit(gpa);
    source.store = .{ .mysql = .{} };
    var mysql = try freeze(gpa, "/host", source, .automatic, binding, &failure);
    defer mysql.deinit(gpa);
    const mysql_len = std.mem.readInt(u16, mysql.bytes[magic.len + 1 ..][0..2], .little);
    const forged_missing = try gpa.alloc(u8, mysql.bytes.len - mysql_len);
    defer gpa.free(forged_missing);
    @memcpy(forged_missing[0..prefix_bytes], mysql.bytes[0..prefix_bytes]);
    std.mem.writeInt(u16, forged_missing[magic.len + 1 ..][0..2], 0, .little);
    @memcpy(forged_missing[prefix_bytes..], mysql.bytes[prefix_bytes + mysql_len ..]);
    const forged_wrong = try gpa.alloc(u8, sqlite.bytes.len + mysql_len);
    defer gpa.free(forged_wrong);
    @memcpy(forged_wrong[0..prefix_bytes], sqlite.bytes[0..prefix_bytes]);
    std.mem.writeInt(u16, forged_wrong[magic.len + 1 ..][0..2], mysql_len, .little);
    @memcpy(forged_wrong[prefix_bytes..][0..mysql_len], mysql.bytes[prefix_bytes..][0..mysql_len]);
    @memcpy(forged_wrong[prefix_bytes + mysql_len ..], sqlite.bytes[prefix_bytes..]);
    const oversized = try gpa.alloc(u8, max_bytes + 1);
    defer gpa.free(oversized);
    @memset(oversized, 0);
    for ([_][]const u8{ forged_missing, forged_wrong, mysql.bytes[0 .. mysql.bytes.len - 1], oversized }) |frame| {
        target.* = .{};
        defer target.deinit();
        try std.testing.expectError(error.SettingsInvalid, decode(frame, "/host", target, gpa, check, &failure));
        try std.testing.expectEqualStrings("missing, malformed or unsupported private settings handoff", failure.message.slice());
        try std.testing.expect(target.store == .sqlite);
    }
}
