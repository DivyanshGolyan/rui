//! The Store's engine: its one connection and the round mechanics Access
//! runs on it. Access queues a statement (`statementFor`, then `bind`),
//! and a pass steps what is queued, in order (`nextRow`, `decodeRow`,
//! `stepWrite`, `endStatement`). The guards, cardinalities and passes stay
//! in Access, written once for every engine.

const std = @import("std");
const Sqlite = @import("engine/Sqlite.zig");
pub const Mysql = @import("engine/Mysql.zig");

pub const Kind = enum { sqlite, mysql };

/// An engine's handle on one queued statement.
pub const Statement = *opaque {};

/// Transaction control, which only the Store's `begin`, `commit` and
/// rollbacks run; each engine spells it.
pub const Control = enum { begin, commit, rollback, savepoint, release, rollback_to };

pub const ControlError = Failure;

/// What a round reports besides its guards' errors. Each one fences.
pub const Failure = error{
    StoreConnectionLost,
    CommitOutcomeUnknown,
    OwnershipLost,
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

/// Where a streaming adapter queues a payload statement. Access owns the
/// queue and steps the result; the adapter owns its representation.
pub const ContentHost = struct {
    context: *anyopaque,
    chunk: *const fn (context: *anyopaque, id: u64, index: u64, n: usize) error{ContentWriteFailed}!*std.Io.Writer,
};

pub const Pass = enum { access, identity };

pub const Engine = union(Kind) {
    sqlite: Sqlite,
    mysql: Mysql,

    // Each method only picks the variant, so it is inline: one variant
    // costs no call.

    /// Whether binds construct an outgoing batch rather than statements
    /// stepped in process. Also determines the effective `.single` mode.
    pub inline fn batches(e: *const Engine) bool {
        return switch (e.*) {
            .sqlite => false,
            .mysql => true,
        };
    }

    /// Test-only physical pass accounting stays behind the adapter.
    pub inline fn notePass(e: *Engine, comptime kind: Pass) void {
        if (@import("builtin").is_test) switch (e.*) {
            .sqlite => {},
            .mysql => |*s| s.notePass(kind),
        };
    }

    /// Whether this statement fits the pending network batch. SQLite binds in place.
    pub inline fn fits(e: *Engine, comptime S: type, args: *const S.Args, now: i64) Failure!bool {
        return switch (e.*) {
            .sqlite => true,
            .mysql => |*s| s.fits(S, args, now),
        };
    }

    pub inline fn startPass(e: *Engine) Failure!void {
        switch (e.*) {
            .sqlite => {},
            .mysql => |*s| try s.startPass(),
        }
    }

    pub inline fn finishPass(e: *Engine) Failure!void {
        switch (e.*) {
            .sqlite => {},
            .mysql => |*s| try s.finishPass(),
        }
    }

    pub inline fn discardBatch(e: *Engine) Failure!void {
        switch (e.*) {
            .sqlite => {},
            .mysql => |*s| try s.discardBatch(),
        }
    }

    /// `S`'s handle, for `bind` and the pass that steps it.
    pub inline fn statementFor(e: *Engine, comptime S: type) Failure!?Statement {
        return switch (e.*) {
            .sqlite => |*s| try s.statementFor(S),
            .mysql => null,
        };
    }

    pub inline fn bind(e: *Engine, statement: ?Statement, comptime S: type, args: *const S.Args, now: i64) Failure!void {
        return switch (e.*) {
            .sqlite => Sqlite.bind(statement, S, args, now),
            .mysql => |*s| s.bind(S, args, now),
        };
    }

    /// Drops a statement bound but never stepped.
    pub inline fn discard(e: *Engine, statement: ?Statement) void {
        switch (e.*) {
            .sqlite => Sqlite.discard(statement),
            .mysql => |*s| s.discard(statement),
        }
    }

    /// True at a row of `statement`, false at its end.
    pub inline fn nextRow(e: *Engine, statement: ?Statement) Failure!bool {
        return switch (e.*) {
            .sqlite => Sqlite.nextRow(statement),
            .mysql => |*s| s.nextRow(),
        };
    }

    /// Decodes the row `nextRow` reached.
    pub inline fn decodeRow(e: *Engine, comptime Row: type, statement: ?Statement, row: *Row) Failure!void {
        return switch (e.*) {
            .sqlite => Sqlite.decodeRow(Row, statement, row),
            .mysql => |*s| s.decodeRow(Row, row),
        };
    }

    /// Runs a write, and returns the rows it changed.
    pub inline fn stepWrite(e: *Engine, statement: ?Statement) Failure!u64 {
        return switch (e.*) {
            .sqlite => |*s| s.stepWrite(statement),
            .mysql => |*s| s.stepWrite(),
        };
    }

    /// Ends a statement its pass ran; null, a content payload, has none.
    pub inline fn endStatement(e: *Engine, statement: ?Statement) void {
        switch (e.*) {
            .sqlite => Sqlite.endStatement(statement),
            .mysql => |*s| s.endStatement(),
        }
    }

    /// Lower while constructing the outgoing batch, never after startPass.
    /// `host` accepts ordinary typed statements or an in-process payload.
    pub inline fn queuePayload(e: *Engine, content_id: u64, bytes: []const u8, host: anytype) void {
        switch (e.*) {
            .sqlite => |*s| s.queuePayload(content_id, bytes, host),
            .mysql => |*s| s.queuePayload(content_id, bytes, host),
        }
    }

    pub inline fn stepPayload(e: *Engine, content_id: u64, bytes: []const u8) Failure!void {
        return switch (e.*) {
            .sqlite => |*s| s.writePayload(content_id, bytes),
            // Network payloads were lowered to statements at queue time.
            .mysql => unreachable,
        };
    }

    pub inline fn chunkFits(e: *Engine, id: u64, index: u64, n: usize) bool {
        return switch (e.*) {
            .sqlite => unreachable,
            .mysql => |*s| s.chunkFits(id, index, n),
        };
    }

    pub inline fn beginChunk(e: *Engine, id: u64, index: u64) Failure!*std.Io.Writer {
        return switch (e.*) {
            .sqlite => unreachable,
            .mysql => |*s| s.beginChunk(id, index),
        };
    }

    pub inline fn readRaw(e: *Engine, content_id: u64, offset: u64, destination: []u8) Failure!void {
        return switch (e.*) {
            .sqlite => |*s| s.readRaw(content_id, offset, destination),
            .mysql => |*s| s.readRaw(content_id, offset, destination),
        };
    }

    /// A sink on the payload of `content_id`, whose row holds `length`
    /// bytes. On MySQL its chunks ride `host`'s batches.
    pub inline fn openSink(e: *Engine, content_id: u64, length: u64, host: ContentHost) Failure!ContentSink {
        return switch (e.*) {
            .sqlite => |*s| .{ .sqlite = try s.openSink(content_id, length) },
            .mysql => |*s| .{ .mysql = try s.openSink(content_id, length, host) },
        };
    }

    pub inline fn control(e: *Engine, comptime which: Control) ControlError!void {
        return switch (e.*) {
            .sqlite => |*s| s.control(which),
            .mysql => |*s| s.control(which),
        };
    }

    pub inline fn inTransaction(e: *const Engine) bool {
        return switch (e.*) {
            .sqlite => |*s| s.inTransaction(),
            .mysql => |*s| s.inTransaction(),
        };
    }

    pub inline fn inWriteTransaction(e: *const Engine) bool {
        return switch (e.*) {
            .sqlite => |*s| s.inWriteTransaction(),
            .mysql => |*s| s.inWriteTransaction(),
        };
    }

    /// Advances with every changed row, rolled-back changes included.
    pub inline fn totalChanges(e: *const Engine) i64 {
        return switch (e.*) {
            .sqlite => |*s| s.totalChanges(),
            .mysql => |*s| s.totalChanges(),
        };
    }

    /// What an Entry holds until it ends.
    pub inline fn releaseEntry(e: *Engine) void {
        switch (e.*) {
            .sqlite => |*s| s.releaseEntry(),
            .mysql => |*s| s.releaseEntry(),
        }
    }

    /// Bulk work must not leave its pager working set resident. This is a
    /// best-effort cache hint, not a change to durable state or an error edge.
    pub inline fn releaseUnusedMemory(e: *Engine, comptime statements: anytype) void {
        switch (e.*) {
            .sqlite => |*s| s.releaseUnusedMemory(statements),
            .mysql => {},
        }
    }

    pub inline fn close(e: *Engine) error{StoreCloseFailed}!void {
        return switch (e.*) {
            .sqlite => |*s| s.close(),
            .mysql => |*s| s.close(),
        };
    }
};

/// Writes one content payload in place, at offsets the writer chooses.
pub const ContentSink = union(Kind) {
    sqlite: Sqlite.ContentSink,
    mysql: Mysql.ContentSink,

    pub inline fn write(sink: ContentSink, bytes: []const u8, offset: u64) error{ ContentWriteFailed, ContentTooLarge }!void {
        return switch (sink) {
            .sqlite => |s| s.write(bytes, offset),
            .mysql => |s| s.write(bytes, offset),
        };
    }

    pub inline fn close(sink: ContentSink) void {
        switch (sink) {
            .sqlite => |s| s.close(),
            .mysql => |s| s.close(),
        }
    }
};
