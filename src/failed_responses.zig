//! Bounded private retention of the raw response bytes of failed model
//! Attempts. After settlement, the execution owner copies the same response
//! capture it classified into `diagnostics/failed-responses/` under the Store:
//! one exact body file and one JSON metadata file per record, named by
//! retention sequence, Operation and Attempt. Records are optional local
//! diagnostics. They never determine recovery or continuation, and a
//! retention fault never changes the saved failure. Only this owner writes
//! the directory while the Host holds the Store lease, and it deletes only
//! canonically named record files there.
const std = @import("std");
const attempt = @import("attempt.zig");
const HostDiagnostics = @import("HostDiagnostics.zig");

pub const directory = "diagnostics/failed-responses";
pub const capture_cap_bytes: u64 = 16 * 1024 * 1024;
pub const total_cap_bytes: u64 = 64 * 1024 * 1024;
pub const max_records = 256;
/// Reserved disk room for one metadata file; the encoder cannot exceed it.
const max_metadata_bytes = 8192;
const copy_window_bytes = 64 * 1024;

pub const Limits = struct {
    capture_bytes: u64 = capture_cap_bytes,
    total_bytes: u64 = total_cap_bytes,
    records: usize = max_records,
};

/// How the transport ended the capture being retained.
pub const Transfer = enum {
    /// A complete HTTP response, sealed before interpretation.
    complete,
    /// The transfer failed after the provider sent these bytes.
    interrupted,
    /// Local capture failed; these are the bytes written before the failure.
    capture_failed,
};

/// Borrowed through `retain`; read positionally, never modified.
pub const Source = struct {
    file: std.Io.File,
    length: u64,
    transfer: Transfer,
};

pub const Failure = struct {
    binding: attempt.AttemptBinding,
    code: []const u8,
    /// The exact bounded diagnostic text saved with the Attempt's failure.
    diagnostic: ?[]const u8 = null,
    http_status: ?u16 = null,
    request_id: []const u8 = "",
};

/// `complete` only when every captured byte of a complete transfer is kept.
pub const Status = enum { complete, partial, omitted };

pub const Retained = struct {
    sequence: u64,
    status: Status,
    /// Why the body is absent from an `omitted` record.
    omission: ?anyerror = null,
};

pub fn open(io: std.Io, store_dir: std.Io.Dir) !std.Io.Dir {
    var dir = try store_dir.createDirPathOpen(io, directory, .{
        .permissions = .fromMode(0o700),
        .open_options = .{ .iterate = true, .follow_symlinks = false },
    });
    errdefer dir.close(io);
    try HostDiagnostics.private(dir.handle, true);
    return dir;
}

/// Evicts oldest records first, then writes the new one. A failed body copy
/// still records `omitted` metadata. An error means no new record was made;
/// the caller reports it and leaves the Attempt's outcome unchanged.
pub fn retain(io: std.Io, dir: std.Io.Dir, limits: Limits, source: Source, failure: Failure) !Retained {
    std.debug.assert(limits.records != 0 and limits.records <= max_records);
    std.debug.assert(limits.capture_bytes + max_metadata_bytes <= limits.total_bytes);
    const kept = @min(source.length, limits.capture_bytes);
    const sequence = try prune(io, dir, limits, kept + max_metadata_bytes);
    var body_name: NameBuffer = undefined;
    const body = nameFor(&body_name, sequence, failure.binding, .body);
    var digest: [32]u8 = undefined;
    const omission: ?anyerror = if (copyBody(io, dir, sequence, failure.binding, source.file, kept, &digest)) null else |err| err;
    const status: Status = if (omission != null)
        .omitted
    else if (source.transfer == .complete and kept == source.length)
        .complete
    else
        .partial;
    var encoded: [max_metadata_bytes]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&encoded);
    encodeMetadata(&writer, .{
        .failure = failure,
        .source = source,
        .status = status,
        .kept = if (omission == null) kept else 0,
        .digest = if (omission == null) &digest else null,
        .body = if (omission == null) body else null,
        .omission = omission,
        .time_ns = std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds,
    }) catch unreachable;
    writeRecordFile(io, dir, sequence, failure.binding, .metadata, writer.buffered()) catch |err| {
        // An orphan body stays named and counted, so the next prune evicts it.
        if (omission == null) dir.deleteFile(io, body) catch {};
        return err;
    };
    return .{ .sequence = sequence, .status = status, .omission = omission };
}

const Part = enum { body, metadata, body_tmp, metadata_tmp };
const NameBuffer = [96]u8;
const suffixes = [_][]const u8{ ".body", ".json", ".body.tmp", ".json.tmp" };

const Name = struct { sequence: u64, binding: attempt.AttemptBinding, part: Part };

fn nameFor(buffer: *NameBuffer, sequence: u64, binding: attempt.AttemptBinding, part: Part) []const u8 {
    return std.fmt.bufPrint(buffer, "response-{d}-{d}-{d}{s}", .{
        sequence, binding.operation_id, binding.attempt_ordinal, suffixes[@backingInt(part)],
    }) catch unreachable;
}

fn parse(name: []const u8) ?Name {
    const prefix = "response-";
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    // Longer `.tmp` suffixes first: `.body` is a suffix of none, but order
    // keeps the match exact.
    const part: Part = for ([_]Part{ .body_tmp, .metadata_tmp, .body, .metadata }) |candidate| {
        if (std.mem.endsWith(u8, name, suffixes[@backingInt(candidate)])) break candidate;
    } else return null;
    var fields = std.mem.splitScalar(u8, name[prefix.len .. name.len - suffixes[@backingInt(part)].len], '-');
    var values: [3]u64 = undefined;
    for (&values) |*value| value.* = std.fmt.parseInt(u64, fields.next() orelse return null, 10) catch return null;
    if (fields.next() != null or values[0] == 0) return null;
    const parsed: Name = .{ .sequence = values[0], .binding = .{
        .turn_id = 0,
        .operation_id = values[1],
        .attempt_ordinal = values[2],
    }, .part = part };
    var canonical: NameBuffer = undefined;
    if (!std.mem.eql(u8, name, nameFor(&canonical, parsed.sequence, parsed.binding, part))) return null;
    return parsed;
}

const Record = struct { sequence: u64, binding: attempt.AttemptBinding, bytes: u64 };

/// Oldest-first count of existing records to delete before one more record
/// of `incoming` bytes fits both the byte and the record bounds.
fn evictionCount(records: []const Record, limits: Limits, incoming: u64) usize {
    var total: u64 = 0;
    for (records) |record| total +|= record.bytes;
    var evicted: usize = 0;
    while (evicted < records.len and
        (records.len - evicted + 1 > limits.records or total +| incoming > limits.total_bytes)) : (evicted += 1)
        total -= records[evicted].bytes;
    return evicted;
}

/// Returns the next sequence after deleting interrupted writes and evicting
/// enough records for `incoming` bytes. A failed deletion never counts as
/// reclaimed space: it fails this retention instead.
fn prune(io: std.Io, dir: std.Io.Dir, limits: Limits, incoming: u64) !u64 {
    while (true) {
        var stale_buffer: NameBuffer = undefined;
        var stale: ?[]const u8 = null;
        var iterator = dir.iterate();
        while (try iterator.next(io)) |entry| {
            const name = parse(entry.name) orelse continue;
            if (name.part != .body_tmp and name.part != .metadata_tmp) continue;
            @memcpy(stale_buffer[0..entry.name.len], entry.name);
            stale = stale_buffer[0..entry.name.len];
            break;
        }
        try dir.deleteFile(io, stale orelse break);
    }
    var records: [max_records + 1]Record = undefined;
    var count: usize = 0;
    var next: u64 = 1;
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        const name = parse(entry.name) orelse continue;
        const stat = try dir.statFile(io, entry.name, .{ .follow_symlinks = false });
        if (stat.kind != .file) return error.InvalidFailedResponseRecord;
        const record = for (records[0..count]) |*record| {
            if (record.sequence == name.sequence) break record;
        } else blk: {
            if (count == records.len) return error.TooManyFailedResponseRecords;
            records[count] = .{ .sequence = name.sequence, .binding = name.binding, .bytes = 0 };
            count += 1;
            break :blk &records[count - 1];
        };
        record.bytes +|= stat.size;
        next = @max(next, std.math.add(u64, name.sequence, 1) catch return error.FailedResponseSequenceExhausted);
    }
    std.mem.sortUnstable(Record, records[0..count], {}, struct {
        fn lessThan(_: void, left: Record, right: Record) bool {
            return left.sequence < right.sequence;
        }
    }.lessThan);
    for (records[0..evictionCount(records[0..count], limits, incoming)]) |record| {
        // Metadata first: a remaining body without metadata is still evicted next time.
        for ([_]Part{ .metadata, .body }) |part| {
            var name: NameBuffer = undefined;
            dir.deleteFile(io, nameFor(&name, record.sequence, record.binding, part)) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
        }
    }
    return next;
}

fn copyBody(
    io: std.Io,
    dir: std.Io.Dir,
    sequence: u64,
    binding: attempt.AttemptBinding,
    source: std.Io.File,
    kept: u64,
    digest: *[32]u8,
) !void {
    var temporary: NameBuffer = undefined;
    const temporary_name = nameFor(&temporary, sequence, binding, .body_tmp);
    const file = try dir.createFile(io, temporary_name, .{ .exclusive = true, .permissions = .fromMode(0o600) });
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    copy(io, source, file, kept, &hash) catch |err| {
        file.close(io);
        // A remaining temporary file stops the next prune before any growth.
        dir.deleteFile(io, temporary_name) catch {};
        return err;
    };
    file.close(io);
    hash.final(digest);
    var final: NameBuffer = undefined;
    dir.rename(temporary_name, dir, nameFor(&final, sequence, binding, .body), io) catch |err| {
        dir.deleteFile(io, temporary_name) catch {};
        return err;
    };
}

fn copy(io: std.Io, source: std.Io.File, destination: std.Io.File, length: u64, hash: *std.crypto.hash.sha2.Sha256) !void {
    var window: [copy_window_bytes]u8 = undefined;
    var offset: u64 = 0;
    while (offset < length) {
        const size: usize = @intCast(@min(window.len, length - offset));
        if (try source.readPositionalAll(io, window[0..size], offset) != size) return error.ShortResponseCaptureRead;
        hash.update(window[0..size]);
        try destination.writeStreamingAll(io, window[0..size]);
        offset += size;
    }
}

fn writeRecordFile(io: std.Io, dir: std.Io.Dir, sequence: u64, binding: attempt.AttemptBinding, part: Part, bytes: []const u8) !void {
    std.debug.assert(part == .metadata);
    var temporary: NameBuffer = undefined;
    const temporary_name = nameFor(&temporary, sequence, binding, .metadata_tmp);
    const file = try dir.createFile(io, temporary_name, .{ .exclusive = true, .permissions = .fromMode(0o600) });
    file.writeStreamingAll(io, bytes) catch |err| {
        file.close(io);
        dir.deleteFile(io, temporary_name) catch {};
        return err;
    };
    file.close(io);
    var final: NameBuffer = undefined;
    dir.rename(temporary_name, dir, nameFor(&final, sequence, binding, part), io) catch |err| {
        dir.deleteFile(io, temporary_name) catch {};
        return err;
    };
}

const Metadata = struct {
    failure: Failure,
    source: Source,
    status: Status,
    kept: u64,
    digest: ?*const [32]u8,
    body: ?[]const u8,
    omission: ?anyerror,
    time_ns: i96,
};

fn encodeMetadata(writer: *std.Io.Writer, metadata: Metadata) !void {
    const failure = metadata.failure;
    try writer.print("{{\"operation\":\"{d}\",\"attempt\":\"{d}\",\"turn\":\"{d}\",\"code\":", .{
        failure.binding.operation_id, failure.binding.attempt_ordinal, failure.binding.turn_id,
    });
    try std.json.Stringify.value(failure.code, .{}, writer);
    try writer.writeAll(",\"diagnostic\":");
    try std.json.Stringify.value(failure.diagnostic, .{}, writer);
    try writer.writeAll(",\"http_status\":");
    try std.json.Stringify.value(failure.http_status, .{}, writer);
    try writer.writeAll(",\"request_id\":");
    // Header bytes need not be UTF-8; an unencodable correlation is omitted.
    const request_id: ?[]const u8 = if (failure.request_id.len != 0 and std.unicode.utf8ValidateSlice(failure.request_id))
        failure.request_id
    else
        null;
    try std.json.Stringify.value(request_id, .{}, writer);
    try writer.print(",\"status\":\"{t}\",\"transfer\":\"{t}\",\"captured_bytes\":\"{d}\",\"retained_bytes\":\"{d}\",\"truncated\":{},\"retained_sha256\":", .{
        metadata.status,
        metadata.source.transfer,
        metadata.source.length,
        metadata.kept,
        metadata.omission == null and metadata.kept < metadata.source.length,
    });
    if (metadata.digest) |digest| try writer.print("\"{x}\"", .{digest}) else try writer.writeAll("null");
    try writer.writeAll(",\"body\":");
    try std.json.Stringify.value(metadata.body, .{}, writer);
    try writer.writeAll(",\"omitted_reason\":");
    try std.json.Stringify.value(if (metadata.omission) |err| @errorName(err) else null, .{}, writer);
    try writer.print(",\"time_ns\":\"{d}\"}}\n", .{metadata.time_ns});
}

const testing = std.testing;

fn testCapture(dir: std.Io.Dir, name: []const u8, bytes: []const u8) !std.Io.File {
    const file = try dir.createFile(testing.io, name, .{ .read = true });
    try file.writeStreamingAll(testing.io, bytes);
    return file;
}

fn readAlloc(dir: std.Io.Dir, name: []const u8) ![]u8 {
    return dir.readFileAlloc(testing.io, name, testing.allocator, .limited(1 << 20));
}

fn expectMode(dir: std.Io.Dir, name: []const u8, mode: u32) !void {
    const stat = try dir.statFile(testing.io, name, .{ .follow_symlinks = false });
    try testing.expectEqual(mode, @as(u32, @intCast(stat.permissions.toMode() & 0o777)));
}

test "failed response records keep exact bytes, signal partial and omitted captures, and stay private" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try open(io, tmp.dir);
    defer dir.close(io);
    try expectMode(tmp.dir, directory, 0o700);

    // Every byte value, so encoding or text handling cannot pass unnoticed.
    var raw: [1024]u8 = undefined;
    for (&raw, 0..) |*byte, index| byte.* = @truncate(index *% 7 +% 3);
    const source = try testCapture(tmp.dir, "capture", &raw);
    defer source.close(io);
    const binding: attempt.AttemptBinding = .{ .turn_id = 11, .operation_id = 22, .attempt_ordinal = 3 };
    const diagnostic = "{\"reason\":\"IncompleteProviderOutput\",\"stage\":\"response\",\"byte_offset\":\"900\",\"output_index\":null}";
    const complete = try retain(io, dir, .{}, .{ .file = source, .length = raw.len, .transfer = .complete }, .{
        .binding = binding,
        .code = "malformed_provider_output",
        .diagnostic = diagnostic,
        .http_status = 200,
        .request_id = "request-\xff",
    });
    try testing.expectEqual(Retained{ .sequence = 1, .status = .complete }, complete);
    const body = try readAlloc(dir, "response-1-22-3.body");
    defer testing.allocator.free(body);
    try testing.expectEqualSlices(u8, &raw, body);
    try expectMode(dir, "response-1-22-3.body", 0o600);
    try expectMode(dir, "response-1-22-3.json", 0o600);
    const metadata_bytes = try readAlloc(dir, "response-1-22-3.json");
    defer testing.allocator.free(metadata_bytes);
    const metadata = try std.json.parseFromSlice(std.json.Value, testing.allocator, metadata_bytes, .{});
    defer metadata.deinit();
    const object = metadata.value.object;
    var expected_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&raw, &expected_digest, .{});
    var expected_hex: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&expected_hex, "{x}", .{&expected_digest});
    try testing.expectEqualStrings("22", object.get("operation").?.string);
    try testing.expectEqualStrings("3", object.get("attempt").?.string);
    try testing.expectEqualStrings("11", object.get("turn").?.string);
    try testing.expectEqualStrings(diagnostic, object.get("diagnostic").?.string);
    try testing.expectEqual(@as(i64, 200), object.get("http_status").?.integer);
    try testing.expect(object.get("request_id").? == .null);
    try testing.expectEqualStrings("complete", object.get("status").?.string);
    try testing.expectEqualStrings("1024", object.get("captured_bytes").?.string);
    try testing.expectEqualStrings("1024", object.get("retained_bytes").?.string);
    try testing.expectEqualStrings(&expected_hex, object.get("retained_sha256").?.string);
    try testing.expectEqualStrings("response-1-22-3.body", object.get("body").?.string);

    // Truncation of a complete transfer is partial, never complete, and the
    // digest covers exactly the retained prefix.
    const truncated = try retain(io, dir, .{ .capture_bytes = 100 }, .{ .file = source, .length = raw.len, .transfer = .complete }, .{ .binding = binding, .code = "provider_http_400" });
    try testing.expectEqual(Status.partial, truncated.status);
    const prefix = try readAlloc(dir, "response-2-22-3.body");
    defer testing.allocator.free(prefix);
    try testing.expectEqualSlices(u8, raw[0..100], prefix);
    const truncated_metadata = try readAlloc(dir, "response-2-22-3.json");
    defer testing.allocator.free(truncated_metadata);
    var prefix_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(raw[0..100], &prefix_digest, .{});
    var prefix_hex: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&prefix_hex, "{x}", .{&prefix_digest});
    try testing.expect(std.mem.indexOf(u8, truncated_metadata, "\"captured_bytes\":\"1024\",\"retained_bytes\":\"100\",\"truncated\":true") != null);
    try testing.expect(std.mem.indexOf(u8, truncated_metadata, &prefix_hex) != null);

    // An interrupted transfer is partial even when every byte fits.
    const interrupted = try retain(io, dir, .{}, .{ .file = source, .length = 10, .transfer = .interrupted }, .{ .binding = binding, .code = "provider_transport_failure" });
    try testing.expectEqual(Status.partial, interrupted.status);

    // A capture that cannot be read leaves no body and says why.
    const omitted = try retain(io, dir, .{}, .{ .file = source, .length = raw.len + 1, .transfer = .complete }, .{ .binding = binding, .code = "response_read_failed" });
    try testing.expectEqual(Status.omitted, omitted.status);
    try testing.expectError(error.FileNotFound, dir.statFile(io, "response-4-22-3.body", .{}));
    try testing.expectError(error.FileNotFound, dir.statFile(io, "response-4-22-3.body.tmp", .{}));
    const omitted_metadata = try readAlloc(dir, "response-4-22-3.json");
    defer testing.allocator.free(omitted_metadata);
    try testing.expect(std.mem.indexOf(u8, omitted_metadata, "\"status\":\"omitted\"") != null);
    try testing.expect(std.mem.indexOf(u8, omitted_metadata, "\"retained_sha256\":null,\"body\":null,\"omitted_reason\":\"ShortResponseCaptureRead\"") != null);
}

test "failed response retention evicts oldest records only and fails closed on undeletable entries" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try open(io, tmp.dir);
    defer dir.close(io);
    const bytes = @as([4096]u8, @splat('r'));
    const source = try testCapture(tmp.dir, "capture", &bytes);
    defer source.close(io);
    // Lookalikes and unrelated files are preserved and uncounted.
    for ([_][]const u8{ "notes.txt", "response-01-1-1.body", "response-1-1.body", "response-0-1-1.json", "host-1.jsonl" }) |name| {
        const file = try dir.createFile(io, name, .{});
        file.close(io);
    }
    const startup = try tmp.dir.createFile(io, "diagnostics/host-1.jsonl", .{});
    startup.close(io);
    // A stale interrupted write is removed before growth.
    const stale = try dir.createFile(io, "response-9-1-1.body.tmp", .{});
    stale.close(io);
    const limits: Limits = .{ .capture_bytes = 4096, .total_bytes = 3 * 4096 + 3 * max_metadata_bytes, .records = 3 };
    for (1..6) |operation| {
        const retained = try retain(io, dir, limits, .{ .file = source, .length = bytes.len, .transfer = .complete }, .{
            .binding = .{ .turn_id = 1, .operation_id = operation, .attempt_ordinal = 1 },
            .code = "provider_http_400",
        });
        try testing.expectEqual(@as(u64, operation), retained.sequence);
    }
    var total: u64 = 0;
    var names: usize = 0;
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (parse(entry.name) == null) continue;
        names += 1;
        total += (try dir.statFile(io, entry.name, .{})).size;
    }
    try testing.expectEqual(@as(usize, 6), names);
    try testing.expect(total <= limits.total_bytes);
    for ([_][]const u8{ "response-1-1-1.json", "response-2-2-1.body", "response-9-1-1.body.tmp" }) |name|
        try testing.expectError(error.FileNotFound, dir.statFile(io, name, .{}));
    for ([_][]const u8{ "response-3-3-1.body", "response-5-5-1.json", "notes.txt", "response-01-1-1.body", "response-1-1.body", "response-0-1-1.json", "host-1.jsonl" }) |name|
        _ = try dir.statFile(io, name, .{});
    _ = try tmp.dir.statFile(io, "diagnostics/host-1.jsonl", .{});

    // Byte pressure alone evicts oldest first, well under the record count.
    _ = try retain(io, dir, .{ .capture_bytes = 4096, .total_bytes = 2 * 4096 + 2 * max_metadata_bytes, .records = 10 }, .{ .file = source, .length = bytes.len, .transfer = .complete }, .{
        .binding = .{ .turn_id = 1, .operation_id = 6, .attempt_ordinal = 1 },
        .code = "provider_http_400",
    });
    try testing.expectError(error.FileNotFound, dir.statFile(io, "response-3-3-1.body", .{}));
    _ = try dir.statFile(io, "response-4-4-1.body", .{});
    _ = try dir.statFile(io, "response-6-6-1.body", .{});

    // A non-file in the record namespace cannot be reclaimed, so retention
    // fails without growth rather than claim the space.
    try dir.createDir(io, "response-7-7-1.json.tmp", .fromMode(0o700));
    if (retain(io, dir, limits, .{ .file = source, .length = bytes.len, .transfer = .complete }, .{
        .binding = .{ .turn_id = 1, .operation_id = 8, .attempt_ordinal = 1 },
        .code = "provider_http_400",
    })) |_| return error.TestUnexpectedResult else |_| {}
    try testing.expectError(error.FileNotFound, dir.statFile(io, "response-7-8-1.json", .{}));
    _ = try dir.statFile(io, "response-4-4-1.body", .{});
}

test "failed response eviction is oldest first under both bounds" {
    const records = [_]Record{
        .{ .sequence = 1, .binding = undefined, .bytes = 10 },
        .{ .sequence = 2, .binding = undefined, .bytes = 30 },
        .{ .sequence = 3, .binding = undefined, .bytes = 5 },
    };
    try testing.expectEqual(@as(usize, 0), evictionCount(&records, .{ .total_bytes = 60, .records = 4 }, 15));
    try testing.expectEqual(@as(usize, 1), evictionCount(&records, .{ .total_bytes = 60, .records = 4 }, 16));
    try testing.expectEqual(@as(usize, 2), evictionCount(&records, .{ .total_bytes = 60, .records = 4 }, 46));
    try testing.expectEqual(@as(usize, 1), evictionCount(&records, .{ .total_bytes = 60, .records = 3 }, 0));
    try testing.expectEqual(@as(usize, 3), evictionCount(&records, .{ .total_bytes = 60, .records = 1 }, 0));
    try testing.expectEqual(@as(usize, 0), evictionCount(&.{}, .{ .total_bytes = 60, .records = 1 }, 60));
}
