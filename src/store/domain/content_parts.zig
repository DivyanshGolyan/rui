//! Canonical compound Content values and their ordered byte parts.
const std = @import("std");
const parts = @import("../../input_parts.zig");
const capture = @import("../../InputCapture.zig");
const custody = @import("../../content_custody.zig");
const content = @import("content.zig");
const core = @import("../Store.zig");
const rsql = @import("../rsql.zig");

pub const Source = union(enum) {
    text: union(enum) {
        sealed: *const custody.ContentField,
        slice: []const u8,
        retained: struct { content_id: u64, reference: content.ContentReference },
    },
    captured: capture.Loan,

    pub fn reference(self: Source) !parts.Reference {
        switch (self) {
            .text => |text| return .{ .bytes = switch (text) {
                .sealed => |field| .{ .length = field.length, .digest = field.digest },
                .slice => |bytes| .{ .length = bytes.len, .digest = @import("../../content_string.zig").digest(bytes) },
                .retained => |value| value.reference,
            } },
            .captured => |loan| {
                if (loan.count == 0) return error.EmptyInput;
                if (loan.count > parts.max_parts) return error.TooManyInputParts;
                var encoder: parts.Manifest.Encoder = .{};
                var cursor = loan.cursor();
                var bytes: [parts.Manifest.max_entry_bytes]u8 = undefined;
                while (try cursor.next()) |part| {
                    const identity: parts.Identity = .{ .length = part.range.length, .digest = part.range.digest, .kind = part.kind };
                    _ = try encoder.append(&identity, &bytes);
                }
                return encoder.finish();
            },
        }
    }
};

pub const Saved = struct { content_id: u64, reference: parts.Reference };
pub const Step = union(enum) { round, saved: Saved };

const insert_part = rsql.Write(.{
    .sql = "INSERT INTO content_part(content_id,ordinal,part_content_id) VALUES(?1,?2,?3)",
    .Args = struct { content_id: u64, ordinal: u32, part_content_id: u64 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

/// All parts rows and their foreign-key index are written through this owner.
/// Its rounds run within the producer's transaction.
pub const Saving = struct {
    source: Source,
    reference: parts.Reference,
    stage: enum { start, value, part, done } = .start,
    value: content.Import = undefined,
    part: content.Import = undefined,
    cursor: ?capture.Cursor = null,
    selected: ?capture.Part = null,
    content_id: u64 = 0,
    ordinal: u32 = 0,

    pub fn init(source: Source) !Saving {
        const reference = try source.reference();
        const identity = reference.identity();
        return .{ .source = source, .reference = reference, .value = .{
            .digest = identity.digest,
            .length = identity.length,
            .private = false,
            .form = std.meta.activeTag(reference),
        }, .cursor = switch (source) {
            .captured => |loan| loan.cursor(),
            .text => null,
        } };
    }

    /// A retried transaction starts with fresh lookup and cursor state; the
    /// sealed source and its already computed identity remain the same.
    pub fn restart(self: *Saving) void {
        self.stage = .start;
        self.value.found = null;
        self.cursor = switch (self.source) {
            .captured => |loan| loan.cursor(),
            .text => null,
        };
        self.selected = null;
        self.content_id = 0;
        self.ordinal = 0;
    }

    /// Finish the existing lookup for a single borrowed Text without adding
    /// a round to its producer's text path.
    pub fn saveBytes(a: anytype, value: *content.Import, bytes: []const u8, faults: core.Faults) !u64 {
        if (faults.content_import) return error.InjectedContentImportFailure;
        return content.importBytes(a, value, bytes);
    }

    pub fn saveSealed(a: anytype, io: std.Io, value: *content.Import, field: *const custody.ContentField, faults: core.Faults) !u64 {
        if (faults.content_import) return error.InjectedContentImportFailure;
        return content.importSealed(a, io, field, value, faults);
    }

    /// Reuse a previously stored single-text value after checking its identity.
    pub fn saveRetained(value: *const content.Import, content_id: u64, faults: core.Faults) !u64 {
        if (faults.content_import) return error.InjectedContentImportFailure;
        const found = value.found orelse return error.CorruptStore;
        if (found.content_id.get() != content_id) return error.CorruptStore;
        return content_id;
    }

    noinline fn select(self: *Saving) !void {
        self.selected = try self.cursor.?.next() orelse return error.ContentChanged;
        const range = self.selected.?.range;
        self.part = .{ .digest = range.digest, .length = range.length, .private = false };
    }

    noinline fn writeManifest(self: *Saving, a: anytype) !void {
        const loan = self.source.captured;
        var cursor = loan.cursor();
        var encoder: parts.Manifest.Encoder = .{};
        var entry: [parts.Manifest.max_entry_bytes]u8 = undefined;
        const sink = try a.contentSink(self.content_id, self.value.length);
        defer sink.close();
        var offset: u64 = 0;
        while (try cursor.next()) |selected| {
            const identity: parts.Identity = .{ .length = selected.range.length, .digest = selected.range.digest, .kind = selected.kind };
            const bytes = try encoder.append(&identity, &entry);
            try sink.write(bytes, offset);
            offset += bytes.len;
        }
        var trailer: [parts.Manifest.trailer_bytes]u8 = undefined;
        std.mem.writeInt(u64, &trailer, encoder.digest.count, .big);
        try sink.write(&trailer, offset);
        const actual = try encoder.finish();
        if (actual != .parts or actual.parts.length != self.value.length or !std.mem.eql(u8, &actual.parts.digest, &self.value.digest)) return error.ContentChanged;
    }

    pub fn step(self: *Saving, a: anytype, io: std.Io, faults: core.Faults) !Step {
        switch (self.stage) {
            .start => {
                content.lookup(a, &self.value);
                if (self.source == .captured and self.reference == .parts) {
                    try self.select();
                    content.lookup(a, &self.part);
                }
                self.stage = .value;
                return .round;
            },
            .value => {
                if (self.reference == .bytes) {
                    self.content_id = switch (self.source) {
                        .text => |text| switch (text) {
                            .sealed => |field| try content.importSealed(a, io, field, &self.value, faults),
                            .slice => |bytes| try content.importBytes(a, &self.value, bytes),
                            .retained => |retained| retained: {
                                const found = self.value.found orelse return error.CorruptStore;
                                if (found.content_id.get() != retained.content_id) return error.CorruptStore;
                                break :retained retained.content_id;
                            },
                        },
                        .captured => captured: {
                            try self.select();
                            break :captured try content.importRange(a, io, self.selected.?.range, &self.value, faults);
                        },
                    };
                    self.stage = .done;
                    return .{ .saved = .{ .content_id = self.content_id, .reference = self.reference } };
                }
                if (self.value.found) |row| {
                    self.content_id = row.content_id.get();
                    self.stage = .done;
                    return .{ .saved = .{ .content_id = self.content_id, .reference = self.reference } };
                }
                self.content_id = try content.insertRow(a, &self.value);
                try self.writeManifest(a);
                self.stage = .part;
                return self.savePart(a, io, faults);
            },
            .part => return self.savePart(a, io, faults),
            .done => unreachable,
        }
    }

    fn savePart(self: *Saving, a: anytype, io: std.Io, faults: core.Faults) !Step {
        const id = try content.importRange(a, io, self.selected.?.range, &self.part, faults);
        a.write(insert_part, .{ .content_id = self.content_id, .ordinal = self.ordinal, .part_content_id = id });
        self.ordinal += 1;
        if (self.ordinal == self.source.captured.count) {
            if (try self.cursor.?.next() != null) return error.ContentChanged;
            self.stage = .done;
            return .{ .saved = .{ .content_id = self.content_id, .reference = self.reference } };
        }
        try self.select();
        content.lookup(a, &self.part);
        return .round;
    }
};

const access = @import("../access.zig");
const part_rows = rsql.Read(.{
    .sql = "SELECT cp.ordinal,cp.part_content_id,p.byte_length,p.digest,p.private,p.form " ++
        "FROM content_part cp LEFT JOIN content p ON p.content_id=cp.part_content_id " ++
        "WHERE cp.content_id=?1 AND cp.ordinal>=?2 ORDER BY cp.ordinal LIMIT 16",
    .Args = struct { content_id: u64, ordinal: u32 },
    .Row = struct {
        ordinal: u64,
        part_content_id: rsql.Positive,
        byte_length: ?u64,
        digest: ?[32]u8,
        private: ?bool,
        form: ?u8,
    },
    .cardinality = .{ .at_most = 16 },
});

pub const Part = struct {
    ordinal: u32,
    kind: parts.Kind,
    content_id: u64,
    reference: content.ContentReference,
};

/// Certifies the entire manifest and index before yielding the first part.
/// The second pass yields in order with fixed memory and checks again as read.
pub const Cursor = struct {
    value: content.Value,
    decoder: parts.Manifest.Decoder,
    check: content.DigestCheck,
    buffer: [content.verified_window_bytes]u8 = undefined,
    position: usize = 0,
    length: usize = 0,
    offset: u64 = 0,
    rows: part_rows.Result = undefined,
    row: usize = 0,
    row_count: usize = 0,
    ordinal: u32 = 0,
    certified: bool = false,
    finished: bool = false,
    pending: enum { none, raw, rows } = .none,
    identity: ?parts.Identity = null,
    trailer: [parts.Manifest.trailer_bytes]u8 = undefined,
    trailer_length: usize = 0,
    raw_length: usize = 0,
    weight: Weight = .{},

    pub fn init(self: *Cursor, value: content.Value) void {
        std.debug.assert(value.reference == .parts);
        self.value = value;
        self.reset();
        self.certified = false;
        self.weight = .{};
    }

    fn reset(self: *Cursor) void {
        self.decoder = .{ .remaining = self.value.reference.parts.length };
        self.check = .{ .hash = parts.Form.parts.hasher() };
        self.position = 0;
        self.length = 0;
        self.offset = 0;
        self.row = 0;
        self.row_count = 0;
        self.ordinal = 0;
        self.finished = false;
        self.pending = .none;
        self.identity = null;
        self.trailer_length = 0;
    }

    /// `certified` marks the pass boundary: the whole manifest and index are
    /// certified and the next step starts yielding parts. It is emitted once.
    pub const Step = union(enum) { raw, rows, certified, part: Part, done };

    pub const Weight = struct {
        bytes: u64 = 0,
        text_bytes: u64 = 0,
        unknown_images: u64 = 0,
        rule: ?@import("../../model_catalog.zig").ImageCostRule = null,
        astra_tokens: u64 = 0,
        astra_unknown: u64 = 0,
        astra_impossible: u64 = 0,
        gpt41_unknown: u64 = 0,
        gpt41_tokens: u64 = 0,

        pub fn take(self: *Weight, part: Part) void {
            self.bytes +|= part.reference.length;
            switch (part.kind) {
                .text => self.text_bytes +|= part.reference.length,
                .image => |image| {
                    self.unknown_images +|= 1;
                    if (self.rule) |rule| switch (rule) {
                        .astra_auto => switch (@import("../../input_media.zig").astraAuto(image.media.width, image.media.height)) {
                            .tokens => |tokens| self.astra_tokens +|= tokens,
                            .impossible => self.astra_impossible +|= 1,
                            .unknown => self.astra_unknown +|= 1,
                        },
                        .gpt41_auto => switch (@import("../../input_media.zig").gpt41Auto(image.media.width, image.media.height)) {
                            .tokens => |tokens| self.gpt41_tokens +|= tokens,
                            .impossible, .unknown => self.gpt41_unknown +|= 1,
                        },
                    };
                },
            }
        }
    };

    fn fill(self: *Cursor, a: anytype) !bool {
        if (self.position < self.length) return true;
        const reference = self.value.reference.parts;
        if (self.offset == reference.length) return error.CorruptStore;
        self.raw_length = @intCast(@min(self.buffer.len, reference.length - self.offset));
        try a.readRaw(self.value.content_id, self.offset, self.buffer[0..self.raw_length]);
        self.pending = .raw;
        return false;
    }

    fn indexRow(self: *Cursor, a: anytype) ?part_rows.Row {
        if (self.row == self.row_count) {
            a.read(part_rows, .{ .content_id = self.value.content_id, .ordinal = self.ordinal }, &self.rows);
            self.pending = .rows;
            return null;
        }
        const result = self.rows.items[self.row];
        self.row += 1;
        return result;
    }

    /// One bounded read at a time. A queued raw read and a queued index read
    /// are distinct effects; callers resume only after the effect completes.
    pub fn step(self: *Cursor, a: anytype) anyerror!Cursor.Step {
        switch (self.pending) {
            .none => {},
            .raw => {
                const bytes = self.buffer[0..self.raw_length];
                if (!self.check.absorb(self.value.reference.parts, self.offset, bytes)) return error.CorruptStore;
                self.offset += self.raw_length;
                self.position = 0;
                self.length = self.raw_length;
            },
            .rows => {
                self.row = 0;
                self.row_count = self.rows.len;
                if (self.identity != null and self.row_count == 0) return error.CorruptStore;
                if (self.identity == null and self.row_count == 0) {
                    self.pending = .none;
                    self.finished = true;
                    return self.finishPass();
                }
            },
        }
        self.pending = .none;
        if (self.finished) return .done;
        while (true) {
            if (self.identity) |identity| {
                const row = self.indexRow(a) orelse return .rows;
                if (row.ordinal != self.ordinal or (row.private orelse return error.CorruptStore) or
                    (try parts.Form.decode(row.form orelse return error.CorruptStore)) != .bytes or
                    (row.byte_length orelse return error.CorruptStore) != identity.length or
                    !std.mem.eql(u8, &(row.digest orelse return error.CorruptStore), &identity.digest)) return error.CorruptStore;
                const part: Part = .{ .ordinal = self.ordinal, .kind = identity.kind, .content_id = row.part_content_id.get(), .reference = .{ .length = identity.length, .digest = identity.digest } };
                self.ordinal += 1;
                self.identity = null;
                if (self.certified) return .{ .part = part };
                self.weight.take(part);
                continue;
            }
            if (self.decoder.remaining > parts.Manifest.trailer_bytes) {
                if (!try self.fill(a)) return .raw;
                self.identity = try self.decoder.next(self.buffer[0..self.length], &self.position);
                continue;
            }
            while (self.trailer_length < self.trailer.len) {
                if (!try self.fill(a)) return .raw;
                self.trailer[self.trailer_length] = self.buffer[self.position];
                self.trailer_length += 1;
                self.position += 1;
            }
            if (try self.decoder.finish(&self.trailer) != self.ordinal or !self.check.verified or
                self.offset != self.value.reference.parts.length or self.position != self.length) return error.CorruptStore;
            if (self.row < self.row_count) return error.CorruptStore;
            _ = self.indexRow(a);
            return .rows;
        }
    }

    fn finishPass(self: *Cursor) Cursor.Step {
        if (self.certified) return .done;
        self.reset();
        self.certified = true;
        return .certified;
    }

    pub fn next(self: *Cursor, a: anytype) !?Part {
        while (true) switch (try self.step(a)) {
            .raw, .certified => {}, // Access.readRaw already completed this effect.
            .rows => try access.runAs(a, error.CorruptStore),
            .part => |part| return part,
            .done => return null,
        };
    }
};

pub fn verify(a: anytype, value: content.Value) !void {
    // Parts projections are rare. One mapped Cursor belongs to this call and
    // releases its bounded workspace when verification ends.
    const mapped = try @import("../../os/pages.zig").Mapped(Cursor).map();
    defer mapped.unmap();
    mapped.value.init(value);
    while (try mapped.value.next(a)) |_| {}
}

/// A byte-oriented projection verifies compound values before declining them.
pub fn publicMetadata(a: anytype, content_id: u64, row: *const content.content_metadata.Row) !content.ContentMetadata {
    if (row.private) return error.CorruptStore;
    if (try parts.Form.decode(row.form) == .parts) {
        try verify(a, try content.Value.of(content_id, row.form, row.byte_length, row.digest));
        return error.InputPartsNotSupported;
    }
    return content.publicMetadata(row);
}
