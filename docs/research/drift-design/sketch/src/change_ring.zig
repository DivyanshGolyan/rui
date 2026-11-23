//! Changes to src/change_ring.zig (sketch).
//!
//! Each entry gains a facet, so a line can tell "this Session's feed changed" from
//! "this lane's app calls changed". A commit that changes an app call touches the call's
//! lane Session with facet `.app_calls` (and the call's own Session with `.feed`, as now).
//! Cost: one byte per entry, 4,096 bytes for the ring. No new structure, no new wake.

const session_id = @import("session_id.zig");

pub const capacity = 4096;
pub const Id = session_id.Id;

pub const Facet = enum(u8) { feed, app_calls };

pub const Entry = struct { session: Id, workspace: u64, facet: Facet = .feed };

/// What a line walk reads: entries newer than a line's `seen_generation`.
pub const FacetEntry = struct { generation: u64, session: Id, facet: Facet };

pub const Ring = struct {
    generations: [capacity]u64 = @splat(0),
    sessions: [capacity]Id = undefined,
    workspaces: [capacity]u64 = undefined,
    facets: [capacity]Facet = undefined,
    next: usize = 0,
    len: usize = 0,
    forgotten_through: u64 = 0,

    /// For the line pool: every entry in (since, through], newest first, into `out`.
    /// Returns null when the ring no longer covers `since` (the caller owes `resync`).
    pub fn since(self: *const Ring, after: u64, through: u64, out: []FacetEntry) ?[]FacetEntry {
        _ = self;
        _ = after;
        _ = through;
        _ = out;
        @panic("not implemented");
    }
};
