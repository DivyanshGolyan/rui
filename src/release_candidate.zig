const std = @import("std");
const builtin = @import("builtin");
const os = @import("os/os.zig");
const client = @import("client.zig");
const process = @import("upgrade_process.zig");

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
        const schema = std.math.order(a.schema, b.schema);
        return if (schema == .eq) std.math.order(a.patch, b.patch) else schema;
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

/// The curl transport every release download shares: no config file,
/// failure on an HTTP error, quiet but for errors, redirects followed, and
/// bounded connect and total time. Callers add their redirect and protocol
/// bounds, any output, and `--` with the URL.
const curl_transport = [_][]const u8{ "curl", "--disable", "--fail", "--silent", "--show-error", "--location", "--connect-timeout", "10", "--max-time", "300" };

fn curlArgv(comptime n: usize, tail: [n][]const u8) [curl_transport.len + n][]const u8 {
    var argv: [curl_transport.len + n][]const u8 = undefined;
    argv[0..curl_transport.len].* = curl_transport;
    argv[curl_transport.len..].* = tail;
    return argv;
}

pub fn fetch(allocator: std.mem.Allocator, io: std.Io, url: []const u8, cancellation: ?*const client.Cancellation, limit: usize, diagnostic: ?*process.DownloadDiagnostic) ![]u8 {
    const fixture = std.mem.startsWith(u8, url, "http://");
    if (fixture) _ = try fixtureOrigin(url) else if (!std.mem.startsWith(u8, url, "https://")) return error.InvalidReleaseEndpoint;
    const argv = curlArgv(8, .{ "--max-redirs", if (fixture) "0" else "5", "--proto", if (fixture) "=http" else "=https", "--proto-redir", "=https", "--", url });
    return process.downloadOutput(allocator, io, &argv, cancellation, limit, diagnostic);
}

pub fn discover(allocator: std.mem.Allocator, io: std.Io, endpoint: []const u8, cancellation: ?*const client.Cancellation, diagnostic: ?*process.DownloadDiagnostic) !ReleaseCandidate {
    const fixture = !std.mem.eql(u8, endpoint, default_endpoint);
    const origin = if (fixture) try fixtureOrigin(endpoint) else download_origin;
    const target = try platform();
    // Follow the whole chain: a future public endpoint may redirect through
    // GitHub's latest page before reaching the tag. Never parse page HTML.
    const argv = curlArgv(12, .{ "--max-redirs", "5", "--proto", if (fixture) "=http" else "=https", "--proto-redir", if (fixture) "=http" else "=https", "--output", "/dev/null", "--write-out", "%{url_effective}", "--", endpoint });
    const effective = try process.downloadOutput(allocator, io, &argv, cancellation, 4096, diagnostic);
    defer allocator.free(effective);
    var result = try fromEffectiveUrl(allocator, effective, if (fixture) origin else tag_origin, origin, target);
    errdefer result.deinit(allocator);
    const sums = try fetch(allocator, io, result.checksum_url, cancellation, 1024 * 1024, diagnostic);
    defer allocator.free(sums);
    result.sha256 = try checksum(sums, result.archive_name);
    return result;
}

pub fn fromEffectiveUrl(allocator: std.mem.Allocator, effective: []const u8, final_origin: []const u8, origin: []const u8, target: []const u8) !ReleaseCandidate {
    if (!std.mem.startsWith(u8, effective, final_origin)) return error.InvalidReleaseEndpoint;
    const path = effective[final_origin.len..];
    const prefix = "/releases/tag/";
    if (!std.mem.startsWith(u8, path, prefix)) return error.InvalidReleaseEndpoint;
    const tag = path[prefix.len..];
    if (!std.mem.startsWith(u8, tag, "v")) return error.InvalidReleaseVersion;
    const version = try Version.parse(tag[1..]);
    if (!std.mem.eql(u8, target, "darwin-arm64") and !std.mem.eql(u8, target, "linux-x86_64")) return error.UnsupportedReleasePlatform;
    const archive_name = try std.fmt.allocPrint(allocator, "rui-{s}-{s}.tar.gz", .{ tag[1..], target });
    errdefer allocator.free(archive_name);
    const archive_url = try std.fmt.allocPrint(allocator, "{s}/releases/download/{s}/{s}", .{ origin, tag, archive_name });
    errdefer allocator.free(archive_url);
    const checksum_url = try std.fmt.allocPrint(allocator, "{s}/releases/download/{s}/SHA256SUMS", .{ origin, tag });
    errdefer allocator.free(checksum_url);
    return .{ .version = version, .tag = try allocator.dupe(u8, tag), .archive_name = archive_name, .archive_url = archive_url, .checksum_url = checksum_url, .sha256 = @splat(0) };
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
