//! Wire additions (sketch). The real shapes live in src/protocol.zig and render to
//! openapi.json, from which clients/ts/src/wire.ts is generated. Each unit bumps
//! src/wire_version.zig and the TS WIRE_VERSION literal together.
//!
//! None of these types reach store/: the route handlers parse into domain values
//! (app_call.Served, app_call.Result, transcript.Item, context_head.ResetRequest).

pub const wire_version_after = .{
    .{ "U3 line", "25" },
    .{ "U5 reset", "26" },
    .{ "U6 appTools in configure", "27" },
    .{ "U7 claim and result routes, serve/calls frames", "28" },
    .{ "U9 tool_result resolution code, failed-compaction row", "29" },
    .{ "U10 import routes, transcript/1", "30" },
};

/// GET /v1/line, Upgrade: rui-line/1. Classified after the request line like any route;
/// headers validated (wire version, Host instance, Store) before the 101. Not a worker job.
pub const LineRoute = struct {};

/// Configure gains `appTools` (U6): the full declared set; omitted keeps it, [] clears it.
pub const AppToolSpec = struct {
    name: []const u8, // tool_name rules: ≤ 64 bytes [A-Za-z0-9_-]
    description: []const u8,
    input_schema: []const u8, // JSON Schema object, validated like MCP input schemas
    replay: enum { safe, unsafe } = .unsafe,
    restart_limit: u8 = 5,
    wait_ms: u32,
};

/// POST /v1/app-call-claim (ordinary route, worker 0). Keyed.
pub const AppCallClaimRequest = struct {
    key: []const u8,
    lane: [6]u8,
    line: []const u8, // decimal line token from `hello`
    tools: []const struct { name: []const u8, digest: [64]u8 },
};
/// answer: accepted { call: null | { action, session, attempt, name, arguments, wait_until } }
///         rejected { code: line_closed }
pub const AppCallClaimReply = struct {};

/// POST /v1/app-call-result (ordinary route, worker 0). Keyed. Content as Message parts.
pub const AppCallResultRequest = struct {
    key: []const u8,
    action: []const u8,
    attempt: u32,
    line: []const u8,
    is_error: bool,
    // parts: the Message `parts` grammar and limits
};
/// answer: accepted | ignored { reason: settled | stale_attempt | not_claimant }
pub const AppCallResultReply = struct {};

/// POST /v1/reset (ordinary route). Keyed. See context_head.ResetRequest.
pub const ResetRequest = struct {};

/// POST /v1/import-begin, /v1/import-append, /v1/import-seal (ordinary routes). Keyed by
/// source id and ordinal. Append's body is `transcript/1` NDJSON, captured in charged scratch.
pub const ImportRoutes = struct {};

/// Store failure: every in-flight mutation and read already answers
/// `canonical_store_failure`; `host-info` answers `dispatch_fenced`; lines get
/// `failed {code: "store_failed"}`. inspection.md names `store_failed` as the one signal
/// a client reports to its callers. No new code on the request routes.
pub const StoreFailure = struct {};
