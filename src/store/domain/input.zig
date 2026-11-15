//! Ordered original Message input. The kind-2 command owns its count
//! certificate and associations; raw bytes remain ordinary Content.
const std = @import("std");
const Bounded = @import("../../bounded.zig").Bounded;
const idempotency_key = @import("../../idempotency_key.zig");
const parts = @import("../../input_parts.zig");
const capture = @import("../../InputCapture.zig");
const custody = @import("../../content_custody.zig");
const content = @import("content.zig");
const store_core = @import("../Store.zig");
const rsql = @import("../rsql.zig");
const store_access = @import("../Access.zig");

/// Text already has three current internal custody forms: a sealed person
/// request, borrowed tool bytes, or a child ending's saved model answer.
/// They all save one ordinary Text through the same private Saving owner.
pub const Text = union(enum) {
    sealed: *const custody.ContentField,
    bytes: []const u8,
    retained: struct { content_id: u64, reference: content.ContentReference },

    fn identity(self: Text) content.Import {
        return switch (self) {
            .sealed => |field| content.sealedIdentity(field),
            .bytes => |bytes| .ofBytes(bytes, false),
            .retained => |retained| .{ .length = retained.reference.length, .digest = retained.reference.digest, .private = false },
        };
    }
};

pub const Input = union(enum) {
    text: Text,
    parts: capture.Loan,

    pub fn count(self: Input) u32 {
        return switch (self) {
            .text => 1,
            .parts => |loan| loan.count,
        };
    }

    pub fn reference(self: Input) Reference {
        return switch (self) {
            .text => |text| text: {
                const value = text.identity();
                break :text .{ .text = .{ .length = value.length, .digest = value.digest } };
            },
            .parts => |loan| if (loan.single_text) |text|
                .{ .text = .{ .length = text.length, .digest = text.digest } }
            else
                .{ .parts = .{ .count = loan.count, .digest = loan.digest } },
        };
    }
};
pub const Reference = parts.Reference;

pub fn referenceCount(reference: Reference) u32 {
    return switch (reference) {
        .text => 1,
        .parts => |value| value.count,
    };
}

pub fn referenceDigest(reference: Reference) [32]u8 {
    return switch (reference) {
        inline else => |value| value.digest,
    };
}
pub const MessageReply = @import("../../command_reply.zig").MessageReceipt(Reference).Reply;

/// The unchanged public text door can only have submitted one Text. This
/// projection never creates a flattened Content reference for compound input.
pub fn textReply(reply: MessageReply) @import("../../command_reply.zig").MessageReply {
    return switch (reply) {
        .accepted => |accepted| .{ .accepted = .{ .replayed = accepted.replayed, .admission_id = accepted.admission_id, .content = .{ .length = accepted.content.text.length, .digest = accepted.content.text.digest }, .session = accepted.session } },
        .rejected => |rejected| .{ .rejected = .{ .replayed = rejected.replayed, .code = rejected.code, .message = rejected.message, .content = .{ .length = rejected.content.text.length, .digest = rejected.content.text.digest } } },
        .conflict => .conflict,
        .infrastructure_failure => .infrastructure_failure,
    };
}

pub const Producer = union(enum) { message: Bounded(idempotency_key.max_bytes) };

const insert_message_part = rsql.Write(.{
    .sql = "INSERT INTO input_part(input_part_id,command_key,command_kind,part_count,ordinal,content_id,part_kind,image_format,image_width,image_height,display_name) " ++
        "VALUES(?1,?2,2,?3,?4,?5,?6,?7,?8,?9,?10)",
    .Args = struct { id: u64, key: []const u8, count: u32, ordinal: u32, content_id: u64, kind: u8, format: ?u8, width: ?u32, height: ?u32, name: ?[]const u8 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

/// The only parts writer. The producer queues its own count certificate
/// before this owner's first lookup. Each part gets one lookup round after
/// the preceding insert, so repeated bytes share Content without growing
/// Access's fixed imported-identity table. All rounds share that producer's
/// transaction. A failure rolls back its certificate, parts and raw imports.
pub const Saving = struct {
    input: Input,
    producer: Producer,
    saved: u32 = 0,
    cursor: ?capture.Cursor,
    selected: ?capture.Part = null,
    value: content.Import = undefined,
    waiting: bool = false,
    // One queued association borrows its name through the next round,
    // while selected may already load the next part's index record.
    saved_name: ?parts.Name = null,

    pub fn init(self: *Saving, input: Input, producer: Producer) void {
        self.* = .{ .input = input, .producer = producer, .cursor = switch (input) {
            .text => null,
            .parts => |loan| loan.cursor(),
        } };
    }

    /// Adopts an identity lookup the producer's existing facts round made.
    /// It does not import or associate bytes; save remains the only writer.
    pub fn foundText(self: *Saving, found: content.Import) void {
        std.debug.assert(self.input == .text and self.saved == 0 and !self.waiting);
        const expected = self.input.text.identity();
        std.debug.assert(found.length == expected.length and !found.private and std.mem.eql(u8, &found.digest, &expected.digest));
        self.value = found;
        self.waiting = true;
    }

    /// Queues one raw identity lookup. Cursor IO reads the sealed scratch
    /// index inside the caller's existing owned Store hold, like the raw
    /// Content import. Container validation already finished outside it.
    pub fn lookupNext(self: *Saving, a: anytype) !bool {
        std.debug.assert(!self.waiting);
        if (self.input.count() == 0) return error.ContentChanged;
        if (self.saved == self.input.count()) return false;
        if (self.saved > self.input.count()) return error.ContentChanged;
        switch (self.input) {
            .text => |text| self.value = text.identity(),
            .parts => {
                self.selected = try self.cursor.?.next() orelse return error.ContentChanged;
                const range = self.selected.?.range;
                self.value = .{ .length = range.length, .digest = range.digest, .private = false };
            },
        }
        content.lookup(a, &self.value);
        self.waiting = true;
        return true;
    }

    /// After lookupNext's round. No producer accepts a scalar Content id
    /// instead of going through this owner, including one ordinary Text.
    pub fn save(self: *Saving, a: anytype, io: std.Io, faults: store_core.Faults) !void {
        std.debug.assert(self.waiting and self.saved < self.input.count());
        if (faults.content_import) return error.InjectedContentImportFailure;
        const content_id = switch (self.input) {
            .text => |text| switch (text) {
                .sealed => |field| try content.importSealed(a, io, field, &self.value, faults),
                .bytes, .retained => try self.importText(a),
            },
            .parts => try content.importRange(a, io, self.selected.?.range, &self.value, faults),
        };
        try self.associate(a, content_id);
    }

    /// Current tool diagnostics and forwarded saved answers have no file
    /// custody. They need no injected IO capability and share associate.
    pub fn saveText(self: *Saving, a: anytype, faults: store_core.Faults) !void {
        std.debug.assert(self.waiting and self.saved == 0 and self.input == .text);
        if (faults.content_import) return error.InjectedContentImportFailure;
        const content_id = try self.importText(a);
        try self.associate(a, content_id);
    }

    fn importText(self: *Saving, a: anytype) !u64 {
        return switch (self.input.text) {
            .sealed => error.MissingContentCustody,
            .bytes => |bytes| try content.importBytes(a, &self.value, bytes),
            .retained => |retained| retained: {
                const found = self.value.found orelse return error.CorruptStore;
                if (found.content_id.get() != retained.content_id) return error.CorruptStore;
                break :retained retained.content_id;
            },
        };
    }

    fn associate(self: *Saving, a: anytype, content_id: u64) !void {
        const kind: *const parts.Kind = if (self.selected) |*part| &part.kind else &.text;
        const image = switch (kind.*) {
            .text => null,
            .image => |*image| image,
        };
        self.saved_name = if (image) |value| value.name else null;
        const id = try a.identity(.input_part_id);
        switch (self.producer) {
            .message => |*key| a.write(insert_message_part, .{
                .id = id,
                .key = key.slice(),
                .count = self.input.count(),
                .ordinal = self.saved,
                .content_id = content_id,
                .kind = if (image == null) 1 else 2,
                .format = if (image) |value| @backingInt(value.media.format) else null,
                .width = if (image) |value| value.media.width else null,
                .height = if (image) |value| value.media.height else null,
                .name = if (self.saved_name) |*name| name.slice() else null,
            }),
        }
        self.saved += 1;
        self.waiting = false;
    }
};

/// Only migrated refused Message commands can have no authored bytes.
/// New Saving inputs cannot select this certificate. A diagnostic is not
/// a Text part, and is inspected through the command's separate outcome.
pub const Certificate = union(enum) { retained: u32, legacy_unavailable };

pub fn partCount(value: ?u64) error{CorruptStore}!u32 {
    const count = std.math.cast(u32, value orelse return error.CorruptStore) orelse return error.CorruptStore;
    if (count == 0) return error.CorruptStore;
    return count;
}

fn partMetadataConsistentSql(comptime row: []const u8) []const u8 {
    return "(" ++ row ++ ".part_kind IS NOT NULL AND ((" ++ row ++ ".part_kind=1 AND (" ++ row ++
        ".image_format IS NULL AND " ++ row ++ ".image_width IS NULL) AND (" ++ row ++ ".image_height IS NULL AND " ++ row ++
        ".display_name IS NULL)) OR (" ++ row ++ ".part_kind=2 AND (" ++ row ++ ".image_format IS NOT NULL AND " ++ row ++
        ".image_format IN (1,2)) AND ((" ++ row ++ ".image_width IS NOT NULL AND " ++ row ++ ".image_width BETWEEN 1 AND 4294967295) AND (" ++ row ++
        ".image_height IS NOT NULL AND " ++ row ++ ".image_height BETWEEN 1 AND 4294967295)))))";
}

/// Count, exclusive source and ordinal bounds are checked before history
/// floors or indexed selection can omit individual rows. Count, distinct
/// ordinals and bounds prove coverage even when damaged indexes are absent.
pub fn messageConsistentSql(comptime source: []const u8, comptime allow_legacy_refusal: bool) []const u8 {
    const retained = "(" ++ source ++ ".input_part_count BETWEEN 1 AND 4294967295 AND " ++ referenceConsistentSql(source) ++ " AND " ++ source ++ ".input_part_count=" ++
        "(SELECT count(*) FROM input_part input_count WHERE input_count.command_key=" ++ source ++ ".command_key) AND " ++
        source ++ ".input_part_count=(SELECT count(DISTINCT input_unique.ordinal) FROM input_part input_unique WHERE input_unique.command_key=" ++ source ++ ".command_key) AND " ++
        "NOT EXISTS(SELECT 1 FROM input_part input_required WHERE input_required.command_key=" ++ source ++ ".command_key AND ((" ++
        "input_required.command_kind IS NULL OR input_required.command_kind<>2 OR input_required.part_count IS NULL OR input_required.ordinal IS NULL) OR (input_required.part_count<>" ++ source ++ ".input_part_count OR " ++
        "input_required.ordinal<0 OR input_required.ordinal>=" ++ source ++ ".input_part_count) OR (NOT " ++ partMetadataConsistentSql("input_required") ++ " OR " ++
        "NOT EXISTS(SELECT 1 FROM content input_bytes WHERE input_bytes.content_id=input_required.content_id AND input_bytes.private=0)))))";
    const legacy = "(" ++ source ++ ".input_part_count=0 AND " ++ source ++ ".accepted=0 AND " ++ source ++ ".input_reference_digest IS NULL AND " ++ source ++ ".input_reference_length IS NULL AND " ++
        "NOT EXISTS(SELECT 1 FROM input_part input_old WHERE input_old.command_key=" ++ source ++ ".command_key))";
    return "(" ++ source ++ ".kind=2 AND " ++ source ++ ".input_part_count IS NOT NULL AND (" ++ retained ++
        (if (allow_legacy_refusal) " OR " ++ legacy else "") ++ "))";
}

/// Single Text keeps its exact raw identity. Other sequences are certified
/// by the ordered digest and must be reconstructed by Cursor before use.
fn referenceConsistentSql(comptime source: []const u8) []const u8 {
    const single = "(" ++ source ++ ".input_part_count=1 AND EXISTS(SELECT 1 FROM input_part ref_text WHERE ref_text.command_key=" ++ source ++ ".command_key AND ref_text.ordinal=0 AND ref_text.part_kind=1))";
    return "(" ++ source ++ ".input_reference_digest IS NOT NULL AND ((" ++ single ++ " AND " ++ source ++ ".input_reference_length IS NOT NULL AND EXISTS(" ++
        "SELECT 1 FROM input_part ref_part JOIN content ref_bytes ON ref_bytes.content_id=ref_part.content_id WHERE ref_part.command_key=" ++ source ++
        ".command_key AND ref_part.ordinal=0 AND ref_bytes.byte_length=" ++ source ++ ".input_reference_length AND ref_bytes.digest=" ++ source ++
        ".input_reference_digest)) OR (NOT " ++ single ++ " AND " ++ source ++ ".input_reference_length IS NULL)))";
}

/// The old scalar Text projection is a selection from the canonical
/// sequence, never a second payload owner. Compound input has no such id.
pub fn messageTextIdSql(comptime source: []const u8) []const u8 {
    return "(SELECT input_text.content_id FROM input_part input_text WHERE input_text.command_key=" ++ source ++
        ".command_key AND input_text.command_kind=2 AND input_text.part_count=1 AND input_text.ordinal=0 AND input_text.part_kind=1)";
}

pub fn messageBytesSql(comptime source: []const u8) []const u8 {
    return "(SELECT coalesce(sum(input_bytes.byte_length),0) FROM input_part input_size JOIN content input_bytes ON input_bytes.content_id=input_size.content_id " ++
        "WHERE input_size.command_key=" ++ source ++ ".command_key)";
}

const message_certificate = rsql.Read(.{
    .sql = "SELECT c.input_part_count AS expected,c.input_reference_length AS reference_length,c.input_reference_digest AS reference_digest,c.accepted,CASE WHEN " ++ messageConsistentSql("c", true) ++ " THEN 1 ELSE 0 END AS consistent " ++
        "FROM core_command c WHERE c.command_key=?1 AND c.kind=2",
    .Args = struct { key: []const u8 },
    .Row = struct { expected: u64, reference_length: ?u64, reference_digest: ?[32]u8, accepted: bool, consistent: bool },
    .cardinality = .optional,
});

const PartRow = struct {
    ordinal: u64,
    content_id: rsql.Positive,
    length: u64,
    digest: [32]u8,
    private: bool,
    part_kind: u8,
    image_format: ?u8,
    image_width: ?u64,
    image_height: ?u64,
    display_name: ?parts.Name,

    fn part(row: *const PartRow) error{CorruptStore}!Part {
        if (row.private) return error.CorruptStore;
        const ordinal = std.math.cast(u32, row.ordinal) orelse return error.CorruptStore;
        const kind: parts.Kind = switch (row.part_kind) {
            1 => text: {
                if (row.image_format != null or row.image_width != null or row.image_height != null or row.display_name != null) return error.CorruptStore;
                break :text .text;
            },
            2 => image: {
                const format = std.enums.fromInt(@import("../../input_media.zig").Format, row.image_format orelse return error.CorruptStore) orelse return error.CorruptStore;
                const width = std.math.cast(u32, row.image_width orelse return error.CorruptStore) orelse return error.CorruptStore;
                const height = std.math.cast(u32, row.image_height orelse return error.CorruptStore) orelse return error.CorruptStore;
                if (width == 0 or height == 0) return error.CorruptStore;
                if (row.display_name) |*name| _ = parts.displayName(name.slice()) catch return error.CorruptStore;
                break :image .{ .image = .{ .media = .{ .format = format, .width = width, .height = height }, .name = row.display_name } };
            },
            else => return error.CorruptStore,
        };
        return .{ .ordinal = ordinal, .content_id = row.content_id.get(), .reference = .{ .length = row.length, .digest = row.digest }, .kind = kind };
    }
};

const part_columns = "p.ordinal,p.content_id,c.byte_length AS length,c.digest,c.private,p.part_kind,p.image_format,p.image_width,p.image_height,p.display_name";
const message_part = rsql.Read(.{
    .sql = "SELECT " ++ part_columns ++ " FROM input_part p JOIN content c ON c.content_id=p.content_id JOIN core_command source " ++
        "ON source.command_key=p.command_key AND source.kind=p.command_kind AND source.input_part_count=p.part_count " ++
        "WHERE p.command_key=?1 AND p.command_kind=2 AND p.ordinal>=?2 ORDER BY p.ordinal LIMIT 1",
    .Args = struct { key: []const u8, ordinal: u32 },
    .Row = PartRow,
    .cardinality = .optional,
});
pub const Part = struct {
    ordinal: u32,
    content_id: u64,
    reference: content.ContentReference,
    kind: parts.Kind,
};

/// One immutable producer, read one part per round. Opening verifies actual
/// row count; each ordinal is checked before returning its part. A missing
/// new part cannot become a legacy refusal or a history-floor omission.
pub const Cursor = struct {
    producer: Producer,
    certificate: Certificate = undefined,
    expected_reference: Reference = undefined,
    ordinal: u32 = 0,
    failed: bool = false,
    digest: parts.Digest = .init(),
    single_text: ?@FieldType(Reference, "text") = null,
    pending: union { message: message_certificate.Result, part: ?PartRow } = undefined,

    pub fn queueOpen(self: *Cursor, a: anytype) void {
        switch (self.producer) {
            .message => |*key| {
                self.pending = .{ .message = null };
                a.read(message_certificate, .{ .key = key.slice() }, &self.pending.message);
            },
        }
    }

    pub fn opened(self: *Cursor) !Certificate {
        errdefer self.failed = true;
        self.certificate = switch (self.producer) {
            .message => message: {
                const row = self.pending.message orelse return error.CorruptStore;
                if (!row.consistent) return error.CorruptStore;
                if (row.expected == 0) {
                    if (row.accepted or row.reference_length != null or row.reference_digest != null) return error.CorruptStore;
                    break :message .legacy_unavailable;
                }
                const count = std.math.cast(u32, row.expected) orelse return error.CorruptStore;
                const digest = row.reference_digest orelse return error.CorruptStore;
                self.expected_reference = if (row.reference_length) |length| .{ .text = .{ .length = length, .digest = digest } } else .{ .parts = .{ .count = count, .digest = digest } };
                break :message .{ .retained = count };
            },
        };
        return self.certificate;
    }

    pub fn queueNext(self: *Cursor, a: anytype) !bool {
        if (self.failed) return error.CorruptStore;
        const count = switch (self.certificate) {
            .legacy_unavailable => return false,
            .retained => |count| count,
        };
        if (self.ordinal == count) return false;
        self.pending = .{ .part = null };
        switch (self.producer) {
            .message => |*key| a.read(message_part, .{ .key = key.slice(), .ordinal = self.ordinal }, &self.pending.part),
        }
        return true;
    }

    pub fn next(self: *Cursor) !Part {
        if (self.failed) return error.CorruptStore;
        errdefer self.failed = true;
        const row = self.pending.part orelse return error.CorruptStore;
        if (row.ordinal != self.ordinal) return error.CorruptStore;
        const result = try row.part();
        const count = self.certificate.retained;
        if (self.ordinal >= count) return error.CorruptStore;
        const identity: parts.Identity = .{ .length = result.reference.length, .digest = result.reference.digest, .kind = result.kind };
        self.digest.append(&identity) catch return error.CorruptStore;
        if (count == 1 and result.kind == .text) self.single_text = .{ .length = result.reference.length, .digest = result.reference.digest };
        self.ordinal += 1;
        if (self.ordinal == count) _ = try self.reference();
        return result;
    }

    pub fn reference(self: *const Cursor) error{CorruptStore}!Reference {
        if (self.failed or self.certificate != .retained or self.ordinal != self.certificate.retained) return error.CorruptStore;
        const actual: Reference = if (self.single_text) |text| .{ .text = text } else .{ .parts = .{ .count = self.ordinal, .digest = self.digest.finish() catch return error.CorruptStore } };
        if (!std.meta.eql(actual, self.expected_reference)) return error.CorruptStore;
        return actual;
    }
};

/// Completes canonical metadata validation under the caller's existing read
/// hold, including a compound certificate, before any unsupported projection.
pub fn verify(a: anytype, key: Bounded(idempotency_key.max_bytes)) !void {
    var cursor: Cursor = .{ .producer = .{ .message = key } };
    cursor.queueOpen(a);
    try store_access.runNamed(a, .{}, error.CorruptStore);
    if (try cursor.opened() == .legacy_unavailable) return error.CorruptStore;
    while (try cursor.queueNext(a)) {
        try store_access.runNamed(a, .{}, error.CorruptStore);
        _ = try cursor.next();
    }
    _ = try cursor.reference();
}
