//! One server's `subscriptions/listen` exchange: the HTTP stream and the reader that turns its events into
//! `listen.Event`s. The cell is heap-owned by the listen shell (`server_mcp_listen.zig`): its Exchange is over
//! 16 KiB, too large for a frame. An event longer than `event_bytes` counts as a dropped stream.

const std = @import("std");
const Exchange = @import("../http1/Exchange.zig");
const http1 = @import("../http1/request.zig");
const EventStream = @import("EventStream.zig");
const post = @import("post.zig");
const reply = @import("reply.zig");
const listen = @import("listen.zig");
const Connection = @import("../server_mcp_settings.zig").Server;

const Subscription = @This();

pub const request_bytes = 2048;
pub const event_bytes = 4096;

const Reading = enum { head, events, whole };

exchange: Exchange,
/// The subscribe request's bytes; the exchange sends from here, so the cell must not move.
request: [request_bytes]u8,
id: u64,
reading: Reading,
status: u16,
stream: EventStream,
/// One event's data while it is read, or a whole non-stream body while it is read.
event: std.Io.Writer,
event_buffer: [event_bytes]u8,
/// Body bytes already read from the exchange and not yet consumed by the event reader.
rest: []const u8,

/// Opens the subscription `id` to `server`. Null when the request cannot be built or the connection cannot start.
pub fn open(allocator: std.mem.Allocator, server: *const Connection, client: post.Client, id: u64) ?*Subscription {
    const target = http1.parseTarget(server.url.slice()) catch return null;
    const self = allocator.create(Subscription) catch return null;
    var writer: std.Io.Writer = .fixed(&self.request);
    post.writeListen(&writer, .{ .target = target, .bearer_token = server.bearer_token.slice(), .label = server.name.slice() }, client, id) catch {
        allocator.destroy(self);
        return null;
    };
    self.exchange.init(target, writer.buffered()) catch {
        allocator.destroy(self);
        return null;
    };
    self.id = id;
    self.reading = .head;
    self.status = 0;
    self.stream = .{};
    self.event = .fixed(&self.event_buffer);
    self.rest = &.{};
    return self;
}

/// Closes the exchange and frees the cell. The cell must have been made by `open` with the same allocator.
pub fn close(self: *Subscription, allocator: std.mem.Allocator) void {
    self.exchange.deinit();
    allocator.destroy(self);
}

/// The next domain event, or null while nothing complete has arrived. Never blocks. A stream that ends, fails,
/// sends a bad or over-long event, or answers with something other than an event stream or a refusal is `.dropped`.
pub fn advance(self: *Subscription) ?listen.Event {
    return self.next() catch .dropped;
}

fn next(self: *Subscription) !?listen.Event {
    while (true) {
        if (self.rest.len != 0) {
            const step = try self.stream.next(self.rest, &self.event);
            self.rest = self.rest[step.used..];
            if (step.dispatched) {
                const event = reply.readNotice(self.event.buffered(), self.id) catch return error.BadEvent;
                self.event.end = 0;
                return event;
            }
            continue;
        }
        switch (try self.exchange.advance()) {
            .waiting => return null,
            .head => |head| {
                self.status = head.status;
                const kind = head.field("Content-Type") orelse "";
                self.reading = if (head.status == 200 and std.mem.startsWith(u8, kind, "text/event-stream")) .events else .whole;
            },
            .body => |bytes| switch (self.reading) {
                .head => return error.BadEvent,
                .events => self.rest = bytes,
                .whole => {
                    // A refusal's body is read whole for its JSON-RPC code; the bytes past the buffer are not needed.
                    const room = self.event.unusedCapacityLen();
                    self.event.writeAll(bytes[0..@min(room, bytes.len)]) catch unreachable;
                },
            },
            .end => return if (self.reading == .whole) self.wholeEnded() else error.Ended,
        }
    }
}

/// Reads a non-stream body's answer once it has ended: a refusal, by status or JSON-RPC code. A 2xx body that
/// names no refusal is not a stream and is dropped.
pub fn wholeEnded(self: *Subscription) listen.Event {
    const rpc: ?i64 = if (reply.readNotice(self.event.buffered(), self.id)) |event| switch (event) {
        .refused => |refusal| refusal.rpc_code,
        else => null,
    } else |_| null;
    if (self.status < 400 and rpc == null) return .dropped;
    return .{ .refused = .{ .status = if (self.status >= 400) self.status else null, .rpc_code = rpc } };
}
