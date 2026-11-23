//! App calls: Actions whose runner is the app (sketch).
//!
//! An app call is an ordinary Action (`action_operation`) with one extra row in `app_call`.
//! Classification, authorization, approval, settlement, fulfillment, backgrounding and
//! stop go through the existing shared route. This file owns only what differs:
//! who may run it (the claim), how long it may wait (the deadline), and what a cut-off means.
//!
//! The work lives in the app, so an app call holds no custody record and no Active
//! Capacity credit. Waiting or running, it costs 0 Host bytes: its row is its state.
//! Liveness of a claim is `line.Slots.isLive(claim_line)`.

const std = @import("std");
const tool_record = @import("../../tool_record.zig");
const line = @import("../../line.zig");
const session_id = @import("../../session_id.zig");

// ---------------------------------------------------------------------------------------
// Table (format N+1, see schema_steps.zig)
//
// app_call(
//   action_id    INTEGER PRIMARY KEY REFERENCES action_operation(action_id),
//   lane_ref     session ref NOT NULL,        -- the declaring Session; frozen at call time
//   ready_at     INTEGER NULL,                -- set when the Action becomes authorized
//   wait_until   INTEGER NULL,                -- ready_at + record.wait_ms; CHECK both or neither
//   claims       INTEGER NOT NULL DEFAULT 0,  -- claims started; 1 ≤ claims ≤ restart_limit
//   claim_line   INTEGER NULL,                -- line.Token of the live claim, or NULL
//   claimed_at   INTEGER NULL,                -- CHECK (claim_line IS NULL) = (claimed_at IS NULL)
//   change_seq   INTEGER NOT NULL             -- bumped on every transition below (index)
// )
// INDEX app_call_offered(lane_ref, claim_line, action_id) -- ClaimNext
// INDEX app_call_due(wait_until)                          -- the execution loop's one MIN query
//
// Replay policy, restart limit and wait limit are NOT columns here: they are fields of the
// frozen tool record (`tool_record.AppPolicy`), read through the call's frozen offer, so a
// re-declare never changes a call already made.
// ---------------------------------------------------------------------------------------

/// The Action's place in the app lifecycle, derived from its rows, never stored.
pub const Phase = enum {
    /// Unauthorized (ask mode, waiting for allow_once). Not offered; no deadline yet.
    awaiting_approval,
    /// Offered to the lane: claimable by any line serving it.
    offered,
    /// Claimed by a live line; the app runs it.
    claimed,
    /// Claimed by a dead line: owed a cut-off decision (sweep or start-up recovery).
    cut_off,
    /// Resolution written. Terminal.
    resolved,
};

pub const Facts = struct {
    authorized: bool,
    resolved: bool,
    claim_line: ?line.Token,
    claim_live: bool,
};

/// Pure. The single definition; `phaseSql` is its SQL twin, tested over the whole domain
/// (the existing tool_offer.stale_sql pattern).
pub fn phase(facts: Facts) Phase {
    _ = facts;
    @panic("not implemented");
}
pub const phase_sql = "-- TODO: CASE over the same four facts";

/// What a cut-off claim becomes. Pure; listed in src/logic_tests.zig.
pub const CutOff = enum {
    /// Unsafe, or the deadline already passed while claimed: "may have run; not repeated".
    indeterminate,
    /// Safe and under the limit: clear the claim, keep `claims`, offer it again.
    reoffer,
    /// Safe and at the limit: error result with diagnostic `restart_limit`.
    restart_limit,
};

pub fn cutOff(policy: tool_record.AppPolicy, claims: u32, now_ms: u64, wait_until: u64) CutOff {
    // TODO: if now_ms >= wait_until → .indeterminate (it was claimed, so it may have run).
    // if policy.replay == .unsafe → .indeterminate.
    // if claims >= policy.restart_limit → .restart_limit.  (pi: "cut off restartLimit times")
    // else → .reoffer.
    _ = policy;
    _ = claims;
    _ = now_ms;
    _ = wait_until;
    @panic("not implemented");
}

/// What a passed deadline becomes. Pure.
pub const Expiry = enum {
    /// Never claimed: it certainly never ran. Settles `failed` naming the wait limit.
    failed_unclaimed,
    /// Claimed and unanswered: it may have run. Settles `indeterminate`.
    indeterminate,
};

pub fn expiry(claimed_ever: bool) Expiry {
    _ = claimed_ever;
    @panic("not implemented");
}

// ---------------------------------------------------------------------------------------
// Transitions. Each is one Store transaction, idempotent by its guard, entered through
// Store.enter / Access.finish with declared ordinary outcomes. Each touches the lane's
// Session in the change ring with facet `.app_calls`, so serving lines get `calls`.
// ---------------------------------------------------------------------------------------

/// Called from the one function that authorizes an Action (writeCalls in bypass, or
/// DecidePermission allow_once). Writes `ready_at` and `wait_until`.
/// Guard: `ready_at IS NULL`.
pub const Ready = struct {
    pub fn run(a: anytype, action_id: u64, now_ms: u64, policy: tool_record.AppPolicy) !void {
        _ = a;
        _ = action_id;
        _ = now_ms;
        _ = policy;
        @panic("not implemented");
    }
};

/// What a serving app can run: a name and the record digest it implements.
pub const Served = struct { name: []const u8, digest: [32]u8 };

pub const Claimed = struct {
    action_id: u64,
    session: session_id.Id,
    /// = claims after this claim. The app's result must carry it.
    attempt: u32,
    name: []const u8,
    /// Content reference to the call's arguments JSON, read in the same reply.
    arguments_content_id: u64,
    wait_until: u64,
};

/// `POST /v1/app-call-claim`, worker 0. Pops the oldest offered call in `lane` whose
/// frozen record digest is in `served`, and claims it in the same transaction:
/// `claim_line = token, claims += 1, claimed_at = now`, and on the first claim
/// `attempt_ordinal = 1, attempt_at = now` on the Action (the existing Attempt facts).
/// Guard: phase = offered. Keyed like every mutation, so a lost reply replays.
/// Precondition the shell checks first: `slots.isLive(token)`. A line that dies after the
/// check is caught by the sweep, which runs after this commit (facet .app_calls).
pub const ClaimNext = struct {
    pub const Answer = union(enum) { claimed: Claimed, none, line_closed };

    pub fn run(a: anytype, lane: session_id.Id, token: line.Token, served: []const Served, now_ms: u64) !Answer {
        _ = a;
        _ = lane;
        _ = token;
        _ = served;
        _ = now_ms;
        @panic("not implemented");
    }
};

/// The app's answer, parsed at the boundary.
pub const Result = struct {
    action_id: u64,
    attempt: u32,
    line: line.Token,
    /// Content parts (text, image) captured like Message parts; `is_error` maps to `failed`.
    content_id: u64,
    is_error: bool,
};

/// `POST /v1/app-call-result`, worker 0. Settles through the shared route:
/// tool_settle.deliver(.app, ...) → action.SettleAttempt (unchanged), which substitutes a
/// cancelled Resolution if the Action was stopped, writes Final.admit for a background
/// Action, queues the Turn continuation and decides retention.
/// Guard (the at-most-once rule for app calls): resolution NULL ∧ claim_line = result.line
/// ∧ claims = result.attempt. Anything else is `ignored`, with no effect.
pub const Answer = union(enum) {
    accepted,
    ignored: Ignored,
    pub const Ignored = enum { settled, stale_attempt, not_claimant };
};

/// Execution loop. Runs after a line-close hint and after any commit with facet
/// .app_calls. Reads claimed, unresolved calls whose token is not live (bounded page),
/// applies `cutOff` to each: reoffer clears the claim; the other two settle through
/// tool_settle with Runner.app's indeterminate text or the restart_limit error.
pub const Sweep = struct {
    pub fn run(a: anytype, slots: *const line.Slots, now_ms: u64) !void {
        _ = a;
        _ = slots;
        _ = now_ms;
        @panic("not implemented");
    }
};

/// Host start, before any line opens: every stored claim is dead. Same decisions as Sweep.
pub const Recover = Sweep;

/// Execution loop timer: the earliest of `wait_until` and the background due time
/// (`ready_at + host_settings.background_after_ms`) over unresolved app calls.
/// One indexed MIN query, run only after commits with facet .app_calls and when the
/// previous deadline fires. An idle Host with no app calls sends no query.
pub const NextDeadline = struct {
    pub fn read(a: anytype) !?u64 {
        _ = a;
        @panic("not implemented");
    }
};

/// Fired deadlines: `expiry` for passed `wait_until`, and background promotion through
/// the shared action_control promotion (the same receipt, the same source_kind 3 final).
pub const Due = struct {
    pub fn run(a: anytype, now_ms: u64) !void {
        _ = a;
        _ = now_ms;
        @panic("not implemented");
    }
};

/// Stop of an app call (Session stop, per-Action stop, auto-deny never applies: it is
/// authorized). The shared stop writes the cancelled Resolution at once, since the Host
/// cannot stop the app's work, and this posts `cancel` to the claimant line through
/// line.PostRing. A missed post is harmless: the late result is answered `ignored`.
pub fn cancelPost(action_id: u64, attempt: u32, token: line.Token) line.Post {
    return .{ .kind = .cancel, .line = token, .action = action_id, .attempt = attempt };
}
