//! One-shot, cross-version TUI drafts. The Store never owns this transient
//! file: only the departing and replacement clients can read it.
const std = @import("std");
const c = @import("posix");
const Input = @import("SessionInput.zig");
const session_id = @import("session_id.zig");
const protocol = @import("protocol.zig");
const upgrade_status = @import("upgrade_status.zig");
const TerminalText = @import("TerminalText.zig");
const stderr = @import("stderr.zig");

pub const Entry = struct { id: []const u8, snapshot: Input.Snapshot };
pub const Payload = struct {
    v: u8,
    store: []const u8,
    open: ?[]const u8 = null,
    overview: Input.Snapshot,
    drafts: []const Entry,
    line: []const u8,
};

const directory_name = ".rui-relaunch";
const name_bytes = 32 + ".json".len;
// Sparse drafts have no population limit below the Session ID domain. Do not
// impose a smaller arbitrary cap and silently lose an otherwise valid draft.
const max_drafts = std.math.pow(usize, session_id.alphabet.len, session_id.bytes);
// JSON escaping needs at most six bytes per input byte. The remaining space
// covers field names, punctuation, three maximum-width integers and refusal.
const max_snapshot_bytes = 6 * Input.capacity + 256;
const max_entry_bytes = max_snapshot_bytes + 6 * session_id.bytes + 64;
pub const max_encoded_bytes = (max_drafts + 1) * max_entry_bytes +
    6 * (protocol.max_store_bytes + upgrade_status.max_line_bytes) + 256;

/// Caller owns the returned bytes. Field order and defaults are a wire contract.
pub fn encode(gpa: std.mem.Allocator, payload: Payload) ![]u8 {
    try validate(gpa, payload, payload.store);
    return std.json.Stringify.valueAlloc(gpa, payload, .{});
}

/// Owns every decoded string, independently of `bytes`; caller must deinit.
pub fn decode(gpa: std.mem.Allocator, bytes: []const u8, store: []const u8) !std.json.Parsed(Payload) {
    if (bytes.len > max_encoded_bytes) return error.HandoffTooLarge;
    var scanner = std.json.Scanner.initCompleteInput(gpa, bytes);
    defer scanner.deinit();
    return parse(gpa, &scanner, store);
}

fn parse(gpa: std.mem.Allocator, source: anytype, store: []const u8) !std.json.Parsed(Payload) {
    const parsed = try std.json.parseFromTokenSource(Payload, gpa, source, .{
        .allocate = .alloc_always,
        .max_value_len = Input.capacity,
    });
    errdefer parsed.deinit();
    try validate(gpa, parsed.value, store);
    return parsed;
}

fn validate(gpa: std.mem.Allocator, payload: Payload, store: []const u8) !void {
    if (payload.v != 1) return error.UnsupportedHandoffVersion;
    if (payload.store.len == 0 or payload.store.len > protocol.max_store_bytes or
        !std.mem.eql(u8, payload.store, store)) return error.HandoffStoreMismatch;
    if (payload.open) |id| if (!session_id.valid(id)) return error.InvalidHandoffSession;
    if (payload.line.len > upgrade_status.max_line_bytes or !std.unicode.utf8ValidateSlice(payload.line))
        return error.InvalidHandoffLine;
    try validateSnapshot(payload.overview);
    if (payload.drafts.len > max_drafts) return error.HandoffTooLarge;
    var seen: std.AutoHashMap(u32, void) = .init(gpa);
    defer seen.deinit();
    for (payload.drafts) |draft| {
        if (!session_id.valid(draft.id)) return error.InvalidHandoffSession;
        try validateSnapshot(draft.snapshot);
        var key: u32 = 0;
        for (draft.id) |byte| key = (key << 5) | @as(u32, @intCast(std.mem.indexOfScalar(u8, session_id.alphabet, byte).?));
        const entry = try seen.getOrPut(key);
        if (entry.found_existing) return error.DuplicateHandoffDraft;
    }
}

fn validateSnapshot(snapshot: Input.Snapshot) !void {
    if (snapshot.bytes.len > Input.capacity or snapshot.cursor > snapshot.bytes.len or
        !std.unicode.utf8ValidateSlice(snapshot.bytes)) return error.InvalidHandoffDraft;
    // An editor cursor is a byte position, but never inside a UTF-8 codepoint.
    if (snapshot.cursor < snapshot.bytes.len and snapshot.bytes[snapshot.cursor] & 0xc0 == 0x80)
        return error.InvalidHandoffDraft;
}

/// Publishes an exclusively created random 0600 file in HOME/.rui-relaunch
/// (0700). The caller owns its path, and deletes the file if exec fails.
pub fn writeEncoded(init: std.process.Init, home: []const u8, bytes: []const u8) ![]const u8 {
    if (bytes.len > max_encoded_bytes) return error.HandoffTooLarge;
    var directory = try openDirectory(init.io, home, true);
    defer directory.close(init.io);
    var random: [16]u8 = undefined;
    try std.Io.randomSecure(init.io, &random);
    var name_buffer: [name_bytes]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buffer, "{s}.json", .{std.fmt.bytesToHex(random, .lower)});
    const path = try std.fs.path.join(init.gpa, &.{ home, directory_name, name });
    errdefer init.gpa.free(path);
    const file = try directory.createFile(init.io, name, .{
        .exclusive = true,
        .permissions = .fromMode(0o600),
    });
    defer file.close(init.io);
    errdefer _ = discardAt(init, directory, name, path);
    try validateFile(init.io, file);
    try file.writeStreamingAll(init.io, bytes);
    // This is an exec handoff, not durable Store state; no power-loss promise.
    return path;
}

/// Consumes the environment entry even when it names a malformed, missing or
/// wrong-Store handoff. Untrusted paths outside our private directory are not
/// opened or deleted. All read/parse failures intentionally mean no handoff.
pub fn read(init: std.process.Init, home: []const u8, store: []const u8) ?std.json.Parsed(Payload) {
    const slot = init.environ_map.getPtr("RUI_RELAUNCH") orelse return null;
    // Transfer the old owned value out of the map without allocating, so even
    // allocation failure cannot leave an inherited handoff reusable by a child.
    const path = slot.*;
    slot.* = "";
    defer init.environ_map.allocator.free(path);
    if (path.len == 0) return null;
    return readFile(init, home, path, store) catch null;
}

fn readFile(init: std.process.Init, home: []const u8, path: []const u8, store: []const u8) !std.json.Parsed(Payload) {
    const expected = try std.fs.path.join(init.gpa, &.{ home, directory_name });
    defer init.gpa.free(expected);
    if (!std.mem.eql(u8, std.fs.path.dirname(path) orelse "", expected)) return error.InvalidHandoffPath;
    const name = std.fs.path.basename(path);
    if (!validName(name)) return error.InvalidHandoffPath;
    var directory = try openDirectory(init.io, home, false);
    defer directory.close(init.io);
    // Once the location is authenticated, consume even unreadable/malformed
    // entries. A symlink is unlinked here, never followed to its target.
    const fd = std.posix.openat(directory.handle, name, .{
        .ACCMODE = .RDONLY,
        .NONBLOCK = true,
        .NOFOLLOW = true,
        .CLOEXEC = true,
    }, 0) catch |err| {
        _ = discardAt(init, directory, name, path);
        return err;
    };
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
    defer file.close(init.io);
    validateFile(init.io, file) catch |err| {
        _ = discardAt(init, directory, name, path);
        return err;
    };
    // Never restore drafts while their named plaintext file remains behind.
    // Malformed payloads are also one-shot: unlink before parsing.
    if (!discardAt(init, directory, name, path)) return error.HandoffCleanupFailed;
    const stat = try file.stat(init.io);
    if (stat.size > max_encoded_bytes) return error.HandoffTooLarge;
    // Parse from the descriptor: no second full-file allocation beside the
    // decoded drafts, and a sparse malformed file cannot demand its stat size
    // in resident memory. The limit also bounds a file that grows while read.
    var buffer: [1024]u8 = undefined;
    // The JSON scanner peeks into the bounded reader, so that outer reader
    // owns the buffer. Its file source streams directly into that one buffer.
    var file_reader = file.reader(init.io, &.{});
    var limited = file_reader.interface.limited(.limited64(stat.size), &buffer);
    var source = std.json.Reader.init(init.gpa, &limited.interface);
    defer source.deinit();
    const parsed = try parse(init.gpa, &source, store);
    errdefer parsed.deinit();
    if ((try file.stat(init.io)).size != stat.size) return error.HandoffChanged;
    return parsed;
}

/// Remove an unconsumed handoff after failed exec. Cleanup failures retain
/// one safe receipt naming the private data, rather than silently abandoning it.
pub fn discard(init: std.process.Init, path: []const u8) void {
    _ = discardAt(init, std.Io.Dir.cwd(), path, path);
}

fn discardAt(init: std.process.Init, directory: std.Io.Dir, name: []const u8, path: []const u8) bool {
    directory.deleteFile(init.io, name) catch |err| switch (err) {
        error.FileNotFound => return true,
        else => {
            retained(path);
            return false;
        },
    };
    return true;
}

noinline fn retained(path: []const u8) void {
    var buffer: [TerminalText.max_bytes_per_byte * std.Io.Dir.max_path_bytes + 512]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    var text: TerminalText = .{ .mode = .line };
    out.writeAll("rui: Private relaunch data could not be removed: ") catch unreachable;
    text.feed(&out, path) catch return stderr.diagnosticBytes("rui: Private relaunch data could not be removed; check HOME/.rui-relaunch.\n");
    text.finish(&out) catch return stderr.diagnosticBytes("rui: Private relaunch data could not be removed; check HOME/.rui-relaunch.\n");
    out.writeByte('\n') catch return stderr.diagnosticBytes("rui: Private relaunch data could not be removed; check HOME/.rui-relaunch.\n");
    _ = stderr.writeReceipt(out.buffered());
}

fn validName(name: []const u8) bool {
    if (name.len != name_bytes or !std.mem.endsWith(u8, name, ".json")) return false;
    for (name[0..32]) |byte| if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) return false;
    return true;
}

fn openDirectory(io: std.Io, home: []const u8, create: bool) !std.Io.Dir {
    if (!std.fs.path.isAbsolute(home)) return error.InvalidHandoffHome;
    var parent = try std.Io.Dir.cwd().openDir(io, home, .{});
    defer parent.close(io);
    if (create) parent.createDir(io, directory_name, .fromMode(0o700)) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    const directory = try parent.openDir(io, directory_name, .{ .follow_symlinks = false });
    errdefer directory.close(io);
    const stat = try directory.stat(io);
    if (stat.kind != .directory or stat.permissions.toMode() & 0o777 != 0o700)
        return error.InsecureHandoffDirectory;
    try validateOwner(directory.handle);
    return directory;
}

fn validateFile(io: std.Io, file: std.Io.File) !void {
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.permissions.toMode() & 0o777 != 0o600 or stat.nlink != 1)
        return error.InsecureHandoffFile;
    try validateOwner(file.handle);
}

fn validateOwner(handle: anytype) !void {
    var stat: c.struct_stat = undefined;
    if (c.fstat(handle, &stat) != 0) return error.HandoffStatFailed;
    if (stat.st_uid != c.geteuid()) return error.HandoffNotOwned;
}

test "handoff exact versioned bytes and owned round trip" {
    const gpa = std.testing.allocator;
    const payload: Payload = .{
        .v = 1,
        .store = "/store",
        .open = "aaaaaa",
        .overview = .{ .bytes = "hi\nα", .cursor = 3, .anchor = .{ .position = 2, .end = 9 }, .rejected = .overflow },
        .drafts = &.{.{ .id = "bbbbbb", .snapshot = .{ .bytes = "chat", .cursor = 2 } }},
        .line = "Upgraded · Host restarted",
    };
    const encoded = try encode(gpa, payload);
    defer gpa.free(encoded);
    try std.testing.expectEqualStrings(
        "{\"v\":1,\"store\":\"/store\",\"open\":\"aaaaaa\",\"overview\":{\"bytes\":\"hi\\nα\",\"cursor\":3,\"anchor\":{\"position\":2,\"end\":9},\"rejected\":\"overflow\"},\"drafts\":[{\"id\":\"bbbbbb\",\"snapshot\":{\"bytes\":\"chat\",\"cursor\":2,\"anchor\":null,\"rejected\":null}}],\"line\":\"Upgraded · Host restarted\"}",
        encoded,
    );
    const source = try gpa.dupe(u8, encoded);
    const parsed = try decode(gpa, source, "/store");
    defer parsed.deinit();
    gpa.free(source);
    try std.testing.expectEqualDeep(payload, parsed.value);
}

test "handoff validates version Store IDs duplicates and editor bounds" {
    const gpa = std.testing.allocator;
    var payload: Payload = .{ .v = 1, .store = "/store", .overview = .{ .bytes = "", .cursor = 0 }, .drafts = &.{}, .line = "" };
    payload.v = 2;
    try std.testing.expectError(error.UnsupportedHandoffVersion, encode(gpa, payload));
    payload.v = 1;
    payload.open = "ABCDEF";
    try std.testing.expectError(error.InvalidHandoffSession, encode(gpa, payload));
    payload.open = null;
    payload.drafts = &.{ .{ .id = "aaaaaa", .snapshot = payload.overview }, .{ .id = "aaaaaa", .snapshot = payload.overview } };
    try std.testing.expectError(error.DuplicateHandoffDraft, encode(gpa, payload));
    payload.drafts = &.{.{ .id = "bad", .snapshot = payload.overview }};
    try std.testing.expectError(error.InvalidHandoffSession, encode(gpa, payload));
    payload.drafts = &.{};
    payload.overview.cursor = 1;
    try std.testing.expectError(error.InvalidHandoffDraft, encode(gpa, payload));
    payload.overview = .{ .bytes = "α", .cursor = 1 };
    try std.testing.expectError(error.InvalidHandoffDraft, encode(gpa, payload));
    payload.overview = .{ .bytes = "\xff", .cursor = 0 };
    try std.testing.expectError(error.InvalidHandoffDraft, encode(gpa, payload));
    const too_long = try gpa.alloc(u8, Input.capacity + 1);
    defer gpa.free(too_long);
    @memset(too_long, 'x');
    payload.overview = .{ .bytes = too_long, .cursor = 0 };
    try std.testing.expectError(error.InvalidHandoffDraft, encode(gpa, payload));
    payload.overview.bytes = too_long[0..Input.capacity];
    payload.overview.cursor = Input.capacity;
    const at_capacity = try encode(gpa, payload);
    defer gpa.free(at_capacity);
    const parsed = try decode(gpa, at_capacity, "/store");
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, Input.capacity), parsed.value.overview.bytes.len);
    try std.testing.expectError(error.HandoffStoreMismatch, decode(gpa, at_capacity, "/other"));
    payload.line = too_long[0 .. upgrade_status.max_line_bytes + 1];
    try std.testing.expectError(error.InvalidHandoffLine, encode(gpa, payload));
    payload.line = "";
    payload.store = too_long[0 .. protocol.max_store_bytes + 1];
    try std.testing.expectError(error.HandoffStoreMismatch, encode(gpa, payload));
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    home: []const u8,
    environment: std.process.Environ.Map,

    fn create() !Fixture {
        const gpa = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const length = try tmp.dir.realPath(std.testing.io, &buffer);
        const home = try gpa.dupe(u8, buffer[0..length]);
        return .{ .tmp = tmp, .home = home, .environment = .init(gpa) };
    }

    fn deinit(self: *Fixture) void {
        self.environment.deinit();
        std.testing.allocator.free(self.home);
        self.tmp.cleanup();
    }

    fn init(self: *Fixture) std.process.Init {
        var value: std.process.Init = undefined;
        value.gpa = std.testing.allocator;
        value.io = std.testing.io;
        value.environ_map = &self.environment;
        return value;
    }
};

const empty_payload: Payload = .{ .v = 1, .store = "/store", .overview = .{ .bytes = "", .cursor = 0 }, .drafts = &.{}, .line = "" };

test "handoff private files round trip consume once and delete" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var fixture = try Fixture.create();
    defer fixture.deinit();
    const encoded = try encode(gpa, empty_payload);
    defer gpa.free(encoded);
    const path = try writeEncoded(fixture.init(), fixture.home, encoded);
    defer gpa.free(path);
    const second = try writeEncoded(fixture.init(), fixture.home, encoded);
    defer gpa.free(second);
    defer std.Io.Dir.cwd().deleteFile(io, second) catch {};
    try std.testing.expect(!std.mem.eql(u8, path, second));
    const directory_stat = try fixture.tmp.dir.statFile(io, directory_name, .{ .follow_symlinks = false });
    const file_stat = try std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    try std.testing.expectEqual(@as(u32, 0o700), directory_stat.permissions.toMode() & 0o777);
    try std.testing.expectEqual(@as(u32, 0o600), file_stat.permissions.toMode() & 0o777);
    try fixture.environment.put("RUI_RELAUNCH", path);
    const parsed = read(fixture.init(), fixture.home, "/store").?;
    defer parsed.deinit();
    try std.testing.expectEqualDeep(empty_payload, parsed.value);
    try std.testing.expectEqualStrings("", fixture.environment.get("RUI_RELAUNCH").?);
    try std.testing.expect(read(fixture.init(), fixture.home, "/store") == null);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, path, .{}));
}

test "handoff ignores malformed missing mismatched and insecure files once" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var fixture = try Fixture.create();
    defer fixture.deinit();
    try std.testing.expect(read(fixture.init(), fixture.home, "/store") == null);
    const encoded = try encode(gpa, empty_payload);
    defer gpa.free(encoded);
    for (0..5) |case| {
        const path = try writeEncoded(fixture.init(), fixture.home, if (case == 0) "{" else encoded);
        defer gpa.free(path);
        if (case == 1) try std.Io.Dir.cwd().deleteFile(io, path);
        if (case == 3 or case == 4) try std.Io.Dir.cwd().setFilePermissions(io, path, .fromMode(if (case == 3) 0o644 else 0), .{});
        try fixture.environment.put("RUI_RELAUNCH", path);
        try std.testing.expect(read(fixture.init(), fixture.home, if (case == 2) "/other" else "/store") == null);
        try std.testing.expectEqualStrings("", fixture.environment.get("RUI_RELAUNCH").?);
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, path, .{}));
    }
}

test "handoff refuses nonprivate directories and never follows symlinks" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var fixture = try Fixture.create();
    defer fixture.deinit();
    const encoded = try encode(gpa, empty_payload);
    defer gpa.free(encoded);
    const path = try writeEncoded(fixture.init(), fixture.home, encoded);
    defer gpa.free(path);
    // The target outside the handoff directory must survive both kinds of
    // symlink, and an arbitrary inherited path must not be deleted either.
    const target = try fixture.tmp.dir.createFile(io, "target", .{ .permissions = .fromMode(0o600) });
    target.close(io);
    try std.Io.Dir.cwd().deleteFile(io, path);
    const relative = try std.fs.path.join(gpa, &.{ directory_name, std.fs.path.basename(path) });
    defer gpa.free(relative);
    try fixture.tmp.dir.symLink(io, "../target", relative, .{});
    try fixture.environment.put("RUI_RELAUNCH", path);
    try std.testing.expect(read(fixture.init(), fixture.home, "/store") == null);
    _ = try fixture.tmp.dir.statFile(io, "target", .{});
    const outside = try std.fs.path.join(gpa, &.{ fixture.home, "target" });
    defer gpa.free(outside);
    try fixture.environment.put("RUI_RELAUNCH", outside);
    try std.testing.expect(read(fixture.init(), fixture.home, "/store") == null);
    _ = try fixture.tmp.dir.statFile(io, "target", .{});
    try fixture.tmp.dir.setFilePermissions(io, directory_name, .fromMode(0o755), .{});
    try std.testing.expectError(error.InsecureHandoffDirectory, writeEncoded(fixture.init(), fixture.home, encoded));
    try fixture.tmp.dir.setFilePermissions(io, directory_name, .fromMode(0o700), .{});
    try fixture.tmp.dir.rename(directory_name, fixture.tmp.dir, "actual", io);
    try fixture.tmp.dir.symLink(io, "actual", directory_name, .{ .is_directory = true });
    if (writeEncoded(fixture.init(), fixture.home, encoded)) |unexpected| {
        gpa.free(unexpected);
        return error.TestExpectedError;
    } else |_| {}
}

test "handoff sparse drafts have no arbitrary small population cap" {
    const gpa = std.testing.allocator;
    // Exceeds common fixed slot counts without reserving one full-size editor
    // per Session. IDs are independent values in the owner's alphabet.
    const count = 1025;
    const ids = try gpa.alloc([session_id.bytes]u8, count);
    defer gpa.free(ids);
    const entries = try gpa.alloc(Entry, count);
    defer gpa.free(entries);
    for (entries, ids, 0..) |*entry, *id, index| {
        var remaining = index;
        for (id) |*byte| {
            byte.* = session_id.alphabet[remaining % session_id.alphabet.len];
            remaining /= session_id.alphabet.len;
        }
        entry.* = .{ .id = id, .snapshot = .{ .bytes = "x", .cursor = 1, .anchor = .{ .position = index, .end = index + 1 } } };
    }
    var payload = empty_payload;
    payload.drafts = entries;
    const bytes = try encode(gpa, payload);
    defer gpa.free(bytes);
    const parsed = try decode(gpa, bytes, payload.store);
    defer parsed.deinit();
    try std.testing.expectEqualDeep(payload, parsed.value);
}

test "handoff descriptor checks reject wrong owner when privileged" {
    // Ownership cannot be forged by an ordinary user. The same checks run
    // everywhere; root-only fixtures can manufacture the negative case.
    if (c.geteuid() != 0) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var fixture = try Fixture.create();
    defer fixture.deinit();
    const bytes = try encode(gpa, empty_payload);
    defer gpa.free(bytes);
    const path = try writeEncoded(fixture.init(), fixture.home, bytes);
    defer gpa.free(path);
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    try file.setOwner(io, 1, null);
    try fixture.environment.put("RUI_RELAUNCH", path);
    try std.testing.expect(read(fixture.init(), fixture.home, "/store") == null);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, path, .{}));
    var directory = try fixture.tmp.dir.openDir(io, directory_name, .{ .iterate = true });
    defer directory.close(io);
    try directory.setOwner(io, 1, null);
    try std.testing.expectError(error.HandoffNotOwned, writeEncoded(fixture.init(), fixture.home, bytes));
}

test "handoff requires an explicit wire version" {
    const unversioned = "{\"store\":\"/store\",\"open\":null,\"overview\":{\"bytes\":\"\",\"cursor\":0,\"anchor\":null,\"rejected\":null},\"drafts\":[],\"line\":\"\"}";
    try std.testing.expectError(error.MissingField, decode(std.testing.allocator, unversioned, "/store"));
}
