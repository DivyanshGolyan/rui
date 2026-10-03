const std = @import("std");
const c = @cImport({
    @cInclude("sys/stat.h");
    @cInclude("unistd.h");
});
const platform = @import("platform.zig");
const protocol = @import("protocol.zig");
const provider_selection = @import("provider_selection.zig");
const model_adapter = @import("model_adapter.zig");

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

/// Safe fields only: availability belongs to the caller selecting a resource.
pub fn validate(values: *const Values) !void {
    if (values.store.len != 0) {
        if (!std.fs.path.isAbsolute(values.store.slice()) or !std.unicode.utf8ValidateSlice(values.store.slice())) return error.InvalidPreferenceStore;
        for (values.store.slice()) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidPreferenceStore;
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

pub const Edit = struct {
    store: ?[]const u8 = null,
    provider: ?[]const u8 = null,
    model: union(enum) { keep, set: []const u8, clear } = .keep,
};

/// Apply choices, never resolved recommendations. Strings are copied into values.
fn apply(saved: Values, edit: Edit, readiness: provider_selection.Readiness) !Values {
    var values = saved;
    if (edit.provider) |name| {
        if (!std.mem.eql(u8, name, model_adapter.provider_label)) return error.UnsupportedPreferenceProvider;
        if (!saved.provider.eql(name)) values.model = .{};
        try values.provider.set(name);
    }
    switch (edit.model) {
        .keep => {},
        .clear => values.model = .{},
        .set => |model| {
            if (!model_adapter.validModel(model)) return error.InvalidPreferenceModel;
            const choice = provider_selection.resolve(&.{model_adapter.capability(readiness)}, null, model, if (values.provider.len != 0) values.provider.slice() else null, null) catch
                return error.UnsupportedPreferenceProvider;
            if (choice == .chooser) return error.PreferenceProviderRequired;
            try values.provider.set(choice.selected.provider);
            try values.model.set(model);
        },
    }
    return values;
}

/// Serializes read/modify/write for competing setup callers. A failed write or
/// rename leaves the previous complete file; post-rename sync failure is uncertain.
pub fn update(home: []const u8, edit: Edit, readiness: provider_selection.Readiness) !Values {
    return (try save(home, edit, readiness, false)).?;
}

/// Under the same preference lock as setup, keep an existing provider choice.
/// Null means no change was published; credentials are owned separately.
pub fn fillProviderAfterLogin(home: []const u8) !bool {
    return (try save(home, .{ .provider = model_adapter.provider_label }, .configured, true)) != null;
}

fn save(home: []const u8, edit: Edit, readiness: provider_selection.Readiness, only_if_unset: bool) !?Values {
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    _ = try directoryPath(home, &path);
    if (edit.store) |value| {
        if (!std.fs.path.isAbsolute(value)) return error.InvalidPreferenceStore;
        for (value) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidPreferenceStore;
        _ = try platform.resolveClientPaths(io, value);
    }
    var dir = blk: {
        var home_dir = try std.Io.Dir.openDirAbsolute(io, home, .{ .iterate = true });
        defer home_dir.close(io);
        const created_config = if (home_dir.createDir(io, ".config", .fromMode(0o700))) |_| true else |err| switch (err) {
            error.PathAlreadyExists => false,
            else => return err,
        };
        // Creation modes are masked by the caller's umask. Repair only the
        // inode we created; an existing directory is not ours to chmod.
        if (created_config and std.c.fchmodat(home_dir.handle, ".config", 0o700, std.c.AT.SYMLINK_NOFOLLOW) != 0)
            return error.PreferencePermissionsFailed;
        var config_dir = try home_dir.openDir(io, ".config", .{ .iterate = true });
        defer config_dir.close(io);
        const created_rui = if (config_dir.createDir(io, "rui", .fromMode(0o700))) |_| true else |err| switch (err) {
            error.PathAlreadyExists => false,
            else => return err,
        };
        if (created_rui and std.c.fchmodat(config_dir.handle, "rui", 0o700, std.c.AT.SYMLINK_NOFOLLOW) != 0)
            return error.PreferencePermissionsFailed;
        const opened = try config_dir.openDir(io, "rui", .{ .iterate = true, .follow_symlinks = false });
        errdefer opened.close(io);
        try privateDirectory(opened);
        // Sync parent entries even when another caller created them but has
        // not synced yet. Parent handles are not needed during publication.
        if (std.c.fsync(home_dir.handle) != 0 or std.c.fsync(config_dir.handle) != 0)
            return error.PreferenceDirectorySyncFailed;
        break :blk opened;
    };
    defer dir.close(io);
    const lock = while (true) {
        break dir.openFile(io, ".preferences.lock", .{ .mode = .read_write, .follow_symlinks = false, .lock = .exclusive }) catch |err| switch (err) {
            error.FileNotFound => created: {
                const created = dir.createFile(io, ".preferences.lock", .{ .read = true, .exclusive = true, .lock = .exclusive, .permissions = .fromMode(0o600) }) catch |create_err| switch (create_err) {
                    error.PathAlreadyExists => continue,
                    else => return create_err,
                };
                if (std.c.fchmod(created.handle, 0o600) != 0) {
                    created.close(io);
                    return error.PreferencePermissionsFailed;
                }
                break :created created;
            },
            else => return err,
        };
    };
    defer lock.close(io);
    try privateFile(lock);
    const saved = try read(dir);
    try validate(&saved);
    if (only_if_unset) {
        if (saved.provider.len != 0) return null;
    }
    var values = try apply(saved, edit, readiness);
    if (edit.store) |value| {
        const paths = try platform.resolveClientPaths(io, value);
        values.store.set(paths.store.slice()) catch return error.InvalidPreferenceStore;
    }
    try validate(&values);

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
    if (std.c.fchmod(file.handle, 0o600) != 0) return error.PreferencePermissionsFailed;
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

test "login fills only a missing provider under the preference lock" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &home_buffer);
    const home = home_buffer[0..len];
    try std.testing.expect(try fillProviderAfterLogin(home));
    const first = try load(home);
    try std.testing.expect(first.provider.eql("codex") and first.model.len == 0);

    // A saved, currently unsupported choice is still the user's choice. An
    // unconditional login update would overwrite this exact counterexample.
    var config = try tmp.dir.openDir(io, ".config/rui", .{});
    defer config.close(io);
    var file = try config.createFile(io, "preferences.tmp", .{ .permissions = .fromMode(0o600) });
    try file.writeStreamingAll(io, "version=1\nstore=\nprovider=legacy\nmodel=legacy-model\n");
    file.close(io);
    try config.rename("preferences.tmp", config, "preferences", io);
    try std.testing.expect(!try fillProviderAfterLogin(home));
    const saved = try load(home);
    try std.testing.expect(saved.provider.eql("legacy") and saved.model.eql("legacy-model"));
}

test "provider preference retains inheritance instead of pinning a recommendation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &home_buffer);
    const home = home_buffer[0..len];
    const values = try update(home, .{ .provider = "codex" }, .configured);
    try std.testing.expectEqualStrings("codex", values.provider.slice());
    try std.testing.expectEqualStrings("", values.model.slice());
}

test "preference edits keep set and clear exact choices independently of availability" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &home_buffer);
    const home = home_buffer[0..len];
    _ = try update(home, .{ .provider = "codex", .model = .{ .set = "explicit-v2" } }, .missing);
    const kept = try update(home, .{ .provider = "codex" }, .missing);
    try std.testing.expectEqualStrings("explicit-v2", kept.model.slice());
    const cleared = try update(home, .{ .model = .clear }, .missing);
    try std.testing.expectEqualStrings("", cleared.model.slice());
    try std.testing.expectError(error.InvalidPreferenceModel, update(home, .{ .model = .{ .set = "" } }, .configured));
    try std.testing.expectEqualStrings("", (try load(home)).model.slice());
    var legacy: Values = .{};
    try legacy.store.set("/unavailable/saved-store");
    try legacy.provider.set("retired");
    try legacy.model.set("old-pin");
    const store_only = try apply(legacy, .{ .store = home }, .missing);
    try std.testing.expect(store_only.provider.eql("retired") and store_only.model.eql("old-pin"));
    const replaced = try apply(legacy, .{ .provider = "codex" }, .missing);
    try std.testing.expect(replaced.provider.eql("codex") and replaced.model.len == 0);
    const pinned = try apply(legacy, .{ .provider = "codex", .model = .{ .set = "new-pin" } }, .missing);
    try std.testing.expectEqualStrings("new-pin", pinned.model.slice());
    try std.testing.expectError(error.PreferenceProviderRequired, apply(.{}, .{ .model = .{ .set = "a-pin" } }, .missing));
    const sole = try apply(.{}, .{ .model = .{ .set = "a-pin" } }, .renewal_due);
    try std.testing.expect(sole.provider.eql("codex") and sole.model.eql("a-pin"));
}

test "loading preferences does not validate an unused missing Store" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &home_buffer);
    const home = home_buffer[0..len];
    var store = try tmp.dir.createDirPathOpen(io, "store", .{ .permissions = .fromMode(0o700) });
    store.close(io);
    var store_buffer: [protocol.max_store_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&store_buffer, "{s}/store", .{home});
    _ = try update(home, .{ .store = path }, .missing);
    try tmp.dir.deleteDir(io, "store");
    try std.testing.expectEqualStrings(path, (try load(home)).store.slice());
    try std.testing.expect(try fillProviderAfterLogin(home));
    const saved = try update(home, .{ .model = .{ .set = "explicit-model" } }, .missing);
    try std.testing.expectEqualStrings(path, saved.store.slice());
    try std.testing.expectEqualStrings("explicit-model", saved.model.slice());
}

test "login publication and setup serialize without losing the explicit pin" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &home_buffer);
    const home = home_buffer[0..len];
    var private = try tmp.dir.createDirPathOpen(io, ".config/rui", .{ .permissions = .fromMode(0o700) });
    private.close(io);
    const Worker = struct {
        home: []const u8,
        login: bool,
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            self.work() catch |err| {
                self.failure = err;
            };
        }
        fn work(self: *@This()) !void {
            if (self.login) {
                const credentials = @import("codex_credentials.zig");
                const auth = @import("codex_auth.zig");
                var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
                const path = try std.fmt.bufPrint(&path_buffer, "{s}/.config/rui/codex.json", .{self.home});
                var record: credentials.Record = .{ .generation = 0, .account_id = .{}, .id_token = .{}, .access_token = .{}, .refresh_token = .{}, .expires_at = 4_102_444_800, .refreshed_at = 100 };
                defer std.crypto.secureZero(u8, std.mem.asBytes(&record));
                try record.account_id.set(auth.fixture_account_id);
                try record.id_token.set(auth.fixture_id_token);
                try record.access_token.set(auth.fixture_access_token);
                try record.refresh_token.set("synthetic-refresh");
                try credentials.install(path, &record, null);
                _ = try fillProviderAfterLogin(self.home);
                var lease: credentials.Lease = undefined;
                try auth.acquireInto(io, path, true, &lease);
                defer lease.release();
                try std.testing.expectEqualStrings(auth.fixture_account_id, lease.record.account_id.slice());
            } else _ = try update(self.home, .{ .provider = "codex", .model = .{ .set = "deliberate-model" } }, .missing);
        }
    };
    var login: Worker = .{ .home = home, .login = true };
    var setup: Worker = .{ .home = home, .login = false };
    const a = try std.Thread.spawn(.{}, Worker.run, .{&login});
    const b = try std.Thread.spawn(.{}, Worker.run, .{&setup});
    a.join();
    b.join();
    if (login.failure) |err| return err;
    if (setup.failure) |err| return err;
    const saved = try load(home);
    try std.testing.expect(saved.provider.eql("codex") and saved.model.eql("deliberate-model"));
}
