const std = @import("std");
const provider_route = @import("provider_route.zig");
const c = @import("posix");
const model_capability = @import("model_capability.zig");
const platform = @import("platform.zig");
const protocol = @import("protocol.zig");
const provider_selection = @import("provider_selection.zig");

const io = std.Io.Threaded.global_single_threaded.io();
const max_file_bytes = 1024;

pub const Values = @import("preference_values.zig").Values;
pub const directoryPath = @import("preference_values.zig").directoryPath;
const validateDirectoryPath = @import("preference_values.zig").validateDirectoryPath;
pub const defaultStore = @import("preference_values.zig").defaultStore;

const document = @import("preference_document.zig");
pub const Change = document.Change;
pub const Edit = document.Edit;
pub const validate = document.validate;
const validateSaved = document.validateSaved;
const PermissionMode = @import("cli_value.zig").PermissionMode;

const Loaded = struct { values: Values = .{}, migrated: bool = false };

fn read(dir: std.Io.Dir) !Loaded {
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
    var current: [max_file_bytes]u8 = undefined;
    const migrated = try document.migrate(bytes[0..count], &current);
    return .{ .values = try document.decode(migrated orelse bytes[0..count]), .migrated = migrated != null };
}

/// Reads the saved defaults; a file an earlier release wrote is saved once as the current document.
pub fn load(home: []const u8) !Values {
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory = try directoryPath(home, &path);
    var dir = openPrivateDirectory(directory) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer dir.close(io);
    const saved = try read(dir);
    try validateSaved(&saved.values);
    if (saved.migrated) {
        const readiness: Readinesses = .initFill(.configured);
        return update(home, .{}, &readiness);
    }
    return saved.values;
}

pub const Readinesses = provider_selection.Readinesses;

pub const Failure = document.Failure;
pub const failure = document.failure;

test "a failed save says whether the file holds it, and why, without an error name" {
    try std.testing.expect(failure(error.PreferenceDirectorySyncFailed).saved);
    for ([_]anyerror{ error.UnsupportedPreferenceProvider, error.PreferenceProviderRequired, error.InvalidPreferenceModel, error.InvalidPreferenceStore }) |err| {
        const said = failure(err);
        try std.testing.expect(!said.saved);
        try std.testing.expect(std.mem.indexOf(u8, said.reason.?, @errorName(err)) == null);
    }
    try std.testing.expectEqual(@as(?[]const u8, null), failure(error.AccessDenied).reason);
}

pub fn update(home: []const u8, edit: Edit, readiness: *const Readinesses) !Values {
    return (try save(home, edit, readiness, null)).values;
}

pub const LoginDefault = enum {
    filled,
    replaced,
    already,
    kept,
};

pub fn fillProviderAfterLogin(home: []const u8, provider: protocol.Provider) !LoginDefault {
    const readiness: Readinesses = .initFill(.configured);
    return (try save(home, .{ .provider = .{ .set = @tagName(provider) } }, &readiness, provider)).login.?;
}

fn loginOutcome(before: *const Values, published: bool, provider: protocol.Provider) LoginDefault {
    if (!published) return if (before.provider.eql(@tagName(provider))) .already else .kept;
    return if (before.provider.len == 0) .filled else .replaced;
}

fn loginMayReplace(saved: []const u8, provider: protocol.Provider) bool {
    return saved.len == 0 or otherWayIn(saved, @tagName(provider));
}

const otherWayIn = document.otherWayIn;

pub fn saveProviderAfterLogin(home: []const u8, provider: protocol.Provider) !void {
    const readiness: Readinesses = .initFill(.configured);
    _ = try save(home, .{ .provider = .{ .set = @tagName(provider) } }, &readiness, null);
}

noinline fn resolveStore(value: []const u8) !@import("host_settings.zig").OsBytes(protocol.max_store_bytes) {
    const paths = platform.resolveClientPaths(io, value) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.AccessDenied, error.PermissionDenied, error.InsecureDirectoryPermissions, error.SymLinkLoop, error.StorePathTooLong, error.NameTooLong, error.InvalidStorePath => return error.InvalidPreferenceStore,
        else => return err,
    };
    var selector: @import("host_settings.zig").OsBytes(protocol.max_store_bytes) = .{};
    try selector.set(paths.selector());
    return selector;
}

fn apply(saved: Values, edit: Edit, readiness: *const Readinesses) !Values {
    var selector: @import("host_settings.zig").OsBytes(protocol.max_store_bytes) = .{};
    if (edit.store == .set) selector = try resolveStore(edit.store.set);
    return document.apply(saved, edit, if (edit.store == .set) selector.slice() else null, readiness);
}

const Saved = struct { values: Values, login: ?LoginDefault };

fn save(home: []const u8, edit: Edit, readiness: *const Readinesses, login: ?protocol.Provider) !Saved {
    return saveWithSync(home, edit, readiness, login, NativeDirectorySync{});
}

const NativeDirectorySync = struct {
    fn sync(_: @This(), fd: std.posix.fd_t) c_int {
        return std.c.fsync(fd);
    }
};

fn saveWithSync(home: []const u8, edit: Edit, readiness: *const Readinesses, login: ?protocol.Provider, directory_sync: anytype) !Saved {
    try validateDirectoryPath(home);
    try document.validateEdit(edit);
    if (edit.store == .set) _ = try resolveStore(edit.store.set);
    var dir = blk: {
        var home_dir = try std.Io.Dir.openDirAbsolute(io, home, .{ .iterate = true });
        defer home_dir.close(io);
        const created_config = if (home_dir.createDir(io, ".config", .fromMode(0o700))) |_| true else |err| switch (err) {
            error.PathAlreadyExists => false,
            else => return err,
        };
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
        if (directory_sync.sync(home_dir.handle) != 0 or directory_sync.sync(config_dir.handle) != 0)
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
    const saved = (try read(dir)).values;
    try validateSaved(&saved);
    if (login) |provider| {
        if (!loginMayReplace(saved.provider.slice(), provider)) return .{ .values = saved, .login = loginOutcome(&saved, false, provider) };
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
    {
        const file = try dir.createFile(io, "preferences.tmp", .{ .read = true, .exclusive = true, .permissions = .fromMode(0o600) });
        errdefer dir.deleteFile(io, "preferences.tmp") catch {};
        {
            defer file.close(io);
            if (std.c.fchmod(file.handle, 0o600) != 0) return error.PreferencePermissionsFailed;
            var bytes: [max_file_bytes]u8 = undefined;
            const encoded = try document.encode(&values, &bytes);
            try file.writeStreamingAll(io, encoded);
            try file.sync(io);
        }
        try dir.rename("preferences.tmp", dir, "preferences", io);
    }
    if (directory_sync.sync(dir.handle) != 0) return error.PreferenceDirectorySyncFailed;
    return .{ .values = values, .login = if (login) |provider| loginOutcome(&saved, true, provider) else null };
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

fn codexOnly(state: provider_selection.Readiness) Readinesses {
    var readiness: Readinesses = .initFill(.missing);
    readiness.set(provider_route.nameOf(.codex), state);
    return readiness;
}

test "native directory sync forwards descriptor failures" {
    const native: NativeDirectorySync = .{};
    var fds: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    try std.testing.expectEqual(@as(c_int, -1), native.sync(fds[0]));
    try std.testing.expectEqual(@as(c_int, -1), native.sync(-1));
    try std.testing.expectEqual(std.posix.E.BADF, std.posix.errno(-1));

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer directory.close(io);
    try std.testing.expectEqual(@as(c_int, 0), native.sync(directory.handle));
}

test "directory sync failures preserve complete preference publication" {
    const Cut = struct {
        at: usize,
        expected: [3]c.struct_stat,
        calls: usize = 0,
        correct_directories: bool = true,

        fn sync(self: *@This(), fd: std.posix.fd_t) c_int {
            var actual: c.struct_stat = undefined;
            const matches = self.calls < self.expected.len and c.fstat(fd, &actual) == 0 and
                actual.st_dev == self.expected[self.calls].st_dev and
                actual.st_ino == self.expected[self.calls].st_ino;
            self.correct_directories = self.correct_directories and matches;
            self.calls += 1;
            return if (self.calls == self.at) -1 else NativeDirectorySync.sync(.{}, fd);
        }
    };
    const old = "version=4\nstore=\nconnection=codex\nmodel=deliberate-pin\nnotifications=on\nreasoning_effort=\npermission_mode=\n";
    const new = "version=4\nstore=\nconnection=codex\nmodel=new-pin\nnotifications=on\nreasoning_effort=\npermission_mode=\n";
    for (0..4) |cut| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const len = try tmp.dir.realPath(io, &path);
        const home = path[0..len];
        _ = try update(home, .{ .provider = .{ .set = "codex" }, .model = .{ .set = "deliberate-pin" } }, &codexOnly(.missing));
        var fault: Cut = .{ .at = cut, .expected = undefined };
        for ([_][]const u8{ ".", ".config", ".config/rui" }, 0..) |name, index| {
            const dir = try tmp.dir.openDir(io, name, .{});
            defer dir.close(io);
            try std.testing.expectEqual(@as(c_int, 0), c.fstat(dir.handle, &fault.expected[index]));
        }
        const result = saveWithSync(home, .{ .model = .{ .set = "new-pin" } }, &codexOnly(.missing), null, &fault);
        if (cut == 0) {
            _ = try result;
        } else try std.testing.expectError(error.PreferenceDirectorySyncFailed, result);
        try std.testing.expect(fault.correct_directories);
        try std.testing.expectEqual(if (cut == 0) @as(usize, 3) else cut, fault.calls);
        const saved = try tmp.dir.openFile(io, ".config/rui/preferences", .{});
        defer saved.close(io);
        var bytes: [1024]u8 = undefined;
        const count = try saved.readPositionalAll(io, &bytes, 0);
        try std.testing.expectEqualStrings(if (cut == 1 or cut == 2) old else new, bytes[0..count]);
        try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(io, ".config/rui/preferences.tmp", .{}));
        const loaded = try load(home);
        try std.testing.expectEqualStrings(if (cut == 1 or cut == 2) "deliberate-pin" else "new-pin", loaded.model.slice());
    }
}

test "login fills only a missing provider under the preference lock" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &home_buffer);
    const home = home_buffer[0..len];
    try std.testing.expectEqual(LoginDefault.filled, try fillProviderAfterLogin(home, .codex));
    const first = try load(home);
    try std.testing.expectEqualStrings("codex", first.provider.slice());
    try std.testing.expectEqualStrings("", first.model.slice());

    var config = try tmp.dir.openDir(io, ".config/rui", .{});
    defer config.close(io);
    var file = try config.createFile(io, "preferences.tmp", .{ .permissions = .fromMode(0o600) });
    try file.writeStreamingAll(io, "version=1\nstore=\nprovider=legacy\nmodel=legacy-model\n");
    file.close(io);
    try config.rename("preferences.tmp", config, "preferences", io);
    try std.testing.expectEqual(LoginDefault.kept, try fillProviderAfterLogin(home, .codex));
    const saved = try load(home);
    try std.testing.expect(saved.provider.eql("legacy") and saved.model.eql("legacy-model"));
}

test "a login fills an unset default, replaces the other sign-in to its account keeping the model, and keeps every other choice" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = home_buffer[0..try tmp.dir.realPath(io, &home_buffer)];
    _ = try update(home, .{}, &.initFill(.configured));
    var config = try tmp.dir.openDir(io, ".config/rui", .{});
    defer config.close(io);
    const pin = "gpt-6-luna";
    const Expected = union(enum) {
        unchanged: LoginDefault,
        saved: struct { outcome: LoginDefault, provider: []const u8, model: []const u8 },
        refused: anyerror,
    };
    const Case = struct { saved: []const u8, pinned: bool, login: protocol.Provider, expected: Expected };
    const cases = [_]Case{
        .{ .saved = "", .pinned = false, .login = .codex, .expected = .{ .saved = .{ .outcome = .filled, .provider = "codex", .model = "" } } },
        .{ .saved = "", .pinned = false, .login = .chatgpt, .expected = .{ .saved = .{ .outcome = .filled, .provider = "chatgpt", .model = "" } } },
        .{ .saved = "", .pinned = false, .login = .openai, .expected = .{ .saved = .{ .outcome = .filled, .provider = "openai", .model = "" } } },
        .{ .saved = "", .pinned = true, .login = .codex, .expected = .{ .refused = error.SavedPreferenceProviderRequired } },
        .{ .saved = "", .pinned = true, .login = .chatgpt, .expected = .{ .refused = error.SavedPreferenceProviderRequired } },
        .{ .saved = "", .pinned = true, .login = .openai, .expected = .{ .refused = error.SavedPreferenceProviderRequired } },
        .{ .saved = "codex", .pinned = false, .login = .codex, .expected = .{ .unchanged = .already } },
        .{ .saved = "codex", .pinned = false, .login = .chatgpt, .expected = .{ .saved = .{ .outcome = .replaced, .provider = "chatgpt", .model = "" } } },
        .{ .saved = "codex", .pinned = false, .login = .openai, .expected = .{ .unchanged = .kept } },
        .{ .saved = "codex", .pinned = true, .login = .codex, .expected = .{ .unchanged = .already } },
        .{ .saved = "codex", .pinned = true, .login = .chatgpt, .expected = .{ .saved = .{ .outcome = .replaced, .provider = "chatgpt", .model = pin } } },
        .{ .saved = "codex", .pinned = true, .login = .openai, .expected = .{ .unchanged = .kept } },
        .{ .saved = "chatgpt", .pinned = false, .login = .codex, .expected = .{ .saved = .{ .outcome = .replaced, .provider = "codex", .model = "" } } },
        .{ .saved = "chatgpt", .pinned = false, .login = .chatgpt, .expected = .{ .unchanged = .already } },
        .{ .saved = "chatgpt", .pinned = false, .login = .openai, .expected = .{ .unchanged = .kept } },
        .{ .saved = "chatgpt", .pinned = true, .login = .codex, .expected = .{ .saved = .{ .outcome = .replaced, .provider = "codex", .model = pin } } },
        .{ .saved = "chatgpt", .pinned = true, .login = .chatgpt, .expected = .{ .unchanged = .already } },
        .{ .saved = "chatgpt", .pinned = true, .login = .openai, .expected = .{ .unchanged = .kept } },
        .{ .saved = "openai", .pinned = false, .login = .codex, .expected = .{ .unchanged = .kept } },
        .{ .saved = "openai", .pinned = false, .login = .chatgpt, .expected = .{ .unchanged = .kept } },
        .{ .saved = "openai", .pinned = false, .login = .openai, .expected = .{ .unchanged = .already } },
        .{ .saved = "openai", .pinned = true, .login = .codex, .expected = .{ .unchanged = .kept } },
        .{ .saved = "openai", .pinned = true, .login = .chatgpt, .expected = .{ .unchanged = .kept } },
        .{ .saved = "openai", .pinned = true, .login = .openai, .expected = .{ .unchanged = .already } },
        .{ .saved = "retired", .pinned = false, .login = .codex, .expected = .{ .unchanged = .kept } },
        .{ .saved = "retired", .pinned = false, .login = .chatgpt, .expected = .{ .unchanged = .kept } },
        .{ .saved = "retired", .pinned = false, .login = .openai, .expected = .{ .unchanged = .kept } },
        .{ .saved = "retired", .pinned = true, .login = .codex, .expected = .{ .unchanged = .kept } },
        .{ .saved = "retired", .pinned = true, .login = .chatgpt, .expected = .{ .unchanged = .kept } },
        .{ .saved = "retired", .pinned = true, .login = .openai, .expected = .{ .unchanged = .kept } },
    };
    try std.testing.expectEqual(5 * std.enums.values(protocol.Provider).len * 2, cases.len);
    for (cases) |case| {
        var text_buffer: [256]u8 = undefined;
        const text = try std.fmt.bufPrint(&text_buffer, "version=3\nstore=\nprovider={s}\nmodel={s}\nnotifications=off\nreasoning_effort=high\n", .{ case.saved, if (case.pinned) pin else "" });
        const file = try config.createFile(io, "preferences", .{ .permissions = .fromMode(0o600) });
        try file.writeStreamingAll(io, text);
        file.close(io);
        const outcome = fillProviderAfterLogin(home, case.login);
        var bytes: [256]u8 = undefined;
        switch (case.expected) {
            .refused => |err| {
                try std.testing.expectError(err, outcome);
                try std.testing.expectEqualStrings(text, try savedFile(config, &bytes));
            },
            .unchanged => |expected| {
                try std.testing.expectEqual(expected, try outcome);
                try std.testing.expectEqualStrings(text, try savedFile(config, &bytes));
            },
            .saved => |expected| {
                try std.testing.expectEqual(expected.outcome, try outcome);
                const saved = try load(home);
                try std.testing.expectEqualStrings(expected.provider, saved.provider.slice());
                try std.testing.expectEqualStrings(expected.model, saved.model.slice());
                try std.testing.expect(!saved.notifications and saved.reasoning_effort == .high);
            },
        }
    }
    for (std.enums.values(protocol.Provider)) |login| {
        const text = "version=9\nstore=\nconnection=codex\nmodel=\n";
        const file = try config.createFile(io, "preferences", .{ .permissions = .fromMode(0o600) });
        try file.writeStreamingAll(io, text);
        file.close(io);
        try std.testing.expectError(error.UnsupportedPreferencesVersion, fillProviderAfterLogin(home, login));
        var bytes: [256]u8 = undefined;
        try std.testing.expectEqualStrings(text, try savedFile(config, &bytes));
    }
}

test "the sign-in screen's save keeps the model only within one account" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = home_buffer[0..try tmp.dir.realPath(io, &home_buffer)];
    const all: Readinesses = .initFill(.configured);
    for ([_]struct { []const u8, protocol.Provider, []const u8 }{
        .{ "codex", .chatgpt, "gpt-6-luna" },
        .{ "chatgpt", .codex, "gpt-6-luna" },
        .{ "codex", .codex, "gpt-6-luna" },
        .{ "codex", .openai, "" },
        .{ "openai", .chatgpt, "" },
        .{ "openai", .codex, "" },
    }) |case| {
        _ = try update(home, .{ .provider = .{ .set = case[0] }, .model = .{ .set = "gpt-6-luna" } }, &all);
        try saveProviderAfterLogin(home, case[1]);
        const saved = try load(home);
        try std.testing.expectEqualStrings(@tagName(case[1]), saved.provider.slice());
        try std.testing.expectEqualStrings(case[2], saved.model.slice());
    }
}

test "preference edits distinguish model keep set and clear without publishing recommendations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &home_buffer);
    const home = home_buffer[0..len];
    const pinned = try update(home, .{ .provider = .{ .set = "codex" }, .model = .{ .set = "gpt-6-luna" } }, &codexOnly(.missing));
    try std.testing.expect(pinned.provider.eql("codex") and pinned.model.eql("gpt-6-luna"));
    const kept = try update(home, .{}, &codexOnly(.credential_error));
    try std.testing.expect(kept.provider.eql("codex") and kept.model.eql("gpt-6-luna"));
    const cleared = try update(home, .{ .model = .clear }, &codexOnly(.configured));
    try std.testing.expect(cleared.provider.eql("codex") and cleared.model.len == 0);
    try std.testing.expect((try load(home)).model.len == 0);
    try std.testing.expectEqual(LoginDefault.already, try fillProviderAfterLogin(home, .codex));
    try std.testing.expect((try load(home)).model.len == 0);
    const reset = try update(home, .{ .model = .{ .set = "gpt-6-luna" } }, &codexOnly(.refresh_required));
    try std.testing.expect(reset.model.eql("gpt-6-luna"));
    for ([_][]const u8{ "family=variant", &@as([256]u8, @splat('x')) }) |valid| {
        const result = try update(home, .{ .model = .{ .set = valid } }, &codexOnly(.missing));
        try std.testing.expectEqualStrings(valid, result.model.slice());
        try std.testing.expectEqualStrings(valid, (try load(home)).model.slice());
        for ([_][]const u8{ "", "bad model", "bad\nmodel", "\x7f", "\xc3\xa9", &@as([257]u8, @splat('x')) }) |invalid| {
            try std.testing.expectError(error.InvalidPreferenceModel, update(home, .{ .model = .{ .set = invalid } }, &codexOnly(.configured)));
            try std.testing.expectEqualStrings(valid, (try load(home)).model.slice());
        }
    }
}

test "notifications stay on until turned off, and a version 1 file reads as on" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &home_buffer);
    const home = home_buffer[0..len];
    try std.testing.expect((try load(home)).notifications);
    _ = try update(home, .{ .provider = .{ .set = "codex" } }, &codexOnly(.missing));
    var config = try tmp.dir.openDir(io, ".config/rui", .{});
    defer config.close(io);
    const file = try config.createFile(io, "preferences", .{ .permissions = .fromMode(0o600) });
    try file.writeStreamingAll(io, "version=1\nstore=\nprovider=codex\nmodel=pin\n");
    file.close(io);
    try std.testing.expect((try load(home)).notifications);
    const off = try update(home, .{ .notifications = false }, &codexOnly(.configured));
    try std.testing.expect(!off.notifications and off.provider.eql("codex") and off.model.eql("pin"));
    const kept = try update(home, .{ .model = .clear }, &codexOnly(.configured));
    try std.testing.expect(!kept.notifications and !(try load(home)).notifications);
    var bytes: [256]u8 = undefined;
    try std.testing.expectEqualStrings("version=4\nstore=\nconnection=codex\nmodel=\nnotifications=off\nreasoning_effort=\npermission_mode=\n", try savedFile(config, &bytes));
    try std.testing.expect((try update(home, .{ .notifications = true }, &codexOnly(.configured))).notifications);
    try std.testing.expectEqualStrings("version=4\nstore=\nconnection=codex\nmodel=\nnotifications=on\nreasoning_effort=\npermission_mode=\n", try savedFile(config, &bytes));
    for ([_][]const u8{ "version=2\nstore=\nprovider=codex\nmodel=\n", "version=2\nstore=\nprovider=codex\nmodel=\nnotifications=yes\n" }) |invalid| {
        const bad = try config.createFile(io, "preferences", .{ .permissions = .fromMode(0o600) });
        try bad.writeStreamingAll(io, invalid);
        bad.close(io);
        try std.testing.expectError(error.InvalidPreferences, load(home));
    }
}

test "a saved effort is kept across other edits, read back, and always written as version 4" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = home_buffer[0..try tmp.dir.realPath(io, &home_buffer)];
    try std.testing.expectEqual(@as(?model_capability.ReasoningEffort, null), (try load(home)).reasoning_effort);
    _ = try update(home, .{ .provider = .{ .set = "codex" }, .reasoning_effort = .{ .set = .high } }, &codexOnly(.missing));
    var config = try tmp.dir.openDir(io, ".config/rui", .{});
    defer config.close(io);
    var bytes: [256]u8 = undefined;
    try std.testing.expectEqualStrings("version=4\nstore=\nconnection=codex\nmodel=\nnotifications=on\nreasoning_effort=high\npermission_mode=\n", try savedFile(config, &bytes));
    const kept = try update(home, .{ .model = .{ .set = "gpt-6-luna" }, .notifications = false }, &codexOnly(.configured));
    try std.testing.expect(kept.reasoning_effort == .high and !kept.notifications);
    try std.testing.expectEqual(@as(?model_capability.ReasoningEffort, .high), (try load(home)).reasoning_effort);
    try std.testing.expectEqualStrings("version=4\nstore=\nconnection=codex\nmodel=gpt-6-luna\nnotifications=off\nreasoning_effort=high\npermission_mode=\n", try savedFile(config, &bytes));
    _ = try update(home, .{ .reasoning_effort = .clear, .notifications = true }, &codexOnly(.configured));
    try std.testing.expectEqualStrings("version=4\nstore=\nconnection=codex\nmodel=gpt-6-luna\nnotifications=on\nreasoning_effort=\npermission_mode=\n", try savedFile(config, &bytes));
    for ([_][]const u8{ "version=3\nstore=\nprovider=codex\nmodel=\nnotifications=on\n", "version=3\nstore=\nprovider=codex\nmodel=\nnotifications=on\nreasoning_effort=\n", "version=3\nstore=\nprovider=codex\nmodel=\nnotifications=on\nreasoning_effort=fast\n" }) |invalid| {
        const bad = try config.createFile(io, "preferences", .{ .permissions = .fromMode(0o600) });
        try bad.writeStreamingAll(io, invalid);
        bad.close(io);
        try std.testing.expectError(error.InvalidPreferences, load(home));
    }
}

test "saved permissions round trip in version 4 and clearing leaves the permission line empty" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = home_buffer[0..try tmp.dir.realPath(io, &home_buffer)];
    for (std.enums.values(PermissionMode)) |mode| {
        for ([_]?model_capability.ReasoningEffort{ null, .high }) |effort| {
            for ([_]bool{ false, true }) |notifications| {
                _ = try update(home, .{ .permission_mode = .{ .set = mode }, .reasoning_effort = if (effort) |value| .{ .set = value } else .clear, .notifications = notifications }, &.initFill(.configured));
                var config = try tmp.dir.openDir(io, ".config/rui", .{});
                defer config.close(io);
                var bytes: [256]u8 = undefined;
                var expected: [256]u8 = undefined;
                const encoded = try std.fmt.bufPrint(&expected, "version=4\nstore=\nconnection=\nmodel=\nnotifications={s}\nreasoning_effort={s}\npermission_mode={s}\n", .{ if (notifications) "on" else "off", if (effort) |value| @tagName(value) else "", @tagName(mode) });
                try std.testing.expectEqualStrings(encoded, try savedFile(config, &bytes));
                const loaded = try load(home);
                try std.testing.expectEqual(mode, loaded.permission_mode.?);
                try std.testing.expectEqual(effort, loaded.reasoning_effort);
                try std.testing.expectEqual(notifications, loaded.notifications);
                const kept = try update(home, .{ .notifications = !notifications }, &.initFill(.configured));
                try std.testing.expectEqual(mode, kept.permission_mode.?);
                try std.testing.expectEqual(mode, (try load(home)).permission_mode.?);
                _ = try update(home, .{ .permission_mode = .clear }, &.initFill(.configured));
                try std.testing.expectEqual(@as(?PermissionMode, null), (try load(home)).permission_mode);
                var cleared: [256]u8 = undefined;
                const expected_cleared = try std.fmt.bufPrint(&cleared, "version=4\nstore=\nconnection=\nmodel=\nnotifications={s}\nreasoning_effort={s}\npermission_mode=\n", .{ if (notifications) "off" else "on", if (effort) |value| @tagName(value) else "" });
                try std.testing.expectEqualStrings(expected_cleared, try savedFile(config, &bytes));
            }
        }
    }
}

test "CLI-38 reading defaults an earlier release saved returns them and leaves the current document in the file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = home_buffer[0..try tmp.dir.realPath(io, &home_buffer)];
    _ = try update(home, .{}, &.initFill(.configured));
    var config = try tmp.dir.openDir(io, ".config/rui", .{});
    defer config.close(io);
    const Case = struct { text: []const u8, after: []const u8, outcome: anyerror!void = {} };
    const current = "version=4\nstore=\nconnection=chatgpt\nmodel=gpt-6.2-sol\nnotifications=on\nreasoning_effort=medium\npermission_mode=\n";
    const cases = [_]Case{
        .{ .text = "version=3\nstore=\nprovider=chatgpt\nmodel=gpt-6.2-sol\nnotifications=on\nreasoning_effort=medium\n", .after = current },
        .{ .text = "version=4\nstore=\nprovider=chatgpt\nmodel=gpt-6.2-sol\nnotifications=on\nreasoning_effort=medium\npermission_mode=\n", .after = current },
        .{ .text = current, .after = current },
        .{ .text = "version=1\nstore=\nprovider=\nmodel=pin\n", .after = "version=1\nstore=\nprovider=\nmodel=pin\n", .outcome = error.SavedPreferenceProviderRequired },
        .{ .text = "version=1\nstore=relative\nprovider=codex\nmodel=\n", .after = "version=1\nstore=relative\nprovider=codex\nmodel=\n", .outcome = error.SavedPreferenceStoreInvalid },
        .{ .text = "version=3\nstore=\nconnection=chatgpt\nmodel=gpt-6.2-sol\nnotifications=on\nreasoning_effort=medium\n", .after = current },
        .{ .text = "version=2\nstore=\nprovider=codex\nmodel=\n", .after = "version=2\nstore=\nprovider=codex\nmodel=\n", .outcome = error.InvalidPreferences },
        .{ .text = "version=9\n", .after = "version=9\n", .outcome = error.UnsupportedPreferencesVersion },
    };
    for (cases) |case| {
        const file = try config.createFile(io, "preferences", .{ .permissions = .fromMode(0o600) });
        try file.writeStreamingAll(io, case.text);
        file.close(io);
        for (0..2) |_| {
            if (case.outcome) |_| {
                const loaded = try load(home);
                try std.testing.expect(loaded.provider.eql("chatgpt") and loaded.model.eql("gpt-6.2-sol") and loaded.reasoning_effort == .medium and loaded.notifications);
            } else |expected| try std.testing.expectError(expected, load(home));
            var bytes: [256]u8 = undefined;
            try std.testing.expectEqualStrings(case.after, try savedFile(config, &bytes));
        }
    }
}

test "new Session permissions use no file then saved ask or bypass with either flag winning" {
    const configure_input = @import("configure_input.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = home_buffer[0..try tmp.dir.realPath(io, &home_buffer)];
    for ([_]?PermissionMode{ null, .ask, .bypass }) |saved| {
        if (saved) |mode| _ = try update(home, .{ .permission_mode = .{ .set = mode } }, &.initFill(.configured));
        const values = try load(home);
        for ([_]?PermissionMode{ null, .ask, .bypass }) |flag| {
            var input: configure_input.ConfigureInput = .{ .store = "", .session = .create, .permission_mode = if (flag) |mode| .{ .present = true, .value = @tagName(mode) } else .{} };
            input.applySavedCreation(values.reasoning_effort, values.permission_mode);
            try std.testing.expectEqual(flag != null, input.permission_mode.present);
            if (flag) |mode| try std.testing.expectEqualStrings(@tagName(mode), input.permission_mode.value);
            try std.testing.expectEqual(saved, input.preferences.permission_mode);
        }
    }
}

fn savedFile(config: std.Io.Dir, buffer: []u8) ![]const u8 {
    const file = try config.openFile(io, "preferences", .{});
    defer file.close(io);
    return buffer[0..try file.readPositionalAll(io, buffer, 0)];
}

test "preference edits persist explicit choices rather than recommendations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &home_buffer);
    const home = home_buffer[0..len];
    _ = try fillProviderAfterLogin(home, .codex);
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
        .{ "codex", "gpt-6-luna", Edit{ .provider = .{ .set = "chatgpt" } }, "chatgpt", "gpt-6-luna" },
        .{ "chatgpt", "gpt-6-luna", Edit{ .provider = .{ .set = "codex" } }, "codex", "gpt-6-luna" },
        .{ "codex", "gpt-6-luna", Edit{ .provider = .{ .set = "openai" } }, "openai", "" },
        .{ "openai", "gpt-6-luna", Edit{ .provider = .{ .set = "chatgpt" } }, "chatgpt", "" },
    };
    inline for (cases) |case| {
        const file = try config.createFile(io, "preferences", .{ .permissions = .fromMode(0o600) });
        try file.writeStreamingAll(io, "version=1\nstore=\nprovider=" ++ case[0] ++ "\nmodel=" ++ case[1] ++ "\n");
        file.close(io);
        const result = try update(home, case[2], &codexOnly(.configured));
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
    const before = try update(home, .{ .store = .{ .set = old }, .provider = .{ .set = "codex" }, .model = .{ .set = "gpt-6-luna" } }, &codexOnly(.missing));
    try tmp.dir.deleteDir(io, "old");
    try std.testing.expectEqualStrings(old, (try load(home)).store.slice());
    const cleared = try update(home, .{ .model = .clear }, &codexOnly(.configured));
    try std.testing.expect(cleared.store.eql(before.store.slice()) and cleared.model.len == 0);
    const independent = try update(home, .{ .model = .{ .set = "explicit-model" } }, &codexOnly(.missing));
    try std.testing.expect(independent.store.eql(old) and independent.model.eql("explicit-model"));
    try std.testing.expectError(error.InvalidPreferenceStore, update(home, .{ .store = .{ .set = old }, .model = .clear }, &codexOnly(.configured)));
    try std.testing.expect((try load(home)).model.eql("explicit-model"));
    const repaired = try update(home, .{ .store = .{ .set = replacement }, .model = .clear }, &codexOnly(.missing));
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
    _ = try update(home, .{ .provider = .{ .set = "codex" } }, &codexOnly(.missing));
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
    try std.testing.expectEqual(@as(c_int, 0), std.c.fchmod(config.handle, 0o750));
    _ = try update(home, .{ .model = .{ .set = "explicit-pin" } }, &codexOnly(.missing));
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o750), (try config.stat(io)).permissions.toMode() & 0o777);
    try std.testing.expectEqual(@as(c_int, 0), std.c.fchmod(private.handle, 0o755));
    defer _ = std.c.fchmod(private.handle, 0o700);
    try std.testing.expectError(error.InsecurePreferenceDirectory, update(home, .{ .model = .clear }, &codexOnly(.configured)));
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
    try std.testing.expectEqual(LoginDefault.filled, try fillProviderAfterLogin(home, .codex));
    try std.testing.expect((try load(home)).provider.eql("codex"));
    _ = try update(home, .{ .model = .{ .set = "family=variant" } }, &codexOnly(.missing));
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
                _ = try fillProviderAfterLogin(self.home, .codex);
            } else _ = try update(self.home, .{ .provider = .{ .set = "codex" }, .model = .{ .set = "deliberate-pin" } }, &codexOnly(.missing));
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

test "any built-in provider can be saved, and a model alone needs one ready provider" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = home_buffer[0..try tmp.dir.realPath(io, &home_buffer)];
    const both: Readinesses = .initFill(.configured);
    try std.testing.expectError(error.UnsupportedPreferenceProvider, update(home, .{ .provider = .{ .set = "claude" } }, &both));
    try std.testing.expectError(error.PreferenceProviderRequired, update(home, .{ .model = .{ .set = "gpt-6-luna" } }, &both));
    const saved = try update(home, .{ .provider = .{ .set = "openai" }, .model = .{ .set = "gpt-6-luna" } }, &both);
    try std.testing.expect(saved.provider.eql("openai") and saved.model.eql("gpt-6-luna"));
    try std.testing.expectEqual(LoginDefault.kept, try fillProviderAfterLogin(home, .codex));
    try std.testing.expect((try load(home)).provider.eql("openai"));
}

pub fn loginDefaultFailureReason(err: @import("error_set.zig").Of(fillProviderAfterLogin)) []const u8 {
    switch (err) {
        error.SavedPreferenceStoreInvalid => return "InvalidPreferenceStore",
        error.SavedPreferenceProviderInvalid => return "InvalidPreferenceProvider",
        error.SavedPreferenceModelInvalid => return "InvalidPreferenceModel",
        error.SavedPreferenceProviderRequired => return "PreferenceProviderRequired",
        else => {},
    }
    inline for (@typeInfo(@TypeOf(err)).error_set.error_names.?) |name| {
        if (err == @field(anyerror, name)) return name;
    }
    unreachable;
}

test "saved invalid preference fields are environment failures and never get overwritten" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_bytes: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home_len = try tmp.dir.realPath(io, &home_bytes);
    const home = home_bytes[0..home_len];
    _ = try update(home, .{ .provider = .{ .set = "codex" } }, &codexOnly(.configured));
    var config = try tmp.dir.openDir(io, ".config/rui", .{});
    defer config.close(io);
    const Case = struct { text: []const u8, err: anyerror, legacy: []const u8 };
    const cases = [_]Case{
        .{ .text = "version=1\nstore=relative\nprovider=codex\nmodel=\n", .err = error.SavedPreferenceStoreInvalid, .legacy = "InvalidPreferenceStore" },
        .{ .text = "version=1\nstore=\nprovider=bad provider\nmodel=\n", .err = error.SavedPreferenceProviderInvalid, .legacy = "InvalidPreferenceProvider" },
        .{ .text = "version=1\nstore=\nprovider=codex\nmodel=two words\n", .err = error.SavedPreferenceModelInvalid, .legacy = "InvalidPreferenceModel" },
        .{ .text = "version=1\nstore=\nprovider=\nmodel=pin\n", .err = error.SavedPreferenceProviderRequired, .legacy = "PreferenceProviderRequired" },
    };
    for (cases) |case| {
        const invalid = case.text;
        const file = try config.createFile(io, "preferences", .{ .permissions = .fromMode(0o600) });
        try file.writeStreamingAll(io, invalid);
        file.close(io);
        try std.testing.expectError(case.err, load(home));
        try std.testing.expectError(case.err, update(home, .{ .notifications = false }, &codexOnly(.configured)));
        const saved_failure = fillProviderAfterLogin(home, .codex);
        if (saved_failure) |_| return error.ExpectedRefusal else |err| {
            try std.testing.expectEqualStrings(case.legacy, loginDefaultFailureReason(err));
        }
        var saved: [512]u8 = undefined;
        try std.testing.expectEqualStrings(invalid, try savedFile(config, &saved));
    }
}

test "CLI-27 updates publish the encoded preference document" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = home_buffer[0..try tmp.dir.realPath(io, &home_buffer)];
    const readiness: Readinesses = .initFill(.configured);
    const edits = [_]Edit{
        .{ .provider = .{ .set = "codex" }, .model = .{ .set = "gpt-6-luna" } },
        .{ .notifications = false },
        .{ .reasoning_effort = .{ .set = .high } },
        .{ .permission_mode = .{ .set = .ask } },
    };
    for (edits) |edit| {
        const written = try update(home, edit, &readiness);
        var config = try tmp.dir.openDir(io, ".config/rui", .{});
        defer config.close(io);
        var expected: [document.max_file_bytes]u8 = undefined;
        var actual: [document.max_file_bytes]u8 = undefined;
        try std.testing.expectEqualStrings(try document.encode(&written, &expected), try savedFile(config, &actual));
    }
}
