const std = @import("std");
const provider_route = @import("provider_route.zig");
const connection = @import("connection.zig");
const connection_names = @import("connection_names.zig");
const model_list = @import("model_list.zig");
const providers_module = @import("providers.zig");
const stderr = @import("stderr.zig");
const Self = @This();

io: std.Io = undefined,
allocator: std.mem.Allocator = undefined,
providers: *const providers_module.Providers = &providers_module.none,
mutex: std.Io.Mutex = .init,
/// One list per served connection that has been given one; a served name without an entry shows the catalog.
live: connection_names.NameArray(model_list.List) = .{},
/// Set by the intake side when a client asks for the lists; taken once by the execution thread.
asked: std.atomic.Value(bool) = .init(false),

pub fn init(io: std.Io, allocator: std.mem.Allocator, providers: *const providers_module.Providers) Self {
    var lists: Self = .{ .io = io, .allocator = allocator, .providers = providers };
    for (providers.table.names[0..providers.table.len], 0..) |name, index| {
        if (providers.liveListAt(index) != null) lists.live.set(name, .pending) catch unreachable;
    }
    return lists;
}

pub fn deinit(self: *Self) void {
    for (self.live.values[0..self.live.len]) |list| switch (list) {
        .live => |ids| self.allocator.free(ids.bytes),
        .catalog, .pending, .catalog_fallback => {},
    };
    self.* = .{};
}

/// The connection's current list: the catalog for a served name that has none of its own.
pub fn get(self: *Self, name: connection.Name) model_list.List {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.live.get(name) orelse .catalog;
}

pub fn set(self: *Self, name: connection.Name, list: model_list.List) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (self.live.findMut(name)) |old| switch (old.*) {
        .live => |ids| self.allocator.free(ids.bytes),
        else => {},
    };
    self.live.set(name, list) catch unreachable;
}

pub fn publish(self: *Self, name: connection.Name, body: anyerror![]const u8) void {
    const served = self.providers.liveList(name).?;
    const list: model_list.List = if (keep(self.allocator, served.credential.listing().?, body)) |bytes| .{ .live = .{ .bytes = bytes } } else |err| failed: {
        stderr.print("rui: {s} model list unavailable ({s}); the picker shows Rui's models\n", .{ if (served.label.len != 0) served.label else name.slice(), @errorName(err) });
        break :failed .catalog_fallback;
    };
    self.set(name, list);
}

noinline fn keep(allocator: std.mem.Allocator, listing: providers_module.Listing, body: anyerror![]const u8) ![]const u8 {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const ids = try arena.allocator().create(model_list.IdBuffer);
    const parsed = try listing.parse(arena.allocator(), try body, ids);
    return allocator.dupe(u8, parsed.bytes);
}

pub fn render(self: *Self, out: *std.Io.Writer, facts: []const @import("model_catalog.zig").Entry) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var entries: [connection.max_served]model_list.Entry = undefined;
    for (self.providers.table.names[0..self.providers.table.len], entries[0..self.providers.table.len]) |name, *entry| {
        entry.* = .{ .provider = name, .list = self.live.get(name) orelse .catalog };
    }
    try model_list.writeProviders(out, facts, entries[0..self.providers.table.len]);
}

pub fn ask(self: *Self) void {
    self.asked.store(true, .release);
}

pub fn takeAsk(self: *Self) bool {
    return self.asked.swap(false, .acq_rel);
}

test "EXR-100 each connection's model list is published and rendered on its own" {
    const catalog = @import("model_catalog.zig");
    const codex = provider_route.nameOf(.codex);
    const openai = provider_route.nameOf(.openai);
    const chatgpt = provider_route.nameOf(.chatgpt);
    const alpha = connection.Name.parse("alpha").?;
    const beta = connection.Name.parse("beta").?;
    var served: providers_module.Providers = .{};
    served.table.set(codex, .{ .endpoint = providers_module.endpoint(.codex), .credential = .{ .chatgpt_device = .{ .path = "/c" } } }) catch unreachable;
    served.table.set(openai, .{ .endpoint = providers_module.endpoint(.openai), .credential = .{ .key_file = .{ .key = "sk-test" } }, .live_list = true }) catch unreachable;
    served.table.set(chatgpt, .{ .endpoint = providers_module.endpoint(.chatgpt), .credential = .{ .chatgpt_plan = .{ .path = "/p" } }, .live_list = true }) catch unreachable;
    served.table.set(alpha, .{ .endpoint = "https://alpha.example/v1/responses", .credential = .{ .key_file = .{ .key = "sk-alpha" } }, .live_list = true }) catch unreachable;
    served.table.set(beta, .{ .endpoint = "https://beta.example/v1/responses", .credential = .{ .key_file = .{ .key = "sk-beta" } } }) catch unreachable;
    var lists: Self = .init(std.testing.io, std.testing.allocator, &served);
    defer lists.deinit();
    const facts: []const catalog.Entry = &.{.{ .id = "gpt-6-sol", .context_window = null, .efforts = .{}, .openai_listed = true }};
    var bytes: [8192]u8 = undefined;
    var out = std.Io.Writer.fixed(&bytes);
    try lists.render(&out, facts);
    const sol = "\"models\":[{\"id\":\"gpt-6-sol\",\"known\":true}]}";
    try std.testing.expectEqualStrings(
        "[{\"connection\":\"codex\",\"source\":\"catalog\"," ++ sol ++ "," ++
            "{\"connection\":\"openai\",\"source\":\"pending\"," ++ sol ++ "," ++
            "{\"connection\":\"chatgpt\",\"source\":\"pending\"," ++ sol ++ "," ++
            "{\"connection\":\"alpha\",\"source\":\"pending\"," ++ sol ++ "," ++
            "{\"connection\":\"beta\",\"source\":\"catalog\"," ++ sol ++ "]",
        out.buffered(),
    );
    lists.publish(chatgpt, "{\"models\":[{\"slug\":\"gpt-6-terra\",\"visibility\":\"list\"},{\"slug\":\"secret\",\"visibility\":\"hide\"},{\"slug\":\"gpt-6-sol\",\"visibility\":\"list\"}]}");
    lists.publish(openai, error.ListingRefused);
    lists.publish(alpha, "{\"data\":[{\"id\":\"gpt-6-sol\"},{\"id\":\"alpha-only\"}]}");
    out = std.Io.Writer.fixed(&bytes);
    try lists.render(&out, facts);
    try std.testing.expectEqualStrings(
        "[{\"connection\":\"codex\",\"source\":\"catalog\"," ++ sol ++ "," ++
            "{\"connection\":\"openai\",\"source\":\"catalog_fallback\"," ++ sol ++ "," ++
            "{\"connection\":\"chatgpt\",\"source\":\"live\",\"models\":[{\"id\":\"gpt-6-terra\",\"known\":false},{\"id\":\"gpt-6-sol\",\"known\":true}]}," ++
            "{\"connection\":\"alpha\",\"source\":\"live\",\"models\":[{\"id\":\"gpt-6-sol\",\"known\":true},{\"id\":\"alpha-only\",\"known\":false}]}," ++
            "{\"connection\":\"beta\",\"source\":\"catalog\"," ++ sol ++ "]",
        out.buffered(),
    );
    lists.publish(chatgpt, "{\"data\":[{\"id\":\"gpt-6-luna\"}]}");
    try std.testing.expect(lists.get(chatgpt) == .catalog_fallback);
    lists.publish(openai, "{\"data\":[{\"id\":\"gpt-6-luna\"}]}");
    lists.publish(openai, "{\"data\":[{\"id\":\"gpt-6-mare\"}]}");
    try std.testing.expectEqualStrings("gpt-6-mare\n", lists.get(openai).live.bytes);
    try std.testing.expect(lists.get(codex) == .catalog);
    try std.testing.expect(lists.get(beta) == .catalog);
    try std.testing.expectEqualStrings("gpt-6-sol\nalpha-only\n", lists.get(alpha).live.bytes);
}

test "EXR-100 model-list asks before one take fold into one true take" {
    var lists: Self = .init(std.testing.io, std.testing.allocator, &providers_module.none);
    defer lists.deinit();
    try std.testing.expect(!lists.takeAsk());
    lists.ask();
    lists.ask();
    try std.testing.expect(lists.takeAsk());
    try std.testing.expect(!lists.takeAsk());
}
