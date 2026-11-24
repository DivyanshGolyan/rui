//! Every server's `subscriptions/listen` stream, owned by the re-list owner on the execution thread. The pure
//! rules are `mcp/listen.zig`; this shell owns the transport cells and applies the core's effects. Its only
//! output is the set of servers to list again: it never touches a slot, the Store or the tool set.

const std = @import("std");
const hs = @import("host_settings.zig");
const listen = @import("mcp/listen.zig");
const relist = @import("mcp/relist.zig");
const offered = @import("mcp/offered.zig");
const Subscription = @import("mcp/Subscription.zig");
const server_mcp_settings = @import("server_mcp_settings.zig");

pub const Listen = struct {
    pub const Asked = std.StaticBitSet(hs.max_mcp_servers);

    allocator: std.mem.Allocator,
    servers: []const server_mcp_settings.Server,
    seed: u64,
    lines: [hs.max_mcp_servers]listen.Line = @splat(.{}),
    cells: [hs.max_mcp_servers]?*Subscription = @splat(null),

    pub fn init(allocator: std.mem.Allocator, servers: []const server_mcp_settings.Server, seed: u64) Listen {
        return .{ .allocator = allocator, .servers = servers, .seed = seed };
    }

    /// Closes every open stream: a client cancel is a close.
    pub fn deinit(self: *Listen) void {
        for (&self.cells) |*cell| {
            if (cell.*) |open| open.close(self.allocator);
            cell.* = null;
        }
    }

    /// Drains each open stream into its line, closes the streams the line no longer holds, and opens every closed
    /// line that is due. Returns the servers to list again, one per acknowledgment or list-change notice.
    pub fn service(self: *Listen, now_ms: u64) Asked {
        var asked: Asked = .empty;
        for (0..self.servers.len) |index| {
            while (self.cells[index]) |cell| {
                const event = cell.advance() orelse break;
                if (self.lines[index].step(event, now_ms, self.seedFor(index, now_ms))) asked.set(index);
                self.settleCell(index);
            }
            if (self.cells[index] != null and self.lines[index].wakeAt() != null and now_ms >= self.lines[index].wakeAt().?) {
                _ = self.lines[index].step(.timed_out, now_ms, self.seedFor(index, now_ms));
                self.settleCell(index);
            }
            if (self.cells[index] == null and self.lines[index].due(now_ms)) {
                const id = self.lines[index].begin(now_ms);
                self.cells[index] = Subscription.open(self.allocator, &self.servers[index], offered.client, id);
                if (self.cells[index] == null) {
                    _ = self.lines[index].step(.dropped, now_ms, self.seedFor(index, now_ms));
                    self.settleCell(index);
                }
            }
        }
        return asked;
    }

    /// The earliest time a closed or opening line needs service again, or null.
    pub fn wakeAt(self: *const Listen) ?u64 {
        var earliest: ?u64 = null;
        for (self.lines[0..self.servers.len]) |*line| {
            const at = line.wakeAt() orelse continue;
            earliest = if (earliest) |current| @min(current, at) else at;
        }
        return earliest;
    }

    /// A client asked for this server again: a refusing server is probed once more.
    pub fn reprobe(self: *Listen, index: usize) void {
        self.lines[index].reprobe();
    }

    pub fn state(self: *const Listen, index: usize) listen.State {
        return self.lines[index].state;
    }

    /// Closes the cell once its line no longer holds a stream.
    fn settleCell(self: *Listen, index: usize) void {
        if (self.lines[index].holdsStream()) return;
        if (self.cells[index]) |open| open.close(self.allocator);
        self.cells[index] = null;
    }

    fn seedFor(self: *const Listen, index: usize, now_ms: u64) u64 {
        return relist.mix(self.seed, index, self.lines[index].opens, now_ms);
    }
};
