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

pub const Change = union(enum) { keep, set: []const u8 };

/// Borrows set strings through update. Keep preserves a choice, not a resolved
/// recommendation; an absent model inherits only when creating a new Session.
pub const Edit = struct {
    store: Change = .keep,
    provider: Change = .keep,
    model: union(enum) { keep, set: []const u8, clear } = .keep,
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

/// Safe fields only: resource availability belongs to the selecting caller.
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

/// Serializes read/modify/write for competing setup callers. A failed write or
/// rename leaves the previous complete file; post-rename sync failure is uncertain.
pub fn update(home: []const u8, edit: Edit, readiness: provider_selection.Readiness) !Values {
    return (try save(home, edit, readiness, false)).?;
}

/// Under the same preference lock as setup, keep an existing provider choice.
/// Null means no change was published; credentials are owned separately.
pub fn fillProviderAfterLogin(home: []const u8) !bool {
    return (try save(home, .{ .provider = .{ .set = "codex" } }, .configured, true)) != null;
}

/// Apply explicit choices to the locked snapshot, never resolved recommendations.
fn apply(saved: Values, edit: Edit, readiness: provider_selection.Readiness) !Values {
    var values = saved;
    if (edit.store == .set) {
        const paths = try platform.resolveClientPaths(io, edit.store.set);
        values.store.set(paths.store.slice()) catch return error.InvalidPreferenceStore;
    }
    if (edit.provider == .set) {
        if (!saved.provider.eql(edit.provider.set)) values.model = .{};
        values.provider.set(edit.provider.set) catch unreachable;
    }
    switch (edit.model) {
        .keep => {},
        .clear => values.model = .{},
        .set => |model| {
            const supported = provider_selection.codex(readiness);
            const choice = provider_selection.resolve(&.{supported}, null, model, if (values.provider.len != 0) values.provider.slice() else null, null) catch |err| switch (err) {
                error.UnsupportedSelectionProvider => return error.UnsupportedPreferenceProvider,
                error.UnsupportedSelectionModel => return error.UnsupportedPreferenceModel,
            };
            if (choice == .chooser) return error.PreferenceProviderRequired;
            values.provider.set(choice.selected.provider) catch unreachable;
            values.model.set(model) catch unreachable;
        },
    }
    return values;
}

fn save(home: []const u8, edit: Edit, readiness: provider_selection.Readiness, only_if_unset: bool) !?Values {
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    _ = try directoryPath(home, &path);
    if (edit.provider == .set) {
        if (!std.mem.eql(u8, edit.provider.set, "codex")) return error.UnsupportedPreferenceProvider;
    }
    if (edit.model == .set) {
        const value = edit.model.set;
        if (value.len == 0 or value.len > protocol.max_model_bytes) return error.InvalidPreferenceModel;
        for (value) |byte| if (byte < 0x21 or byte > 0x7e) return error.InvalidPreferenceModel;
        const supported = provider_selection.codex(.missing);
        _ = provider_selection.resolve(&.{supported}, "codex", value, null, null) catch
            return error.UnsupportedPreferenceModel;
    }
    if (edit.store == .set) {
        const value = edit.store.set;
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
        // Only newly created entries belong to this owner. Existing parents
        // retain their modes; existing private entries still fail validation.
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
        // Sync both parent entries even if another caller created them but
        // has not synced yet; close parent handles before lock/publication.
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
    const values = try apply(saved, edit, readiness);
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
    try std.testing.expectEqualStrings("codex", first.provider.slice());
    try std.testing.expectEqualStrings("", first.model.slice());

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

test "preference edits distinguish model keep set and clear without publishing recommendations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &home_buffer);
    const home = home_buffer[0..len];
    const pinned = try update(home, .{ .provider = .{ .set = "codex" }, .model = .{ .set = "gpt-6-luna" } }, .missing);
    try std.testing.expect(pinned.provider.eql("codex") and pinned.model.eql("gpt-6-luna"));
    const kept = try update(home, .{}, .credential_error);
    try std.testing.expect(kept.provider.eql("codex") and kept.model.eql("gpt-6-luna"));
    const cleared = try update(home, .{ .model = .clear }, .configured);
    try std.testing.expect(cleared.provider.eql("codex") and cleared.model.len == 0);
    try std.testing.expect((try load(home)).model.len == 0);
    try std.testing.expect(!try fillProviderAfterLogin(home));
    try std.testing.expect((try load(home)).model.len == 0);
    const reset = try update(home, .{ .model = .{ .set = "gpt-6-luna" } }, .refresh_required);
    try std.testing.expect(reset.model.eql("gpt-6-luna"));
    try std.testing.expectError(error.InvalidPreferenceModel, update(home, .{ .model = .{ .set = "" } }, .configured));
    try std.testing.expect((try load(home)).model.eql("gpt-6-luna"));
}

test "preference edits persist explicit choices rather than recommendations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &home_buffer);
    const home = home_buffer[0..len];
    _ = try fillProviderAfterLogin(home);
    var config = try tmp.dir.openDir(io, ".config/rui", .{});
    defer config.close(io);
    const cases = .{
        .{ "", "", Edit{ .model = .clear }, "", "" },
        .{ "legacy", "retired-model", Edit{ .model = .clear }, "legacy", "" },
        .{ "legacy", "retired-model", Edit{ .provider = .{ .set = "codex" }, .model = .clear }, "codex", "" },
        .{ "legacy", "retired-model", Edit{ .provider = .{ .set = "codex" } }, "codex", "" },
        .{ "codex", "family=variant", Edit{ .provider = .{ .set = "codex" } }, "codex", "family=variant" },
        .{ "", "", Edit{ .provider = .{ .set = "codex" } }, "codex", "" },
        .{ "legacy", "retired-model", Edit{ .provider = .{ .set = "codex" }, .model = .{ .set = "new-pin" } }, "codex", "new-pin" },
        .{ "", "", Edit{ .model = .{ .set = "gpt-6-luna" } }, "codex", "gpt-6-luna" },
        .{ "legacy", "retired-model", Edit{}, "legacy", "retired-model" },
    };
    inline for (cases) |case| {
        const file = try config.createFile(io, "preferences", .{ .permissions = .fromMode(0o600) });
        try file.writeStreamingAll(io, "version=1\nstore=\nprovider=" ++ case[0] ++ "\nmodel=" ++ case[1] ++ "\n");
        file.close(io);
        const result = try update(home, case[2], .configured);
        try std.testing.expectEqualStrings(case[3], result.provider.slice());
        try std.testing.expectEqualStrings(case[4], result.model.slice());
        const reloaded = try load(home);
        try std.testing.expectEqualStrings(case[3], reloaded.provider.slice());
        try std.testing.expectEqualStrings(case[4], reloaded.model.slice());
    }
}

test "preference edits preserve unused deleted Store but validate supplied replacement" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &home_buffer);
    const home = home_buffer[0..len];
    try tmp.dir.createDir(io, "old", .fromMode(0o700));
    try tmp.dir.createDir(io, "replacement", .fromMode(0o700));
    var old_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var replacement_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const old = try std.fmt.bufPrint(&old_buffer, "{s}/old", .{home});
    const replacement = try std.fmt.bufPrint(&replacement_buffer, "{s}/replacement", .{home});
    const before = try update(home, .{ .store = .{ .set = old }, .provider = .{ .set = "codex" }, .model = .{ .set = "gpt-6-luna" } }, .missing);
    try tmp.dir.deleteDir(io, "old");
    try std.testing.expectEqualStrings(old, (try load(home)).store.slice());
    const cleared = try update(home, .{ .model = .clear }, .configured);
    try std.testing.expect(cleared.store.eql(before.store.slice()) and cleared.model.len == 0);
    const independent = try update(home, .{ .model = .{ .set = "explicit-model" } }, .missing);
    try std.testing.expect(independent.store.eql(old) and independent.model.eql("explicit-model"));
    try std.testing.expectError(error.FileNotFound, update(home, .{ .store = .{ .set = old }, .model = .clear }, .configured));
    try std.testing.expect((try load(home)).model.eql("explicit-model"));
    const repaired = try update(home, .{ .store = .{ .set = replacement }, .model = .clear }, .missing);
    try std.testing.expect(repaired.store.eql(replacement) and repaired.provider.eql("codex") and repaired.model.len == 0);
    try std.testing.expect((try load(home)).store.eql(replacement));
}

test "preference publication creates owner usable private modes despite umask" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &home_buffer);
    const home = home_buffer[0..len];
    const previous = c.umask(0o777);
    defer _ = c.umask(previous);
    _ = try update(home, .{ .provider = .{ .set = "codex" } }, .missing);
    var config = try tmp.dir.openDir(io, ".config", .{ .iterate = true });
    defer config.close(io);
    var private = try config.openDir(io, "rui", .{ .iterate = true });
    defer private.close(io);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o700), (try config.stat(io)).permissions.toMode() & 0o777);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o700), (try private.stat(io)).permissions.toMode() & 0o777);
    for ([_][]const u8{ "preferences", ".preferences.lock" }) |name| {
        const file = try private.openFile(io, name, .{});
        defer file.close(io);
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), (try file.stat(io)).permissions.toMode() & 0o777);
    }
    // Do not silently repair an existing parent's mode or an unsafe private owner.
    try std.testing.expectEqual(@as(c_int, 0), std.c.fchmod(config.handle, 0o750));
    _ = try update(home, .{ .model = .{ .set = "explicit-pin" } }, .missing);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o750), (try config.stat(io)).permissions.toMode() & 0o777);
    try std.testing.expectEqual(@as(c_int, 0), std.c.fchmod(private.handle, 0o755));
    defer _ = std.c.fchmod(private.handle, 0o700);
    try std.testing.expectError(error.InsecurePreferenceDirectory, update(home, .{ .model = .clear }, .configured));
}

test "preference publication is independent of an unused oversized HOME Store fallback" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var len = try tmp.dir.realPath(io, &home_buffer);
    while (len + 2 <= home_buffer.len - 18) {
        @memcpy(home_buffer[len..][0..2], "/.");
        len += 2;
    }
    const home = home_buffer[0..len];
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try std.testing.expectError(error.PreferencePathTooLong, defaultStore(home, &path_buffer));
    _ = try directoryPath(home, &path_buffer);
    try std.testing.expect(try fillProviderAfterLogin(home));
    try std.testing.expect((try load(home)).provider.eql("codex"));
    _ = try update(home, .{ .model = .{ .set = "family=variant" } }, .missing);
    try std.testing.expect((try load(home)).model.eql("family=variant"));
}

test "preference login fill and setup serialize without losing an explicit pin" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &home_buffer);
    const home = home_buffer[0..len];
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
                _ = try fillProviderAfterLogin(self.home);
            } else _ = try update(self.home, .{ .provider = .{ .set = "codex" }, .model = .{ .set = "deliberate-pin" } }, .missing);
        }
    };
    var login: Worker = .{ .home = home, .login = true };
    var setup: Worker = .{ .home = home, .login = false };
    const a = try std.Thread.spawn(.{}, Worker.run, .{&login});
    const b = std.Thread.spawn(.{}, Worker.run, .{&setup}) catch |err| {
        a.join();
        return err;
    };
    b.join();
    a.join();
    if (login.failure) |err| return err;
    if (setup.failure) |err| return err;
    const saved = try load(home);
    try std.testing.expect(saved.provider.eql("codex") and saved.model.eql("deliberate-pin"));
}
