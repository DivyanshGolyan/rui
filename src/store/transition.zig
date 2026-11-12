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
//!   the rounds run. A failed statement in a round is that round's error.
//! - `round_budget`: its `.always` rounds plus its commit, checked here.
//! - `writes`: whether it commits. One that does not cannot ask to.
//! - `Input`, `Result`, `Ordinary` (the errors `apply` returns without
//!   fencing) and `Declined` (the guard errors whose commit answers
//!   `declined(t, err)` instead of failing).
//! - `committed(t)`, the result once its commit stands.
//!
//! For now a round runs reads only and every write rides the commit round,
//! the shape the retry admission has; the transaction opens with the first
//! write, position or identity, as an `Access` opens it. The rounds run
//! through `Access` until its queue core moves here.

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
};

/// The rounds `spec` declares, in order: its tag enum `At`, each tag's
/// `Kind` and the error a failed statement in that round answers.
pub fn rounds(comptime spec: anytype) type {
    const names = @typeInfo(@TypeOf(spec)).@"struct".field_names;
    var values: [names.len]u8 = undefined;
    var always_count = 0;
    var Named: type = error{};
    for (&values, names, 0..) |*value, name, i| {
        value.* = i;
        const declared: Kind = @field(spec, name)[0];
        always_count += @intFromBool(declared == .always);
        Named = Named || @TypeOf(@field(spec, name)[1]);
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

        /// The error a failed statement in `at` answers.
        pub fn failed(at: At) Error {
            return switch (at) {
                inline else => |tag| @field(spec, @tagName(tag))[1],
            };
        }

        /// Whether `next` may run after `last`: rounds run in declared
        /// order, and only a `.paged` round runs again.
        pub fn follows(last: ?At, next: At) bool {
            const before = last orelse return true;
            if (next == before) return kind(next) == .paged;
            return @backingInt(next) > @backingInt(before);
        }
    };
}

/// What a step asks for: a declared round, the commit, or its result.
/// A transition that declares no writes cannot ask to commit.
pub fn Next(comptime T: type) type {
    return union(enum) {
        round: T.rounds.At,
        commit: if (T.writes) void else noreturn,
        done: T.Result,
    };
}

/// What a step queues on: reads, and writes once `T.writes`. It holds the
/// runner's Accesses behind a pointer no step can name, so a step has no
/// way to run a round or commit.
pub fn Round(comptime T: type) type {
    return struct {
        const Self = @This();
        core: *anyopaque,

        fn get(r: *Self) *Core(T) {
            return @ptrCast(@alignCast(r.core));
        }

        /// `Access.read`: `destination` is defined once the round runs.
        pub fn read(r: *Self, comptime S: type, args: S.Args, destination: *S.Result) void {
            r.get().reader.read(S, args, destination);
        }

        /// `Access.readInto`.
        pub fn readInto(r: *Self, comptime S: type, args: S.Args, row: *S.Row, found: *store_access.Found) void {
            r.get().reader.readInto(S, args, row, found);
        }

        /// `Access.readEach`: `visitor` must outlive the round, so it is a
        /// field of the transition value.
        pub fn readEach(r: *Self, comptime S: type, args: S.Args, limit: u64, visitor: anytype) void {
            r.get().reader.readEach(S, args, limit, visitor);
        }

        /// `Access.write`: it runs in the commit round.
        pub fn write(r: *Self, comptime S: type, args: S.Args) void {
            if (!T.writes) @compileError("a transition that declares no writes queues none: " ++ S.sql);
            r.get().writer.write(S, args);
        }

        /// `Access.writeCount`: it runs in the commit round.
        pub fn writeCount(r: *Self, comptime S: type, args: S.Args, rows: u64) void {
            if (!T.writes) @compileError("a transition that declares no writes queues none: " ++ S.sql);
            r.get().writer.writeCount(S, args, rows);
        }

        /// `Access.positions`: the commit advances them.
        pub fn positions(r: *Self, head: rsql.SessionHead) error{TooManyPositionClaims}!*store_access.Positions {
            if (!T.writes) @compileError("a transition that declares no writes claims no positions");
            return r.get().writer.positions(head);
        }

        /// `Access.identity`: the next value of `column` in this transaction.
        pub fn identity(r: *Self, comptime column: store_core.Identity) !u64 {
            if (!T.writes) @compileError("a transition that declares no writes takes no identities");
            return r.get().writer.identity(column);
        }

        /// The faults this run injects; a step checks its own.
        pub fn faults(r: *Self) Faults {
            return r.get().faults;
        }
    };
}

/// The runner's state: a read Access for the rounds and, when `T.writes`,
/// a write Access for the commit, as the retry admission held them before.
fn Core(comptime T: type) type {
    return struct {
        reader: store_access.Access(.read, error{}),
        writer: if (T.writes) store_access.Access(.write, T.Declined) else void,
        faults: Faults,
    };
}

fn check(comptime T: type) void {
    const commits: comptime_int = @intFromBool(T.writes);
    if (T.round_budget != T.rounds.always + commits) @compileError(std.fmt.comptimePrint(
        "{s}.round_budget is {d}, but it declares {d} .always rounds and {d} commit",
        .{ @typeName(T), T.round_budget, T.rounds.always, commits },
    ));
    if (@sizeOf(T) > 1024) @compileError(std.fmt.comptimePrint(
        "{s} is {d} bytes; a transition value holds at most 1 KiB",
        .{ @typeName(T), @sizeOf(T) },
    ));
}

/// Runs `t` under `entry`'s lock: each round its steps ask for, then its
/// commit, answering `committed`, or `declined` when a `Declined` guard
/// stops the commit. On `.done` or an error it abandons what it queued.
/// `t` lives in the caller's frame: a queued statement may read its bytes
/// in place until the pass that steps it.
pub noinline fn run(entry: *const store_core.Entry, comptime T: type, t: *T, faults: Faults) !T.Result {
    comptime check(T);
    var core: Core(T) = .{ .reader = .open(entry), .writer = if (T.writes) .open(entry) else {}, .faults = faults };
    defer core.reader.deinit();
    defer if (T.writes) core.writer.deinit();
    if (T.writes) return core.writer.end(faults, drive(T, t, &core)) else return drive(T, t, &core);
}

fn drive(comptime T: type, t: *T, core: *Core(T)) !T.Result {
    var round: Round(T) = .{ .core = core };
    var last: ?T.rounds.At = null;
    while (true) switch (try T.step(t, &round, last)) {
        .round => |at| {
            if (builtin.is_test and !T.rounds.follows(last, at)) std.debug.panic(
                "{s} asked for round {s} after {s}: rounds run in declared order, and only a .paged one repeats",
                .{ @typeName(T), @tagName(at), if (last) |before| @tagName(before) else "none" },
            );
            // Writes ride the commit round in this runner.
            if (T.writes) std.debug.assert(core.writer.queued == 0);
            core.reader.run() catch |err| return if (err == error.StatementFailed) T.rounds.failed(at) else err;
            last = at;
        },
        .commit => if (!T.writes) unreachable else {
            core.writer.commit() catch |err| {
                const declined = declinedBy(T, err) orelse return err;
                try core.writer.abandon(core.faults);
                return T.declined(t, declined);
            };
            return T.committed(t);
        },
        .done => |result| {
            if (T.writes) try core.writer.abandon(core.faults);
            return result;
        },
    };
}

/// `err` as one of `T.Declined`, or null.
fn declinedBy(comptime T: type, err: anyerror) ?T.Declined {
    const names = @typeInfo(T.Declined).error_set.error_names orelse return null;
    inline for (names) |name| if (err == @field(anyerror, name)) return @errorCast(err);
    return null;
}

/// Runs `T` from `input` as one entry point: enter, `run`, then finish the
/// transaction, returning `T.Ordinary` errors and fencing on the rest. Its
/// caller is the entry point's `Held` body, which the round budget scan
/// finds by this call.
pub fn apply(self: *Store, comptime T: type, input: T.Input, faults: Faults) !T.Result {
    const entry = try store_core.enter(self, .none);
    defer entry.release();
    var t: T = .{ .input = input };
    return entry.finishTransaction(T.Ordinary, faults, run(&entry, T, &t, faults));
}
