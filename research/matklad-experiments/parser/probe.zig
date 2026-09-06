// Throwaway: sealed output-item arrays, not the complete Responses/SSE adapter.
const std = @import("std");
const prod = @import("prod");
const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("unistd.h");
    @cInclude("time.h");
    @cInclude("sqlite3.h");
});
extern fn probe_rss() u64;
extern fn probe_footprint() u64;
extern fn probe_peak_rss() u64;

const Counted = struct {
    live: usize = 0,
    peak: usize = 0,
    calls: usize = 0,
    fn api(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, n: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        const p = std.heap.page_allocator.rawAlloc(n, a, ra) orelse return null;
        self.live += n;
        self.peak = @max(self.peak, self.live);
        self.calls += 1;
        return p;
    }
    fn free(ctx: *anyopaque, b: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.live -= b.len;
        std.heap.page_allocator.rawFree(b, a, ra);
    }
};
const Role = enum { list, item, content_list, content_item, ignored };
const Field = enum(u5) { unknown, type, id, role, content, text, arguments, name, call_id, encrypted_content };
const Frame = struct {
    role: Role,
    object: bool,
    key: bool = true,
    field: Field = .unknown,
    seen: u32 = 0,
    start: u64 = 0,
    kind: [64]u8 = undefined,
    kind_len: usize = 0,
};
const Parser = struct {
    frames: [64]Frame = undefined,
    depth: usize = 0,
    string_active: bool = false,
    string_key: bool = false,
    small: [128]u8 = undefined,
    small_len: usize = 0,
    string_len: usize = 0,
    number_active: bool = false,
    closed: bool = false,
    count: u64 = 0,
    unsupported: bool = false,
    index: ?*c.FILE,
    importer: ?*Importer = null,
    fn field(name: []const u8) Field {
        inline for (std.meta.fields(Field)) |f| {
            if (std.mem.eql(u8, name, f.name)) return @enumFromInt(f.value);
        }
        return .unknown;
    }
    fn bit(f: Field) u32 {
        return @as(u32, 1) << @intFromEnum(f);
    }
    fn doneValue(self: *@This()) void {
        if (self.depth > 0 and self.frames[self.depth - 1].object) self.frames[self.depth - 1].key = true;
    }
    fn stringPart(self: *@This(), bytes: []const u8, done: bool) !void {
        if (!self.string_active) {
            if (self.depth == 0) return error.BadShape;
            self.string_active = true;
            self.string_key = self.frames[self.depth - 1].object and self.frames[self.depth - 1].key;
            self.small_len = 0;
            self.string_len = 0;
            if (!self.string_key) try self.checkShape(.string);
        }
        self.string_len += bytes.len;
        const take = @min(bytes.len, self.small.len - self.small_len);
        @memcpy(self.small[self.small_len..][0..take], bytes[0..take]);
        self.small_len += take;
        if (!done) return;
        const fr = &self.frames[self.depth - 1];
        const name = self.small[0..self.small_len];
        if (self.string_key) {
            fr.field = if (self.string_len <= self.small.len and fr.role != .ignored) field(name) else .unknown;
            if (fr.field != .unknown) {
                if ((fr.seen & bit(fr.field)) != 0) return error.DuplicateConsumedField;
                fr.seen |= bit(fr.field);
            }
            fr.key = false;
        } else {
            if (fr.field == .type and fr.role != .ignored) {
                if (self.string_len > fr.kind.len) return error.DiscriminatorTooLong;
                @memcpy(fr.kind[0..name.len], name);
                fr.kind_len = name.len;
            }
            self.doneValue();
        }
        self.string_active = false;
    }
    fn checkShape(self: *@This(), shape: enum { string, object, array, scalar }) !void {
        const fr = &self.frames[self.depth - 1];
        if (fr.role == .list or fr.role == .content_list) {
            if (shape != .object) return error.BadShape;
            return;
        }
        if (fr.role == .ignored) return;
        if (fr.key) return error.BadShape;
        switch (fr.field) {
            .unknown => {},
            .content => if (shape != .array) {
                return error.BadShape;
            },
            else => if (shape != .string) {
                return error.BadShape;
            },
        }
    }
    fn token(self: *@This(), t: std.json.Token, end: u64) !void {
        switch (t) {
            .partial_string => |s| try self.stringPart(s, false),
            .partial_string_escaped_1 => |s| try self.stringPart(&s, false),
            .partial_string_escaped_2 => |s| try self.stringPart(&s, false),
            .partial_string_escaped_3 => |s| try self.stringPart(&s, false),
            .partial_string_escaped_4 => |s| try self.stringPart(&s, false),
            .string => |s| try self.stringPart(s, true),
            .object_begin, .array_begin => {
                if (self.depth == self.frames.len or self.closed) return error.DepthOrShape;
                var role: Role = .ignored;
                if (self.depth == 0) {
                    if (t != .array_begin) return error.BadShape;
                    role = .list;
                } else {
                    try self.checkShape(if (t == .object_begin) .object else .array);
                    const parent = self.frames[self.depth - 1];
                    if (parent.role == .list) role = .item;
                    if (parent.role == .content_list) role = .content_item;
                    if (parent.role == .item and parent.field == .content) role = .content_list;
                }
                self.frames[self.depth] = .{ .role = role, .object = t == .object_begin, .start = end - 1 };
                self.depth += 1;
            },
            .object_end, .array_end => {
                if (self.depth == 0) return error.BadShape;
                const fr = self.frames[self.depth - 1];
                if (fr.object != (t == .object_end)) return error.BadShape;
                if (fr.role == .item or fr.role == .content_item) {
                    if ((fr.seen & bit(.type)) == 0) return error.MissingType;
                    const kind = fr.kind[0..fr.kind_len];
                    if (fr.role == .item) {
                        var required: u32 = bit(.type);
                        if (std.mem.eql(u8, kind, "message")) required |= bit(.role) | bit(.content) else if (std.mem.eql(u8, kind, "function_call")) required |= bit(.name) | bit(.arguments) | bit(.call_id) else if (!std.mem.eql(u8, kind, "reasoning") and !std.mem.eql(u8, kind, "compaction")) self.unsupported = true;
                        if ((fr.seen & required) != required) return error.MissingField;
                        const pair = [2]u64{ fr.start, end - fr.start };
                        if (self.index) |idx| {
                            if (c.fwrite(&pair, @sizeOf(@TypeOf(pair)), 1, idx) != 1) return error.IO;
                        }
                        if (self.importer) |imp| try imp.item(pair, self.count);
                        self.count += 1;
                    } else if (std.mem.eql(u8, kind, "output_text")) {
                        if ((fr.seen & bit(.text)) == 0) return error.MissingText;
                    } else self.unsupported = true;
                }
                self.depth -= 1;
                self.doneValue();
                if (self.depth == 0) self.closed = true;
            },
            .partial_number => {
                if (!self.number_active) try self.checkShape(.scalar);
                self.number_active = true;
            },
            .number, .true, .false, .null => {
                if (!self.number_active) try self.checkShape(.scalar);
                self.number_active = false;
                self.doneValue();
            },
            .end_of_document => if (!self.closed or self.depth != 0) {
                return error.BadShape;
            },
            else => return error.UnexpectedAllocatedToken,
        }
    }
};

fn scan(file: *c.FILE, index: ?*c.FILE, importer: ?*Importer, allocator: std.mem.Allocator, window: usize) !Parser {
    var scanner = std.json.Scanner.initStreaming(allocator);
    defer scanner.deinit();
    try scanner.ensureTotalStackCapacity(64);
    var p: Parser = .{ .index = index, .importer = importer };
    var buf: [4096]u8 = undefined;
    var base: u64 = 0;
    while (true) {
        const n = c.fread(&buf, 1, window, file);
        if (c.ferror(file) != 0) return error.IO;
        scanner.feedInput(buf[0..n]);
        if (n == 0) scanner.endInput();
        while (true) {
            const tok = scanner.next() catch |err| {
                if (err == error.BufferUnderrun) break;
                return err;
            };
            if (scanner.stackHeight() > 64) return error.DepthOrShape;
            try p.token(tok, base + scanner.cursor);
            if (tok == .end_of_document) return p;
        }
        base += n;
    }
}
fn sql(db: ?*c.sqlite3, q: [*:0]const u8) !void {
    if (c.sqlite3_exec(db, q, null, null, null) != c.SQLITE_OK) return error.SQLite;
}
fn nowNs() u64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(u64, @intCast(ts.tv_sec)) * 1000000000 + @as(u64, @intCast(ts.tv_nsec));
}
const Importer = struct {
    db: ?*c.sqlite3,
    file: *c.FILE,
    stmt: ?*c.sqlite3_stmt,
    inject_failure: bool,
    fn item(self: *@This(), pair: [2]u64, ordinal: u64) !void {
        if (self.inject_failure and ordinal == 1) return error.InjectedImportFailure;
        _ = c.sqlite3_reset(self.stmt);
        _ = c.sqlite3_bind_int64(self.stmt, 1, @intCast(pair[1]));
        if (c.sqlite3_step(self.stmt) != c.SQLITE_DONE) return error.SQLite;
        var blob: ?*c.sqlite3_blob = null;
        if (c.sqlite3_blob_open(self.db, "main", "items", "payload", c.sqlite3_last_insert_rowid(self.db), 1, &blob) != c.SQLITE_OK) return error.SQLite;
        defer _ = c.sqlite3_blob_close(blob);
        var buf: [4096]u8 = undefined;
        var offset: usize = 0;
        while (offset < pair[1]) {
            const n = @min(buf.len, pair[1] - offset);
            if (c.pread(c.fileno(self.file), &buf, n, @intCast(pair[0] + offset)) != n) return error.IO;
            if (c.sqlite3_blob_write(blob, &buf, @intCast(n), @intCast(offset)) != c.SQLITE_OK) return error.SQLite;
            offset += n;
        }
    }
};
fn importItems(db: ?*c.sqlite3, file: *c.FILE, index: ?*c.FILE, count: u64, inject_failure: bool, allocator: std.mem.Allocator, window: usize) !void {
    const start = nowNs();
    defer _ = c.fprintf(c.__stderrp, "import_ns=%llu\n", nowNs() - start);
    try sql(db, "BEGIN IMMEDIATE");
    errdefer sql(db, "ROLLBACK") catch {};
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, "INSERT INTO items(payload) VALUES(zeroblob(?))", -1, &stmt, null) != c.SQLITE_OK) return error.SQLite;
    defer _ = c.sqlite3_finalize(stmt);
    var imp: Importer = .{ .db = db, .file = file, .stmt = stmt, .inject_failure = inject_failure };
    if (index) |idx| {
        c.rewind(idx);
        for (0..count) |ordinal| {
            var pair: [2]u64 = undefined;
            if (c.fread(&pair, @sizeOf(@TypeOf(pair)), 1, idx) != 1) return error.IO;
            try imp.item(pair, ordinal);
        }
    } else {
        c.rewind(file);
        const p = try scan(file, null, &imp, allocator, window);
        if (p.count != count) return error.BadShape;
    }
    try sql(db, "COMMIT");
}
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 5) return error.Usage;
    const mode = args[1];
    const input = try init.arena.allocator().dupeZ(u8, args[2]);
    const db_path = try init.arena.allocator().dupeZ(u8, args[3]);
    const window = try std.fmt.parseInt(usize, args[4], 10);
    if (window == 0 or window > 4096) return error.Window;
    const file = c.fopen(input, "rb") orelse return error.IO;
    defer _ = c.fclose(file);
    _ = c.fseeko(file, 0, c.SEEK_END);
    const size: usize = @intCast(c.ftello(file));
    c.rewind(file);
    var counted: Counted = .{};
    const allocator = counted.api();
    const rss_before = probe_rss();
    const footprint_before = probe_footprint();
    var valid = true;
    var supported = true;
    var items: u64 = 0;
    var diagnostic: [:0]const u8 = "none";
    var struct_bytes: usize = 0;
    var decoded: usize = 0;
    if (std.mem.startsWith(u8, mode, "stream")) {
        var db: ?*c.sqlite3 = null;
        if (c.sqlite3_open(db_path, &db) != c.SQLITE_OK) return error.SQLite;
        defer _ = c.sqlite3_close(db);
        try sql(db, "PRAGMA journal_mode=DELETE; PRAGMA synchronous=EXTRA; PRAGMA cache_size=-256; PRAGMA mmap_size=0; CREATE TABLE items(id INTEGER PRIMARY KEY,payload BLOB NOT NULL)");
        const two = std.mem.indexOf(u8, mode, "two") != null;
        const index: ?*c.FILE = if (two) null else (c.tmpfile() orelse return error.IO);
        defer {
            if (index) |idx| {
                _ = c.fclose(idx);
            }
        }
        struct_bytes = @sizeOf(Parser) + 4096;
        const validation_start = nowNs();
        if (scan(file, index, null, allocator, window)) |p| {
            _ = c.fprintf(c.__stderrp, "validation_ns=%llu\n", nowNs() - validation_start);
            items = p.count;
            supported = !p.unsupported;
            importItems(db, file, index, items, std.mem.endsWith(u8, mode, "fail"), allocator, window) catch |err| {
                valid = false;
                diagnostic = @errorName(err);
            };
        } else |err| {
            valid = false;
            diagnostic = @errorName(err);
        }
        decoded = @intCast(c.sqlite3_memory_highwater(0));
    } else if (std.mem.eql(u8, mode, "dom")) {
        const bytes = try allocator.alloc(u8, size);
        defer allocator.free(bytes);
        if (c.fread(bytes.ptr, 1, size, file) != size) return error.IO;
        if (std.json.parseFromSlice(std.json.Value, allocator, bytes, .{ .allocate = .alloc_always, .max_value_len = size })) |parsed| {
            defer parsed.deinit();
            if (parsed.value == .array) items = parsed.value.array.items.len;
        } else |err| {
            valid = false;
            diagnostic = @errorName(err);
        }
    } else if (std.mem.eql(u8, mode, "production")) {
        var capture = prod.Capture.init(allocator, null);
        defer capture.deinit();
        struct_bytes = @sizeOf(prod.Capture);
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = c.fread(&buf, 1, window, file);
            if (n == 0) break;
            capture.appendSse(buf[0..n]) catch |err| {
                valid = false;
                diagnostic = @errorName(err);
                break;
            };
        }
        capture.finishSse();
        valid = valid and !capture.malformed and !capture.resource_exceeded and capture.candidate_failure == .none and capture.terminal_status == .completed and capture.candidate_count == 1;
        if (capture.candidate_failure != .none) diagnostic = @tagName(capture.candidate_failure);
        decoded = capture.decoded_occupied_high_water;
        items = capture.candidate_count;
    } else return error.Mode;
    _ = c.printf("{\"valid\":%s,\"supported\":%s,\"diagnostic\":\"%s\",\"input_bytes\":%zu,\"items\":%llu,\"allocator_peak\":%zu,\"allocator_calls\":%zu,\"allocator_live_after\":%zu,\"declared_parser_and_read_buffer_bytes\":%zu,\"sqlite_or_decoded_peak\":%zu,\"rss_before\":%llu,\"rss_after\":%llu,\"peak_rss\":%llu,\"footprint_before\":%llu,\"footprint_after\":%llu}\n", @as([*:0]const u8, if (valid) "true" else "false"), @as([*:0]const u8, if (supported) "true" else "false"), diagnostic.ptr, size, items, counted.peak, counted.calls, counted.live, struct_bytes, decoded, rss_before, probe_rss(), probe_peak_rss(), footprint_before, probe_footprint());
}
