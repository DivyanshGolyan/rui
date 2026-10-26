//! Rui's HTTP/2 client on nghttp2 and OpenSSL (issue #556).
//!
//! A self-contained build module: it imports nothing from Rui, and Rui
//! reaches it only as `@import("h2")`. A file belongs to one module, so a
//! path import of these files from Rui fails the build.
//!
//! Shape: a polled engine for one owner thread. The owner calls `drive` to
//! do all ready work and `wait` to block until there is some; nothing here
//! runs on its own. Other threads may only call `Client.wake`. `exchange`
//! is one blocking request on a private Client, for callers that send one
//! request at a time.
//!
//! What the engine owns, so its caller does not:
//! - one connection pool per origin, opening another connection only when
//!   the peer's SETTINGS_MAX_CONCURRENT_STREAMS is full, and draining a
//!   connection after GOAWAY;
//! - TLS with ALPN `h2` only, verified by the system's trust (the host's CA
//!   bundle on Linux, SecTrust on macOS) or against one CA file, and h2c
//!   by prior knowledge for loopback `http://`;
//! - name lookup, and SecTrust's evaluation, on short-lived threads;
//! - request bodies read from the caller's file within the peer's window,
//!   never copied into a buffer per request;
//! - response bodies written from the one shared read buffer straight to
//!   the caller's sink, one write per stream per socket read; a stream's
//!   receive window reopens only after that write returned;
//! - the one in-client resend: a stream the server proved it did not
//!   process (REFUSED_STREAM, or above a GOAWAY's last stream id);
//! - per-stream inactivity in one shared timer list, one PING per quiet
//!   connection, and RST_STREAM(CANCEL) for a single-stream cancel;
//! - positive evidence that no request byte was sent (`End.request_sent`).
//!
//! It does not do HTTP/1.1, redirects, proxies, cookies, decompression,
//! server push, priorities, or resends for any other reason. Requests ask
//! for `identity`, and a coded response ends `.encoded_response`. The caller's
//! receiver decides what the response headers mean.
const std = @import("std");
const c = @import("h2_c");

const policy = @import("policy.zig");
const Record = @import("Stream.zig");
const Engine = @import("Engine.zig");

/// The library versions this client is written and tested against.
pub const nghttp2_version = "1.70.0";
pub const openssl_version = "3.6.3";

pub const max_url_bytes = 2048;
/// The longest DNS name; IP literals are shorter.
pub const max_host_bytes = 253;
pub const max_endpoints = 4;
/// Request fields a caller may set; pseudo-headers, content-length and
/// accept-encoding are the client's own.
pub const max_fields = 16;
pub const max_field_block_bytes = 64 * 1024;
/// Receive credit granted to each stream: the most response bytes the peer
/// can have outstanding on it.
pub const stream_window_bytes: u31 = 16 * 1024;
/// Every socket read lands in the Client's one buffer and is decoded there.
pub const read_buffer_bytes = 16 * 1024;
/// The most bytes one `drive` reads from one connection before moving on.
/// Streams on a connection that hit it skip that drive's inactivity
/// expiry, since their bytes may be waiting.
pub const read_allowance_bytes = 64 * 1024;

/// The linked nghttp2 and OpenSSL must be exactly the pinned versions. Its
/// caller runs this at startup, so a build that picked up other headers or
/// archives fails there instead of behaving differently.
pub fn checkLibraries() error{UnexpectedLibraryVersion}!void {
    const nghttp2: *const c.nghttp2_info = c.nghttp2_version(0) orelse return error.UnexpectedLibraryVersion;
    if (!std.mem.eql(u8, std.mem.span(nghttp2.version_str), nghttp2_version)) return error.UnexpectedLibraryVersion;
    const openssl = c.OpenSSL_version(c.OPENSSL_VERSION_STRING) orelse return error.UnexpectedLibraryVersion;
    if (!std.mem.eql(u8, std.mem.span(openssl), openssl_version)) return error.UnexpectedLibraryVersion;
}

// ---------------------------------------------------------------- endpoints

pub const UrlError = error{ InvalidUrl, CleartextNotLoopback };

pub const Scheme = enum(u8) { https, http };

pub const Url = struct {
    scheme: Scheme,
    /// Without brackets for an IPv6 literal. Name lookup uses it as written.
    host: []const u8,
    /// What SNI carries and the certificate must match: `host` without a
    /// fully qualified name's trailing dot (RFC 6066 section 3).
    server_name: []const u8,
    port: u16,
    /// `host[:port]` as written, for `:authority`.
    authority: []const u8,
    /// Path and query; "/" when the URL has none.
    path: []const u8,
};

/// The transport's safety rule: `https://` to any host, `http://` (h2c by
/// prior knowledge) only to the loopback literals 127.0.0.1 and [::1]. No
/// userinfo, no fragment, valid UTF-8, at most `max_url_bytes`. The parts
/// are slices of `url`.
pub fn parseUrl(url: []const u8) UrlError!Url {
    if (url.len > max_url_bytes or !std.unicode.utf8ValidateSlice(url)) return error.InvalidUrl;
    if (std.mem.indexOfAny(u8, url, "#\\ \t\r\n") != null) return error.InvalidUrl;
    const scheme: Scheme, const rest = if (std.mem.startsWith(u8, url, "https://"))
        .{ .https, url["https://".len..] }
    else if (std.mem.startsWith(u8, url, "http://"))
        .{ .http, url["http://".len..] }
    else
        return error.InvalidUrl;
    const authority_end = std.mem.indexOfAny(u8, rest, "/?") orelse rest.len;
    const authority = rest[0..authority_end];
    const path = if (authority_end == rest.len) "/" else rest[authority_end..];
    if (path[0] != '/') return error.InvalidUrl;
    if (authority.len == 0 or std.mem.indexOfScalar(u8, authority, '@') != null) return error.InvalidUrl;

    var host: []const u8 = authority;
    var port_text: ?[]const u8 = null;
    if (authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return error.InvalidUrl;
        host = authority[1..close];
        const after = authority[close + 1 ..];
        if (after.len > 0) {
            if (after[0] != ':') return error.InvalidUrl;
            port_text = after[1..];
        }
        _ = std.Io.net.Ip6Address.parse(host, 0) catch return error.InvalidUrl;
    } else {
        if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
            host = authority[0..colon];
            port_text = authority[colon + 1 ..];
        }
        if (host.len == 0 or host.len > max_host_bytes) return error.InvalidUrl;
        for (host) |byte| switch (byte) {
            'a'...'z', 'A'...'Z', '0'...'9', '.', '-' => {},
            else => return error.InvalidUrl,
        };
    }
    const port: u16 = if (port_text) |text| blk: {
        if (text.len == 0) return error.InvalidUrl;
        const value = std.fmt.parseInt(u16, text, 10) catch return error.InvalidUrl;
        if (value == 0) return error.InvalidUrl;
        break :blk value;
    } else switch (scheme) {
        .https => 443,
        .http => 80,
    };
    if (scheme == .http and !std.mem.eql(u8, host, "127.0.0.1") and !std.mem.eql(u8, host, "::1"))
        return error.CleartextNotLoopback;
    const server_name = if (host.len > 1 and host[host.len - 1] == '.') host[0 .. host.len - 1] else host;
    return .{ .scheme = scheme, .host = host, .server_name = server_name, .port = port, .authority = authority, .path = path };
}

/// A registered URL. Requests name one; the Client keeps the parsed origin
/// and path once, not per stream.
pub const Endpoint = enum(u8) { _ };

// ------------------------------------------------------------------ options

pub const Liveness = policy.Liveness;

/// What verifies an `https://` peer. Verification is never off.
pub const Trust = union(enum) {
    /// Apple SecTrust on macOS. On Linux, OpenSSL's `SSL_CERT_FILE` (a
    /// PEM bundle) and `SSL_CERT_DIR` (colon-separated hashed directories)
    /// when either is set and not empty, read when trust loads; otherwise
    /// the first readable bundle among the host's usual CA bundle paths.
    system,
    /// Only the certificates in this PEM file (`--provider-ca-file`).
    ca_file: []const u8,
};

pub const Options = struct {
    /// Most streams alive at once. Sizes the connection table: one
    /// connection per stream at worst, when the peer allows one stream.
    stream_capacity: u32,
    /// One interval for every stream of this Client: armed at `launch`
    /// (queue time counts) and renewed by response bytes on the stream.
    /// Being uniform is what lets one list order every deadline.
    inactivity_ns: u64,
    /// Lookup, connect, TLS and the peer's first SETTINGS, per connection.
    connect_timeout_ns: u64,
    liveness: Liveness = .{},
    /// Loaded once, by the first `https://` `addEndpoint`, which fails when
    /// the bundle or file cannot be loaded.
    trust: Trust = .system,
};

// ----------------------------------------------------------------- requests

/// A request header field. Names are lowercase tokens; values contain no
/// NUL, CR or LF.
pub const Field = struct {
    name: []const u8,
    value: []const u8,
    /// Never enters the HPACK dynamic table (NGHTTP2_NV_FLAG_NO_INDEX).
    sensitive: bool = false,
    /// `prepare` keeps the name's and value's addresses instead of a copy,
    /// for bytes many streams share, such as a credential or a literal.
    /// They must stay valid until the stream's first `.head` event or its
    /// end (collected or cancelled): h2 never reads them after either.
    borrowed: bool = false,
};

pub const Body = union(enum) {
    /// Positional reads of [0, length) from a file the caller owns and keeps
    /// open until the `body_retired` event or `cancel`. A short read or a
    /// read error ends the stream `.body_failed`.
    file: struct { handle: std.posix.fd_t, length: u64 },
    /// Borrowed until the stream ends.
    bytes: []const u8,
};

pub const Sink = union(enum) {
    /// Positional writes at the current response length. The caller owns
    /// the descriptor; a write error ends the stream `.sink_failed`.
    file: std.posix.fd_t,
    /// A fixed caller buffer. Bytes past its end end the stream `.sink_refused`.
    buffer: []u8,
};

pub const Request = struct {
    endpoint: Endpoint,
    /// Copied by `prepare` into one owned block of exact length, so the
    /// caller may wipe its own copies (credentials) once it returns; a
    /// borrowed field leaves only its two addresses there. The block is
    /// kept while a resend is possible, then zeroed and freed.
    fields: []const Field,
    body: Body,
    sink: Sink,
};

// ------------------------------------------------------------ receiver side

/// What a receiver sees while `drive` decodes, on the driving thread.
pub const Event = union(enum) {
    /// One complete response header block, borrowed for the call.
    /// `.refuse` resets the stream: it ends `.rejected_headers`.
    head: Head,
    /// About to write this many body bytes to the sink in one write.
    /// `.refuse` resets the stream before any of them is written: it ends
    /// `.sink_refused`. This is where the caller charges its budget.
    body: usize,
    /// The client will never read this stream's request body again. At most
    /// once per stream, never for a stream the caller cancelled. The
    /// verdict is ignored.
    body_retired,
};

pub const Head = struct {
    kind: enum(u8) {
        /// `:status` 1xx.
        interim,
        /// The first non-1xx block; `status` is the response status.
        final,
        /// A block after the final one; `status` is 0.
        trailers,
    },
    status: u16,
    /// Regular fields in arrival order, names lowercase. No pseudo-headers.
    fields: []const Field,
};

pub const Verdict = enum { accept, refuse };

// ------------------------------------------------------------------ endings

pub const Cause = policy.Cause;

pub const End = struct {
    cause: Cause,
    /// False only when this stream's HEADERS were never packed for sending
    /// on any connection: positive evidence that no request byte left.
    request_sent: bool,
};

// ------------------------------------------------------------------- Stream

/// One request and its response, stored in caller memory that must not
/// move from `Client.prepare` until `deinit`. Opaque: the record type is
/// not public, so no caller depends on its layout. All-zero bytes are the
/// idle state.
pub const Stream = extern struct {
    storage: [Record.size]u8 align(Record.alignment) = @splat(0),

    pub const idle: Stream = .{};

    /// Collected, cancelled or idle -> idle. A prepared stream is cancelled
    /// first, which frees its field block; a launched one comes back from
    /// `Client.nextFinished` or goes through `Client.cancel`.
    pub fn deinit(self: *Stream) void {
        const record = Record.of(self);
        std.debug.assert(record.state == .idle or record.state == .collected or record.state == .cancelled);
        std.debug.assert(record.fields == null);
        self.* = .idle;
    }

    /// The final response status, once a final header block arrived.
    pub fn status(self: *const Stream) ?u16 {
        const record = Record.ofConst(self);
        return if (record.flags.final_seen) record.status else null;
    }

    /// Set exactly when the stream has ended.
    pub fn end(self: *const Stream) ?End {
        const record = Record.ofConst(self);
        if (record.state != .finished and record.state != .collected) return null;
        return .{ .cause = record.cause.?, .request_sent = record.flags.request_sent };
    }

    /// Response body bytes accepted by `body` events and written to the sink.
    pub fn responseLength(self: *const Stream) u64 {
        return Record.ofConst(self).sink_written;
    }

    /// This stream was the first carried by a connection opened for it.
    pub fn openedConnection(self: *const Stream) bool {
        return Record.ofConst(self).flags.opened_connection;
    }

    pub fn replays(self: *const Stream) u8 {
        return Record.ofConst(self).flags.replays;
    }
};

// ------------------------------------------------------------------- Client

pub const InitError = error{ OutOfMemory, SystemResources };
pub const EndpointError = UrlError || error{ OutOfMemory, TooManyEndpoints, TrustUnavailable, InvalidCaFile, InvalidSslCertFile, InvalidSslCertDir };
pub const PrepareError = error{ OutOfMemory, InvalidRequest };
pub const DriveError = error{PollFailed};

/// The engine for one owner thread. Opaque like `Stream`. Initialize it in
/// its final storage: streams and connections hold its address.
pub const Client = extern struct {
    storage: [Engine.size]u8 align(Engine.alignment),

    pub fn init(self: *Client, allocator: std.mem.Allocator, io: std.Io, options: Options) InitError!void {
        return Engine.of(self).init(allocator, io, options);
    }

    /// Sends GOAWAY(NO_ERROR) without blocking and closes every connection.
    /// Asserts no stream is launched or uncollected.
    pub fn deinit(self: *Client) void {
        Engine.of(self).deinit();
    }

    /// Registers a URL. Endpoints with one origin share its pool.
    /// The first `https://` one loads `Options.trust`.
    pub fn addEndpoint(self: *Client, url: []const u8) EndpointError!Endpoint {
        return Engine.of(self).addEndpoint(url);
    }

    /// Idle -> prepared. Validates the request and copies its fields into
    /// one owned block, the only allocation a stream makes. Touches no
    /// connection or socket.
    pub fn prepare(self: *Client, stream: *Stream, request: Request) PrepareError!void {
        return Engine.of(self).prepare(Record.of(stream), request);
    }

    /// Prepared -> pending, and its inactivity interval starts now.
    /// Infallible and O(1) with no I/O: HEADERS are packed only by a later
    /// `drive`, so no request byte exists before this returns.
    pub fn launch(self: *Client, stream: *Stream) void {
        Engine.of(self).launch(Record.of(stream));
    }

    /// Any state after `prepare` -> cancelled. An open stream gets
    /// RST_STREAM(CANCEL), sent by the next `drive`; its connection and
    /// siblings are untouched. Nothing is written to the sink after this
    /// returns. Idempotent.
    pub fn cancel(self: *Client, stream: *Stream) void {
        Engine.of(self).cancel(Record.of(stream));
    }

    /// Does all ready work without blocking. `receiver.observe(*Stream,
    /// Event) Verdict` sees the events; it must not call the Client. Every
    /// connection or stream failure becomes some stream's `End`.
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

    /// Blocks until a socket is ready, the earliest timer is due, `wake` is
    /// called, or `timeout_ms` passes. Processes nothing.
    pub fn wait(self: *Client, timeout_ms: u32) DriveError!void {
        return Engine.of(self).wait(timeout_ms);
    }

    /// Ends the current or next `wait` early. The one call any thread may make.
    pub fn wake(self: *Client) void {
        Engine.of(self).waker.wake();
    }

    /// Pops the oldest ended stream; its storage is the caller's again.
    pub fn nextFinished(self: *Client) ?*Stream {
        return Engine.of(self).nextFinished();
    }

    pub fn finishedCount(self: *const Client) usize {
        return Engine.ofConst(self).finished_count;
    }

    /// True while any connection exists, open or opening, even with no
    /// stream left. Keep driving until it is false: a cancel's RST_STREAM,
    /// PING answers and the idle close all go out only from `drive`.
    pub fn hasConnections(self: *const Client) bool {
        return Engine.ofConst(self).connections_len > 0;
    }
};

// ----------------------------------------------------------------- exchange

pub const Exchange = struct {
    url: []const u8,
    fields: []const Field,
    body: []const u8,
    /// The response body lands here; a longer one ends `.sink_refused`.
    response: []u8,
    trust: Trust = .system,
    connect_timeout_ns: u64,
    /// From the call until the stream ends, whatever arrives meanwhile.
    total_timeout_ns: u64,
    /// Polled at least every 100 ms; true cancels the request and returns
    /// `error.Interrupted`.
    cancelled: ?*const fn () bool = null,
};

pub const ExchangeOutcome = union(enum) {
    /// The whole response, its body a prefix of `Exchange.response`.
    answered: struct { status: u16, body: []const u8 },
    /// Never `.complete`.
    failed: End,
    /// `total_timeout_ns` passed first.
    timed_out: struct { request_sent: bool },
};

pub const ExchangeError = InitError || EndpointError || PrepareError || DriveError || error{Interrupted};

/// One request on a private Client and connection, blocking the calling
/// thread until it ends: no pool and no reuse.
/// Allocates from the page allocator, since its callers (token refresh,
/// device login) have none and run a few times an hour at most.
pub fn exchange(io: std.Io, request: Exchange) ExchangeError!ExchangeOutcome {
    const started = std.Io.Clock.awake.now(io).nanoseconds;
    if (request.cancelled) |cancelled| if (cancelled()) return error.Interrupted;
    var client: Client = undefined;
    try client.init(std.heap.page_allocator, io, .{
        .stream_capacity = 1,
        // The total deadline below is the one that matters; this only
        // keeps the inactivity timer from ending the stream first.
        .inactivity_ns = request.total_timeout_ns +| std.time.ns_per_s,
        .connect_timeout_ns = request.connect_timeout_ns,
        .trust = request.trust,
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

// -------------------------------------------------------------------- tests

test "the linked libraries are the pinned versions" {
    try checkLibraries();
}

test "URLs: https anywhere, cleartext only to loopback literals" {
    const parsed = try parseUrl("https://chatgpt.com/backend-api/codex/responses");
    try std.testing.expectEqual(Scheme.https, parsed.scheme);
    try std.testing.expectEqualStrings("chatgpt.com", parsed.host);
    try std.testing.expectEqual(@as(u16, 443), parsed.port);
    try std.testing.expectEqualStrings("chatgpt.com", parsed.authority);
    try std.testing.expectEqualStrings("/backend-api/codex/responses", parsed.path);
    try std.testing.expectEqualStrings("chatgpt.com", parsed.server_name);
    const qualified = try parseUrl("https://chatgpt.com./x");
    try std.testing.expectEqualStrings("chatgpt.com.", qualified.host);
    try std.testing.expectEqualStrings("chatgpt.com", qualified.server_name);
    try std.testing.expectEqualStrings("chatgpt.com.", qualified.authority);

    const loopback = try parseUrl("http://127.0.0.1:8080/v1?x=1");
    try std.testing.expectEqual(@as(u16, 8080), loopback.port);
    try std.testing.expectEqualStrings("127.0.0.1:8080", loopback.authority);
    try std.testing.expectEqualStrings("/v1?x=1", loopback.path);
    const six = try parseUrl("http://[::1]:9/v1");
    try std.testing.expectEqualStrings("::1", six.host);
    try std.testing.expectEqualStrings("[::1]:9", six.authority);

    try std.testing.expectError(error.CleartextNotLoopback, parseUrl("http://localhost:80/"));
    try std.testing.expectError(error.CleartextNotLoopback, parseUrl("http://10.0.0.1/"));
    for ([_][]const u8{
        "ftp://example.com/",
        "https://user@example.com/",
        "https://example.com/#top",
        "https:///path",
        "https://example.com:0/",
        "https://example.com:65536/",
        "https://example.com:/",
        "https://example.com?q=1",
        "https://exa mple.com/",
        "https://[::1/",
        "https://[not-ip]/",
        "https://example.com\xff/",
        comptime long: {
            var name: [max_host_bytes + 1]u8 = undefined;
            @memset(&name, 'a');
            const url = "https://" ++ name ++ "/";
            break :long url;
        },
    }) |url| try std.testing.expectError(error.InvalidUrl, parseUrl(url));
}

test {
    _ = policy;
    _ = Record;
    _ = Engine;
    _ = @import("Waker.zig");
    _ = @import("Resolver.zig");
    _ = @import("tls.zig");
    _ = @import("tests.zig");
}
