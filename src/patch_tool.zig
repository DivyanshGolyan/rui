const std = @import("std");
const binding_digest = @import("binding.zig");

pub const max_patch_size = 16 * 1024;
pub const max_file_size: u64 = 1024 * 1024;
pub const max_path_size = 1024;
pub const max_workspace_path_size = 1024;
pub const intent_header_size = 176;
pub const max_intent_size = intent_header_size + max_workspace_path_size + max_path_size;
pub const result_size = 64;
pub const version: u16 = 4;

const intent_magic = "ONEPINT\x00";
const result_magic = "ONEPRES\x00";

pub const Decision = enum(u8) {
    allow = 1,
    ask = 2,
    deny = 3,
};

pub const TargetPath = struct {
    length: u16,
    bytes: [max_path_size]u8,

    fn init(path: []const u8) !TargetPath {
        if (path.len == 0 or path.len > max_path_size) return error.RepositoryEscape;
        var result: TargetPath = .{ .length = @intCast(path.len), .bytes = @splat(0) };
        @memcpy(result.bytes[0..path.len], path);
        return result;
    }

    pub fn slice(self: *const TargetPath) []const u8 {
        return self.bytes[0..self.length];
    }
};

pub const Intent = struct {
    operation_id: u64,
    operation_generation: u32,
    patch_ref: u64,
    workspace_path: []const u8,
    target_path: TargetPath,
    patch_digest: binding_digest.PatchDescriptor,
    intent_digest: binding_digest.PatchIntent,
    preimage_digest: binding_digest.Preimage,
    postimage_digest: binding_digest.Postimage,
    preimage_inode: std.Io.File.INode,
    file_mode: u32,
};

pub const ActionContext = struct {
    operation_id: u64,
    operation_generation: u32,
    patch_ref: u64,
};

const PreparationTestPhase = enum {
    after_first_snapshot_chunk,
    before_git,
};

const PreparationTestHook = struct {
    context: *anyopaque,
    call_fn: *const fn (*anyopaque, PreparationTestPhase) anyerror!void,

    fn call(self: PreparationTestHook, phase: PreparationTestPhase) !void {
        try self.call_fn(self.context, phase);
    }
};

pub const Policy = struct {
    context: *anyopaque,
    classify_fn: *const fn (*anyopaque, Intent, []const u8) anyerror!Decision,
    ask_fn: *const fn (*anyopaque, Intent, []const u8) anyerror!bool,

    pub fn classify(self: Policy, intent: Intent, patch: []const u8) !Decision {
        return self.classify_fn(self.context, intent, patch);
    }

    pub fn ask(self: Policy, intent: Intent, patch: []const u8) !bool {
        return self.ask_fn(self.context, intent, patch);
    }
};

const Observation = enum(u8) {
    preimage = 1,
    postimage = 2,
    diverged = 3,
    invalid = 4,
};

pub const ResultStatus = enum(u8) {
    denied = 1,
    stale = 2,
    applied = 3,
    indeterminate = 4,
};

pub const Result = struct {
    status: ResultStatus,
    intent_ref: u64,
    intent_digest: binding_digest.PatchIntent,
};

pub const Reconciliation = struct {
    status: ResultStatus,
    mutated: bool,
};

pub fn encodeIntent(out: []u8, intent: Intent) ![]const u8 {
    if (intent.operation_id == 0 or intent.operation_generation == 0 or intent.patch_ref == 0 or
        intent.workspace_path.len == 0 or intent.workspace_path.len > max_workspace_path_size or
        intent.target_path.length == 0 or intent.target_path.length > max_path_size)
    {
        return error.InvalidPatchIntent;
    }
    const total = intent_header_size + intent.workspace_path.len + intent.target_path.length;
    if (out.len < total) return error.IntentBufferTooSmall;
    @memset(out[0..total], 0);
    @memcpy(out[0..intent_magic.len], intent_magic);
    write(u16, out, 8, version);
    write(u16, out, 10, @intCast(total));
    write(u16, out, 12, @intCast(intent.workspace_path.len));
    write(u16, out, 14, intent.target_path.length);
    write(u64, out, 16, intent.operation_id);
    write(u32, out, 24, intent.operation_generation);
    write(u32, out, 28, intent.file_mode);
    write(u64, out, 32, intent.patch_ref);
    write(u64, out, 40, @intCast(intent.preimage_inode));
    @memcpy(out[48..80], &intent.patch_digest.bytes);
    @memcpy(out[80..112], &intent.preimage_digest.bytes);
    @memcpy(out[112..144], &intent.postimage_digest.bytes);
    @memcpy(out[144..176], &intent.intent_digest.bytes);
    @memcpy(out[intent_header_size..][0..intent.workspace_path.len], intent.workspace_path);
    @memcpy(out[intent_header_size + intent.workspace_path.len .. total], intent.target_path.slice());
    const canonical_digest = intentDigest(intent);
    if (!binding_digest.eql(binding_digest.PatchIntent, canonical_digest, intent.intent_digest)) {
        return error.InvalidPatchIntent;
    }
    return out[0..total];
}

pub fn decodeIntent(bytes: []const u8) !Intent {
    if (bytes.len < intent_header_size or bytes.len > max_intent_size or
        !std.mem.eql(u8, bytes[0..intent_magic.len], intent_magic) or
        read(u16, bytes, 8) != version or read(u16, bytes, 10) != bytes.len)
    {
        return error.InvalidPatchIntent;
    }
    const workspace_length = read(u16, bytes, 12);
    const target_length = read(u16, bytes, 14);
    if (workspace_length == 0 or workspace_length > max_workspace_path_size or
        target_length == 0 or target_length > max_path_size or
        intent_header_size + workspace_length + target_length != bytes.len)
    {
        return error.InvalidPatchIntent;
    }
    const intent: Intent = .{
        .operation_id = read(u64, bytes, 16),
        .operation_generation = read(u32, bytes, 24),
        .file_mode = read(u32, bytes, 28),
        .patch_ref = read(u64, bytes, 32),
        .preimage_inode = @intCast(read(u64, bytes, 40)),
        .patch_digest = .{ .bytes = bytes[48..80].* },
        .preimage_digest = .{ .bytes = bytes[80..112].* },
        .postimage_digest = .{ .bytes = bytes[112..144].* },
        .intent_digest = .{ .bytes = bytes[144..176].* },
        .workspace_path = bytes[intent_header_size..][0..workspace_length],
        .target_path = try TargetPath.init(bytes[intent_header_size + workspace_length ..]),
    };
    var canonical: [max_intent_size]u8 = undefined;
    const encoded = try encodeIntent(&canonical, intent);
    if (!std.mem.eql(u8, encoded, bytes)) return error.InvalidPatchIntent;
    return intent;
}

pub fn encodeResult(out: *[result_size]u8, result: Result) !void {
    if (result.intent_ref == 0) return error.InvalidPatchResult;
    @memset(out, 0);
    @memcpy(out[0..result_magic.len], result_magic);
    write(u16, out, 8, version);
    out[10] = @intFromEnum(result.status);
    write(u64, out, 16, result.intent_ref);
    @memcpy(out[32..64], &result.intent_digest.bytes);
}

pub fn decodeResult(bytes: *const [result_size]u8) !Result {
    if (!std.mem.eql(u8, bytes[0..result_magic.len], result_magic) or
        read(u16, bytes, 8) != version or bytes[11] != 0 or bytes[12] != 0 or
        bytes[13] != 0 or bytes[14] != 0 or bytes[15] != 0 or
        !std.mem.allEqual(u8, bytes[24..32], 0))
    {
        return error.InvalidPatchResult;
    }
    const status: ResultStatus = switch (bytes[10]) {
        1 => .denied,
        2 => .stale,
        3 => .applied,
        4 => .indeterminate,
        else => return error.InvalidPatchResult,
    };
    const result: Result = .{
        .status = status,
        .intent_ref = read(u64, bytes, 16),
        .intent_digest = .{ .bytes = bytes[32..64].* },
    };
    var canonical: [result_size]u8 = undefined;
    try encodeResult(&canonical, result);
    if (!std.mem.eql(u8, &canonical, bytes)) return error.InvalidPatchResult;
    return result;
}

fn descriptorDigest(patch: []const u8) binding_digest.PatchDescriptor {
    return binding_digest.hash(binding_digest.PatchDescriptor, patch);
}

pub fn prepare(
    io: std.Io,
    workspace_path: []const u8,
    patch: []const u8,
    action: ActionContext,
) !Intent {
    return prepareWithTestHook(io, workspace_path, patch, action, null);
}

fn prepareWithTestHook(
    io: std.Io,
    workspace_path: []const u8,
    patch: []const u8,
    action: ActionContext,
    test_hook: ?PreparationTestHook,
) !Intent {
    if (action.operation_id == 0 or action.operation_generation == 0 or action.patch_ref == 0) {
        return error.InvalidPatchIntent;
    }
    var canonical_workspace_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const canonical_workspace_length = try std.Io.Dir.cwd().realPathFile(
        io,
        workspace_path,
        &canonical_workspace_buffer,
    );
    if (!std.mem.eql(
        u8,
        workspace_path,
        canonical_workspace_buffer[0..canonical_workspace_length],
    )) return error.NoncanonicalWorkspace;
    var target_buffer: [max_path_size]u8 = undefined;
    const target_path = try deriveTarget(io, patch, &target_buffer);
    var workspace = try std.Io.Dir.cwd().openDir(io, workspace_path, .{});
    defer workspace.close(io);
    var target = try openRegularTarget(workspace, io, target_path);
    defer target.close(io);
    const stat = try target.stat(io);
    if (stat.kind != .file or stat.nlink != 1) return error.UnsupportedSpecialFile;
    if (stat.size > max_file_size) return error.PatchTargetTooLarge;

    try gitTracked(io, workspace_path, target_path);
    const prepared = try prepareSnapshot(
        io,
        target,
        stat.size,
        target_path,
        patch,
        test_hook,
        null,
    );
    var confirmed_target = try openRegularTarget(workspace, io, target_path);
    defer confirmed_target.close(io);
    const confirmed_stat = try confirmed_target.stat(io);
    if (confirmed_stat.kind != .file or confirmed_stat.nlink != 1) return error.UnsupportedSpecialFile;
    if (confirmed_stat.size > max_file_size) return error.PatchTargetTooLarge;
    const confirmed_digest = try hashFile(io, confirmed_target, confirmed_stat.size);
    if (confirmed_stat.inode != stat.inode or confirmed_stat.size != stat.size or
        !binding_digest.eql(binding_digest.Preimage, confirmed_digest, prepared.preimage_digest))
    {
        return error.PreimageChangedDuringValidation;
    }
    var intent: Intent = .{
        .operation_id = action.operation_id,
        .operation_generation = action.operation_generation,
        .patch_ref = action.patch_ref,
        .workspace_path = workspace_path,
        .target_path = try TargetPath.init(target_path),
        .patch_digest = descriptorDigest(patch),
        .intent_digest = undefined,
        .preimage_digest = prepared.preimage_digest,
        .postimage_digest = prepared.postimage_digest,
        .preimage_inode = stat.inode,
        .file_mode = @intFromEnum(stat.permissions),
    };
    intent.intent_digest = intentDigest(intent);
    return intent;
}

fn deriveTarget(
    io: std.Io,
    patch: []const u8,
    out: *[max_path_size]u8,
) ![]const u8 {
    if (patch.len == 0) return error.MalformedPatch;
    if (patch.len > max_patch_size) return error.PatchTooLarge;
    var git_output: [max_patch_size + 1]u8 = undefined;
    const parsed = try runGit(
        io,
        "/private/tmp",
        &.{ "apply", "--no-index", "--numstat", "-z", "-" },
        patch,
        &git_output,
    );
    if (parsed.code != 0) return error.MalformedPatch;
    var summary_output: [max_patch_size + 1]u8 = undefined;
    const summary = try runGit(
        io,
        "/private/tmp",
        &.{ "apply", "--no-index", "--summary", "-z", "-" },
        patch,
        &summary_output,
    );
    if (summary.code != 0) return error.MalformedPatch;
    // Git reports create, delete, rename, copy, and mode metadata here. V1 admits none of them.
    if (summary.stdout_len != 0) return error.UnsupportedSpecialFile;
    // Parse only Git's NUL-delimited machine result: two counts and exactly one literal path.
    const bytes = git_output[0..parsed.stdout_len];
    const first_tab = std.mem.indexOfScalar(u8, bytes, '\t') orelse return error.MalformedPatch;
    const second_tab = std.mem.indexOfPos(u8, bytes, first_tab + 1, "\t") orelse
        return error.MalformedPatch;
    const terminator = std.mem.indexOfScalar(u8, bytes, 0) orelse return error.MalformedPatch;
    if (terminator + 1 != bytes.len) return error.MultipleFiles;
    if (!decimalCount(bytes[0..first_tab]) or !decimalCount(bytes[first_tab + 1 .. second_tab])) {
        return if (std.mem.eql(u8, bytes[0..first_tab], "-") and
            std.mem.eql(u8, bytes[first_tab + 1 .. second_tab], "-"))
            error.BinaryPatch
        else
            error.MalformedPatch;
    }
    const path = bytes[second_tab + 1 .. terminator];
    try validateRelativePath(path);
    @memcpy(out[0..path.len], path);
    return out[0..path.len];
}

fn decimalCount(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    for (bytes) |byte| if (byte < '0' or byte > '9') return false;
    return true;
}

fn validateRelativePath(path: []const u8) !void {
    if (path.len == 0 or path.len > max_path_size or path[0] == '/' or path[path.len - 1] == '/') {
        return error.RepositoryEscape;
    }
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) {
            return error.PathTraversal;
        }
    }
}

fn openRegularTarget(workspace: std.Io.Dir, io: std.Io, target_path: []const u8) !std.Io.File {
    return openRegularTargetMode(workspace, io, target_path, .read_only);
}

fn openRegularTargetMode(
    workspace: std.Io.Dir,
    io: std.Io,
    target_path: []const u8,
    mode: std.Io.File.OpenMode,
) !std.Io.File {
    const separator = std.mem.lastIndexOfScalar(u8, target_path, '/');
    const parent_path = if (separator) |index| target_path[0..index] else "";
    const basename = if (separator) |index| target_path[index + 1 ..] else target_path;
    var current = workspace;
    var owns_current = false;
    errdefer if (owns_current) current.close(io);
    var components = std.mem.splitScalar(u8, parent_path, '/');
    while (components.next()) |component| {
        if (component.len == 0) continue;
        const stat = try current.statFile(io, component, .{ .follow_symlinks = false });
        if (stat.kind == .sym_link) return error.SymlinkEscape;
        if (stat.kind != .directory) return error.UnsupportedSpecialFile;
        const next = current.openDir(io, component, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.NotDir, error.SymLinkLoop => return error.SymlinkEscape,
            else => return err,
        };
        if (owns_current) current.close(io);
        current = next;
        owns_current = true;
    }
    const target_stat = try current.statFile(io, basename, .{ .follow_symlinks = false });
    if (target_stat.kind == .sym_link) return error.SymlinkEscape;
    if (target_stat.kind != .file or target_stat.nlink != 1) return error.UnsupportedSpecialFile;
    const file = current.openFile(io, basename, .{
        .mode = mode,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.SymLinkLoop => return error.SymlinkEscape,
        else => return err,
    };
    if (owns_current) current.close(io);
    return file;
}

fn hashFile(io: std.Io, file: std.Io.File, size: u64) !binding_digest.Preimage {
    return hashFileAs(binding_digest.Preimage, io, file, size);
}

fn hashFileAs(comptime T: type, io: std.Io, file: std.Io.File, size: u64) !T {
    var hasher = binding_digest.Hasher(T).init();
    var buffer: [4096]u8 = undefined;
    var offset: u64 = 0;
    while (offset < size) {
        const remaining: usize = @intCast(@min(size - offset, buffer.len));
        const count = try file.readPositionalAll(io, buffer[0..remaining], offset);
        if (count == 0) return error.PreimageChangedDuringRead;
        hasher.update(buffer[0..count]);
        offset += count;
    }
    if (try file.length(io) != size) return error.PreimageChangedDuringRead;
    return hasher.final();
}

const PreparedSnapshot = struct {
    preimage_digest: binding_digest.Preimage,
    postimage_digest: binding_digest.Postimage,
};

fn prepareSnapshot(
    io: std.Io,
    source: std.Io.File,
    source_size: u64,
    target_path: []const u8,
    patch: []const u8,
    test_hook: ?PreparationTestHook,
    apply_intent: ?Intent,
) !PreparedSnapshot {
    var temporary_root = try std.Io.Dir.cwd().openDir(io, "/private/tmp", .{});
    defer temporary_root.close(io);
    var random: [16]u8 = undefined;
    var name_buffer: [48]u8 = undefined;
    var name: []const u8 = undefined;
    for (0..8) |_| {
        io.random(&random);
        name = try std.fmt.bufPrint(
            &name_buffer,
            "onepage-patch-{s}",
            .{std.fmt.bytesToHex(random, .lower)},
        );
        temporary_root.createDir(io, name, .fromMode(0o700)) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        break;
    } else return error.TemporaryWorkspaceExhausted;
    var temporary = try temporary_root.openDir(io, name, .{});
    defer {
        temporary.close(io);
        temporary_root.deleteTree(io, name) catch {
            // This non-authoritative private copy is garbage if cleanup fails.
        };
    }
    try copyExactTarget(io, source, source_size, temporary, target_path, test_hook);
    var preimage = try openRegularTarget(temporary, io, target_path);
    defer preimage.close(io);
    const preimage_stat = try preimage.stat(io);
    if (preimage_stat.kind != .file or preimage_stat.nlink != 1) return error.UnsupportedSpecialFile;
    if (preimage_stat.size != source_size) return error.PreimageChangedDuringRead;
    const preimage_digest = try hashFile(io, preimage, preimage_stat.size);
    if (test_hook) |hook| try hook.call(.before_git);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "/private/tmp/{s}", .{name});
    const applied = try runGit(
        io,
        path,
        &.{ "apply", "--no-index", "--whitespace=nowarn", "-" },
        patch,
        null,
    );
    if (applied.code != 0) return error.PatchNotApplicable;
    var target = try openRegularTarget(temporary, io, target_path);
    defer target.close(io);
    const stat = try target.stat(io);
    if (stat.kind != .file or stat.nlink != 1) return error.UnsupportedSpecialFile;
    if (stat.size > max_file_size) return error.PatchPostimageTooLarge;
    if (stat.permissions != preimage_stat.permissions) return error.UnsupportedSpecialFile;
    const postimage_digest = try hashFileAs(binding_digest.Postimage, io, target, stat.size);
    if (apply_intent) |intent| {
        if (!binding_digest.eql(binding_digest.Postimage, postimage_digest, intent.postimage_digest)) {
            return error.PatchEffectUncertain;
        }
        const source_stat = try source.stat(io);
        if (source_stat.kind != .file or source_stat.nlink != 1 or
            source_stat.inode != intent.preimage_inode or
            @intFromEnum(source_stat.permissions) != intent.file_mode or
            source_stat.size > max_file_size)
        {
            return error.PatchPreimageMismatch;
        }
        const source_digest = try hashFileAs(binding_digest.Preimage, io, source, source_stat.size);
        if (!binding_digest.eql(binding_digest.Preimage, source_digest, intent.preimage_digest)) {
            return error.PatchPreimageMismatch;
        }
        try source.setLength(io, stat.size);
        var buffer: [4096]u8 = undefined;
        var offset: u64 = 0;
        while (offset < stat.size) {
            const remaining: usize = @intCast(@min(stat.size - offset, buffer.len));
            const count = try target.readPositionalAll(io, buffer[0..remaining], offset);
            if (count == 0) return error.PatchEffectUncertain;
            try source.writePositionalAll(io, buffer[0..count], offset);
            offset += count;
        }
        try source.sync(io);
    }
    return .{
        .preimage_digest = preimage_digest,
        .postimage_digest = postimage_digest,
    };
}

fn copyExactTarget(
    io: std.Io,
    source: std.Io.File,
    source_size: u64,
    destination_dir: std.Io.Dir,
    target_path: []const u8,
    test_hook: ?PreparationTestHook,
) !void {
    std.debug.assert(source_size <= max_file_size);
    if (std.mem.lastIndexOfScalar(u8, target_path, '/')) |separator| {
        try destination_dir.createDirPath(io, target_path[0..separator]);
    }
    var destination = try destination_dir.createFile(io, target_path, .{ .exclusive = true });
    defer destination.close(io);
    const source_stat = try source.stat(io);
    try destination.setPermissions(io, source_stat.permissions);
    var buffer: [4096]u8 = undefined;
    var offset: u64 = 0;
    while (offset < source_size) {
        const remaining: usize = @intCast(@min(source_size - offset, buffer.len));
        const count = try source.readPositionalAll(io, buffer[0..remaining], offset);
        if (count == 0) return error.PreimageChangedDuringRead;
        try destination.writeStreamingAll(io, buffer[0..count]);
        offset += count;
        if (offset == count) {
            if (test_hook) |hook| try hook.call(.after_first_snapshot_chunk);
        }
    }
    if (try source.length(io) != source_size) return error.PreimageChangedDuringRead;
}

fn gitTracked(io: std.Io, workspace_path: []const u8, target_path: []const u8) !void {
    var output: [max_path_size + 2]u8 = undefined;
    const result = try runGit(
        io,
        workspace_path,
        &.{
            "--literal-pathspecs",
            "ls-files",
            "-z",
            "--error-unmatch",
            "--format=%(path)",
            "--",
            target_path,
        },
        null,
        &output,
    );
    if (result.code != 0 or result.stdout_len != target_path.len + 1 or
        !std.mem.eql(u8, output[0..target_path.len], target_path) or
        output[target_path.len] != 0)
    {
        return error.NotTrackedRepositoryFile;
    }
}

const GitResult = struct {
    code: u8,
    stdout_len: usize,
};

fn runGit(
    io: std.Io,
    workspace_path: []const u8,
    arguments: []const []const u8,
    input: ?[]const u8,
    stdout_buffer: ?[]u8,
) !GitResult {
    var argv_buffer: [8][]const u8 = undefined;
    if (arguments.len + 1 > argv_buffer.len) return error.InvalidGitInvocation;
    argv_buffer[0] = "/usr/bin/git";
    @memcpy(argv_buffer[1..][0..arguments.len], arguments);
    var environment = std.process.Environ.Map.init(std.heap.page_allocator);
    defer environment.deinit();
    try environment.put("PATH", "/usr/bin:/bin");
    try environment.put("LC_ALL", "C");
    try environment.put("GIT_CONFIG_NOSYSTEM", "1");
    try environment.put("GIT_CONFIG_GLOBAL", "/dev/null");
    var child = try std.process.spawn(io, .{
        .argv = argv_buffer[0 .. arguments.len + 1],
        .cwd = .{ .path = workspace_path },
        .environ_map = &environment,
        .stdin = if (input == null) .ignore else .pipe,
        .stdout = if (stdout_buffer == null) .ignore else .pipe,
        .stderr = .ignore,
    });
    errdefer {
        child.kill(io);
    }
    if (input) |bytes| {
        try child.stdin.?.writeStreamingAll(io, bytes);
        child.stdin.?.close(io);
        child.stdin = null;
    }
    var stdout_len: usize = 0;
    if (stdout_buffer) |buffer| {
        while (stdout_len < buffer.len) {
            const count = child.stdout.?.readStreaming(io, &.{buffer[stdout_len..]}) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            if (count == 0) break;
            stdout_len += count;
        }
        if (stdout_len == buffer.len) {
            var extra: [1]u8 = undefined;
            const count = child.stdout.?.readStreaming(io, &.{&extra}) catch |err| switch (err) {
                error.EndOfStream => 0,
                else => return err,
            };
            if (count != 0) {
                return error.GitOutputTooLarge;
            }
        }
        child.stdout.?.close(io);
        child.stdout = null;
    }
    const term = try child.wait(io);
    return .{
        .code = switch (term) {
            .exited => |code| code,
            else => 255,
        },
        .stdout_len = stdout_len,
    };
}

fn observe(io: std.Io, intent: Intent, patch: []const u8) !Observation {
    if (!binding_digest.eql(binding_digest.PatchIntent, intentDigest(intent), intent.intent_digest) or
        !binding_digest.eql(binding_digest.PatchDescriptor, descriptorDigest(patch), intent.patch_digest))
    {
        return error.InvalidPatchIntent;
    }
    var target_buffer: [max_path_size]u8 = undefined;
    const target_path = deriveTarget(io, patch, &target_buffer) catch return .invalid;
    if (!std.mem.eql(u8, target_path, intent.target_path.slice())) return .invalid;
    var canonical_workspace: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const canonical_length = std.Io.Dir.cwd().realPathFile(
        io,
        intent.workspace_path,
        &canonical_workspace,
    ) catch return .invalid;
    if (!std.mem.eql(u8, intent.workspace_path, canonical_workspace[0..canonical_length])) {
        return .invalid;
    }
    var workspace = std.Io.Dir.cwd().openDir(io, intent.workspace_path, .{}) catch return .invalid;
    defer workspace.close(io);
    var target = openRegularTarget(workspace, io, intent.target_path.slice()) catch return .invalid;
    defer target.close(io);
    const stat = target.stat(io) catch return .invalid;
    if (stat.kind != .file or stat.nlink != 1 or stat.size > max_file_size or
        @intFromEnum(stat.permissions) != intent.file_mode)
    {
        return .invalid;
    }
    gitTracked(io, intent.workspace_path, intent.target_path.slice()) catch return .invalid;
    const preimage = hashFileAs(binding_digest.Preimage, io, target, stat.size) catch return .invalid;
    if (binding_digest.eql(binding_digest.Preimage, preimage, intent.preimage_digest)) {
        return if (stat.inode == intent.preimage_inode) .preimage else .diverged;
    }
    const postimage = hashFileAs(binding_digest.Postimage, io, target, stat.size) catch return .invalid;
    if (binding_digest.eql(binding_digest.Postimage, postimage, intent.postimage_digest)) {
        return if (stat.inode == intent.preimage_inode) .postimage else .diverged;
    }
    return .diverged;
}

fn apply(io: std.Io, intent: Intent, patch: []const u8) !Observation {
    if (try observe(io, intent, patch) != .preimage) return error.PatchPreimageMismatch;
    var workspace = try std.Io.Dir.cwd().openDir(io, intent.workspace_path, .{});
    defer workspace.close(io);
    var target = try openRegularTargetMode(workspace, io, intent.target_path.slice(), .read_write);
    defer target.close(io);
    const stat = try target.stat(io);
    _ = try prepareSnapshot(io, target, stat.size, intent.target_path.slice(), patch, null, intent);
    const observed = try observe(io, intent, patch);
    if (observed != .postimage) return error.PatchEffectUncertain;
    return observed;
}

pub fn readyForAttempt(io: std.Io, intent: Intent, patch: []const u8) !bool {
    return try observe(io, intent, patch) == .preimage;
}

pub fn reconcile(io: std.Io, intent: Intent, patch: []const u8) !Reconciliation {
    return switch (try observe(io, intent, patch)) {
        .postimage => .{ .status = .applied, .mutated = false },
        .diverged, .invalid => .{ .status = .indeterminate, .mutated = false },
        .preimage => blk: {
            _ = apply(io, intent, patch) catch |err| switch (err) {
                error.PatchPreimageMismatch => break :blk .{
                    .status = .indeterminate,
                    .mutated = false,
                },
                error.PatchEffectUncertain => break :blk .{
                    .status = .indeterminate,
                    .mutated = true,
                },
                else => return err,
            };
            break :blk .{
                .status = if (try observe(io, intent, patch) == .postimage) .applied else .indeterminate,
                .mutated = true,
            };
        },
    };
}

fn intentDigest(intent: Intent) binding_digest.PatchIntent {
    var hasher = binding_digest.Hasher(binding_digest.PatchIntent).init();
    var integers: [32]u8 = @splat(0);
    std.mem.writeInt(u64, integers[0..8], intent.operation_id, .little);
    std.mem.writeInt(u32, integers[8..12], intent.operation_generation, .little);
    std.mem.writeInt(u32, integers[12..16], intent.file_mode, .little);
    std.mem.writeInt(u64, integers[16..24], intent.patch_ref, .little);
    std.mem.writeInt(u64, integers[24..32], @intCast(intent.preimage_inode), .little);
    hasher.update(&integers);
    updateLengthPrefixed(binding_digest.PatchIntent, &hasher, intent.workspace_path);
    updateLengthPrefixed(binding_digest.PatchIntent, &hasher, intent.target_path.slice());
    hasher.update("regular-file-single-link-v1\x00");
    hasher.update(&intent.patch_digest.bytes);
    hasher.update(&intent.preimage_digest.bytes);
    hasher.update(&intent.postimage_digest.bytes);
    return hasher.final();
}

fn updateLengthPrefixed(
    comptime T: type,
    hasher: *binding_digest.Hasher(T),
    bytes: []const u8,
) void {
    var length: [4]u8 = undefined;
    std.mem.writeInt(u32, &length, @intCast(bytes.len), .little);
    hasher.update(&length);
    hasher.update(bytes);
}

fn write(comptime T: type, out: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, out[offset..][0..@sizeOf(T)], value, .little);
}

fn read(comptime T: type, input: []const u8, offset: usize) T {
    return std.mem.readInt(T, input[offset..][0..@sizeOf(T)], .little);
}

test "one exact tracked regular-file patch validates without mutation" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, io, "note.txt", "old\n");
    var relative_buffer: [128]u8 = undefined;
    const relative = try std.fmt.bufPrint(&relative_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_length = try std.Io.Dir.cwd().realPathFile(io, relative, &path_buffer);
    const path = path_buffer[0..path_length];
    try expectGit(io, path, &.{ "init", "-q" });
    try expectGit(io, path, &.{ "add", "note.txt" });
    const patch =
        "diff --git a/note.txt b/note.txt\n" ++
        "index 3367afd..3e75765 100644\n" ++
        "--- a/note.txt\n" ++
        "+++ b/note.txt\n" ++
        "@@ -1 +1 @@\n" ++
        "-old\n" ++
        "+new\n";
    const validated = try prepare(io, path, patch, testAction());
    try std.testing.expectEqualStrings("note.txt", validated.target_path.slice());
    try std.testing.expect(binding_digest.eql(
        binding_digest.PatchDescriptor,
        descriptorDigest(patch),
        validated.patch_digest,
    ));
    try std.testing.expectEqual(@as(usize, 32), validated.intent_digest.bytes.len);
    try std.testing.expectEqual(@as(usize, 32), validated.postimage_digest.bytes.len);
    try std.testing.expect(binding_digest.eql(
        binding_digest.Postimage,
        binding_digest.hash(binding_digest.Postimage, "new\n"),
        validated.postimage_digest,
    ));
    var changed_intent = validated;
    changed_intent.operation_generation = 2;
    const changed_generation = intentDigest(changed_intent);
    try std.testing.expect(!binding_digest.eql(
        binding_digest.PatchIntent,
        validated.intent_digest,
        changed_generation,
    ));
    var actual: [4]u8 = undefined;
    var file = try tmp.dir.openFile(io, "note.txt", .{});
    defer file.close(io);
    try std.testing.expectEqual(@as(usize, 4), try file.readPositionalAll(io, &actual, 0));
    try std.testing.expectEqualStrings("old\n", &actual);
}

test "prepare accepts Git-valid spaces and quoted path bytes" {
    const io = std.testing.io;
    const cases = [_]struct { target: []const u8, patch: []const u8 }{
        .{
            .target = "space name.txt",
            .patch = "diff --git a/space name.txt b/space name.txt\n" ++
                "index 3367afd..3e75765 100644\n" ++
                "--- a/space name.txt\t\n+++ b/space name.txt\t\n" ++
                "@@ -1 +1 @@\n-old\n+new\n",
        },
        .{
            .target = "quote\"name.txt",
            .patch = "diff --git \"a/quote\\\"name.txt\" \"b/quote\\\"name.txt\"\n" ++
                "index 3367afd..3e75765 100644\n" ++
                "--- \"a/quote\\\"name.txt\"\n+++ \"b/quote\\\"name.txt\"\n" ++
                "@@ -1 +1 @@\n-old\n+new\n",
        },
    };
    for (cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try writeTestFile(tmp.dir, io, case.target, "old\n");
        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path = try canonicalTestPath(io, &tmp.sub_path, &path_buffer);
        try expectGit(io, path, &.{ "init", "-q" });
        try expectGit(io, path, &.{ "add", case.target });
        const intent = try prepare(io, path, case.patch, testAction());
        try std.testing.expectEqualStrings(case.target, intent.target_path.slice());
        try expectTestFile(tmp.dir, io, case.target, "old\n");
    }
}

test "patch preparation bounds both target and expected postimage bytes" {
    const io = std.testing.io;
    const cases = [_]struct {
        target_size: u64,
        replacement: []const u8,
        expected_error: ?anyerror,
    }{
        .{ .target_size = max_file_size, .replacement = "new", .expected_error = null },
        .{ .target_size = max_file_size + 1, .replacement = "new", .expected_error = error.PatchTargetTooLarge },
        .{ .target_size = max_file_size, .replacement = "new!", .expected_error = error.PatchPostimageTooLarge },
    };
    for (cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try writeSizedTestFile(tmp.dir, io, "bounded.txt", case.target_size);
        var relative_buffer: [128]u8 = undefined;
        const relative = try std.fmt.bufPrint(&relative_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path_length = try std.Io.Dir.cwd().realPathFile(io, relative, &path_buffer);
        const path = path_buffer[0..path_length];
        try expectGit(io, path, &.{ "init", "-q" });
        try expectGit(io, path, &.{ "add", "bounded.txt" });
        var patch_buffer: [256]u8 = undefined;
        const patch = try std.fmt.bufPrint(
            &patch_buffer,
            "diff --git a/bounded.txt b/bounded.txt\n" ++
                "--- a/bounded.txt\n" ++
                "+++ b/bounded.txt\n" ++
                "@@ -1,2 +1,2 @@\n" ++
                "-old\n" ++
                "+{s}\n" ++
                " x\n",
            .{case.replacement},
        );
        if (case.expected_error) |expected_error| {
            try std.testing.expectError(
                expected_error,
                prepare(io, path, patch, testAction()),
            );
        } else {
            _ = try prepare(io, path, patch, testAction());
        }
        try expectSizedTestFileUnchanged(tmp.dir, io, "bounded.txt", case.target_size);
    }
}

test "patch preparation binds the exact bounded snapshot used by git" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeSizedTestFile(tmp.dir, io, "stable.txt", 8192);
    var relative_buffer: [128]u8 = undefined;
    const relative = try std.fmt.bufPrint(&relative_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_length = try std.Io.Dir.cwd().realPathFile(io, relative, &path_buffer);
    const path = path_buffer[0..path_length];
    try expectGit(io, path, &.{ "init", "-q" });
    try expectGit(io, path, &.{ "add", "stable.txt" });
    var state = SnapshotRaceTestState{
        .dir = tmp.dir,
        .io = io,
        .mode = .same_size_restore,
    };
    const patch =
        "diff --git a/stable.txt b/stable.txt\n" ++
        "--- a/stable.txt\n" ++
        "+++ b/stable.txt\n" ++
        "@@ -1,2 +1,2 @@\n" ++
        "-old\n" ++
        "+new\n" ++
        " x\n";
    try std.testing.expectError(
        error.PreimageChangedDuringValidation,
        prepareWithTestHook(
            io,
            path,
            patch,
            testAction(),
            state.hook(),
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), state.before_git_count);
    try expectSizedTestFileUnchanged(tmp.dir, io, "stable.txt", 8192);
    var file = try tmp.dir.openFile(io, "stable.txt", .{});
    defer file.close(io);
    var restored: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try file.readPositionalAll(io, &restored, 4096));
    try std.testing.expectEqualStrings("x", &restored);
}

test "patch preparation rejects concurrent growth before git sees the snapshot" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeSizedTestFile(tmp.dir, io, "growing.txt", max_file_size);
    var relative_buffer: [128]u8 = undefined;
    const relative = try std.fmt.bufPrint(&relative_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_length = try std.Io.Dir.cwd().realPathFile(io, relative, &path_buffer);
    const path = path_buffer[0..path_length];
    try expectGit(io, path, &.{ "init", "-q" });
    try expectGit(io, path, &.{ "add", "growing.txt" });
    var state = SnapshotRaceTestState{
        .dir = tmp.dir,
        .io = io,
        .mode = .grow,
    };
    const patch =
        "diff --git a/growing.txt b/growing.txt\n" ++
        "--- a/growing.txt\n" ++
        "+++ b/growing.txt\n" ++
        "@@ -1,2 +1,2 @@\n" ++
        "-old\n" ++
        "+new\n" ++
        " x\n";
    try std.testing.expectError(
        error.PreimageChangedDuringRead,
        prepareWithTestHook(
            io,
            path,
            patch,
            testAction(),
            state.hook(),
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), state.before_git_count);
    try expectSizedTestFileUnchanged(tmp.dir, io, "growing.txt", max_file_size + 1);
}

test "one immutable Patch Intent and typed Result are canonical" {
    var expected: Intent = .{
        .operation_id = 11,
        .operation_generation = 2,
        .patch_ref = 4,
        .workspace_path = "/tmp/workspace",
        .target_path = try TargetPath.init("src/main.zig"),
        .patch_digest = binding_digest.hash(binding_digest.PatchDescriptor, "patch-5"),
        .intent_digest = undefined,
        .preimage_inode = 8,
        .preimage_digest = binding_digest.hash(binding_digest.Preimage, "preimage-7"),
        .postimage_digest = binding_digest.hash(binding_digest.Postimage, "postimage-8"),
        .file_mode = 0o644,
    };
    expected.intent_digest = intentDigest(expected);
    var intent_bytes: [max_intent_size]u8 = undefined;
    const encoded = try encodeIntent(&intent_bytes, expected);
    const decoded = try decodeIntent(encoded);
    try std.testing.expectEqual(expected.operation_id, decoded.operation_id);
    try std.testing.expectEqualStrings(expected.workspace_path, decoded.workspace_path);
    try std.testing.expect(binding_digest.eql(
        binding_digest.Preimage,
        expected.preimage_digest,
        decoded.preimage_digest,
    ));

    const expected_result: Result = .{
        .status = .stale,
        .intent_ref = 9,
        .intent_digest = expected.intent_digest,
    };
    var result_bytes: [result_size]u8 = undefined;
    try encodeResult(&result_bytes, expected_result);
    const decoded_result = try decodeResult(&result_bytes);
    try std.testing.expectEqualDeep(expected_result, decoded_result);
}

test "observe and apply classify one authorized Git-backed Patch Intent" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, io, "note.txt", "old\n");
    var relative_buffer: [128]u8 = undefined;
    const relative = try std.fmt.bufPrint(&relative_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_length = try std.Io.Dir.cwd().realPathFile(io, relative, &path_buffer);
    const path = path_buffer[0..path_length];
    try expectGit(io, path, &.{ "init", "-q" });
    try expectGit(io, path, &.{ "add", "note.txt" });
    const patch =
        "diff --git a/note.txt b/note.txt\n" ++
        "--- a/note.txt\n" ++
        "+++ b/note.txt\n" ++
        "@@ -1 +1 @@\n" ++
        "-old\n" ++
        "+new\n";
    const intent = try prepare(io, path, patch, testAction());
    try std.testing.expectEqual(Observation.preimage, try observe(io, intent, patch));
    try std.testing.expectEqual(Observation.postimage, try apply(io, intent, patch));
    try std.testing.expectEqual(Observation.postimage, try observe(io, intent, patch));
    try expectTestFile(tmp.dir, io, "note.txt", "new\n");
}

test "replacement and wrong mode fail closed before mutation" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, io, "note.txt", "old\n");
    var relative_buffer: [128]u8 = undefined;
    const relative = try std.fmt.bufPrint(&relative_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_length = try std.Io.Dir.cwd().realPathFile(io, relative, &path_buffer);
    const path = path_buffer[0..path_length];
    try expectGit(io, path, &.{ "init", "-q" });
    try expectGit(io, path, &.{ "add", "note.txt" });
    const patch =
        "diff --git a/note.txt b/note.txt\n--- a/note.txt\n+++ b/note.txt\n" ++
        "@@ -1 +1 @@\n-old\n+new\n";
    const intent = try prepare(io, path, patch, testAction());
    try tmp.dir.rename("note.txt", tmp.dir, "old-note.txt", io);
    try writeTestFile(tmp.dir, io, "note.txt", "old\n");
    try std.testing.expectEqual(Observation.diverged, try observe(io, intent, patch));
    try std.testing.expectError(error.PatchPreimageMismatch, apply(io, intent, patch));
    var file = try tmp.dir.openFile(io, "note.txt", .{ .mode = .read_write });
    try file.setPermissions(io, .fromMode(0o600));
    file.close(io);
    try std.testing.expectEqual(Observation.invalid, try observe(io, intent, patch));
    try expectTestFile(tmp.dir, io, "note.txt", "old\n");
}

test "replacement containing the expected postimage is divergence" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, io, "note.txt", "old\n");
    var relative_buffer: [128]u8 = undefined;
    const relative = try std.fmt.bufPrint(&relative_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_length = try std.Io.Dir.cwd().realPathFile(io, relative, &path_buffer);
    const path = path_buffer[0..path_length];
    try expectGit(io, path, &.{ "init", "-q" });
    try expectGit(io, path, &.{ "add", "note.txt" });
    const patch =
        "diff --git a/note.txt b/note.txt\n--- a/note.txt\n+++ b/note.txt\n" ++
        "@@ -1 +1 @@\n-old\n+new\n";
    const intent = try prepare(io, path, patch, testAction());
    try tmp.dir.rename("note.txt", tmp.dir, "old-note.txt", io);
    try writeTestFile(tmp.dir, io, "note.txt", "new\n");
    try std.testing.expectEqual(Observation.diverged, try observe(io, intent, patch));
}

test "trackedness is the exact literal target rather than a Git pathspec" {
    const io = std.testing.io;
    for ([_]struct { target: []const u8, tracked: []const u8 }{
        .{ .target = "note[1].txt", .tracked = "note1.txt" },
        .{ .target = "tree", .tracked = "tree/leaf.txt" },
    }) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        if (std.mem.eql(u8, case.target, "tree")) try tmp.dir.createDir(io, "tree", .default_dir);
        try writeTestFile(tmp.dir, io, case.tracked, "other\n");
        var relative_buffer: [128]u8 = undefined;
        const relative = try std.fmt.bufPrint(&relative_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path_length = try std.Io.Dir.cwd().realPathFile(io, relative, &path_buffer);
        const path = path_buffer[0..path_length];
        try expectGit(io, path, &.{ "init", "-q" });
        try expectGit(io, path, &.{ "add", case.tracked });
        if (std.mem.eql(u8, case.target, "tree")) try tmp.dir.deleteTree(io, "tree");
        try writeTestFile(tmp.dir, io, case.target, "old\n");
        var patch_buffer: [512]u8 = undefined;
        const patch = try std.fmt.bufPrint(
            &patch_buffer,
            "diff --git a/{s} b/{s}\n--- a/{s}\n+++ b/{s}\n@@ -1 +1 @@\n-old\n+new\n",
            .{ case.target, case.target, case.target, case.target },
        );
        try std.testing.expectError(
            error.NotTrackedRepositoryFile,
            prepare(io, path, patch, testAction()),
        );
        try expectTestFile(tmp.dir, io, case.target, "old\n");
    }
}

test "dirty overlap, missing, untracked, symlink, and special substitution never write" {
    const io = std.testing.io;
    const Mutation = enum { dirty, missing, untracked, symlink, special };
    for ([_]Mutation{ .dirty, .missing, .untracked, .symlink, .special }) |mutation| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try writeTestFile(tmp.dir, io, "note.txt", "old\n");
        var relative_buffer: [128]u8 = undefined;
        const relative = try std.fmt.bufPrint(&relative_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path_length = try std.Io.Dir.cwd().realPathFile(io, relative, &path_buffer);
        const path = path_buffer[0..path_length];
        try expectGit(io, path, &.{ "init", "-q" });
        try expectGit(io, path, &.{ "add", "note.txt" });
        const patch =
            "diff --git a/note.txt b/note.txt\n--- a/note.txt\n+++ b/note.txt\n" ++
            "@@ -1 +1 @@\n-old\n+new\n";
        const intent = try prepare(io, path, patch, testAction());
        switch (mutation) {
            .dirty => try writeTestFile(tmp.dir, io, "note.txt", "mine\n"),
            .missing => try tmp.dir.rename("note.txt", tmp.dir, "missing.txt", io),
            .untracked => try expectGit(io, path, &.{ "rm", "--cached", "-q", "note.txt" }),
            .symlink => {
                try tmp.dir.rename("note.txt", tmp.dir, "original.txt", io);
                try tmp.dir.symLink(io, "original.txt", "note.txt", .{});
            },
            .special => {
                try tmp.dir.rename("note.txt", tmp.dir, "original.txt", io);
                try tmp.dir.hardLink("original.txt", tmp.dir, "note.txt", io, .{});
            },
        }
        const observed = try observe(io, intent, patch);
        try std.testing.expectEqual(
            if (mutation == .dirty) Observation.diverged else Observation.invalid,
            observed,
        );
        try std.testing.expectError(error.PatchPreimageMismatch, apply(io, intent, patch));
        if (mutation == .dirty or mutation == .untracked) {
            try expectTestFile(tmp.dir, io, "note.txt", if (mutation == .dirty) "mine\n" else "old\n");
        }
    }
}

test "applicable control bytes prepare but remain exact data" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, io, "control.txt", "old\x1b[2J\n");
    var relative_buffer: [128]u8 = undefined;
    const relative = try std.fmt.bufPrint(&relative_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_length = try std.Io.Dir.cwd().realPathFile(io, relative, &path_buffer);
    const path = path_buffer[0..path_length];
    try expectGit(io, path, &.{ "init", "-q" });
    try expectGit(io, path, &.{ "add", "control.txt" });
    const patch =
        "diff --git a/control.txt b/control.txt\n" ++
        "--- a/control.txt\n" ++
        "+++ b/control.txt\n" ++
        "@@ -1 +1 @@\n" ++
        "-old\x1b[2J\n" ++
        "+new\x1b[2J\n";
    _ = try prepare(io, path, patch, testAction());
    try expectTestFile(tmp.dir, io, "control.txt", "old\x1b[2J\n");
}

test "Git-derived policy rejects unsupported patch operations" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, io, "a.txt", "old\n");
    try writeTestFile(tmp.dir, io, "b.txt", "x\n");
    try writeTestFile(tmp.dir, io, "a.bin", "\x00\x01\x02\x03");
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try canonicalTestPath(io, &tmp.sub_path, &path_buffer);
    try expectGit(io, path, &.{ "init", "-q" });
    try expectGit(io, path, &.{ "add", "a.txt", "b.txt", "a.bin" });

    try std.testing.expectError(error.MalformedPatch, prepare(io, path, "not a patch\n", testAction()));
    const binary =
        "diff --git a/a.bin b/a.bin\n" ++
        "index eaf36c1daccfdf325514461cd1a2ffbc139b5464..82ae0e33690b082386b8b25a3b10eba15c20285b 100644\n" ++
        "GIT binary patch\nliteral 4\nLcmZQzWMKvX01^NR\n\nliteral 4\nLcmZQzWMT#Y01f~L\n\n";
    try std.testing.expectError(error.BinaryPatch, prepare(io, path, binary, testAction()));
    const valid =
        "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-old\n+new\n";
    const second =
        "diff --git a/b.txt b/b.txt\n--- a/b.txt\n+++ b/b.txt\n@@ -1 +1 @@\n-x\n+y\n";
    try std.testing.expectError(error.MultipleFiles, prepare(io, path, valid ++ second, testAction()));
    try std.testing.expectError(error.UnsupportedSpecialFile, prepare(
        io,
        path,
        "diff --git a/new.txt b/new.txt\nnew file mode 100644\n--- /dev/null\n+++ b/new.txt\n@@ -0,0 +1 @@\n+new\n",
        testAction(),
    ));
    try std.testing.expectError(error.UnsupportedSpecialFile, prepare(
        io,
        path,
        "diff --git a/a.txt b/a.txt\ndeleted file mode 100644\n--- a/a.txt\n+++ /dev/null\n@@ -1 +0,0 @@\n-old\n",
        testAction(),
    ));
    try std.testing.expectError(error.UnsupportedSpecialFile, prepare(
        io,
        path,
        "diff --git a/a.txt b/renamed.txt\nsimilarity index 100%\nrename from a.txt\nrename to renamed.txt\n",
        testAction(),
    ));
    try std.testing.expectError(error.UnsupportedSpecialFile, prepare(
        io,
        path,
        "diff --git a/a.txt b/a.txt\nold mode 100644\nnew mode 100755\n",
        testAction(),
    ));
    var oversized: [max_patch_size + 1]u8 = @splat('x');
    oversized[oversized.len - 1] = '\n';
    try std.testing.expectError(error.PatchTooLarge, prepare(io, path, &oversized, testAction()));
}

test "symlink target and symlink parent are rejected without changing bytes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, io, "outside.txt", "outside\n");
    try tmp.dir.symLink(io, "outside.txt", "link.txt", .{});
    try tmp.dir.hardLink("outside.txt", tmp.dir, "hard.txt", io, .{});
    try tmp.dir.createDir(io, "real", .default_dir);
    try writeTestFile(tmp.dir, io, "real/note.txt", "old\n");
    try tmp.dir.symLink(io, "real", "linked", .{});
    var relative_buffer: [128]u8 = undefined;
    const relative = try std.fmt.bufPrint(&relative_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_length = try std.Io.Dir.cwd().realPathFile(io, relative, &path_buffer);
    const path = path_buffer[0..path_length];
    const target_patch =
        "diff --git a/link.txt b/link.txt\n--- a/link.txt\n+++ b/link.txt\n@@ -1 +1 @@\n-outside\n+changed\n";
    try std.testing.expectError(error.SymlinkEscape, prepare(io, path, target_patch, testAction()));
    const hardlink_patch =
        "diff --git a/hard.txt b/hard.txt\n--- a/hard.txt\n+++ b/hard.txt\n@@ -1 +1 @@\n-outside\n+changed\n";
    try std.testing.expectError(
        error.UnsupportedSpecialFile,
        prepare(io, path, hardlink_patch, testAction()),
    );
    const parent_patch =
        "diff --git a/linked/note.txt b/linked/note.txt\n--- a/linked/note.txt\n+++ b/linked/note.txt\n@@ -1 +1 @@\n-old\n+changed\n";
    try std.testing.expectError(error.SymlinkEscape, prepare(io, path, parent_patch, testAction()));
    try expectTestFile(tmp.dir, io, "outside.txt", "outside\n");
    try expectTestFile(tmp.dir, io, "real/note.txt", "old\n");
}

fn writeTestFile(dir: std.Io.Dir, io: std.Io, path: []const u8, bytes: []const u8) !void {
    var file = try dir.createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}

fn writeSizedTestFile(dir: std.Io.Dir, io: std.Io, path: []const u8, size: u64) !void {
    std.debug.assert(size >= 4);
    var file = try dir.createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, "old\n");
    const filler = "x\n" ** 2048;
    var remaining = size - 4;
    while (remaining > 0) {
        const count: usize = @intCast(@min(remaining, filler.len));
        try file.writeStreamingAll(io, filler[0..count]);
        remaining -= count;
    }
}

const SnapshotRaceTestState = struct {
    const Mode = enum { same_size_restore, grow };

    dir: std.Io.Dir,
    io: std.Io,
    mode: Mode,
    before_git_count: usize = 0,

    fn hook(self: *SnapshotRaceTestState) PreparationTestHook {
        return .{ .context = self, .call_fn = call };
    }

    fn call(context: *anyopaque, phase: PreparationTestPhase) !void {
        const self: *SnapshotRaceTestState = @ptrCast(@alignCast(context));
        var file = try self.dir.openFile(self.io, switch (self.mode) {
            .same_size_restore => "stable.txt",
            .grow => "growing.txt",
        }, .{ .mode = .read_write });
        defer file.close(self.io);
        switch (phase) {
            .after_first_snapshot_chunk => switch (self.mode) {
                .same_size_restore => try file.writePositionalAll(self.io, "y", 4096),
                .grow => try file.writePositionalAll(self.io, "x", max_file_size),
            },
            .before_git => {
                self.before_git_count += 1;
                if (self.mode == .same_size_restore) {
                    try file.writePositionalAll(self.io, "x", 4096);
                }
            },
        }
    }
};

fn expectSizedTestFileUnchanged(
    dir: std.Io.Dir,
    io: std.Io,
    path: []const u8,
    size: u64,
) !void {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    try std.testing.expectEqual(size, try file.length(io));
    var prefix: [4]u8 = undefined;
    try std.testing.expectEqual(prefix.len, try file.readPositionalAll(io, &prefix, 0));
    try std.testing.expectEqualStrings("old\n", &prefix);
}

fn expectTestFile(dir: std.Io.Dir, io: std.Io, path: []const u8, expected: []const u8) !void {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var buffer: [128]u8 = undefined;
    const count = try file.readPositionalAll(io, &buffer, 0);
    try std.testing.expectEqualStrings(expected, buffer[0..count]);
}

fn expectGit(io: std.Io, path: []const u8, arguments: []const []const u8) !void {
    if ((try runGit(io, path, arguments, null, null)).code != 0) return error.GitFixtureFailed;
}

fn canonicalTestPath(
    io: std.Io,
    sub_path: []const u8,
    out: *[std.Io.Dir.max_path_bytes]u8,
) ![]const u8 {
    var relative_buffer: [128]u8 = undefined;
    const relative = try std.fmt.bufPrint(&relative_buffer, ".zig-cache/tmp/{s}", .{sub_path});
    const length = try std.Io.Dir.cwd().realPathFile(io, relative, out);
    return out[0..length];
}

fn testAction() ActionContext {
    return .{ .operation_id = 11, .operation_generation = 1, .patch_ref = 13 };
}
