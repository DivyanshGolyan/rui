const std = @import("std");
const c = @cImport({
    @cInclude("sys/stat.h");
    @cInclude("unistd.h");
});
const platform = @import("platform.zig");
const protocol = @import("protocol.zig");
const provider_selection = @import("provider_selection.zig");

const io = std.Io.Threaded.global_single_threaded.io();
const max_file_bytes = 1024;

/// Values own their bytes; callers may retain this value after closing the file.
pub const Values = struct {
    store: protocol.Bounded(protocol.max_store_bytes) = .{},
    provider: protocol.Bounded(16) = .{},
    model: protocol.Bounded(protocol.max_model_bytes) = .{},
};

pub fn directoryPath(home: []const u8, buffer: []u8) ![]const u8 {
    try validateHome(home);
    return std.fmt.bufPrint(buffer, "{s}/.config/rui", .{home}) catch error.PreferencePathTooLong;
}

pub fn defaultStore(home: []const u8, buffer: []u8) ![]const u8 {
    try validateHome(home);
    return std.fmt.bufPrint(buffer, "{s}/.local/share/rui/store", .{home}) catch error.PreferencePathTooLong;
}

fn validateHome(home: []const u8) !void {
    if (!std.fs.path.isAbsolute(home) or !std.unicode.utf8ValidateSlice(home)) return error.InvalidHome;
    for (home) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidHome;
}

/// File syntax and Store custody are valid independently of current provider support.
pub fn validate(values: *const Values) !void {
    if (values.store.len != 0) {
        if (!std.fs.path.isAbsolute(values.store.slice())) return error.InvalidPreferenceStore;
        for (values.store.slice()) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidPreferenceStore;
        _ = try platform.resolveClientPaths(io, values.store.slice());
    }
    for (values.provider.slice()) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return error.InvalidPreferenceProvider;
    }
    for (values.model.slice()) |byte| {
        if (byte < 0x21 or byte > 0x7e) return error.InvalidPreferenceModel;
    }
    if (values.model.len != 0 and values.provider.len == 0) return error.PreferenceProviderRequired;
}

fn read(dir: std.Io.Dir) !Values {
    const file = openPreferenceFile(dir, "preferences") catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer file.close(io);
    try privateFile(file);
    const stat = try file.stat(io);
    if (stat.size > max_file_bytes) return error.InvalidPreferences;
    var bytes: [max_file_bytes + 1]u8 = undefined;
    const count = try file.readPositionalAll(io, bytes[0..@intCast(stat.size + 1)], 0);
    if (count != stat.size) return error.InvalidPreferences;
    var lines = std.mem.splitScalar(u8, bytes[0..count], '\n');
    if (!std.mem.eql(u8, lines.next() orelse "", "version=1")) return error.UnsupportedPreferencesVersion;
    var result: Values = .{};
    const fields = .{ .{ "store=", &result.store }, .{ "provider=", &result.provider }, .{ "model=", &result.model } };
    inline for (fields) |field| {
        const line = lines.next() orelse return error.InvalidPreferences;
        if (!std.mem.startsWith(u8, line, field[0])) return error.InvalidPreferences;
        field[1].set(line[field[0].len..]) catch return error.InvalidPreferences;
    }
    if (!std.mem.eql(u8, lines.next() orelse return error.InvalidPreferences, "") or lines.next() != null)
        return error.InvalidPreferences;
    return result;
}

pub fn load(home: []const u8) !Values {
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory = try directoryPath(home, &path);
    var dir = openPrivateDirectory(directory) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer dir.close(io);
    const values = try read(dir);
    try validate(&values);
    return values;
}

/// Serializes read/modify/write for competing setup callers. A failed write or
/// rename leaves the previous complete file; post-rename sync failure is uncertain.
pub fn update(home: []const u8, store: ?[]const u8, provider: ?[]const u8, model: ?[]const u8) !Values {
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    _ = try directoryPath(home, &path);
    if (provider) |value| {
        if (!std.mem.eql(u8, value, "codex")) return error.UnsupportedPreferenceProvider;
    }
    if (model) |value| {
        if (value.len == 0 or value.len > protocol.max_model_bytes) return error.InvalidPreferenceModel;
        for (value) |byte| if (byte < 0x21 or byte > 0x7e) return error.InvalidPreferenceModel;
        const supported = provider_selection.codex(.missing);
        _ = provider_selection.resolve(&.{supported}, "codex", value, null, null) catch
            return error.UnsupportedPreferenceModel;
    }
    if (store) |value| {
        if (!std.fs.path.isAbsolute(value)) return error.InvalidPreferenceStore;
        for (value) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidPreferenceStore;
        _ = try platform.resolveClientPaths(io, value);
    }
    var home_dir = try std.Io.Dir.openDirAbsolute(io, home, .{ .iterate = true });
    defer home_dir.close(io);
    home_dir.createDir(io, ".config", .fromMode(0o700)) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var config_dir = try home_dir.openDir(io, ".config", .{ .iterate = true });
    defer config_dir.close(io);
    config_dir.createDir(io, "rui", .fromMode(0o700)) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var dir = try config_dir.openDir(io, "rui", .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(io);
    try privateDirectory(dir);
    // Also persist the parent entries: syncing rui alone cannot make newly
    // created .config/rui survive power loss. Sync both even when another
    // setup caller created them but has not yet synced its parent.
    if (std.c.fsync(home_dir.handle) != 0 or std.c.fsync(config_dir.handle) != 0)
        return error.PreferenceDirectorySyncFailed;
    const lock = while (true) {
        break dir.openFile(io, ".preferences.lock", .{ .mode = .read_write, .follow_symlinks = false, .lock = .exclusive }) catch |err| switch (err) {
            error.FileNotFound => dir.createFile(io, ".preferences.lock", .{ .read = true, .exclusive = true, .lock = .exclusive, .permissions = .fromMode(0o600) }) catch |create_err| switch (create_err) {
                error.PathAlreadyExists => continue,
                else => return create_err,
            },
            else => return err,
        };
    };
    defer lock.close(io);
    try privateFile(lock);
    var values = try read(dir);
    if (store) |value| {
        const paths = try platform.resolveClientPaths(io, value);
        values.store.set(paths.store.slice()) catch return error.InvalidPreferenceStore;
    }
    if (provider) |value| values.provider.set(value) catch return error.UnsupportedPreferenceProvider;
    if (model) |value| values.model.set(value) catch return error.InvalidPreferenceModel;
    try validate(&values);
    // A provider/model-only edit must not publish defaults whose fallback
    // Store cannot be selected by the very next setup or Session caller.
    if (values.store.len == 0) _ = try defaultStore(home, &path);
    if (values.provider.len != 0) {
        const supported = provider_selection.codex(.missing);
        _ = provider_selection.resolve(&.{supported}, null, null, values.provider.slice(), if (values.model.len != 0) values.model.slice() else null) catch |err| switch (err) {
            error.UnsupportedSelectionProvider => return error.UnsupportedPreferenceProvider,
            error.UnsupportedSelectionModel => return error.UnsupportedPreferenceModel,
        };
    }

    if (openPreferenceFile(dir, "preferences.tmp")) |stale| {
        defer stale.close(io);
        try privateFile(stale);
        try dir.deleteFile(io, "preferences.tmp");
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    const file = try dir.createFile(io, "preferences.tmp", .{ .read = true, .exclusive = true, .permissions = .fromMode(0o600) });
    var open = true;
    var published = false;
    defer {
        if (open) file.close(io);
        if (!published) dir.deleteFile(io, "preferences.tmp") catch {};
    }
    var bytes: [max_file_bytes]u8 = undefined;
    const encoded = std.fmt.bufPrint(&bytes, "version=1\nstore={s}\nprovider={s}\nmodel={s}\n", .{ values.store.slice(), values.provider.slice(), values.model.slice() }) catch return error.InvalidPreferences;
    try file.writeStreamingAll(io, encoded);
    try file.sync(io);
    file.close(io);
    open = false;
    try dir.rename("preferences.tmp", dir, "preferences", io);
    published = true;
    if (std.c.fsync(dir.handle) != 0) return error.PreferenceDirectorySyncFailed;
    return values;
}

fn openPreferenceFile(dir: std.Io.Dir, name: []const u8) !std.Io.File {
    // A private path may be a FIFO. O_NONBLOCK lets privateFile reject it
    // rather than waiting indefinitely for a writer.
    return .{ .handle = try std.posix.openat(dir.handle, name, .{
        .ACCMODE = .RDONLY,
        .NONBLOCK = true,
        .NOFOLLOW = true,
        .CLOEXEC = true,
    }, 0), .flags = .{ .nonblocking = true } };
}

fn openPrivateDirectory(path: []const u8) !std.Io.Dir {
    var dir = try std.Io.Dir.openDirAbsolute(io, path, .{ .follow_symlinks = false });
    errdefer dir.close(io);
    try privateDirectory(dir);
    return dir;
}

fn privateDirectory(dir: std.Io.Dir) !void {
    const stat = try dir.stat(io);
    if (stat.kind != .directory or stat.permissions.toMode() & 0o077 != 0) return error.InsecurePreferenceDirectory;
    try validateOwner(dir.handle);
}

fn privateFile(file: std.Io.File) !void {
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.permissions.toMode() & 0o077 != 0) return error.InsecurePreferenceFile;
    try validateOwner(file.handle);
}

fn validateOwner(handle: anytype) !void {
    var stat: c.struct_stat = undefined;
    if (c.fstat(handle, &stat) != 0) return error.PreferenceStatFailed;
    if (stat.st_uid != c.geteuid()) return error.UnownedPreferences;
}
