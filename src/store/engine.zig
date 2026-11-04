//! The Store's engine: its one connection and the round mechanics Access
//! runs on it. Access queues a statement (`statementFor`, then `bind`),
//! and a pass steps what is queued, in order (`nextRow`, `decodeRow`,
//! `stepWrite`, `endStatement`). The guards, cardinalities and passes stay
//! in Access, written once for every engine.

const Sqlite = @import("engine/Sqlite.zig");

pub const Kind = enum { sqlite };

/// An engine's handle on one queued statement.
pub const Statement = *opaque {};

/// Transaction control, which only the Store's `begin`, `commit` and
/// rollbacks run; each engine spells it.
pub const Control = enum { begin, commit, rollback, savepoint, release, rollback_to };

pub const ControlError = error{ StatementPrepareFailed, OutOfMemory, SqliteExecFailed };

/// What a round reports besides its guards' errors. Each one fences.
pub const Failure = error{
    BindFailed,
    IntegerOutOfRange,
    StatementPrepareFailed,
    OutOfMemory,
    StatementFailed,
    CanonicalStorageFull,
    CanonicalRollbackFailed,
    CorruptStore,
    ContentWriteFailed,
    ContentReadFailed,
    RangeOutOfBounds,
    SqliteExecFailed,
    ClockReadFailed,
    SessionPositionExhausted,
    IdentityExhausted,
    IdentityOutsideTransaction,
    IdentityReadFailed,
    TooManyPositionClaims,
    ContentNotInserted,
};

pub const Engine = union(Kind) {
    sqlite: Sqlite,

    /// `S`'s handle, for `bind` and the pass that steps it.
    pub fn statementFor(e: *Engine, comptime S: type) error{ StatementPrepareFailed, OutOfMemory }!?Statement {
        return switch (e.*) {
            .sqlite => |*s| try s.statementFor(S),
        };
    }

    pub fn bind(e: *Engine, statement: ?Statement, comptime S: type, args: *const S.Args, now: i64) Failure!void {
        return switch (e.*) {
            .sqlite => Sqlite.bind(statement, S, args, now),
        };
    }

    /// Drops a statement bound but never stepped.
    pub fn discard(e: *Engine, statement: ?Statement) void {
        switch (e.*) {
            .sqlite => Sqlite.discard(statement),
        }
    }

    /// True at a row of `statement`, false at its end.
    pub fn nextRow(e: *Engine, statement: ?Statement) Failure!bool {
        return switch (e.*) {
            .sqlite => Sqlite.nextRow(statement),
        };
    }

    /// Decodes the row `nextRow` reached.
    pub fn decodeRow(e: *Engine, comptime Row: type, statement: ?Statement, row: *Row) error{CorruptStore}!void {
        return switch (e.*) {
            .sqlite => Sqlite.decodeRow(Row, statement, row),
        };
    }

    /// Runs a write, and returns the rows it changed.
    pub fn stepWrite(e: *Engine, statement: ?Statement) Failure!u64 {
        return switch (e.*) {
            .sqlite => |*s| s.stepWrite(statement),
        };
    }

    /// Ends a statement its pass ran; null, a content payload, has none.
    pub fn endStatement(e: *Engine, statement: ?Statement) void {
        switch (e.*) {
            .sqlite => Sqlite.endStatement(statement),
        }
    }

    pub fn writePayload(e: *Engine, content_id: u64, bytes: []const u8) Failure!void {
        return switch (e.*) {
            .sqlite => |*s| s.writePayload(content_id, bytes),
        };
    }

    pub fn readRaw(e: *Engine, content_id: u64, offset: u64, destination: []u8) Failure!void {
        return switch (e.*) {
            .sqlite => |*s| s.readRaw(content_id, offset, destination),
        };
    }

    /// A sink on the payload of `content_id`, whose row holds `length` bytes.
    pub fn openSink(e: *Engine, content_id: u64, length: u64) Failure!ContentSink {
        return switch (e.*) {
            .sqlite => |*s| .{ .sqlite = try s.openSink(content_id, length) },
        };
    }

    pub fn control(e: *Engine, comptime which: Control) ControlError!void {
        return switch (e.*) {
            .sqlite => |*s| s.control(which),
        };
    }

    pub fn inTransaction(e: *const Engine) bool {
        return switch (e.*) {
            .sqlite => |*s| s.inTransaction(),
        };
    }

    pub fn inWriteTransaction(e: *const Engine) bool {
        return switch (e.*) {
            .sqlite => |*s| s.inWriteTransaction(),
        };
    }

    /// Advances with every changed row, rolled-back changes included.
    pub fn totalChanges(e: *const Engine) i64 {
        return switch (e.*) {
            .sqlite => |*s| s.totalChanges(),
        };
    }

    /// What an Entry holds until it ends.
    pub fn releaseEntry(e: *Engine) void {
        switch (e.*) {
            .sqlite => |*s| s.releaseEntry(),
        }
    }

    pub fn close(e: *Engine) error{StoreCloseFailed}!void {
        return switch (e.*) {
            .sqlite => |*s| s.close(),
        };
    }
};

/// Writes one content payload in place, at offsets the writer chooses.
pub const ContentSink = union(Kind) {
    sqlite: Sqlite.ContentSink,

    pub fn write(sink: ContentSink, bytes: []const u8, offset: u64) error{ ContentWriteFailed, ContentTooLarge }!void {
        return switch (sink) {
            .sqlite => |s| s.write(bytes, offset),
        };
    }

    pub fn close(sink: ContentSink) void {
        switch (sink) {
            .sqlite => |s| s.close(),
        }
    }
};

comptime {
    if (@sizeOf(Engine) != @sizeOf(Sqlite)) @compileError("a one-variant Engine adds no tag");
    if (@sizeOf(ContentSink) != @sizeOf(Sqlite.ContentSink)) @compileError("a one-variant ContentSink adds no tag");
}
