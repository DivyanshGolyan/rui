const std = @import("std");
const builtin = @import("builtin");
const os = @import("os");
const client = @import("client.zig");
const policy = @import("download_policy.zig");
const process = @import("upgrade_process.zig");
const upgrade_status = @import("upgrade_status.zig");

const download_origin = "https://ruicode.com";
pub const default_endpoint = download_origin ++ "/releases/latest";
const tag_origin = "https://github.com/DivyanshGolyan/rui";

pub const Version = struct {
    schema: u32,
    patch: u32,

    pub fn parse(text: []const u8) !Version {
        var parts = std.mem.splitScalar(u8, text, '.');
        if (!std.mem.eql(u8, parts.next() orelse return error.InvalidReleaseVersion, "0")) return error.InvalidReleaseVersion;
        const schema = try number(parts.next() orelse return error.InvalidReleaseVersion);
        const patch = try number(parts.next() orelse return error.InvalidReleaseVersion);
        if (parts.next() != null) return error.InvalidReleaseVersion;
        return .{ .schema = schema, .patch = patch };
    }

    fn number(text: []const u8) !u32 {
        if (text.len == 0 or (text.len > 1 and text[0] == '0')) return error.InvalidReleaseVersion;
        for (text) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidReleaseVersion;
        return std.fmt.parseInt(u32, text, 10) catch error.InvalidReleaseVersion;
    }

    pub fn order(a: Version, b: Version) std.math.Order {
        return upgrade_status.Version.order(.{ .schema = a.schema, .patch = a.patch }, .{ .schema = b.schema, .patch = b.patch });
    }
};

pub const ReleaseCandidate = struct {
    version: Version,
    tag: []const u8,
    archive_name: []const u8,
    archive_url: []const u8,
    checksum_url: []const u8,
    sha256: [32]u8,

    pub fn deinit(self: *ReleaseCandidate, allocator: std.mem.Allocator) void {
        allocator.free(self.tag);
        allocator.free(self.archive_name);
        allocator.free(self.archive_url);
        allocator.free(self.checksum_url);
        self.* = undefined;
    }
};

pub fn platform() ![]const u8 {
    if (os.tag == .macos and builtin.cpu.arch == .aarch64) return "darwin-arm64";
    if (os.tag == .linux and builtin.cpu.arch == .x86_64) return "linux-x86_64";
    return error.UnsupportedReleasePlatform;
}

fn fixtureOrigin(endpoint: []const u8) ![]const u8 {
    const prefix = "http://";
    if (!std.mem.startsWith(u8, endpoint, prefix)) return error.InvalidReleaseEndpoint;
    const end = std.mem.indexOfScalarPos(u8, endpoint, prefix.len, '/') orelse return error.InvalidReleaseEndpoint;
    const authority = endpoint[prefix.len..end];
    const hosts = [_][]const u8{ "127.0.0.1:", "localhost:", "[::1]:" };
    for (hosts) |host| {
        if (!std.mem.startsWith(u8, authority, host)) continue;
        const port = authority[host.len..];
        if (port.len == 0) return error.InvalidReleaseEndpoint;
        for (port) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidReleaseEndpoint;
        _ = std.fmt.parseInt(u16, port, 10) catch return error.InvalidReleaseEndpoint;
        return endpoint[0..end];
    }
    return error.InvalidReleaseEndpoint;
}

pub fn fetch(allocator: std.mem.Allocator, io: std.Io, url: []const u8, cancellation: ?*const client.Cancellation, limit: usize, diagnostic: ?*process.Download) ![]u8 {
    const fixture = std.mem.startsWith(u8, url, "http://");
    if (fixture) _ = try fixtureOrigin(url) else if (!std.mem.startsWith(u8, url, "https://")) return error.InvalidReleaseEndpoint;
    return process.downloadOutput(allocator, io, .{ .url = url }, cancellation, limit, diagnostic);
}

const release_tag_prefix = "/releases/tag/";
const max_release_hops = 5;

const Origins = struct { origin: []const u8, tag_origin: []const u8 };

/// The origin that serves archives, and the origin the tag URL must sit on.
fn origins(endpoint: []const u8) !Origins {
    if (std.mem.eql(u8, endpoint, default_endpoint)) return .{ .origin = download_origin, .tag_origin = tag_origin };
    const fixture = try fixtureOrigin(endpoint);
    return .{ .origin = fixture, .tag_origin = fixture };
}

pub fn discover(allocator: std.mem.Allocator, io: std.Io, endpoint: []const u8, cancellation: ?*const client.Cancellation, diagnostic: ?*process.Download) !ReleaseCandidate {
    const found = try origins(endpoint);
    const target = try platform();
    const tag_url = try tagUrl(allocator, io, endpoint, found.tag_origin, "curl", cancellation, diagnostic);
    defer allocator.free(tag_url);
    var result = try fromEffectiveUrl(allocator, tag_url, found.tag_origin, found.origin, target);
    errdefer result.deinit(allocator);
    const sums = try fetch(allocator, io, result.checksum_url, cancellation, 1024 * 1024, diagnostic);
    defer allocator.free(sums);
    result.sha256 = try checksum(sums, result.archive_name);
    return result;
}

/// The latest stable release's version, read from the redirect chain alone.
/// It does not need a platform the release can be installed on.
pub fn latestVersion(allocator: std.mem.Allocator, io: std.Io, endpoint: []const u8, cancellation: ?*const client.Cancellation, diagnostic: ?*process.Download) !Version {
    return latestVersionWith(allocator, io, "curl", endpoint, cancellation, diagnostic);
}

fn latestVersionWith(allocator: std.mem.Allocator, io: std.Io, executable: []const u8, endpoint: []const u8, cancellation: ?*const client.Cancellation, diagnostic: ?*process.Download) !Version {
    const found = try origins(endpoint);
    const tag_url = try tagUrl(allocator, io, endpoint, found.tag_origin, executable, cancellation, diagnostic);
    defer allocator.free(tag_url);
    return (try parseTag(tag_url, found.tag_origin)).version;
}

/// Follows redirects one hop at a time and returns the first Location on the
/// final origin's tag path, so the tag page itself is never downloaded.
fn tagUrl(allocator: std.mem.Allocator, io: std.Io, endpoint: []const u8, final_origin: []const u8, executable: []const u8, cancellation: ?*const client.Cancellation, diagnostic: ?*process.Download) ![]u8 {
    const fixture = std.mem.startsWith(u8, endpoint, "http://");
    const fixture_origin = if (fixture) try fixtureOrigin(endpoint) else "";
    var local: process.Download = .{};
    defer local.deinit(allocator);
    const download = diagnostic orelse &local;
    const deadline: std.Io.Clock.Timestamp = .fromNow(io, .{ .raw = .fromNanoseconds(policy.download_timeout_ns), .clock = .awake });
    var url = try allocator.dupe(u8, endpoint);
    errdefer allocator.free(url);
    for (0..max_release_hops) |_| {
        const location = try download.outputUntil(allocator, io, .{ .url = url, .output = .redirect_url }, cancellation, 4096, executable, deadline);
        if (location.len == 0) {
            allocator.free(location);
            return error.InvalidReleaseEndpoint;
        }
        allocator.free(url);
        url = location;
        if (std.mem.startsWith(u8, url, final_origin) and std.mem.startsWith(u8, url[final_origin.len..], release_tag_prefix)) return url;
        if (!std.mem.startsWith(u8, url, "https://") and !(fixture and std.mem.startsWith(u8, url, fixture_origin))) return error.InvalidReleaseEndpoint;
    }
    return error.InvalidReleaseEndpoint;
}

const ParsedTag = struct { tag: []const u8, version: Version };

fn parseTag(url: []const u8, final_origin: []const u8) !ParsedTag {
    if (!std.mem.startsWith(u8, url, final_origin)) return error.InvalidReleaseEndpoint;
    const path = url[final_origin.len..];
    if (!std.mem.startsWith(u8, path, release_tag_prefix)) return error.InvalidReleaseEndpoint;
    const tag = path[release_tag_prefix.len..];
    if (!std.mem.startsWith(u8, tag, "v")) return error.InvalidReleaseVersion;
    return .{ .tag = tag, .version = try Version.parse(tag[1..]) };
}

pub fn fromEffectiveUrl(allocator: std.mem.Allocator, effective: []const u8, final_origin: []const u8, origin: []const u8, target: []const u8) !ReleaseCandidate {
    const parsed = try parseTag(effective, final_origin);
    const tag = parsed.tag;
    if (!std.mem.eql(u8, target, "darwin-arm64") and !std.mem.eql(u8, target, "linux-x86_64")) return error.UnsupportedReleasePlatform;
    const archive_name = try std.fmt.allocPrint(allocator, "rui-{s}-{s}.tar.gz", .{ tag[1..], target });
    errdefer allocator.free(archive_name);
    const archive_url = try std.fmt.allocPrint(allocator, "{s}/releases/download/{s}/{s}", .{ origin, tag, archive_name });
    errdefer allocator.free(archive_url);
    const checksum_url = try std.fmt.allocPrint(allocator, "{s}/releases/download/{s}/SHA256SUMS", .{ origin, tag });
    errdefer allocator.free(checksum_url);
    return .{ .version = parsed.version, .tag = try allocator.dupe(u8, tag), .archive_name = archive_name, .archive_url = archive_url, .checksum_url = checksum_url, .sha256 = @splat(0) };
}

pub fn checksum(sums: []const u8, archive_name: []const u8) ![32]u8 {
    var found: ?[32]u8 = null;
    var lines = std.mem.splitScalar(u8, sums, '\n');
    while (lines.next()) |line| {
        if (line.len < 67 or line[64] != ' ') continue;
        const name = if (line[65] == ' ' or line[65] == '*') line[66..] else continue;
        if (!std.mem.eql(u8, name, archive_name)) continue;
        if (found != null) return error.DuplicateReleaseChecksum;
        var digest: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&digest, line[0..64]) catch return error.InvalidReleaseChecksum;
        found = digest;
    }
    return found orelse error.MissingReleaseChecksum;
}

test "release versions are canonical numeric values" {
    const old = try Version.parse("0.9.10");
    try std.testing.expectEqual(std.math.Order.lt, old.order(try Version.parse("0.10.0")));
    try std.testing.expectEqual(std.math.Order.gt, old.order(try Version.parse("0.9.2")));
    for ([_][]const u8{ "", "v0.9.1", "1.2.3", "0.01.2", "0.1.02", "0.+1.2", "0.1.2-rc1", "0.1.2.3", "0.4294967296.0" }) |bad| try std.testing.expectError(error.InvalidReleaseVersion, Version.parse(bad));
}

test "release checksum must uniquely name the pinned archive" {
    const row = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef  rui.tar.gz\n";
    const digest = try checksum(row, "rui.tar.gz");
    try std.testing.expectEqual(@as(u8, 0x01), digest[0]);
    try std.testing.expectError(error.MissingReleaseChecksum, checksum(row, "other.tar.gz"));
    try std.testing.expectError(error.DuplicateReleaseChecksum, checksum(row ++ row, "rui.tar.gz"));
}

test "release endpoint injection accepts only loopback HTTP fixtures" {
    try std.testing.expectEqualStrings("http://127.0.0.1:1234", try fixtureOrigin("http://127.0.0.1:1234/latest"));
    for ([_][]const u8{ "https://example.com/latest", "http://127.0.0.1.evil:80/latest", "http://127.0.0.1:80@evil/latest", "http://example.com:80/latest" }) |bad| try std.testing.expectError(error.InvalidReleaseEndpoint, fixtureOrigin(bad));
}

test "release effective URL pins a canonical tag and derived assets" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqualStrings("https://ruicode.com/releases/latest", default_endpoint);
    for ([_]struct { []const u8, []const u8, []const u8 }{
        .{ "linux-x86_64", "rui-0.56.2-linux-x86_64.tar.gz", "https://ruicode.com/releases/download/v0.56.2/rui-0.56.2-linux-x86_64.tar.gz" },
        .{ "darwin-arm64", "rui-0.56.2-darwin-arm64.tar.gz", "https://ruicode.com/releases/download/v0.56.2/rui-0.56.2-darwin-arm64.tar.gz" },
    }) |case| {
        var candidate = try fromEffectiveUrl(allocator, "https://github.com/DivyanshGolyan/rui/releases/tag/v0.56.2", tag_origin, download_origin, case[0]);
        defer candidate.deinit(allocator);
        try std.testing.expectEqualStrings("v0.56.2", candidate.tag);
        try std.testing.expectEqualStrings(case[1], candidate.archive_name);
        try std.testing.expectEqualStrings(case[2], candidate.archive_url);
        try std.testing.expectEqualStrings("https://ruicode.com/releases/download/v0.56.2/SHA256SUMS", candidate.checksum_url);
    }
    for ([_][]const u8{
        tag_origin ++ "/releases/latest",
        tag_origin ++ ".evil/releases/tag/v0.56.2",
        "https://example.com/releases/tag/v0.56.2",
        "http://github.com/DivyanshGolyan/rui/releases/tag/v0.56.2",
    }) |bad| try std.testing.expectError(error.InvalidReleaseEndpoint, fromEffectiveUrl(allocator, bad, tag_origin, download_origin, "linux-x86_64"));
    for ([_][]const u8{ "0.56.2", "v0.056.2", "v0.56.2-rc1", "v0.56.2/", "v0.56.2?x=1", "v0.56.2#fragment", "" }) |bad| {
        const url = try std.fmt.allocPrint(allocator, "{s}/releases/tag/{s}", .{ tag_origin, bad });
        defer allocator.free(url);
        try std.testing.expectError(error.InvalidReleaseVersion, fromEffectiveUrl(allocator, url, tag_origin, download_origin, "linux-x86_64"));
    }
    try std.testing.expectError(error.UnsupportedReleasePlatform, fromEffectiveUrl(allocator, tag_origin ++ "/releases/tag/v0.56.2", tag_origin, download_origin, "linux-arm64"));
    var stopped: client.Cancellation = .{};
    stopped.requestStop();
    try std.testing.expectError(error.Cancelled, discover(allocator, std.testing.io, default_endpoint, &stopped, null));
}

const Hop = struct { from: []const u8, to: []const u8 };

/// A fake curl that answers each URL from `hops` with its Location, and logs
/// every URL it is asked for beside itself.
fn writeRedirectCurl(allocator: std.mem.Allocator, io: std.Io, directory: std.Io.Dir, hops: []const Hop) ![:0]u8 {
    var script: std.Io.Writer.Allocating = .init(allocator);
    defer script.deinit();
    try script.writer.writeAll("#!/bin/sh\nfor last; do :; done\nprintf '%s\\n' \"$last\" >> \"$0.log\"\ncase \"$last\" in\n");
    for (hops) |hop| try script.writer.print("{s}) printf '%s' '{s}' ;;\n", .{ hop.from, hop.to });
    try script.writer.writeAll("*) ;;\nesac\n");
    try directory.writeFile(io, .{ .sub_path = "curl", .data = script.written(), .flags = .{ .permissions = .fromMode(0o700) } });
    return directory.realPathFileAlloc(io, "curl", allocator);
}

fn expectRequestLog(io: std.Io, directory: std.Io.Dir, requests: []const []const u8) !void {
    var buffer: [4096]u8 = undefined;
    const log = try directory.readFile(io, "curl.log", &buffer);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, log, "\n"), '\n');
    for (requests) |request| try std.testing.expectEqualStrings(request, lines.next() orelse return error.TestUnexpectedResult);
    try std.testing.expect(lines.next() == null);
}

test "SH-148 the release lookup follows redirects one hop at a time and never requests the tag page" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const latest = "https://ruicode.com/releases/latest";
    const github_latest = "https://github.com/DivyanshGolyan/rui/releases/latest";
    const tag = "https://github.com/DivyanshGolyan/rui/releases/tag/v0.56.2";
    const five_hops = [_]Hop{
        .{ .from = latest, .to = "https://github.com/a/1" },
        .{ .from = "https://github.com/a/1", .to = "https://github.com/a/2" },
        .{ .from = "https://github.com/a/2", .to = "https://github.com/a/3" },
        .{ .from = "https://github.com/a/3", .to = "https://github.com/a/4" },
        .{ .from = "https://github.com/a/4", .to = tag },
    };
    const six_hops = [_]Hop{
        .{ .from = latest, .to = "https://github.com/a/1" },
        .{ .from = "https://github.com/a/1", .to = "https://github.com/a/2" },
        .{ .from = "https://github.com/a/2", .to = "https://github.com/a/3" },
        .{ .from = "https://github.com/a/3", .to = "https://github.com/a/4" },
        .{ .from = "https://github.com/a/4", .to = "https://github.com/a/5" },
        .{ .from = "https://github.com/a/5", .to = tag },
    };
    const version: Version = .{ .schema = 56, .patch = 2 };
    const first_four = [_][]const u8{ latest, "https://github.com/a/1", "https://github.com/a/2", "https://github.com/a/3", "https://github.com/a/4" };
    const cases = [_]struct { hops: []const Hop, requests: []const []const u8, expected: anyerror!Version }{
        .{ .hops = &.{.{ .from = latest, .to = tag }}, .requests = &.{latest}, .expected = version },
        .{ .hops = &.{ .{ .from = latest, .to = github_latest }, .{ .from = github_latest, .to = tag } }, .requests = &.{ latest, github_latest }, .expected = version },
        .{ .hops = &five_hops, .requests = &first_four, .expected = version },
        .{ .hops = &six_hops, .requests = &first_four, .expected = error.InvalidReleaseEndpoint },
        .{ .hops = &.{.{ .from = latest, .to = "http://github.com/DivyanshGolyan/rui/releases/tag/v0.56.2" }}, .requests = &.{latest}, .expected = error.InvalidReleaseEndpoint },
        .{ .hops = &.{.{ .from = latest, .to = "https://example.com/elsewhere" }}, .requests = &.{ latest, "https://example.com/elsewhere" }, .expected = error.InvalidReleaseEndpoint },
        .{ .hops = &.{}, .requests = &.{latest}, .expected = error.InvalidReleaseEndpoint },
    };
    for (cases) |case| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        const executable = try writeRedirectCurl(allocator, io, temporary.dir, case.hops);
        defer allocator.free(executable);
        // latestVersion needs no installable platform, so this holds on every host.
        const actual = latestVersionWith(allocator, io, executable, latest, null, null);
        if (case.expected) |expected| {
            try std.testing.expectEqual(expected, try actual);
        } else |expected| {
            try std.testing.expectError(expected, actual);
        }
        try expectRequestLog(io, temporary.dir, case.requests);
    }
}
