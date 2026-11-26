const std = @import("std");
const c = @import("h2_c");

const policy = @import("policy.zig");
const liveness = @import("liveness.zig");
const Record = @import("Stream.zig");
const Engine = @import("Engine.zig");
const Origin = @import("Origin.zig");
const tls_client = @import("tls_client");
const url_value = @import("url");

/// Loopback fixtures share the transport's existing peer and wire counters.
pub const testing = if (@import("builtin").is_test) struct {
    pub const Peer = @import("testing/Peer.zig");
} else struct {};

pub const test_access = if (@import("builtin").is_test) struct {
    pub fn engineOf(client: *Client) *Engine {
        return engine(client);
    }

    pub fn recordOf(stream: *Stream) *Record {
        return record(stream);
    }
} else struct {};

pub const nghttp2_version = "1.71.0";
pub const openssl_version = "3.6.5";

pub const max_url_bytes = url_value.max_url_bytes;
pub const max_host_bytes = url_value.max_host_bytes;
/// The most endpoints one client holds: a served connection each (16 at most, `connection.max_served`),
/// that connection's model listing each (16 more) and the models.dev catalog (1).
/// provider.Reactor checks that this covers the served set and every listing slot.
pub const max_endpoints = 33;
pub const max_fields = 16;
pub const owned_fields = [_][]const u8{ "content-length", "accept-encoding", "connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade", "te", "host" };
pub const max_field_block_bytes = 64 * 1024;
pub const stream_window_bytes: u31 = 16 * 1024;
pub const read_buffer_bytes = 16 * 1024;
pub const read_allowance_bytes = 64 * 1024;

pub fn checkLibraries() error{UnexpectedLibraryVersion}!void {
    const nghttp2: *const c.nghttp2_info = c.nghttp2_version(0) orelse return error.UnexpectedLibraryVersion;
    if (!std.mem.eql(u8, std.mem.span(nghttp2.version_str), nghttp2_version)) return error.UnexpectedLibraryVersion;
    const linked = tls_client.c.OpenSSL_version(tls_client.c.OPENSSL_VERSION_STRING) orelse return error.UnexpectedLibraryVersion;
    if (!std.mem.eql(u8, std.mem.span(linked), openssl_version)) return error.UnexpectedLibraryVersion;
}

pub const UrlError = url_value.UrlError;
pub const Scheme = url_value.Scheme;
pub const Url = url_value.Url;
pub const parseUrl = url_value.parseUrl;
pub const parseHostPort = url_value.parseHostPort;

pub const Endpoint = enum(u8) { _ };

pub const Liveness = liveness.Liveness;

pub const Trust = tls_client.Trust;

pub const Options = struct {
    stream_capacity: u32,
    inactivity_ns: u64,
    connect_timeout_ns: u64,
    liveness: Liveness = .{},
    trust: Trust = .system,
    proxy: ?Proxy = null,
};

pub const Proxy = struct {
    url: []const u8,
    no_proxy: []const u8 = "",
};

pub fn proxyFromEnvironment() ?Proxy {
    return proxyFrom(std.c.getenv);
}

pub fn checkProxy(allocator: std.mem.Allocator, proxy: Proxy) InitError!void {
    var route = try Origin.Route.init(allocator, proxy);
    route.deinit(allocator);
}

fn proxyFrom(comptime lookup: fn ([*:0]const u8) callconv(.c) ?[*:0]u8) ?Proxy {
    return .{
        .url = environmentSetting(lookup, tls_client.environment.https_proxy) orelse return null,
        .no_proxy = environmentSetting(lookup, tls_client.environment.no_proxy) orelse "",
    };
}

fn environmentSetting(comptime lookup: anytype, names: [2][:0]const u8) ?[]const u8 {
    const value = std.mem.span(lookup(names[0]) orelse lookup(names[1]) orelse return null);
    return if (value.len > 0) value else null;
}

test "a set lowercase proxy variable decides, even empty" {
    const Environment = struct {
        var https_proxy: ?[:0]const u8 = null;
        var no_proxy: ?[:0]const u8 = null;
        fn lookup(name: [*:0]const u8) callconv(.c) ?[*:0]u8 {
            const value = if (std.mem.eql(u8, std.mem.span(name), "https_proxy"))
                https_proxy
            else if (std.mem.eql(u8, std.mem.span(name), "HTTPS_PROXY"))
                "http://upper:1"
            else if (std.mem.eql(u8, std.mem.span(name), "no_proxy"))
                no_proxy
            else
                "upper.example";
            return @constCast(if (value) |text| text.ptr else null);
        }
    };
    try std.testing.expectEqualStrings("http://upper:1", proxyFrom(Environment.lookup).?.url);
    try std.testing.expectEqualStrings("upper.example", proxyFrom(Environment.lookup).?.no_proxy);
    Environment.https_proxy = "http://lower:1";
    Environment.no_proxy = "";
    try std.testing.expectEqualStrings("http://lower:1", proxyFrom(Environment.lookup).?.url);
    try std.testing.expectEqualStrings("", proxyFrom(Environment.lookup).?.no_proxy);
    Environment.https_proxy = "";
    try std.testing.expectEqual(@as(?Proxy, null), proxyFrom(Environment.lookup));
}

pub const Field = struct {
    name: []const u8,
    value: []const u8,
    sensitive: bool = false,
    borrowed: bool = false,
};

pub const Body = union(enum) {
    file: struct { handle: std.posix.fd_t, length: u64 },
    bytes: []const u8,
};

pub const Sink = union(enum) {
    file: std.posix.fd_t,
    buffer: []u8,
};

pub const Method = enum { post, get };

pub const Request = struct {
    endpoint: Endpoint,
    method: Method = .post,
    fields: []const Field,
    body: Body,
    sink: Sink,
};

pub const Event = union(enum) {
    head: Head,
    body: usize,
    body_retired,
};

pub const Head = struct {
    kind: enum(u8) {
        interim,
        final,
        trailers,
    },
    status: u16,
    fields: []const Field,
};

pub const Verdict = enum { accept, refuse };

pub const Cause = policy.Cause;

pub const End = struct {
    cause: Cause,
    request_sent: bool,
};

pub const Stream = extern struct {
    storage: [Record.size]u8 align(Record.alignment) = @splat(0),

    pub const idle: Stream = .{};

    pub fn deinit(self: *Stream) void {
        const rec = record(self);
        std.debug.assert(rec.state == .idle or rec.state == .collected or rec.state == .cancelled);
        std.debug.assert(rec.fields == null);
        self.* = .idle;
    }

    pub fn status(self: *const Stream) ?u16 {
        const rec = recordConst(self);
        return if (rec.flags.final_seen) rec.status else null;
    }

    pub fn end(self: *const Stream) ?End {
        const rec = recordConst(self);
        if (rec.state != .finished and rec.state != .collected) return null;
        return .{ .cause = rec.cause.?, .request_sent = rec.flags.request_sent };
    }

    pub fn responseLength(self: *const Stream) u64 {
        return recordConst(self).sink_written;
    }

    pub fn openedConnection(self: *const Stream) bool {
        return recordConst(self).flags.opened_connection;
    }

    pub fn replays(self: *const Stream) u8 {
        return recordConst(self).flags.replays;
    }
};

pub const InitError = error{ OutOfMemory, SystemResources, HttpsProxyInvalid, HttpsProxySchemeUnsupported };
pub const EndpointError = UrlError || tls_client.TrustError || error{ OutOfMemory, TooManyEndpoints };
pub const PrepareError = error{ OutOfMemory, InvalidRequest };
pub const DriveError = error{PollFailed};

fn engine(client: *Client) *Engine {
    return @ptrCast(client);
}

fn engineConst(client: *const Client) *const Engine {
    return @ptrCast(client);
}

fn record(stream: *Stream) *Record {
    return @ptrCast(stream);
}

fn recordConst(stream: *const Stream) *const Record {
    return @ptrCast(stream);
}

fn public(r: *Record) *Stream {
    return @ptrCast(r);
}

pub const Client = extern struct {
    storage: [Engine.size]u8 align(Engine.alignment),

    pub fn init(self: *Client, allocator: std.mem.Allocator, io: std.Io, options: Options) InitError!void {
        return engine(self).init(allocator, io, options);
    }

    pub fn deinit(self: *Client) void {
        engine(self).deinit();
    }

    pub fn addEndpoint(self: *Client, url: []const u8) EndpointError!Endpoint {
        return engine(self).addEndpoint(url);
    }

    pub fn prepare(self: *Client, stream: *Stream, request: Request) PrepareError!void {
        return engine(self).prepare(record(stream), request);
    }

    pub fn launch(self: *Client, stream: *Stream) void {
        engine(self).launch(record(stream));
    }

    pub fn cancel(self: *Client, stream: *Stream) void {
        engine(self).cancel(record(stream));
    }

    pub fn drive(self: *Client, receiver: anytype) DriveError!void {
        const R = @typeInfo(@TypeOf(receiver)).pointer.child;
        if (!@hasDecl(R, "observe")) @compileError(@typeName(R) ++ " is not an h2 receiver");
        return engine(self).drive(.{
            .context = receiver,
            .observe = struct {
                fn observe(context: *anyopaque, rec: *Record, event: Event) Verdict {
                    const typed: *R = @ptrCast(@alignCast(context));
                    return typed.observe(public(rec), event);
                }
            }.observe,
        });
    }

    pub fn wait(self: *Client, timeout_ms: u32) DriveError!void {
        return engine(self).wait(timeout_ms);
    }

    pub fn armWait(self: *Client, timeout_ms: u32) Armed {
        return engine(self).armWait(timeout_ms);
    }

    pub const Armed = Engine.Armed;

    pub fn wake(self: *Client) void {
        engine(self).wake();
    }

    pub fn nextFinished(self: *Client) ?*Stream {
        const rec = engine(self).nextFinished() orelse return null;
        return public(rec);
    }

    pub fn finishedCount(self: *const Client) usize {
        return engineConst(self).finishedCount();
    }

    pub fn retireConnections(self: *Client, endpoint: Endpoint) void {
        engine(self).retireConnections(endpoint);
    }

    pub fn hasConnections(self: *const Client) bool {
        return engineConst(self).hasConnections();
    }
};

pub const Exchange = struct {
    url: []const u8,
    fields: []const Field,
    body: []const u8,
    response: []u8,
    trust: Trust = .system,
    proxy: ?Proxy = null,
    connect_timeout_ns: u64,
    total_timeout_ns: u64,
    cancelled: ?*const fn () bool = null,
};

pub const ExchangeOutcome = union(enum) {
    answered: struct { status: u16, body: []const u8 },
    failed: End,
    timed_out: struct { request_sent: bool },
};

pub const ExchangeError = InitError || EndpointError || PrepareError || DriveError || error{Interrupted};

pub fn exchange(io: std.Io, request: Exchange) ExchangeError!ExchangeOutcome {
    const started = std.Io.Clock.awake.now(io).nanoseconds;
    if (request.cancelled) |cancelled| if (cancelled()) return error.Interrupted;
    var client: Client = undefined;
    try client.init(std.heap.page_allocator, io, .{
        .stream_capacity = 1,
        .inactivity_ns = request.total_timeout_ns +| std.time.ns_per_s,
        .connect_timeout_ns = request.connect_timeout_ns,
        .trust = request.trust,
        .proxy = request.proxy,
    });
    defer client.deinit();
    const endpoint = try client.addEndpoint(request.url);
    var stream: Stream = .idle;
    try client.prepare(&stream, .{
        .endpoint = endpoint,
        .fields = request.fields,
        .body = .{ .bytes = request.body },
        .sink = .{ .buffer = request.response },
    });
    defer {
        client.cancel(&stream);
        stream.deinit();
    }
    client.launch(&stream);
    var receiver: AcceptAll = .{};
    while (true) {
        try client.drive(&receiver);
        if (client.nextFinished()) |_| {
            const end = stream.end().?;
            if (end.cause != .complete) return .{ .failed = end };
            return .{ .answered = .{ .status = stream.status().?, .body = request.response[0..@intCast(stream.responseLength())] } };
        }
        if (request.cancelled) |cancelled| if (cancelled()) return error.Interrupted;
        const elapsed: u64 = @intCast(std.Io.Clock.awake.now(io).nanoseconds - started);
        if (elapsed >= request.total_timeout_ns)
            return .{ .timed_out = .{ .request_sent = record(&stream).flags.request_sent } };
        const remaining_ms = std.math.divCeil(u64, request.total_timeout_ns - elapsed, std.time.ns_per_ms) catch unreachable;
        try client.wait(@intCast(@min(remaining_ms, 100)));
    }
}

const AcceptAll = struct {
    pub fn observe(_: *AcceptAll, _: *Stream, _: Event) Verdict {
        return .accept;
    }
};

test "the linked libraries are the pinned versions" {
    try checkLibraries();
}

test {
    _ = policy;
    _ = @import("dial_policy.zig");
    _ = @import("liveness.zig");
    _ = Record;
    _ = Engine;
    _ = @import("Resolver.zig");
    _ = @import("proxy.zig");
    _ = @import("tls.zig");
    _ = @import("tests.zig");
    _ = @import("fault_tests.zig");
    _ = @import("testing/Faults.zig");
}
