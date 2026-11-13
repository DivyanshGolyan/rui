//! A Store transition: a value `T` that queues its statements one declared
//! round at a time, while `run` sends each round and commits. `T` holds
//! its own row destinations and steps through
//! `T.step(t: *T, r: *Round(T), ran: ?T.rounds.At) !Next(T)`: `ran` is the
//! round that just ran, null on the first step. A step queues through
//! `Round`, which has no run, commit or Store, then asks for one of the
//! rounds `T.rounds` declares, for the commit, or ends with a result. So a
//! step cannot add a round trip: a new round is a new tag in `T.rounds`,
//! and `round_budget` must count it.
//!
//! A transition declares:
//! - `rounds`: `rounds(.{ .tag = .{ Kind, error.Named } })`, in the order
//!   the rounds run. A failed statement in a round with a named error is
//!   that error; `.{ Kind }` names none. A third element,
//!   `.{ .{ S, error.Each }, ... }`, names the failure of statement `S`
//!   (`Access.failedOn`) in that round, ahead of the round's own name, as
//!   `store_access.runNamed` does.
//! - `round_budget`: its `.always` rounds plus its commit, checked here.
//! - `commit`: how it commits (`Commit`). One that does not cannot ask to.
//! - `begin`: the round its transaction opens before, or null when its
//!   writes ride the commit round. Rounds before it read outside the
//!   transaction; from it on, reads and writes share the transaction.
//! - `Input`, `Result`, `Ordinary` (the errors `apply` returns without
//!   fencing), `Guards` (every guard error its writes report) and
//!   `Declined` (those of `Guards` whose commit answers `declined(t, err)`
//!   instead of failing).
//! - `committed(t)`, the result once its commit stands.
//! - optionally `announced(t)`, what the Host hears once its commit stands
//!   and before the Store runs anything else (`Store.announce`).
//! - optionally `follow(t)`, the reads its commit carries after COMMIT in
//!   the same message where that message carries reads, or null
//!   (`Access.commitFollowed`): a pointer to a value with `queue(reads)`
//!   and `followed()`, which the value keeps until the commit ends.
//! - optionally `failed(t)`, which lets go of what its steps took on that
//!   only a commit hands on, such as a view its commit's reads fill, when
//!   `run` ends with an error, before its transaction rolls back.
//! - optionally `deinit(t)`, which frees what its steps allocated, once
//!   `apply` ends on any path.
//!
//! The rounds run through `Access` until its queue core moves here.

const std = @import("std");
const builtin = @import("builtin");
const store_core = @import("Store.zig");
const store_access = @import("access.zig");
const Store = store_core.Store;
const Faults = store_core.Faults;
const rsql = @import("rsql.zig");

/// How often a declared round runs on the paths through a transition.
pub const Kind = enum {
    /// On every path that does not end before it.
    always,
    /// On some paths only.
    branch,
    /// Zero or more times, each time a page.
    paged,
    /// Zero or more times, each time one window of a content row's bytes
    /// that the step asked for with `Round.readRaw`, read alone: a content
    /// round (`Access.readRaw`), never one that runs what is queued.
    raw,
};

/// How a transition's writes reach the Store.
pub const Commit = enum {
    /// It writes nothing, and cannot ask to commit.
    none,
    /// One transaction of any number of writes, positions and identities.
    transaction,
    /// Exactly one write and no positions or identities: SQLite runs it in
    /// autocommit under the Entry lock, a batching engine in an
    /// ownership-fenced transaction (`Access`'s `.single`).
    single,
};

/// The rounds `spec` declares, in order: its tag enum `At`, each tag's
/// `Kind` and the error a failed statement in that round answers, if any.
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
        /// The errors this transition's rounds name.
        pub const Error = FailedError;
        /// Its `.always` rounds.
        pub const always = always_rounds;

        pub fn kind(at: At) Kind {
            return switch (at) {
                inline else => |tag| @field(spec, @tagName(tag))[0],
            };
        }

        /// The error a failed statement in `at` answers, or null when the
        /// round names none: the name of the statement whose step failed
        /// in `access`, the Access that ran the round, if the round names
        /// it (`store_access.failedName`), or else the round's.
        pub fn failed(at: At, access: anytype) ?Error {
            return switch (at) {
                inline else => |tag| {
                    const round = @field(spec, @tagName(tag));
                    if (round.len == 3) if (store_access.failedName(access, round[2])) |name| return name;
                    return if (round.len >= 2) round[1] else null;
                },
            };
        }

        /// Whether `next` may run after `last`: rounds run in declared
        /// order, and only a `.paged` or `.raw` round runs again.
        pub fn follows(last: ?At, next: At) bool {
            const before = last orelse return true;
            if (next == before) return kind(next) == .paged or kind(next) == .raw;
            return @backingInt(next) > @backingInt(before);
        }
    };
}

/// What a step asks for: a declared round, the commit, or its result.
/// A transition that commits nothing cannot ask to commit.
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

/// What a step queues on: reads, and writes unless it commits nothing. It
/// holds the runner's Accesses behind a pointer no step can name, so a
/// step has no way to run a round or commit. Two transitions that declare
/// the same rounds, commit, guards and begin share it, so one can step
/// through another.
pub fn Round(comptime T: type) type {
    return RoundOf(T.rounds, T.commit, GuardsOf(T), beginIndex(T));
}

fn RoundOf(comptime R: type, comptime commit: Commit, comptime Guards: type, comptime begin: ?u8) type {
    return struct {
        const Self = @This();
        core: *anyopaque,

        fn get(r: *Self) *Core(R, commit, Guards, begin) {
            return @ptrCast(@alignCast(r.core));
        }

        fn writes(comptime what: []const u8) void {
            if (commit == .none) @compileError("a transition that commits nothing " ++ what);
        }

        fn transacts(comptime what: []const u8) void {
            if (commit != .transaction) @compileError("only a transaction " ++ what);
        }

        /// `Access.read`: `destination` is defined once the round runs.
        pub fn read(r: *Self, comptime S: type, args: S.Args, destination: *S.Result) void {
            const core = r.get();
            if (core.inside()) core.writer.read(S, args, destination) else core.reader.read(S, args, destination);
        }

        /// `Access.readInto`.
        pub fn readInto(r: *Self, comptime S: type, args: S.Args, row: *S.Row, found: *store_access.Found) void {
            const core = r.get();
            if (core.inside()) core.writer.readInto(S, args, row, found) else core.reader.readInto(S, args, row, found);
        }

        /// `Access.readEach`: `visitor` must outlive the round, so it is a
        /// field of the transition value.
        pub fn readEach(r: *Self, comptime S: type, args: S.Args, limit: u64, visitor: anytype) void {
            const core = r.get();
            if (core.inside()) core.writer.readEach(S, args, limit, visitor) else core.reader.readEach(S, args, limit, visitor);
        }

        /// `Access.write`: it runs in the commit round, or, from `begin`
        /// on, in the round it is queued for.
        pub fn write(r: *Self, comptime S: type, args: S.Args) void {
            writes("queues no write: " ++ S.sql);
            r.get().writer.write(S, args);
        }

        /// Publication settlement whose identity does not bind a Session column.
        pub fn obligationsChanged(r: *Self, head: rsql.SessionHead) void {
            transacts("changes obligations");
            r.get().writer.obligationsChanged(head);
        }

        /// `Access.readRaw`, as the `.raw` round the step asks for next:
        /// `destination`, which must outlive that round, is defined once it
        /// runs. Nothing else may be queued for it. Its error is the
        /// round's, so this never fails.
        pub fn readRaw(r: *Self, content_id: u64, offset: u64, destination: []u8) error{}!void {
            const core = r.get();
            if (core.raw != null) @panic("a raw round reads one window");
            core.raw = .{ .content_id = content_id, .offset = offset, .destination = destination };
        }

        /// `Access.writeCount`, as `write`.
        pub fn writeCount(r: *Self, comptime S: type, args: S.Args, rows: u64) void {
            writes("queues no write: " ++ S.sql);
            r.get().writer.writeCount(S, args, rows);
        }

        /// `Access.positions`: the commit advances them.
        pub fn positions(r: *Self, head: rsql.SessionHead) error{TooManyPositionClaims}!*store_access.Positions {
            transacts("claims positions");
            return r.get().writer.positions(head);
        }

        /// `Access.identity`: the next value of `column` in this transaction.
        pub fn identity(r: *Self, comptime column: store_core.Identity) !u64 {
            transacts("takes identities");
            return r.get().writer.identity(column);
        }

        /// `Access.writeContent`.
        pub fn writeContent(r: *Self, content_id: u64, bytes: []const u8) void {
            transacts("writes content");
            r.get().writer.writeContent(content_id, bytes);
        }

        /// `Access.insertedContent`.
        pub fn insertedContent(r: *Self, digest: *const [32]u8, length: u64, private: bool) ?u64 {
            transacts("inserts content");
            return r.get().writer.insertedContent(digest, length, private);
        }

        /// `Access.recordInserted`.
        pub fn recordInserted(r: *Self, digest: *const [32]u8, length: u64, private: bool, content_id: u64) void {
            transacts("inserts content");
            r.get().writer.recordInserted(digest, length, private, content_id);
        }

        /// `Access.recordContentRow`.
        pub fn recordContentRow(r: *Self, content_id: u64) void {
            transacts("inserts content");
            r.get().writer.recordContentRow(content_id);
        }

        /// `Access.contentSink`: it steps what is queued in process where
        /// the engine needs the row first, and adds no round.
        pub fn contentSink(r: *Self, content_id: u64, length: u64) !store_access.ContentSink {
            transacts("streams content");
            return r.get().writer.contentSink(content_id, length);
        }

        /// The configure reads in the Store's scratch, which the Entry
        /// releases (`Store.configurationReads`): a lease for the run.
        pub fn configurationReads(r: *Self) @typeInfo(@TypeOf(Store.configurationReads)).@"fn".return_type.? {
            transacts("leases the configure reads");
            return r.get().writer.store.configurationReads();
        }

        /// `Access.attemptTimings`.
        pub fn attemptTimings(r: *Self, operation: u64) @import("../model_timing.zig").Values {
            writes("ends no Attempt");
            return r.get().writer.attemptTimings(operation);
        }

        /// The faults this run injects; a step checks its own.
        pub fn faults(r: *Self) Faults {
            return r.get().faults;
        }
    };
}

/// The index of `T.begin`, or null.
fn beginIndex(comptime T: type) ?u8 {
    const at: T.rounds.At = T.begin orelse return null;
    return @backingInt(at);
}

/// `T.Guards`, or none when it commits nothing.
fn GuardsOf(comptime T: type) type {
    return if (T.commit == .none) error{} else T.Guards;
}

/// `Core` for `T`.
fn CoreFor(comptime T: type) type {
    return Core(T.rounds, T.commit, GuardsOf(T), beginIndex(T));
}

/// The runner's state: a read Access for the rounds before `begin`, and
/// the writer `commit` names, which runs the rounds from `begin` on. A
/// transition whose transaction opens before its first round has no read
/// Access; one that commits nothing has no writer.
fn Core(comptime R: type, comptime commit: Commit, comptime Guards: type, comptime begin: ?u8) type {
    const reads_outside = (begin orelse 1) > 0;
    return struct {
        const Self = @This();
        reader: if (reads_outside) store_access.Access(.read, error{}) else void,
        writer: switch (commit) {
            .none => void,
            .transaction => store_access.Access(.write, Guards),
            .single => store_access.Access(.single, Guards),
        },
        faults: Faults,
        /// The round the step queues for comes after this one.
        last: ?R.At = null,
        /// The window a `.raw` round reads (`Round.readRaw`).
        raw: ?struct { content_id: u64, offset: u64, destination: []u8 } = null,

        /// Whether the step queues for a round from `begin` on. Every
        /// round before `begin` is `.always` (`check`), so the round after
        /// `last` is the next one declared.
        fn opened(core: *const Self) bool {
            const first = begin orelse return false;
            const next = if (core.last) |last| @backingInt(last) + 1 else 0;
            return next >= first;
        }

        /// `opened`, comptime-known where only one Access exists.
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

/// Runs `t` under `entry`'s lock: each round its steps ask for, then its
/// commit, answering `committed`, or `declined` when a `Declined` guard
/// stops the commit. On `.done` or an error it abandons what it queued;
/// on an error, after `failed` when `T` declares it. `t` lives in the caller's frame: a queued statement may read its bytes
/// in place until the pass that steps it.
pub noinline fn run(entry: *const store_core.Entry, comptime T: type, t: *T, faults: Faults) !T.Result {
    comptime check(T);
    const State = CoreFor(T);
    var core: State = .{
        .reader = if (@FieldType(State, "reader") == void) {} else .open(entry),
        .writer = if (T.commit == .none) {} else .open(entry),
        .faults = faults,
    };
    defer if (@FieldType(State, "reader") != void) core.reader.deinit();
    defer if (T.commit != .none) core.writer.deinit();
    const result = drive(T, t, &core);
    if (comptime @hasDecl(T, "failed")) if (result) |_| {} else |_| T.failed(t);
    if (T.commit != .none) return core.writer.end(faults, result) else return result;
}

fn drive(comptime T: type, t: *T, core: *CoreFor(T)) !T.Result {
    var round: Round(T) = .{ .core = core };
    while (true) switch (try T.step(t, &round, core.last)) {
        .round => |at| {
            if (builtin.is_test and !T.rounds.follows(core.last, at)) std.debug.panic(
                "{s} asked for round {s} after {s}: rounds run in declared order, and only a .paged one repeats",
                .{ @typeName(T), @tagName(at), if (core.last) |before| @tagName(before) else "none" },
            );
            const begin = comptime beginIndex(T);
            const inside = if (begin) |first| @backingInt(at) >= first else false;
            // Reads queued where the round runs them.
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
                // Before `begin`, writes ride the commit round.
                if (T.commit != .none) std.debug.assert(core.writer.queued == 0);
                core.reader.run() catch |err| return named(T, at, err, &core.reader);
            } else {
                core.writer.run() catch |err| return named(T, at, err, &core.writer);
            }
            core.last = at;
        },
        .commit => if (T.commit == .none) unreachable else {
            // Reads queued outside the transaction would never run.
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
        },
        .done => |result| {
            if (T.commit != .none) try core.writer.abandon(core.faults);
            return result;
        },
    };
}

/// A round's failure: a failed statement is the error the round names
/// for it in `access`, which ran the round, if it names one.
fn named(comptime T: type, at: T.rounds.At, err: anytype, access: anytype) (@TypeOf(err) || T.rounds.Error) {
    if (err == error.StatementFailed) if (T.rounds.failed(at, access)) |failed| return failed;
    return err;
}

/// `err` as one of `T.Declined`, or null.
fn declinedBy(comptime T: type, err: anyerror) ?T.Declined {
    const names = @typeInfo(T.Declined).error_set.error_names orelse return null;
    inline for (names) |name| if (err == @field(anyerror, name)) return @errorCast(err);
    return null;
}

/// Runs `T` from `input` as one entry point: enter, `run`, then finish the
/// transaction, returning `T.Ordinary` errors and fencing on the rest. A
/// control's `faults` carry its trace, which marks when the Entry holds
/// the Store and releases it. Its caller is the entry point's `Held` body,
/// which the round budget scan finds by this call.
pub fn apply(self: *Store, comptime T: type, input: T.Input, faults: Faults) !T.Result {
    const entry = try store_core.enter(self, .fromControl(faults.control_trace));
    defer entry.release();
    var t: T = .{ .input = input };
    defer if (comptime @hasDecl(T, "deinit")) t.deinit();
    return entry.finishTransaction(T.Ordinary, faults, run(&entry, T, &t, faults));
}
