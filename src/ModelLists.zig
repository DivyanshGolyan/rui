const std = @import("std");
const protocol = @import("protocol.zig");
const model_list = @import("model_list.zig");
const providers_module = @import("providers.zig");
const stderr = @import("stderr.zig");
const Self = @This();

io: std.Io = undefined,
allocator: std.mem.Allocator = undefined,
providers: *const providers_module.Providers = &providers_module.none,
mutex: std.Io.Mutex = .init,
live: std.EnumArray(protocol.Provider, model_list.List) = .initFill(.catalog),
/// Set by the intake side when a client asks for the lists; taken once by the execution thread.
asked: std.atomic.Value(bool) = .init(false),

pub fn init(io: std.Io, allocator: std.mem.Allocator, providers: *const providers_module.Providers) Self {
    var lists: Self = .{ .io = io, .allocator = allocator, .providers = providers };
    for (std.enums.values(protocol.Provider)) |name| {
        if (providers.liveList(name) != null) lists.live.set(name, .pending);
    }
    return lists;
}

pub fn deinit(self: *Self) void {
    for (self.live.values) |list| switch (list) {
        .live => |ids| self.allocator.free(ids.bytes),
        .catalog, .pending, .catalog_fallback => {},
    };
    self.* = .{};
}

pub fn set(self: *Self, name: protocol.Provider, list: model_list.List) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    switch (self.live.get(name)) {
        .live => |ids| self.allocator.free(ids.bytes),
        else => {},
    }
    self.live.set(name, list);
}

pub fn publish(self: *Self, name: protocol.Provider, body: anyerror![]const u8) void {
    const listing = self.providers.liveList(name).?.credential.listing().?;
    const list: model_list.List = if (keep(self.allocator, listing, body)) |bytes| .{ .live = .{ .bytes = bytes } } else |err| failed: {
        stderr.print("rui: {s} model list unavailable ({s}); the picker shows Rui's models\n", .{ name.shown(), @errorName(err) });
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
    var entries: [std.enums.values(protocol.Provider).len]model_list.Entry = undefined;
    var count: usize = 0;
    for (std.enums.values(protocol.Provider)) |name| {
        if (!self.providers.serves(name)) continue;
        entries[count] = .{ .provider = name, .list = self.live.get(name) };
        count += 1;
    }
    try model_list.writeProviders(out, facts, entries[0..count]);
}

pub fn ask(self: *Self) void {
    self.asked.store(true, .release);
}

pub fn takeAsk(self: *Self) bool {
    return self.asked.swap(false, .acq_rel);
}

test "EXR-100 each provider's model list is published and rendered on its own" {
    const catalog = @import("model_catalog.zig");
    var served: providers_module.Providers = .{};
    served.table.set(.codex, .{ .endpoint = providers_module.endpoint(.codex), .credential = .{ .chatgpt_device = .{ .path = "/c" } } });
    served.table.set(.openai, .{ .endpoint = providers_module.endpoint(.openai), .credential = .{ .key_file = .{ .key = "sk-test" } } });
    served.table.set(.chatgpt, .{ .endpoint = providers_module.endpoint(.chatgpt), .credential = .{ .chatgpt_plan = .{ .path = "/p" } } });
    var lists: Self = .init(std.testing.io, std.testing.allocator, &served);
    defer lists.deinit();
    const facts: []const catalog.Entry = &.{.{ .id = "gpt-6-sol", .context_window = null, .efforts = .{}, .openai_listed = true }};
    var bytes: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&bytes);
    try lists.render(&out, facts);
    try std.testing.expectEqualStrings(
        "[{\"provider\":\"codex\",\"source\":\"catalog\",\"models\":[{\"id\":\"gpt-6-sol\",\"known\":true}]}," ++
            "{\"provider\":\"openai\",\"source\":\"pending\",\"models\":[{\"id\":\"gpt-6-sol\",\"known\":true}]}," ++
            "{\"provider\":\"chatgpt\",\"source\":\"pending\",\"models\":[{\"id\":\"gpt-6-sol\",\"known\":true}]}]",
        out.buffered(),
    );
    lists.publish(.chatgpt, "{\"models\":[{\"slug\":\"gpt-6-terra\",\"visibility\":\"list\"},{\"slug\":\"secret\",\"visibility\":\"hide\"},{\"slug\":\"gpt-6-sol\",\"visibility\":\"list\"}]}");
    lists.publish(.openai, error.ListingRefused);
    out = std.Io.Writer.fixed(&bytes);
    try lists.render(&out, facts);
    try std.testing.expectEqualStrings(
        "[{\"provider\":\"codex\",\"source\":\"catalog\",\"models\":[{\"id\":\"gpt-6-sol\",\"known\":true}]}," ++
            "{\"provider\":\"openai\",\"source\":\"catalog_fallback\",\"models\":[{\"id\":\"gpt-6-sol\",\"known\":true}]}," ++
            "{\"provider\":\"chatgpt\",\"source\":\"live\",\"models\":[{\"id\":\"gpt-6-terra\",\"known\":false},{\"id\":\"gpt-6-sol\",\"known\":true}]}]",
        out.buffered(),
    );
    lists.publish(.chatgpt, "{\"data\":[{\"id\":\"gpt-6-luna\"}]}");
    try std.testing.expect(lists.live.get(.chatgpt) == .catalog_fallback);
    lists.publish(.openai, "{\"data\":[{\"id\":\"gpt-6-luna\"}]}");
    lists.publish(.openai, "{\"data\":[{\"id\":\"gpt-6-mare\"}]}");
    try std.testing.expectEqualStrings("gpt-6-mare\n", lists.live.get(.openai).live.bytes);
    try std.testing.expect(lists.live.get(.codex) == .catalog);
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
