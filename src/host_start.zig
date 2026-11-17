const std = @import("std");
const hs = @import("host_settings.zig");
const launch_frame = @import("host_launch_frame.zig");
const transfer = @import("host_launch_transfer.zig");
const cli_args = @import("cli_args.zig");
const providers = @import("providers.zig");
const protocol = @import("protocol.zig");
const api_key = @import("api_key.zig");
const provider_login = @import("provider_login.zig");
const credentials = @import("codex_credentials.zig");
const platform = @import("platform.zig");
const stderr = @import("stderr.zig");

const secret_value = @import("secret_value.zig");
const codex_auth = @import("codex_auth.zig");
const start_report = @import("start_report.zig");
pub const ShutdownPolicy = hs.Interface.Lifetime;

const checkPreset = @import("host_settings_file.zig").checkPreset;

fn assign(settings: *hs.Settings, gpa: std.mem.Allocator, path: []const u8, value: []const u8, failure: *start_report.Failure) !void {
    try hs.assign(settings, gpa, path, value, checkPreset, failure);
}

fn text(settings: *hs.Settings, gpa: std.mem.Allocator, path: []const u8, value: []const u8, failure: *start_report.Failure) !void {
    for (hs.leaves) |leaf| if (std.mem.eql(u8, leaf.pattern, path) and std.mem.eql(u8, leaf.kind, "path")) return assign(settings, gpa, path, value, failure);
    var wiping: secret_value.WipingAllocator = .{ .backing = gpa };
    const json = try std.json.Stringify.valueAlloc(wiping.allocator(), value, .{});
    defer wiping.allocator().free(json);
    try assign(settings, gpa, path, json, failure);
}

fn parse(gpa: std.mem.Allocator, bytes: []const u8, failure: *start_report.Failure) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, gpa, bytes, .{ .allocate = .alloc_always, .parse_numbers = false }) catch |err| {
        if (err == error.OutOfMemory) return err;
        return invalid(failure, "settings", "must be a JSON document");
    };
}

fn encoded(gpa: std.mem.Allocator, value: std.json.Value) ![]u8 {
    return std.json.Stringify.valueAlloc(gpa, value, .{});
}

fn complete(gpa: std.mem.Allocator, settings: *const hs.Settings, failure: *start_report.Failure) !std.json.Value {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try hs.write(settings, &out.writer);
    return parse(gpa, out.written(), failure);
}

fn lookup(root: std.json.Value, path: []const u8) ?std.json.Value {
    if (path.len == 0) return root;
    if (root != .object) return null;
    const dot = std.mem.indexOfScalar(u8, path, '.');
    const child = root.object.get(path[0 .. dot orelse path.len]) orelse return null;
    return if (dot) |at| lookup(child, path[at + 1 ..]) else child;
}

fn put(gpa: std.mem.Allocator, root: *std.json.Value, path: []const u8, value: std.json.Value) !void {
    if (root.* != .object) root.* = .{ .object = .{} };
    const dot = std.mem.indexOfScalar(u8, path, '.');
    const head = path[0 .. dot orelse path.len];
    if (dot) |at| {
        if (!root.object.contains(head)) try root.object.put(gpa, try gpa.dupe(u8, head), .{ .object = .{} });
        try put(gpa, root.object.getPtr(head).?, path[at + 1 ..], value);
    } else try root.object.put(gpa, try gpa.dupe(u8, head), value);
}

fn remove(root: *std.json.Value, path: []const u8) void {
    if (root.* != .object) return;
    const dot = std.mem.indexOfScalar(u8, path, '.');
    const head = path[0 .. dot orelse path.len];
    if (dot) |at| {
        const child = root.object.getPtr(head) orelse return;
        remove(child, path[at + 1 ..]);
    } else _ = root.object.swapRemove(head);
}

fn matches(pattern: []const u8, path: []const u8) bool {
    var a = std.mem.splitScalar(u8, pattern, '.');
    var b = std.mem.splitScalar(u8, path, '.');
    while (a.next()) |part| {
        const concrete = b.next() orelse return false;
        if (!std.mem.eql(u8, part, "*") and !std.mem.eql(u8, part, concrete)) return false;
    }
    return b.next() == null;
}

fn input(init: std.process.Init, settings: *hs.Settings, path: []const u8, value: []const u8, failure: *start_report.Failure) !void {
    if (!std.mem.startsWith(u8, value, "@")) return assign(settings, init.gpa, path, value, failure);
    var wiping: secret_value.WipingAllocator = .{ .backing = init.gpa };
    var memory: std.heap.ArenaAllocator = .init(wiping.allocator());
    defer memory.deinit();
    const gpa = memory.allocator();
    const bytes = std.Io.Dir.cwd().readFileAlloc(init.io, value[1..], gpa, .limited(hs.max_document_bytes)) catch return invalid(failure, "settings", "@FILE must be readable within the document byte bound");
    defer {
        std.crypto.secureZero(u8, bytes);
        gpa.free(bytes);
    }
    const json = try parse(gpa, bytes, failure);
    for (hs.leaves) |leaf| {
        if (std.mem.eql(u8, leaf.kind, "path") and matches(leaf.pattern, path)) {
            try assign(settings, init.gpa, path, leaf.sample_text, failure);
            const dot = std.mem.lastIndexOfScalar(u8, path, '.').?;
            var child: std.json.Value = .{ .object = .{} };
            try child.object.put(gpa, path[dot + 1 ..], json);
            return assign(settings, init.gpa, path[0..dot], try encoded(gpa, child), failure);
        }
    }
    try assign(settings, init.gpa, path, bytes, failure);
}

fn savedPath(init: std.process.Init, gpa: std.mem.Allocator, dir: []const u8) ![]const u8 {
    var canonical: [protocol.max_store_bytes]u8 = undefined;
    const host = try platform.canonicalStoreDestination(init.io, dir, &canonical);
    return std.fs.path.join(gpa, &.{ host, "host.json" });
}

fn saved(init: std.process.Init, gpa: std.mem.Allocator, dir: []const u8, settings: *hs.Settings, failure: *start_report.Failure) !std.json.Value {
    var canonical: [protocol.max_store_bytes]u8 = undefined;
    const host = try platform.canonicalStoreDestination(init.io, dir, &canonical);
    return @import("host_settings_file.zig").read(init.io, init.gpa, gpa, host, settings, failure);
}

pub fn savedEdit(init: std.process.Init, dir: []const u8, path: []const u8, value: ?[]const u8, failure: *start_report.Failure) !void {
    var wiping: secret_value.WipingAllocator = .{ .backing = init.gpa };
    var memory: std.heap.ArenaAllocator = .init(wiping.allocator());
    defer memory.deinit();
    const gpa = memory.allocator();
    const target = try savedPath(init, gpa, dir);
    var directory = try std.Io.Dir.cwd().createDirPathOpen(init.io, std.fs.path.dirname(target).?, .{ .permissions = .fromMode(0o700) });
    directory.close(init.io);
    const buffer = try gpa.alloc(u8, hs.max_document_bytes + 1);
    const Edit = struct {
        init: std.process.Init,
        gpa: std.mem.Allocator,
        path: []const u8,
        value: ?[]const u8,
        failure: *start_report.Failure,
        fn apply(ctx: @This(), current: ?[]const u8) !?[]const u8 {
            const init_ = ctx.init;
            return editSaved(init_, ctx.gpa, ctx.path, ctx.value, ctx.failure, current);
        }
    };
    switch (try credentials.editPrivate(target, buffer, Edit{ .init = init, .gpa = gpa, .path = path, .value = value, .failure = failure }, Edit.apply, null)) {
        .committed => {},
        .unconfirmed => |cause| return cause,
    }
}

fn editSaved(init: std.process.Init, gpa: std.mem.Allocator, path: []const u8, value: ?[]const u8, failure: *start_report.Failure, current: ?[]const u8) !?[]const u8 {
    const settings = try init.gpa.create(hs.Settings);
    defer init.gpa.destroy(settings);
    settings.* = .{};
    defer settings.deinit();
    var document: std.json.Value = .{ .object = .{} };
    if (current) |bytes| {
        try hs.apply(settings, init.gpa, bytes, .file, checkPreset, failure);
        document = try parse(gpa, bytes, failure);
    }
    if (value) |given| {
        try input(init, settings, path, given, failure);
        const all = try complete(gpa, settings, failure);
        const admitted = lookup(all, path) orelse return invalid(failure, "settings", "assignment did not produce a setting");
        if (std.mem.startsWith(u8, path, "store.")) {
            const selected_store = lookup(all, "store").?;
            if (document.object.getPtr("store")) |old| {
                if (old.* == .object) {
                    var keys = old.object.iterator();
                    while (keys.next()) |entry| if (!selected_store.object.contains(entry.key_ptr.*)) {
                        _ = old.object.swapRemove(entry.key_ptr.*);
                        break;
                    };
                }
            }
        }
        try put(gpa, &document, path, admitted);
    } else {
        const all = try complete(gpa, settings, failure);
        if (lookup(all, path)) |existing| {
            var sample = try encoded(gpa, existing);
            for (hs.leaves) |leaf| if (std.mem.eql(u8, leaf.kind, "path") and matches(leaf.pattern, path)) {
                sample = try gpa.dupe(u8, leaf.sample_text);
                break;
            };
            try assign(settings, init.gpa, path, sample, failure);
        } else {
            var sample: []const u8 = "null";
            for (hs.leaves) |leaf| if (matches(leaf.pattern, path)) {
                sample = leaf.sample_text;
                break;
            };
            try assign(settings, init.gpa, path, sample, failure);
        }
        remove(&document, path);
    }
    const bytes = try encoded(gpa, document);
    if (bytes.len > hs.max_document_bytes) return invalid(failure, "settings", "saved document exceeds the document byte bound");
    settings.deinit();
    try hs.apply(settings, init.gpa, bytes, .file, checkPreset, failure);
    return bytes;
}

pub const openai_endpoint = @import("provider_name.zig").api_endpoint;
pub const EndpointEdit = union(enum) { unchanged: []const u8, base: []const u8 };
pub const ConnectionKey = union(enum) { provided: []const u8, existing: *const ConnectionInfo };
pub const Connection = struct {
    endpoint: protocol.Bounded(@import("endpoint_value.zig").max_endpoint_bytes) = .{},
    key_file: protocol.Bounded(hs.max_path_bytes) = .{},
};
pub const ConnectionSave = union(enum) {
    saved: Connection,
    uncertain: struct { connection: Connection, cause: anyerror },
    failed: struct { cause: anyerror, cleanup: ?struct { cause: anyerror, key_file: protocol.Bounded(hs.max_path_bytes) } = null },
};

pub fn saveConnection(init: std.process.Init, dir: []const u8, endpoint_edit: EndpointEdit, key: ConnectionKey, model: []const u8, publish: *const fn () bool) !ConnectionSave {
    return saveConnectionWithFault(init, dir, endpoint_edit, key, model, publish, .{});
}

const ConnectionFault = struct { key: ?credentials.PrivateFault = null, document: ?credentials.PrivateFault = null, cleanup: ?anyerror = null, cleanup_sync: ?anyerror = null };

fn saveConnectionWithFault(init: std.process.Init, dir: []const u8, endpoint_edit: EndpointEdit, key: ConnectionKey, model: []const u8, publish: *const fn () bool, fault: ConnectionFault) !ConnectionSave {
    if (key == .provided and !api_key.valid(key.provided)) return error.InvalidApiKey;
    var wiping: secret_value.WipingAllocator = .{ .backing = init.gpa };
    var memory: std.heap.ArenaAllocator = .init(wiping.allocator());
    defer memory.deinit();
    const gpa = memory.allocator();
    const endpoint = switch (endpoint_edit) {
        .unchanged => |endpoint| endpoint,
        .base => |base| try @import("endpoint_value.zig").endpointUnder(gpa, base),
    };
    try @import("endpoint_value.zig").validateEndpoint(endpoint);
    try @import("endpoint_value.zig").validateKeyEndpoint(endpoint, null, false);
    if (!@import("model_capability.zig").validModelSyntax(model)) return error.InvalidModel;
    const target = try savedPath(init, gpa, dir);
    const parent = std.fs.path.dirname(target).?;
    var directory = try std.Io.Dir.cwd().createDirPathOpen(init.io, parent, .{ .permissions = .fromMode(0o700), .open_options = .{ .iterate = true } });
    defer directory.close(init.io);
    var random: [16]u8 = undefined;
    try std.Io.randomSecure(init.io, &random);
    const key_file = try std.fmt.allocPrint(gpa, "{s}/.openai-{s}.key", .{ parent, std.fmt.bytesToHex(random, .lower) });
    var connection: Connection = .{};
    try connection.endpoint.set(endpoint);
    try connection.key_file.set(key_file);
    const Edit = struct {
        init: std.process.Init,
        gpa: std.mem.Allocator,
        endpoint: []const u8,
        key_file: []const u8,
        key: ConnectionKey,
        dir: []const u8,
        publish: *const fn () bool,
        staged: bool = false,
        key_fault: ?credentials.PrivateFault,
        fn apply(ctx: *@This(), current: ?[]const u8) !?[]const u8 {
            const settings = try ctx.init.gpa.create(hs.Settings);
            defer ctx.init.gpa.destroy(settings);
            settings.* = .{};
            defer settings.deinit();
            var failure: start_report.Failure = undefined;
            var document: std.json.Value = .{ .object = .{} };
            if (current) |bytes| {
                try hs.apply(settings, ctx.init.gpa, bytes, .file, checkPreset, &failure);
                document = try parse(ctx.gpa, bytes, &failure);
            }
            try checkStart(ctx.init, .{ .dir = ctx.dir }, &failure);
            const automatic = !document.object.contains("providers");
            if (ctx.key == .existing) {
                if (automatic) {
                    var entry = try defaultApiEntry(ctx.init) orelse return error.ConnectionSuperseded;
                    try matchConnectionSource(ctx.init, ctx.key.existing, ctx.endpoint, &entry);
                } else {
                    try explicitBaseUrl(ctx.init, settings, &failure);
                    const entry = if (settings.providers.entries.openai) |*entry| entry else return error.ConnectionSuperseded;
                    try matchConnectionSource(ctx.init, ctx.key.existing, ctx.endpoint, entry);
                }
            }
            if (automatic) try defaultProviders(ctx.init, settings, &failure);
            const key_bytes = switch (ctx.key) {
                .provided => |value| value,
                .existing => existing: {
                    try resolveProviders(ctx.init, settings, .{}, &failure);
                    const entry = settings.providers.entries.openai orelse return error.ApiKeyMissing;
                    if (!api_key.valid(entry.key.value())) return error.ApiKeyMissing;
                    break :existing try ctx.gpa.dupe(u8, entry.key.value());
                },
            };
            try text(settings, ctx.init.gpa, "providers.openai.endpoint", ctx.endpoint, &failure);
            try assign(settings, ctx.init.gpa, "providers.openai.key", try std.fmt.allocPrint(ctx.gpa, "file:{s}", .{ctx.key_file}), &failure);
            try assign(settings, ctx.init.gpa, "providers.openai.unauthenticated", "false", &failure);
            const all = try complete(ctx.gpa, settings, &failure);
            if (!document.object.contains("providers")) {
                try put(ctx.gpa, &document, "providers", lookup(all, "providers").?);
            } else try put(ctx.gpa, &document, "providers.openai", lookup(all, "providers.openai").?);
            const bytes = try encoded(ctx.gpa, document);
            if (bytes.len > hs.max_document_bytes) return error.SettingsInvalid;
            settings.deinit();
            try hs.apply(settings, ctx.init.gpa, bytes, .file, checkPreset, &failure);
            if (std.Io.Dir.cwd().statFile(ctx.init.io, ctx.key_file, .{ .follow_symlinks = false })) |_| return error.PathAlreadyExists else |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            }
            if (!ctx.publish()) return error.LoginInterrupted;
            if (!try api_key.create(ctx.key_file, key_bytes, &ctx.staged, ctx.key_fault)) {
                return error.PathAlreadyExists;
            }
            return bytes;
        }
    };
    var edit: Edit = .{ .init = init, .gpa = gpa, .endpoint = endpoint, .key_file = key_file, .key = key, .dir = dir, .publish = publish, .key_fault = fault.key };
    const buffer = try gpa.alloc(u8, hs.max_document_bytes + 1);
    const publication = credentials.editPrivate(target, buffer, &edit, Edit.apply, fault.document) catch |err| {
        var cleanup_error: ?anyerror = null;
        if (edit.staged) {
            if (fault.cleanup) |cleanup| cleanup_error = cleanup else std.Io.Dir.cwd().deleteFile(init.io, key_file) catch |cleanup| switch (cleanup) {
                error.FileNotFound => {},
                else => cleanup_error = cleanup,
            };
            if (cleanup_error == null) {
                if (fault.cleanup_sync) |cause| cleanup_error = cause else credentials.syncPrivateDirectory(directory) catch |cause| {
                    cleanup_error = cause;
                };
            }
        }
        if (edit.staged) return .{ .failed = .{ .cause = err, .cleanup = if (cleanup_error) |cause| .{ .cause = cause, .key_file = connection.key_file } else null } };
        return err;
    };
    return switch (publication) {
        .committed => .{ .saved = connection },
        .unconfirmed => |cause| .{ .uncertain = .{ .connection = connection, .cause = cause } },
    };
}

pub fn connectionAssignment(init: std.process.Init, gpa: std.mem.Allocator, connection: *const Connection) ![]const u8 {
    const settings = try init.gpa.create(hs.Settings);
    defer init.gpa.destroy(settings);
    settings.* = .{};
    defer settings.deinit();
    var failure: start_report.Failure = undefined;
    try text(settings, init.gpa, "providers.openai.endpoint", connection.endpoint.slice(), &failure);
    try assign(settings, init.gpa, "providers.openai.key", try std.fmt.allocPrint(gpa, "file:{s}", .{connection.key_file.slice()}), &failure);
    try assign(settings, init.gpa, "providers.openai.unauthenticated", "false", &failure);
    const all = try complete(gpa, settings, &failure);
    return std.fmt.allocPrint(gpa, "providers.openai={s}", .{try encoded(gpa, lookup(all, "providers.openai").?)});
}

pub fn confirmConnection(init: std.process.Init, dir: []const u8, connection: *const Connection) !ConnectionSave {
    return confirmConnectionWithFault(init, dir, connection, null);
}

fn confirmConnectionWithFault(init: std.process.Init, dir: []const u8, connection: *const Connection, fault: ?credentials.PrivateFault) !ConnectionSave {
    var wiping: secret_value.WipingAllocator = .{ .backing = init.gpa };
    var memory: std.heap.ArenaAllocator = .init(wiping.allocator());
    defer memory.deinit();
    const gpa = memory.allocator();
    const Check = struct {
        init: std.process.Init,
        connection: *const Connection,
        matches: bool = false,
        fn apply(ctx: *@This(), current: ?[]const u8) !?[]const u8 {
            const bytes = current orelse return null;
            const settings = try ctx.init.gpa.create(hs.Settings);
            defer ctx.init.gpa.destroy(settings);
            settings.* = .{};
            defer settings.deinit();
            var failure: start_report.Failure = undefined;
            try hs.apply(settings, ctx.init.gpa, bytes, .file, checkPreset, &failure);
            const entry = settings.providers.entries.openai orelse return null;
            const endpoint = if (entry.endpoint) |*value| value.slice() else openai_endpoint;
            if (entry.key.source != .file or entry.unauthenticated.value or !std.mem.eql(u8, endpoint, ctx.connection.endpoint.slice()) or !std.mem.eql(u8, entry.key.source.file.slice(), ctx.connection.key_file.slice())) return null;
            ctx.matches = true;
            return bytes;
        }
    };
    var check: Check = .{ .init = init, .connection = connection };
    const result = try credentials.editPrivate(try savedPath(init, gpa, dir), try gpa.alloc(u8, hs.max_document_bytes + 1), &check, Check.apply, fault);
    if (!check.matches) return error.ConnectionSuperseded;
    return switch (result) {
        .committed => .{ .saved = connection.* },
        .unconfirmed => |cause| .{ .uncertain = .{ .connection = connection.*, .cause = cause } },
    };
}

pub const ConnectionInfo = struct {
    endpoint: protocol.Bounded(@import("endpoint_value.zig").max_endpoint_bytes) = .{},
    readiness: @import("provider_selection.zig").Readiness = .missing,
    key_source: ?@FieldType(hs.Secret(.provider_saved), "source") = null,
    unauthenticated: bool = false,
    pub fn reusable(self: *const @This()) bool {
        return self.readiness.usable() and !self.unauthenticated and self.key_source != null;
    }
    pub fn custom(self: *const @This()) bool {
        return !std.mem.eql(u8, self.endpoint.slice(), openai_endpoint);
    }
};

fn matchConnectionSource(init: std.process.Init, expected: *const ConnectionInfo, endpoint: []const u8, entry: *hs.ProviderEntry(.api_key)) !void {
    const current_endpoint = if (entry.endpoint) |*value| value.slice() else openai_endpoint;
    if (!expected.reusable() or entry.unauthenticated.value or !std.mem.eql(u8, expected.endpoint.slice(), endpoint) or !std.mem.eql(u8, current_endpoint, endpoint)) return error.ConnectionSuperseded;
    try defaultKeySource(init, &entry.key);
    const source = expected.key_source.?;
    if (std.meta.activeTag(source) != std.meta.activeTag(entry.key.source)) return error.ConnectionSuperseded;
    const same = switch (source) {
        .file => |*file| std.mem.eql(u8, file.slice(), entry.key.source.file.slice()),
        .env => |*name| std.mem.eql(u8, name.slice(), entry.key.source.env.slice()),
        .default, .literal => false,
    };
    if (!same) return error.ConnectionSuperseded;
}

fn defaultKeySource(init: std.process.Init, key: *hs.Secret(.provider_saved)) !void {
    if (key.source != .default) return;
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = api_key.path(init.environ_map, &path_buffer) catch |err| return if (err == error.HomeRequired) error.HomeUnavailable else err;
    key.source = .{ .file = .{} };
    try key.source.file.text.set(path);
}

pub fn inspectConnection(init: std.process.Init, dir: []const u8) !ConnectionInfo {
    const settings = try init.gpa.create(hs.Settings);
    defer init.gpa.destroy(settings);
    settings.* = .{};
    defer settings.deinit();
    var problem: cli_args.Refusal = undefined;
    const parsed = try cli_args.Command.host_serve.definition().parse(&.{}, init.arena.allocator(), &problem);
    var fixtures: providers.Fixtures = .{};
    var failure: start_report.Failure = undefined;
    try fillAt(init, &parsed, dir, settings, &fixtures, &failure);
    var result: ConnectionInfo = .{};
    try result.endpoint.set(if (settings.providers.entries.openai) |*entry| if (entry.endpoint) |*value| value.slice() else openai_endpoint else openai_endpoint);
    if (settings.providers.entries.openai) |*entry| {
        result.unauthenticated = entry.unauthenticated.value;
        if (!entry.unauthenticated.value) {
            try defaultKeySource(init, &entry.key);
            result.key_source = entry.key.source;
        }
    } else return result;
    resolveProviders(init, settings, fixtures, &failure) catch {
        result.readiness = .credential_error;
        return result;
    };
    result.readiness = .configured;
    return result;
}

pub fn showSaved(init: std.process.Init, dir: []const u8, out: *std.Io.Writer, failure: *start_report.Failure) !void {
    var wiping: secret_value.WipingAllocator = .{ .backing = init.gpa };
    var memory: std.heap.ArenaAllocator = .init(wiping.allocator());
    defer memory.deinit();
    const settings = try init.gpa.create(hs.Settings);
    defer init.gpa.destroy(settings);
    settings.* = .{};
    defer settings.deinit();
    const document = try saved(init, memory.allocator(), dir, settings, failure);
    if (!document.object.contains("providers")) try defaultProviders(init, settings, failure);
    try hs.write(settings, out);
    try out.writeByte('\n');
}

pub fn listPaths(out: *std.Io.Writer) !void {
    for (hs.leaves) |leaf| try out.print("{s}\t{s}\t{s}\t{s}\n", .{ leaf.pattern, leaf.kind, leaf.default, leaf.doc });
}

fn defaultProviders(init: std.process.Init, settings: *hs.Settings, failure: *start_report.Failure) !void {
    try assign(settings, init.gpa, "providers", "{}", failure);
    inline for (std.enums.values(protocol.Provider)) |provider| {
        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const usable = switch (comptime provider.facts().credential) {
            .sign_in => if (comptime provider.facts().model_list == .catalog) true else usable: {
                const path = provider_login.credentialPath(init, provider, &path_buffer, false) catch break :usable false;
                const status = codex_auth.localStatus(path, codex_auth.nowSeconds(init.io)) catch break :usable false;
                break :usable status == .configured or status == .renewal_due;
            },
            .api_key => usable: {
                const path = api_key.path(init.environ_map, &path_buffer) catch break :usable false;
                break :usable api_key.present(path) catch false;
            },
        };
        if (usable) serve: {
            const at = "providers." ++ @tagName(provider);
            if (comptime provider.facts().credential == .api_key) {
                @field(settings.providers.entries, @tagName(provider)) = try defaultApiEntry(init) orelse break :serve;
                break :serve;
            }
            try assign(settings, init.gpa, at, "{}", failure);
        }
    }
}

fn defaultApiEntry(init: std.process.Init) !?hs.ProviderEntry(.api_key) {
    var entry: hs.ProviderEntry(.api_key) = .{};
    if (init.environ_map.get(providers.openai_base_url_variable)) |base| {
        const endpoint = providers.endpointUnder(init.gpa, base) catch |err| {
            if (err != error.InvalidBaseUrl) return err;
            stderr.diagnostic(@import("host_launch.zig").invalid_base_url ++ "; this Host starts without {s}.\n", .{protocol.Provider.openai.shown()});
            return null;
        };
        defer init.gpa.free(endpoint);
        entry.endpoint = .{};
        try entry.endpoint.?.text.set(endpoint);
    }
    return entry;
}

fn explicitBaseUrl(init: std.process.Init, settings: *hs.Settings, failure: *start_report.Failure) !void {
    const entry = settings.providers.entries.openai orelse return;
    if (entry.endpoint != null) return;
    const base = init.environ_map.get(providers.openai_base_url_variable) orelse return;
    const endpoint = providers.endpointUnder(init.gpa, base) catch |err| {
        if (err == error.InvalidBaseUrl) stderr.diagnostic(@import("host_launch.zig").invalid_base_url ++ "; the Host did not start.\n", .{});
        return err;
    };
    defer init.gpa.free(endpoint);
    try text(settings, init.gpa, "providers.openai.endpoint", endpoint, failure);
}

pub fn fillAt(init: std.process.Init, parsed: *const cli_args.Parsed, dir: []const u8, settings: *hs.Settings, fixtures: *providers.Fixtures, failure: *start_report.Failure) !void {
    if (parsed.get("test-codex-fixture-endpoint") != null and init.environ_map.get("RUI_CODEX_CREDENTIAL_FILE") == null) return error.FixtureCredentialPathRequired;
    if (parsed.get("test-chatgpt-fixture-endpoint") != null and init.environ_map.get("RUI_CHATGPT_CREDENTIAL_FILE") == null) return error.FixtureCredentialPathRequired;
    if (parsed.get("test-openai-fixture-endpoint") != null and init.environ_map.get(api_key.path_variable) == null) return error.FixtureCredentialPathRequired;
    const intent = try readSources(init, .{ .dir = dir, .settings_file = parsed.get("settings"), .assignments = parsed.all("set") }, settings, failure);
    try finishSources(init, settings, intent, failure);
    try fixtureInputs(init, parsed, settings, fixtures, failure);
}

/// One placement owner for serving, starting and directory-based client lookup.
/// Reading placement never resolves a secret or inspects provider credentials.
pub fn anchorPlacement(init: std.process.Init, settings: *hs.Settings, dir: []const u8, failure: *start_report.Failure) !void {
    return platform.anchorPlacement(init.io, settings, dir, failure);
}

fn existingPlacement(io: std.Io, dir: []const u8) !platform.Paths {
    return (platform.ClientSelection{ .directory = dir }).paths(io);
}

pub const savedPlacement = platform.savedPlacement;

/// A private, empty Host directory: tests must not read the checkout's cwd.
fn testHostDir(tmp: *std.testing.TmpDir, buffer: *[std.Io.Dir.max_path_bytes]u8) ![]const u8 {
    var host = try tmp.dir.createDirPathOpen(std.testing.io, "host-dir", .{ .permissions = .fromMode(0o700) });
    defer host.close(std.testing.io);
    return buffer[0..try host.realPath(std.testing.io, buffer)];
}

fn fixtureInputs(init: std.process.Init, parsed: *const cli_args.Parsed, settings: *hs.Settings, fixtures: *providers.Fixtures, failure: *start_report.Failure) !void {
    const gpa = init.gpa;
    if (parsed.get("test-openai-fixture-endpoint")) |endpoint| {
        try text(settings, gpa, "providers.openai.endpoint", endpoint, failure);
        try assign(settings, gpa, "providers.openai.unauthenticated", "true", failure);
        fixtures.openai = true;
    }
    if (parsed.get("test-codex-fixture-endpoint")) |endpoint| {
        try text(settings, gpa, "providers.codex.endpoint", endpoint, failure);
        try assign(settings, gpa, "providers.codex.unauthenticated", "true", failure);
        fixtures.codex = true;
    }
    if (parsed.get("test-chatgpt-fixture-endpoint")) |endpoint| {
        const base = providers.responsesBase(endpoint) orelse return error.InvalidArguments;
        try text(settings, gpa, "providers.chatgpt.endpoint", endpoint, failure);
        try assign(settings, gpa, "providers.chatgpt.unauthenticated", "true", failure);
        fixtures.chatgpt_token_endpoint = try std.fmt.allocPrint(init.arena.allocator(), "{s}/oauth/token", .{base});
    }
}

fn invalid(failure: *start_report.Failure, comptime path: []const u8, comptime reason: []const u8) error{SettingsInvalid} {
    failure.* = .init(.settings_invalid, path ++ ": " ++ reason);
    return error.SettingsInvalid;
}

pub noinline fn readDocument(init: std.process.Init, source: []const u8, settings: *hs.Settings, failure: *start_report.Failure) !void {
    _ = try readDocumentAt(init, source, settings, failure);
}

fn readDocumentAt(init: std.process.Init, source: []const u8, settings: *hs.Settings, failure: *start_report.Failure) !bool {
    if (std.mem.eql(u8, source, "-")) return readPipeAt(init, .stdin(), settings, failure);
    var wiping: secret_value.WipingAllocator = .{ .backing = init.gpa };
    var memory: std.heap.ArenaAllocator = .init(wiping.allocator());
    defer memory.deinit();
    const gpa = memory.allocator();
    const buffer = try gpa.alloc(u8, hs.max_document_bytes + 1);
    var cwd: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = if (std.fs.path.isAbsolute(source)) source else try std.fs.path.join(gpa, &.{ cwd[0..try std.Io.Dir.cwd().realPath(init.io, &cwd)], source });
    const bytes = credentials.readPrivate(path, buffer) catch return invalid(failure, "settings", "must be a readable private file within the document byte bound");
    const document = bytes orelse return invalid(failure, "settings", "file does not exist");
    try hs.apply(settings, init.gpa, document, .file, checkPreset, failure);
    const json = try parse(gpa, document, failure);
    return json.object.contains("providers");
}

pub fn documentNamesProviders(init: std.process.Init, source: []const u8) !bool {
    const settings = try init.gpa.create(hs.Settings);
    defer init.gpa.destroy(settings);
    settings.* = .{};
    defer settings.deinit();
    var failure: start_report.Failure = undefined;
    return readDocumentAt(init, source, settings, &failure);
}

fn readPipe(init: std.process.Init, file: std.Io.File, settings: *hs.Settings, failure: *start_report.Failure) !void {
    _ = try readPipeAt(init, file, settings, failure);
}

fn readPipeAt(init: std.process.Init, file: std.Io.File, settings: *hs.Settings, failure: *start_report.Failure) !bool {
    var wiping: secret_value.WipingAllocator = .{ .backing = init.gpa };
    var memory: std.heap.ArenaAllocator = .init(wiping.allocator());
    defer memory.deinit();
    var prefix: [4]u8 = undefined;
    readExact(init.io, file, &prefix) catch return invalid(failure, "settings", "stdin closed before the 4-byte document length");
    const length = std.mem.readInt(u32, &prefix, .big);
    if (length == 0 or length > hs.max_document_bytes) return invalid(failure, "settings", "document length must be 1 to 1048576 bytes");
    const bytes = try memory.allocator().alloc(u8, length);
    readExact(init.io, file, bytes) catch return invalid(failure, "settings", "stdin closed before the whole document arrived");
    try hs.apply(settings, init.gpa, bytes, .pipe, checkPreset, failure);
    const json = try parse(memory.allocator(), bytes, failure);
    return json.object.contains("providers");
}

fn readExact(io: std.Io, file: std.Io.File, buffer: []u8) !void {
    var filled: usize = 0;
    while (filled < buffer.len) {
        const count = try file.readStreaming(io, &.{buffer[filled..]});
        if (count == 0) return error.EndOfStream;
        filled += count;
    }
}

pub noinline fn report(io: std.Io, failure: *const start_report.Failure) void {
    var buffer: [start_report.max_line_bytes]u8 = undefined;
    std.Io.File.stdout().writeStreamingAll(io, start_report.line(failure, &buffer)) catch {};
    const sentence = std.fmt.bufPrint(&buffer, "rui: the Host did not start: {f} [{s}]\n", .{ std.zig.fmtString(failure.message.slice()), @tagName(failure.code) }) catch unreachable;
    std.Io.File.stderr().writeStreamingAll(io, sentence) catch {};
}

pub fn prepare(init: std.process.Init, settings: *hs.Settings, fixtures: providers.Fixtures, failure: *start_report.Failure) !hs.Prepared {
    var cwd: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (settings.store == .mysql and settings.interface.dir.anchored)
        try anchorPlacement(init, settings, cwd[0..try std.Io.Dir.cwd().realPath(init.io, &cwd)], failure);
    hs.anchor(settings, cwd[0..try std.Io.Dir.cwd().realPath(init.io, &cwd)]) catch return invalid(failure, "store.sqlite.dir", "Host directory exceeds the path byte bound");
    try resolveProviders(init, settings, fixtures, failure);
    if (settings.store == .mysql) resolve(init, &settings.store.mysql.url) catch |err| return resolutionFailure(failure, "store.mysql.url", err);
    for (settings.tools.mcp.names[0..settings.tools.mcp.len], settings.tools.mcp.values[0..settings.tools.mcp.len]) |*name, *server| {
        resolve(init, &server.bearer_token) catch |err| {
            var path_buffer: [128]u8 = undefined;
            return resolutionFailure(failure, try std.fmt.bufPrint(&path_buffer, "tools.mcp.{s}.bearerToken", .{name.slice()}), err);
        };
    }
    return hs.seal(settings, failure);
}

pub fn resolveProviders(init: std.process.Init, settings: *hs.Settings, fixtures: providers.Fixtures, failure: *start_report.Failure) !void {
    inline for (std.enums.values(protocol.Provider)) |provider| {
        if (@field(settings.providers.entries, @tagName(provider))) |*entry| {
            switch (comptime provider.facts().credential) {
                .api_key => if (!entry.unauthenticated.value or fixtures.openai) {
                    if (entry.key.source == .default) {
                        try defaultKeySource(init, &entry.key);
                        resolve(init, &entry.key) catch |err| {
                            if (err == error.ApiKeyMissing) stderr.diagnostic("rui: no OpenAI API key; save one with `" ++ comptime protocol.Provider.openai.login().? ++ "`, then start the Host again.\n", .{});
                            return err;
                        };
                    } else resolve(init, &entry.key) catch |err| return resolutionFailure(failure, "providers." ++ @tagName(provider) ++ ".key", err);
                },
                .sign_in => if (!entry.unauthenticated.value or (provider == .codex and fixtures.codex) or (provider == .chatgpt and fixtures.chatgpt_token_endpoint != null)) {
                    if (entry.credential_file == null) {
                        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
                        const path = provider_login.credentialPath(init, provider, &path_buffer, false) catch |err| return if (err == error.HomeRequired) error.HomeUnavailable else err;
                        entry.credential_file = .{};
                        try entry.credential_file.?.text.set(path);
                    }
                },
            }
        }
    }
}

fn resolutionFailure(failure: *start_report.Failure, path: []const u8, err: anyerror) anyerror {
    if (err == error.OutOfMemory) return err;
    failure.code = .settings_invalid;
    const message = std.fmt.bufPrint(&failure.message.bytes, "{s}: credential source is missing, unreadable, insecure or invalid", .{path}) catch unreachable;
    failure.message.len = message.len;
    return error.SettingsInvalid;
}

fn resolve(init: std.process.Init, secret: anytype) !void {
    const Secret = @typeInfo(@TypeOf(secret)).pointer.child;
    if (secret.source == .literal) return;
    if (comptime Secret.default_source == .mysql) {
        if (secret.bytes.parsed != null) return;
    } else if (secret.bytes.len != 0) return;
    const buffer = try init.arena.allocator().alloc(u8, if (Secret.default_source == .mysql) hs.max_document_bytes + 2 else api_key.max_key_bytes + 2);
    defer {
        std.crypto.secureZero(u8, buffer);
        init.arena.allocator().free(buffer);
    }
    const bytes = switch (secret.source) {
        .literal => unreachable,
        .default => return error.ApiKeyMissing,
        .env => |*name| init.environ_map.get(name.slice()) orelse return error.ApiKeyMissing,
        .file => |*file| api_key.trimNewline(try credentials.readPrivate(file.slice(), buffer) orelse return error.ApiKeyMissing),
    };
    if (Secret.default_source == .mysql) {
        try secret.bytes.set(init.arena.allocator(), bytes);
    } else {
        if (!api_key.valid(bytes)) return error.InvalidApiKey;
        secret.bytes.wipe();
        @memcpy(secret.bytes.bytes[0..bytes.len], bytes);
        secret.bytes.len = bytes.len;
    }
}

pub noinline fn selectStore(init: std.process.Init, settings: *hs.Settings, selected: []const u8, from_document: bool, failure: *start_report.Failure) !void {
    _ = from_document;
    var canonical: [protocol.max_store_bytes]u8 = undefined;
    const value = platform.canonicalStoreDestination(init.io, selected, &canonical) catch |err| switch (err) {
        error.StorePathTooLong, error.NameTooLong => return invalid(failure, "store.sqlite.dir", "canonical path exceeds the Store byte bound"),
        else => return err,
    };
    if (settings.store == .mysql) {
        if (settings.interface.dir.anchored) try text(settings, init.gpa, "interface.dir", value, failure);
    } else try text(settings, init.gpa, "store.sqlite.dir", value, failure);
}

pub fn shutdownPolicy(settings: *const hs.Settings) ShutdownPolicy {
    return settings.interface.lifetime.value;
}

pub fn storeKind(settings: *const hs.Settings) start_report.Store {
    return if (settings.store == .mysql) .mysql else .sqlite;
}

pub const Admission = enum { foreground, detached };

/// Shared --check/serve intake: detached checks use the starter's read and
/// placement admission, without rebasing a running Host's argv. Both doors
/// finish provider selection and resolve before the caller's proxy precondition
/// and `admitSelected` anchor/seal. No Store or Host is opened here.
pub fn intake(init: std.process.Init, parsed: *const cli_args.Parsed, dir: []const u8, settings: *hs.Settings, fixtures: *providers.Fixtures, failure: *start_report.Failure, admission: Admission) !void {
    switch (admission) {
        .foreground => try fillAt(init, parsed, dir, settings, fixtures, failure),
        .detached => {
            const intent = try readStart(init, .{ .dir = dir, .settings_file = parsed.get("settings"), .assignments = parsed.all("set") }, settings, failure);
            try finishSources(init, settings, intent, failure);
            try fixtureInputs(init, parsed, settings, fixtures, failure);
        },
    }
    try resolveProviders(init, settings, fixtures.*, failure);
}

pub fn admitSelected(init: std.process.Init, dir: []const u8, settings: *hs.Settings, fixtures: providers.Fixtures, failure: *start_report.Failure) !hs.Prepared {
    try anchorPlacement(init, settings, dir, failure);
    return prepare(init, settings, fixtures, failure);
}

fn parseForTest(gpa: std.mem.Allocator, args: []const []const u8) !cli_args.Parsed {
    var problem: cli_args.Refusal = undefined;
    return cli_args.Command.host_serve.definition().parse(args, gpa, &problem);
}

fn initForTest(arena: *std.heap.ArenaAllocator, env: *std.process.Environ.Map) std.process.Init {
    return .{ .minimal = .{ .args = .{ .vector = &.{} }, .environ = .empty }, .arena = arena, .gpa = std.testing.allocator, .io = std.testing.io, .environ_map = env, .preopens = .empty };
}

test "Host start resolves environment private file and saved credential sources" {
    const gpa = std.testing.allocator;
    var environment: std.process.Environ.Map = .init(gpa);
    defer environment.deinit();
    try environment.put("HOST_START_TEST_\xff", "env-key");
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const init = initForTest(&arena, &environment);
    const settings = try gpa.create(hs.Settings);
    defer gpa.destroy(settings);
    settings.* = .{};
    defer settings.deinit();
    var failure: start_report.Failure = undefined;
    try hs.apply(settings, gpa, "{\"providers\":{}}", .file, checkPreset, &failure);
    try assign(settings, gpa, "providers.openai.key", "env:HOST_START_TEST_\xff", &failure);
    _ = try prepare(init, settings, .{}, &failure);
    try std.testing.expectEqualStrings("env-key", settings.providers.entries.openai.?.key.value());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var private = try tmp.dir.createDirPathOpen(std.testing.io, "private", .{ .permissions = .fromMode(0o700) });
    defer private.close(std.testing.io);
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    // APFS rejects malformed UTF-8 filenames, so the created file uses valid UTF-8.
    const path = try std.fmt.allocPrint(arena.allocator(), "{s}/private/openai.key", .{root[0..try tmp.dir.realPath(std.testing.io, &root)]});
    try api_key.install(path, "file-key");
    try assign(settings, arena.allocator(), "providers.openai.key", "null", &failure);
    try environment.put(api_key.path_variable, path);
    try environment.put("RUI_CODEX_CREDENTIAL_FILE", "/tmp/./codex-\xff.json");
    try environment.put("RUI_CHATGPT_CREDENTIAL_FILE", "/tmp/./chatgpt-\xff.json");
    try assign(settings, arena.allocator(), "providers.codex", "{}", &failure);
    try assign(settings, arena.allocator(), "providers.chatgpt", "{}", &failure);
    _ = try prepare(init, settings, .{}, &failure);
    try std.testing.expectEqualStrings("file-key", settings.providers.entries.openai.?.key.value());
    try std.testing.expectEqualStrings(path, settings.providers.entries.openai.?.key.source.file.slice());
    try std.testing.expectEqualStrings("/tmp/./codex-\xff.json", settings.providers.entries.codex.?.credential_file.?.slice());
    try std.testing.expectEqualStrings("/tmp/./chatgpt-\xff.json", settings.providers.entries.chatgpt.?.credential_file.?.slice());
    try private.setFilePermissions(std.testing.io, "openai.key", .fromMode(0o644), .{});
    try assign(settings, arena.allocator(), "providers.openai.key", "null", &failure);
    try std.testing.expectError(error.InsecureCredentialFile, prepare(init, settings, .{}, &failure));
    try assign(settings, arena.allocator(), "providers.openai.key", try std.fmt.allocPrint(arena.allocator(), "file:{s}", .{path}), &failure);
    try std.testing.expectError(error.SettingsInvalid, prepare(init, settings, .{}, &failure));
    try std.testing.expect(std.mem.startsWith(u8, failure.message.slice(), "providers.openai.key:"));
}

test "Host start canonical Store leaf accepts a long raw alias" {
    const gpa = std.testing.allocator;
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const init = initForTest(&arena, &env);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var private = try tmp.dir.createDirPathOpen(std.testing.io, "store", .{ .permissions = .fromMode(0o700) });
    defer private.close(std.testing.io);
    const canonical = root[0..try private.realPath(std.testing.io, &root)];
    const alias = try arena.allocator().alloc(u8, canonical.len + 540);
    @memcpy(alias[0..canonical.len], canonical);
    for (0..180) |i| @memcpy(alias[canonical.len + i * 3 ..][0..3], "/./");
    try std.testing.expect(alias.len >= 580);
    const settings = try gpa.create(hs.Settings);
    defer gpa.destroy(settings);
    settings.* = .{};
    defer settings.deinit();
    var failure: start_report.Failure = undefined;
    try selectStore(init, settings, alias, false, &failure);
    try std.testing.expectEqualStrings(canonical, settings.store.sqlite.dir.slice());
    try savedEdit(init, alias, "execution.paused", "true", &failure);
    var shown: std.Io.Writer.Allocating = .init(gpa);
    defer shown.deinit();
    try showSaved(init, alias, &shown.writer, &failure);
    const json = try parse(arena.allocator(), shown.written(), &failure);
    try std.testing.expect(lookup(json, "execution.paused").?.bool);
}

test "Host start pipe reads one bounded document without implying lifetime" {
    const gpa = std.testing.allocator;
    var environment: std.process.Environ.Map = .init(gpa);
    defer environment.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const init = initForTest(&arena, &environment);
    const document = "{\"providers\":{\"openai\":{\"key\":{\"value\":\"pipe-key\"}}},\"tools\":{\"bash\":{\"timeoutMs\":17}}}";
    var bytes: [4 + document.len]u8 = undefined;
    std.mem.writeInt(u32, bytes[0..4], document.len, .big);
    @memcpy(bytes[4..], document);
    const settings = try gpa.create(hs.Settings);
    defer gpa.destroy(settings);
    for ([_]usize{ bytes.len, 2, 4, bytes.len - 1 }) |sent| {
        settings.* = .{};
        defer settings.deinit();
        var fds: [2]std.posix.fd_t = undefined;
        if (std.c.pipe(&fds) != 0) return error.PipeFailed;
        const reader: std.Io.File = .{ .handle = fds[0], .flags = .{ .nonblocking = false } };
        defer reader.close(init.io);
        const writer: std.Io.File = .{ .handle = fds[1], .flags = .{ .nonblocking = false } };
        try writer.writeStreamingAll(init.io, bytes[0..sent]);
        writer.close(init.io);
        var failure: start_report.Failure = undefined;
        if (sent == bytes.len) {
            try readPipe(init, reader, settings, &failure);
            try std.testing.expectEqualStrings("pipe-key", settings.providers.entries.openai.?.key.value());
            try std.testing.expectEqual(@as(u64, 17), settings.tools.bash.timeout_ms.value);
            try std.testing.expectEqual(hs.Interface.Lifetime.detached, settings.interface.lifetime.value);
        } else {
            try std.testing.expectError(error.SettingsInvalid, readPipe(init, reader, settings, &failure));
            try std.testing.expectEqual(start_report.StartError.settings_invalid, failure.code);
            try std.testing.expect(std.mem.indexOf(u8, failure.message.slice(), "pipe-key") == null);
        }
    }
    for ([_]u32{ 0, hs.max_document_bytes + 1, std.math.maxInt(u32) }) |length| {
        settings.* = .{};
        defer settings.deinit();
        var fds: [2]std.posix.fd_t = undefined;
        if (std.c.pipe(&fds) != 0) return error.PipeFailed;
        const reader: std.Io.File = .{ .handle = fds[0], .flags = .{ .nonblocking = false } };
        defer reader.close(init.io);
        const writer: std.Io.File = .{ .handle = fds[1], .flags = .{ .nonblocking = false } };
        defer writer.close(init.io);
        var prefix: [4]u8 = undefined;
        std.mem.writeInt(u32, &prefix, length, .big);
        try writer.writeStreamingAll(init.io, &prefix);
        var failure: start_report.Failure = undefined;
        try std.testing.expectError(error.SettingsInvalid, readPipe(init, reader, settings, &failure));
    }
}

test "Host start private file origin refuses literal secrets and assignments override document leaves" {
    const gpa = std.testing.allocator;
    var environment: std.process.Environ.Map = .init(gpa);
    defer environment.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const init = initForTest(&arena, &environment);
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var host_root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var private = try tmp.dir.createDirPathOpen(init.io, "private", .{ .permissions = .fromMode(0o700), .open_options = .{ .iterate = true } });
    defer private.close(init.io);
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.allocPrint(arena.allocator(), "{s}/host.json", .{root[0..try private.realPath(init.io, &root)]});
    const settings = try gpa.create(hs.Settings);
    defer gpa.destroy(settings);
    settings.* = .{};
    defer settings.deinit();
    var failure: start_report.Failure = undefined;
    try private.writeFile(init.io, .{ .sub_path = "host.json", .data = "{\"providers\":{\"openai\":{\"key\":{\"value\":\"never-print-this\"}}}}" });
    try private.setFilePermissions(init.io, "host.json", .fromMode(0o600), .{});
    try std.testing.expectError(error.SettingsInvalid, readDocument(init, path, settings, &failure));
    try std.testing.expectEqual(start_report.StartError.settings_invalid, failure.code);
    try std.testing.expect(std.mem.indexOf(u8, failure.message.slice(), "providers.openai.key") != null);
    try std.testing.expect(std.mem.indexOf(u8, failure.message.slice(), "never-print-this") == null);
    try private.writeFile(init.io, .{ .sub_path = "host.json", .data = "{\"providers\":{},\"tools\":{\"bash\":{\"timeoutMs\":17}},\"execution\":{\"activeCapacity\":3},\"interface\":{\"lifetime\":\"stdin\"}}" });
    const parsed = try parseForTest(arena.allocator(), &.{ "--settings", path, "--set", "tools.bash.timeoutMs=99", "--set", "execution.activeCapacity=4", "--set", "providers.codex={}" });
    var fixtures: providers.Fixtures = .{};
    try fillAt(init, &parsed, try testHostDir(&tmp, &host_root), settings, &fixtures, &failure);
    try std.testing.expectEqual(@as(u64, 99), settings.tools.bash.timeout_ms.value);
    try std.testing.expectEqual(@as(usize, 4), settings.execution.active_capacity.value);
    try std.testing.expectEqual(hs.Interface.Lifetime.stdin, settings.interface.lifetime.value);
    try std.testing.expect(settings.providers.entries.codex != null);
    try private.setFilePermissions(init.io, "host.json", .fromMode(0o644), .{});
    try std.testing.expectError(error.SettingsInvalid, readDocument(init, path, settings, &failure));
}

test "Host start pipe file and assignment admissions report every code on both streams even if one refuses" {
    const Probe = struct {
        var output: [2][4096]u8 = undefined;
        var used: [2]usize = .{ 0, 0 };
        var refused: ?usize = null;
        var attempted: [2]bool = .{ false, false };
        fn operate(userdata: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
            if (operation == .file_write_streaming) {
                const write = operation.file_write_streaming;
                if (write.file.handle == 1 or write.file.handle == 2) {
                    const index: usize = @intCast(write.file.handle - 1);
                    attempted[index] = true;
                    if (refused == index) return .{ .file_write_streaming = error.NoSpaceLeft };
                    var out = std.Io.Writer.fixed(output[index][used[index]..]);
                    out.writeAll(write.header) catch return .{ .file_write_streaming = error.NoSpaceLeft };
                    for (write.data, 0..) |part, i| {
                        const repeats = if (i == write.data.len - 1) write.splat else 1;
                        for (0..repeats) |_| out.writeAll(part) catch return .{ .file_write_streaming = error.NoSpaceLeft };
                    }
                    used[index] += out.buffered().len;
                    return .{ .file_write_streaming = out.buffered().len };
                }
            }
            return std.testing.io.vtable.operate(userdata, operation);
        }
    };
    var vtable = std.testing.io.vtable.*;
    vtable.operate = Probe.operate;
    const io: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    const gpa = std.testing.allocator;
    var environment: std.process.Environ.Map = .init(gpa);
    defer environment.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const init = initForTest(&arena, &environment);
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var host_root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var private = try tmp.dir.createDirPathOpen(init.io, "private", .{ .permissions = .fromMode(0o700), .open_options = .{ .iterate = true } });
    defer private.close(init.io);
    const document = "{\"providers\":{},\"tools\":{\"bash\":{\"timeoutMs\":17}}}";
    try private.writeFile(init.io, .{ .sub_path = "host.json", .data = document });
    try private.setFilePermissions(init.io, "host.json", .fromMode(0o600), .{});
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.allocPrint(arena.allocator(), "{s}/host.json", .{root[0..try private.realPath(init.io, &root)]});
    const settings = try gpa.create(hs.Settings);
    defer gpa.destroy(settings);
    for ([_]enum { pipe, file, assignments }{ .pipe, .file, .assignments }) |source| {
        settings.* = .{};
        defer settings.deinit();
        var admission_failure: start_report.Failure = undefined;
        var fixtures: providers.Fixtures = .{};
        switch (source) {
            .pipe => {
                var bytes: [4 + document.len]u8 = undefined;
                std.mem.writeInt(u32, bytes[0..4], document.len, .big);
                @memcpy(bytes[4..], document);
                var fds: [2]std.posix.fd_t = undefined;
                if (std.c.pipe(&fds) != 0) return error.PipeFailed;
                const reader: std.Io.File = .{ .handle = fds[0], .flags = .{ .nonblocking = false } };
                defer reader.close(init.io);
                const writer: std.Io.File = .{ .handle = fds[1], .flags = .{ .nonblocking = false } };
                defer writer.close(init.io);
                try writer.writeStreamingAll(init.io, &bytes);
                try readPipe(init, reader, settings, &admission_failure);
            },
            .file => {
                const parsed = try parseForTest(arena.allocator(), &.{ "--settings", path });
                try fillAt(init, &parsed, try testHostDir(&tmp, &host_root), settings, &fixtures, &admission_failure);
            },
            .assignments => {
                const parsed = try parseForTest(arena.allocator(), &.{ "--set", "tools.bash.timeoutMs=17" });
                try fillAt(init, &parsed, try testHostDir(&tmp, &host_root), settings, &fixtures, &admission_failure);
            },
        }
        try std.testing.expectEqual(@as(u64, 17), settings.tools.bash.timeout_ms.value);
        const Message = struct { raw: []const u8, json: []const u8, sentence: []const u8 };
        inline for ([_]Message{
            .{ .raw = "message", .json = "\"message\"", .sentence = "message" },
            .{ .raw = "line\n\r\t\x1b", .json = "\"line\\n\\r\\t\\u001b\"", .sentence = "line\\n\\r\\t\\x1b" },
            .{ .raw = "literal\\n\\x1b\"", .json = "\"literal\\\\n\\\\x1b\\\"\"", .sentence = "literal\\\\n\\\\x1b\\\"" },
            .{ .raw = "\u{0085}\u{2028}\u{2029}\u{feff}", .json = "\"\u{0085}\u{2028}\u{2029}\u{feff}\"", .sentence = "\\xc2\\x85\\xe2\\x80\\xa8\\xe2\\x80\\xa9\\xef\\xbb\\xbf" },
        }) |message| {
            inline for (comptime std.meta.tags(start_report.StartError)) |code| {
                for ([_]?usize{ null, 0, 1 }) |refused| {
                    Probe.used = .{ 0, 0 };
                    Probe.attempted = .{ false, false };
                    Probe.refused = refused;
                    const failure: start_report.Failure = .init(code, message.raw);
                    report(io, &failure);
                    try std.testing.expect(Probe.attempted[0] and Probe.attempted[1]);
                    if (refused != 0) try std.testing.expectEqualStrings("{\"rui_start_error\":{\"code\":\"" ++ @tagName(code) ++ "\",\"message\":" ++ message.json ++ "}}\n", Probe.output[0][0..Probe.used[0]]);
                    if (refused != 1) try std.testing.expectEqualStrings("rui: the Host did not start: " ++ message.sentence ++ " [" ++ @tagName(code) ++ "]\n", Probe.output[1][0..Probe.used[1]]);
                }
            }
        }
        try std.testing.expectError(error.SettingsInvalid, hs.apply(settings, gpa, "{\"bad\\n\\u001b\":\"never-print-this-value\"}", .pipe, checkPreset, &admission_failure));
        Probe.used = .{ 0, 0 };
        Probe.attempted = .{ false, false };
        Probe.refused = null;
        report(io, &admission_failure);
        try std.testing.expectEqualStrings("{\"rui_start_error\":{\"code\":\"settings_invalid\",\"message\":\"bad\\n\\u001b: unknown setting\"}}\n", Probe.output[0][0..Probe.used[0]]);
        try std.testing.expectEqualStrings("rui: the Host did not start: bad\\n\\x1b: unknown setting [settings_invalid]\n", Probe.output[1][0..Probe.used[1]]);
    }
}

fn concreteLeaf(gpa: std.mem.Allocator, pattern: []const u8) ![]const u8 {
    return std.mem.replaceOwned(u8, gpa, pattern, "*", "sample");
}

fn expectJsonEqual(expected: std.json.Value, actual: std.json.Value) !void {
    const a = try encoded(std.testing.allocator, expected);
    defer std.testing.allocator.free(a);
    const b = try encoded(std.testing.allocator, actual);
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings(a, b);
}

test "Host start every generated leaf saves shows loads and unsets to defaults" {
    const gpa = std.testing.allocator;
    var environment: std.process.Environ.Map = .init(gpa);
    defer environment.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const init = initForTest(&arena, &environment);
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var private = try tmp.dir.createDirPathOpen(init.io, "host", .{ .permissions = .fromMode(0o700), .open_options = .{ .iterate = true } });
    defer private.close(init.io);
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = root[0..try private.realPath(init.io, &root)];
    const effective = try gpa.create(hs.Settings);
    defer gpa.destroy(effective);
    const expected = try gpa.create(hs.Settings);
    defer gpa.destroy(expected);
    var failure: start_report.Failure = undefined;
    const parsed = try parseForTest(arena.allocator(), &.{});
    for (hs.leaves) |leaf| {
        const path = try concreteLeaf(arena.allocator(), leaf.pattern);
        errdefer std.debug.print("saved Host leaf: {s}; {s}\n", .{ path, failure.message.slice() });
        try savedEdit(init, dir, path, leaf.sample_text, &failure);
        try std.testing.expectEqual(@as(u16, 0o600), (try private.statFile(init.io, "host.json", .{})).permissions.toMode() & 0o777);
        var shown: std.Io.Writer.Allocating = .init(gpa);
        defer shown.deinit();
        try showSaved(init, dir, &shown.writer, &failure);
        const json = try parse(arena.allocator(), shown.written(), &failure);
        expected.* = .{};
        defer expected.deinit();
        try assign(expected, gpa, path, leaf.sample_text, &failure);
        const canonical = try complete(arena.allocator(), expected, &failure);
        try expectJsonEqual(lookup(canonical, path).?, lookup(json, path).?);
        effective.* = .{};
        defer effective.deinit();
        var fixtures: providers.Fixtures = .{};
        try fillAt(init, &parsed, dir, effective, &fixtures, &failure);
        const loaded = try complete(arena.allocator(), effective, &failure);
        try expectJsonEqual(lookup(canonical, path).?, lookup(loaded, path).?);
        try savedEdit(init, dir, path, null, &failure);
        shown.clearRetainingCapacity();
        try showSaved(init, dir, &shown.writer, &failure);
        const restored = try parse(arena.allocator(), shown.written(), &failure);
        const default_value: std.json.Value = if (std.mem.eql(u8, leaf.default, "null") or std.mem.eql(u8, leaf.default, "(Host directory)") or (std.mem.eql(u8, leaf.kind, "url") and leaf.default.len == 0)) .null else if (std.mem.eql(u8, leaf.kind, "count") or std.mem.eql(u8, leaf.kind, "flag")) try parse(arena.allocator(), leaf.default, &failure) else .{ .string = leaf.default };
        try expectJsonEqual(default_value, lookup(restored, path) orelse .null);
        const sparse = try private.readFileAlloc(init.io, "host.json", gpa, .limited(hs.max_document_bytes));
        defer gpa.free(sparse);
        try std.testing.expect(lookup(try parse(arena.allocator(), sparse, &failure), path) == null);
        try private.deleteFile(init.io, "host.json");
    }
    var listed: std.Io.Writer.Allocating = .init(gpa);
    defer listed.deinit();
    try listPaths(&listed.writer);
    for (hs.leaves) |leaf| try std.testing.expect(std.mem.indexOf(u8, listed.written(), leaf.pattern) != null);
}

test "Host start saved input is sparse ordered private and JSON files carry OS paths" {
    const gpa = std.testing.allocator;
    var environment: std.process.Environ.Map = .init(gpa);
    defer environment.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const init = initForTest(&arena, &environment);
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var private = try tmp.dir.createDirPathOpen(init.io, "host", .{ .permissions = .fromMode(0o700), .open_options = .{ .iterate = true } });
    defer private.close(init.io);
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = root[0..try private.realPath(init.io, &root)];
    var failure: start_report.Failure = undefined;
    try savedEdit(init, dir, "tools.bash.timeoutMs", "17", &failure);
    try private.writeFile(init.io, .{ .sub_path = "input.json", .data = "{\"hex\":\"2f746d702fff\"}" });
    const at_file = try std.fmt.allocPrint(arena.allocator(), "@{s}/input.json", .{dir});
    try savedEdit(init, dir, "tools.bash.path", at_file, &failure);
    const settings = try gpa.create(hs.Settings);
    defer gpa.destroy(settings);
    settings.* = .{};
    defer settings.deinit();
    const document = try std.fmt.allocPrint(arena.allocator(), "{s}/override.json", .{dir});
    try private.writeFile(init.io, .{ .sub_path = "override.json", .data = "{\"tools\":{\"bash\":{\"timeoutMs\":18}}}" });
    try private.setFilePermissions(init.io, "override.json", .fromMode(0o600), .{});
    const parsed = try parseForTest(arena.allocator(), &.{ "--settings", document, "--set", "tools.bash.timeoutMs=19", "--set", "tools.bash.timeoutMs=20" });
    var fixtures: providers.Fixtures = .{};
    try fillAt(init, &parsed, dir, settings, &fixtures, &failure);
    try std.testing.expectEqual(@as(u64, 20), settings.tools.bash.timeout_ms.value);
    try std.testing.expectEqualStrings("/tmp/\xff", settings.tools.bash.path.slice());
    try savedEdit(init, dir, "tools.bash.path", "{raw-path", &failure);
    try private.writeFile(init.io, .{ .sub_path = "input.json", .data = "\"{json-path\"" });
    try savedEdit(init, dir, "tools.bash.path", at_file, &failure);
    var shown: std.Io.Writer.Allocating = .init(gpa);
    defer shown.deinit();
    try showSaved(init, dir, &shown.writer, &failure);
    const json = try parse(arena.allocator(), shown.written(), &failure);
    try std.testing.expectEqualStrings("{json-path", lookup(json, "tools.bash.path").?.string);
    try std.testing.expectError(error.SettingsInvalid, savedEdit(init, dir, "tools.bash.timoutMs", "22", &failure));
    try std.testing.expect(std.mem.indexOf(u8, failure.message.slice(), "tools.bash.timeoutMs") != null);
    try std.testing.expectError(error.SettingsInvalid, savedEdit(init, dir, "providers.openai.key", "{\"value\":\"never-print-secret\"}", &failure));
    try std.testing.expect(std.mem.indexOf(u8, failure.message.slice(), "never-print-secret") == null);
    try private.writeFile(init.io, .{ .sub_path = "input.json", .data = "{\"hex\":\"00\"}" });
    try std.testing.expectError(error.SettingsInvalid, savedEdit(init, dir, "tools.bash.path", at_file, &failure));
    try private.writeFile(init.io, .{ .sub_path = "input.json", .data = "not-json-never-print-secret" });
    try std.testing.expectError(error.SettingsInvalid, savedEdit(init, dir, "tools.bash.path", at_file, &failure));
    try std.testing.expect(std.mem.indexOf(u8, failure.message.slice(), "never-print-secret") == null);
    try private.setFilePermissions(init.io, "host.json", .fromMode(0o644), .{});
    try std.testing.expectError(error.SettingsInvalid, showSaved(init, dir, &shown.writer, &failure));
}

test "Host start explicit providers replace automatic defaults and MySQL keeps its Adapter" {
    const gpa = std.testing.allocator;
    var environment: std.process.Environ.Map = .init(gpa);
    defer environment.deinit();
    try environment.put("HOME", "/nonexistent-host-start-test-home");
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const init = initForTest(&arena, &environment);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var private = try tmp.dir.createDirPathOpen(init.io, "host", .{ .permissions = .fromMode(0o700) });
    defer private.close(init.io);
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = root[0..try private.realPath(init.io, &root)];
    const settings = try gpa.create(hs.Settings);
    defer gpa.destroy(settings);
    var failure: start_report.Failure = undefined;
    for ([_][]const []const u8{ &.{}, &.{ "--set", "providers={}" }, &.{ "--set", "providers.openai.unauthenticated=true" }, &.{ "--set", "providers.codex={}", "--set", "providers.openai={}" } }, 0..) |args, index| {
        settings.* = .{};
        defer settings.deinit();
        const parsed = try parseForTest(arena.allocator(), args);
        var fixtures: providers.Fixtures = .{};
        try fillAt(init, &parsed, dir, settings, &fixtures, &failure);
        inline for (std.enums.values(protocol.Provider)) |provider| {
            const served = @field(settings.providers.entries, @tagName(provider)) != null;
            const wanted = switch (index) {
                0 => provider == .codex,
                1 => false,
                2 => provider == .openai,
                else => provider == .codex or provider == .openai,
            };
            try std.testing.expectEqual(wanted, served);
        }
    }
    try environment.put(providers.openai_base_url_variable, "https://example.test/custom/v1/");
    for ([_][]const u8{ "providers.openai={}", "providers.openai.endpoint=https://named.test/responses" }, [_][]const u8{ "https://example.test/custom/v1/responses", "https://named.test/responses" }) |assignment, endpoint| {
        settings.* = .{};
        defer settings.deinit();
        const parsed = try parseForTest(arena.allocator(), &.{ "--set", assignment });
        var fixtures: providers.Fixtures = .{};
        try fillAt(init, &parsed, dir, settings, &fixtures, &failure);
        try std.testing.expectEqualStrings(endpoint, settings.providers.entries.openai.?.endpoint.?.slice());
    }
    _ = environment.swapRemove(providers.openai_base_url_variable);
    settings.* = .{};
    defer settings.deinit();
    const parsed = try parseForTest(arena.allocator(), &.{ "--store", dir, "--set", "store.mysql.url=env:MYSQL_TEST_URL" });
    var fixtures: providers.Fixtures = .{};
    try fillAt(init, &parsed, dir, settings, &fixtures, &failure);
    try std.testing.expectEqual(start_report.Store.mysql, storeKind(settings));
    try anchorPlacement(init, settings, dir, &failure);
    var runtime: [platform.max_socket_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(try platform.defaultMysqlInterface(dir, &runtime), settings.interface.dir.slice());
    try selectStore(init, settings, dir, false, &failure);
    try std.testing.expectEqual(start_report.Store.mysql, storeKind(settings));
}

test "Host start reads a previous release's retired flags as the settings those flags filled" {
    const serve_grammar = @import("serve_grammar.zig");
    const gpa = std.testing.allocator;
    var environment: std.process.Environ.Map = .init(gpa);
    defer environment.deinit();
    try environment.put("HOME", "/nonexistent-host-start-test-home");
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const init = initForTest(&arena, &environment);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try testHostDir(&tmp, &root);
    var failure: start_report.Failure = undefined;
    const Case = struct { args: []const []const u8, expected: []const u8 };
    for ([_]Case{
        .{ .args = &.{ "--active-capacity", "7" }, .expected = "{\"providers\":{},\"execution\":{\"activeCapacity\":7}}" },
        .{ .args = &.{ "--provider", "codex" }, .expected = "{\"providers\":{\"codex\":{}}}" },
        .{ .args = &.{ "--provider", "codex", "--provider", "chatgpt", "--provider", "openai" }, .expected = "{\"providers\":{\"codex\":{},\"chatgpt\":{},\"openai\":{}}}" },
        .{ .args = &.{ "--provider-endpoint", "http://127.0.0.1:9/responses" }, .expected = "{\"providers\":{\"codex\":{\"endpoint\":\"http://127.0.0.1:9/responses\",\"unauthenticated\":true}}}" },
        .{ .args = &.{ "--provider-ca-file", "/private/ca.pem" }, .expected = "{\"providers\":{},\"network\":{\"caFile\":\"/private/ca.pem\"}}" },
        .{ .args = &.{ "--bash-path", "/bin/bash" }, .expected = "{\"providers\":{},\"tools\":{\"bash\":{\"path\":\"/bin/bash\"}}}" },
        .{ .args = &.{ "--bash-timeout-ms", "1500" }, .expected = "{\"providers\":{},\"tools\":{\"bash\":{\"timeoutMs\":1500}}}" },
        .{ .args = &.{ "--store", dir, "--provider", "codex", "--provider", "openai", "--active-capacity", "4" }, .expected = "{\"providers\":{\"codex\":{},\"openai\":{}},\"execution\":{\"activeCapacity\":4}}" },
        .{
            .args = &.{ "--store", dir, "--active-capacity", "3", "--provider-endpoint", "http://127.0.0.1:9/responses", "--provider-ca-file", "/private/ca.pem", "--bash-path", "/bin/bash", "--bash-timeout-ms", "1500" },
            .expected = "{\"providers\":{\"codex\":{\"endpoint\":\"http://127.0.0.1:9/responses\",\"unauthenticated\":true}},\"execution\":{\"activeCapacity\":3},\"network\":{\"caFile\":\"/private/ca.pem\"},\"tools\":{\"bash\":{\"path\":\"/bin/bash\",\"timeoutMs\":1500}}}",
        },
    }) |case| {
        const replayed = try gpa.create(hs.Settings);
        defer gpa.destroy(replayed);
        replayed.* = .{};
        defer replayed.deinit();
        // Restart source finishing prefixes the previous release's provider set.
        const translated = try serve_grammar.currentArguments(arena.allocator(), case.args);
        const replayed_args = try std.mem.concat(arena.allocator(), []const u8, &.{ &.{ "--set", serve_grammar.previousProviders(false, false).? }, translated });
        const parsed = try parseForTest(arena.allocator(), replayed_args);
        var fixtures: providers.Fixtures = .{};
        try fillAt(init, &parsed, dir, replayed, &fixtures, &failure);
        const expected = try gpa.create(hs.Settings);
        defer gpa.destroy(expected);
        expected.* = .{};
        defer expected.deinit();
        try hs.apply(expected, gpa, case.expected, .file, checkPreset, &failure);
        try expectJsonEqual(try complete(arena.allocator(), expected, &failure), try complete(arena.allocator(), replayed, &failure));
    }
    const current: []const []const u8 = &.{ "--store", dir, "--set", "providers.codex={}" };
    try std.testing.expectEqual(current.ptr, (try serve_grammar.currentArguments(arena.allocator(), current)).ptr);
    try std.testing.expectError(error.InvalidArguments, serve_grammar.currentArguments(arena.allocator(), &.{ "--store", dir, "--provider" }));
}

test "Host start refused JSON input allocations erase secret bytes before release" {
    const Observer = struct {
        child: std.mem.Allocator,
        stale: bool = false,
        frees: usize = 0,
        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
        }
        fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.child.rawAlloc(len, alignment, ret);
        }
        fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.stale = self.stale or std.mem.indexOf(u8, bytes, "never-release-secret") != null;
            self.frees += 1;
            self.child.rawFree(bytes, alignment, ret);
        }
    };
    const gpa = std.testing.allocator;
    var environment: std.process.Environ.Map = .init(gpa);
    defer environment.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var observer: Observer = .{ .child = gpa };
    var init = initForTest(&arena, &environment);
    init.gpa = observer.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var private = try tmp.dir.createDirPathOpen(init.io, "host", .{ .permissions = .fromMode(0o700) });
    defer private.close(init.io);
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = root[0..try private.realPath(init.io, &root)];
    try private.writeFile(init.io, .{ .sub_path = "value.json", .data = "{\"value\":\"never-release-secret\"}" });
    const value = try std.fmt.allocPrint(arena.allocator(), "@{s}/value.json", .{dir});
    var failure: start_report.Failure = undefined;
    try std.testing.expectError(error.SettingsInvalid, savedEdit(init, dir, "providers.openai.key", value, &failure));
    try std.testing.expect(observer.frees > 0);
    try std.testing.expect(!observer.stale);
}

pub fn capacityAssignment(value: usize, buffer: []u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, hs.path("execution.activeCapacity") ++ "={d}", .{value});
}

test "Host start unset retains exact provider sets and selected Store arms" {
    const gpa = std.testing.allocator;
    var environment: std.process.Environ.Map = .init(gpa);
    defer environment.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const init = initForTest(&arena, &environment);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var private = try tmp.dir.createDirPathOpen(init.io, "host", .{ .permissions = .fromMode(0o700) });
    defer private.close(init.io);
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = root[0..try private.realPath(init.io, &root)];
    var failure: start_report.Failure = undefined;
    try savedEdit(init, dir, "providers.openai.endpoint", "https://example.test/responses", &failure);
    try savedEdit(init, dir, "providers.openai.endpoint", null, &failure);
    var shown: std.Io.Writer.Allocating = .init(gpa);
    defer shown.deinit();
    try showSaved(init, dir, &shown.writer, &failure);
    var json = try parse(arena.allocator(), shown.written(), &failure);
    try std.testing.expect(lookup(json, "providers.openai") != null);
    try std.testing.expect(lookup(json, "providers.codex") == null);
    try savedEdit(init, dir, "providers.openai", null, &failure);
    shown.clearRetainingCapacity();
    try showSaved(init, dir, &shown.writer, &failure);
    json = try parse(arena.allocator(), shown.written(), &failure);
    try std.testing.expect(lookup(json, "providers") != null);
    inline for (std.enums.values(protocol.Provider)) |provider| try std.testing.expect(lookup(json, "providers." ++ @tagName(provider)) == null);
    try savedEdit(init, dir, "store.mysql.url", "env:MYSQL_TEST_URL", &failure);
    try savedEdit(init, dir, "store.mysql.url", null, &failure);
    shown.clearRetainingCapacity();
    try showSaved(init, dir, &shown.writer, &failure);
    json = try parse(arena.allocator(), shown.written(), &failure);
    try std.testing.expect(lookup(json, "store.mysql") != null);
    try std.testing.expect(lookup(json, "store.sqlite") == null);
}

const HostLaunchResult = @import("host_launch.zig").Result;
extern "c" fn rui_launch_detached_reported(executable: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, argc: usize, settings_read: c_int, startup_read: *c_int, report_read: *c_int, launched_pid: *c_int, launched_started: *c_ulonglong) c_int;
pub const Progress = struct { context: *anyopaque, report: *const fn (*anyopaque, []const u8) void };
pub const Spawn = struct { dir: []const u8, settings_file: ?[]const u8 = null, assignments: []const []const u8 = &.{}, frozen: ?[]const u8 = null };

/// Finish a running Host's semantic sources, not a child launch plan. Older
/// releases had flag-fill provider policy; prefix that baseline BEFORE explicit
/// providers, and keep observed runtime capacity authoritative LAST. The caller
/// owns a wiping arena and has authenticated the running release identity.
pub fn restartSources(init: std.process.Init, allocator: std.mem.Allocator, sources: Spawn, previous_release: bool, active_capacity: usize) !Spawn {
    const baseline = if (previous_release) base: {
        const names = if (sources.settings_file) |file| names: {
            // Never consume stdin or open a cwd-dependent source during upgrade.
            // The target's check supplies its typed detached refusal instead.
            if (!std.fs.path.isAbsolute(file)) break :names false;
            break :names try documentNamesProviders(init, file);
        } else false;
        break :base @import("serve_grammar.zig").previousProviders(sources.settings_file != null, names);
    } else null;
    const assignments = try allocator.alloc([]const u8, sources.assignments.len + 1 + @intFromBool(baseline != null));
    var offset: usize = 0;
    if (baseline) |value| {
        assignments[0] = value;
        offset = 1;
    }
    @memcpy(assignments[offset..][0..sources.assignments.len], sources.assignments);
    var buffer: [128]u8 = undefined;
    assignments[assignments.len - 1] = try allocator.dupe(u8, try capacityAssignment(active_capacity, &buffer));
    return .{ .dir = sources.dir, .settings_file = sources.settings_file, .assignments = assignments };
}

pub const Ops = struct {
    context: ?*anyopaque = null,
    observe: *const fn (?*anyopaque, std.Io, *const platform.Paths, ?i128) @import("protocol_reply.zig").HostStatus = nativeObserve,
    launch: *const fn (?*anyopaque, [*:0]const u8, [*:null]const ?[*:0]const u8, usize, c_int, *c_int, *c_int, *c_int, *c_ulonglong) c_int = nativeLaunch,
    verify: *const fn (?*anyopaque, std.Io, *const platform.Paths, c_int, u64, []const u8, ?i128, *@import("protocol_reply.zig").HostInfoFacts) bool = nativeVerify,
    read: *const fn (?*anyopaque, c_int, []u8) isize = nativeRead,
    now: *const fn (?*anyopaque, std.Io) i96 = nativeNow,
    pause: *const fn (?*anyopaque, std.Io, u64) anyerror!void = nativePause,

    fn nativeObserve(_: ?*anyopaque, io: std.Io, paths: *const platform.Paths, until: ?i128) @import("protocol_reply.zig").HostStatus {
        return @import("client.zig").hostStatusAt(io, paths, until);
    }
    fn nativeLaunch(_: ?*anyopaque, executable: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, argc: usize, settings_read: c_int, startup_read: *c_int, report_read: *c_int, pid: *c_int, started: *c_ulonglong) c_int {
        return rui_launch_detached_reported(executable, argv, argc, settings_read, startup_read, report_read, pid, started);
    }
    fn nativeVerify(_: ?*anyopaque, io: std.Io, paths: *const platform.Paths, pid: c_int, started: u64, executable: []const u8, until: ?i128, facts: *@import("protocol_reply.zig").HostInfoFacts) bool {
        if (pid <= 0 or started == 0) return false;
        const observed = @import("client.zig").observeHostProcessAt(io, paths, until) catch return false;
        if (observed.pid != pid) return false;
        const identity = @import("host_identity.zig");
        var snapshot = identity.snapshot(std.heap.c_allocator, observed.pid) catch return false;
        defer snapshot.deinit(std.heap.c_allocator);
        if (!identity.matchesLaunch(pid, started, &snapshot, executable)) return false;
        facts.* = observed.ready;
        return true;
    }
    fn nativeRead(_: ?*anyopaque, fd: c_int, bytes: []u8) isize {
        return transfer.Ops.nativeRead(null, fd, bytes);
    }
    fn nativeNow(_: ?*anyopaque, io: std.Io) i96 {
        return std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    }
    fn nativePause(_: ?*anyopaque, io: std.Io, ns: u64) !void {
        try std.Io.sleep(io, .fromNanoseconds(ns), .awake);
    }
};

pub fn launchFailure(result: *HostLaunchResult, kind: HostLaunchResult.Cause.Kind, err: anyerror, store: ?[]const u8) void {
    result.outcome = .{ .failed = .{ .cause = .{ .kind = kind, .err = err }, .store = .{ .len = 0 } } };
    if (store) |canonical| result.outcome.failed.store.set(canonical) catch unreachable;
}

pub fn launchReady(result: *HostLaunchResult, ready: @import("protocol_reply.zig").HostInfoFacts, paths: *const platform.Paths, adopted: bool) void {
    result.outcome = .{ .ready = .{ .facts = ready, .selector = .{ .len = 0 }, .diagnostics_directory = .{ .len = 0 }, .adopted = adopted } };
    result.outcome.ready.selector.set(paths.selector()) catch unreachable;
    result.outcome.ready.diagnostics_directory.set(paths.diagnosticsDirectory()) catch unreachable;
}

pub const ProviderIntent = launch_frame.ProviderIntent;

pub fn readSources(init: std.process.Init, request: Spawn, settings: *hs.Settings, failure: *start_report.Failure) !ProviderIntent {
    var wiping: secret_value.WipingAllocator = .{ .backing = init.gpa };
    var memory: std.heap.ArenaAllocator = .init(wiping.allocator());
    defer memory.deinit();
    const document = try saved(init, memory.allocator(), request.dir, settings, failure);
    var intent: ProviderIntent = if (document == .object and document.object.contains("providers")) .explicit else .automatic;
    if (request.settings_file) |file| {
        if (try readDocumentAt(init, file, settings, failure)) intent = .explicit;
    }
    for (request.assignments) |assignment| {
        const equals = std.mem.indexOfScalar(u8, assignment, '=') orelse return invalid(failure, "settings", "--set requires PATH=VALUE");
        const path = assignment[0..equals];
        const selects_providers = std.mem.eql(u8, path, "providers") or std.mem.startsWith(u8, path, "providers.");
        if (selects_providers and intent == .automatic) try assign(settings, init.gpa, "providers", "{}", failure);
        try input(init, settings, path, assignment[equals + 1 ..], failure);
        if (selects_providers) intent = .explicit;
    }
    return intent;
}

pub fn finishSources(init: std.process.Init, settings: *hs.Settings, intent: ProviderIntent, failure: *start_report.Failure) !void {
    switch (intent) {
        .automatic => try defaultProviders(init, settings, failure),
        .explicit => try explicitBaseUrl(init, settings, failure),
    }
}

pub const Cwd = struct {
    io: std.Io,
    path: ?[]const u8 = null,
    buffer: [std.Io.Dir.max_path_bytes]u8 = undefined,

    fn get(self: *Cwd) ?[]const u8 {
        if (self.path == null) self.path = self.buffer[0 .. std.Io.Dir.cwd().realPath(self.io, &self.buffer) catch return null];
        return self.path;
    }
};

pub fn anchorTyped(gpa: std.mem.Allocator, cwd: *Cwd, request: Spawn, failure: *start_report.Failure) !Spawn {
    var anchored = request;
    if (request.settings_file) |file| {
        if (!std.mem.eql(u8, file, "-") and !std.fs.path.isAbsolute(file)) anchored.settings_file = try std.fs.path.join(gpa, &.{ try cwdBase(cwd, "settings", failure), file });
    }
    const assignments = try gpa.alloc([]const u8, request.assignments.len);
    for (request.assignments, assignments) |assignment, *out| out.* = try anchorAssignment(gpa, cwd, assignment, failure);
    anchored.assignments = assignments;
    return anchored;
}

fn cwdBase(cwd: *Cwd, leaf: []const u8, failure: *start_report.Failure) error{SettingsInvalid}![]const u8 {
    if (cwd.get()) |path| return path;
    var buffer: [start_report.max_refusal_message_bytes]u8 = undefined;
    const reason = "the current directory no longer exists, so a relative path has no base; give an absolute path";
    failure.* = .init(.settings_invalid, std.fmt.bufPrint(&buffer, "{s}: {s}", .{ leaf, reason }) catch "settings: " ++ reason);
    return error.SettingsInvalid;
}

fn anchorAssignment(gpa: std.mem.Allocator, cwd: *Cwd, assignment: []const u8, failure: *start_report.Failure) ![]const u8 {
    const equals = std.mem.indexOfScalar(u8, assignment, '=') orelse return assignment;
    const path = assignment[0..equals];
    const value = assignment[equals + 1 ..];
    if (std.mem.startsWith(u8, value, "@")) {
        if (value.len == 1 or std.fs.path.isAbsolute(value[1..])) return assignment;
        return std.fmt.allocPrint(gpa, "{s}=@{s}", .{ path, try std.fs.path.join(gpa, &.{ try cwdBase(cwd, path, failure), value[1..] }) });
    }
    for (hs.leaves) |leaf| if (matches(leaf.pattern, path)) {
        if (std.mem.eql(u8, leaf.kind, "path") and value.len != 0 and !std.fs.path.isAbsolute(value))
            return std.fmt.allocPrint(gpa, "{s}={s}", .{ path, try std.fs.path.join(gpa, &.{ try cwdBase(cwd, path, failure), value }) });
        if (leaf.secret and std.mem.startsWith(u8, value, "file:") and value.len > "file:".len and !std.fs.path.isAbsolute(value["file:".len..]))
            return std.fmt.allocPrint(gpa, "{s}=file:{s}", .{ path, try std.fs.path.join(gpa, &.{ try cwdBase(cwd, path, failure), value["file:".len..] }) });
        break;
    };
    return assignment;
}

/// Read every layer a detached launch applies and refuse what cannot run in
/// `/` without stdin: a stdin or relative --settings, a relative @FILE, any
/// relative path or `file:` source in any layer, and the stdin lifetime. The
/// Host directory itself is the anchored default, never relative.
fn readDetached(init: std.process.Init, request: Spawn, settings: *hs.Settings, failure: *start_report.Failure) !ProviderIntent {
    if (request.settings_file) |file| {
        if (std.mem.eql(u8, file, "-")) return invalid(failure, "settings", "a Host started by bare rui or rui host start has no stdin; pass a document on stdin with rui host serve --settings -");
        if (!std.fs.path.isAbsolute(file)) return invalid(failure, "settings", relative);
    }
    for (request.assignments) |assignment| {
        const equals = std.mem.indexOfScalar(u8, assignment, '=') orelse return invalid(failure, "settings", "--set requires PATH=VALUE");
        const value = assignment[equals + 1 ..];
        if (std.mem.startsWith(u8, value, "@") and !std.fs.path.isAbsolute(value[1..])) return invalid(failure, "settings", "@FILE " ++ relative);
    }
    const intent = try readSources(init, request, settings, failure);
    try detachedValue(settings, failure);
    return intent;
}

fn detachedValue(settings: *const hs.Settings, failure: *start_report.Failure) !void {
    if (settings.interface.lifetime.value == .stdin) return invalid(failure, "interface.lifetime", "a Host started by bare rui or rui host start has no stdin; use detached, or run rui host serve");
    var name: LeafName = .{};
    if (relativeLeaf(hs.Settings, settings, &name)) {
        var buffer: [start_report.max_refusal_message_bytes]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, "{s}: {s}", .{ name.slice(), relative }) catch "settings: " ++ relative;
        failure.* = .init(.settings_invalid, message);
        return error.SettingsInvalid;
    }
    return;
}

const relative = "a Host started in / has no base for a relative path; give an absolute path";

const LeafName = struct {
    bytes: [256]u8 = undefined,
    len: usize = 0,
    fn push(self: *LeafName, part: []const u8) void {
        const dot: usize = if (self.len == 0) 0 else 1;
        if (self.len + dot + part.len > self.bytes.len) return;
        if (dot == 1) self.bytes[self.len] = '.';
        @memcpy(self.bytes[self.len + dot ..][0..part.len], part);
        self.len += dot + part.len;
    }
    fn slice(self: *const LeafName) []const u8 {
        return self.bytes[0..self.len];
    }
};

fn relativeLeaf(comptime T: type, value: *const T, name: *LeafName) bool {
    const at = name.len;
    if (relativeBelow(T, value, name)) return true;
    name.len = at;
    return false;
}

fn relativeBelow(comptime T: type, value: *const T, name: *LeafName) bool {
    if (@typeInfo(T) == .optional) {
        return if (value.*) |*present| relativeLeaf(@typeInfo(T).optional.child, present, name) else false;
    }
    const at = name.len;
    if (@hasDecl(T, "kind")) {
        return switch (T.kind) {
            .path => !(value.anchored or (value.slice().len == 0 and T.allow_empty) or std.fs.path.isAbsolute(value.slice())),
            .secret => switch (value.source) {
                .file => |*file| relativeLeaf(@TypeOf(file.*), file, name),
                else => false,
            },
            .named => for (value.names[0..value.len], value.values[0..value.len]) |*entry_name, *entry| {
                name.len = at;
                name.push(entry_name.slice());
                if (relativeLeaf(T.Child, entry, name)) break true;
            } else false,
            .providers => relativeLeaf(T.Table, &value.entries, name),
            else => false,
        };
    }
    switch (@typeInfo(T)) {
        .@"struct" => |info| inline for (info.field_names, info.field_types) |field, Field| {
            name.len = at;
            name.push(comptime hs.camel(field));
            if (relativeLeaf(Field, &@field(value, field), name)) return true;
        },
        .@"union" => switch (value.*) {
            inline else => |*payload, tag| {
                name.push(comptime hs.camel(@tagName(tag)));
                return relativeLeaf(@TypeOf(payload.*), payload, name);
            },
        },
        else => @compileError("not a Host settings kind"),
    }
    return false;
}

/// Admission before any effect: detached-safe sources and saved placement.
/// Non-placement overrides are replayable; placement must also be visible to
/// a later client given only the Host directory.
pub fn checkStart(init: std.process.Init, request: Spawn, failure: *start_report.Failure) !void {
    const settings = try init.gpa.create(hs.Settings);
    defer init.gpa.destroy(settings);
    settings.* = .{};
    defer settings.deinit();
    _ = try readStart(init, request, settings, failure);
}

/// Retain this caller-owned unresolved allocation through route selection and
/// freezing. Full --check may resolve it only AFTER the source-only frame exists.
pub fn freezeStart(init: std.process.Init, request: Spawn, settings: *hs.Settings, failure: *start_report.Failure) !launch_frame.Owned {
    const intent = try readStart(init, request, settings, failure);
    var canonical: [protocol.max_store_bytes]u8 = undefined;
    const directory = try platform.canonicalStoreDestination(init.io, request.dir, &canonical);
    return launch_frame.freeze(init.gpa, directory, settings, intent, failure);
}

pub fn decodeStart(init: std.process.Init, bytes: []const u8, selected: []const u8, settings: *hs.Settings, failure: *start_report.Failure) !ProviderIntent {
    var canonical: [protocol.max_store_bytes]u8 = undefined;
    const directory = try platform.canonicalStoreDestination(init.io, selected, &canonical);
    const intent = try launch_frame.decode(bytes, directory, settings, init.gpa, checkPreset, failure);
    try detachedValue(settings, failure);
    try anchorPlacement(init, settings, directory, failure);
    return intent;
}

pub fn finishDetached(init: std.process.Init, settings: *hs.Settings, intent: ProviderIntent, fixtures: providers.Fixtures, failure: *start_report.Failure) !void {
    try finishSources(init, settings, intent, failure);
    try resolveProviders(init, settings, fixtures, failure);
}

/// One detached source/placement owner for spawn and settings --check. Keep
/// provider finishing/resolution out of this read-only phase: attachment and
/// saved connection editing do not eagerly need another provider's login.
fn readStart(init: std.process.Init, request: Spawn, settings: *hs.Settings, failure: *start_report.Failure) !ProviderIntent {
    const intent = try readDetached(init, request, settings, failure);
    try anchorPlacement(init, settings, request.dir, failure);
    // Only overridden sources need a comparison with the saved placement.
    if (request.settings_file == null and request.assignments.len == 0) return intent;
    // Only saved placement is discoverable by subsequent directory clients.
    const saved_settings = try init.gpa.create(hs.Settings);
    defer init.gpa.destroy(saved_settings);
    saved_settings.* = .{};
    defer saved_settings.deinit();
    _ = try readSources(init, .{ .dir = request.dir }, saved_settings, failure);
    try anchorPlacement(init, saved_settings, request.dir, failure);
    var wiping: secret_value.WipingAllocator = .{ .backing = init.gpa };
    var comparison: std.heap.ArenaAllocator = .init(wiping.allocator());
    defer comparison.deinit();
    const current = try complete(comparison.allocator(), settings, failure);
    const persisted = try complete(comparison.allocator(), saved_settings, failure);
    for ([_][]const u8{ "store", "interface.dir" }) |path| {
        const a = try encoded(comparison.allocator(), lookup(current, path).?);
        const b = try encoded(comparison.allocator(), lookup(persisted, path).?);
        if (!std.mem.eql(u8, a, b)) {
            failure.* = .init(.settings_invalid, "unsaved Store or interface placement cannot be found by later clients; save it with rui host set --store DIR, then retry");
            return error.SettingsInvalid;
        }
    }
    return intent;
}

pub noinline fn spawn(init: std.process.Init, typed: Spawn, ops: Ops, progress: ?Progress, result: *HostLaunchResult) void {
    const selected = typed.dir;
    const io = init.io;
    const settings = init.gpa.create(hs.Settings) catch |err| return launchFailure(result, .setup, err, null);
    defer init.gpa.destroy(settings);
    settings.* = .{};
    defer settings.deinit();
    var reach_failure: start_report.Failure = .init(.settings_invalid, "settings: could not be read");
    if (typed.frozen) |bytes| {
        _ = decodeStart(init, bytes, selected, settings, &reach_failure) catch |err| {
            launchFailure(result, .child_refused, err, null);
            result.outcome.failed.refusal = reach_failure;
            result.outcome.failed.cause.refusal_code = reach_failure.code;
            return;
        };
    }
    const selection = platform.resolveClientSelection(selected);
    var resolved: ?platform.Paths = (if (typed.frozen != null) platform.placementPaths(io, settings) else if (selection == .mysql) selection.paths(io) else existingPlacement(io, selected)) catch |err| switch (err) {
        error.FileNotFound, error.SettingsInvalid => null,
        else => return launchFailure(result, .store_access, error.StoreAccessFailed, null),
    };
    if (typed.frozen) |bytes| if (resolved) |*paths| paths.host_directory.set((launch_frame.inspect(bytes) catch unreachable).directory) catch unreachable;
    switch (if (resolved) |*paths| ops.observe(ops.context, io, paths, null) else @as(@import("protocol_reply.zig").HostStatus, .unavailable)) {
        .ready => |ready| return launchReady(result, ready, &resolved.?, true),
        .incompatible => return launchFailure(result, .incompatible, error.IncompatibleHost, null),
        .access_failure => return launchFailure(result, .store_access, error.StoreAccessFailed, null),
        .unavailable, .owned_unavailable => {},
    }
    if (selection == .mysql) return launchFailure(result, .mysql_unavailable, error.MysqlHostUnavailable, null);
    var wiping: secret_value.WipingAllocator = .{ .backing = std.heap.c_allocator };
    var anchoring: std.heap.ArenaAllocator = .init(wiping.allocator());
    defer anchoring.deinit();
    var cwd: Cwd = .{ .io = io };
    var frozen: ?launch_frame.Owned = null;
    defer if (frozen) |*owned_frame| owned_frame.deinit(init.gpa);
    const admitted: anyerror!Spawn = admit: {
        const anchored = anchorTyped(anchoring.allocator(), &cwd, typed, &reach_failure) catch |err| break :admit err;
        if (typed.frozen == null) frozen = freezeStart(init, anchored, settings, &reach_failure) catch |err| break :admit err;
        break :admit anchored;
    };
    const request = admitted catch |err| {
        var canonical: [protocol.max_store_bytes]u8 = undefined;
        launchFailure(result, .child_refused, if (err == error.SettingsInvalid) error.HostStartupFailed else err, platform.canonicalStoreDestination(io, selected, &canonical) catch null);
        result.outcome.failed.refusal = reach_failure;
        result.outcome.failed.cause.refusal_code = reach_failure.code;
        return;
    };
    const frame_bytes = typed.frozen orelse frozen.?.bytes;
    const admitted_directory = (launch_frame.inspect(frame_bytes) catch unreachable).directory;
    // Placement and the selected directory come from the same retained intake,
    // before creating a directory or publishing a child. Never select again
    // from saved sources (or the original directory alias) after freezing.
    var paths = platform.placementPaths(io, settings) catch |err| return launchFailure(result, .store_access, err, null);
    paths.host_directory.set(admitted_directory) catch unreachable;
    @import("upgrade_process.zig").waitForTestGate(init.gpa, io, init.environ_map.get("RUI_TEST_HOST_AFTER_FREEZE_GATE"), null, .fromSeconds(300)) catch |err| return launchFailure(result, .interrupted, err, null);
    var dir = std.Io.Dir.cwd().createDirPathOpen(io, admitted_directory, .{ .permissions = .fromMode(0o700) }) catch |err| return launchFailure(result, .setup, err, null);
    dir.close(io);
    var executable_buffer: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
    const length = std.process.executablePath(io, &executable_buffer) catch |err| return launchFailure(result, .setup, err, paths.selector());
    if (length == executable_buffer.len) return launchFailure(result, .setup, error.ExecutablePathTooLong, paths.selector());
    executable_buffer[length] = 0;
    const gpa = std.heap.c_allocator;
    const first: usize = if (request.settings_file == null) 5 else 7;
    const provenance_argc = first + 2 * request.assignments.len;
    const argc = provenance_argc + 2;
    const argv = gpa.allocSentinel(?[*:0]const u8, argc, null) catch |err| return launchFailure(result, .setup, err, paths.selector());
    defer gpa.free(argv);
    argv[0] = @ptrCast(&executable_buffer);
    argv[1] = "host";
    argv[2] = "serve";
    argv[3] = "--store";
    const directory = gpa.dupeSentinel(u8, admitted_directory, 0) catch |err| return launchFailure(result, .setup, err, paths.selector());
    defer gpa.free(directory);
    argv[4] = directory.ptr;
    const settings_file = if (request.settings_file) |file| gpa.dupeSentinel(u8, file, 0) catch |err| return launchFailure(result, .setup, err, paths.selector()) else null;
    defer if (settings_file) |file| gpa.free(file);
    if (settings_file) |file| {
        argv[5] = "--settings";
        argv[6] = file.ptr;
    }
    var owned: usize = 0;
    defer for (0..owned) |index| {
        const value = std.mem.span(argv[first + 1 + index * 2].?);
        std.crypto.secureZero(u8, @constCast(value));
        gpa.free(value[0..value.len :0]);
    };
    for (request.assignments, 0..) |assignment, index| {
        argv[first + index * 2] = "--set";
        const value = gpa.dupeSentinel(u8, assignment, 0) catch |err| return launchFailure(result, .setup, err, paths.selector());
        argv[first + 1 + index * 2] = value.ptr;
        owned += 1;
    }
    argv[provenance_argc] = "--" ++ launch_frame.input_option;
    argv[provenance_argc + 1] = "5";
    var input_pipe = transfer.Pipe.init() catch |err| return launchFailure(result, .setup, err, paths.selector());
    defer input_pipe.close();
    var delivery: transfer.Transfer = .{ .input = input_pipe.writer, .bytes = frame_bytes };
    input_pipe.writer = -1;
    defer delivery.deinit();
    var startup_read: c_int = -1;
    var report_read: c_int = -1;
    var launched_pid: c_int = 0;
    var launched_started: c_ulonglong = 0;
    const launched = ops.launch(ops.context, argv[0].?, argv.ptr, argc, input_pipe.reader, &startup_read, &report_read, &launched_pid, &launched_started);
    defer if (report_read >= 0) {
        _ = std.c.close(report_read);
    };
    var report_bytes: [HostLaunchResult.max_startup_bytes]u8 = undefined;
    var report_len: usize = 0;
    var refusal: ?start_report.Failure = null;
    defer if (startup_read >= 0) {
        _ = std.c.close(startup_read);
    };
    if (launched != 0) {
        launchFailure(result, .os_launch, error.HostLaunchFailed, paths.selector());
        result.outcome.failed.os_error = launched;
        return;
    }
    _ = std.c.close(input_pipe.reader);
    input_pipe.reader = -1;
    result.wait = .init(ops.now(ops.context, io));
    while (!result.wait.?.expired(ops.now(ops.context, io))) {
        const moved = delivery.step(.{ .context = ops.context, .read = ops.read }, .{
            .{ .fd = startup_read, .buffer = result.startup_bytes[result.startup_len..] },
            .{ .fd = report_read, .buffer = if (refusal == null) report_bytes[report_len..] else &.{} },
        }) catch |err| return launchFailure(result, .interrupted, err, paths.selector());
        result.startup_len += moved.counts[0];
        report_len += moved.counts[1];
        if (refusal == null and report_len <= report_bytes.len) {
            var lines = std.mem.splitScalar(u8, report_bytes[0..report_len], '\n');
            var offset: usize = 0;
            while (lines.next()) |line_bytes| {
                const end = offset + line_bytes.len + 1;
                if (end > report_len) break;
                if (start_report.parseLine(gpa, report_bytes[offset..end]) catch |err| return launchFailure(result, .setup, err, paths.selector())) |failure| {
                    refusal = failure;
                    break;
                }
                offset = end;
            }
        }
        const startup_closed = moved.closed[0];
        const now = ops.now(ops.context, io);
        result.wait.?.observe(result.startup(), now);
        const until: i128 = result.wait.?.until(now);
        if (progress) |hook| hook.report(hook.context, result.startup());
        if ((refusal != null and refusal.?.code != .store_locked) or startup_closed or result.startup_len == HostLaunchResult.max_startup_bytes or report_len == report_bytes.len) {
            if (ops.observe(ops.context, io, &paths, until) != .ready) {
                if (refusal) |failure| {
                    launchFailure(result, if (failure.code == .store_schema_behind) .store_format else if (failure.code == .store_fenced) .store_identity else .child_refused, if (failure.code == .store_fenced) error.StoreIdentityMismatch else error.HostStartupFailed, paths.selector());
                    result.outcome.failed.refusal = failure;
                    result.outcome.failed.cause.refusal_code = failure.code;
                    return;
                }
                if (result.startup_len == HostLaunchResult.max_startup_bytes or report_len == report_bytes.len) return launchFailure(result, .startup_full, error.HostReadinessUnconfirmed, paths.selector());
                if (std.mem.endsWith(u8, result.startup(), "[store_identity_mismatch]\n")) return launchFailure(result, .store_identity, error.StoreIdentityMismatch, paths.selector());
                if (std.mem.endsWith(u8, result.startup(), "[store_format_unsupported]\n")) return launchFailure(result, .store_format, error.HostStartupFailed, paths.selector());
                return launchFailure(result, if (result.startup_len == 0) .child_closed else .child_refused, error.HostStartupFailed, paths.selector());
            }
        }
        switch (ops.observe(ops.context, io, &paths, until)) {
            .ready => |ready| {
                const final_count = ops.read(ops.context, startup_read, result.startup_bytes[result.startup_len..]);
                if (final_count > 0) result.startup_len += @intCast(final_count);
                result.wait.?.observe(result.startup(), ops.now(ops.context, io));
                const lost = refusal != null and refusal.?.code == .store_locked;
                if (lost) result.startup_len = 0;
                if (std.mem.indexOf(u8, result.startup(), @import("host_launch.zig").invalid_base_url) != null) result.warning = .invalid_openai_base_url;
                var facts = ready;
                const exact = !lost and ops.verify(ops.context, io, &paths, launched_pid, launched_started, executable_buffer[0..length], until, &facts);
                return launchReady(result, facts, &paths, !exact);
            },
            .incompatible => return launchFailure(result, .incompatible, error.IncompatibleHost, paths.selector()),
            .access_failure => return launchFailure(result, .store_access, error.StoreAccessFailed, paths.selector()),
            .unavailable, .owned_unavailable => {},
        }
        const remaining = until - ops.now(ops.context, io);
        if (delivery.input >= 0 and moved.progressed) continue;
        if (remaining > 0) ops.pause(ops.context, io, @intCast(@min(remaining, (if (delivery.input >= 0) @as(i128, 1) else 100) * std.time.ns_per_ms))) catch |err| return launchFailure(result, .interrupted, err, paths.selector());
    }
    return launchFailure(result, .readiness_timeout, error.HostReadinessUnconfirmed, paths.selector());
}

test "Host start source provider intent distinguishes omission empty and exact sets in every layer" {
    const gpa = std.testing.allocator;
    var environment: std.process.Environ.Map = .init(gpa);
    defer environment.deinit();
    try environment.put("HOME", "/nonexistent-host-start-test-home");
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const init = initForTest(&arena, &environment);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const settings = try gpa.create(hs.Settings);
    defer gpa.destroy(settings);
    const Layer = enum { saved, document, set, file };
    const cases = [_]struct { document: []const u8, path: []const u8, value: []const u8, intent: ProviderIntent, before: [3]bool, after: [3]bool }{
        .{ .document = "{}", .path = "execution.paused", .value = "true", .intent = .automatic, .before = .{ true, true, true }, .after = .{ false, true, false } },
        .{ .document = "{\"providers\":{}}", .path = "providers", .value = "{}", .intent = .explicit, .before = .{ false, false, false }, .after = .{ false, false, false } },
        .{ .document = "{\"providers\":{\"openai\":{}}}", .path = "providers", .value = "{\"openai\":{}}", .intent = .explicit, .before = .{ true, false, false }, .after = .{ true, false, false } },
        .{ .document = "{\"providers\":{\"codex\":{},\"chatgpt\":{}}}", .path = "providers", .value = "{\"codex\":{},\"chatgpt\":{}}", .intent = .explicit, .before = .{ false, true, true }, .after = .{ false, true, true } },
    };
    for (cases, 0..) |case, index| for (std.enums.values(Layer)) |layer| {
        settings.* = .{};
        defer settings.deinit();
        var name: [48]u8 = undefined;
        var host = try tmp.dir.createDirPathOpen(init.io, try std.fmt.bufPrint(&name, "host-{d}-{s}", .{ index, @tagName(layer) }), .{ .permissions = .fromMode(0o700) });
        defer host.close(init.io);
        var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const dir = root[0..try host.realPath(init.io, &root)];
        var request: Spawn = .{ .dir = dir };
        switch (layer) {
            .saved, .document => {
                const filename = if (layer == .saved) "host.json" else "document.json";
                try host.writeFile(init.io, .{ .sub_path = filename, .data = case.document });
                try host.setFilePermissions(init.io, filename, .fromMode(0o600), .{});
                if (layer == .document) request.settings_file = try std.fs.path.join(arena.allocator(), &.{ dir, filename });
            },
            .set, .file => {
                const value = if (layer == .set) case.value else value: {
                    try host.writeFile(init.io, .{ .sub_path = "value.json", .data = case.value });
                    break :value try std.fmt.allocPrint(arena.allocator(), "@{s}/value.json", .{dir});
                };
                const assignments = try arena.allocator().alloc([]const u8, 1);
                assignments[0] = try std.fmt.allocPrint(arena.allocator(), "{s}={s}", .{ case.path, value });
                request.assignments = assignments;
            },
        }
        var failure: start_report.Failure = undefined;
        const intent = try readSources(init, request, settings, &failure);
        try std.testing.expectEqual(case.intent, intent);
        try std.testing.expectEqual(case.before, [3]bool{ settings.providers.entries.openai != null, settings.providers.entries.codex != null, settings.providers.entries.chatgpt != null });
        try finishSources(init, settings, intent, &failure);
        try std.testing.expectEqual(case.after, [3]bool{ settings.providers.entries.openai != null, settings.providers.entries.codex != null, settings.providers.entries.chatgpt != null });
    };
}

test "Host start source layers preserve explicit provider intent and assignment order" {
    const gpa = std.testing.allocator;
    var environment: std.process.Environ.Map = .init(gpa);
    defer environment.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const init = initForTest(&arena, &environment);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const settings = try gpa.create(hs.Settings);
    defer gpa.destroy(settings);
    const cases = [_]struct { saved: []const u8, document: []const u8, assignments: []const []const u8, providers: [3]bool }{
        .{ .saved = "{\"providers\":{\"codex\":{},\"chatgpt\":{}}}", .document = "{}", .assignments = &.{"providers.openai={}"}, .providers = .{ true, true, true } },
        .{ .saved = "{\"providers\":{\"openai\":{}}}", .document = "{\"providers\":{}}", .assignments = &.{ "providers.codex={}", "providers.chatgpt={}", "providers.codex=null" }, .providers = .{ false, false, true } },
        .{ .saved = "{\"providers\":{\"codex\":{}}}", .document = "{\"providers\":{\"openai\":{}}}", .assignments = &.{"providers.openai=null"}, .providers = .{ false, false, false } },
        .{ .saved = "{}", .document = "{}", .assignments = &.{ "providers.chatgpt={}", "providers.openai={}", "providers.chatgpt=null" }, .providers = .{ true, false, false } },
        .{ .saved = "{}", .document = "{}", .assignments = &.{"providers.openai=null"}, .providers = .{ false, false, false } },
    };
    for (cases, 0..) |case, index| {
        settings.* = .{};
        defer settings.deinit();
        var name: [32]u8 = undefined;
        var host = try tmp.dir.createDirPathOpen(init.io, try std.fmt.bufPrint(&name, "host-{d}", .{index}), .{ .permissions = .fromMode(0o700) });
        defer host.close(init.io);
        var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const dir = root[0..try host.realPath(init.io, &root)];
        try host.writeFile(init.io, .{ .sub_path = "host.json", .data = case.saved });
        try host.setFilePermissions(init.io, "host.json", .fromMode(0o600), .{});
        try host.writeFile(init.io, .{ .sub_path = "document.json", .data = case.document });
        try host.setFilePermissions(init.io, "document.json", .fromMode(0o600), .{});
        var failure: start_report.Failure = undefined;
        const intent = try readSources(init, .{ .dir = dir, .settings_file = try std.fs.path.join(arena.allocator(), &.{ dir, "document.json" }), .assignments = case.assignments }, settings, &failure);
        try std.testing.expectEqual(ProviderIntent.explicit, intent);
        try std.testing.expectEqual(case.providers, [3]bool{ settings.providers.entries.openai != null, settings.providers.entries.codex != null, settings.providers.entries.chatgpt != null });
    }
}

test "Host start detached first provider assignment selects an exact ordered set" {
    const gpa = std.testing.allocator;
    var environment: std.process.Environ.Map = .init(gpa);
    defer environment.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const init = initForTest(&arena, &environment);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try testHostDir(&tmp, &root);
    const settings = try gpa.create(hs.Settings);
    defer gpa.destroy(settings);
    const cases = [_]struct { assignments: []const []const u8, openai: bool, codex: bool, chatgpt: bool }{
        .{ .assignments = &.{"providers.openai={}"}, .openai = true, .codex = false, .chatgpt = false },
        .{ .assignments = &.{"providers.codex={}"}, .openai = false, .codex = true, .chatgpt = false },
        .{ .assignments = &.{"providers.chatgpt={}"}, .openai = false, .codex = false, .chatgpt = true },
        .{ .assignments = &.{ "providers.openai={}", "providers.codex={}", "providers.openai=null" }, .openai = false, .codex = true, .chatgpt = false },
        .{ .assignments = &.{ "providers.codex={}", "providers={}", "providers.chatgpt={}" }, .openai = false, .codex = false, .chatgpt = true },
    };
    for (cases) |case| {
        settings.* = .{};
        defer settings.deinit();
        var failure: start_report.Failure = undefined;
        _ = try readDetached(init, .{ .dir = dir, .assignments = case.assignments }, settings, &failure);
        try std.testing.expectEqual(case.openai, settings.providers.entries.openai != null);
        try std.testing.expectEqual(case.codex, settings.providers.entries.codex != null);
        try std.testing.expectEqual(case.chatgpt, settings.providers.entries.chatgpt != null);
    }
}

test "Host start detached launches rebase typed paths and refuse paths with no base over every layer and door" {
    const gpa = std.testing.allocator;
    var environment: std.process.Environ.Map = .init(gpa);
    defer environment.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const init = initForTest(&arena, &environment);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var here_dir = try tmp.dir.createDirPathOpen(init.io, "here", .{ .permissions = .fromMode(0o700) });
    defer here_dir.close(init.io);
    var here_root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const here = here_root[0..try here_dir.realPath(init.io, &here_root)];
    const Layer = enum { saved, document, set, file };
    const Kind = struct { leaf: []const u8, relative: []const u8, json: []const u8, text: []const u8, anchored: ?[]const u8 };
    const kinds = [_]Kind{
        .{ .leaf = "tools.bash.path", .relative = "bin/bash", .json = "{\"tools\":{\"bash\":{\"path\":\"bin/bash\"}}}", .text = "bin/bash", .anchored = "bin/bash" },
        .{ .leaf = "providers.openai.key", .relative = "key.txt", .json = "{\"providers\":{\"openai\":{\"key\":{\"file\":\"key.txt\"}}}}", .text = "file:key.txt", .anchored = "key.txt" },
        .{ .leaf = "interface.lifetime", .relative = "", .json = "{\"interface\":{\"lifetime\":\"stdin\"}}", .text = "stdin", .anchored = null },
    };
    for (kinds, 0..) |kind, kind_index| for (std.enums.values(Layer)) |layer| {
        var name: [32]u8 = undefined;
        var host = try tmp.dir.createDirPathOpen(init.io, try std.fmt.bufPrint(&name, "host-{d}-{s}", .{ kind_index, @tagName(layer) }), .{ .permissions = .fromMode(0o700) });
        defer host.close(init.io);
        var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const dir = root[0..try host.realPath(init.io, &root)];
        var request: Spawn = .{ .dir = dir };
        const content_name = try std.fmt.bufPrint(&name, "content-{d}.json", .{kind_index});
        switch (layer) {
            .saved => {
                try host.writeFile(init.io, .{ .sub_path = "host.json", .data = kind.json });
                try host.setFilePermissions(init.io, "host.json", .fromMode(0o600), .{});
            },
            .document => {
                try here_dir.writeFile(init.io, .{ .sub_path = "document.json", .data = kind.json });
                try here_dir.setFilePermissions(init.io, "document.json", .fromMode(0o600), .{});
                request.settings_file = try std.fs.path.join(a, &.{ here, "document.json" });
            },
            .set => request.assignments = try a.dupe([]const u8, &.{try std.fmt.allocPrint(a, "{s}={s}", .{ kind.leaf, kind.text })}),
            .file => {
                const parent = kind.leaf[0..std.mem.lastIndexOfScalar(u8, kind.leaf, '.').?];
                const member = kind.leaf[parent.len + 1 ..];
                const json = if (std.mem.eql(u8, member, "key")) "{\"key\":{\"file\":\"key.txt\"}}" else if (std.mem.eql(u8, member, "path")) "{\"path\":\"bin/bash\"}" else "{\"lifetime\":\"stdin\"}";
                try here_dir.writeFile(init.io, .{ .sub_path = content_name, .data = json });
                request.assignments = try a.dupe([]const u8, &.{try std.fmt.allocPrint(a, "{s}=@{s}", .{ parent, try std.fs.path.join(a, &.{ here, content_name }) })});
            },
        }
        const typed = layer == .set and kind.anchored != null;
        var failure: start_report.Failure = undefined;
        var cwd: Cwd = .{ .io = init.io, .path = here };
        const started = try anchorTyped(a, &cwd, request, &failure);
        const start_result = checkStart(init, started, &failure);
        if (typed) {
            try start_result;
            const value = started.assignments[0][std.mem.indexOfScalar(u8, started.assignments[0], '=').? + 1 ..];
            const expected = try std.fs.path.join(a, &.{ here, kind.anchored.? });
            try std.testing.expect(std.mem.endsWith(u8, value, expected));
        } else {
            try std.testing.expectError(error.SettingsInvalid, start_result);
            try std.testing.expectEqual(start_report.StartError.settings_invalid, failure.code);
            try std.testing.expect(std.mem.startsWith(u8, failure.message.slice(), kind.leaf));
            try std.testing.expectEqual(@as(u8, ':'), failure.message.slice()[kind.leaf.len]);
            try std.testing.expect(std.mem.indexOf(u8, failure.message.slice(), if (kind.anchored == null) "no stdin" else "absolute path") != null);
        }
        try std.testing.expectError(error.SettingsInvalid, checkStart(init, request, &failure));
    };
    var host = try here_dir.createDirPathOpen(init.io, "host-references", .{ .permissions = .fromMode(0o700) });
    defer host.close(init.io);
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = root[0..try host.realPath(init.io, &root)];
    try here_dir.writeFile(init.io, .{ .sub_path = "plain.json", .data = "{\"execution\":{\"activeCapacity\":3}}" });
    try here_dir.setFilePermissions(init.io, "plain.json", .fromMode(0o600), .{});
    try here_dir.writeFile(init.io, .{ .sub_path = "bash.json", .data = "{\"path\":\"/bin/bash\"}" });
    for ([_]Spawn{
        .{ .dir = dir, .settings_file = "plain.json" },
        .{ .dir = dir, .assignments = &.{"tools.bash=@bash.json"} },
    }) |request| {
        var failure: start_report.Failure = undefined;
        var cwd: Cwd = .{ .io = init.io, .path = here };
        try checkStart(init, try anchorTyped(a, &cwd, request, &failure), &failure);
        try std.testing.expectError(error.SettingsInvalid, checkStart(init, request, &failure));
    }
    var failure: start_report.Failure = undefined;
    var cwd: Cwd = .{ .io = init.io, .path = here };
    try std.testing.expectError(error.SettingsInvalid, checkStart(init, try anchorTyped(a, &cwd, .{ .dir = dir, .settings_file = "-" }, &failure), &failure));
    try std.testing.expect(std.mem.indexOf(u8, failure.message.slice(), "rui host serve --settings -") != null);
}

test "Host start placement agrees across Store interface and every door without resolving secrets" {
    const gpa = std.testing.allocator;
    var environment: std.process.Environ.Map = .init(gpa);
    defer environment.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const init = initForTest(&arena, &environment);
    var tmp = try @import("socket_fixture.zig").Directory.init();
    defer tmp.cleanup();
    const Store = enum { here, elsewhere, mysql };
    const Door = enum { serve, starter, client };
    for (std.enums.values(Store)) |store| for ([_]bool{ false, true }) |explicit| {
        const name = try std.fmt.allocPrint(arena.allocator(), "{s}-{s}", .{ @tagName(store), if (explicit) "explicit" else "default" });
        const dir = try std.fs.path.join(arena.allocator(), &.{ tmp.root[0..tmp.root_len], name });
        const elsewhere = try std.fs.path.join(arena.allocator(), &.{ dir, "data" });
        const interface = try std.fs.path.join(arena.allocator(), &.{ tmp.root[0..tmp.root_len], "interface" });
        var failure: start_report.Failure = undefined;
        try savedEdit(init, dir, "providers", "{}", &failure);
        switch (store) {
            .here => {},
            .elsewhere => try savedEdit(init, dir, "store.sqlite.dir", elsewhere, &failure),
            .mysql => try savedEdit(init, dir, "store.mysql.url", "env:HOST_START_NEVER_RESOLVED", &failure),
        }
        if (explicit) try savedEdit(init, dir, "interface.dir", interface, &failure);
        var expected: ?platform.Paths = null;
        for (std.enums.values(Door)) |door| {
            const settings = try gpa.create(hs.Settings);
            defer gpa.destroy(settings);
            settings.* = .{};
            defer settings.deinit();
            const paths = switch (door) {
                .client => try savedPlacement(init.io, dir),
                .serve => result: {
                    const parsed = try parseForTest(arena.allocator(), &.{});
                    var fixtures: providers.Fixtures = .{};
                    try fillAt(init, &parsed, dir, settings, &fixtures, &failure);
                    try anchorPlacement(init, settings, dir, &failure);
                    break :result try platform.placementPaths(init.io, settings);
                },
                .starter => result: {
                    try checkStart(init, .{ .dir = dir }, &failure);
                    _ = try readDetached(init, .{ .dir = dir }, settings, &failure);
                    try anchorPlacement(init, settings, dir, &failure);
                    break :result try platform.placementPaths(init.io, settings);
                },
            };
            if (expected) |first| {
                try std.testing.expectEqual(first.kind, paths.kind);
                try std.testing.expectEqualStrings(first.store_identity.slice(), paths.store_identity.slice());
                try std.testing.expectEqualStrings(first.socket.slice(), paths.socket.slice());
            } else expected = paths;
            if (explicit) try std.testing.expectEqualStrings(try std.fs.path.join(arena.allocator(), &.{ interface, "rui.sock" }), paths.socket.slice());
            if (store == .mysql) {
                try std.testing.expectEqual(platform.Kind.mysql, paths.kind);
                try std.testing.expectEqual(@as(usize, 0), paths.store_identity.len);
            } else try std.testing.expectEqualStrings(if (store == .here) dir else elsewhere, paths.store_identity.slice());
        }
    };
    // Long default placement remains short, unlike an explicit interface.
    const component: [150]u8 = @splat('d');
    const long = try std.fs.path.join(arena.allocator(), &.{ tmp.root[0..tmp.root_len], &component });
    var failure: start_report.Failure = undefined;
    try savedEdit(init, long, "providers", "{}", &failure);
    const sqlite = try savedPlacement(init.io, long);
    try savedEdit(init, long, "store.mysql.url", "env:HOST_START_NEVER_RESOLVED", &failure);
    const mysql = try savedPlacement(init.io, long);
    try std.testing.expect(sqlite.socket.len < hs.max_launch_socket_path_bytes);
    try std.testing.expect(mysql.socket.len < hs.max_launch_socket_path_bytes);
    try checkStart(init, .{ .dir = long }, &failure);
}

test "Host start unsaved placement is refused but saved placement and other overrides are admitted" {
    const gpa = std.testing.allocator;
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const init = initForTest(&arena, &env);
    var tmp = try @import("socket_fixture.zig").Directory.init();
    defer tmp.cleanup();
    const dir = tmp.root[0..tmp.root_len];
    var failure: start_report.Failure = undefined;
    const interface = try std.fs.path.join(arena.allocator(), &.{ dir, "runtime" });
    for ([_][]const u8{ "store.mysql.url=env:NEVER_RESOLVED", try std.fmt.allocPrint(arena.allocator(), "interface.dir={s}", .{interface}), try std.fmt.allocPrint(arena.allocator(), "store.sqlite.dir={s}/data", .{dir}) }) |assignment| {
        try std.testing.expectError(error.SettingsInvalid, checkStart(init, .{ .dir = dir, .assignments = &.{assignment} }, &failure));
        try std.testing.expect(std.mem.indexOf(u8, failure.message.slice(), "rui host set") != null);
    }
    const file = try std.fs.path.join(arena.allocator(), &.{ dir, "placement.json" });
    try tmp.dir.writeFile(init.io, .{ .sub_path = "placement.json", .data = "{\"store\":{\"mysql\":{\"url\":{\"env\":\"NEVER_RESOLVED\"}}}}" });
    try tmp.dir.setFilePermissions(init.io, "placement.json", .fromMode(0o600), .{});
    try std.testing.expectError(error.SettingsInvalid, checkStart(init, .{ .dir = dir, .settings_file = file }, &failure));
    try savedEdit(init, dir, "interface.dir", interface, &failure);
    try checkStart(init, .{ .dir = dir, .assignments = &.{"execution.activeCapacity=3"} }, &failure);
}

test "Host start guided connection isolates two Stores preserves providers and freezes the pair" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = home_buffer[0..try tmp.dir.realPath(io, &home_buffer)];
    var environment: std.process.Environ.Map = .init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("HOME", home);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const init = initForTest(&arena, &environment);
    const a = arena.allocator();
    const first_dir = try std.fs.path.join(a, &.{ home, "first" });
    const other_dir = try std.fs.path.join(a, &.{ home, "other" });
    try provider_login.key(init, "global-key-kept");
    var failure: start_report.Failure = undefined;
    try savedEdit(init, first_dir, "providers", "{\"codex\":{},\"chatgpt\":{}}", &failure);
    try savedEdit(init, first_dir, "execution.activeCapacity", "7", &failure);
    const Gate = struct {
        fn yes() bool {
            return true;
        }
        fn no() bool {
            return false;
        }
    };
    const first = try saveConnection(init, first_dir, .{ .base = "https://one.example/v1" }, .{ .provided = "first-private-key" }, "vendor-chat-v1", Gate.yes);
    try std.testing.expect(first == .saved);
    try std.testing.expectEqualStrings("https://one.example/v1/responses", first.saved.endpoint.slice());
    const info = try inspectConnection(init, first_dir);
    try std.testing.expect(info.custom());
    try std.testing.expect(info.readiness.usable());
    const other = try inspectConnection(init, other_dir);
    try std.testing.expect(!other.custom());
    try std.testing.expect(other.readiness.usable());
    var key: api_key.Key = .{};
    defer key.wipe();
    var key_path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try std.testing.expect(try api_key.read(try api_key.path(&environment, &key_path), &key));
    try std.testing.expectEqualStrings("global-key-kept", key.slice());
    try std.testing.expect(try api_key.read(first.saved.key_file.slice(), &key));
    try std.testing.expectEqualStrings("first-private-key", key.slice());
    try std.testing.expectEqual(@as(u16, 0o600), (try std.Io.Dir.cwd().statFile(io, first.saved.key_file.slice(), .{})).permissions.toMode() & 0o777);
    const settings = try std.testing.allocator.create(hs.Settings);
    defer std.testing.allocator.destroy(settings);
    settings.* = .{};
    defer settings.deinit();
    const parsed = try parseForTest(a, &.{});
    var fixtures: providers.Fixtures = .{};
    try fillAt(init, &parsed, first_dir, settings, &fixtures, &failure);
    try std.testing.expect(settings.providers.entries.codex != null and settings.providers.entries.chatgpt != null);
    try std.testing.expectEqual(@as(usize, 7), settings.execution.active_capacity.value);
    try std.testing.expect(!settings.providers.entries.openai.?.unauthenticated.value);
    try std.testing.expectEqualStrings(first.saved.key_file.slice(), settings.providers.entries.openai.?.key.source.file.slice());
    try std.testing.expect((try confirmConnection(init, first_dir, &first.saved)) == .saved);
    const second = try saveConnection(init, first_dir, .{ .base = "https://two.example/api" }, .{ .provided = "second-private-key" }, "other-chat", Gate.yes);
    try std.testing.expect(second == .saved);
    try std.testing.expect(!std.mem.eql(u8, first.saved.key_file.slice(), second.saved.key_file.slice()));
    try std.testing.expectError(error.ConnectionSuperseded, confirmConnection(init, first_dir, &first.saved));
    try std.testing.expect(try api_key.read(first.saved.key_file.slice(), &key));
    try std.testing.expectEqualStrings("first-private-key", key.slice());
    const assignment = try connectionAssignment(init, a, &first.saved);
    try std.testing.expect(std.mem.indexOf(u8, assignment, "first-private-key") == null);
    settings.deinit();
    settings.* = .{};
    const intent = try readSources(init, .{ .dir = first_dir, .assignments = &.{assignment} }, settings, &failure);
    try finishSources(init, settings, intent, &failure);
    try std.testing.expectEqualStrings(first.saved.endpoint.slice(), settings.providers.entries.openai.?.endpoint.?.slice());
    try std.testing.expectEqualStrings(first.saved.key_file.slice(), settings.providers.entries.openai.?.key.source.file.slice());
    try std.testing.expectError(error.LoginInterrupted, saveConnection(init, first_dir, .{ .base = "https://cancelled.example" }, .{ .provided = "cancelled-key" }, "valid-chat", Gate.no));
    try std.testing.expect((try confirmConnection(init, first_dir, &second.saved)) == .saved);
    for ([_][]const u8{ "", "two words", "bad\nkey" }) |invalid_key| try std.testing.expectError(error.InvalidApiKey, saveConnection(init, first_dir, .{ .base = "https://unused.example" }, .{ .provided = invalid_key }, "valid-chat", Gate.yes));
    for ([_][]const u8{ "http://host", "https://user@host", "https://host?q=1", "https://host#fragment" }) |base| try std.testing.expectError(error.InvalidBaseUrl, saveConnection(init, first_dir, .{ .base = base }, .{ .provided = "valid-key" }, "valid-chat", Gate.yes));
    try std.testing.expect((try confirmConnection(init, first_dir, &second.saved)) == .saved);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, ".config/rui/preferences", .{}));
}

test "Host start guided connection materializes automatic routes and reuses the effective private source" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = home_buffer[0..try tmp.dir.realPath(io, &home_buffer)];
    var environment: std.process.Environ.Map = .init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("HOME", home);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const init = initForTest(&arena, &environment);
    try environment.put("GUIDED_EXISTING_KEY", "from-environment");
    const dir = try std.fs.path.join(arena.allocator(), &.{ home, "store" });
    var failure: start_report.Failure = undefined;
    const Gate = struct {
        fn yes() bool {
            return true;
        }
    };
    const first = try saveConnection(init, dir, .{ .base = "https://example.test" }, .{ .provided = "first-key" }, "custom-chat", Gate.yes);
    try std.testing.expect(first == .saved);
    const settings = try std.testing.allocator.create(hs.Settings);
    defer std.testing.allocator.destroy(settings);
    settings.* = .{};
    defer settings.deinit();
    const document = try saved(init, arena.allocator(), dir, settings, &failure);
    try std.testing.expect(document.object.contains("providers"));
    try std.testing.expect(settings.providers.entries.chatgpt == null and settings.providers.entries.codex != null);
    try savedEdit(init, dir, "providers.openai.key", "env:GUIDED_EXISTING_KEY", &failure);
    const reuse = try inspectConnection(init, dir);
    try std.testing.expect(reuse.reusable());
    const second = try saveConnection(init, dir, .{ .unchanged = first.saved.endpoint.slice() }, .{ .existing = &reuse }, "custom-chat", Gate.yes);
    try std.testing.expect(second == .saved);
    var key: api_key.Key = .{};
    defer key.wipe();
    try std.testing.expect(try api_key.read(second.saved.key_file.slice(), &key));
    try std.testing.expectEqualStrings("from-environment", key.slice());
    var browser_path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const browser = try provider_login.credentialPath(init, .chatgpt, &browser_path, true);
    const record = try init.gpa.create(credentials.Record);
    defer init.gpa.destroy(record);
    record.* = .{ .generation = 0, .account_id = .{}, .id_token = .{}, .access_token = .{}, .refresh_token = .{}, .expires_at = 4_102_444_800, .refreshed_at = 1 };
    defer std.crypto.secureZero(u8, std.mem.asBytes(record));
    try record.account_id.set(codex_auth.fixture_account_id);
    try record.id_token.set(codex_auth.fixture_id_token);
    try record.access_token.set(codex_auth.fixture_access_token);
    try record.refresh_token.set("fixture-refresh");
    const scratch = try init.gpa.create(credentials.Scratch);
    defer init.gpa.destroy(scratch);
    try credentials.install(browser, record, null, scratch);
    const browser_dir = try std.fs.path.join(arena.allocator(), &.{ home, "browser-host" });
    const third = try saveConnection(init, browser_dir, .{ .base = "https://browser.example/v1" }, .{ .provided = "third-key" }, "custom-chat", Gate.yes);
    try std.testing.expect(third == .saved);
    settings.deinit();
    settings.* = .{};
    _ = try saved(init, arena.allocator(), browser_dir, settings, &failure);
    try std.testing.expect(settings.providers.entries.chatgpt != null and settings.providers.entries.codex != null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, ".config/rui/openai.key", .{}));
}

test "Host start guided connection distinguishes key sync settings sync and retained cleanup identity" {
    const Gate = struct {
        fn yes() bool {
            return true;
        }
    };
    for ([_]ConnectionFault{
        .{ .key = .write },
        .{ .key = .file_sync },
        .{ .key = .rename },
        .{ .key = .directory_sync },
        .{ .document = .write },
        .{ .document = .file_sync },
        .{ .document = .rename },
        .{ .document = .directory_sync },
        .{ .document = .write, .cleanup = error.AccessDenied },
        .{ .document = .write, .cleanup_sync = error.DirectorySyncFailed },
    }) |fault| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const home = home_buffer[0..try tmp.dir.realPath(std.testing.io, &home_buffer)];
        var environment: std.process.Environ.Map = .init(std.testing.allocator);
        defer environment.deinit();
        try environment.put("HOME", home);
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const init = initForTest(&arena, &environment);
        const dir = try std.fs.path.join(arena.allocator(), &.{ home, "host" });
        var failure: start_report.Failure = undefined;
        try savedEdit(init, dir, "execution.activeCapacity", "7", &failure);
        const saved_path = try savedPath(init, arena.allocator(), dir);
        var before: [hs.max_document_bytes + 1]u8 = undefined;
        const old = try arena.allocator().dupe(u8, (try credentials.readPrivate(saved_path, &before)).?);
        const operation = saveConnectionWithFault(init, dir, .{ .base = "https://custom.example/v1" }, .{ .provided = "private-fixture-key" }, "custom-model", Gate.yes, fault);
        if (fault.key != null and fault.key != .directory_sync) {
            try std.testing.expectError(switch (fault.key.?) {
                .write => error.InjectedCredentialWriteFailure,
                .file_sync => error.InjectedCredentialFileSyncFailure,
                .rename => error.InjectedCredentialRenameFailure,
                .directory_sync => unreachable,
            }, operation);
            var intact: [hs.max_document_bytes + 1]u8 = undefined;
            try std.testing.expectEqualStrings(old, (try credentials.readPrivate(saved_path, &intact)).?);
            continue;
        }
        const result = try operation;
        var after: [hs.max_document_bytes + 1]u8 = undefined;
        const document = (try credentials.readPrivate(saved_path, &after)).?;
        if (fault.document == .directory_sync) {
            try std.testing.expectEqual(error.InjectedCredentialDirectorySyncFailure, result.uncertain.cause);
            try std.testing.expect(try api_key.present(result.uncertain.connection.key_file.slice()));
            try std.testing.expect(std.mem.indexOf(u8, document, result.uncertain.connection.key_file.slice()) != null);
            try std.testing.expect((try confirmConnection(init, dir, &result.uncertain.connection)) == .saved);
        } else {
            try std.testing.expect(result == .failed);
            try std.testing.expectEqualStrings(old, document);
            try std.testing.expectEqual(if (fault.key != null) error.InjectedCredentialDirectorySyncFailure else switch (fault.document.?) {
                .write => error.InjectedCredentialWriteFailure,
                .file_sync => error.InjectedCredentialFileSyncFailure,
                .rename => error.InjectedCredentialRenameFailure,
                .directory_sync => unreachable,
            }, result.failed.cause);
            const cleanup_cause: ?anyerror = if (fault.cleanup != null) fault.cleanup else fault.cleanup_sync;
            if (cleanup_cause) |cause| {
                try std.testing.expectEqual(cause, result.failed.cleanup.?.cause);
                const retained = result.failed.cleanup.?.key_file.slice();
                try std.testing.expect(std.mem.startsWith(u8, retained, dir));
                try std.testing.expectEqual(fault.cleanup != null, try api_key.present(retained));
                try std.testing.expect(std.mem.indexOf(u8, document, retained) == null);
            } else {
                try std.testing.expect(result.failed.cleanup == null);
                var directory = try std.Io.Dir.cwd().openDir(init.io, dir, .{ .iterate = true });
                defer directory.close(init.io);
                var entries = directory.iterate();
                while (try entries.next(init.io)) |entry| try std.testing.expect(!std.mem.endsWith(u8, entry.name, ".key"));
            }
        }
        var key_path: [std.Io.Dir.max_path_bytes]u8 = undefined;
        try std.testing.expect(!try api_key.present(try api_key.path(&environment, &key_path)));
    }
}

test "Host start guided reuse refuses source-only and auth-only supersession before chosen key resolution or publication" {
    const Change = enum { source, unauthenticated };
    const Gate = struct {
        var calls: usize = 0;
        fn publish() bool {
            calls += 1;
            return true;
        }
        fn yes() bool {
            return true;
        }
    };
    for (std.enums.values(Change)) |change| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const home = path_buffer[0..try tmp.dir.realPath(std.testing.io, &path_buffer)];
        var env: std.process.Environ.Map = .init(std.testing.allocator);
        defer env.deinit();
        try env.put("HOME", home);
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const init = initForTest(&arena, &env);
        try provider_login.key(init, "global-key-kept");
        const dir = try std.fs.path.join(arena.allocator(), &.{ home, "host" });
        const first = try saveConnection(init, dir, .{ .base = "https://first.example/v1" }, .{ .provided = "first-key" }, "custom-model", Gate.yes);
        const admitted = try inspectConnection(init, dir);
        try std.testing.expect(admitted.reusable());
        if (change == .unauthenticated) {
            var failure: start_report.Failure = undefined;
            try savedEdit(init, dir, "providers.openai.unauthenticated", "true", &failure);
        } else {
            const second = try saveConnection(init, dir, .{ .base = "https://first.example/v1" }, .{ .provided = "second-key" }, "custom-model", Gate.yes);
            try std.Io.Dir.cwd().deleteFile(init.io, second.saved.key_file.slice());
        }
        const target = try savedPath(init, arena.allocator(), dir);
        var before: [hs.max_document_bytes + 1]u8 = undefined;
        const bytes = try arena.allocator().dupe(u8, (try credentials.readPrivate(target, &before)).?);
        Gate.calls = 0;
        try std.testing.expectError(error.ConnectionSuperseded, saveConnection(init, dir, .{ .unchanged = admitted.endpoint.slice() }, .{ .existing = &admitted }, "custom-model", Gate.publish));
        try std.testing.expectEqual(@as(usize, 0), Gate.calls);
        var after: [hs.max_document_bytes + 1]u8 = undefined;
        try std.testing.expectEqualStrings(bytes, (try credentials.readPrivate(target, &after)).?);
        var key: api_key.Key = .{};
        defer key.wipe();
        try std.testing.expect(try api_key.read(first.saved.key_file.slice(), &key));
        try std.testing.expectEqualStrings("first-key", key.slice());
        try std.testing.expect(try api_key.read(try api_key.path(&env, &path_buffer), &key));
        try std.testing.expectEqualStrings("global-key-kept", key.slice());
        var directory = try std.Io.Dir.cwd().openDir(init.io, dir, .{ .iterate = true });
        defer directory.close(init.io);
        var entries = directory.iterate();
        var keys: usize = 0;
        while (try entries.next(init.io)) |entry| if (std.mem.endsWith(u8, entry.name, ".key")) {
            keys += 1;
            try std.testing.expectEqualStrings(std.fs.path.basename(first.saved.key_file.slice()), entry.name);
        };
        try std.testing.expectEqual(@as(usize, 1), keys);
    }
}

test "Host start guided reuse refuses endpoint-only supersession with unchanged file env and default authority" {
    const Source = enum { file, env, default };
    const Gate = struct {
        var calls: usize = 0;
        fn publish() bool {
            calls += 1;
            return true;
        }
    };
    for (std.enums.values(Source)) |source| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const home = home_buffer[0..try tmp.dir.realPath(std.testing.io, &home_buffer)];
        var env: std.process.Environ.Map = .init(std.testing.allocator);
        defer env.deinit();
        try env.put("HOME", home);
        try env.put("GUIDED_ENDPOINT_KEY", "environment-key");
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const init = initForTest(&arena, &env);
        try provider_login.key(init, "global-key-kept");
        var key_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const key_path = try api_key.path(&env, &key_path_buffer);
        const dir = try std.fs.path.join(arena.allocator(), &.{ home, "host" });
        var failure: start_report.Failure = undefined;
        try savedEdit(init, dir, "providers", "{\"openai\":{}}", &failure);
        try savedEdit(init, dir, "providers.openai.endpoint", "https://first.example/v1/responses", &failure);
        switch (source) {
            .file => try savedEdit(init, dir, "providers.openai.key", try std.fmt.allocPrint(arena.allocator(), "file:{s}", .{key_path}), &failure),
            .env => try savedEdit(init, dir, "providers.openai.key", "env:GUIDED_ENDPOINT_KEY", &failure),
            .default => {},
        }
        const admitted = try inspectConnection(init, dir);
        try std.testing.expect(admitted.reusable());
        try std.testing.expect(!admitted.unauthenticated);
        try savedEdit(init, dir, "providers.openai.endpoint", "https://second.example/v2/responses", &failure);
        const superseding = try inspectConnection(init, dir);
        try std.testing.expect(superseding.reusable() and !superseding.unauthenticated);
        try std.testing.expectEqualStrings("https://second.example/v2/responses", superseding.endpoint.slice());
        switch (source) {
            .file, .default => {
                try std.testing.expectEqualStrings(key_path, admitted.key_source.?.file.slice());
                try std.testing.expectEqualStrings(key_path, superseding.key_source.?.file.slice());
            },
            .env => {
                try std.testing.expectEqualStrings("GUIDED_ENDPOINT_KEY", admitted.key_source.?.env.slice());
                try std.testing.expectEqualStrings("GUIDED_ENDPOINT_KEY", superseding.key_source.?.env.slice());
            },
        }
        const target = try savedPath(init, arena.allocator(), dir);
        var before: [hs.max_document_bytes + 1]u8 = undefined;
        const bytes = try arena.allocator().dupe(u8, (try credentials.readPrivate(target, &before)).?);
        if (source == .env) try env.put("GUIDED_ENDPOINT_KEY", "invalid key bytes") else try std.Io.Dir.cwd().deleteFile(init.io, key_path);
        Gate.calls = 0;
        try std.testing.expectError(error.ConnectionSuperseded, saveConnection(init, dir, .{ .unchanged = admitted.endpoint.slice() }, .{ .existing = &admitted }, "custom-model", Gate.publish));
        try std.testing.expectEqual(@as(usize, 0), Gate.calls);
        var after: [hs.max_document_bytes + 1]u8 = undefined;
        try std.testing.expectEqualStrings(bytes, (try credentials.readPrivate(target, &after)).?);
        if (source == .env) {
            var key: api_key.Key = .{};
            defer key.wipe();
            try std.testing.expect(try api_key.read(key_path, &key));
            try std.testing.expectEqualStrings("global-key-kept", key.slice());
            try std.testing.expectEqualStrings("invalid key bytes", env.get("GUIDED_ENDPOINT_KEY").?);
        } else try std.testing.expect(!try api_key.present(key_path));
        var directory = try std.Io.Dir.cwd().openDir(init.io, dir, .{ .iterate = true });
        defer directory.close(init.io);
        var entries = directory.iterate();
        while (try entries.next(init.io)) |entry| try std.testing.expect(!std.mem.endsWith(u8, entry.name, ".key"));
    }
}

test "Host start guided reuse admits equivalent automatic omitted endpoint env base and default file sources" {
    const Source = enum { automatic, omitted_endpoint, explicit_file };
    const Gate = struct {
        fn yes() bool {
            return true;
        }
    };
    for (std.enums.values(Source)) |source| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const home = home_buffer[0..try tmp.dir.realPath(std.testing.io, &home_buffer)];
        var env: std.process.Environ.Map = .init(std.testing.allocator);
        defer env.deinit();
        try env.put("HOME", home);
        try env.put(providers.openai_base_url_variable, "https://effective.example/v1");
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const init = initForTest(&arena, &env);
        try provider_login.key(init, "global-source-key");
        const dir = try std.fs.path.join(arena.allocator(), &.{ home, "host" });
        var failure: start_report.Failure = undefined;
        try savedEdit(init, dir, if (source == .automatic) "execution.activeCapacity" else "providers", if (source == .automatic) "7" else "{\"openai\":{}}", &failure);
        const admitted = try inspectConnection(init, dir);
        try std.testing.expect(admitted.reusable());
        try std.testing.expectEqualStrings("https://effective.example/v1/responses", admitted.endpoint.slice());
        if (source == .explicit_file) {
            var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
            try savedEdit(init, dir, "providers.openai.key", try std.fmt.allocPrint(arena.allocator(), "file:{s}", .{try api_key.path(&env, &path_buffer)}), &failure);
        }
        const saved_connection = try saveConnection(init, dir, .{ .unchanged = admitted.endpoint.slice() }, .{ .existing = &admitted }, "custom-model", Gate.yes);
        try std.testing.expect(saved_connection == .saved);
        try std.testing.expectEqualStrings(admitted.endpoint.slice(), saved_connection.saved.endpoint.slice());
        var key: api_key.Key = .{};
        defer key.wipe();
        try std.testing.expect(try api_key.read(saved_connection.saved.key_file.slice(), &key));
        try std.testing.expectEqualStrings("global-source-key", key.slice());
    }
}

test "Host start guided recheck separates supersession from publication durability at every fault phase" {
    const Gate = struct {
        fn yes() bool {
            return true;
        }
    };
    const State = enum { matching, missing, superseding };
    for (std.enums.values(State)) |state| for ([_]?credentials.PrivateFault{ null, .write, .file_sync, .rename, .directory_sync }) |fault| {
        errdefer std.debug.print("recheck state={s} fault={s}\n", .{ @tagName(state), if (fault) |value| @tagName(value) else "none" });
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const home = home_buffer[0..try tmp.dir.realPath(std.testing.io, &home_buffer)];
        var environment: std.process.Environ.Map = .init(std.testing.allocator);
        defer environment.deinit();
        try environment.put("HOME", home);
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const init = initForTest(&arena, &environment);
        const dir = try std.fs.path.join(arena.allocator(), &.{ home, "host" });
        const first = try saveConnection(init, dir, .{ .base = "https://first.example/v1" }, .{ .provided = "private-first-key" }, "custom-model", Gate.yes);
        const path = try savedPath(init, arena.allocator(), dir);
        switch (state) {
            .matching => {},
            .missing => try std.Io.Dir.cwd().deleteFile(init.io, path),
            .superseding => _ = try saveConnection(init, dir, .{ .base = "https://other.example/v2" }, .{ .provided = "private-second-key" }, "custom-model", Gate.yes),
        }
        var before: [hs.max_document_bytes + 1]u8 = undefined;
        const old = if (try credentials.readPrivate(path, &before)) |bytes| try arena.allocator().dupe(u8, bytes) else null;
        const result = confirmConnectionWithFault(init, dir, &first.saved, fault);
        if (state != .matching) {
            try std.testing.expectError(error.ConnectionSuperseded, result);
        } else if (fault != null and fault != .directory_sync) {
            try std.testing.expectError(switch (fault.?) {
                .write => error.InjectedCredentialWriteFailure,
                .file_sync => error.InjectedCredentialFileSyncFailure,
                .rename => error.InjectedCredentialRenameFailure,
                .directory_sync => unreachable,
            }, result);
        } else {
            const confirmed = try result;
            if (fault == .directory_sync) {
                try std.testing.expect(confirmed == .uncertain);
                try std.testing.expectEqual(error.InjectedCredentialDirectorySyncFailure, confirmed.uncertain.cause);
                try std.testing.expectEqualStrings(first.saved.endpoint.slice(), confirmed.uncertain.connection.endpoint.slice());
                try std.testing.expectEqualStrings(first.saved.key_file.slice(), confirmed.uncertain.connection.key_file.slice());
            } else try std.testing.expect(confirmed == .saved);
        }
        var after: [hs.max_document_bytes + 1]u8 = undefined;
        const current = try credentials.readPrivate(path, &after);
        try std.testing.expectEqual(old == null, current == null);
        if (old) |bytes| try std.testing.expectEqualStrings(bytes, current.?);
        try std.testing.expect(try api_key.present(first.saved.key_file.slice()));
        if (state == .matching) try std.testing.expect((try confirmConnection(init, dir, &first.saved)) == .saved);
    };
}

test "Host detached check shares source admission then resolves and seals without opening a Store" {
    const gpa = std.testing.allocator;
    var environment: std.process.Environ.Map = .init(gpa);
    defer environment.deinit();
    try environment.put("CHECK_MYSQL_URL", "mysql://user:password@127.0.0.1:9/database");
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const init = initForTest(&arena, &environment);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try testHostDir(&tmp, &root);
    const settings = try gpa.create(hs.Settings);
    defer gpa.destroy(settings);
    const cases = [_]struct { args: []const []const u8, foreground: bool = true, detached: bool = true }{
        .{ .args = &.{} },
        .{ .args = &.{ "--set", "execution.activeCapacity=3" } },
        .{ .args = &.{ "--set", "interface.lifetime=stdin" }, .detached = false },
        .{ .args = &.{ "--set", "tools.bash.path=relative/bash" }, .detached = false },
        .{ .args = &.{ "--set", "tools.bash.path=relative/bash", "--set", "tools.bash.path=/bin/bash" } },
        .{ .args = &.{ "--set", "interface.dir=/tmp/unsaved-check-interface" }, .detached = false },
        .{ .args = &.{ "--set", "execution.activeCapacity=0" } },
        .{ .args = &.{ "--set", "execution.activeCapacity=-1" }, .foreground = false, .detached = false },
        .{ .args = &.{ "--set", "providers.codex.credentialFile=/tmp/check-credential", "--set", "providers.codex.endpoint=https://example.com/responses" }, .foreground = false, .detached = false },
        .{ .args = &.{ "--set", "providers.openai.key=env:CHECK_ABSENT_KEY" }, .foreground = false, .detached = false },
    };
    for (cases, 0..) |case, index| for (std.enums.values(Admission)) |door| {
        errdefer std.debug.print("check admission case {d}, door {s}\n", .{ index, @tagName(door) });
        settings.* = .{};
        defer settings.deinit();
        var failure: start_report.Failure = undefined;
        var fixtures: providers.Fixtures = .{};
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(gpa);
        try args.appendSlice(gpa, &.{ "--set", "providers={}" });
        try args.appendSlice(gpa, case.args);
        const parsed = try parseForTest(arena.allocator(), args.items);
        const admitted: anyerror!void = admit: {
            intake(init, &parsed, dir, settings, &fixtures, &failure, door) catch |err| break :admit err;
            _ = admitSelected(init, dir, settings, fixtures, &failure) catch |err| break :admit err;
        };
        if (if (door == .foreground) case.foreground else case.detached) {
            try admitted;
        } else {
            try std.testing.expectError(error.SettingsInvalid, admitted);
            try std.testing.expectEqual(start_report.StartError.settings_invalid, failure.code);
        }
    };
    // Check resolves/seals MySQL input, but never dials or locks it.
    var host = try tmp.dir.openDir(init.io, "host-dir", .{});
    defer host.close(init.io);
    try host.writeFile(init.io, .{ .sub_path = "host.json", .data = "{\"providers\":{},\"store\":{\"mysql\":{\"url\":{\"env\":\"CHECK_MYSQL_URL\"}}}}" });
    try host.setFilePermissions(init.io, "host.json", .fromMode(0o600), .{});
    settings.* = .{};
    defer settings.deinit();
    var failure: start_report.Failure = undefined;
    var fixtures: providers.Fixtures = .{};
    const parsed = try parseForTest(arena.allocator(), &.{});
    try intake(init, &parsed, dir, settings, &fixtures, &failure, .detached);
    _ = try admitSelected(init, dir, settings, fixtures, &failure);
    try std.testing.expectEqual(.mysql, std.meta.activeTag(settings.store));
}

test "Host restart sources preserve previous and current release provider semantics" {
    const gpa = std.testing.allocator;
    var environment: std.process.Environ.Map = .init(gpa);
    defer environment.deinit();
    // Signed out with no key: the current automatic set is codex alone.
    try environment.put("HOME", "/nonexistent-upgrade-provider-test-home");
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const init: std.process.Init = .{ .minimal = .{ .args = .{ .vector = &.{} }, .environ = .empty }, .arena = &arena, .gpa = gpa, .io = std.testing.io, .environ_map = &environment, .preopens = .empty };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var host = try tmp.dir.createDirPathOpen(init.io, "host", .{ .permissions = .fromMode(0o700) });
    defer host.close(init.io);
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = root[0..try host.realPath(init.io, &root)];
    const without = try std.fmt.allocPrint(arena.allocator(), "{s}/without.json", .{dir});
    const with = try std.fmt.allocPrint(arena.allocator(), "{s}/with.json", .{dir});
    try host.writeFile(init.io, .{ .sub_path = "without.json", .data = "{\"execution\":{\"activeCapacity\":2}}" });
    try host.writeFile(init.io, .{ .sub_path = "with.json", .data = "{\"providers\":{\"openai\":{}}}" });
    for ([_][]const u8{ "without.json", "with.json" }) |name| try host.setFilePermissions(init.io, name, .fromMode(0o600), .{});
    const Served = struct { codex: bool = false, openai: bool = false, chatgpt: bool = false };
    // Each `served` is what the old Host served: a flag-only fill started
    // from no providers, and a document without `providers` served every
    // built-in entry; named providers added to either.
    const Case = struct { argv: []const []const u8, previous: bool, served: Served };
    for ([_]Case{
        .{ .argv = &.{ "rui", "host", "serve", "--store", dir }, .previous = true, .served = .{} },
        .{ .argv = &.{ "rui", "host", "serve", "--store", dir, "--active-capacity", "3" }, .previous = true, .served = .{} },
        .{ .argv = &.{ "rui", "host", "serve", "--store", dir, "--provider", "codex", "--provider", "chatgpt", "--active-capacity", "3" }, .previous = true, .served = .{ .codex = true, .chatgpt = true } },
        .{ .argv = &.{ "rui", "host", "serve", "--store", dir, "--provider-endpoint", "http://127.0.0.1:9/responses" }, .previous = true, .served = .{ .codex = true } },
        .{ .argv = &.{ "rui", "host", "serve", "--store", dir, "--settings", without }, .previous = true, .served = .{ .codex = true, .openai = true, .chatgpt = true } },
        .{ .argv = &.{ "rui", "host", "serve", "--store", dir, "--settings", without, "--provider", "codex" }, .previous = true, .served = .{ .codex = true, .openai = true, .chatgpt = true } },
        .{ .argv = &.{ "rui", "host", "serve", "--store", dir, "--settings", with }, .previous = true, .served = .{ .openai = true } },
        .{ .argv = &.{ "rui", "host", "serve", "--store", dir, "--settings", with, "--provider", "chatgpt" }, .previous = true, .served = .{ .openai = true, .chatgpt = true } },
        // This release's Host with unset providers keeps the current default.
        .{ .argv = &.{ "rui", "host", "serve", "--store", dir }, .previous = false, .served = .{ .codex = true } },
        .{ .argv = &.{ "rui", "host", "serve", "--store", dir, "--settings", without }, .previous = false, .served = .{ .codex = true } },
        .{ .argv = &.{ "rui", "host", "serve", "--store", dir, "--set", "providers.chatgpt={}" }, .previous = false, .served = .{ .chatgpt = true } },
    }) |case| {
        const running = try @import("serve_grammar.zig").runningSources(arena.allocator(), case.argv);
        const request = try restartSources(init, arena.allocator(), .{ .dir = dir, .settings_file = running.settings_file, .assignments = running.assignments }, case.previous, 7);
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(gpa);
        try args.appendSlice(gpa, &.{ "--store", request.dir });
        if (request.settings_file) |file| try args.appendSlice(gpa, &.{ "--settings", file });
        for (request.assignments) |value| try args.appendSlice(gpa, &.{ "--set", value });
        var problem: cli_args.Refusal = undefined;
        const parsed = try cli_args.Command.host_serve.definition().parse(args.items, arena.allocator(), &problem);
        const settings = try gpa.create(@import("host_settings.zig").Settings);
        defer gpa.destroy(settings);
        settings.* = .{};
        defer settings.deinit();
        var fixtures: @import("providers.zig").Fixtures = .{};
        var failure: @import("start_report.zig").Failure = undefined;
        try fillAt(init, &parsed, dir, settings, &fixtures, &failure);
        try std.testing.expectEqual(@as(usize, 7), settings.execution.active_capacity.value);
        const entries = settings.providers.entries;
        try std.testing.expectEqual(case.served, Served{ .codex = entries.codex != null, .openai = entries.openai != null, .chatgpt = entries.chatgpt != null });
    }
}
