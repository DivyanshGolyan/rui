//! Saved models.dev facts. Publication is one transaction: a model_id is
//! unique across generations, so committing a partial refresh would hide old facts.
const std = @import("std");
const Bounded = @import("../../bounded.zig").Bounded;
const catalog = @import("../../model_catalog.zig");
const rsql = @import("../rsql.zig");
const store_core = @import("../Store.zig");
const transition = @import("../transition.zig");

pub const Source = struct {
    etag: ?Bounded(512),
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
    .Row = struct { model_id: Bounded(256) },
    .cardinality = .each,
});

// One statement selects the authority and its facts together. The LEFT JOIN
// deliberately emits a source-only row for an empty generation or absent ID:
// neither may resurrect a shipped entry. No source emits no rows.
fn selectionSql(comptime columns: []const u8, comptime model: ?[]const u8) []const u8 {
    return "SELECT " ++ columns ++ " FROM model_catalog_source source LEFT JOIN model_fact fact " ++
        "ON fact.generation=source.generation" ++
        // Full traversal and a non-null point lookup need different plans.
        // A nullable OR would scan every fact inside the admission hold.
        (if (model) |id| " AND fact.model_id=" ++ id else "") ++ " WHERE source.slot=1";
}
const selection_columns = "fact.model_id,fact.context_window,fact.efforts,fact.openai_listed";

/// Effective window selected inside an Operation's INSERT, with no extra round.
/// A source-only row (empty generation, missing model or null window) uses the
/// unlisted fallback; only no source uses the bound shipped window. Keep that
/// authority selection shared with Model and the full-catalog reader.
pub fn contextWindowSql(comptime model: []const u8, comptime shipped: []const u8, comptime unlisted: []const u8) []const u8 {
    return "coalesce((" ++ selectionSql("coalesce(fact.context_window," ++ unlisted ++ ")", model) ++ ")," ++ shipped ++ ")";
}
const SelectionRow = struct {
    model_id: ?Bounded(256),
    context_window: ?u32,
    efforts: ?u8,
    openai_listed: ?bool,

    fn entry(self: *const SelectionRow, id: []const u8) catalog.Entry {
        return .{
            .id = id,
            .context_window = self.context_window,
            .efforts = .{ .bits = .{ .mask = @intCast(self.efforts.?) } },
            .openai_listed = self.openai_listed.?,
        };
    }
};
const selected = rsql.Read(.{
    .sql = selectionSql(selection_columns, null) ++ " ORDER BY fact.model_id",
    .Args = struct {},
    .Row = SelectionRow,
    .cardinality = .each,
});
const selected_model = rsql.Read(.{
    .sql = selectionSql(selection_columns, "?1"),
    .Args = struct { id: []const u8 },
    .Row = SelectionRow,
    .cardinality = .optional,
});

/// Operation-scoped single-model selection, including the source-only row.
/// Queue alongside other reads, then call facts after the round completes.
pub const Model = struct {
    row: ?SelectionRow = null,
    entry: [1]catalog.Entry = undefined,

    pub fn read(self: *Model, a: anytype, id: []const u8) void {
        a.read(selected_model, .{ .id = id }, &self.row);
    }

    /// Borrowed until this Model is released or read again. When there is no
    /// source, the shipped snapshot is borrowed instead (the same selection
    /// rule as the full-catalog read).
    pub fn facts(self: *Model) []const catalog.Entry {
        const row = if (self.row) |*row| row else return catalog.shipped;
        const id = if (row.model_id) |*id| id.slice() else return &.{};
        self.entry[0] = row.entry(id);
        return &self.entry;
    }
};

const Selection = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(catalog.Entry) = .empty,
    saved: bool = false,
    failed: bool = false,

    pub fn visit(self: *Selection, row: *const SelectionRow) bool {
        self.saved = true;
        const id = if (row.model_id) |*id| id.slice() else return true;
        const owned = self.allocator.dupe(u8, id) catch {
            self.failed = true;
            return false;
        };
        self.entries.append(self.allocator, row.entry(owned)) catch {
            self.allocator.free(owned);
            self.failed = true;
            return false;
        };
        return true;
    }

    fn deinit(self: *Selection) void {
        for (self.entries.items) |entry| self.allocator.free(entry.id);
        self.entries.deinit(self.allocator);
    }
};

/// Full selected generation for a single consumer operation. The caller's
/// arena owns all saved entries and IDs; no source borrows shipped instead.
/// One SELECT/Store round, with no separately observed source/fact state.
pub fn readSelected(a: anytype, arena: std.mem.Allocator) ![]const catalog.Entry {
    var selection: Selection = .{ .allocator = arena };
    errdefer selection.deinit();
    a.readEach(selected, .{}, std.math.maxInt(u64), &selection);
    try a.run();
    if (selection.failed) return error.OutOfMemory;
    if (!selection.saved) return catalog.shipped;
    return selection.entries.toOwnedSlice(arena);
}

const existing = rsql.Read(.{
    .sql = "SELECT model_id FROM model_fact",
    .Args = struct {},
    .Row = struct { model_id: Bounded(256) },
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

/// Saves `entries` and `etag` as the next generation in one transaction.
/// Round `.facts` reads the saved source and which IDs exist, in any
/// generation; the commit round inserts or updates each fact and the
/// source. Access flushes the commit round's writes in bounded batches,
/// all inside the transaction.
pub const Save = struct {
    pub const rounds = transition.rounds(.{ .facts = .{.always} });
    pub const round_budget = 2;
    pub const commit: transition.Commit = .transaction;
    pub const begin: ?rounds.At = .facts;
    /// The caller's, which outlive the transition: the writes bind each
    /// entry's ID and the etag in place.
    pub const Input = struct { entries: []const catalog.Entry, etag: ?[]const u8 };
    pub const Result = void;
    pub const Ordinary = store_core.Ordinary.none;
    pub const Guards = error{};
    pub const Declined = error{};

    input: Input,
    known: Existing = .{ .ids = .init(std.heap.page_allocator) },
    previous: ?Source = null,

    pub fn step(t: *Save, r: *transition.Round(Save), ran: ?rounds.At) !transition.Next(Save) {
        if (ran == null) {
            for (t.input.entries) |entry| try t.known.ids.put(entry.id, false);
            r.read(source, .{}, &t.previous);
            // D202 forbids production DELETE, and rsql has no upsert. Read all
            // existence once, then let Access batch writes without per-ID waits.
            r.readEach(existing, .{}, std.math.maxInt(u64), &t.known);
            return .{ .round = .facts };
        }
        const generation = std.math.add(u64, if (t.previous) |p| p.generation else 0, 1) catch return error.CorruptStore;
        for (t.input.entries) |entry| {
            const args: FactArgs = .{
                .id = entry.id,
                .context_window = entry.context_window,
                .efforts = @intCast(entry.efforts.bits.mask),
                .openai_listed = entry.openai_listed,
                .generation = generation,
            };
            const old = t.known.ids.getPtr(entry.id).?;
            if (old.*) r.write(update_fact, args) else r.write(insert_fact, args);
            old.* = true;
        }
        const args: SourceArgs = .{ .etag = t.input.etag, .generation = generation };
        if (t.previous != null) r.write(update_source, args) else r.write(insert_source, args);
        return .commit;
    }

    pub fn committed(_: *const Save) Result {}

    pub fn deinit(t: *Save) void {
        t.known.ids.deinit();
    }
};
