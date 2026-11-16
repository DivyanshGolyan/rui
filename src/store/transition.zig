const std = @import("std");
const builtin = @import("builtin");
const store_core = @import("Store.zig");
const store_access = @import("access.zig");
const Store = store_core.Store;
const Faults = store_core.Faults;
const rsql = @import("rsql.zig");

pub const Kind = enum {
    always,
    branch,
    paged,
    raw,
};

pub const Commit = enum {
    none,
    transaction,
    single,
};

pub const Pass = enum {
    ordinary,
    wide,
};

pub fn rounds(comptime spec: anytype) type {
    const names = @typeInfo(@TypeOf(spec)).@"struct".field_names;
    var values: [names.len]u8 = undefined;
    var always_count = 0;
    var Named: type = error{};
    for (&values, names, 0..) |*value, name, i| {
        value.* = i;
        const round = @field(spec, name);
        const declared: Kind = round[0];
        always_count += @intFromBool(declared == .always);
        if (round.len >= 2) Named = Named || @TypeOf(round[1]);
        if (round.len == 3) for (round[2]) |pair| {
            Named = Named || @TypeOf(pair[1]);
        };
    }
    const Tags = @Enum(u8, .exhaustive, names, &values);
    const always_rounds = always_count;
    const FailedError = Named;
    return struct {
        pub const At = Tags;
        pub const Error = FailedError;
        pub const always = always_rounds;

        pub fn kind(at: At) Kind {
            return switch (at) {
                inline else => |tag| @field(spec, @tagName(tag))[0],
            };
        }

        pub fn failed(at: At, access: anytype) ?Error {
            return switch (at) {
                inline else => |tag| {
                    const round = @field(spec, @tagName(tag));
                    if (round.len == 3) if (store_access.failedName(access, round[2])) |name| return name;
                    return if (round.len >= 2) round[1] else null;
                },
            };
        }

        pub fn follows(last: ?At, next: At) bool {
            const before = last orelse return true;
            if (next == before) return kind(next) == .paged or kind(next) == .raw;
            return @backingInt(next) > @backingInt(before);
        }
    };
}

pub fn Next(comptime T: type) type {
    return NextOf(T.rounds.At, T.commit, T.Result);
}

fn NextOf(comptime At: type, comptime commit: Commit, comptime Result: type) type {
    return union(enum) {
        round: At,
        commit: if (commit == .none) noreturn else void,
        done: Result,
    };
}

pub fn Round(comptime T: type) type {
    return RoundOf(T.rounds, T.commit, GuardsOf(T), beginIndex(T), passOf(T));
}

fn RoundOf(comptime R: type, comptime commit: Commit, comptime Guards: type, comptime begin: ?u8, comptime pass: Pass) type {
    return struct {
        const Self = @This();
        core: *anyopaque,

        fn get(r: *Self) *Core(R, commit, Guards, begin, pass) {
            return @ptrCast(@alignCast(r.core));
        }

        fn writes(comptime what: []const u8) void {
            if (commit == .none) @compileError("a transition that commits nothing " ++ what);
        }

        fn transacts(comptime what: []const u8) void {
            if (commit != .transaction) @compileError("only a transaction " ++ what);
        }

        pub fn read(r: *Self, comptime S: type, args: S.Args, destination: *S.Result) void {
            const core = r.get();
            if (core.inside()) core.writer.read(S, args, destination) else core.reader.read(S, args, destination);
        }

        pub fn readInto(r: *Self, comptime S: type, args: S.Args, row: *S.Row, found: *store_access.Found) void {
            const core = r.get();
            if (core.inside()) core.writer.readInto(S, args, row, found) else core.reader.readInto(S, args, row, found);
        }

        pub fn readEach(r: *Self, comptime S: type, args: S.Args, limit: u64, visitor: anytype) void {
            const core = r.get();
            if (core.inside()) core.writer.readEach(S, args, limit, visitor) else core.reader.readEach(S, args, limit, visitor);
        }

        pub fn readEachFrom(r: *Self, comptime S: type, args: *const S.Args, limit: u64, visitor: anytype) void {
            const core = r.get();
            if (core.inside()) core.writer.readEachFrom(S, args, limit, visitor) else core.reader.readEachFrom(S, args, limit, visitor);
        }

        pub fn write(r: *Self, comptime S: type, args: S.Args) void {
            writes("queues no write: " ++ S.sql);
            r.get().writer.write(S, args);
        }

        pub fn invalidateSessions(r: *Self) void {
            transacts("invalidates Session listing");
            r.get().writer.store.touched.everything = true;
        }

        pub fn obligationsChanged(r: *Self, head: rsql.SessionHead) void {
            transacts("changes obligations");
            r.get().writer.obligationsChanged(head);
        }

        pub fn readRaw(r: *Self, content_id: u64, offset: u64, destination: []u8) error{}!void {
            const core = r.get();
            if (core.raw != null) @panic("a raw round reads one window");
            core.raw = .{ .content_id = content_id, .offset = offset, .destination = destination };
        }

        pub fn writeCount(r: *Self, comptime S: type, args: S.Args, rows: u64) void {
            writes("queues no write: " ++ S.sql);
            r.get().writer.writeCount(S, args, rows);
        }

        pub fn positions(r: *Self, head: rsql.SessionHead) error{TooManyPositionClaims}!*store_access.Positions {
            transacts("claims positions");
            return r.get().writer.positions(head);
        }

        pub fn identity(r: *Self, comptime column: store_core.Identity) !u64 {
            transacts("takes identities");
            return r.get().writer.identity(column);
        }

        pub fn writeContent(r: *Self, content_id: u64, bytes: []const u8) void {
            transacts("writes content");
            r.get().writer.writeContent(content_id, bytes);
        }

        pub fn insertedContent(r: *Self, digest: *const [32]u8, length: u64, private: bool) ?u64 {
            transacts("inserts content");
            return r.get().writer.insertedContent(digest, length, private);
        }

        pub fn recordInserted(r: *Self, digest: *const [32]u8, length: u64, private: bool, content_id: u64) void {
            transacts("inserts content");
            r.get().writer.recordInserted(digest, length, private, content_id);
        }

        pub fn recordContentRow(r: *Self, content_id: u64) void {
            transacts("inserts content");
            r.get().writer.recordContentRow(content_id);
        }

        pub fn contentSink(r: *Self, content_id: u64, length: u64) !store_access.ContentSink {
            transacts("streams content");
            return r.get().writer.contentSink(content_id, length);
        }

        pub fn configurationReads(r: *Self) @typeInfo(@TypeOf(Store.configurationReads)).@"fn".return_type.? {
            transacts("leases the configure reads");
            return r.get().writer.store.configurationReads();
        }

        pub fn attemptTimings(r: *Self, operation: u64) @import("../model_timing.zig").Values {
            writes("ends no Attempt");
            return r.get().writer.attemptTimings(operation);
        }

        pub fn transactionOpen(r: *Self) bool {
            transacts("opens a transaction");
            return r.get().writer.transactionOpen();
        }

        pub fn faults(r: *Self) Faults {
            return r.get().faults;
        }
    };
}

fn beginIndex(comptime T: type) ?u8 {
    const at: T.rounds.At = T.begin orelse return null;
    return @backingInt(at);
}

fn passOf(comptime T: type) Pass {
    return if (@hasDecl(T, "pass")) T.pass else .ordinary;
}

fn GuardsOf(comptime T: type) type {
    return if (T.commit == .none) error{} else T.Guards;
}

fn CoreFor(comptime T: type) type {
    return Core(T.rounds, T.commit, GuardsOf(T), beginIndex(T), passOf(T));
}

fn Core(comptime R: type, comptime commit: Commit, comptime Guards: type, comptime begin: ?u8, comptime pass: Pass) type {
    const reads_outside = (begin orelse 1) > 0;
    return struct {
        const Self = @This();
        reader: if (reads_outside) store_access.Access(.read, error{}) else void,
        writer: switch (commit) {
            .none => void,
            .transaction => store_access.Access(if (pass == .wide) .settlement else .write, Guards),
            .single => store_access.Access(.single, Guards),
        },
        faults: Faults,
        last: ?R.At = null,
        raw: ?struct { content_id: u64, offset: u64, destination: []u8 } = null,

        fn opened(core: *const Self) bool {
            const first = begin orelse return false;
            const next = if (core.last) |last| @backingInt(last) + 1 else 0;
            return next >= first;
        }

        inline fn inside(core: *const Self) bool {
            if (commit == .none) return false;
            if (!reads_outside) return true;
            return core.opened();
        }
    };
}

fn check(comptime T: type) void {
    const commits: comptime_int = @intFromBool(T.commit != .none);
    if (T.round_budget != T.rounds.always + commits) @compileError(std.fmt.comptimePrint(
        "{s}.round_budget is {d}, but it declares {d} .always rounds and {d} commit",
        .{ @typeName(T), T.round_budget, T.rounds.always, commits },
    ));
    if (@sizeOf(T) > 1024) @compileError(std.fmt.comptimePrint(
        "{s} is {d} bytes; a transition value holds at most 1 KiB",
        .{ @typeName(T), @sizeOf(T) },
    ));
    if (passOf(T) == .wide and T.commit != .transaction) @compileError(@typeName(T) ++ ": only a transaction steps a wide pass");
    if (beginIndex(T)) |begin| {
        if (T.commit == .none) @compileError(@typeName(T) ++ " opens a transaction but commits nothing");
        for (0..begin) |i| if (T.rounds.kind(@fromBackingInt(@intCast(i))) != .always)
            @compileError(@typeName(T) ++ ": every round before begin is .always");
    }
    if (T.commit != .none) outer: for (@typeInfo(T.Declined).error_set.error_names.?) |name| {
        for (@typeInfo(T.Guards).error_set.error_names.?) |guard| if (std.mem.eql(u8, name, guard)) continue :outer;
        @compileError(@typeName(T) ++ " declines error." ++ name ++ ", which none of its Guards reports");
    };
}

pub noinline fn run(entry: *const store_core.Entry, comptime T: type, t: *T, faults: Faults) !T.Result {
    comptime check(T);
    const State = CoreFor(T);
    var core: State = undefined;
    core.faults = faults;
    core.last = null;
    core.raw = null;
    if (@FieldType(State, "reader") != void) core.reader.init(entry);
    if (T.commit != .none) core.writer.init(entry);
    defer if (@FieldType(State, "reader") != void) core.reader.deinit();
    defer if (T.commit != .none) core.writer.deinit();
    const result = drive(T, t, &core);
    if (comptime @hasDecl(T, "failed")) if (result) |_| {} else |_| T.failed(t);
    if (T.commit != .none) return end(T, &core, result) else return result;
}

fn drive(comptime T: type, t: *T, core: *CoreFor(T)) !T.Result {
    var round: Round(T) = .{ .core = core };
    while (true) switch (try T.step(t, &round, core.last)) {
        .round => |at| try runRound(T, core, at),
        .commit => if (T.commit == .none) unreachable else return commitRun(T, t, core),
        .done => |result| {
            if (T.commit != .none) try abandon(T, core);
            return result;
        },
    };
}

noinline fn runRound(comptime T: type, core: *CoreFor(T), at: T.rounds.At) !void {
    if (builtin.is_test and !T.rounds.follows(core.last, at)) std.debug.panic(
        "{s} asked for round {s} after {s}: rounds run in declared order, and only a .paged one repeats",
        .{ @typeName(T), @tagName(at), if (core.last) |before| @tagName(before) else "none" },
    );
    const begin = comptime beginIndex(T);
    const inside = if (begin) |first| @backingInt(at) >= first else false;
    std.debug.assert(inside == core.opened());
    if (T.rounds.kind(at) == .raw) {
        const window = core.raw orelse @panic("a raw round reads the window Round.readRaw asked for");
        core.raw = null;
        if (@FieldType(CoreFor(T), "reader") != void and !inside) {
            core.reader.readRaw(window.content_id, window.offset, window.destination) catch |err| return named(T, at, err, &core.reader);
        } else if (T.commit != .none) {
            core.writer.readRaw(window.content_id, window.offset, window.destination) catch |err| return named(T, at, err, &core.writer);
        } else unreachable;
    } else if (core.raw != null) {
        @panic("a window Round.readRaw asked for is read only by a .raw round");
    } else if (@FieldType(CoreFor(T), "reader") != void and !inside) {
        if (T.commit != .none) std.debug.assert(core.writer.queued == 0);
        core.reader.run() catch |err| return named(T, at, err, &core.reader);
    } else {
        core.writer.run() catch |err| return named(T, at, err, &core.writer);
    }
    core.last = at;
}

noinline fn commitRun(comptime T: type, t: *T, core: *CoreFor(T)) !T.Result {
    if (@FieldType(CoreFor(T), "reader") != void) std.debug.assert(core.reader.queued == 0);
    std.debug.assert(core.raw == null);
    const committing = if (comptime @hasDecl(T, "follow")) core.writer.commitFollowed(T.follow(t)) else core.writer.commit();
    committing catch |err| {
        if (comptime @typeInfo(T.Declined).error_set.error_names.?.len != 0) if (declinedBy(T, err)) |declined| {
            try core.writer.abandon(core.faults);
            return T.declined(t, declined);
        };
        return err;
    };
    if (comptime @hasDecl(T, "announced")) if (T.announced(t)) |announcement| store_core.announce(core.writer.store, announcement);
    return T.committed(t);
}

noinline fn abandon(comptime T: type, core: *CoreFor(T)) !void {
    try core.writer.abandon(core.faults);
}

noinline fn end(comptime T: type, core: *CoreFor(T), result: anytype) @TypeOf(result) {
    return core.writer.end(core.faults, result);
}

fn named(comptime T: type, at: T.rounds.At, err: anytype, access: anytype) (@TypeOf(err) || T.rounds.Error) {
    if (err == error.StatementFailed) if (T.rounds.failed(at, access)) |failed| return failed;
    return err;
}

fn declinedBy(comptime T: type, err: anyerror) ?T.Declined {
    const names = @typeInfo(T.Declined).error_set.error_names orelse return null;
    inline for (names) |name| if (err == @field(anyerror, name)) return @errorCast(err);
    return null;
}

pub fn apply(self: *Store, comptime T: type, input: T.Input, faults: Faults) !T.Result {
    const entry = try store_core.enter(self, .fromControl(faults.control_trace));
    defer entry.release();
    var t: T = .{ .input = input };
    defer if (comptime @hasDecl(T, "deinit")) t.deinit();
    return entry.finishTransaction(T.Ordinary, faults, run(&entry, T, &t, faults));
}
