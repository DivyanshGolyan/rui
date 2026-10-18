//! Startup diagnostic file sequence over values: file names, the open-time
//! scan, rotation and torn-tail repair. `HostDiagnostics.zig` owns the
//! directory, file handles, permission checks and clock, and applies these
//! decisions.
const std = @import("std");

const DiagnosticFiles = @This();

pub const max_files = 16;
pub const max_record_bytes = 4096;

file_cap: u64,
next: u64 = 1,
oldest: u64 = 0,
count: usize = 0,

/// Each of the retained files gets an equal share of the total cap.
pub fn init(cap_bytes: u64) error{InvalidDiagnosticCap}!DiagnosticFiles {
    const file_cap = cap_bytes / max_files;
    if (file_cap < max_record_bytes) return error.InvalidDiagnosticCap;
    return .{ .file_cap = file_cap };
}

/// Account for one existing file found while opening.
pub fn observe(self: *DiagnosticFiles, id: u64, length: u64) error{ InvalidDiagnosticFile, DiagnosticSequenceExhausted }!void {
    if (length > self.file_cap) return error.InvalidDiagnosticFile;
    self.count += 1;
    if (self.oldest == 0 or id < self.oldest) self.oldest = id;
    if (id >= self.next) self.next = std.math.add(u64, id, 1) catch return error.DiagnosticSequenceExhausted;
}

/// The file new records append to after the scan, if any exists.
pub fn latest(self: DiagnosticFiles) error{InvalidDiagnosticFile}!?u64 {
    if (self.count > max_files) return error.InvalidDiagnosticFile;
    return if (self.count == 0) null else self.next - 1;
}

/// A record starts a new file when none is open or it would pass the cap.
pub fn needsRotation(self: DiagnosticFiles, open_length: ?u64, record_bytes: usize) bool {
    const length = open_length orelse return true;
    return length + record_bytes > self.file_cap;
}

/// The file to delete before rotating, so retained files never exceed the
/// cap even briefly.
pub fn retiring(self: DiagnosticFiles) ?u64 {
    return if (self.count == max_files) self.oldest else null;
}

/// Record the deletion of `retiring`. `lowest_remaining` is the lowest file
/// number still present, or null when the scan found none.
pub fn retired(self: *DiagnosticFiles, lowest_remaining: ?u64) void {
    self.count -= 1;
    self.oldest = @min(lowest_remaining orelse self.next, self.next);
}

/// The number of the next file to create.
pub fn rotation(self: DiagnosticFiles) error{DiagnosticSequenceExhausted}!u64 {
    if (self.next == std.math.maxInt(u64)) return error.DiagnosticSequenceExhausted;
    return self.next;
}

/// Record that the file numbered by `rotation` now exists.
pub fn rotated(self: *DiagnosticFiles) void {
    if (self.count == 0) self.oldest = self.next;
    self.next += 1;
    self.count += 1;
}

/// The length that keeps only complete records. `tail` holds the file's last
/// `@min(length, max_record_bytes)` bytes. A record is never longer than
/// `max_record_bytes`, so a longer file without a newline in its tail is not
/// a diagnostic file.
pub fn repairedLength(length: u64, tail: []const u8) error{InvalidDiagnosticFile}!u64 {
    std.debug.assert(tail.len == @min(length, max_record_bytes));
    if (length == 0 or tail[tail.len - 1] == '\n') return length;
    const last = std.mem.lastIndexOfScalar(u8, tail, '\n') orelse {
        if (length > tail.len) return error.InvalidDiagnosticFile;
        return 0;
    };
    return length - tail.len + last + 1;
}

pub fn nameFor(buffer: []u8, id: u64) error{NoSpaceLeft}![]const u8 {
    return std.fmt.bufPrint(buffer, "host-{d}.jsonl", .{id});
}

/// The number of a file this writer created, or null for any other name.
pub fn fileNumber(name: []const u8) ?u64 {
    if (!std.mem.startsWith(u8, name, "host-") or !std.mem.endsWith(u8, name, ".jsonl")) return null;
    const id = std.fmt.parseInt(u64, name[5 .. name.len - 6], 10) catch return null;
    var canonical: [64]u8 = undefined;
    if (id == 0 or !std.mem.eql(u8, name, nameFor(&canonical, id) catch return null)) return null;
    return id;
}

test "only canonical writer file names have numbers" {
    const cases = [_]struct { name: []const u8, expected: ?u64 }{
        .{ .name = "host-1.jsonl", .expected = 1 },
        .{ .name = "host-18446744073709551615.jsonl", .expected = std.math.maxInt(u64) },
        .{ .name = "host-0.jsonl", .expected = null },
        .{ .name = "host-01.jsonl", .expected = null },
        .{ .name = "host-+1.jsonl", .expected = null },
        .{ .name = "host-.jsonl", .expected = null },
        .{ .name = "host-18446744073709551616.jsonl", .expected = null },
        .{ .name = "host-1.json", .expected = null },
        .{ .name = "Host-1.jsonl", .expected = null },
        .{ .name = "host-1.jsonl.tmp", .expected = null },
    };
    for (cases) |case| try std.testing.expectEqual(case.expected, fileNumber(case.name));
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("host-42.jsonl", try nameFor(&buffer, 42));
}

test "the cap is shared by sixteen files and each holds at least one record" {
    try std.testing.expectError(error.InvalidDiagnosticCap, init(max_files * max_record_bytes - 1));
    try std.testing.expectEqual(@as(u64, max_record_bytes), (try init(max_files * max_record_bytes)).file_cap);
    try std.testing.expectEqual(@as(u64, 8 * 1024 * 1024), (try init(128 * 1024 * 1024)).file_cap);
}

test "the open-time scan continues after the highest number and rejects oversize state" {
    var files = try init(max_files * max_record_bytes);
    try std.testing.expectEqual(@as(?u64, null), try files.latest());
    // Directory order is arbitrary, and gaps are allowed.
    for ([_]u64{ 7, 3, 9 }) |id| try files.observe(id, max_record_bytes);
    try std.testing.expectEqual(@as(u64, 3), files.oldest);
    try std.testing.expectEqual(@as(u64, 10), files.next);
    try std.testing.expectEqual(@as(?u64, 9), try files.latest());
    try std.testing.expectError(error.InvalidDiagnosticFile, files.observe(11, max_record_bytes + 1));

    var exhausted = try init(max_files * max_record_bytes);
    try std.testing.expectError(error.DiagnosticSequenceExhausted, exhausted.observe(std.math.maxInt(u64), 0));

    var crowded = try init(max_files * max_record_bytes);
    for (1..max_files + 2) |id| try crowded.observe(id, 0);
    try std.testing.expectError(error.InvalidDiagnosticFile, crowded.latest());
}

test "rotation deletes the oldest file before a seventeenth exists" {
    var files = try init(max_files * max_record_bytes);
    try std.testing.expect(files.needsRotation(null, 1));
    try std.testing.expectEqual(@as(?u64, null), files.retiring());
    for (1..max_files + 1) |expected| {
        try std.testing.expectEqual(@as(u64, expected), try files.rotation());
        files.rotated();
    }
    try std.testing.expectEqual(@as(u64, 1), files.oldest);
    try std.testing.expect(!files.needsRotation(max_record_bytes - 10, 10));
    try std.testing.expect(files.needsRotation(max_record_bytes - 10, 11));
    try std.testing.expectEqual(@as(?u64, 1), files.retiring());
    files.retired(2);
    try std.testing.expectEqual(@as(usize, max_files - 1), files.count);
    try std.testing.expectEqual(@as(?u64, null), files.retiring());
    try std.testing.expectEqual(@as(u64, 17), try files.rotation());
    files.rotated();
    try std.testing.expectEqual(@as(u64, 2), files.oldest);
    try std.testing.expectEqual(@as(?u64, 2), files.retiring());

    // A first file after an empty scan is also the oldest.
    var empty = try init(max_files * max_record_bytes);
    empty.next = 5;
    empty.rotated();
    try std.testing.expectEqual(@as(u64, 5), empty.oldest);
    empty.next = std.math.maxInt(u64);
    try std.testing.expectError(error.DiagnosticSequenceExhausted, empty.rotation());
}

test "tail repair keeps only complete records" {
    const cases = [_]struct { length: u64, tail: []const u8, expected: ?u64 }{
        .{ .length = 0, .tail = "", .expected = 0 },
        .{ .length = 4, .tail = "{}\n\n", .expected = 4 },
        .{ .length = 8, .tail = "{}\n{\"tor", .expected = 3 },
        // A file holding only a torn first record is emptied.
        .{ .length = 4, .tail = "{\"to", .expected = 0 },
        // Only the tail is read; earlier bytes are kept whole.
        .{ .length = 10_000, .tail = &(@as([max_record_bytes - 5]u8, @splat('x')) ++ "\n{\"t".*), .expected = 10_000 - 4 },
    };
    for (cases) |case| {
        const result = repairedLength(case.length, case.tail);
        if (case.expected) |expected| try std.testing.expectEqual(expected, try result) else try std.testing.expectError(error.InvalidDiagnosticFile, result);
    }
    try std.testing.expectError(error.InvalidDiagnosticFile, repairedLength(max_record_bytes + 1, &(@as([max_record_bytes]u8, @splat('x')))));
}
