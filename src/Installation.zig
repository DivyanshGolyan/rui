const std = @import("std");
const client = @import("client.zig");
const releases = @import("release_candidate.zig");
const process = @import("upgrade_process.zig");
const Dir = std.Io.Dir;
const Allocator = std.mem.Allocator;
const TerminalText = @import("TerminalText.zig");
const stderr = @import("stderr.zig");

pub const Released = struct { build: []const u8, version: releases.Version };
pub const Selection = union(enum) {
    absent,
    ineligible,
    source: []const u8,
    unknown_managed: []const u8,
    released: Released,

    pub fn deinit(self: *Selection, allocator: Allocator) void {
        switch (self.*) {
            .released => |released| allocator.free(released.build),
            .source, .unknown_managed => |build| allocator.free(build),
            .absent, .ineligible => {},
        }
        self.* = undefined;
    }
};

pub const Intent = enum { released_upgrade, released_install, intentional_source };
pub const Receipt = struct { operation_build: []const u8, selected_after: []const u8 };
pub const InstallationOutcome = union(enum) {
    installed: Receipt,
    unchanged: Receipt,

    pub fn receipt(self: InstallationOutcome) Receipt {
        return switch (self) {
            inline else => |value| value,
        };
    }

    pub fn deinit(self: *InstallationOutcome, allocator: Allocator) void {
        const value = self.receipt();
        allocator.free(value.operation_build);
        allocator.free(value.selected_after);
        self.* = undefined;
    }
};

pub const CleanupFailure = struct {
    primary: ?anyerror,
    secondary: anyerror,
    /// Borrowed only until the synchronous reporter returns.
    retained_path: []const u8,
};

pub const CleanupReporter = struct {
    context: ?*anyopaque = null,
    report: *const fn (?*anyopaque, CleanupFailure) void = diagnosticCleanup,

    fn emit(self: CleanupReporter, failure: CleanupFailure) void {
        self.report(self.context, failure);
    }
};

pub fn writeCleanupFailure(writer: *std.Io.Writer, failure: CleanupFailure) !void {
    if (failure.primary) |primary| {
        try writer.print("\nrui: installation failed ({s}); cleanup also failed ({s}). Retained installation files: ", .{ @errorName(primary), @errorName(failure.secondary) });
    } else {
        try writer.print("\nrui: installation cleanup failed ({s}). Retained installation files: ", .{@errorName(failure.secondary)});
    }
    try TerminalText.writeShellWord(writer, failure.retained_path);
    try writer.writeAll(". Inspect or remove this path before retrying. Cleanup did not change the selected command.\n");
}

fn diagnosticCleanup(_: ?*anyopaque, failure: CleanupFailure) void {
    const Output = struct {
        fn drain(writer: *std.Io.Writer, parts: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            if (!stderr.writeHeld(writer.buffered())) return error.WriteFailed;
            writer.end = 0;
            var count: usize = 0;
            for (parts[0 .. parts.len - 1]) |part| {
                if (!stderr.writeHeld(part)) return error.WriteFailed;
                count += part.len;
            }
            for (0..splat) |_| {
                const part = parts[parts.len - 1];
                if (!stderr.writeHeld(part)) return error.WriteFailed;
                count += part.len;
            }
            return count;
        }
    };
    if (!stderr.tryAcquire()) return;
    defer stderr.release();
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .{ .vtable = &.{ .drain = Output.drain }, .buffer = &buffer };
    writeCleanupFailure(&writer, failure) catch return;
    writer.flush() catch return;
}

const CleanupFaults = struct {
    remove_tree: ?anyerror = null,
    remove_link: ?anyerror = null,
};

fn removeTree(io: std.Io, directory: []const u8, faults: CleanupFaults) !void {
    if (faults.remove_tree) |err| return err;
    try Dir.cwd().deleteTree(io, directory);
}

fn removeLink(io: std.Io, prefix: Dir, name: []const u8, faults: CleanupFaults) !void {
    if (faults.remove_link) |err| return err;
    try prefix.deleteFile(io, name);
}

pub const PreparedBuild = struct {
    path: []const u8,
    version: ?releases.Version,
    published: bool = false,

    pub fn dispose(self: *PreparedBuild, allocator: Allocator, io: std.Io) !void {
        return self.disposeWithReporter(allocator, io, .{});
    }

    pub fn disposeWithReporter(self: *PreparedBuild, allocator: Allocator, io: std.Io, reporter: CleanupReporter) !void {
        if (self.disposeResult(allocator, io, null, reporter, .{})) |err| return err;
    }

    fn disposeResult(self: *PreparedBuild, allocator: Allocator, io: std.Io, primary: ?anyerror, reporter: CleanupReporter, faults: CleanupFaults) ?anyerror {
        defer {
            allocator.free(self.path);
            self.* = undefined;
        }
        if (!self.published) removeTree(io, self.path, faults) catch |secondary| {
            reporter.emit(.{ .primary = primary, .secondary = secondary, .retained_path = self.path });
            return primary orelse secondary;
        };
        return primary;
    }
};

fn path(allocator: Allocator, home: []const u8, suffix: []const u8) ![]u8 {
    if (!std.fs.path.isAbsolute(home)) return error.InvalidInstallationHome;
    return std.fmt.allocPrint(allocator, "{s}/.local/{s}", .{ home, suffix });
}

fn regular(io: std.Io, name: []const u8, executable: bool) !bool {
    const stat = Dir.cwd().statFile(io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return false,
        else => return err,
    };
    return stat.kind == .file and (!executable or stat.permissions.toMode() & 0o111 != 0);
}

pub fn executableVersion(allocator: Allocator, io: std.Io, binary: []const u8, cancellation: ?*const client.Cancellation) !?releases.Version {
    const output = try process.output(allocator, io, &.{ binary, "--version" }, cancellation, 1024);
    defer allocator.free(output);
    const line = std.mem.trimEnd(u8, output, "\n");
    if (!std.mem.startsWith(u8, line, "rui ") or !std.mem.endsWith(u8, line, ")")) return null;
    const end = std.mem.indexOf(u8, line[4..], " (") orelse return null;
    return releases.Version.parse(line[4..][0..end]) catch null;
}

fn managedBuild(allocator: Allocator, io: std.Io, home: []const u8, build: []const u8) ![]u8 {
    const root = try path(allocator, home, "lib/rui");
    defer allocator.free(root);
    const physical_root = try Dir.cwd().realPathFileAlloc(io, root, allocator);
    defer allocator.free(physical_root);
    const physical = try Dir.cwd().realPathFileAlloc(io, build, allocator);
    defer allocator.free(physical);
    const parent = std.fs.path.dirname(physical) orelse return error.InvalidManagedBuild;
    if (!std.mem.eql(u8, parent, physical_root)) return error.InvalidManagedBuild;
    const binary = try std.fmt.allocPrint(allocator, "{s}/bin/rui", .{physical});
    defer allocator.free(binary);
    const bin = try std.fmt.allocPrint(allocator, "{s}/bin", .{physical});
    defer allocator.free(bin);
    const stat = try Dir.cwd().statFile(io, bin, .{ .follow_symlinks = false });
    if (stat.kind != .directory or !try regular(io, binary, true)) return error.InvalidManagedBuild;
    return allocator.dupe(u8, physical);
}

fn noticesPresent(allocator: Allocator, io: std.Io, build: []const u8) !bool {
    const notices = try std.fmt.allocPrint(allocator, "{s}/THIRD_PARTY_NOTICES.md", .{build});
    defer allocator.free(notices);
    return regular(io, notices, false);
}

pub fn inspect(allocator: Allocator, io: std.Io, home: []const u8) !Selection {
    return inspectCancellable(allocator, io, home, null);
}

pub fn inspectCancellable(allocator: Allocator, io: std.Io, home: []const u8, cancellation: ?*const client.Cancellation) !Selection {
    try process.check(cancellation);
    const link = try path(allocator, home, "bin/rui");
    defer allocator.free(link);
    const stat = Dir.cwd().statFile(io, link, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return .absent,
        error.NotDir => return .ineligible,
        else => return err,
    };
    if (stat.kind != .sym_link) return .ineligible;
    const target = Dir.cwd().realPathFileAlloc(io, link, allocator) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.SymLinkLoop => return .ineligible,
        else => return err,
    };
    defer allocator.free(target);
    if (!std.mem.endsWith(u8, target, "/bin/rui")) return .ineligible;
    return inspectBuild(allocator, io, home, target[0 .. target.len - "/bin/rui".len], cancellation);
}

pub fn inspectBuild(allocator: Allocator, io: std.Io, home: []const u8, directory: []const u8, cancellation: ?*const client.Cancellation) !Selection {
    try process.check(cancellation);
    const build = managedBuild(allocator, io, home, directory) catch |err| switch (err) {
        error.InvalidManagedBuild, error.FileNotFound, error.NotDir, error.SymLinkLoop => return .ineligible,
        else => return err,
    };
    errdefer allocator.free(build);
    const revision = try std.fmt.allocPrint(allocator, "{s}/revision", .{build});
    defer allocator.free(revision);
    if (Dir.cwd().statFile(io, revision, .{ .follow_symlinks = false })) |_| {
        return .{ .source = build };
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    if (!try noticesPresent(allocator, io, build)) return .{ .unknown_managed = build };
    const binary = try std.fmt.allocPrint(allocator, "{s}/bin/rui", .{build});
    defer allocator.free(binary);
    const version = executableVersion(allocator, io, binary, cancellation) catch |err| switch (err) {
        error.UpgradeChildFailed, error.StreamTooLong, error.Timeout => null,
        else => return err,
    };
    if (version) |value| return .{ .released = .{ .build = build, .version = value } };
    return .{ .unknown_managed = build };
}

fn managedPath(selection: Selection) ![]const u8 {
    return switch (selection) {
        .released => |released| released.build,
        .source, .unknown_managed => |build| build,
        .absent, .ineligible => error.InvalidManagedBuild,
    };
}

fn newStage(allocator: Allocator, io: std.Io, home: []const u8) ![]u8 {
    const root = try path(allocator, home, "lib/rui");
    defer allocator.free(root);
    try Dir.cwd().createDirPath(io, root);
    while (true) {
        var random: [16]u8 = undefined;
        io.random(&random);
        const stage = try std.fmt.allocPrint(allocator, "{s}/install.{s}", .{ root, std.fmt.bytesToHex(&random, .lower) });
        if (Dir.cwd().createDir(io, stage, .fromMode(0o700))) |_| return stage else |err| {
            allocator.free(stage);
            if (err != error.PathAlreadyExists) return err;
        }
    }
}

pub fn prepare(allocator: Allocator, io: std.Io, home: []const u8, candidate: *const releases.ReleaseCandidate, cancellation: ?*const client.Cancellation) !PreparedBuild {
    return prepareWithReporter(allocator, io, home, candidate, cancellation, .{});
}

pub fn prepareWithReporter(allocator: Allocator, io: std.Io, home: []const u8, candidate: *const releases.ReleaseCandidate, cancellation: ?*const client.Cancellation, reporter: CleanupReporter) !PreparedBuild {
    return prepareWithCleanup(allocator, io, home, candidate, cancellation, reporter, .{});
}

fn prepareWithCleanup(allocator: Allocator, io: std.Io, home: []const u8, candidate: *const releases.ReleaseCandidate, cancellation: ?*const client.Cancellation, reporter: CleanupReporter, faults: CleanupFaults) !PreparedBuild {
    try process.check(cancellation);
    var prepared: PreparedBuild = .{ .path = try newStage(allocator, io, home), .version = candidate.version };
    prepareInto(allocator, io, &prepared, candidate, cancellation) catch |primary| {
        return prepared.disposeResult(allocator, io, primary, reporter, faults).?;
    };
    return prepared;
}

fn prepareInto(allocator: Allocator, io: std.Io, prepared: *PreparedBuild, candidate: *const releases.ReleaseCandidate, cancellation: ?*const client.Cancellation) !void {
    const archive = try std.fmt.allocPrint(allocator, "{s}/archive.tar.gz", .{prepared.path});
    defer allocator.free(archive);
    const fixture = std.mem.startsWith(u8, candidate.archive_url, "http://");
    const output = try process.output(allocator, io, &.{
        "curl",         "--fail",                  "--silent",            "--show-error",                     "--location",    "--connect-timeout", "10",             "--max-time", "300",
        "--max-redirs", if (fixture) "0" else "5", "--proto",             if (fixture) "=http" else "=https", "--proto-redir", "=https",            "--max-filesize", "268435456",  "--output",
        archive,        "--",                      candidate.archive_url,
    }, cancellation, 1024);
    allocator.free(output);
    try verifyArchive(allocator, io, prepared, candidate, cancellation, archive);
}

const ArchiveReader = struct {
    source: *std.Io.Reader,
    cancellation: ?*const client.Cancellation,
    remaining: usize,
    failure: ?anyerror = null,
    interface: std.Io.Reader,

    fn init(source: *std.Io.Reader, cancellation: ?*const client.Cancellation, buffer: []u8, remaining: usize) ArchiveReader {
        return .{ .source = source, .cancellation = cancellation, .remaining = remaining, .interface = .{ .vtable = &.{ .stream = stream }, .buffer = buffer, .seek = 0, .end = 0 } };
    }

    fn stream(reader: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *ArchiveReader = @fieldParentPtr("interface", reader);
        process.check(self.cancellation) catch |err| {
            self.failure = err;
            return error.ReadFailed;
        };
        if (self.remaining == 0) {
            self.failure = error.ReleaseArchiveTooLarge;
            return error.ReadFailed;
        }
        const count = try self.source.stream(writer, limit.min(.limited(@min(self.remaining, 65536))));
        self.remaining -= count;
        return count;
    }
};

fn verifyArchive(allocator: Allocator, io: std.Io, prepared: *PreparedBuild, candidate: *const releases.ReleaseCandidate, cancellation: ?*const client.Cancellation, archive: []const u8) !void {
    var file = try Dir.cwd().openFile(io, archive, .{});
    defer file.close(io);
    const scratch = try allocator.alloc(u8, 65536);
    defer allocator.free(scratch);
    var hash: std.crypto.hash.sha2.Sha256 = .init(.{});
    var offset: u64 = 0;
    while (true) {
        try process.check(cancellation);
        const count = try file.readPositional(io, &.{scratch}, offset);
        if (count == 0) break;
        hash.update(scratch[0..count]);
        offset += count;
        if (offset > 256 * 1024 * 1024) return error.ReleaseArchiveTooLarge;
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    if (!std.mem.eql(u8, &digest, &candidate.sha256)) return error.ReleaseChecksumMismatch;
    var reader = file.reader(io, scratch);
    const decompressor = try allocator.create(std.compress.flate.Decompress);
    defer allocator.destroy(decompressor);
    const window = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(window);
    decompressor.* = .init(&reader.interface, .gzip, window);
    const root = candidate.archive_name[0 .. candidate.archive_name.len - ".tar.gz".len];
    const archive_buffer = try allocator.alloc(u8, 4096);
    defer allocator.free(archive_buffer);
    var guarded: ArchiveReader = .init(&decompressor.reader, cancellation, archive_buffer, 1024 * 1024 * 1024 + 4 * 1024 * 1024);
    extract(allocator, io, prepared.path, root, &guarded.interface, cancellation) catch |err| return guarded.failure orelse err;
    try Dir.cwd().deleteFile(io, archive);
    const binary = try std.fmt.allocPrint(allocator, "{s}/bin/rui", .{prepared.path});
    defer allocator.free(binary);
    const notices = try std.fmt.allocPrint(allocator, "{s}/THIRD_PARTY_NOTICES.md", .{prepared.path});
    defer allocator.free(notices);
    if (!try regular(io, binary, true) or !try regular(io, notices, false)) return error.InvalidManagedBuild;
    const version = (try executableVersion(allocator, io, binary, cancellation)) orelse return error.InvalidReleaseExecutable;
    if (version.order(candidate.version) != .eq) return error.ReleaseExecutableVersionMismatch;
}

fn relativeEntry(name: []const u8, root: []const u8) ![]const u8 {
    const trimmed = std.mem.trimEnd(u8, name, "/");
    if (std.mem.eql(u8, trimmed, root)) return "";
    if (!std.mem.startsWith(u8, trimmed, root) or trimmed.len <= root.len or trimmed[root.len] != '/') return error.UnsafeReleaseArchive;
    const relative = trimmed[root.len + 1 ..];
    var parts = std.mem.splitScalar(u8, relative, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.UnsafeReleaseArchive;
        for (part) |byte| if (byte < 0x20 or byte == 0x7f or byte == '\\') return error.UnsafeReleaseArchive;
    }
    return relative;
}

fn extract(allocator: Allocator, io: std.Io, destination: []const u8, root: []const u8, reader: *std.Io.Reader, cancellation: ?*const client.Cancellation) !void {
    const names = try allocator.alloc(u8, 2 * Dir.max_path_bytes);
    defer allocator.free(names);
    const buffer = try allocator.alloc(u8, 65536);
    defer allocator.free(buffer);
    var iterator: std.tar.Iterator = .init(reader, .{ .file_name_buffer = names[0..Dir.max_path_bytes], .link_name_buffer = names[Dir.max_path_bytes..] });
    var directory = try Dir.cwd().openDir(io, destination, .{});
    defer directory.close(io);
    var total: u64 = 0;
    var entries: usize = 0;
    while (try iterator.next()) |entry| {
        try process.check(cancellation);
        entries += 1;
        total = std.math.add(u64, total, entry.size) catch return error.ReleaseArchiveTooLarge;
        if (total > 1024 * 1024 * 1024 or entries > 4096) return error.ReleaseArchiveTooLarge;
        if (entry.kind == .file and entry.name.len == root.len + 2 and std.mem.startsWith(u8, entry.name, "._") and std.mem.eql(u8, entry.name[2..], root)) continue;
        const relative = try relativeEntry(entry.name, root);
        if (entry.kind == .sym_link) return error.UnsafeReleaseArchive;
        if (relative.len == 0) {
            if (entry.kind != .directory) return error.UnsafeReleaseArchive;
            continue;
        }
        if (entry.kind == .directory) {
            try directory.createDirPath(io, relative);
            continue;
        }
        if (std.fs.path.dirname(relative)) |parent| try directory.createDirPath(io, parent);
        const extracted = try directory.createFile(io, relative, .{ .exclusive = true, .permissions = .fromMode(if (entry.mode & 0o111 != 0) 0o700 else 0o600) });
        defer extracted.close(io);
        var writer = extracted.writer(io, buffer);
        var remaining = entry.size;
        while (remaining != 0) {
            try process.check(cancellation);
            const count = @min(remaining, 65536);
            try reader.streamExact64(&writer.interface, count);
            remaining -= count;
        }
        iterator.unread_file_bytes = 0;
        try writer.interface.flush();
    }
}

fn openLock(io: std.Io, prefix: Dir) !std.Io.File {
    while (true) {
        return prefix.openFile(io, ".rui-install.lock", .{ .mode = .read_write, .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => prefix.createFile(io, ".rui-install.lock", .{ .read = true, .exclusive = true, .permissions = .fromMode(0o600) }) catch |create_err| switch (create_err) {
                error.PathAlreadyExists => continue,
                else => return create_err,
            },
            else => return err,
        };
    }
}

pub fn publishExisting(allocator: Allocator, io: std.Io, home: []const u8, build: []const u8, intent: Intent, cancellation: ?*const client.Cancellation) !InstallationOutcome {
    var kind = try inspectBuild(allocator, io, home, build, cancellation);
    defer kind.deinit(allocator);
    const physical = try managedPath(kind);
    const binary = try std.fmt.allocPrint(allocator, "{s}/bin/rui", .{physical});
    defer allocator.free(binary);
    const version = if (kind == .released) kind.released.version else null;
    if (intent == .intentional_source) {
        const help = try process.output(allocator, io, &.{ binary, "--help" }, cancellation, 65536);
        allocator.free(help);
    }
    if (intent != .intentional_source and version == null) return error.InvalidReleaseExecutable;
    var prepared: PreparedBuild = .{ .path = physical, .version = version };
    return publish(allocator, io, home, &prepared, intent, cancellation);
}

pub fn publish(allocator: Allocator, io: std.Io, home: []const u8, prepared: *PreparedBuild, intent: Intent, cancellation: ?*const client.Cancellation) !InstallationOutcome {
    return publishWithReporter(allocator, io, home, prepared, intent, cancellation, .{});
}

pub fn publishWithReporter(allocator: Allocator, io: std.Io, home: []const u8, prepared: *PreparedBuild, intent: Intent, cancellation: ?*const client.Cancellation, reporter: CleanupReporter) !InstallationOutcome {
    return publishWithCleanup(allocator, io, home, prepared, intent, cancellation, reporter, .{});
}

fn publishWithCleanup(allocator: Allocator, io: std.Io, home: []const u8, prepared: *PreparedBuild, intent: Intent, cancellation: ?*const client.Cancellation, reporter: CleanupReporter, faults: CleanupFaults) !InstallationOutcome {
    try process.check(cancellation);
    const prefix_path = try path(allocator, home, "");
    defer allocator.free(prefix_path);
    var prefix = try Dir.cwd().openDir(io, prefix_path, .{});
    defer prefix.close(io);
    const lock = try openLock(io, prefix);
    defer lock.close(io);
    while (!try lock.tryLock(io, .exclusive)) {
        try process.check(cancellation);
        try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    }
    defer lock.unlock(io);
    try process.check(cancellation);
    var candidate = try inspectBuild(allocator, io, home, prepared.path, cancellation);
    defer candidate.deinit(allocator);
    const complete = try managedPath(candidate);
    if (!try noticesPresent(allocator, io, complete)) return error.InvalidManagedBuild;
    if (intent != .intentional_source) {
        if (candidate != .released) return error.InvalidReleaseExecutable;
        const expected = prepared.version orelse return error.InvalidReleaseExecutable;
        if (candidate.released.version.order(expected) != .eq) return error.ReleaseExecutableVersionMismatch;
    }
    var selection = try inspectCancellable(allocator, io, home, cancellation);
    defer selection.deinit(allocator);
    if (intent != .intentional_source) {
        const version = prepared.version orelse return error.InvalidReleaseExecutable;
        switch (selection) {
            .ineligible => return error.IneligibleInstallation,
            .source, .unknown_managed => if (intent == .released_upgrade) return error.IneligibleInstallation,
            .absent => if (intent == .released_upgrade) return error.IneligibleInstallation,
            .released => |selected| if (version.order(selected.version) != .gt) {
                if (std.mem.eql(u8, complete, selected.build)) prepared.published = true;
                const operation = try allocator.dupe(u8, complete);
                errdefer allocator.free(operation);
                return .{ .unchanged = .{ .operation_build = operation, .selected_after = try allocator.dupe(u8, selected.build) } };
            },
        }
    }
    try prefix.createDirPath(io, "bin");
    const binary = try std.fmt.allocPrint(allocator, "{s}/bin/rui", .{complete});
    defer allocator.free(binary);
    const operation = try allocator.dupe(u8, complete);
    errdefer allocator.free(operation);
    const selected = try allocator.dupe(u8, complete);
    errdefer allocator.free(selected);
    var random: [16]u8 = undefined;
    io.random(&random);
    const temporary = try std.fmt.allocPrint(allocator, "bin/.rui-install-{s}", .{std.fmt.bytesToHex(&random, .lower)});
    defer allocator.free(temporary);
    const temporary_path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix_path, temporary });
    defer allocator.free(temporary_path);
    try process.check(cancellation);
    try prefix.symLink(io, binary, temporary, .{});
    prefix.rename(temporary, prefix, "bin/rui", io) catch |primary| {
        removeLink(io, prefix, temporary, faults) catch |secondary| {
            reporter.emit(.{ .primary = primary, .secondary = secondary, .retained_path = temporary_path });
        };
        return primary;
    };
    prepared.published = true;
    return .{ .installed = .{ .operation_build = operation, .selected_after = selected } };
}

test "release archive entries cannot leave their single root" {
    try std.testing.expectEqualStrings("bin/rui", try relativeEntry("rui-0.56.0/bin/rui", "rui-0.56.0"));
    for ([_][]const u8{ "/rui-0.56.0/bin/rui", "rui-0.56.0/../escape", "rui-0.56.0/bin/./rui", "rui-0.56.0x/bin/rui", "rui-0.56.0/bin//rui", "rui-0.56.0/bin/ru\x1bi" }) |bad| try std.testing.expectError(error.UnsafeReleaseArchive, relativeEntry(bad, "rui-0.56.0"));
}

fn testBuild(allocator: Allocator, io: std.Io, home: []const u8, name: []const u8, label: []const u8) ![]u8 {
    const build = try std.fmt.allocPrint(allocator, "{s}/.local/lib/rui/{s}", .{ home, name });
    errdefer allocator.free(build);
    const bin = try std.fmt.allocPrint(allocator, "{s}/bin", .{build});
    defer allocator.free(bin);
    try Dir.cwd().createDirPath(io, bin);
    var dir = try Dir.cwd().openDir(io, build, .{});
    defer dir.close(io);
    const script = try std.fmt.allocPrint(allocator, "#!/bin/sh\nprintf '%s\\n' 'rui {s} (fixture)'\n", .{label});
    defer allocator.free(script);
    try dir.writeFile(io, .{ .sub_path = "bin/rui", .data = script, .flags = .{ .permissions = .fromMode(0o700) } });
    try dir.writeFile(io, .{ .sub_path = "THIRD_PARTY_NOTICES.md", .data = "Fixture notices\n" });
    return build;
}

test "installation native owner serializes release no-downgrade and intentional source replacement" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const home = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(home);
    const newer = try testBuild(allocator, io, home, "newer", "0.56.10");
    defer allocator.free(newer);
    const older = try testBuild(allocator, io, home, "older", "0.56.2");
    defer allocator.free(older);
    var first = try publishExisting(allocator, io, home, newer, .released_install, null);
    defer first.deinit(allocator);
    try std.testing.expect(first == .installed);
    var second = try publishExisting(allocator, io, home, older, .released_upgrade, null);
    defer second.deinit(allocator);
    try std.testing.expect(second == .unchanged);
    try std.testing.expectEqualStrings(older, second.receipt().operation_build);
    try std.testing.expectEqualStrings(newer, second.receipt().selected_after);
    var equal = try publishExisting(allocator, io, home, newer, .released_upgrade, null);
    defer equal.deinit(allocator);
    try std.testing.expect(equal == .unchanged);
    const source = try testBuild(allocator, io, home, "source", "unreleased");
    defer allocator.free(source);
    var explicit = try publishExisting(allocator, io, home, source, .intentional_source, null);
    defer explicit.deinit(allocator);
    try std.testing.expect(explicit == .installed);
    try std.testing.expectError(error.IneligibleInstallation, publishExisting(allocator, io, home, newer, .released_upgrade, null));
}

test "installation publication rechecks broken unmanaged and absent selections" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const home = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(home);
    const build = try testBuild(allocator, io, home, "candidate", "0.56.0");
    defer allocator.free(build);
    try std.testing.expectError(error.IneligibleInstallation, publishExisting(allocator, io, home, build, .released_upgrade, null));
    try temporary.dir.createDirPath(io, ".local/bin");
    try temporary.dir.symLink(io, "/nonexistent/rui", ".local/bin/rui", .{});
    try std.testing.expectError(error.IneligibleInstallation, publishExisting(allocator, io, home, build, .released_install, null));
    try temporary.dir.deleteFile(io, ".local/bin/rui");
    try temporary.dir.writeFile(io, .{ .sub_path = ".local/bin/rui", .data = "unmanaged" });
    try std.testing.expectError(error.IneligibleInstallation, publishExisting(allocator, io, home, build, .released_upgrade, null));
    try temporary.dir.deleteFile(io, ".local/bin/rui");
    try temporary.dir.createDir(io, ".local/bin/rui", .default_dir);
    try std.testing.expectError(error.IsDir, publishExisting(allocator, io, home, build, .intentional_source, null));
    const stat = try temporary.dir.statFile(io, ".local/bin/rui", .{});
    try std.testing.expectEqual(std.Io.File.Kind.directory, stat.kind);
}

test "installation cancellation before publication leaves selection unchanged" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const home = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(home);
    var token: client.Cancellation = .{};
    token.requestStop();
    var prepared: PreparedBuild = .{ .path = "/never-executed", .version = .{ .schema = 56, .patch = 0 } };
    try std.testing.expectError(error.Cancelled, publish(allocator, io, home, &prepared, .released_install, &token));
    var selection = try inspect(allocator, io, home);
    defer selection.deinit(allocator);
    try std.testing.expect(selection == .absent);
    try std.testing.expectError(error.Cancelled, prepare(allocator, io, home, &.{ .version = .{ .schema = 56, .patch = 0 }, .tag = "v0.56.0", .archive_name = "rui-0.56.0-darwin-arm64.tar.gz", .archive_url = "http://127.0.0.1:1/archive", .checksum_url = "http://127.0.0.1:1/SHA256SUMS", .sha256 = @splat(0) }, &token));
}

const TestPublisher = struct {
    allocator: Allocator,
    io: std.Io,
    home: []const u8,
    build: []const u8,
    intent: Intent,
    start: *std.Io.Event,
    cancellation: ?*const client.Cancellation = null,
    outcome: ?InstallationOutcome = null,
    failure: ?anyerror = null,

    fn run(self: *TestPublisher) void {
        self.start.wait(self.io) catch |err| {
            self.failure = err;
            return;
        };
        self.outcome = publishExisting(self.allocator, self.io, self.home, self.build, self.intent, self.cancellation) catch |err| {
            self.failure = err;
            return;
        };
    }
};

test "installation concurrent release and source writers share final selection authority" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const home = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(home);
    const old = try testBuild(allocator, io, home, "old", "0.55.0");
    defer allocator.free(old);
    const newer = try testBuild(allocator, io, home, "newer", "0.56.0");
    defer allocator.free(newer);
    const newest = try testBuild(allocator, io, home, "newest", "0.57.0");
    defer allocator.free(newest);
    var initial = try publishExisting(allocator, io, home, old, .released_install, null);
    defer initial.deinit(allocator);
    var start: std.Io.Event = .unset;
    var a: TestPublisher = .{ .allocator = allocator, .io = io, .home = home, .build = newer, .intent = .released_upgrade, .start = &start };
    var b: TestPublisher = .{ .allocator = allocator, .io = io, .home = home, .build = newest, .intent = .released_upgrade, .start = &start };
    const first = try std.Thread.spawn(.{}, TestPublisher.run, .{&a});
    const second = try std.Thread.spawn(.{}, TestPublisher.run, .{&b});
    start.set(io);
    first.join();
    second.join();
    if (a.failure) |err| return err;
    if (b.failure) |err| return err;
    defer a.outcome.?.deinit(allocator);
    defer b.outcome.?.deinit(allocator);
    var selected = try inspect(allocator, io, home);
    defer selected.deinit(allocator);
    try std.testing.expectEqualStrings(newest, selected.released.build);
    const source = try testBuild(allocator, io, home, "source", "unreleased");
    defer allocator.free(source);
    start.reset();
    var release_writer: TestPublisher = .{ .allocator = allocator, .io = io, .home = home, .build = newest, .intent = .released_upgrade, .start = &start };
    var source_writer: TestPublisher = .{ .allocator = allocator, .io = io, .home = home, .build = source, .intent = .intentional_source, .start = &start };
    const release_thread = try std.Thread.spawn(.{}, TestPublisher.run, .{&release_writer});
    const source_thread = try std.Thread.spawn(.{}, TestPublisher.run, .{&source_writer});
    start.set(io);
    release_thread.join();
    source_thread.join();
    if (source_writer.failure) |err| return err;
    defer source_writer.outcome.?.deinit(allocator);
    if (release_writer.outcome) |*outcome| outcome.deinit(allocator);
    if (release_writer.failure) |err| try std.testing.expectEqual(error.IneligibleInstallation, err);
    var after = try inspect(allocator, io, home);
    defer after.deinit(allocator);
    try std.testing.expect(after == .unknown_managed);
    const link = try temporary.dir.realPathFileAlloc(io, ".local/bin/rui", allocator);
    defer allocator.free(link);
    try std.testing.expect(std.mem.startsWith(u8, link, source));
}

test "installation archive verifies digest executable notices and traversal before publication" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const home = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(home);
    const root = "rui-0.56.0-darwin-arm64";
    const build = try testBuild(allocator, io, home, root, "0.56.0");
    defer allocator.free(build);
    const archive = try std.fmt.allocPrint(allocator, "{s}/fixture.tar.gz", .{home});
    defer allocator.free(archive);
    const library = try path(allocator, home, "lib/rui");
    defer allocator.free(library);
    const output = try process.output(allocator, io, &.{ "env", "COPYFILE_DISABLE=1", "tar", "-czf", archive, "-C", library, root }, null, 1024);
    allocator.free(output);
    const bytes = try Dir.cwd().readFileAlloc(io, archive, allocator, .limited(1024 * 1024));
    defer allocator.free(bytes);
    var candidate: releases.ReleaseCandidate = .{ .version = .{ .schema = 56, .patch = 0 }, .tag = "v0.56.0", .archive_name = root ++ ".tar.gz", .archive_url = "http://127.0.0.1:1/archive", .checksum_url = "http://127.0.0.1:1/SHA256SUMS", .sha256 = @splat(0) };
    var prepared: PreparedBuild = .{ .path = try newStage(allocator, io, home), .version = candidate.version };
    defer prepared.dispose(allocator, io) catch @panic("fixture cleanup failed");
    try std.testing.expectError(error.ReleaseChecksumMismatch, verifyArchive(allocator, io, &prepared, &candidate, null, archive));
    std.crypto.hash.sha2.Sha256.hash(bytes, &candidate.sha256, .{});
    candidate.version.patch = 1;
    try std.testing.expectError(error.ReleaseExecutableVersionMismatch, verifyArchive(allocator, io, &prepared, &candidate, null, archive));
    var selected = try inspect(allocator, io, home);
    defer selected.deinit(allocator);
    try std.testing.expect(selected == .absent);
    const offline = prepare(allocator, io, home, &candidate, null);
    try std.testing.expectError(error.UpgradeChildFailed, offline);
    try Dir.cwd().writeFile(io, .{ .sub_path = archive, .data = bytes });
    var complete: PreparedBuild = .{ .path = try newStage(allocator, io, home), .version = .{ .schema = 56, .patch = 0 } };
    defer complete.dispose(allocator, io) catch @panic("fixture cleanup failed");
    candidate.version.patch = 0;
    try verifyArchive(allocator, io, &complete, &candidate, null, archive);
    var published = try publish(allocator, io, home, &complete, .released_install, null);
    defer published.deinit(allocator);
    try std.testing.expect(published == .installed);
    try std.testing.expectEqualStrings(complete.path, published.receipt().selected_after);
}

test "installation cancellation interrupts locked selected-build probe without publication" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const home = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(home);
    const candidate = try testBuild(allocator, io, home, "candidate", "0.56.0");
    defer allocator.free(candidate);
    const previous = try testBuild(allocator, io, home, "previous", "0.55.0");
    defer allocator.free(previous);
    const marker = try std.fmt.allocPrint(allocator, "{s}/probe-ready", .{home});
    defer allocator.free(marker);
    const previous_binary = try std.fmt.allocPrint(allocator, "{s}/bin/rui", .{previous});
    defer allocator.free(previous_binary);
    const script = try std.fmt.allocPrint(allocator, "#!/bin/sh\n: > '{s}'\nexec sleep 300\n", .{marker});
    defer allocator.free(script);
    try Dir.cwd().writeFile(io, .{ .sub_path = previous_binary, .data = script, .flags = .{ .permissions = .fromMode(0o700) } });
    try temporary.dir.createDirPath(io, ".local/bin");
    try temporary.dir.symLink(io, previous_binary, ".local/bin/rui", .{});
    var token: client.Cancellation = .{};
    var start: std.Io.Event = .is_set;
    var writer: TestPublisher = .{ .allocator = allocator, .io = io, .home = home, .build = candidate, .intent = .released_upgrade, .start = &start, .cancellation = &token };
    {
        const thread = try std.Thread.spawn(.{}, TestPublisher.run, .{&writer});
        defer thread.join();
        defer token.requestStop();
        const Probe = struct {
            io: std.Io,
            marker: []const u8,
            fn ready(self: @This()) !bool {
                _ = Dir.cwd().statFile(self.io, self.marker, .{}) catch |err| switch (err) {
                    error.FileNotFound => return false,
                    else => return err,
                };
                return true;
            }
        };
        const poll = @import("test_poll");
        try poll.waitUntil(io, poll.after(io, .fromSeconds(5)), Probe{ .io = io, .marker = marker }, Probe.ready);
        token.requestStop();
    }
    try std.testing.expectEqual(error.Cancelled, writer.failure.?);
    try std.testing.expect(writer.outcome == null);
    const selected = try temporary.dir.realPathFileAlloc(io, ".local/bin/rui", allocator);
    defer allocator.free(selected);
    try std.testing.expectEqualStrings(previous_binary, selected);
}

test "installation cancellation after publication never removes the selected build" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const home = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(home);
    const build = try testBuild(allocator, io, home, "complete", "0.56.0");
    var prepared: PreparedBuild = .{ .path = build, .version = .{ .schema = 56, .patch = 0 } };
    var token: client.Cancellation = .{};
    var outcome = try publish(allocator, io, home, &prepared, .released_install, &token);
    defer outcome.deinit(allocator);
    token.requestStop();
    try prepared.dispose(allocator, io);
    var selected = try inspect(allocator, io, home);
    defer selected.deinit(allocator);
    try std.testing.expectEqualStrings(outcome.receipt().selected_after, selected.released.build);
}

test "installation archive reader bounds ignored metadata and cancellation" {
    var source: std.Io.Reader = .fixed("metadata");
    var buffer: [4]u8 = undefined;
    var guarded: ArchiveReader = .init(&source, null, &buffer, 4);
    try guarded.interface.discardAll(4);
    try std.testing.expectError(error.ReadFailed, guarded.interface.discardAll(1));
    try std.testing.expectEqual(error.ReleaseArchiveTooLarge, guarded.failure.?);
    var token: client.Cancellation = .{};
    token.requestStop();
    var cancelled: ArchiveReader = .init(&source, &token, &buffer, 4);
    try std.testing.expectError(error.ReadFailed, cancelled.interface.discardAll(1));
    try std.testing.expectEqual(error.Cancelled, cancelled.failure.?);
}

test "installation source marker defeats tagged version and explicit release install replaces managed source" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const home = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(home);
    const source = try testBuild(allocator, io, home, "tagged-source", "0.99.0");
    defer allocator.free(source);
    const revision = try std.fmt.allocPrint(allocator, "{s}/revision", .{source});
    defer allocator.free(revision);
    try Dir.cwd().writeFile(io, .{ .sub_path = revision, .data = "abcdef0 (local changes)\n" });
    var source_kind = try inspectBuild(allocator, io, home, source, null);
    defer source_kind.deinit(allocator);
    try std.testing.expect(source_kind == .source);
    var installed_source = try publishExisting(allocator, io, home, source, .intentional_source, null);
    defer installed_source.deinit(allocator);
    const release = try testBuild(allocator, io, home, "release", "0.56.0");
    defer allocator.free(release);
    try std.testing.expectError(error.IneligibleInstallation, publishExisting(allocator, io, home, release, .released_upgrade, null));
    var manual = try publishExisting(allocator, io, home, release, .released_install, null);
    defer manual.deinit(allocator);
    try std.testing.expect(manual == .installed);
    var selected = try inspect(allocator, io, home);
    defer selected.deinit(allocator);
    try std.testing.expectEqualStrings(release, selected.released.build);
    try std.testing.expectError(error.InvalidReleaseExecutable, publishExisting(allocator, io, home, source, .released_install, null));
}

const CleanupCapture = struct {
    allocator: Allocator,
    io: std.Io,
    calls: usize = 0,
    primary: ?anyerror = null,
    secondary: ?anyerror = null,
    retained_path: ?[]const u8 = null,
    existed_during_report: bool = false,

    fn reporter(self: *CleanupCapture) CleanupReporter {
        return .{ .context = self, .report = capture };
    }

    fn capture(context: ?*anyopaque, failure: CleanupFailure) void {
        const self: *CleanupCapture = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        self.primary = failure.primary;
        self.secondary = failure.secondary;
        self.retained_path = self.allocator.dupe(u8, failure.retained_path) catch @panic("fixture capture failed");
        self.existed_during_report = if (Dir.cwd().statFile(self.io, failure.retained_path, .{ .follow_symlinks = false })) |_| true else |_| false;
    }

    fn deinit(self: *CleanupCapture) void {
        if (self.retained_path) |retained| self.allocator.free(retained);
    }
};

test "installation preparation cleanup failure preserves download cause and retained stage custody" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const home = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(home);
    var captured: CleanupCapture = .{ .allocator = allocator, .io = io };
    defer captured.deinit();
    const candidate: releases.ReleaseCandidate = .{ .version = .{ .schema = 56, .patch = 0 }, .tag = "v0.56.0", .archive_name = "rui-0.56.0-darwin-arm64.tar.gz", .archive_url = "http://127.0.0.1:1/archive", .checksum_url = "http://127.0.0.1:1/SHA256SUMS", .sha256 = @splat(0) };
    try std.testing.expectError(error.UpgradeChildFailed, prepareWithCleanup(allocator, io, home, &candidate, null, captured.reporter(), .{ .remove_tree = error.AccessDenied }));
    try std.testing.expectEqual(@as(usize, 1), captured.calls);
    try std.testing.expectEqual(error.UpgradeChildFailed, captured.primary.?);
    try std.testing.expectEqual(error.AccessDenied, captured.secondary.?);
    try std.testing.expect(captured.existed_during_report);
    const retained = captured.retained_path.?;
    try std.testing.expect(std.mem.startsWith(u8, retained, home));
    const stat = try Dir.cwd().statFile(io, retained, .{});
    try std.testing.expectEqual(std.Io.File.Kind.directory, stat.kind);
    var selected = try inspect(allocator, io, home);
    defer selected.deinit(allocator);
    try std.testing.expect(selected == .absent);
    try Dir.cwd().deleteTree(io, retained);
}

test "installation preparation cleanup preserves checksum failure and frees its path allocation" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const home = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(home);
    var prepared: PreparedBuild = .{ .path = try newStage(allocator, io, home), .version = .{ .schema = 56, .patch = 0 } };
    const archive = try std.fmt.allocPrint(allocator, "{s}/archive.tar.gz", .{prepared.path});
    defer allocator.free(archive);
    try Dir.cwd().writeFile(io, .{ .sub_path = archive, .data = "checksum mismatch" });
    const candidate: releases.ReleaseCandidate = .{ .version = .{ .schema = 56, .patch = 0 }, .tag = "v0.56.0", .archive_name = "rui-0.56.0-darwin-arm64.tar.gz", .archive_url = "unused", .checksum_url = "unused", .sha256 = @splat(0) };
    const primary = if (verifyArchive(allocator, io, &prepared, &candidate, null, archive)) |_| return error.TestExpectedError else |err| err;
    try std.testing.expectEqual(error.ReleaseChecksumMismatch, primary);
    var captured: CleanupCapture = .{ .allocator = allocator, .io = io };
    defer captured.deinit();
    const failure = prepared.disposeResult(allocator, io, primary, captured.reporter(), .{ .remove_tree = error.AccessDenied });
    try std.testing.expectEqual(error.ReleaseChecksumMismatch, failure.?);
    try std.testing.expectEqual(error.ReleaseChecksumMismatch, captured.primary.?);
    try std.testing.expectEqual(error.AccessDenied, captured.secondary.?);
    try std.testing.expect(captured.existed_during_report);
    try Dir.cwd().deleteTree(io, captured.retained_path.?);
}

test "installation publication cleanup failure preserves rename cause and retained link custody" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const home = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(home);
    const build = try testBuild(allocator, io, home, "candidate", "0.56.0");
    var prepared: PreparedBuild = .{ .path = build, .version = .{ .schema = 56, .patch = 0 } };
    defer prepared.dispose(allocator, io) catch @panic("fixture cleanup failed");
    try temporary.dir.createDirPath(io, ".local/bin/rui");
    var captured: CleanupCapture = .{ .allocator = allocator, .io = io };
    defer captured.deinit();
    try std.testing.expectError(error.IsDir, publishWithCleanup(allocator, io, home, &prepared, .intentional_source, null, captured.reporter(), .{ .remove_link = error.AccessDenied }));
    try std.testing.expectEqual(@as(usize, 1), captured.calls);
    try std.testing.expectEqual(error.IsDir, captured.primary.?);
    try std.testing.expectEqual(error.AccessDenied, captured.secondary.?);
    try std.testing.expect(captured.existed_during_report);
    try std.testing.expect(!prepared.published);
    const retained = captured.retained_path.?;
    try std.testing.expect(std.fs.path.isAbsolute(retained));
    try std.testing.expect(std.mem.startsWith(u8, retained, home));
    const link = try Dir.cwd().statFile(io, retained, .{ .follow_symlinks = false });
    try std.testing.expectEqual(std.Io.File.Kind.sym_link, link.kind);
    const selected = try temporary.dir.statFile(io, ".local/bin/rui", .{});
    try std.testing.expectEqual(std.Io.File.Kind.directory, selected.kind);
    try Dir.cwd().deleteFile(io, retained);
}

test "installation cleanup report renders both causes and an escaped actionable retained path" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeCleanupFailure(&output.writer, .{ .primary = error.ReleaseChecksumMismatch, .secondary = error.AccessDenied, .retained_path = "/home/quoted '\x1b[31m/stage" });
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "ReleaseChecksumMismatch") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "AccessDenied") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "Retained installation files: $") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, output.written(), 0x1b) == null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\\033") != null);
}
