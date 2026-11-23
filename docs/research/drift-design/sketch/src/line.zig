//! The line: one held, notification-only connection per client (sketch).
//!
//! Owner: the intake thread (`src/server.zig` `Intake`). No new Host thread.
//! A line carries nudges for saved facts and payload only for facts that are never saved.
//! It never carries a durable mutation: claim and result stay ordinary keyed exchanges.
//!
//! Resident cost: `Line` is about 27 KiB and lives in a fixed pool of `capacity` lines,
//! outside `intake_capacity`, so lines never starve ordinary exchanges.
//! Nothing here grows with Sessions, history or waiting tool calls.

const std = @import("std");
const change_ring = @import("change_ring.zig");
const session_id = @import("session_id.zig");

pub const capacity = 64;
pub const max_watched = 256;
pub const max_lanes = 16;
pub const max_frame_bytes = 16 * 1024;
pub const out_bytes = 8 * 1024;
pub const ping_interval_ms = 20_000;

/// Unique for the Host's life: slot index in the low byte, a slot generation above it.
/// Claims store it; after a restart every stored token is dead, which recovery relies on.
pub const Token = packed struct(u64) { slot: u8, generation: u56 };

/// Which line tokens are live. Intake writes, workers (claim) and execution (sweep) read.
/// 64 × 8 bytes. A token absent here is a cut-off claim, whatever the Store says.
pub const Slots = struct {
    live: [capacity]std.atomic.Value(u64) = @splat(.init(0)),

    pub fn isLive(self: *const Slots, token: Token) bool {
        _ = self;
        _ = token;
        @panic("not implemented");
    }
};

/// Transient posts from the execution thread to intake: a cancel to a claimant line.
/// Fixed ring; when full the post is dropped. The durable stop stays the authority:
/// a runner that misses the cancel learns it when its result is answered `ignored`.
pub const Post = struct {
    pub const Kind = enum(u8) { cancel };
    kind: Kind,
    line: Token,
    action: u64,
    attempt: u32,
};
pub const PostRing = struct {
    entries: [256]Post = undefined,
    head: std.atomic.Value(u32) = .init(0),
    tail: std.atomic.Value(u32) = .init(0),

    /// Execution side. Returns false when full (the post is dropped).
    pub fn push(self: *PostRing, post: Post) bool {
        _ = self;
        _ = post;
        @panic("not implemented");
    }
    /// Intake side, after its wake pipe fires.
    pub fn drain(self: *PostRing, sink: anytype) void {
        _ = self;
        _ = sink;
        @panic("not implemented");
    }
};

/// Frames from the app. Parsed at the boundary into these; nothing else sees JSON.
pub const InFrame = union(enum) {
    /// Replace the watched set. `all` costs no per-Session state.
    watch: Watch,
    /// Replace the served lanes (lane = the declaring Session of an app tool set).
    serve: []const session_id.Id,
    /// Live tool progress from the runner; fanned out to every line watching `session`.
    progress: struct { session: session_id.Id, action: u64, attempt: u32, text: []const u8 },

    pub const Watch = union(enum) { all, sessions: []const session_id.Id };
};

/// Frames to the app. `changed` and `calls` are nudges: the app reads saved facts next.
pub const OutFrame = union(enum) {
    hello: struct { line: Token, instance: [32]u8 },
    changed: session_id.Id,
    calls: session_id.Id,
    /// The change ring wrapped past this line's last generation: re-read everything watched.
    resync,
    progress: struct { session: session_id.Id, action: u64, attempt: u32, text: []const u8 },
    cancel: struct { action: u64, attempt: u32 },
    failed: Failure,
    ping,

    pub const Failure = enum { store_failed, host_stopping };
};

/// The line's whole state. Its pending output is a dirty set, never a queue,
/// so a slow app cannot make the Host buffer saved facts.
pub const Line = struct {
    token: Token,
    fd: std.posix.fd_t,
    watch_all: bool = false,
    watched: [max_watched]session_id.Id = undefined,
    watched_len: u16 = 0,
    /// One bit per `watched` entry: changed since the last `changed` frame.
    dirty: std.StaticBitSet(max_watched) = .initEmpty(),
    /// Under `watch_all`, changed Sessions wait here; overflow becomes `resync`.
    dirty_any: [32]session_id.Id = undefined,
    dirty_any_len: u8 = 0,
    lanes: [max_lanes]session_id.Id = undefined,
    lanes_len: u8 = 0,
    lanes_dirty: std.StaticBitSet(max_lanes) = .initEmpty(),
    resync_owed: bool = false,
    /// Ring generation through which this line's dirty bits are current.
    seen_generation: u64,
    /// Transient frames only (progress, cancel, failed). Progress is dropped when full.
    out: [out_bytes]u8 = undefined,
    out_len: u16 = 0,
    in: [max_frame_bytes + 4]u8 = undefined,
    in_len: u16 = 0,
    last_write_ms: u64,

    /// Pure: what one ring walk means for this line. `touched` is every ring entry
    /// newer than `seen_generation`; `covered` is `ring.covers(seen_generation)`.
    pub fn absorb(self: *Line, touched: []const change_ring.FacetEntry, covered: bool, through: u64) void {
        // TODO: !covered → resync_owed = true.
        // .feed entries set `dirty` for watched Sessions (or `dirty_any` under watch_all);
        // .app_calls entries set `lanes_dirty` for served lanes.
        _ = self;
        _ = touched;
        _ = covered;
        _ = through;
        @panic("not implemented");
    }

    /// Pure: the next frame to write, draining dirty state first, then transient bytes.
    /// Returns null when nothing is owed.
    pub fn next(self: *Line, now_ms: u64) ?OutFrame {
        _ = self;
        _ = now_ms;
        @panic("not implemented");
    }

    /// Pure: apply one parsed app frame. Progress returns the fan-out request for intake.
    pub fn apply(self: *Line, frame: InFrame) ?InFrame {
        _ = self;
        _ = frame;
        @panic("not implemented");
    }
};

/// Intake's line pool. The shell: sockets, wake pipe, LineSlots, the 101 reply.
pub const Pool = struct {
    lines: [capacity]?*Line = @splat(null),
    slots: *Slots,
    posts: *PostRing,

    /// Upgrade an exchange whose route is `line` after its headers validated
    /// (wire version, Host instance, Store). Answers 101 and writes `hello`.
    pub fn open(self: *Pool, fd: std.posix.fd_t, generation: u64) error{LinesFull}!*Line {
        _ = self;
        _ = fd;
        _ = generation;
        @panic("not implemented");
    }

    /// Clears the token from LineSlots, then publishes the execution hint so the
    /// app-call sweep cuts off this line's claims. Idempotent.
    pub fn close(self: *Pool, line: *Line) void {
        _ = self;
        _ = line;
        @panic("not implemented");
    }

    /// Called on every intake wake: walk the ring once for all lines, drain posts.
    pub fn onWake(self: *Pool, ring: *const change_ring.Ring, generation: u64) void {
        _ = self;
        _ = ring;
        _ = generation;
        @panic("not implemented");
    }

    /// Fence or drain: write `failed` to every line, then close each.
    pub fn failAll(self: *Pool, why: OutFrame.Failure) void {
        _ = self;
        _ = why;
        @panic("not implemented");
    }
};

/// The Store's commit wake gains a second fixed subscriber (sketch of the change in
/// `src/store/Store.zig:456`): an array of two slots, execution and intake. Intake's
/// waker writes one byte to `intake_wake` only while `Pool` has a line and the pipe is
/// not already armed.
pub const CommitWakers = struct {
    execution: std.atomic.Value(?*std.Io.Event) = .init(null),
    intake: std.atomic.Value(?*IntakeWaker) = .init(null),

    pub const IntakeWaker = struct {
        armed: std.atomic.Value(bool) = .init(false),
        lines_open: std.atomic.Value(u8) = .init(0),
        pipe: std.posix.fd_t,
    };

    pub fn set(self: *CommitWakers) void {
        _ = self;
        @panic("not implemented");
    }
};
