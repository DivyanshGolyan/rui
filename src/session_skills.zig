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
    var found: catalog.Catalog = .{ .entries = &.{} };
    out.* = try prepareInitial(allocator, scratch_allocator, io, workspace, home, &found);
    return out;
}

fn initialFailure(err: anyerror) error{OutOfMemory}!storage.InitialSkills {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    // Keyed creation validation, not capture, owns ordinary refusal precedence.
    return .unavailable;
}

fn prepareInitial(allocator: std.mem.Allocator, scratch_allocator: std.mem.Allocator, io: std.Io, workspace: []const u8, home: ?[]const u8, found: *catalog.Catalog) !storage.InitialSkills {
    found.* = catalog.discoverWithScratch(allocator, scratch_allocator, io, workspace, home) catch |err| return initialFailure(err);
    return initialFromCatalog(allocator, found.*);
}

fn initialFromCatalog(allocator: std.mem.Allocator, found: catalog.Catalog) !storage.InitialSkills {
    const rendered = catalog.initialCatalog(allocator, found) catch |err| return initialFailure(err);
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
                else => return .{ .failed = try readFailure(@FieldType(Capture, "failed"), allocator, name, err) },
            };
            return .{ .invocation = bytes };
        },
        .reload => return .{ .reload = catalog.discoverWithScratch(allocator, scratch_allocator, io, state.workspace.slice(), home) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .failed = .{ .code = .skills_unavailable, .bytes = try std.fmt.allocPrint(allocator, "Rui could not reload skills: {s}. The previous catalog is unchanged.", .{@errorName(err)}) } },
        } },
    }
}

fn readFailure(comptime Failure: type, allocator: std.mem.Allocator, name: []const u8, err: anyerror) !Failure {
    return .{ .code = switch (err) {
        error.SkillFileTooLarge, error.SkillBatchTooLarge => .skill_file_too_large,
        error.InvalidUtf8 => .skill_text_invalid,
        else => .skill_file_unavailable,
    }, .bytes = try std.fmt.allocPrint(allocator, "Rui could not read skill {s}: {s}. The catalog was not changed.", .{ name, @errorName(err) }) };
}

pub const PreparedMessage = struct {
    initial: ?*const storage.InitialSkills = null,
    captured: ?storage.CapturedMessageSkills = null,
};

/// Message text as a door holds it: a wire field, bytes the Host made, or
/// content the Store saved.
pub const Text = union(enum) {
    field: *const wire_request.ContentField,
    bytes: []const u8,
    stored: struct { store: *storage.Store, reference: storage.ContentReference },
};

/// The wire Message door: a creation binds against the catalog it creates,
/// any other Message against its Session's. Replays prepare nothing.
pub fn prepareMessage(allocator: std.mem.Allocator, scratch_allocator: std.mem.Allocator, io: std.Io, store: *storage.Store, command: *const wire_request.MessageCommand, home: ?[]const u8) !*PreparedMessage {
    const prepared = try allocator.create(PreparedMessage);
    prepared.* = .{};
    // This includes accepted, rejected and conflicting keys: no metadata or
    // file discovery precedes the Store's authoritative replay classification.
    if (try store.commandExists(command.key.slice())) return prepared;
    if (command.configuration) |*configuration| {
        prepared.* = try prepareCreation(allocator, scratch_allocator, io, if (configuration.workspace.state == .value) configuration.workspace.value.slice() else "/", home, .{ .field = &command.text });
    } else prepared.captured = try bindTo(allocator, io, store, command.session.slice(), .{ .field = &command.text });
    return prepared;
}

/// A Message that creates its Session, from a client or `start_agent`:
/// the new Session's initial catalog, and the text bound against it.
pub fn prepareCreation(allocator: std.mem.Allocator, scratch_allocator: std.mem.Allocator, io: std.Io, workspace: []const u8, home: ?[]const u8, text: Text) !PreparedMessage {
    var found: catalog.Catalog = .{ .entries = &.{} };
    const initial_value = try allocator.create(storage.InitialSkills);
    initial_value.* = try prepareInitial(allocator, scratch_allocator, io, workspace, home, &found);
    if (initial_value.* == .unavailable) return .{ .initial = initial_value };
    return .{ .initial = initial_value, .captured = try bind(allocator, io, text, found) };
}

/// A Message to an existing Session: binds `text` against that Session's
/// catalog. Null when no word names a skill there; an unknown Session
/// binds nothing and is the Store's refusal.
pub fn bindTo(allocator: std.mem.Allocator, io: std.Io, store: *storage.Store, session: []const u8, text: Text) !?storage.CapturedMessageSkills {
    // Only text with a `/name` word needs the recipient's catalog.
    var any: AnyReference = .{};
    try eachReference(io, text, &any);
    if (!any.found) return null;
    const state = store.readSkills(allocator, session) catch |err| switch (err) {
        error.SessionNotFound => return null,
        else => return err,
    };
    return bind(allocator, io, text, state.catalog);
}

/// The one binding step every Message passes: each `/name` word that names
/// a skill in `found` binds it, once, in the order the text first names it,
/// with the skill's whole current file read now. Other words are prose.
/// Null when nothing binds. The bodies are owned by `allocator`.
pub fn bind(allocator: std.mem.Allocator, io: std.Io, text: Text, found: catalog.Catalog) !?storage.CapturedMessageSkills {
    var binder: Binder = .{ .allocator = allocator, .found = found };
    defer binder.selected.deinit(allocator);
    try eachReference(io, text, &binder);
    if (binder.selected.items.len == 0) return null;
    const bound = try allocator.alloc(storage.BoundSkill, binder.selected.items.len);
    var total: usize = 0;
    for (binder.selected.items, bound) |entry, *skill| {
        const invocation = catalog.invocationWithLength(allocator, io, entry) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return .{ .failed = try bindFailure(allocator, entry.name, err) },
        };
        total = std.math.add(usize, total, invocation.raw_length) catch std.math.maxInt(usize);
        if (total > max_batch_body_bytes) return .{ .failed = try bindFailure(allocator, entry.name, error.SkillBatchTooLarge) };
        skill.* = .{ .name = entry.name, .bytes = invocation.bytes };
    }
    return .{ .bound = bound };
}

/// Why a bound skill could not be read; each door says what it then did.
fn bindFailure(allocator: std.mem.Allocator, name: []const u8, err: anyerror) !storage.MessageSkillFailure {
    const failure = try readFailure(storage.MessageSkillFailure, allocator, name, err);
    return .{ .code = failure.code, .bytes = try std.fmt.allocPrint(allocator, "Rui could not read skill {s}: {s}.", .{ name, @errorName(err) }) };
}

const AnyReference = struct {
    found: bool = false,
    fn visit(self: *AnyReference, _: []const u8) !bool {
        self.found = true;
        return false;
    }
};

/// The catalog entries a Message's `/name` words name, each once, in the
/// order the text first names them. Other words stay prose.
const Binder = struct {
    allocator: std.mem.Allocator,
    found: catalog.Catalog,
    selected: std.ArrayList(catalog.Entry) = .empty,

    fn visit(self: *Binder, name: []const u8) !bool {
        // Full catalogs are lexical by name.
        const index = std.sort.binarySearch(catalog.Entry, self.found.entries, name, struct {
            fn order(key: []const u8, entry: catalog.Entry) std.math.Order {
                return std.mem.order(u8, key, entry.name);
            }
        }.order) orelse return true;
        const entry = self.found.entries[index];
        for (self.selected.items) |bound| if (std.mem.eql(u8, bound.name, entry.name)) return true;
        try self.selected.append(self.allocator, entry);
        return true;
    }
};

/// Streams the text's `/name` words to `visitor` in order, until its `visit`
/// returns false. Sealed and saved text is read in bounded windows.
fn eachReference(io: std.Io, text: Text, visitor: anytype) !void {
    var scanner: catalog.References = .{};
    switch (text) {
        .bytes => |bytes| for (bytes) |byte| if (scanner.feed(byte)) |name| if (!try visitor.visit(name)) return,
        .field => |field| if (field.borrowedBytes()) |bytes| {
            for (bytes) |byte| if (scanner.feed(byte)) |name| if (!try visitor.visit(name)) return;
        } else if (field.length != 0) {
            const file = field.file orelse return error.MissingContentCapture;
            var buffer: [protocol.content_window_bytes]u8 = undefined;
            var offset: u64 = 0;
            while (offset < field.length) {
                const size: usize = @intCast(@min(buffer.len, field.length - offset));
                const count = try file.readPositionalAll(io, buffer[0..size], offset);
                if (count != size) return error.ContentLengthMismatch;
                for (buffer[0..count]) |byte| if (scanner.feed(byte)) |name| if (!try visitor.visit(name)) return;
                offset += count;
            }
        },
        .stored => |stored| {
            var reader: storage.ContentReader = undefined;
            reader.open(try stored.store.openContent(stored.reference));
            defer reader.close();
            // A small window: this runs on execution threads' stacks too.
            var buffer: [protocol.content_window_bytes]u8 = undefined;
            var offset: u64 = 0;
            while (offset < stored.reference.length) {
                const count = try reader.read(offset, buffer[0..@intCast(@min(buffer.len, stored.reference.length - offset))]);
                if (count == 0) return error.ShortCanonicalRead;
                for (buffer[0..count]) |byte| if (scanner.feed(byte)) |name| if (!try visitor.visit(name)) return;
                offset += count;
            }
        },
    }
    if (scanner.finish()) |name| _ = try visitor.visit(name);
}

/// Every skill one Message binds, raw file bytes together.
const max_batch_body_bytes = 1024 * 1024;

pub fn suggestions(allocator: std.mem.Allocator, scratch_allocator: std.mem.Allocator, io: std.Io, store: *storage.Store, scope: @import("skill_suggestions.zig").Scope, prefix: []const u8, home: ?[]const u8) !@import("skill_suggestions.zig").Page {
    if (prefix.len > 64 or !std.unicode.utf8ValidateSlice(prefix)) return error.InvalidPrefix;
    var memory: std.heap.ArenaAllocator = .init(scratch_allocator);
    defer memory.deinit();
    const found = switch (scope) {
        .session => |session| (try store.readSkills(memory.allocator(), session)).catalog,
        .workspace => |workspace| try catalog.discoverWithScratch(memory.allocator(), scratch_allocator, io, workspace, home),
    };
    return selectSuggestions(allocator, found, prefix);
}

fn selectSuggestions(allocator: std.mem.Allocator, found: catalog.Catalog, prefix: []const u8) !@import("skill_suggestions.zig").Page {
    const suggestion = @import("skill_suggestions.zig");
    // All full catalogs are lexical. Retain a bounded page, never their paths.
    var count: usize = 0;
    var total: usize = 0;
    var revision: std.hash.Wyhash = .init(0);
    for (found.entries) |entry| {
        for ([_][]const u8{ entry.name, entry.description, entry.path }) |field| {
            var size: [8]u8 = undefined;
            std.mem.writeInt(u64, &size, field.len, .big);
            revision.update(&size);
            revision.update(field);
        }
        if (std.mem.startsWith(u8, entry.name, prefix)) total += 1;
    }
    const entries = try allocator.alloc(suggestion.Entry, @min(total, suggestion.capacity));
    var page: suggestion.Page = .{ .entries = entries[0..0], .revision = revision.final(), .total = total };
    errdefer {
        for (entries[0..count]) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.description);
        }
        allocator.free(entries);
    }
    for (found.entries) |entry| {
        if (!std.mem.startsWith(u8, entry.name, prefix)) continue;
        if (count == entries.len) break;
        const name = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(name);
        const description = try allocator.dupe(u8, entry.description);
        entries[count] = .{ .name = name, .description = description };
        count += 1;
    }
    page.entries = entries;
    return page;
}

test "inline skills suggestions bound pages and retain prefix-independent revision" {
    const names = [_][]const u8{ "alpha", "beta", "delta" };
    var entries: [3]catalog.Entry = undefined;
    for (names, 0..) |name, i| entries[i] = .{ .name = name, .description = "description", .path = "/not-exported" };
    var all = try selectSuggestions(std.testing.allocator, .{ .entries = &entries }, "");
    defer all.deinit(std.testing.allocator);
    var filtered = try selectSuggestions(std.testing.allocator, .{ .entries = &entries }, "b");
    defer filtered.deinit(std.testing.allocator);
    try std.testing.expectEqual(all.revision, filtered.revision);
    try std.testing.expectEqual(@as(usize, 3), all.total);
    try std.testing.expectEqual(@as(usize, 1), filtered.total);
    try std.testing.expectEqualStrings("beta", filtered.entries[0].name);
}

fn expectBound(text: *const wire_request.ContentField, found: catalog.Catalog, expected: []const []const u8) !void {
    var binder: Binder = .{ .allocator = std.testing.allocator, .found = found };
    defer binder.selected.deinit(std.testing.allocator);
    try eachReference(std.testing.io, .{ .field = text }, &binder);
    try std.testing.expectEqual(expected.len, binder.selected.items.len);
    for (expected, binder.selected.items) |name, entry| try std.testing.expectEqualStrings(name, entry.name);
}

test "inline skills bind each catalog name a /name word names, once, in text order" {
    const entries = [_]catalog.Entry{
        .{ .name = "alpha", .description = "Metadata", .path = "/never-read" },
        .{ .name = "beta", .description = "Metadata", .path = "/never-read" },
        .{ .name = "tmp", .description = "Metadata", .path = "/never-read" },
    };
    const text = "use /beta, not /tmp/etc or /gamma; then /alpha and /beta again /tmp";
    const borrowed: wire_request.ContentField = .{ .state = .value, .borrowed = text.ptr, .length = text.len };
    try expectBound(&borrowed, .{ .entries = &entries }, &.{ "beta", "alpha", "tmp" });
    // Sealed text streams in windows; a word may straddle one.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const padding = protocol.content_window_bytes - 3;
    const file = try tmp.dir.createFile(std.testing.io, "text", .{ .read = true });
    defer file.close(std.testing.io);
    var bytes: [padding + " /alpha".len]u8 = undefined;
    @memset(bytes[0..padding], 'x');
    @memcpy(bytes[padding..], " /alpha");
    try file.writeStreamingAll(std.testing.io, &bytes);
    const sealed: wire_request.ContentField = .{ .state = .value, .file = file, .length = bytes.len };
    try expectBound(&sealed, .{ .entries = &entries }, &.{"alpha"});
    const empty: wire_request.ContentField = .{ .state = .value };
    try expectBound(&empty, .{ .entries = &entries }, &.{});
}

test "inline skills refuse a Message whose bound files together exceed the body cap" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    const raw = try std.testing.allocator.alloc(u8, 600 * 1024);
    defer std.testing.allocator.free(raw);
    @memset(raw, 'x');
    for ([_][]const u8{ "first.md", "second.md" }) |name| {
        const file = try tmp.dir.createFile(std.testing.io, name, .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, raw);
    }
    var first_path: [protocol.max_workspace_bytes]u8 = undefined;
    var second_path: [protocol.max_workspace_bytes]u8 = undefined;
    const entries = [_]catalog.Entry{
        .{ .name = "first", .description = "Metadata", .path = try std.fmt.bufPrint(&first_path, "{s}/first.md", .{root}) },
        .{ .name = "second", .description = "Metadata", .path = try std.fmt.bufPrint(&second_path, "{s}/second.md", .{root}) },
    };
    var memory: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer memory.deinit();
    // Each file alone fits; the second one's bytes cross the cap.
    for ([_]struct { text: []const u8, bound: usize }{ .{ .text = "/first", .bound = 1 }, .{ .text = "/second and /first", .bound = 0 } }) |case| {
        const text: wire_request.ContentField = .{ .state = .value, .borrowed = case.text.ptr, .length = case.text.len };
        const captured = (try bind(memory.allocator(), std.testing.io, .{ .field = &text }, .{ .entries = &entries })).?;
        if (case.bound == 0) {
            try std.testing.expectEqual(.skill_file_too_large, captured.failed.code);
            try std.testing.expect(std.mem.indexOf(u8, captured.failed.bytes, "first") != null);
        } else {
            try std.testing.expectEqual(case.bound, captured.bound.len);
            try std.testing.expectEqualStrings("first", captured.bound[0].name);
            try std.testing.expect(std.mem.endsWith(u8, captured.bound[0].bytes, raw));
        }
    }
    // A word that names no skill binds nothing and reads no file.
    const prose: wire_request.ContentField = .{ .state = .value, .borrowed = "/tmp/etc /month".ptr, .length = "/tmp/etc /month".len };
    try std.testing.expect(try bind(memory.allocator(), std.testing.io, .{ .field = &prose }, .{ .entries = &entries }) == null);
}

test "inline skills initial render limits remain keyed refusals with ordinary configuration precedence" {
    // The factored owner receives a discovered snapshot. Force its supported
    // encoding limit without a giant filesystem tree or a whole JSON buffer.
    const entries = try std.testing.allocator.alloc(catalog.Entry, catalog.max_entries + 1);
    defer std.testing.allocator.free(entries);
    const unavailable = try initialFromCatalog(std.testing.allocator, .{ .entries = entries });
    try std.testing.expect(unavailable == .unavailable);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var database_buffer: [protocol.max_store_bytes]u8 = undefined;
    const database = try std.fmt.bufPrint(&database_buffer, "{s}/catalog-limit.sqlite", .{root});
    var store: storage.Store = undefined;
    try store.open(std.testing.io, database, root);
    defer store.close() catch unreachable;
    var configuration = try storage.testingCompleteConfiguration("unused", "", root, "");
    var command: wire_request.MessageCommand = .{ .configuration = configuration.configuration, .text = .{ .state = .value, .length = 0, .digest = protocol.contentDigest("") } };
    try command.key.set("invalid-config-render-limit");
    const invalid = store.submitMessageWithInitialSkills(&command, null, &unavailable, .{});
    try std.testing.expect(invalid == .rejected);
    try std.testing.expectEqual(.invalid_model, invalid.rejected.code);
    try configuration.configuration.model.value.set("model-a");
    command.configuration = configuration.configuration;
    try command.key.set("valid-config-render-limit");
    const refused = store.submitMessageWithInitialSkills(&command, null, &unavailable, .{});
    try std.testing.expect(refused == .rejected);
    try std.testing.expectEqual(.skills_unavailable, refused.rejected.code);
    try std.testing.expect(!store.isFenced());
    var used: std.atomic.Value(u64) = .init(0);
    var page = try store.captureSessionList(&.{}, .{ .scratch_path = root, .scratch_budget = .{ .used = &used, .limit = 1024 }, .request_number = 1 });
    defer page.deinit();
    var bytes: [1024]u8 = undefined;
    const count = try page.read(0, &bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes[0..count], .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.value.object.get("sessions").?.array.items.len);
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
