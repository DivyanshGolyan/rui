const std = @import("std");
const TerminalText = @import("TerminalText.zig");

pub const Family = enum { automatic, ipv4 };

// Release generation reads these single-line literal declarations from the
// pinned release source. The strict reader accepts positive second values up
// to 86400 with connect <= download and distinct exit codes from 1 through 255.
pub const connect_timeout_seconds: u32 = 10;
pub const download_timeout_seconds: u32 = 300;
pub const retry_exit_codes = [_]u8{ 6, 28 };

pub const connect_timeout_ns: i96 = @as(i96, connect_timeout_seconds) * 1_000_000_000;
pub const download_timeout_ns: i96 = @as(i96, download_timeout_seconds) * 1_000_000_000;

/// One release download: what curl fetches and where its bytes go.
/// A loopback `http://` URL is the fixture origin; every other URL is HTTPS.
pub const Request = struct {
    url: []const u8,
    output: union(enum) { body, effective_url, archive: []const u8 } = .body,
};

/// Storage for one attempt's argument list. The returned slice borrows it.
pub const Arguments = struct {
    list: [24][]const u8 = undefined,
    max_time: [32]u8 = undefined,
};

/// curl's confined argument list for one attempt: configuration file
/// disabled, protocols and redirects bounded, and the time left on the one
/// download deadline. A retry differs only by `--ipv4`, so an archive retry
/// writes the same output path again from the start (no resume).
pub fn arguments(storage: *Arguments, executable: []const u8, request: Request, family: Family, remaining_ms: u64) []const []const u8 {
    const max_time = std.fmt.bufPrint(&storage.max_time, "{d}.{d:0>3}", .{ remaining_ms / 1000, remaining_ms % 1000 }) catch unreachable;
    const connect_time = std.fmt.comptimePrint("{d}", .{@divExact(connect_timeout_ns, 1_000_000_000)});
    const fixture = std.mem.startsWith(u8, request.url, "http://");
    const discovery = request.output == .effective_url;
    const common = [_][]const u8{
        executable,          "--disable",                        "--fail",        "--silent",                                       "--show-error", "--location",
        "--connect-timeout", connect_time,                       "--max-time",    max_time,                                         "--max-redirs", if (fixture and !discovery) "0" else "5",
        "--proto",           if (fixture) "=http" else "=https", "--proto-redir", if (fixture and discovery) "=http" else "=https",
    };
    const argv = &storage.list;
    argv[0..common.len].* = common;
    var count: usize = common.len;
    if (family == .ipv4) {
        argv[count] = "--ipv4";
        count += 1;
    }
    switch (request.output) {
        .body => {},
        .effective_url => {
            argv[count..][0..4].* = .{ "--output", "/dev/null", "--write-out", "%{url_effective}" };
            count += 4;
        },
        .archive => |path| {
            argv[count..][0..4].* = .{ "--max-filesize", "268435456", "--output", path };
            count += 4;
        },
    }
    argv[count..][0..2].* = .{ "--", request.url };
    count += 2;
    return argv[0..count];
}

/// What follows one finished attempt.
pub const Next = union(enum) {
    /// The download succeeded; later downloads of the same run use this family.
    done: Family,
    retry_ipv4,
    failed,
};

/// `exit` is curl's exit status, or null when a signal ended it.
/// `remaining_ns` is what is left of the download deadline after the attempt.
pub fn after(family: Family, exit: ?u8, remaining_ns: i96) Next {
    if (exit == 0) return .{ .done = family };
    return if (retry(family, exit, remaining_ns)) .retry_ipv4 else .failed;
}

/// The transport owns both curl timeouts and disables curl's config file.
/// With a full connection budget left on the same download deadline, exit 28
/// cannot be the total-transfer timeout; it is a connection-phase timeout,
/// including a resolver stall on a redirect. No stderr text is interpreted.
fn retry(family: Family, exit_code: ?u8, remaining_ns: i96) bool {
    const code = exit_code orelse return false;
    return family == .automatic and
        remaining_ns >= connect_timeout_ns and
        std.mem.indexOfScalar(u8, &retry_exit_codes, code) != null;
}

/// The last non-empty line of curl's stderr, made terminal-safe and ended
/// with a newline; nothing when there is no such line.
pub fn writeDiagnostic(writer: *std.Io.Writer, stderr: []const u8) !void {
    const trimmed = std.mem.trimEnd(u8, stderr, "\r\n");
    const start = if (std.mem.lastIndexOfScalar(u8, trimmed, '\n')) |at| at + 1 else 0;
    if (trimmed.len == start) return;
    var text: TerminalText = .{ .mode = .line };
    try text.feed(writer, trimmed[start..]);
    try text.finish(writer);
    try writer.writeAll("\n");
}

/// SH-70's expected lists, typed from the base commit's inline argument
/// table in `upgrade_process.Download.outputUntil` (531600a53), not from
/// `arguments`. The executable is `curl` and the time left is 299 999 ms.
const sh61 = struct {
    const fixture_url = "http://127.0.0.1:8000/releases/latest";
    const release_url = "https://github.com/owner/rui/releases/latest";
    const archive_path = "/tmp/rui-download/archive.tar.gz";

    const Case = struct { request: Request, family: Family, expected: []const []const u8 };

    const cases = [_]Case{
        .{ .request = .{ .url = release_url }, .family = .automatic, .expected = &.{
            "curl", "--disable", "--fail", "--silent", "--show-error", "--location", "--connect-timeout", "10", "--max-time", "299.999", "--max-redirs", "5", "--proto", "=https", "--proto-redir", "=https",
            "--",   release_url,
        } },
        .{ .request = .{ .url = release_url }, .family = .ipv4, .expected = &.{
            "curl",   "--disable", "--fail",    "--silent", "--show-error", "--location", "--connect-timeout", "10", "--max-time", "299.999", "--max-redirs", "5", "--proto", "=https", "--proto-redir", "=https",
            "--ipv4", "--",        release_url,
        } },
        .{ .request = .{ .url = release_url, .output = .effective_url }, .family = .automatic, .expected = &.{
            "curl",     "--disable", "--fail",      "--silent",         "--show-error", "--location", "--connect-timeout", "10", "--max-time", "299.999", "--max-redirs", "5", "--proto", "=https", "--proto-redir", "=https",
            "--output", "/dev/null", "--write-out", "%{url_effective}", "--",           release_url,
        } },
        .{ .request = .{ .url = release_url, .output = .effective_url }, .family = .ipv4, .expected = &.{
            "curl",   "--disable", "--fail",    "--silent",    "--show-error",     "--location", "--connect-timeout", "10", "--max-time", "299.999", "--max-redirs", "5", "--proto", "=https", "--proto-redir", "=https",
            "--ipv4", "--output",  "/dev/null", "--write-out", "%{url_effective}", "--",         release_url,
        } },
        .{ .request = .{ .url = release_url, .output = .{ .archive = archive_path } }, .family = .automatic, .expected = &.{
            "curl",           "--disable", "--fail",   "--silent",   "--show-error", "--location", "--connect-timeout", "10", "--max-time", "299.999", "--max-redirs", "5", "--proto", "=https", "--proto-redir", "=https",
            "--max-filesize", "268435456", "--output", archive_path, "--",           release_url,
        } },
        .{ .request = .{ .url = release_url, .output = .{ .archive = archive_path } }, .family = .ipv4, .expected = &.{
            "curl",   "--disable",      "--fail",    "--silent", "--show-error", "--location", "--connect-timeout", "10", "--max-time", "299.999", "--max-redirs", "5", "--proto", "=https", "--proto-redir", "=https",
            "--ipv4", "--max-filesize", "268435456", "--output", archive_path,   "--",         release_url,
        } },
        .{ .request = .{ .url = fixture_url }, .family = .automatic, .expected = &.{
            "curl", "--disable", "--fail", "--silent", "--show-error", "--location", "--connect-timeout", "10", "--max-time", "299.999", "--max-redirs", "0", "--proto", "=http", "--proto-redir", "=https",
            "--",   fixture_url,
        } },
        .{ .request = .{ .url = fixture_url }, .family = .ipv4, .expected = &.{
            "curl",   "--disable", "--fail",    "--silent", "--show-error", "--location", "--connect-timeout", "10", "--max-time", "299.999", "--max-redirs", "0", "--proto", "=http", "--proto-redir", "=https",
            "--ipv4", "--",        fixture_url,
        } },
        .{ .request = .{ .url = fixture_url, .output = .effective_url }, .family = .automatic, .expected = &.{
            "curl",     "--disable", "--fail",      "--silent",         "--show-error", "--location", "--connect-timeout", "10", "--max-time", "299.999", "--max-redirs", "5", "--proto", "=http", "--proto-redir", "=http",
            "--output", "/dev/null", "--write-out", "%{url_effective}", "--",           fixture_url,
        } },
        .{ .request = .{ .url = fixture_url, .output = .effective_url }, .family = .ipv4, .expected = &.{
            "curl",   "--disable", "--fail",    "--silent",    "--show-error",     "--location", "--connect-timeout", "10", "--max-time", "299.999", "--max-redirs", "5", "--proto", "=http", "--proto-redir", "=http",
            "--ipv4", "--output",  "/dev/null", "--write-out", "%{url_effective}", "--",         fixture_url,
        } },
        .{ .request = .{ .url = fixture_url, .output = .{ .archive = archive_path } }, .family = .automatic, .expected = &.{
            "curl",           "--disable", "--fail",   "--silent",   "--show-error", "--location", "--connect-timeout", "10", "--max-time", "299.999", "--max-redirs", "0", "--proto", "=http", "--proto-redir", "=https",
            "--max-filesize", "268435456", "--output", archive_path, "--",           fixture_url,
        } },
        .{ .request = .{ .url = fixture_url, .output = .{ .archive = archive_path } }, .family = .ipv4, .expected = &.{
            "curl",   "--disable",      "--fail",    "--silent", "--show-error", "--location", "--connect-timeout", "10", "--max-time", "299.999", "--max-redirs", "0", "--proto", "=http", "--proto-redir", "=https",
            "--ipv4", "--max-filesize", "268435456", "--output", archive_path,   "--",         fixture_url,
        } },
    };
};

test "SH-70 every download attempt confines curl" {
    for (sh61.cases) |case| {
        var storage: Arguments = .{};
        const actual = arguments(&storage, "curl", case.request, case.family, 299_999);
        try std.testing.expectEqual(case.expected.len, actual.len);
        for (case.expected, actual) |expected, argument| try std.testing.expectEqualStrings(expected, argument);
    }
    // The two families of one request differ only by `--ipv4`, so a retry
    // keeps the same output path and never resumes the failed attempt's bytes.
    for (0..sh61.cases.len / 2) |index| {
        var automatic_storage: Arguments = .{};
        var ipv4_storage: Arguments = .{};
        const request = sh61.cases[index * 2].request;
        const automatic = arguments(&automatic_storage, "curl", request, .automatic, 12_345);
        const ipv4 = arguments(&ipv4_storage, "curl", request, .ipv4, 12_345);
        const at = for (ipv4, 0..) |argument, position| {
            if (std.mem.eql(u8, argument, "--ipv4")) break position;
        } else return error.TestUnexpectedResult;
        try std.testing.expectEqual(automatic.len + 1, ipv4.len);
        for (automatic[0..at], ipv4[0..at]) |a, b| try std.testing.expectEqualStrings(a, b);
        for (automatic[at..], ipv4[at + 1 ..]) |a, b| try std.testing.expectEqualStrings(a, b);
        for (ipv4) |argument| for ([_][]const u8{ "-C", "--continue-at", "--config", "-K" }) |forbidden|
            try std.testing.expect(!std.mem.eql(u8, argument, forbidden));
    }
    // The time left is printed in seconds with milliseconds.
    for ([_]struct { u64, []const u8 }{ .{ 1, "0.001" }, .{ 10_000, "10.000" }, .{ 300_000, "300.000" }, .{ std.math.maxInt(u64), "18446744073709551.615" } }) |case| {
        var storage: Arguments = .{};
        const actual = arguments(&storage, "curl", .{ .url = sh61.release_url }, .automatic, case[0]);
        try std.testing.expectEqualStrings(case[1], actual[9]);
    }
}

test "SH-44 a download retries once over IPv4 only for an early resolution or connection failure, and keeps IPv4 for its run" {
    const budgets = [_]i96{
        -1,                     0,
        connect_timeout_ns - 1, connect_timeout_ns,
        connect_timeout_ns + 1, download_timeout_ns,
    };
    for ([_]Family{ .automatic, .ipv4 }) |family| {
        for (budgets) |remaining_ns| {
            for (0..256) |code| {
                const expected: Next = if (code == 0)
                    .{ .done = family }
                else if (family == .automatic and remaining_ns >= 10_000_000_000 and (code == 6 or code == 28))
                    .retry_ipv4
                else
                    .failed;
                try std.testing.expectEqual(expected, after(family, @intCast(code), remaining_ns));
            }
            try std.testing.expectEqual(Next.failed, after(family, null, remaining_ns));
        }
    }

    // One run downloads latest, sums and archive in that order, as the shell
    // loop does: each finished attempt asks `after`, and a run's family carries
    // into its next download. Expected traces are the attempt lists the
    // retired `upgrade_integration.py:download_cases` asserted (path, family,
    // code); `x` is a signal. Every other single failure follows the rule below.
    const Script = struct { stage: u2, codes: []const ?u8, sticky_latest: bool = false, expected: []const u8 };
    const scripts = [_]Script{
        .{ .stage = 0, .codes = &.{6}, .expected = "0n6 0v0 1v0 2v0" },
        .{ .stage = 0, .codes = &.{28}, .expected = "0n28 0v0 1v0 2v0" },
        .{ .stage = 1, .codes = &.{6}, .expected = "0n0 1n6 1v0 2v0" },
        .{ .stage = 1, .codes = &.{28}, .expected = "0n0 1n28 1v0 2v0" },
        .{ .stage = 2, .codes = &.{6}, .expected = "0n0 1n0 2n6 2v0" },
        .{ .stage = 2, .codes = &.{28}, .expected = "0n0 1n0 2n28 2v0" },
        .{ .stage = 0, .codes = &.{ 6, 28 }, .expected = "0n6 0v28" },
        .{ .stage = 0, .codes = &.{ 28, 6 }, .expected = "0n28 0v6" },
        .{ .stage = 1, .codes = &.{ 6, 28 }, .expected = "0n0 1n6 1v28" },
        .{ .stage = 1, .codes = &.{ 28, 6 }, .expected = "0n0 1n28 1v6" },
        .{ .stage = 2, .codes = &.{ 6, 28 }, .expected = "0n0 1n0 2n6 2v28" },
        .{ .stage = 2, .codes = &.{ 28, 6 }, .expected = "0n0 1n0 2n28 2v6" },
        .{ .stage = 0, .codes = &.{22}, .expected = "0n22" },
        .{ .stage = 0, .codes = &.{60}, .expected = "0n60" },
        .{ .stage = 0, .codes = &.{7}, .expected = "0n7" },
        .{ .stage = 0, .codes = &.{23}, .expected = "0n23" },
        .{ .stage = 0, .codes = &.{null}, .expected = "0nx" },
        .{ .stage = 1, .codes = &.{22}, .expected = "0n0 1n22" },
        .{ .stage = 1, .codes = &.{60}, .expected = "0n0 1n60" },
        .{ .stage = 1, .codes = &.{7}, .expected = "0n0 1n7" },
        .{ .stage = 1, .codes = &.{23}, .expected = "0n0 1n23" },
        .{ .stage = 1, .codes = &.{null}, .expected = "0n0 1nx" },
        .{ .stage = 2, .codes = &.{22}, .expected = "0n0 1n0 2n22" },
        .{ .stage = 2, .codes = &.{60}, .expected = "0n0 1n0 2n60" },
        .{ .stage = 2, .codes = &.{7}, .expected = "0n0 1n0 2n7" },
        .{ .stage = 2, .codes = &.{23}, .expected = "0n0 1n0 2n23" },
        .{ .stage = 2, .codes = &.{null}, .expected = "0n0 1n0 2nx" },
        .{ .stage = 1, .codes = &.{6}, .sticky_latest = true, .expected = "0n6 0v0 1v6" },
        .{ .stage = 2, .codes = &.{6}, .sticky_latest = true, .expected = "0n6 0v0 1v0 2v6" },
        // A later run starts with ordinary address selection.
        .{ .stage = 0, .codes = &.{}, .expected = "0n0 1n0 2n0" },
    };
    for (scripts) |script| {
        var buffer: [128]u8 = undefined;
        try std.testing.expectEqualStrings(script.expected, try traceRun(&buffer, script.stage, script.codes, script.sticky_latest));
    }
    for (0..3) |stage| for (0..257) |raw| {
        const code: ?u8 = if (raw == 256) null else @intCast(raw);
        if (code == 0) continue;
        var buffer: [128]u8 = undefined;
        var expected_buffer: [128]u8 = undefined;
        var expected = std.Io.Writer.fixed(&expected_buffer);
        for (0..stage) |earlier| try expected.print("{d}n0 ", .{earlier});
        try expected.print("{d}n{s}", .{ stage, if (code) |value| std.fmt.bufPrint(buffer[100..], "{d}", .{value}) catch unreachable else "x" });
        if (code == 6 or code == 28) {
            try expected.print(" {d}v0", .{stage});
            for (stage + 1..3) |later| try expected.print(" {d}v0", .{later});
        }
        try std.testing.expectEqualStrings(expected.buffered(), try traceRun(buffer[0..100], @intCast(stage), &.{code}, false));
    };
}

/// The shell's three downloads of one run, driven by `after` with a full
/// budget: `codes` fail attempts of `stage` in order and `sticky_latest`
/// also fails the first latest attempt with exit 6. Writes "stage family code".
fn traceRun(buffer: []u8, stage: u2, codes: []const ?u8, sticky_latest: bool) ![]const u8 {
    var trace = std.Io.Writer.fixed(buffer);
    var family: Family = .automatic;
    for (0..3) |path| {
        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            const code: ?u8 = if (path == stage and attempt < codes.len)
                codes[attempt]
            else if (sticky_latest and path == 0 and attempt == 0) 6 else 0;
            if (trace.end != 0) try trace.writeAll(" ");
            try trace.print("{d}{c}", .{ path, @as(u8, if (family == .ipv4) 'v' else 'n') });
            if (code) |value| try trace.print("{d}", .{value}) else try trace.writeAll("x");
            switch (after(family, code, download_timeout_ns)) {
                .done => |kept| {
                    family = kept;
                    break;
                },
                .retry_ipv4 => family = .ipv4,
                .failed => return trace.buffered(),
            }
        }
    }
    return trace.buffered();
}

test "SH-71 a failed download reports only its last line" {
    for ([_]struct { []const u8, []const u8 }{
        .{ "", "" },
        .{ "\r\n", "" },
        .{ "\n\n\n", "" },
        .{ "only", "only\n" },
        .{ "first\r\nlast\r\n", "last\n" },
        .{ "earlier line\nlast curl failure\n", "last curl failure\n" },
        .{ "curl fixture: discarded earlier diagnostic\ncurl fixture final: /releases/latest attempt 2 exit 28\n", "curl fixture final: /releases/latest attempt 2 exit 28\n" },
        .{ "curl: (22) The requested URL returned error: 403\n", "curl: (22) The requested URL returned error: 403\n" },
        .{ "curl: \x1b[31m\xff\n", "curl: \\x1b[31m\\xff\n" },
    }) |case| {
        var buffer: [128]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try writeDiagnostic(&writer, case[0]);
        try std.testing.expectEqualStrings(case[1], writer.buffered());
    }
}
