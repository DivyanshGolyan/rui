//! Filesystem capture shared by human admission and model core calls.
//! Captures are borrowed by one atomic Store settlement. They are never a
//! retained instruction layer or an authority to execute sibling resources.
const std = @import("std");
const catalog = @import("skills.zig");
const protocol = @import("protocol.zig");
const wire_request = @import("wire_request.zig");
const storage = @import("store.zig");

pub fn initial(allocator: std.mem.Allocator, scratch_allocator: std.mem.Allocator, io: std.Io, store: *storage.Store, key: []const u8, configuration: *const wire_request.Configuration, home: ?[]const u8) !?*const storage.InitialSkills {
    if (try store.commandExists(key)) return null;
    return captureInitial(allocator, scratch_allocator, io, if (configuration.workspace.state == .value) configuration.workspace.value.slice() else "/", home);
}

pub fn captureInitial(allocator: std.mem.Allocator, scratch_allocator: std.mem.Allocator, io: std.Io, workspace: []const u8, home: ?[]const u8) !*const storage.InitialSkills {
    const out = try allocator.create(storage.InitialSkills);
    out.* = prepareInitial(allocator, scratch_allocator, io, workspace, home) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // Refusal is carried into the normal keyed creation transaction, where
        // replay wins even if the filesystem changed since the original request.
        else => .unavailable,
    };
    return out;
}

fn prepareInitial(allocator: std.mem.Allocator, scratch_allocator: std.mem.Allocator, io: std.Io, workspace: []const u8, home: ?[]const u8) !storage.InitialSkills {
    const found = try catalog.discoverWithScratch(allocator, scratch_allocator, io, workspace, home);
    const rendered = try catalog.initialCatalog(allocator, found);
    return .{ .ready = .{ .encoded = rendered.encoded, .instruction = rendered.instruction } };
}

pub const Capture = storage.CapturedSkill;

pub fn capture(allocator: std.mem.Allocator, scratch_allocator: std.mem.Allocator, io: std.Io, store: *storage.Store, session: []const u8, request: *const protocol.SkillRequest, home: ?[]const u8) !Capture {
    const state = store.readSkills(allocator, session) catch |err| switch (err) {
        error.SessionNotFound => return .{ .failed = .{ .code = .unknown_session, .bytes = "Rui could not use skills: unknown Session." } },
        else => return err,
    };
    switch (request.operation) {
        .invoke => {
            const requested_name = request.name orelse return .{ .failed = .{ .code = .unknown_skill, .bytes = "Skill invocation requires a name." } };
            const name = requested_name.slice();
            const selected = for (state.catalog.entries) |entry| {
                if (std.mem.eql(u8, entry.name, name)) break entry;
            } else return .{ .failed = .{ .code = .unknown_skill, .bytes = "No advertised skill has that name. Reload skills to refresh the catalog." } };
            const bytes = catalog.invocation(allocator, io, selected) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return .{ .failed = .{ .code = switch (err) {
                    error.SkillFileTooLarge => .skill_file_too_large,
                    error.InvalidUtf8 => .skill_text_invalid,
                    else => .skill_file_unavailable,
                }, .bytes = try std.fmt.allocPrint(allocator, "Rui could not read skill {s}: {s}. The catalog was not changed.", .{ name, @errorName(err) }) } },
            };
            return .{ .invocation = bytes };
        },
        .reload => return .{ .reload = catalog.discoverWithScratch(allocator, scratch_allocator, io, state.workspace.slice(), home) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .failed = .{ .code = .skills_unavailable, .bytes = try std.fmt.allocPrint(allocator, "Rui could not reload skills: {s}. The previous catalog is unchanged.", .{@errorName(err)}) } },
        } },
    }
}

// These witnesses wrap the actual request arena, not just the scanner's scratch.
// Backing high-water includes arena slack and ignored frees until settlement.
test "skills creation capture shares one materialized catalog in the request arena" {
    const owner = @This();
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try catalog.fixturePath(allocator, tmp.dir);
    defer allocator.free(root);
    try tmp.dir.createDirPath(io, ".git");
    const description = try allocator.alloc(u8, 4 * 1024);
    for (0..1024) |index| @memcpy(description[4 * index ..][0..4], "😀");
    defer allocator.free(description);
    var oracle: std.Io.Writer.Allocating = .init(allocator);
    defer oracle.deinit();
    try oracle.writer.writeAll("{\"entries\":[");
    const population = 128;
    for (0..population) |index| {
        var name_buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "dense-{d:0>4}", .{index});
        const directory = try std.fs.path.join(allocator, &.{ ".agents/skills", name });
        defer allocator.free(directory);
        try catalog.fixtureSkill(tmp.dir, directory, name, description);
        if (index != 0) try oracle.writer.writeByte(',');
        try oracle.writer.print("{{\"name\":\"{s}\",\"description\":\"{s}\",\"path\":\"{s}/{s}/SKILL.md\"}}", .{ name, description, root, directory });
    }
    try oracle.writer.writeAll("]}");
    var backing: catalog.TestHighWaterAllocator = .{ .child = allocator };
    var scratch: catalog.TestHighWaterAllocator = .{ .child = allocator };
    {
        var arena: std.heap.ArenaAllocator = .init(backing.allocator());
        defer arena.deinit();
        var requested = std.testing.FailingAllocator.init(arena.allocator(), .{});
        const started = std.Io.Clock.awake.now(io);
        const captured = try owner.captureInitial(requested.allocator(), scratch.allocator(), io, root, null);
        const elapsed = started.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds();
        try std.testing.expect(captured.* == .ready);
        const ready = captured.ready;
        try std.testing.expectEqualStrings(oracle.written(), ready.encoded);
        const instruction = ready.instruction.?;
        try std.testing.expect(std.mem.endsWith(u8, instruction, ready.encoded));
        std.debug.print("creation capture: entries={d} json={d} requested={d} backing_peak={d} backing_live={d} scratch_peak={d} ns={d}\n", .{ population, ready.encoded.len, requested.allocated_bytes, backing.peak, backing.live, scratch.peak, elapsed });
        // Complete bytes have one owner. The independently rendered JSON is a
        // borrowed suffix, never a second allocation with the same payload.
        try std.testing.expectEqual(@intFromPtr(instruction.ptr) + instruction.len - ready.encoded.len, @intFromPtr(ready.encoded.ptr));
        const metadata = population * (@sizeOf(catalog.Entry) + "dense-0000".len + description.len + root.len + "/.agents/skills/dense-0000/SKILL.md".len);
        try std.testing.expect(requested.allocated_bytes < instruction.len + 2 * metadata);
        try std.testing.expectEqual(@as(usize, 0), scratch.live);
    }
    try std.testing.expectEqual(@as(usize, 0), backing.live);
    {
        var arenas: [4]std.heap.ArenaAllocator = undefined;
        for (&arenas) |*arena| arena.* = .init(backing.allocator());
        defer for (&arenas) |*arena| arena.deinit();
        var held: [4]*const @import("store.zig").InitialSkills = undefined;
        for (&arenas, &held) |*arena, *held_capture| held_capture.* = try owner.captureInitial(arena.allocator(), scratch.allocator(), io, root, null);
        for (held) |held_capture| try std.testing.expectEqualStrings(oracle.written(), held_capture.ready.encoded);
        std.debug.print("creation held captures: live_exchanges=4 backing_peak={d} backing_live={d}\n", .{ backing.peak, backing.live });
    }
    try std.testing.expectEqual(@as(usize, 0), backing.live);
}

test "skills invocation capture retains only final max-body bytes in the request arena" {
    const owner = @This();
    const store = @import("store.zig");
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try catalog.fixturePath(allocator, tmp.dir);
    defer allocator.free(root);
    try tmp.dir.createDirPath(io, ".git");
    // Escaping, CRLF, BOM, Unicode and trailing bytes belong to the raw suffix.
    const directory = ".agents/skills/demo";
    try catalog.fixtureSkill(tmp.dir, directory, "demo", "metadata");
    var initial_memory: std.heap.ArenaAllocator = .init(allocator);
    defer initial_memory.deinit();
    const initial_skills = try owner.captureInitial(initial_memory.allocator(), allocator, io, root, null);
    var database: store.Store = undefined;
    try store.testingStoreWith(&.{ .engine = .sqlite }, &database, &tmp, io, .{});
    defer database.close() catch unreachable;
    var create = try store.testingCompleteConfiguration("capture-memory-create", "", root, "model-a");
    const session = database.configureWithInitialSkills(&create, null, initial_skills, .{}).accepted.session;
    const raw = try allocator.alloc(u8, catalog.max_skill_bytes);
    defer allocator.free(raw);
    @memset(raw, 'x');
    const header = "\xef\xbb\xbf---\r\nname: demo\r\ndescription: metadata\r\n---\r\n雪 e\xcc\x81\r\n";
    @memcpy(raw[0..header.len], header);
    @memcpy(raw[raw.len - 5 ..], "\r\n\n \n");
    try tmp.dir.writeFile(io, .{ .sub_path = directory ++ "/SKILL.md", .data = raw });
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}/SKILL.md", .{ root, directory });
    defer allocator.free(path);
    const expected = try std.fmt.allocPrint(allocator, "Skill file: \"{s}\"\n\n{s}", .{ path, raw });
    defer allocator.free(expected);
    var backing: catalog.TestHighWaterAllocator = .{ .child = allocator };
    {
        var arena: std.heap.ArenaAllocator = .init(backing.allocator());
        defer arena.deinit();
        var requested = std.testing.FailingAllocator.init(arena.allocator(), .{});
        var name: protocol.Bounded(64) = .{};
        try name.set("demo");
        const started = std.Io.Clock.awake.now(io);
        const captured = try owner.capture(requested.allocator(), allocator, io, &database, session.slice(), &.{ .operation = .invoke, .name = name }, null);
        const elapsed = started.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds();
        try std.testing.expect(captured == .invocation);
        try std.testing.expectEqualStrings(expected, captured.invocation);
        std.debug.print("invocation capture: raw={d} final={d} requested={d} backing_peak={d} backing_live={d} ns={d}\n", .{ raw.len, captured.invocation.len, requested.allocated_bytes, backing.peak, backing.live, elapsed });
        // Small decoded catalog/state is necessary; another complete body is not.
        try std.testing.expect(requested.allocated_bytes < captured.invocation.len + 32 * 1024);
        try std.testing.expect(backing.peak < 2 * captured.invocation.len);
    }
    try std.testing.expectEqual(@as(usize, 0), backing.live);
    {
        var arenas: [4]std.heap.ArenaAllocator = undefined;
        for (&arenas) |*arena| arena.* = .init(backing.allocator());
        defer for (&arenas) |*arena| arena.deinit();
        var held: [4]owner.Capture = undefined;
        var name: protocol.Bounded(64) = .{};
        try name.set("demo");
        for (&arenas, &held) |*arena, *held_capture| held_capture.* = try owner.capture(arena.allocator(), allocator, io, &database, session.slice(), &.{ .operation = .invoke, .name = name }, null);
        for (held) |held_capture| try std.testing.expectEqualStrings(expected, held_capture.invocation);
        std.debug.print("invocation held captures: live_exchanges=4 backing_peak={d} backing_live={d}\n", .{ backing.peak, backing.live });
    }
    try std.testing.expectEqual(@as(usize, 0), backing.live);
}
