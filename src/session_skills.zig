//! Filesystem capture shared by human admission and model core calls.
//! Captures are borrowed by one atomic Store settlement. They are never a
//! retained instruction layer or an authority to execute sibling resources.
const std = @import("std");
const catalog = @import("skills.zig");
const protocol = @import("protocol.zig");
const storage = @import("store.zig");

pub fn initial(allocator: std.mem.Allocator, scratch_allocator: std.mem.Allocator, io: std.Io, store: *storage.Store, key: []const u8, configuration: *const protocol.Configuration, home: ?[]const u8) !?*const storage.InitialSkills {
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

/// One request owner, borrowed by the Store through synchronous settlement.
/// Its expanded descriptor shares the Ingress scratch budget and cleanup home.
pub const PreparedMessage = struct {
    initial: ?*const storage.InitialSkills = null,
    captured: ?Capture = null,
    payload: protocol.ContentField = .{},

    pub fn deinit(self: *PreparedMessage, io: std.Io) void {
        protocol.removeContent(&self.payload, io) catch unreachable;
    }
};

pub fn prepareMessage(allocator: std.mem.Allocator, scratch_allocator: std.mem.Allocator, io: std.Io, store: *storage.Store, command: *const protocol.MessageCommand, home: ?[]const u8, options: protocol.ParseOptions) !*PreparedMessage {
    const prepared = try allocator.create(PreparedMessage);
    prepared.* = .{};
    // This includes accepted, rejected and conflicting keys: no metadata or
    // file discovery precedes the Store's authoritative replay classification.
    if (try store.commandExists(command.key.slice())) return prepared;
    const invokes = command.skill != null or command.skills.len != 0;
    var found: catalog.Catalog = .{ .entries = &.{} };
    if (command.configuration) |*configuration| {
        const initial_value = try allocator.create(storage.InitialSkills);
        prepared.initial = initial_value;
        found = catalog.discoverWithScratch(allocator, scratch_allocator, io, if (configuration.workspace.state == .value) configuration.workspace.value.slice() else "/", home) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                initial_value.* = .unavailable;
                return prepared;
            },
        };
        const rendered = try catalog.initialCatalog(allocator, found);
        initial_value.* = .{ .ready = .{ .encoded = rendered.encoded, .instruction = rendered.instruction } };
    } else if (invokes) {
        const state = store.readSkills(allocator, command.session.slice()) catch |err| switch (err) {
            error.SessionNotFound => {
                prepared.captured = .{ .failed = .{ .code = .unknown_session, .bytes = "Rui could not use skills: unknown Session." } };
                return prepared;
            },
            else => return err,
        };
        found = state.catalog;
    }
    if (!invokes) return prepared;
    preparePayload(prepared, scratch_allocator, io, command, found, options) catch |err| switch (err) {
        error.OutOfMemory, error.ScratchCapacityExhausted => return err,
        else => prepared.captured = .{ .failed = .{ .code = switch (err) {
            error.UnknownSkill => .unknown_skill,
            error.SkillFileTooLarge, error.SkillBatchTooLarge => .skill_file_too_large,
            error.InvalidUtf8 => .skill_text_invalid,
            else => .skill_file_unavailable,
        }, .bytes = try std.fmt.allocPrint(allocator, "Rui could not prepare skills: {s}. No Message was admitted.", .{@errorName(err)}) } },
    };
    return prepared;
}

const max_batch_body_bytes = 1024 * 1024;

fn preparePayload(prepared: *PreparedMessage, allocator: std.mem.Allocator, io: std.Io, command: *const protocol.MessageCommand, found: catalog.Catalog, options: protocol.ParseOptions) !void {
    // Capture is >1KiB; one heap home, never copied on a Host stack.
    const destination = try allocator.create(protocol.ContentCapture);
    defer allocator.destroy(destination);
    try destination.init(options, 3); // Ingress owns ordinals 1 and 2.
    defer destination.deinit();
    if (command.skill == null) try destination.copy(&command.text);
    var total: usize = 0;
    const names = if (command.skill) |*name| @as([]const protocol.Bounded(64), @as([*]const protocol.Bounded(64), @ptrCast(name))[0..1]) else command.skills;
    for (names, 0..) |name, index| {
        const entry = for (found.entries) |entry| {
            if (std.mem.eql(u8, entry.name, name.slice())) break entry;
        } else return error.UnknownSkill;
        // The per-file allocation is released before the next file is read.
        const invocation = try catalog.invocationWithLength(allocator, io, entry);
        defer allocator.free(invocation.bytes);
        total = std.math.add(usize, total, invocation.raw_length) catch return error.SkillBatchTooLarge;
        if (total > max_batch_body_bytes) return error.SkillBatchTooLarge;
        if (command.skill == null and (command.text.length != 0 or index != 0)) try destination.write("\n\n");
        try destination.write(invocation.bytes);
    }
    prepared.payload = try destination.seal();
    prepared.captured = .{ .payload = &prepared.payload };
}

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
