const std = @import("std");
const binding_digest = @import("binding.zig");

pub const max_patch_size = 16 * 1024;
pub const max_path_size = 1024;
pub const binding_size = 224;
pub const result_size = 112;
pub const version: u16 = 3;

const binding_magic = "ONEPATCH";
const result_magic = "ONEPRES\x00";

pub const Decision = enum(u8) {
    allow = 1,
    ask = 2,
    deny = 3,
};

pub const Validation = struct {
    workspace_path: []const u8,
    target_path: []const u8,
    patch_digest: binding_digest.PatchDescriptor,
    intent_digest: binding_digest.PatchIntent,
    preimage_digest: binding_digest.Preimage,
    postimage_digest: binding_digest.Postimage,
    workspace_digest: binding_digest.WorkspaceState,
    preimage_size: u64,
    preimage_inode: std.Io.File.INode,
};

pub const ActionContext = struct {
    operation_id: u64,
    operation_generation: u32,
    patch_ref: u64,
};

pub const Policy = struct {
    context: *anyopaque,
    classify_fn: *const fn (*anyopaque, PermissionSubject, []const u8) anyerror!Decision,
    ask_fn: *const fn (*anyopaque, PermissionSubject, []const u8) anyerror!bool,

    pub fn classify(self: Policy, subject: PermissionSubject, patch: []const u8) !Decision {
        return self.classify_fn(self.context, subject, patch);
    }

    pub fn ask(self: Policy, subject: PermissionSubject, patch: []const u8) !bool {
        return self.ask_fn(self.context, subject, patch);
    }
};

pub const PermissionSubject = struct {
    operation_id: u64,
    operation_generation: u32,
    validation: Validation,
};

pub const Binding = struct {
    decision: Decision,
    operation_id: u64,
    operation_generation: u32,
    ownership_epoch: u64,
    patch_ref: u64,
    patch_digest: binding_digest.PatchDescriptor,
    intent_digest: binding_digest.PatchIntent,
    workspace_digest: binding_digest.WorkspaceState,
    preimage_size: u64,
    preimage_inode: u64,
    preimage_digest: binding_digest.Preimage,
    postimage_digest: binding_digest.Postimage,
};

pub const ResultStatus = enum(u8) {
    denied = 1,
    stale = 2,
};

pub const Result = struct {
    status: ResultStatus,
    intent_digest: binding_digest.PatchIntent,
    expected_workspace_digest: binding_digest.WorkspaceState,
    observed_workspace_digest: ?binding_digest.WorkspaceState,
};

pub fn encodeBinding(out: *[binding_size]u8, binding: Binding) !void {
    if (binding.operation_id == 0 or binding.operation_generation == 0 or binding.ownership_epoch == 0 or
        binding.patch_ref == 0)
    {
        return error.InvalidPatchBinding;
    }
    @memset(out, 0);
    @memcpy(out[0..binding_magic.len], binding_magic);
    write(u16, out, 8, version);
    write(u16, out, 10, binding_size);
    out[12] = @intFromEnum(binding.decision);
    write(u64, out, 16, binding.operation_id);
    write(u32, out, 24, binding.operation_generation);
    write(u64, out, 32, binding.ownership_epoch);
    write(u64, out, 40, binding.patch_ref);
    @memcpy(out[48..80], &binding.patch_digest.bytes);
    @memcpy(out[80..112], &binding.intent_digest.bytes);
    @memcpy(out[112..144], &binding.workspace_digest.bytes);
    write(u64, out, 144, binding.preimage_size);
    write(u64, out, 152, binding.preimage_inode);
    @memcpy(out[160..192], &binding.preimage_digest.bytes);
    @memcpy(out[192..224], &binding.postimage_digest.bytes);
}

pub fn decodeBinding(bytes: *const [binding_size]u8) !Binding {
    if (!std.mem.eql(u8, bytes[0..binding_magic.len], binding_magic) or
        read(u16, bytes, 8) != version or read(u16, bytes, 10) != binding_size or
        bytes[13] != 0 or bytes[14] != 0 or bytes[15] != 0 or
        bytes[28] != 0 or bytes[29] != 0 or bytes[30] != 0 or bytes[31] != 0)
    {
        return error.InvalidPatchBinding;
    }
    const decision: Decision = switch (bytes[12]) {
        1 => .allow,
        2 => .ask,
        3 => .deny,
        else => return error.InvalidPatchBinding,
    };
    const binding: Binding = .{
        .decision = decision,
        .operation_id = read(u64, bytes, 16),
        .operation_generation = read(u32, bytes, 24),
        .ownership_epoch = read(u64, bytes, 32),
        .patch_ref = read(u64, bytes, 40),
        .patch_digest = .{ .bytes = bytes[48..80].* },
        .intent_digest = .{ .bytes = bytes[80..112].* },
        .workspace_digest = .{ .bytes = bytes[112..144].* },
        .preimage_size = read(u64, bytes, 144),
        .preimage_inode = read(u64, bytes, 152),
        .preimage_digest = .{ .bytes = bytes[160..192].* },
        .postimage_digest = .{ .bytes = bytes[192..224].* },
    };
    var canonical: [binding_size]u8 = undefined;
    try encodeBinding(&canonical, binding);
    if (!std.mem.eql(u8, &canonical, bytes)) return error.InvalidPatchBinding;
    return binding;
}

pub fn encodeResult(out: *[result_size]u8, result: Result) !void {
    if (result.status == .denied and result.observed_workspace_digest != null) {
        return error.InvalidPatchResult;
    }
    @memset(out, 0);
    @memcpy(out[0..result_magic.len], result_magic);
    write(u16, out, 8, version);
    out[10] = @intFromEnum(result.status);
    out[11] = @intFromBool(result.observed_workspace_digest != null);
    @memcpy(out[16..48], &result.intent_digest.bytes);
    @memcpy(out[48..80], &result.expected_workspace_digest.bytes);
    if (result.observed_workspace_digest) |observed| @memcpy(out[80..112], &observed.bytes);
}

pub fn decodeResult(bytes: *const [result_size]u8) !Result {
    if (!std.mem.eql(u8, bytes[0..result_magic.len], result_magic) or
        read(u16, bytes, 8) != version or bytes[11] > 1 or bytes[12] != 0 or
        bytes[13] != 0 or bytes[14] != 0 or bytes[15] != 0)
    {
        return error.InvalidPatchResult;
    }
    const status: ResultStatus = switch (bytes[10]) {
        1 => .denied,
        2 => .stale,
        else => return error.InvalidPatchResult,
    };
    const result: Result = .{
        .status = status,
        .intent_digest = .{ .bytes = bytes[16..48].* },
        .expected_workspace_digest = .{ .bytes = bytes[48..80].* },
        .observed_workspace_digest = if (bytes[11] == 1)
            .{ .bytes = bytes[80..112].* }
        else
            null,
    };
    var canonical: [result_size]u8 = undefined;
    try encodeResult(&canonical, result);
    if (!std.mem.eql(u8, &canonical, bytes)) return error.InvalidPatchResult;
    return result;
}

pub fn sameWorkspace(expected: Validation, observed: Validation) bool {
    return std.mem.eql(u8, expected.workspace_path, observed.workspace_path) and
        binding_digest.eql(binding_digest.PatchDescriptor, expected.patch_digest, observed.patch_digest) and
        binding_digest.eql(binding_digest.PatchIntent, expected.intent_digest, observed.intent_digest) and
        binding_digest.eql(binding_digest.WorkspaceState, expected.workspace_digest, observed.workspace_digest) and
        expected.preimage_size == observed.preimage_size and
        expected.preimage_inode == observed.preimage_inode and
        binding_digest.eql(binding_digest.Preimage, expected.preimage_digest, observed.preimage_digest) and
        std.mem.eql(u8, expected.target_path, observed.target_path);
}

pub fn descriptorDigest(patch: []const u8) binding_digest.PatchDescriptor {
    return binding_digest.hash(binding_digest.PatchDescriptor, patch);
}

pub fn validate(
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_path: []const u8,
    patch: []const u8,
    action: ActionContext,
) !Validation {
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
    const target_path = try validateStructure(patch);
    var workspace = try std.Io.Dir.cwd().openDir(io, workspace_path, .{});
    defer workspace.close(io);
    var target = try openRegularTarget(workspace, io, target_path);
    defer target.close(io);
    const stat = try target.stat(io);
    if (stat.kind != .file or stat.nlink != 1) return error.UnsupportedSpecialFile;
    const preimage_digest = try hashFile(io, target, stat.size);

    try gitTracked(io, workspace_path, target_path);
    try gitApplicable(io, workspace_path, patch);
    const postimage_digest = try expectedPostimage(
        allocator,
        io,
        workspace,
        workspace_path,
        target_path,
        patch,
    );
    var confirmed_target = try openRegularTarget(workspace, io, target_path);
    defer confirmed_target.close(io);
    const confirmed_stat = try confirmed_target.stat(io);
    if (confirmed_stat.kind != .file or confirmed_stat.nlink != 1) return error.UnsupportedSpecialFile;
    const confirmed_digest = try hashFile(io, confirmed_target, confirmed_stat.size);
    if (confirmed_stat.inode != stat.inode or confirmed_stat.size != stat.size or
        !binding_digest.eql(binding_digest.Preimage, confirmed_digest, preimage_digest))
    {
        return error.PreimageChangedDuringValidation;
    }
    const patch_digest = descriptorDigest(patch);
    const workspace_digest = workspaceDigest(
        workspace_path,
        target_path,
        preimage_digest,
        stat.size,
        stat.inode,
    );
    return .{
        .workspace_path = workspace_path,
        .target_path = target_path,
        .patch_digest = patch_digest,
        .intent_digest = intentDigest(
            action,
            workspace_path,
            target_path,
            patch_digest,
            preimage_digest,
            postimage_digest,
            stat.size,
            stat.inode,
        ),
        .preimage_digest = preimage_digest,
        .postimage_digest = postimage_digest,
        .workspace_digest = workspace_digest,
        .preimage_size = stat.size,
        .preimage_inode = stat.inode,
    };
}

pub fn validateStructure(patch: []const u8) ![]const u8 {
    if (patch.len == 0) return error.MalformedPatch;
    if (patch.len > max_patch_size) return error.PatchTooLarge;
    if (patch[patch.len - 1] != '\n' or std.mem.indexOfScalar(u8, patch, 0) != null or
        std.mem.indexOfScalar(u8, patch, '\r') != null)
    {
        return error.MalformedPatch;
    }

    var lines = std.mem.splitScalar(u8, patch, '\n');
    const first = lines.next() orelse return error.MalformedPatch;
    const prefix = "diff --git ";
    if (!std.mem.startsWith(u8, first, prefix)) return error.MalformedPatch;
    var paths = std.mem.splitScalar(u8, first[prefix.len..], ' ');
    const old_token = paths.next() orelse return error.MalformedPatch;
    const new_token = paths.next() orelse return error.MalformedPatch;
    if (paths.next() != null or !std.mem.startsWith(u8, old_token, "a/") or
        !std.mem.startsWith(u8, new_token, "b/") or old_token.len <= 2 or new_token.len <= 2 or
        !std.mem.eql(u8, old_token[2..], new_token[2..]))
    {
        return error.MalformedPatch;
    }
    const target_path = old_token[2..];
    try validateRelativePath(target_path);

    var line = lines.next() orelse return error.MalformedPatch;
    if (std.mem.startsWith(u8, line, "index ")) {
        line = lines.next() orelse return error.MalformedPatch;
    }
    try rejectMetadata(line);
    if (!std.mem.startsWith(u8, line, "--- ") or !std.mem.eql(u8, line[4..], old_token)) {
        return error.MalformedPatch;
    }
    line = lines.next() orelse return error.MalformedPatch;
    if (!std.mem.startsWith(u8, line, "+++ ") or !std.mem.eql(u8, line[4..], new_token)) {
        return error.MalformedPatch;
    }

    var saw_hunk = false;
    var saw_body = false;
    while (lines.next()) |body_line| {
        if (body_line.len == 0) {
            if (lines.next() != null) return error.MalformedPatch;
            break;
        }
        if (std.mem.startsWith(u8, body_line, "diff --git ") or
            std.mem.startsWith(u8, body_line, "index ") or
            std.mem.startsWith(u8, body_line, "--- ") or
            std.mem.startsWith(u8, body_line, "+++ "))
        {
            return error.MultipleFiles;
        }
        if (std.mem.startsWith(u8, body_line, "@@ ")) {
            if (std.mem.indexOfPos(u8, body_line, 3, " @@") == null) return error.MalformedPatch;
            saw_hunk = true;
            continue;
        }
        if (!saw_hunk) {
            try rejectMetadata(body_line);
            return error.MalformedPatch;
        }
        if (body_line[0] != ' ' and body_line[0] != '+' and body_line[0] != '-' and
            !std.mem.eql(u8, body_line, "\\ No newline at end of file"))
        {
            return error.MalformedPatch;
        }
        saw_body = true;
    }
    if (!saw_hunk or !saw_body) return error.MalformedPatch;
    return target_path;
}

fn validateRelativePath(path: []const u8) !void {
    if (path.len == 0 or path.len > max_path_size or path[0] == '/' or path[path.len - 1] == '/' or
        std.mem.indexOfScalar(u8, path, '\\') != null or std.mem.indexOfScalar(u8, path, '\t') != null)
    {
        return error.RepositoryEscape;
    }
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) {
            return error.PathTraversal;
        }
    }
}

fn rejectMetadata(line: []const u8) !void {
    const unsupported = [_][]const u8{
        "GIT binary patch",
        "Binary files ",
        "new file mode ",
        "deleted file mode ",
        "old mode ",
        "new mode ",
        "similarity index ",
        "dissimilarity index ",
        "rename from ",
        "rename to ",
        "copy from ",
        "copy to ",
    };
    for (unsupported) |prefix| {
        if (std.mem.startsWith(u8, line, prefix)) {
            if (std.mem.startsWith(u8, prefix, "GIT binary") or std.mem.startsWith(u8, prefix, "Binary")) {
                return error.BinaryPatch;
            }
            return error.UnsupportedSpecialFile;
        }
    }
}

fn openRegularTarget(workspace: std.Io.Dir, io: std.Io, target_path: []const u8) !std.Io.File {
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

fn expectedPostimage(
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace: std.Io.Dir,
    workspace_path: []const u8,
    target_path: []const u8,
    patch: []const u8,
) !binding_digest.Postimage {
    _ = allocator;
    _ = workspace_path;
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
    try workspace.copyFile(target_path, temporary, target_path, io, .{ .make_path = true });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "/private/tmp/{s}", .{name});
    const term = try runGit(
        io,
        path,
        &.{ "apply", "--no-index", "--whitespace=nowarn", "-" },
        patch,
    );
    if (term != 0) return error.PatchNotApplicable;
    var target = try openRegularTarget(temporary, io, target_path);
    defer target.close(io);
    const stat = try target.stat(io);
    if (stat.kind != .file or stat.nlink != 1) return error.UnsupportedSpecialFile;
    return hashFileAs(binding_digest.Postimage, io, target, stat.size);
}

fn gitTracked(io: std.Io, workspace_path: []const u8, target_path: []const u8) !void {
    const term = try runGit(io, workspace_path, &.{ "ls-files", "--error-unmatch", "--", target_path }, null);
    if (term != 0) return error.NotTrackedRepositoryFile;
}

fn gitApplicable(io: std.Io, workspace_path: []const u8, patch: []const u8) !void {
    const term = try runGit(io, workspace_path, &.{ "apply", "--check", "--whitespace=nowarn", "-" }, patch);
    if (term != 0) return error.PatchNotApplicable;
}

fn runGit(
    io: std.Io,
    workspace_path: []const u8,
    arguments: []const []const u8,
    input: ?[]const u8,
) !u8 {
    var argv_buffer: [8][]const u8 = undefined;
    if (arguments.len + 1 > argv_buffer.len) return error.InvalidGitInvocation;
    argv_buffer[0] = "/usr/bin/git";
    @memcpy(argv_buffer[1..][0..arguments.len], arguments);
    var environment = std.process.Environ.Map.init(std.heap.page_allocator);
    defer environment.deinit();
    try environment.put("PATH", "/usr/bin:/bin");
    try environment.put("LC_ALL", "C");
    var child = try std.process.spawn(io, .{
        .argv = argv_buffer[0 .. arguments.len + 1],
        .cwd = .{ .path = workspace_path },
        .environ_map = &environment,
        .stdin = if (input == null) .ignore else .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    errdefer {
        child.kill(io);
        _ = child.wait(io) catch {};
    }
    if (input) |bytes| {
        try child.stdin.?.writeStreamingAll(io, bytes);
        child.stdin.?.close(io);
        child.stdin = null;
    }
    const term = try child.wait(io);
    return switch (term) {
        .exited => |code| code,
        else => 255,
    };
}

fn workspaceDigest(
    workspace_path: []const u8,
    target_path: []const u8,
    preimage_digest: binding_digest.Preimage,
    size: u64,
    inode: std.Io.File.INode,
) binding_digest.WorkspaceState {
    var hasher = binding_digest.Hasher(binding_digest.WorkspaceState).init();
    updateLengthPrefixed(binding_digest.WorkspaceState, &hasher, workspace_path);
    updateLengthPrefixed(binding_digest.WorkspaceState, &hasher, target_path);
    hasher.update(&preimage_digest.bytes);
    var integers: [16]u8 = undefined;
    std.mem.writeInt(u64, integers[0..8], size, .little);
    std.mem.writeInt(u64, integers[8..16], @intCast(inode), .little);
    hasher.update(&integers);
    return hasher.final();
}

fn intentDigest(
    action: ActionContext,
    workspace_path: []const u8,
    target_path: []const u8,
    patch_digest: binding_digest.PatchDescriptor,
    preimage_digest: binding_digest.Preimage,
    postimage_digest: binding_digest.Postimage,
    size: u64,
    inode: std.Io.File.INode,
) binding_digest.PatchIntent {
    var hasher = binding_digest.Hasher(binding_digest.PatchIntent).init();
    var integers: [32]u8 = @splat(0);
    std.mem.writeInt(u64, integers[0..8], action.operation_id, .little);
    std.mem.writeInt(u32, integers[8..12], action.operation_generation, .little);
    std.mem.writeInt(u64, integers[16..24], action.patch_ref, .little);
    std.mem.writeInt(u64, integers[24..32], size, .little);
    hasher.update(&integers);
    updateLengthPrefixed(binding_digest.PatchIntent, &hasher, workspace_path);
    updateLengthPrefixed(binding_digest.PatchIntent, &hasher, target_path);
    hasher.update("regular-file-single-link-v1\x00");
    hasher.update(&patch_digest.bytes);
    hasher.update(&preimage_digest.bytes);
    hasher.update(&postimage_digest.bytes);
    var inode_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &inode_bytes, @intCast(inode), .little);
    hasher.update(&inode_bytes);
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
    const validated = try validate(std.testing.allocator, io, path, patch, testAction());
    try std.testing.expectEqualStrings("note.txt", validated.target_path);
    try std.testing.expect(binding_digest.eql(
        binding_digest.PatchDescriptor,
        descriptorDigest(patch),
        validated.patch_digest,
    ));
    try std.testing.expectEqual(@as(usize, 32), validated.workspace_digest.bytes.len);
    try std.testing.expectEqual(@as(usize, 32), validated.intent_digest.bytes.len);
    try std.testing.expectEqual(@as(usize, 32), validated.postimage_digest.bytes.len);
    try std.testing.expect(binding_digest.eql(
        binding_digest.Postimage,
        binding_digest.hash(binding_digest.Postimage, "new\n"),
        validated.postimage_digest,
    ));
    const changed_generation = intentDigest(
        .{ .operation_id = 11, .operation_generation = 2, .patch_ref = 13 },
        path,
        validated.target_path,
        validated.patch_digest,
        validated.preimage_digest,
        validated.postimage_digest,
        validated.preimage_size,
        validated.preimage_inode,
    );
    try std.testing.expect(!binding_digest.eql(
        binding_digest.PatchIntent,
        validated.intent_digest,
        changed_generation,
    ));
    try std.testing.expectEqual(@as(u64, 4), validated.preimage_size);
    var actual: [4]u8 = undefined;
    var file = try tmp.dir.openFile(io, "note.txt", .{});
    defer file.close(io);
    try std.testing.expectEqual(@as(usize, 4), try file.readPositionalAll(io, &actual, 0));
    try std.testing.expectEqualStrings("old\n", &actual);
}

test "permission binding and typed result are canonical" {
    const preimage = binding_digest.hash(binding_digest.Preimage, "preimage-7");
    const expected: Binding = .{
        .decision = .ask,
        .operation_id = 11,
        .operation_generation = 2,
        .ownership_epoch = 3,
        .patch_ref = 4,
        .patch_digest = binding_digest.hash(binding_digest.PatchDescriptor, "patch-5"),
        .intent_digest = binding_digest.hash(binding_digest.PatchIntent, "intent-5"),
        .workspace_digest = binding_digest.hash(binding_digest.WorkspaceState, "workspace-6"),
        .preimage_size = 7,
        .preimage_inode = 8,
        .preimage_digest = preimage,
        .postimage_digest = binding_digest.hash(binding_digest.Postimage, "postimage-8"),
    };
    var binding_bytes: [binding_size]u8 = undefined;
    try encodeBinding(&binding_bytes, expected);
    const decoded = try decodeBinding(&binding_bytes);
    try std.testing.expectEqual(expected.operation_id, decoded.operation_id);
    try std.testing.expectEqual(expected.decision, decoded.decision);
    try std.testing.expect(binding_digest.eql(
        binding_digest.Preimage,
        preimage,
        decoded.preimage_digest,
    ));

    const expected_result: Result = .{
        .status = .stale,
        .intent_digest = binding_digest.hash(binding_digest.PatchIntent, "intent-9"),
        .expected_workspace_digest = binding_digest.hash(binding_digest.WorkspaceState, "workspace-10"),
        .observed_workspace_digest = binding_digest.hash(binding_digest.WorkspaceState, "workspace-11"),
    };
    var result_bytes: [result_size]u8 = undefined;
    try encodeResult(&result_bytes, expected_result);
    const decoded_result = try decodeResult(&result_bytes);
    try std.testing.expectEqualDeep(expected_result, decoded_result);

    const unavailable_result: Result = .{
        .status = .stale,
        .intent_digest = expected_result.intent_digest,
        .expected_workspace_digest = expected_result.expected_workspace_digest,
        .observed_workspace_digest = null,
    };
    try encodeResult(&result_bytes, unavailable_result);
    try std.testing.expectEqualDeep(unavailable_result, try decodeResult(&result_bytes));
}

test "applicable control bytes validate but remain exact data" {
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
    _ = try validate(std.testing.allocator, io, path, patch, testAction());
    try expectTestFile(tmp.dir, io, "control.txt", "old\x1b[2J\n");
}

test "structural rejection classes fail before workspace access" {
    const valid =
        "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-old\n+new\n";
    try std.testing.expectEqualStrings("a.txt", try validateStructure(valid));
    try std.testing.expectError(error.MalformedPatch, validateStructure("not a patch\n"));
    try std.testing.expectError(error.BinaryPatch, validateStructure(
        "diff --git a/a.txt b/a.txt\nGIT binary patch\nliteral 0\n",
    ));
    try std.testing.expectError(error.MultipleFiles, validateStructure(
        valid ++ "diff --git a/b.txt b/b.txt\n--- a/b.txt\n+++ b/b.txt\n@@ -1 +1 @@\n-x\n+y\n",
    ));
    try std.testing.expectError(error.MultipleFiles, validateStructure(
        valid ++ "--- a/b.txt\n+++ b/b.txt\n@@ -1 +1 @@\n-x\n+y\n",
    ));
    try std.testing.expectError(error.PathTraversal, validateStructure(
        "diff --git a/../a.txt b/../a.txt\n--- a/../a.txt\n+++ b/../a.txt\n@@ -1 +1 @@\n-x\n+y\n",
    ));
    try std.testing.expectError(error.RepositoryEscape, validateStructure(
        "diff --git a//tmp/a b//tmp/a\n--- a//tmp/a\n+++ b//tmp/a\n@@ -1 +1 @@\n-x\n+y\n",
    ));
    try std.testing.expectError(error.UnsupportedSpecialFile, validateStructure(
        "diff --git a/a.txt b/a.txt\nnew file mode 100644\n--- /dev/null\n+++ b/a.txt\n@@ -0,0 +1 @@\n+x\n",
    ));
    var oversized: [max_patch_size + 1]u8 = @splat('x');
    oversized[oversized.len - 1] = '\n';
    try std.testing.expectError(error.PatchTooLarge, validateStructure(&oversized));
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
    try std.testing.expectError(error.SymlinkEscape, validate(std.testing.allocator, io, path, target_patch, testAction()));
    const hardlink_patch =
        "diff --git a/hard.txt b/hard.txt\n--- a/hard.txt\n+++ b/hard.txt\n@@ -1 +1 @@\n-outside\n+changed\n";
    try std.testing.expectError(
        error.UnsupportedSpecialFile,
        validate(std.testing.allocator, io, path, hardlink_patch, testAction()),
    );
    const parent_patch =
        "diff --git a/linked/note.txt b/linked/note.txt\n--- a/linked/note.txt\n+++ b/linked/note.txt\n@@ -1 +1 @@\n-old\n+changed\n";
    try std.testing.expectError(error.SymlinkEscape, validate(std.testing.allocator, io, path, parent_patch, testAction()));
    try expectTestFile(tmp.dir, io, "outside.txt", "outside\n");
    try expectTestFile(tmp.dir, io, "real/note.txt", "old\n");
}

fn writeTestFile(dir: std.Io.Dir, io: std.Io, path: []const u8, bytes: []const u8) !void {
    var file = try dir.createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}

fn expectTestFile(dir: std.Io.Dir, io: std.Io, path: []const u8, expected: []const u8) !void {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var buffer: [128]u8 = undefined;
    const count = try file.readPositionalAll(io, &buffer, 0);
    try std.testing.expectEqualStrings(expected, buffer[0..count]);
}

fn expectGit(io: std.Io, path: []const u8, arguments: []const []const u8) !void {
    if (try runGit(io, path, arguments, null) != 0) return error.GitFixtureFailed;
}

fn testAction() ActionContext {
    return .{ .operation_id = 11, .operation_generation = 1, .patch_ref = 13 };
}
