const std = @import("std");
const Sqlite = @import("engine/Sqlite.zig");
pub const Mysql = @import("engine/Mysql.zig");

pub const Kind = @import("../store_target.zig").Kind;

pub const Statement = *opaque {};

pub const Control = @import("write_batch.zig").Control;

pub const ControlError = Failure;

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

pub const ContentHost = struct {
    context: *anyopaque,
    chunk: *const fn (context: *anyopaque, id: u64, index: u64, n: usize) error{ContentWriteFailed}!*std.Io.Writer,
};

pub const Pass = enum { access, identity };

pub const Engine = union(Kind) {
    sqlite: Sqlite,
    mysql: Mysql,

    pub fn publicSelector(e: *const Engine, sqlite_selector: []const u8) []const u8 {
        return switch (e.*) {
            .sqlite => sqlite_selector,
            .mysql => |s| &s.state.store_id,
        };
    }

    pub fn serve(e: *Engine, served: *@import("../provider_route.zig").Routes) !void {
        switch (e.*) {
            .sqlite => |*s| try s.serve(served),
            .mysql => |*s| s.state.served = served,
        }
    }

    pub fn prepareRollback(e: *Engine) !void {
        switch (e.*) {
            .sqlite => |*s| try s.prepareRollback(),
            .mysql => {},
        }
    }

    pub fn admissionDoublewrite(e: *const Engine) ?[]const u8 {
        return switch (e.*) {
            .sqlite => null,
            .mysql => |s| s.state.doublewrite.slice(),
        };
    }

    pub fn diagnostic(e: *Engine) @import("Store.zig").Diagnostic {
        return switch (e.*) {
            .sqlite => |*s| .{ .sqlite = s.diagnostic() },
            .mysql => |*s| .{ .mysql = s.diagnostic() },
        };
    }

    pub inline fn batches(e: *const Engine) bool {
        return switch (e.*) {
            .sqlite => false,
            .mysql => true,
        };
    }

    pub inline fn notePass(e: *Engine, comptime kind: Pass) void {
        if (@import("builtin").is_test) switch (e.*) {
            .sqlite => {},
            .mysql => |*s| s.notePass(kind),
        };
    }

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

    pub inline fn commitArmed(e: *const Engine) bool {
        return switch (e.*) {
            .sqlite => false,
            .mysql => |*s| s.commitArmed(),
        };
    }

    pub inline fn guard(e: *Engine, comptime at_most: bool, rows: u64) bool {
        return switch (e.*) {
            .sqlite => false,
            .mysql => |*s| s.guard(at_most, rows),
        };
    }

    pub inline fn appendCommit(e: *Engine) bool {
        return switch (e.*) {
            .sqlite => false,
            .mysql => |*s| s.appendCommit(),
        };
    }

    pub inline fn dropTail(e: *Engine) void {
        switch (e.*) {
            .sqlite => unreachable,
            .mysql => |*s| s.dropTail(),
        }
    }

    pub inline fn stepCommit(e: *Engine) Failure!void {
        return switch (e.*) {
            .sqlite => unreachable,
            .mysql => |*s| s.stepCommit(),
        };
    }

    pub inline fn settleCommit(e: *Engine) Failure!void {
        return switch (e.*) {
            .sqlite => unreachable,
            .mysql => |*s| s.settleCommit(),
        };
    }

    pub inline fn discardBatch(e: *Engine) Failure!void {
        switch (e.*) {
            .sqlite => {},
            .mysql => |*s| try s.discardBatch(),
        }
    }

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

    pub inline fn discard(e: *Engine, statement: ?Statement) void {
        switch (e.*) {
            .sqlite => Sqlite.discard(statement),
            .mysql => |*s| s.discard(statement),
        }
    }

    pub inline fn nextRow(e: *Engine, statement: ?Statement) Failure!bool {
        return switch (e.*) {
            .sqlite => Sqlite.nextRow(statement),
            .mysql => |*s| s.nextRow(),
        };
    }

    pub inline fn decodeRow(e: *Engine, comptime Row: type, statement: ?Statement, row: *Row) Failure!void {
        return switch (e.*) {
            .sqlite => Sqlite.decodeRow(Row, statement, row),
            .mysql => |*s| s.decodeRow(Row, row),
        };
    }

    pub inline fn stepWrite(e: *Engine, statement: ?Statement) Failure!u64 {
        return switch (e.*) {
            .sqlite => |*s| s.stepWrite(statement),
            .mysql => |*s| s.stepWrite(),
        };
    }

    pub inline fn endStatement(e: *Engine, statement: ?Statement) void {
        switch (e.*) {
            .sqlite => Sqlite.endStatement(statement),
            .mysql => |*s| s.endStatement(),
        }
    }

    pub inline fn queuePayload(e: *Engine, content_id: u64, bytes: []const u8, host: anytype) void {
        switch (e.*) {
            .sqlite => |*s| s.queuePayload(content_id, bytes, host),
            .mysql => |*s| s.queuePayload(content_id, bytes, host),
        }
    }

    pub inline fn stepPayload(e: *Engine, content_id: u64, bytes: []const u8) Failure!void {
        return switch (e.*) {
            .sqlite => |*s| s.writePayload(content_id, bytes),
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

    pub inline fn totalChanges(e: *const Engine) i64 {
        return switch (e.*) {
            .sqlite => |*s| s.totalChanges(),
            .mysql => |*s| s.totalChanges(),
        };
    }

    pub inline fn releaseEntry(e: *Engine) void {
        switch (e.*) {
            .sqlite => |*s| s.releaseEntry(),
            .mysql => |*s| s.releaseEntry(),
        }
    }

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
