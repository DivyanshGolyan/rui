//! Saved models.dev facts. Publication is one transaction: a model_id is
//! unique across generations, so committing a partial refresh would hide old facts.
const std = @import("std");
const protocol = @import("../../protocol.zig");
const catalog = @import("../../model_catalog.zig");
const rsql = @import("../rsql.zig");

pub const Source = struct {
    etag: ?protocol.Bounded(512),
    generation: u64,
    fetched_at: i64,
};

pub const Fact = struct {
    context_window: ?u32,
    efforts: u8,
    openai_listed: bool,
    generation: u64,
};

pub const source = rsql.Read(.{
    .sql = "SELECT etag,generation,fetched_at FROM model_catalog_source WHERE slot=1",
    .Args = struct {},
    .Row = Source,
    .cardinality = .optional,
});

pub const fact = rsql.Read(.{
    .sql = "SELECT fact.context_window,fact.efforts,fact.openai_listed,fact.generation FROM model_fact fact JOIN model_catalog_source source ON source.generation=fact.generation WHERE source.slot=1 AND fact.model_id=?1",
    .Args = struct { id: []const u8 },
    .Row = Fact,
    .cardinality = .optional,
});

pub const openai_ids = rsql.Read(.{
    .sql = "SELECT fact.model_id FROM model_fact fact JOIN model_catalog_source source ON source.generation=fact.generation WHERE source.slot=1 AND fact.openai_listed=1 ORDER BY fact.model_id",
    .Args = struct {},
    .Row = struct { model_id: protocol.Bounded(256) },
    .cardinality = .each,
});

const existing = rsql.Read(.{
    .sql = "SELECT model_id FROM model_fact",
    .Args = struct {},
    .Row = struct { model_id: protocol.Bounded(256) },
    .cardinality = .each,
});
const FactArgs = struct { id: []const u8, context_window: ?u32, efforts: u8, openai_listed: bool, generation: u64 };
const insert_fact = rsql.Write(.{
    .sql = "INSERT INTO model_fact(model_id,context_window,efforts,openai_listed,generation) VALUES(?1,?2,?3,?4,?5)",
    .Args = FactArgs,
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});
const update_fact = rsql.Write(.{
    .sql = "UPDATE model_fact SET context_window=?2,efforts=?3,openai_listed=?4,generation=?5 WHERE model_id=?1",
    .Args = FactArgs,
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});
const SourceArgs = struct { etag: ?[]const u8, generation: u64 };
const insert_source = rsql.Write(.{
    .sql = "INSERT INTO model_catalog_source(slot,etag,generation,fetched_at) VALUES(1,?1,?2,@now)",
    .Args = SourceArgs,
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});
const update_source = rsql.Write(.{
    .sql = "UPDATE model_catalog_source SET etag=?1,generation=?2,fetched_at=@now WHERE slot=1",
    .Args = SourceArgs,
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

/// Access bounds each queued batch and flushes repeated statements. All
/// batches share one transaction; only its final COMMIT publishes the source.
/// These statements serve the infrequent bulk refresh, not a Session's
/// hot path. The Store releases their prepared forms after the outer commit.
pub const save_statements = .{ source, existing, insert_fact, update_fact, insert_source, update_source };

/// Keys borrow only this refresh's entries, not rows from the Store. The
/// bulk read marks which already exist, including IDs in older generations.
const Existing = struct {
    ids: std.StringHashMap(bool),

    pub fn visit(self: *Existing, row: *const existing.Row) bool {
        if (self.ids.getPtr(row.model_id.slice())) |found| found.* = true;
        return true;
    }
};

pub fn save(a: anytype, entries: []const catalog.Entry, etag: ?[]const u8) !void {
    var known: Existing = .{ .ids = .init(std.heap.page_allocator) };
    defer known.ids.deinit();
    for (entries) |entry| try known.ids.put(entry.id, false);

    var previous: ?Source = null;
    a.read(source, .{}, &previous);
    // D202 forbids production DELETE, and rsql has no upsert. Read all
    // existence once, then let Access batch writes without per-ID waits.
    a.readEach(existing, .{}, std.math.maxInt(u64), &known);
    try a.run();
    const generation = std.math.add(u64, if (previous) |p| p.generation else 0, 1) catch return error.CorruptStore;
    for (entries) |entry| {
        const args: FactArgs = .{
            .id = entry.id,
            .context_window = entry.context_window,
            .efforts = @intCast(entry.efforts.bits.mask),
            .openai_listed = entry.openai_listed,
            .generation = generation,
        };
        const old = known.ids.getPtr(entry.id).?;
        if (old.*) a.write(update_fact, args) else a.write(insert_fact, args);
        old.* = true;
    }
    const args: SourceArgs = .{ .etag = etag, .generation = generation };
    if (previous != null) a.write(update_source, args) else a.write(insert_source, args);
    try a.commit();
}
