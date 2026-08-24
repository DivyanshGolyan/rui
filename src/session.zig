const std = @import("std");
const durable_transition = @import("durable_transition.zig");
const harness = @import("harness.zig");
const operation_log = @import("operation_log.zig");
const owner_fence = @import("owner_fence.zig");

pub const manifest_max_size = 2048;
pub const manifest_header_size = 128;
pub const conversation_record_size = 80;
pub const version: u16 = 1;

const manifest_magic = "ONESESS\x00";
const conversation_magic = "ONECONV\x00";
const manifest_path = "manifest";
const manifest_temp_path = "manifest.tmp";
const conversation_path = "conversation.log";
const lock_path = "owner.lock";

const manifest_crc_offset = 20;

pub const Identities = struct {
    session_id: u64,
    agent_id: u64,
    task_id: u64,
    branch_id: u64,

    fn validate(self: Identities) !void {
        const values = [_]u64{
            self.session_id,
            self.agent_id,
            self.task_id,
            self.branch_id,
        };
        for (values, 0..) |value, index| {
            if (value == 0) return error.InvalidIdentity;
            for (values[index + 1 ..]) |other| {
                if (value == other) return error.InvalidIdentity;
            }
        }
    }
};

pub const Config = struct {
    workspace_path: []const u8,
    model: []const u8,
    task: []const u8,
};

pub const CreateConfig = struct {
    identities: Identities,
    workspace_path: []const u8,
    model: []const u8,
    task: []const u8,
};

pub const OwnerToken = struct {
    session_id: u64,
    epoch: u64,
};

pub const EntryKind = enum(u8) {
    user = 1,
    assistant = 2,
    tool_result = 3,
    context_checkpoint = 4,
};

pub const ConversationEntry = struct {
    kind: EntryKind,
    session_id: u64,
    entry_id: u64,
    parent_id: u64,
    task_id: u64,
    content_ref: u64,
    sequence: u64,
};

pub const ManifestView = struct {
    identities: Identities,
    ownership_epoch: u64,
    active_leaf_id: u64,
    entry_count: u64,
    workspace_path: []const u8,
    model: []const u8,
    task: []const u8,
};

pub const Restored = struct {
    session: Session,
    manifest: ManifestView,
};

pub const Projection = struct {
    session_id: u64,
    task_id: u64,
    active_leaf_id: u64,
    ownership_epoch: u64,
};

pub const AppendBoundary = enum {
    after_entry_sync,
};

pub const FaultHook = struct {
    context: *anyopaque,
    reached: *const fn (*anyopaque, AppendBoundary) anyerror!void,
};

pub const Session = struct {
    io: std.Io,
    dir: std.Io.Dir,
    lock_file: std.Io.File,
    session_id: u64,
    agent_id: u64,
    task_id: u64,
    branch_id: u64,
    ownership_epoch: u64,
    active_leaf_id: u64,
    entry_count: u64,
    open: bool = true,
    failed: bool = false,

    pub fn create(root: std.Io.Dir, io: std.Io, config: Config) !Session {
        for (0..8) |_| {
            var identities: Identities = undefined;
            io.random(std.mem.asBytes(&identities));
            identities.validate() catch continue;
            return createExact(root, io, .{
                .identities = identities,
                .workspace_path = config.workspace_path,
                .model = config.model,
                .task = config.task,
            }) catch |err| switch (err) {
                error.PathAlreadyExists => continue,
                else => return err,
            };
        }
        return error.IdentityAllocationExhausted;
    }

    fn createExact(root: std.Io.Dir, io: std.Io, config: CreateConfig) !Session {
        try config.identities.validate();
        if (config.workspace_path.len == 0 or config.model.len == 0 or config.task.len == 0) {
            return error.InvalidSessionMetadata;
        }
        try validateWorkspace(io, config.workspace_path);

        const initial_view: ManifestView = .{
            .identities = config.identities,
            .ownership_epoch = 1,
            .active_leaf_id = 1,
            .entry_count = 1,
            .workspace_path = config.workspace_path,
            .model = config.model,
            .task = config.task,
        };
        var validation_buffer: [manifest_max_size]u8 = undefined;
        _ = try encodeManifest(&validation_buffer, initial_view);

        var name_buffer: [16]u8 = undefined;
        const name = sessionName(config.identities.session_id, &name_buffer);
        try root.createDir(io, name, .default_dir);
        try syncDir(root, io);
        var dir = try root.openDir(io, name, .{});
        errdefer dir.close(io);

        var lock_file = try dir.createFile(io, lock_path, .{
            .exclusive = true,
            .lock = .exclusive,
            .lock_nonblocking = true,
        });
        errdefer {
            lock_file.unlock(io);
            lock_file.close(io);
        }

        var conversation = try dir.createFile(io, conversation_path, .{ .exclusive = true });
        defer conversation.close(io);
        try appendEntryFile(conversation, io, 0, .{
            .kind = .user,
            .session_id = config.identities.session_id,
            .entry_id = 1,
            .parent_id = 0,
            .task_id = config.identities.task_id,
            .content_ref = config.identities.task_id,
            .sequence = 1,
        });
        try publishManifest(dir, io, initial_view);

        return fromManifest(io, dir, lock_file, initial_view);
    }

    pub fn openExisting(
        root: std.Io.Dir,
        io: std.Io,
        session_id: u64,
        manifest_buffer: *[manifest_max_size]u8,
    ) !Restored {
        if (session_id == 0) return error.InvalidIdentity;
        var name_buffer: [16]u8 = undefined;
        const name = sessionName(session_id, &name_buffer);
        var dir = try root.openDir(io, name, .{});
        errdefer dir.close(io);
        var lock_file = dir.openFile(io, lock_path, .{
            .mode = .read_write,
            .lock = .exclusive,
            .lock_nonblocking = true,
        }) catch |err| switch (err) {
            error.WouldBlock => return error.SessionBusy,
            else => return err,
        };
        errdefer {
            lock_file.unlock(io);
            lock_file.close(io);
        }

        var view = try readManifest(dir, io, manifest_buffer);
        if (view.identities.session_id != session_id) return error.SessionIdentityMismatch;
        try validateWorkspace(io, view.workspace_path);
        if (view.ownership_epoch == std.math.maxInt(u64)) return error.OwnershipEpochExhausted;
        view.ownership_epoch += 1;
        try publishManifest(dir, io, view);

        view = try reconcileConversation(dir, io, view);
        const restored_view = try readManifest(dir, io, manifest_buffer);
        return .{
            .session = fromManifest(io, dir, lock_file, view),
            .manifest = restored_view,
        };
    }

    fn fromManifest(
        io: std.Io,
        dir: std.Io.Dir,
        lock_file: std.Io.File,
        view: ManifestView,
    ) Session {
        return .{
            .io = io,
            .dir = dir,
            .lock_file = lock_file,
            .session_id = view.identities.session_id,
            .agent_id = view.identities.agent_id,
            .task_id = view.identities.task_id,
            .branch_id = view.identities.branch_id,
            .ownership_epoch = view.ownership_epoch,
            .active_leaf_id = view.active_leaf_id,
            .entry_count = view.entry_count,
        };
    }

    pub fn ownerToken(self: *const Session) OwnerToken {
        return .{ .session_id = self.session_id, .epoch = self.ownership_epoch };
    }

    pub fn projection(self: *const Session) Projection {
        return .{
            .session_id = self.session_id,
            .task_id = self.task_id,
            .active_leaf_id = self.active_leaf_id,
            .ownership_epoch = self.ownership_epoch,
        };
    }

    pub fn fence(self: *Session) owner_fence.Fence {
        return .{ .context = self, .authorize = authorizeFence };
    }

    fn authorizeFence(context: *anyopaque) anyerror!void {
        const self: *Session = @ptrCast(@alignCast(context));
        try self.authorize(self.ownerToken());
    }

    pub fn authorize(self: *Session, token: OwnerToken) !void {
        if (!self.open) return error.SessionClosed;
        if (self.failed) return error.SessionUnavailable;
        if (token.session_id != self.session_id or token.epoch != self.ownership_epoch) {
            return error.StaleOwner;
        }
        var manifest_buffer: [manifest_max_size]u8 = undefined;
        const view = try readManifest(self.dir, self.io, &manifest_buffer);
        if (view.identities.session_id != token.session_id or
            view.ownership_epoch != token.epoch)
        {
            return error.StaleOwner;
        }
    }

    pub fn appendConversation(
        self: *Session,
        token: OwnerToken,
        kind: EntryKind,
        content_ref: u64,
        fault: ?FaultHook,
    ) !ConversationEntry {
        if (content_ref == 0) return error.InvalidContentReference;
        try self.authorize(token);
        return self.appendAuthorized(kind, content_ref, fault) catch |err| {
            self.failed = true;
            return err;
        };
    }

    fn appendAuthorized(
        self: *Session,
        kind: EntryKind,
        content_ref: u64,
        fault: ?FaultHook,
    ) !ConversationEntry {
        var manifest_buffer: [manifest_max_size]u8 = undefined;
        var view = try readManifest(self.dir, self.io, &manifest_buffer);
        view = try reconcileConversation(self.dir, self.io, view);
        if (view.entry_count == std.math.maxInt(u64)) return error.EntryIdentityExhausted;

        const entry: ConversationEntry = .{
            .kind = kind,
            .session_id = self.session_id,
            .entry_id = view.entry_count + 1,
            .parent_id = view.active_leaf_id,
            .task_id = self.task_id,
            .content_ref = content_ref,
            .sequence = view.entry_count + 1,
        };
        var conversation = try self.dir.openFile(self.io, conversation_path, .{ .mode = .read_write });
        defer conversation.close(self.io);
        try appendEntryFile(conversation, self.io, view.entry_count, entry);
        if (fault) |hook| try hook.reached(hook.context, .after_entry_sync);

        view.active_leaf_id = entry.entry_id;
        view.entry_count = entry.sequence;
        try publishManifest(self.dir, self.io, view);
        self.active_leaf_id = view.active_leaf_id;
        self.entry_count = view.entry_count;
        return entry;
    }

    pub fn readEntry(self: *Session, sequence: u64) !ConversationEntry {
        if (!self.open) return error.SessionClosed;
        if (sequence == 0 or sequence > self.entry_count) return error.InvalidEntrySequence;
        var conversation = try self.dir.openFile(self.io, conversation_path, .{});
        defer conversation.close(self.io);
        return readEntryFile(conversation, self.io, sequence - 1);
    }

    pub fn close(self: *Session) void {
        if (!self.open) return;
        self.lock_file.unlock(self.io);
        self.lock_file.close(self.io);
        self.dir.close(self.io);
        self.open = false;
    }
};

pub fn formatId(session_id: u64, buffer: *[16]u8) ![]const u8 {
    if (session_id == 0) return error.InvalidIdentity;
    return std.fmt.bufPrint(buffer, "{x:0>16}", .{session_id});
}

fn sessionName(session_id: u64, buffer: *[16]u8) []const u8 {
    return formatId(session_id, buffer) catch unreachable;
}

fn syncDir(dir: std.Io.Dir, io: std.Io) !void {
    const directory_file: std.Io.File = .{
        .handle = dir.handle,
        .flags = .{ .nonblocking = false },
    };
    try directory_file.sync(io);
}

fn validateWorkspace(io: std.Io, path: []const u8) !void {
    var workspace = if (std.fs.path.isAbsolute(path))
        std.Io.Dir.openDirAbsolute(io, path, .{}) catch return error.WorkspaceUnavailable
    else
        std.Io.Dir.cwd().openDir(io, path, .{}) catch return error.WorkspaceUnavailable;
    defer workspace.close(io);
    workspace.access(io, ".git", .{}) catch return error.NotGitWorktree;
}

fn publishManifest(dir: std.Io.Dir, io: std.Io, view: ManifestView) !void {
    var encoded: [manifest_max_size]u8 = undefined;
    const bytes = try encodeManifest(&encoded, view);
    var temp = try dir.createFile(io, manifest_temp_path, .{});
    var temp_open = true;
    defer if (temp_open) temp.close(io);
    try temp.writePositionalAll(io, bytes, 0);
    try temp.sync(io);
    temp.close(io);
    temp_open = false;
    try dir.rename(manifest_temp_path, dir, manifest_path, io);
    try syncDir(dir, io);
}

fn readManifest(
    dir: std.Io.Dir,
    io: std.Io,
    buffer: *[manifest_max_size]u8,
) !ManifestView {
    var file = try dir.openFile(io, manifest_path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.size < manifest_header_size) return error.TruncatedManifest;
    if (stat.size > manifest_max_size) return error.InvalidManifestLength;
    const expected_size: usize = @intCast(stat.size);
    const bytes_read = try file.readPositionalAll(io, buffer[0..expected_size], 0);
    if (bytes_read != expected_size) return error.TruncatedManifest;
    return decodeManifest(buffer[0..bytes_read]);
}

fn encodeManifest(out: *[manifest_max_size]u8, view: ManifestView) ![]const u8 {
    try view.identities.validate();
    if (view.ownership_epoch == 0) return error.InvalidOwnershipEpoch;
    if (view.entry_count == 0 or view.active_leaf_id != view.entry_count) {
        return error.InvalidActiveLeaf;
    }
    if (view.workspace_path.len == 0 or view.model.len == 0 or view.task.len == 0) {
        return error.InvalidSessionMetadata;
    }
    const total = manifest_header_size +
        view.workspace_path.len +
        view.model.len +
        view.task.len;
    if (total > out.len or
        view.workspace_path.len > std.math.maxInt(u16) or
        view.model.len > std.math.maxInt(u16) or
        view.task.len > std.math.maxInt(u16))
    {
        return error.SessionMetadataTooLarge;
    }

    @memset(out, 0);
    @memcpy(out[0..manifest_magic.len], manifest_magic);
    write(u16, out, 8, version);
    write(u16, out, 10, manifest_header_size);
    write(u32, out, 12, 0);
    write(u32, out, 16, @intCast(total));
    write(u64, out, 24, view.identities.session_id);
    write(u64, out, 32, view.identities.agent_id);
    write(u64, out, 40, view.identities.task_id);
    write(u64, out, 48, view.identities.branch_id);
    write(u64, out, 56, view.ownership_epoch);
    write(u64, out, 64, view.active_leaf_id);
    write(u64, out, 72, view.entry_count);
    write(u16, out, 80, @intCast(view.workspace_path.len));
    write(u16, out, 82, @intCast(view.model.len));
    write(u16, out, 84, @intCast(view.task.len));
    var cursor: usize = manifest_header_size;
    @memcpy(out[cursor..][0..view.workspace_path.len], view.workspace_path);
    cursor += view.workspace_path.len;
    @memcpy(out[cursor..][0..view.model.len], view.model);
    cursor += view.model.len;
    @memcpy(out[cursor..][0..view.task.len], view.task);
    const crc = manifestCrc(out[0..total]);
    write(u32, out, manifest_crc_offset, crc);
    return out[0..total];
}

fn decodeManifest(bytes: []const u8) !ManifestView {
    if (bytes.len < manifest_header_size) return error.TruncatedManifest;
    if (!std.mem.eql(u8, bytes[0..manifest_magic.len], manifest_magic)) {
        return error.InvalidManifestMagic;
    }
    if (read(u16, bytes, 8) != version) return error.UnsupportedManifestVersion;
    if (read(u16, bytes, 10) != manifest_header_size) return error.InvalidManifestHeader;
    if (read(u32, bytes, 12) != 0) return error.UnsupportedManifestFlags;
    const total: usize = read(u32, bytes, 16);
    if (total != bytes.len or total > manifest_max_size) return error.InvalidManifestLength;
    if (read(u32, bytes, manifest_crc_offset) != manifestCrc(bytes)) {
        return error.ManifestChecksumMismatch;
    }
    for (bytes[86..manifest_header_size]) |byte| {
        if (byte != 0) return error.NonzeroManifestReservedByte;
    }

    const workspace_len: usize = read(u16, bytes, 80);
    const model_len: usize = read(u16, bytes, 82);
    const task_len: usize = read(u16, bytes, 84);
    if (manifest_header_size + workspace_len + model_len + task_len != total or
        workspace_len == 0 or model_len == 0 or task_len == 0)
    {
        return error.InvalidSessionMetadata;
    }
    var cursor: usize = manifest_header_size;
    const workspace = bytes[cursor..][0..workspace_len];
    cursor += workspace_len;
    const model = bytes[cursor..][0..model_len];
    cursor += model_len;
    const task = bytes[cursor..][0..task_len];
    const view: ManifestView = .{
        .identities = .{
            .session_id = read(u64, bytes, 24),
            .agent_id = read(u64, bytes, 32),
            .task_id = read(u64, bytes, 40),
            .branch_id = read(u64, bytes, 48),
        },
        .ownership_epoch = read(u64, bytes, 56),
        .active_leaf_id = read(u64, bytes, 64),
        .entry_count = read(u64, bytes, 72),
        .workspace_path = workspace,
        .model = model,
        .task = task,
    };
    try view.identities.validate();
    if (view.ownership_epoch == 0) return error.InvalidOwnershipEpoch;
    if (view.entry_count == 0 or view.active_leaf_id != view.entry_count) {
        return error.InvalidActiveLeaf;
    }
    return view;
}

fn manifestCrc(bytes: []const u8) u32 {
    var crc: std.hash.Crc32 = .init();
    crc.update(bytes[0..manifest_crc_offset]);
    crc.update(bytes[manifest_crc_offset + @sizeOf(u32) ..]);
    return crc.final();
}

fn encodeEntry(out: *[conversation_record_size]u8, entry: ConversationEntry) !void {
    if (entry.session_id == 0 or entry.entry_id == 0 or entry.task_id == 0 or
        entry.content_ref == 0 or entry.sequence == 0 or entry.entry_id != entry.sequence)
    {
        return error.InvalidConversationEntry;
    }
    if ((entry.sequence == 1 and entry.parent_id != 0) or
        (entry.sequence > 1 and
            (entry.parent_id == 0 or entry.parent_id >= entry.entry_id)))
    {
        return error.InvalidConversationParent;
    }
    @memset(out, 0);
    @memcpy(out[0..conversation_magic.len], conversation_magic);
    write(u16, out, 8, version);
    out[10] = @intFromEnum(entry.kind);
    out[11] = 0;
    write(u64, out, 12, entry.session_id);
    write(u64, out, 20, entry.entry_id);
    write(u64, out, 28, entry.parent_id);
    write(u64, out, 36, entry.task_id);
    write(u64, out, 44, entry.content_ref);
    write(u64, out, 52, entry.sequence);
    write(u32, out, 60, std.hash.Crc32.hash(out[0..60]));
}

fn decodeEntry(bytes: *const [conversation_record_size]u8) !ConversationEntry {
    if (!std.mem.eql(u8, bytes[0..conversation_magic.len], conversation_magic)) {
        return error.InvalidConversationMagic;
    }
    if (read(u16, bytes, 8) != version) return error.UnsupportedConversationVersion;
    if (bytes[11] != 0) return error.UnsupportedConversationFlags;
    for (bytes[64..]) |byte| {
        if (byte != 0) return error.NonzeroConversationReservedByte;
    }
    if (read(u32, bytes, 60) != std.hash.Crc32.hash(bytes[0..60])) {
        return error.ConversationChecksumMismatch;
    }
    const kind: EntryKind = switch (bytes[10]) {
        1 => .user,
        2 => .assistant,
        3 => .tool_result,
        4 => .context_checkpoint,
        else => return error.InvalidConversationKind,
    };
    const entry: ConversationEntry = .{
        .kind = kind,
        .session_id = read(u64, bytes, 12),
        .entry_id = read(u64, bytes, 20),
        .parent_id = read(u64, bytes, 28),
        .task_id = read(u64, bytes, 36),
        .content_ref = read(u64, bytes, 44),
        .sequence = read(u64, bytes, 52),
    };
    var canonical: [conversation_record_size]u8 = undefined;
    try encodeEntry(&canonical, entry);
    if (!std.mem.eql(u8, bytes, &canonical)) return error.NonCanonicalConversationEntry;
    return entry;
}

fn appendEntryFile(
    file: std.Io.File,
    io: std.Io,
    expected_count: u64,
    entry: ConversationEntry,
) !void {
    const stat = try file.stat(io);
    const expected_offset = std.math.mul(u64, expected_count, conversation_record_size) catch {
        return error.ConversationTooLarge;
    };
    if (stat.size != expected_offset) return error.ConversationLengthMismatch;
    var encoded: [conversation_record_size]u8 = undefined;
    try encodeEntry(&encoded, entry);
    try file.writePositionalAll(io, &encoded, expected_offset);
    try file.sync(io);
}

fn readEntryFile(file: std.Io.File, io: std.Io, zero_based_index: u64) !ConversationEntry {
    const offset = std.math.mul(u64, zero_based_index, conversation_record_size) catch {
        return error.ConversationTooLarge;
    };
    var encoded: [conversation_record_size]u8 = undefined;
    const bytes_read = try file.readPositionalAll(io, &encoded, offset);
    if (bytes_read != conversation_record_size) return error.TruncatedConversationEntry;
    return decodeEntry(&encoded);
}

fn reconcileConversation(
    dir: std.Io.Dir,
    io: std.Io,
    view: ManifestView,
) !ManifestView {
    var conversation = try dir.openFile(io, conversation_path, .{});
    defer conversation.close(io);
    const stat = try conversation.stat(io);
    if (stat.size % conversation_record_size != 0) return error.TruncatedConversationEntry;
    const actual_count = stat.size / conversation_record_size;
    if (actual_count < view.entry_count or actual_count > view.entry_count + 1) {
        return error.ConversationLengthMismatch;
    }
    if (actual_count == 0) return error.MissingConversationRoot;
    const last = try readEntryFile(conversation, io, actual_count - 1);
    if (last.session_id != view.identities.session_id or
        last.task_id != view.identities.task_id or
        last.sequence != actual_count)
    {
        return error.ConversationIdentityMismatch;
    }
    if (actual_count == view.entry_count) {
        if (last.entry_id != view.active_leaf_id) return error.ActiveLeafMismatch;
        return view;
    }
    if (last.parent_id != view.active_leaf_id) return error.ActiveLeafMismatch;
    var advanced = view;
    advanced.active_leaf_id = last.entry_id;
    advanced.entry_count = last.sequence;
    try publishManifest(dir, io, advanced);
    return advanced;
}

fn write(comptime T: type, out: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, out[offset..][0..@sizeOf(T)], value, .little);
}

fn read(comptime T: type, input: []const u8, offset: usize) T {
    return std.mem.readInt(T, input[offset..][0..@sizeOf(T)], .little);
}

fn testConfig(workspace_path: []const u8, session_id: u64) CreateConfig {
    return .{
        .identities = .{
            .session_id = session_id,
            .agent_id = session_id + 1,
            .task_id = session_id + 2,
            .branch_id = session_id + 3,
        },
        .workspace_path = workspace_path,
        .model = "fixture:repair",
        .task = "Fix the failing test",
    };
}

const TestLayout = struct {
    tmp: std.testing.TmpDir,
    sessions: std.Io.Dir,
    workspace: std.Io.Dir,
    workspace_path: [128]u8,
    workspace_path_len: u8,

    fn init(io: std.Io) !TestLayout {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDir(io, "sessions", .default_dir);
        try tmp.dir.createDir(io, "repo", .default_dir);
        var workspace = try tmp.dir.openDir(io, "repo", .{});
        errdefer workspace.close(io);
        try workspace.createDir(io, ".git", .default_dir);
        const sessions = try tmp.dir.openDir(io, "sessions", .{});
        var workspace_path: [128]u8 = undefined;
        const rendered = try std.fmt.bufPrint(
            &workspace_path,
            ".zig-cache/tmp/{s}/repo",
            .{tmp.sub_path},
        );
        return .{
            .tmp = tmp,
            .sessions = sessions,
            .workspace = workspace,
            .workspace_path = workspace_path,
            .workspace_path_len = @intCast(rendered.len),
        };
    }

    fn workspacePath(self: *const TestLayout) []const u8 {
        return self.workspace_path[0..self.workspace_path_len];
    }

    fn deinit(self: *TestLayout, io: std.Io) void {
        self.sessions.close(io);
        self.workspace.close(io);
        self.tmp.cleanup();
    }
};

test "create and exact resume preserve distinct identities and one owner" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);

    var created = try Session.createExact(layout.sessions, io, testConfig(layout.workspacePath(), 10));
    const first_token = created.ownerToken();
    var id_buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("000000000000000a", try formatId(created.session_id, &id_buffer));
    try std.testing.expectEqual(@as(u64, 1), first_token.epoch);
    try std.testing.expectEqual(@as(u64, 1), created.active_leaf_id);
    try std.testing.expectEqual(@as(u64, 1), created.entry_count);

    var busy_buffer: [manifest_max_size]u8 = undefined;
    try std.testing.expectError(
        error.SessionBusy,
        Session.openExisting(layout.sessions, io, 10, &busy_buffer),
    );
    created.close();

    var manifest_buffer: [manifest_max_size]u8 = undefined;
    var restored = try Session.openExisting(layout.sessions, io, 10, &manifest_buffer);
    defer restored.session.close();
    try std.testing.expectEqual(@as(u64, 2), restored.manifest.ownership_epoch);
    try std.testing.expectEqualStrings(layout.workspacePath(), restored.manifest.workspace_path);
    try std.testing.expectEqualStrings("fixture:repair", restored.manifest.model);
    try std.testing.expectEqualStrings("Fix the failing test", restored.manifest.task);
    try std.testing.expectEqualDeep(testConfig(layout.workspacePath(), 10).identities, restored.manifest.identities);
    try std.testing.expectEqualDeep(Projection{
        .session_id = 10,
        .task_id = 12,
        .active_leaf_id = 1,
        .ownership_epoch = 2,
    }, restored.session.projection());
    try std.testing.expectError(error.StaleOwner, restored.session.authorize(first_token));
    try restored.session.authorize(restored.session.ownerToken());

    const root = try restored.session.readEntry(1);
    try std.testing.expectEqual(EntryKind.user, root.kind);
    try std.testing.expectEqual(@as(u64, 0), root.parent_id);
    try std.testing.expectEqual(restored.session.task_id, root.content_ref);
}

test "conversation append advances the leaf only after its record is durable" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    var created = try Session.createExact(layout.sessions, io, testConfig(layout.workspacePath(), 20));
    defer created.close();
    const token = created.ownerToken();

    const assistant = try created.appendConversation(token, .assistant, 900, null);

    try std.testing.expectEqual(@as(u64, 2), assistant.entry_id);
    try std.testing.expectEqual(@as(u64, 1), assistant.parent_id);
    try std.testing.expectEqual(@as(u64, 2), created.active_leaf_id);
    const stored = try created.readEntry(2);
    try std.testing.expectEqualDeep(assistant, stored);
}

test "conversation records preserve parent links needed by future forks" {
    const entry: ConversationEntry = .{
        .kind = .assistant,
        .session_id = 1,
        .entry_id = 3,
        .parent_id = 1,
        .task_id = 2,
        .content_ref = 4,
        .sequence = 3,
    };
    var encoded: [conversation_record_size]u8 = undefined;
    try encodeEntry(&encoded, entry);
    try std.testing.expectEqualDeep(entry, try decodeEntry(&encoded));
}

const AppendCrash = struct {
    fn reached(_: *anyopaque, boundary: AppendBoundary) anyerror!void {
        if (boundary == .after_entry_sync) return error.InjectedCrash;
    }
};

test "resume reconciles a conversation record ahead of the manifest" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    var marker: u8 = 0;
    var created = try Session.createExact(layout.sessions, io, testConfig(layout.workspacePath(), 30));
    try std.testing.expectError(
        error.InjectedCrash,
        created.appendConversation(created.ownerToken(), .tool_result, 901, .{
            .context = &marker,
            .reached = AppendCrash.reached,
        }),
    );
    try std.testing.expectEqual(@as(u64, 1), created.active_leaf_id);
    try std.testing.expectError(error.SessionUnavailable, created.authorize(created.ownerToken()));
    created.close();

    var manifest_buffer: [manifest_max_size]u8 = undefined;
    var restored = try Session.openExisting(layout.sessions, io, 30, &manifest_buffer);
    defer restored.session.close();
    try std.testing.expectEqual(@as(u64, 2), restored.manifest.active_leaf_id);
    try std.testing.expectEqual(@as(u64, 2), restored.manifest.entry_count);
    const recovered = try restored.session.readEntry(2);
    try std.testing.expectEqual(EntryKind.tool_result, recovered.kind);
    try std.testing.expectEqual(@as(u64, 1), recovered.parent_id);
}

test "repeating task text creates a distinct session" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    const config: Config = .{
        .workspace_path = layout.workspacePath(),
        .model = "fixture:repair",
        .task = "Fix the failing test",
    };
    var first = try Session.create(layout.sessions, io, config);
    defer first.close();
    var second = try Session.create(layout.sessions, io, config);
    defer second.close();

    try std.testing.expect(first.session_id != second.session_id);
    try std.testing.expect(first.agent_id != second.agent_id);
    try std.testing.expect(first.task_id != second.task_id);
    try std.testing.expect(first.branch_id != second.branch_id);
}

test "creation rejects non Git workspaces and aliased identities" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "sessions", .default_dir);
    try tmp.dir.createDir(io, "plain", .default_dir);
    var sessions = try tmp.dir.openDir(io, "sessions", .{});
    defer sessions.close(io);
    var plain = try tmp.dir.openDir(io, "plain", .{});
    defer plain.close(io);

    var plain_path_buffer: [128]u8 = undefined;
    const plain_path = try std.fmt.bufPrint(
        &plain_path_buffer,
        ".zig-cache/tmp/{s}/plain",
        .{tmp.sub_path},
    );
    try std.testing.expectError(error.NotGitWorktree, Session.createExact(sessions, io, testConfig(plain_path, 60)));

    try plain.createDir(io, ".git", .default_dir);
    var invalid = testConfig(plain_path, 70);
    invalid.identities.agent_id = invalid.identities.session_id;
    try std.testing.expectError(error.InvalidIdentity, Session.createExact(sessions, io, invalid));

    var oversized_bytes: [manifest_max_size]u8 = undefined;
    @memset(&oversized_bytes, 'x');
    var oversized = testConfig(plain_path, 75);
    oversized.task = &oversized_bytes;
    try std.testing.expectError(
        error.SessionMetadataTooLarge,
        Session.createExact(sessions, io, oversized),
    );
    var name_buffer: [16]u8 = undefined;
    try std.testing.expectError(
        error.FileNotFound,
        sessions.access(io, sessionName(75, &name_buffer), .{}),
    );
}

test "resume rejects a corrupted manifest before advancing ownership" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    var created = try Session.createExact(layout.sessions, io, testConfig(layout.workspacePath(), 80));
    created.close();

    var name_buffer: [16]u8 = undefined;
    var session_dir = try layout.sessions.openDir(io, sessionName(80, &name_buffer), .{});
    defer session_dir.close(io);
    var manifest = try session_dir.openFile(io, manifest_path, .{ .mode = .read_write });
    defer manifest.close(io);
    var byte: [1]u8 = undefined;
    _ = try manifest.readPositionalAll(io, &byte, 24);
    byte[0] ^= 1;
    try manifest.writePositionalAll(io, &byte, 24);
    try manifest.sync(io);

    var manifest_buffer: [manifest_max_size]u8 = undefined;
    try std.testing.expectError(
        error.ManifestChecksumMismatch,
        Session.openExisting(layout.sessions, io, 80, &manifest_buffer),
    );
}

test "resume rejects a missing recorded workspace before advancing ownership" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    var created = try Session.createExact(layout.sessions, io, testConfig(layout.workspacePath(), 85));
    created.close();
    layout.workspace.close(io);
    try layout.tmp.dir.rename("repo", layout.tmp.dir, "moved", io);
    layout.workspace = try layout.tmp.dir.openDir(io, "moved", .{});

    var manifest_buffer: [manifest_max_size]u8 = undefined;
    try std.testing.expectError(
        error.WorkspaceUnavailable,
        Session.openExisting(layout.sessions, io, 85, &manifest_buffer),
    );

    var name_buffer: [16]u8 = undefined;
    var session_dir = try layout.sessions.openDir(io, sessionName(85, &name_buffer), .{});
    defer session_dir.close(io);
    const view = try readManifest(session_dir, io, &manifest_buffer);
    try std.testing.expectEqual(@as(u64, 1), view.ownership_epoch);
}

test "resume publishes the new epoch before conversation reconstruction" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    var created = try Session.createExact(layout.sessions, io, testConfig(layout.workspacePath(), 90));
    created.close();

    var name_buffer: [16]u8 = undefined;
    var session_dir = try layout.sessions.openDir(io, sessionName(90, &name_buffer), .{});
    defer session_dir.close(io);
    var conversation = try session_dir.openFile(io, conversation_path, .{ .mode = .read_write });
    defer conversation.close(io);
    var byte: [1]u8 = undefined;
    _ = try conversation.readPositionalAll(io, &byte, 20);
    byte[0] ^= 1;
    try conversation.writePositionalAll(io, &byte, 20);
    try conversation.sync(io);

    var manifest_buffer: [manifest_max_size]u8 = undefined;
    try std.testing.expectError(
        error.ConversationChecksumMismatch,
        Session.openExisting(layout.sessions, io, 90, &manifest_buffer),
    );
    const view = try readManifest(session_dir, io, &manifest_buffer);
    try std.testing.expectEqual(@as(u64, 2), view.ownership_epoch);
}

const FenceTrace = struct {
    persisted: u8 = 0,
    applied: u8 = 0,

    fn classify(_: *anyopaque, _: harness.Input) anyerror!harness.InputState {
        return .applicable;
    }

    fn persist(context: *anyopaque, _: harness.Input) anyerror!void {
        const self: *FenceTrace = @ptrCast(@alignCast(context));
        self.persisted += 1;
    }

    fn apply(context: *anyopaque, _: harness.Input) anyerror!void {
        const self: *FenceTrace = @ptrCast(@alignCast(context));
        self.applied += 1;
    }

    fn transition(self: *FenceTrace) harness.Transition {
        return .{
            .context = self,
            .classify = classify,
            .persist = persist,
            .apply = apply,
        };
    }
};

const RecoverySlot = struct {
    state: durable_transition.SlotState = .accepted,
    apply_count: u8 = 0,

    fn inspect(
        context: *anyopaque,
        _: harness.Completion,
    ) anyerror!durable_transition.SlotState {
        const self: *RecoverySlot = @ptrCast(@alignCast(context));
        return self.state;
    }

    fn apply(context: *anyopaque, _: harness.Completion) anyerror!void {
        const self: *RecoverySlot = @ptrCast(@alignCast(context));
        self.state = .completed;
        self.apply_count += 1;
    }

    fn interface(self: *RecoverySlot) durable_transition.Slot {
        return .{ .context = self, .inspect = inspect, .apply = apply };
    }
};

test "the owner loop fences every drive through the live Session" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    var session = try Session.createExact(layout.sessions, io, testConfig(layout.workspacePath(), 100));
    var trace: FenceTrace = .{};
    var owner = try harness.Harness.open(.{
        .input_capacity = 2,
        .drive_quantum = 1,
        .transition = trace.transition(),
        .owner_fence = session.fence(),
    });
    try std.testing.expectEqual(harness.OfferResult.queued, owner.offer(.{ .start_task = .{
        .task_id = session.task_id,
        .agent_id = session.agent_id,
        .agent_generation = 1,
        .task_ref = session.task_id,
    } }));
    _ = try owner.drive();
    try std.testing.expectEqual(@as(u8, 1), trace.persisted);
    try std.testing.expectEqual(@as(u8, 1), trace.applied);

    try std.testing.expectEqual(harness.OfferResult.queued, owner.offer(.{ .completion = .{
        .agent_id = session.agent_id,
        .agent_generation = 1,
        .operation_id = 900,
        .operation_generation = 1,
        .ownership_epoch = session.ownership_epoch,
        .result = 901,
    } }));
    session.close();

    try std.testing.expectError(error.SessionClosed, owner.drive());
    try std.testing.expectEqual(@as(u8, 1), trace.persisted);
    try std.testing.expectEqual(@as(u8, 1), trace.applied);
    try std.testing.expectEqual(
        harness.OfferResult.unavailable,
        owner.offer(.shutdown),
    );
}

test "resume reconciles a prior epoch journal ahead of the restored slot" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    var created = try Session.createExact(layout.sessions, io, testConfig(layout.workspacePath(), 110));
    const previous_epoch = created.ownership_epoch;
    created.close();

    const completion: harness.Completion = .{
        .agent_id = 111,
        .operation_id = 700,
        .ownership_epoch = previous_epoch,
        .result = 701,
        .agent_generation = 1,
        .operation_generation = 1,
    };
    {
        var initial = try operation_log.Writer.createIn(layout.tmp.dir, io, "recovery.journal");
        defer initial.close(io);
        try initial.appendDurable(io, .{
            .kind = .accepted,
            .agent_id = completion.agent_id,
            .agent_generation = completion.agent_generation,
            .operation_id = completion.operation_id,
            .operation_generation = completion.operation_generation,
            .ownership_epoch = completion.ownership_epoch,
            .sequence = 1,
            .result = 0,
        });
        try initial.appendDurable(io, .{
            .kind = .completed,
            .agent_id = completion.agent_id,
            .agent_generation = completion.agent_generation,
            .operation_id = completion.operation_id,
            .operation_generation = completion.operation_generation,
            .ownership_epoch = completion.ownership_epoch,
            .sequence = 2,
            .result = completion.result,
        });
    }

    var manifest_buffer: [manifest_max_size]u8 = undefined;
    var restored = try Session.openExisting(layout.sessions, io, 110, &manifest_buffer);
    defer restored.session.close();
    try std.testing.expectEqual(previous_epoch + 1, restored.session.ownership_epoch);
    var writer = try operation_log.Writer.openAppendIn(
        layout.tmp.dir,
        io,
        "recovery.journal",
    );
    defer writer.close(io);
    const journal_offset = writer.offset;
    var slot: RecoverySlot = .{};
    var adapter: durable_transition.Adapter = .{
        .io = io,
        .dir = layout.tmp.dir,
        .journal_path = "recovery.journal",
        .writer = &writer,
        .ownership_epoch = restored.session.ownership_epoch,
        .slot = slot.interface(),
    };
    var owner = try harness.Harness.open(.{
        .input_capacity = 1,
        .drive_quantum = 1,
        .transition = adapter.transition(),
        .owner_fence = restored.session.fence(),
    });
    try std.testing.expectEqual(
        harness.OfferResult.queued,
        owner.offer(.{ .completion = completion }),
    );

    const progress = try owner.drive();

    try std.testing.expectEqual(@as(u8, 1), progress.applied);
    try std.testing.expectEqual(@as(u8, 1), slot.apply_count);
    try std.testing.expectEqual(journal_offset, writer.offset);
    try std.testing.expectEqualSlices(
        harness.Projection,
        &.{.{ .kind = .completion_committed, .subject = completion.operation_id }},
        progress.projectionSlice(),
    );
}
