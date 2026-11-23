const std = @import("std");
const c = @import("h2_c");

const policy = @import("policy.zig");
const Record = @import("Stream.zig");
const Engine = @import("Engine.zig");
const tls_client = @import("tls_client");
const url_value = @import("url");

/// Loopback fixtures share the transport's existing peer and wire counters.
pub const testing = if (@import("builtin").is_test) struct {
    pub const Peer = @import("testing/Peer.zig");
} else struct {};

pub const nghttp2_version = "1.71.0";
pub const openssl_version = "3.6.5";

pub const max_url_bytes = url_value.max_url_bytes;
pub const max_host_bytes = url_value.max_host_bytes;
pub const max_endpoints = 6;
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

pub const Liveness = policy.Liveness;

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
    var route = try Engine.ProxyRoute.init(allocator, proxy);
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
        const record = Record.of(self);
        std.debug.assert(record.state == .idle or record.state == .collected or record.state == .cancelled);
        std.debug.assert(record.fields == null);
        self.* = .idle;
    }

    pub fn status(self: *const Stream) ?u16 {
        const record = Record.ofConst(self);
        return if (record.flags.final_seen) record.status else null;
    }

    pub fn end(self: *const Stream) ?End {
        const record = Record.ofConst(self);
        if (record.state != .finished and record.state != .collected) return null;
        return .{ .cause = record.cause.?, .request_sent = record.flags.request_sent };
    }

    pub fn responseLength(self: *const Stream) u64 {
        return Record.ofConst(self).sink_written;
    }

    pub fn openedConnection(self: *const Stream) bool {
        return Record.ofConst(self).flags.opened_connection;
    }

    pub fn replays(self: *const Stream) u8 {
        return Record.ofConst(self).flags.replays;
    }
};

pub const InitError = error{ OutOfMemory, SystemResources, HttpsProxyInvalid, HttpsProxySchemeUnsupported };
pub const EndpointError = UrlError || tls_client.TrustError || error{ OutOfMemory, TooManyEndpoints };
pub const PrepareError = error{ OutOfMemory, InvalidRequest };
pub const DriveError = error{PollFailed};

pub const Client = extern struct {
    storage: [Engine.size]u8 align(Engine.alignment),

    pub fn init(self: *Client, allocator: std.mem.Allocator, io: std.Io, options: Options) InitError!void {
        return Engine.of(self).init(allocator, io, options);
    }

    pub fn deinit(self: *Client) void {
        Engine.of(self).deinit();
    }

    pub fn addEndpoint(self: *Client, url: []const u8) EndpointError!Endpoint {
        return Engine.of(self).addEndpoint(url);
    }

    pub fn prepare(self: *Client, stream: *Stream, request: Request) PrepareError!void {
        return Engine.of(self).prepare(Record.of(stream), request);
    }

    pub fn launch(self: *Client, stream: *Stream) void {
        Engine.of(self).launch(Record.of(stream));
    }

    pub fn cancel(self: *Client, stream: *Stream) void {
        Engine.of(self).cancel(Record.of(stream));
    }

    pub fn drive(self: *Client, receiver: anytype) DriveError!void {
        const R = @typeInfo(@TypeOf(receiver)).pointer.child;
        if (!@hasDecl(R, "observe")) @compileError(@typeName(R) ++ " is not an h2 receiver");
        return Engine.of(self).drive(.{
            .context = receiver,
            .observe = struct {
                fn observe(context: *anyopaque, stream: *Stream, event: Event) Verdict {
                    const typed: *R = @ptrCast(@alignCast(context));
                    return typed.observe(stream, event);
                }
            }.observe,
        });
    }

    pub fn wait(self: *Client, timeout_ms: u32) DriveError!void {
        return Engine.of(self).wait(timeout_ms);
    }

    pub fn armWait(self: *Client, timeout_ms: u32) Armed {
        return Engine.of(self).armWait(timeout_ms);
    }

    pub const Armed = Engine.Armed;

    pub fn wake(self: *Client) void {
        Engine.of(self).waker.wake();
    }

    pub fn nextFinished(self: *Client) ?*Stream {
        return Engine.of(self).nextFinished();
    }

    pub fn finishedCount(self: *const Client) usize {
        return Engine.ofConst(self).finished_count;
    }

    pub fn retireConnections(self: *Client, endpoint: Endpoint) void {
        Engine.of(self).retireConnections(endpoint);
    }

    pub fn hasConnections(self: *const Client) bool {
        return Engine.ofConst(self).connections_len > 0;
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
            return .{ .timed_out = .{ .request_sent = Record.of(&stream).flags.request_sent } };
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
    _ = Record;
    _ = Engine;
    _ = @import("Resolver.zig");
    _ = @import("proxy.zig");
    _ = @import("tls.zig");
    _ = @import("tests.zig");
    _ = @import("fault_tests.zig");
    _ = @import("testing/Faults.zig");
}
