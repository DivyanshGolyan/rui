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
    return .{ .ready = .{
        .encoded = try catalog.encodeCatalog(allocator, found),
        .instruction = if (found.entries.len == 0) null else try catalog.initialInstruction(allocator, found),
    } };
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
            const raw = catalog.readSkill(allocator, io, selected) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return .{ .failed = .{ .code = switch (err) {
                    error.SkillFileTooLarge => .skill_file_too_large,
                    error.InvalidUtf8 => .skill_text_invalid,
                    else => .skill_file_unavailable,
                }, .bytes = try std.fmt.allocPrint(allocator, "Rui could not read skill {s}: {s}. The catalog was not changed.", .{ name, @errorName(err) }) } },
            };
            // The raw file is the complete suffix, unchanged, including YAML,
            // CRLF, Unicode and trailing newlines. The path is JSON-escaped.
            const path = try std.json.Stringify.valueAlloc(allocator, selected.path, .{});
            return .{ .invocation = try std.fmt.allocPrint(allocator, "Skill file: {s}\n\n{s}", .{ path, raw }) };
        },
        .reload => return .{ .reload = catalog.discoverWithScratch(allocator, scratch_allocator, io, state.workspace.slice(), home) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .failed = .{ .code = .skills_unavailable, .bytes = try std.fmt.allocPrint(allocator, "Rui could not reload skills: {s}. The previous catalog is unchanged.", .{@errorName(err)}) } },
        } },
    }
}
