//! Binding-keyed replay: the one owner of "may this stored output item go into this
//! request, and in which form". It replaces `output_item.Kind.replayableTo`.
//!
//! A functional core: values in, a `Replay` out. The shell reads each Binding from the
//! Store (a revision's connection, codec and model) and passes it in; this file names no
//! SQL, no codec module and no provider.
//!
//! The Store keeps each output item as neutral form plus a provider bag. A bag may be
//! read only on the Wire that wrote it, and opaque continuation (encrypted reasoning,
//! provider compaction) only on the same Binding, because it is bound to the account
//! and model that produced it. Nothing here converts an item: a request is rebuilt from
//! the Store, and an item from another Wire replays from its neutral fields alone.

const std = @import("std");
const bounded = @import("bounded.zig");
const codec_abi = @import("codec_abi.zig");
const output_item = @import("output_item.zig");
const protocol = @import("protocol.zig");

/// Which wire grammar wrote a bag (codec_abi.Dialect; codecs.dialect derives it from a codec).
pub const Dialect = codec_abi.Dialect;

/// Connection name as the Store's `provider` column holds it (1-16 lowercase, #1862).
pub const ConnectionName = bounded.Bounded(16);
pub const ModelName = bounded.Bounded(protocol.max_model_bytes);

/// Where a bag may be read: the same connection (account-bound ids) and the same dialect
/// (wire grammar).
pub const Wire = struct {
    connection: ConnectionName,
    dialect: Dialect,

    pub fn eql(self: *const Wire, other: *const Wire) bool {
        return self.dialect == other.dialect and self.connection.eql(other.connection.slice());
    }
};

/// Where opaque continuation may be read: the same Wire and the same requested model.
pub const Binding = struct {
    wire: Wire,
    model: ModelName,

    pub fn eql(self: *const Binding, other: *const Binding) bool {
        return self.wire.eql(&other.wire) and self.model.eql(other.model.slice());
    }
};

pub const Use = output_item.Use; // .history | .selected_base
pub const Kind = output_item.Kind;

/// How one stored item enters a request.
pub const Replay = enum {
    /// Not sent at all.
    omit,
    /// Neutral fields only: kind, phase, text parts, call name, call id and arguments. The
    /// bags are withheld, empty text parts are skipped and `arguments_object` is supplied
    /// (adapter-owned neutral rules). The codec MUST produce a valid item from these alone.
    neutral,
    /// Neutral fields plus every bag: parses equal to what the provider sent (cache parity).
    exact,
};

/// The whole rule, pure, over the producing Binding and the requesting Binding:
///
///   kind                        same Binding   same Wire, other model   other Wire
///   message / function_call     exact          exact (D192)             neutral
///   reasoning                   exact          omit (D192)              omit
///   compaction, selected_base   exact          omit (D192)              omit
///   compaction, history         omit           omit                     omit
///   web_search_call             exact          exact                    omit
pub fn decide(kind: Kind, producer: *const Binding, request: *const Binding, use: Use) Replay {
    const same_wire = producer.wire.eql(&request.wire);
    const same_binding = same_wire and producer.model.eql(request.model.slice());
    return switch (kind) {
        .reasoning => if (same_binding) .exact else .omit,
        .compaction => if (use == .selected_base and same_binding) .exact else .omit,
        .message, .function_call => if (same_wire) .exact else .neutral,
        .web_search_call => if (same_wire) .exact else .omit,
    };
}

test "decide over kind x producing relation x use" {
    // Expected outcomes are the table in the doc comment above, written cell by cell
    // rather than derived from `decide`. The four relations of the request's Binding to
    // the producing one: the same binding, the same wire with another model, another
    // connection on the same dialect, and the same connection on another dialect.
    const producer = binding("marlin", .openai_responses, "model-a");
    const relations = [_]struct { name: []const u8, request: Binding }{
        .{ .name = "same binding", .request = binding("marlin", .openai_responses, "model-a") },
        .{ .name = "same wire, other model", .request = binding("marlin", .openai_responses, "model-b") },
        .{ .name = "other connection", .request = binding("chatgpt", .openai_responses, "model-a") },
        .{ .name = "other dialect", .request = binding("marlin", .anthropic_messages, "model-a") },
    };
    const Expect = struct { kind: Kind, use: Use, relation: usize, replay: Replay };
    const expected = [_]Expect{
        // message and function_call: exact on the same wire (D192), neutral across wires.
        .{ .kind = .message, .use = .history, .relation = 0, .replay = .exact },
        .{ .kind = .message, .use = .history, .relation = 1, .replay = .exact },
        .{ .kind = .message, .use = .history, .relation = 2, .replay = .neutral },
        .{ .kind = .message, .use = .history, .relation = 3, .replay = .neutral },
        .{ .kind = .message, .use = .selected_base, .relation = 0, .replay = .exact },
        .{ .kind = .message, .use = .selected_base, .relation = 1, .replay = .exact },
        .{ .kind = .message, .use = .selected_base, .relation = 2, .replay = .neutral },
        .{ .kind = .message, .use = .selected_base, .relation = 3, .replay = .neutral },
        .{ .kind = .function_call, .use = .history, .relation = 0, .replay = .exact },
        .{ .kind = .function_call, .use = .history, .relation = 1, .replay = .exact },
        .{ .kind = .function_call, .use = .history, .relation = 2, .replay = .neutral },
        .{ .kind = .function_call, .use = .history, .relation = 3, .replay = .neutral },
        .{ .kind = .function_call, .use = .selected_base, .relation = 0, .replay = .exact },
        .{ .kind = .function_call, .use = .selected_base, .relation = 1, .replay = .exact },
        .{ .kind = .function_call, .use = .selected_base, .relation = 2, .replay = .neutral },
        .{ .kind = .function_call, .use = .selected_base, .relation = 3, .replay = .neutral },
        // web_search_call: a hosted call has no neutral meaning in another wire.
        .{ .kind = .web_search_call, .use = .history, .relation = 0, .replay = .exact },
        .{ .kind = .web_search_call, .use = .history, .relation = 1, .replay = .exact },
        .{ .kind = .web_search_call, .use = .history, .relation = 2, .replay = .omit },
        .{ .kind = .web_search_call, .use = .history, .relation = 3, .replay = .omit },
        .{ .kind = .web_search_call, .use = .selected_base, .relation = 0, .replay = .exact },
        .{ .kind = .web_search_call, .use = .selected_base, .relation = 1, .replay = .exact },
        .{ .kind = .web_search_call, .use = .selected_base, .relation = 2, .replay = .omit },
        .{ .kind = .web_search_call, .use = .selected_base, .relation = 3, .replay = .omit },
        // reasoning: opaque, exact only on the same binding.
        .{ .kind = .reasoning, .use = .history, .relation = 0, .replay = .exact },
        .{ .kind = .reasoning, .use = .history, .relation = 1, .replay = .omit },
        .{ .kind = .reasoning, .use = .history, .relation = 2, .replay = .omit },
        .{ .kind = .reasoning, .use = .history, .relation = 3, .replay = .omit },
        .{ .kind = .reasoning, .use = .selected_base, .relation = 0, .replay = .exact },
        .{ .kind = .reasoning, .use = .selected_base, .relation = 1, .replay = .omit },
        .{ .kind = .reasoning, .use = .selected_base, .relation = 2, .replay = .omit },
        .{ .kind = .reasoning, .use = .selected_base, .relation = 3, .replay = .omit },
        // compaction: a selected base is opaque and exact only on the same binding; compaction
        // in history is never replayed.
        .{ .kind = .compaction, .use = .history, .relation = 0, .replay = .omit },
        .{ .kind = .compaction, .use = .history, .relation = 1, .replay = .omit },
        .{ .kind = .compaction, .use = .history, .relation = 2, .replay = .omit },
        .{ .kind = .compaction, .use = .history, .relation = 3, .replay = .omit },
        .{ .kind = .compaction, .use = .selected_base, .relation = 0, .replay = .exact },
        .{ .kind = .compaction, .use = .selected_base, .relation = 1, .replay = .omit },
        .{ .kind = .compaction, .use = .selected_base, .relation = 2, .replay = .omit },
        .{ .kind = .compaction, .use = .selected_base, .relation = 3, .replay = .omit },
    };
    // Every (kind, use, relation) cell is named exactly once.
    try std.testing.expectEqual(std.meta.tags(Kind).len * 2 * relations.len, expected.len);
    for (expected) |cell| {
        const request = relations[cell.relation].request;
        errdefer std.debug.print("{s} {s} {s}\n", .{ @tagName(cell.kind), @tagName(cell.use), relations[cell.relation].name });
        try std.testing.expectEqual(cell.replay, decide(cell.kind, &producer, &request, cell.use));
    }
    // Invariants over the whole domain, independent of the table.
    inline for (std.meta.tags(Kind)) |kind| for (std.meta.tags(Use)) |use| for (relations) |relation| {
        const replay = decide(kind, &producer, &relation.request, use);
        // (1) a bag never crosses a Wire.
        if (replay == .exact) try std.testing.expect(producer.wire.eql(&relation.request.wire));
        // (2) opaque kinds are never neutral.
        if (kind == .reasoning or kind == .compaction) try std.testing.expect(replay != .neutral);
    };
}

test "a Binding is equal only on the whole of its wire and model" {
    const base = binding("marlin", .openai_responses, "model-a");
    try std.testing.expect(base.eql(&binding("marlin", .openai_responses, "model-a")));
    try std.testing.expect(!base.eql(&binding("marlin", .openai_responses, "model-b")));
    try std.testing.expect(!base.eql(&binding("chatgpt", .openai_responses, "model-a")));
    try std.testing.expect(!base.eql(&binding("marlin", .anthropic_messages, "model-a")));
}

fn binding(connection: []const u8, dialect: Dialect, model: []const u8) Binding {
    var value: Binding = undefined;
    value.wire.connection = ConnectionName.from(connection) catch unreachable;
    value.wire.dialect = dialect;
    value.model = ModelName.from(model) catch unreachable;
    return value;
}
