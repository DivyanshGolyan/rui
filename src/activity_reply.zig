//! The `activity-page` and `activity-search` replies: the Host writes the
//! page and the search the Store reads (`activity_facts.zig`) with the
//! shapes here, which also give the replies' schemas (`openapi.zig`).
const std = @import("std");
const protocol = @import("protocol.zig");
const activity_facts = @import("activity_facts.zig");
const activity_read = @import("activity_read.zig");
const change_ring = @import("change_ring.zig");
const wire_version = @import("wire_version.zig").wire_version;

const H = protocol.Hole;
const writeShape = protocol.writeShape;
const shapeBytes = protocol.shapeBytes;
const jsonListBytes = protocol.jsonListBytes;
const ContentJson = protocol.ContentJson;
const NamedPeerJson = protocol.NamedPeerJson;
const ToolPresentationJson = protocol.ToolPresentationJson;
const Item = activity_facts.Item;
const Page = activity_facts.Page;
const Search = activity_facts.Search;

pub const max_page_bytes = page_reply.max_bytes;
pub const max_search_bytes = search_reply.max_bytes;

/// One activity row as JSON.
pub const ItemJson = struct {
    item: *const Item,

    pub const openapi_name = "ActivityItem";

    /// Holes: position, ordinal, at; then the value's shape, then `tail`.
    pub fn head(comptime kind: Item.Kind) struct { []const u8, H, []const u8, H, []const u8, H, []const u8 } {
        return .{ "{\"position\":\"", .decimal, "\",\"ordinal\":\"", .decimal, "\",\"at\":\"", .decimal, "\",\"value\":{\"" ++ @tagName(kind) ++ "\":" };
    }
    pub const tail = .{"}}"};
    /// Each value kind's JSON, named by its tag.
    pub const value_shapes = struct {
        /// Holes: admission, key, turn, state, admitted at, sender, content.
        const message = .{ "{\"admission\":\"", H.decimal, "\",\"key\":", H{ .string = protocol.max_key_bytes }, ",\"turn\":", H.optional_id, ",\"state\":\"", H{ .tag = @FieldType(Item.Message, "state") }, "\",\"admitted_at\":\"", H.decimal, "\",\"sender\":", H{ .optional_json = NamedPeerJson }, ",\"content\":", H{ .json = ContentJson }, "}" };
        pub const admission = message;
        pub const user = message;
        pub const received = message;
        /// Holes: content, final.
        pub const assistant = .{ "{\"content\":", H{ .json = ContentJson }, ",\"final\":", H.boolean, "}" };
        /// Holes: operation, turn, call ordinal, Action, rejection, the three field contents.
        pub const call = .{ "{\"operation\":\"", H.decimal, "\",\"turn\":\"", H.decimal, "\",\"call_ordinal\":\"", H.decimal, "\",\"action\":", H.optional_id, ",\"rejection\":", H{ .optional_tag = protocol.ProposalRejection }, ",\"fields\":[", H{ .json = ContentJson }, ",", H{ .json = ContentJson }, ",", H{ .json = ContentJson }, "]}" };
        /// Holes: content, presentation.
        pub const tool_result = .{ "{\"content\":", H{ .json = ContentJson }, ",\"presentation\":", H{ .json = ToolPresentationJson }, "}" };
        /// A call the provider ran, shown by its line alone. Hole: presentation.
        pub const hosted_call = .{ "{\"presentation\":", H{ .json = ToolPresentationJson }, "}" };
        /// Holes: turn, operation, ending, code, content.
        pub const turn_ended = .{ "{\"session\":", H{ .string = protocol.session_id_bytes }, ",\"turn\":\"", H.decimal, "\",\"operation\":\"", H.decimal, "\",\"ending\":\"", H{ .tag = protocol.TurnEnding }, "\",\"code\":", H{ .string = protocol.max_code_bytes }, ",\"content\":", H{ .optional_json = ContentJson }, "}" };
        /// Holes: key, turn, cutoff, completion.
        pub const stop = .{ "{\"key\":", H{ .string = protocol.max_key_bytes }, ",\"turn\":", H.optional_id, ",\"cutoff\":\"", H.decimal, "\",\"completion\":\"", H{ .tag = protocol.SessionStopCompletion }, "\"}" };
        /// Holes: admission, admitted at, target, content.
        pub const sent = .{ "{\"admission\":\"", H.decimal, "\",\"admitted_at\":\"", H.decimal, "\",\"target\":", H{ .json = NamedPeerJson }, ",\"content\":", H{ .json = ContentJson }, "}" };
        /// Holes: key, target, code.
        pub const send_failed = .{ "{\"key\":", H{ .string = protocol.max_key_bytes }, ",\"target\":", H{ .optional_json = NamedPeerJson }, ",\"code\":", H{ .string = protocol.max_code_bytes }, "}" };
        /// Holes: action, operation, call ordinal.
        pub const approval_requested = .{ "{\"session\":", H{ .string = protocol.session_id_bytes }, ",\"action\":\"", H.decimal, "\",\"operation\":\"", H.decimal, "\",\"call_ordinal\":\"", H.decimal, "\"}" };
        /// Holes: revision, field, provider text.
        pub const session_changed = .{ "{\"revision\":\"", H.decimal, "\",\"field\":\"", H{ .tag = protocol.SessionField }, "\",\"provider_text\":", H{ .optional_string = protocol.max_report_bytes }, "}" };
        /// Holes: operation, dropped.
        pub const compacted = .{ "{\"operation\":\"", H.decimal, "\",\"dropped\":\"", H.decimal, "\"}" };
    };
    pub const max_json_bytes = blk: {
        @setEvalBranchQuota(10_000);
        var bytes = 0;
        for (std.meta.tags(Item.Kind)) |kind| {
            const name = @tagName(kind);
            bytes = @max(bytes, shapeBytes(head(kind)) + shapeBytes(@field(value_shapes, name)));
        }
        break :blk bytes + shapeBytes(tail);
    };

    pub fn writeJson(self: *const ItemJson, out: *std.Io.Writer) !void {
        const item = self.item;
        switch (item.value) {
            inline else => |_, kind| try writeShape(out, head(kind), .{ item.position, item.ordinal, item.at }),
        }
        switch (item.value) {
            inline .admission, .user, .received => |message, tag| {
                const name = @tagName(tag);
                try writeShape(out, @field(value_shapes, name), .{
                    message.admission,   message.key.slice(),                    message.turn,                            message.state,
                    message.admitted_at, NamedPeerJson.optional(message.sender), ContentJson{ .value = message.content },
                });
            },
            .sent => |sent| try writeShape(out, value_shapes.sent, .{ sent.admission, sent.admitted_at, NamedPeerJson{ .value = sent.target }, ContentJson{ .value = sent.content } }),
            .send_failed => |failed| try writeShape(out, value_shapes.send_failed, .{ failed.key.slice(), NamedPeerJson.optional(failed.target), failed.code.slice() }),
            .approval_requested => |request| try writeShape(out, value_shapes.approval_requested, .{ request.session.slice(), request.action, request.operation, request.call_ordinal }),
            .session_changed => |change| try writeShape(out, value_shapes.session_changed, .{ change.revision, change.field, if (change.provider_text) |text| text.slice() else null }),
            .compacted => |compacted| try writeShape(out, value_shapes.compacted, .{ compacted.operation, compacted.dropped }),
            .assistant => |assistant| try writeShape(out, value_shapes.assistant, .{ ContentJson{ .value = assistant.content }, assistant.final }),
            .tool_result => |result| try writeShape(out, value_shapes.tool_result, .{ ContentJson{ .value = result.content }, ToolPresentationJson{ .value = result.presentation } }),
            .hosted_call => |presentation| try writeShape(out, value_shapes.hosted_call, .{ToolPresentationJson{ .value = presentation }}),
            .call => |call| {
                comptime std.debug.assert(call.fields.len == 3);
                var fields: [3]ContentJson = undefined;
                for (call.fields, &fields) |field, *content| content.* = .{ .value = .{ .length = field.length, .digest = field.digest } };
                try writeShape(out, value_shapes.call, .{ call.operation, call.turn, call.call_ordinal, call.action, call.rejection, fields[0], fields[1], fields[2] });
            },
            .turn_ended => |ended| try writeShape(out, value_shapes.turn_ended, .{ ended.session.slice(), ended.turn, ended.operation, ended.ending, ended.code.slice(), ContentJson.optional(ended.content) }),
            .stop => |stop| try writeShape(out, value_shapes.stop, .{ stop.key.slice(), stop.turn, stop.cutoff, stop.completion }),
        }
        try writeShape(out, tail, .{});
    }
};

pub const CallActivityJson = struct {
    value: *const activity_facts.CallActivity,

    pub const openapi_name = "CallActivity";
    /// Hole: total.
    pub const head = .{ "{\"total\":\"", H.decimal, "\",\"entries\":[" };
    /// Holes: operation, ordinal, presentation.
    pub const entry_shape = .{ "{\"operation\":\"", H.decimal, "\",\"ordinal\":\"", H.decimal, "\",\"presentation\":", H{ .json = ToolPresentationJson }, "}" };
    pub const tail = .{"]}"};
    pub const max_json_bytes = shapeBytes(head) + jsonListBytes(@typeInfo(@FieldType(activity_facts.CallActivity, "entries")).array.len, shapeBytes(entry_shape)) + shapeBytes(tail);

    pub fn writeJson(self: *const CallActivityJson, out: *std.Io.Writer) !void {
        const activity = self.value;
        try writeShape(out, head, .{activity.total});
        for (activity.entries[0..activity.count], 0..) |entry, index| {
            if (index != 0) try out.writeByte(',');
            try writeShape(out, entry_shape, .{ entry.operation, entry.ordinal, ToolPresentationJson{ .value = entry.presentation } });
        }
        try writeShape(out, tail, .{});
    }
};

pub const QueuedJson = struct {
    value: *const activity_facts.Queued,

    pub const openapi_name = "Queued";
    /// Holes: count, oldest position, newest admission, newest position.
    pub const json_shape = .{ "{\"count\":\"", H.decimal, "\",\"oldest_position\":\"", H.decimal, "\",\"newest_admission\":\"", H.decimal, "\",\"newest_position\":\"", H.decimal, "\"}" };
    pub const max_json_bytes = shapeBytes(json_shape);

    pub fn writeJson(self: *const QueuedJson, out: *std.Io.Writer) !void {
        const queued = self.value;
        try writeShape(out, json_shape, .{ queued.count, queued.oldest_position, queued.newest_admission, queued.newest_position });
    }
};

pub const PageWorkJson = struct {
    value: *const activity_facts.PageWork,

    pub const openapi_name = "PageWork";
    /// Holes: the work's fields, revision, Workspace.
    pub const json_shape = .{"{"} ++ protocol.SessionWork.fields ++ .{ ",\"revision\":\"", H.decimal, "\",\"workspace\":", H{ .string = protocol.max_workspace_bytes }, "}" };
    pub const max_json_bytes = shapeBytes(json_shape);

    pub fn writeJson(self: *const PageWorkJson, out: *std.Io.Writer) !void {
        const work: protocol.SessionWork = .fromCore(self.value.work);
        try writeShape(out, json_shape, work.args() ++ .{ self.value.revision, self.value.workspace.slice() });
    }
};

/// An `activity-page` reply: a full page, or the token of an unchanged one.
pub const page_reply = struct {
    /// Holes: end, direction; then the items, then `tail`.
    pub const head = .{ "{\"version\":\"" ++ wire_version ++ "\",\"type\":\"activity_page\",\"end\":\"", H.decimal, "\",\"direction\":\"", H{ .tag = @FieldType(activity_read.ActivityPage, "direction") }, "\",\"items\":[" };
    /// Holes: more, call activity, queued, work.
    pub const tail = .{ "],\"more\":", H.boolean, ",\"call_activity\":", H{ .json = CallActivityJson }, ",\"queued\":", H{ .json = QueuedJson }, ",\"work\":", H{ .json = PageWorkJson }, ",\"delta\":\"full\",\"since\":", H{ .optional_string = change_ring.SessionToken.max_bytes }, "}" };
    pub const unchanged = .{ "{\"version\":\"" ++ wire_version ++ "\",\"type\":\"activity_page\",\"delta\":\"not_modified\",\"since\":", H{ .string = change_ring.SessionToken.max_bytes }, "}" };
    pub const max_bytes = shapeBytes(head) + jsonListBytes(@typeInfo(@FieldType(Page, "items")).array.len, ItemJson.max_json_bytes) + shapeBytes(tail);
};

pub fn writePage(out: *std.Io.Writer, page: *const Page) !void {
    var token_buffer: [change_ring.SessionToken.max_bytes]u8 = undefined;
    const token = if (page.token) |value| value.format(&token_buffer) else null;
    if (page.not_modified) return writeShape(out, page_reply.unchanged, .{token.?});
    try writeFullPage(out, page, token);
}

pub fn writeFullPage(out: *std.Io.Writer, page: *const Page, token: ?[]const u8) !void {
    try writeShape(out, page_reply.head, .{ page.end, page.direction });
    for (page.items[0..page.count], 0..) |*item, index| {
        if (index != 0) try out.writeByte(',');
        try (ItemJson{ .item = item }).writeJson(out);
    }
    try writeShape(out, page_reply.tail, .{ page.more, CallActivityJson{ .value = &page.call_activity }, QueuedJson{ .value = &page.queued }, PageWorkJson{ .value = &page.work }, token });
}

pub const SearchHitJson = struct {
    value: *const Search.Hit,

    pub const openapi_name = "ActivitySearchFactsHit";
    pub const json_shape = .{ "{\"snippet\":", H{ .string = 160 }, ",\"offset\":\"", H.decimal, "\",\"length\":\"", H.decimal, "\"}" };
    pub const max_json_bytes = shapeBytes(json_shape);

    pub fn writeJson(self: *const SearchHitJson, out: *std.Io.Writer) !void {
        try writeShape(out, json_shape, .{ self.value.snippet.slice(), self.value.offset, self.value.length });
    }
};

pub const SearchCursorJson = struct {
    value: Search.Cursor,

    pub const openapi_name = "ActivitySearchFactsCursor";
    pub const json_shape = .{ "{\"position\":\"", H.decimal, "\",\"ordinal\":\"", H.decimal, "\"}" };
    pub const max_json_bytes = shapeBytes(json_shape);

    pub fn writeJson(self: *const SearchCursorJson, out: *std.Io.Writer) !void {
        try writeShape(out, json_shape, .{ self.value.position, self.value.ordinal });
    }
};

/// One searched row and its hits.
pub const SearchMatchJson = struct {
    value: *const Search.Match,

    pub const head = .{ "{\"position\":\"", H.decimal, "\",\"ordinal\":\"", H.decimal, "\",\"kind\":\"", H{ .tag = activity_read.Kind }, "\",\"hits\":[" };
    pub const max_json_bytes = shapeBytes(head) + jsonListBytes(@typeInfo(@FieldType(Search.Match, "hits")).array.len, SearchHitJson.max_json_bytes) + 2;

    pub fn writeJson(self: *const SearchMatchJson, out: *std.Io.Writer) !void {
        const match = self.value;
        try writeShape(out, head, .{ match.position, match.ordinal, match.kind });
        for (match.hits[0..match.count], 0..) |*hit, index| {
            if (index != 0) try out.writeByte(',');
            try (SearchHitJson{ .value = hit }).writeJson(out);
        }
        try out.writeAll("]}");
    }
};

/// An `activity-search` reply.
pub const search_reply = struct {
    pub const head = .{"{\"version\":\"" ++ wire_version ++ "\",\"type\":\"activity_search\",\"items\":["};
    pub const tail = .{ "],\"next\":", H{ .optional_json = SearchCursorJson }, "}" };
    pub const max_bytes = shapeBytes(head) + jsonListBytes(@typeInfo(@FieldType(Search, "items")).array.len, SearchMatchJson.max_json_bytes) + shapeBytes(tail);
};

pub fn writeSearch(out: *std.Io.Writer, search: *const Search) !void {
    try writeShape(out, search_reply.head, .{});
    for (search.items[0..search.count], 0..) |*match, index| {
        if (index != 0) try out.writeByte(',');
        try (SearchMatchJson{ .value = match }).writeJson(out);
    }
    try writeShape(out, search_reply.tail, .{if (search.next) |next| SearchCursorJson{ .value = next } else null});
}

test "activity search reply bounds preserve snippets and nullable continuation" {
    var facts: Search = .{};
    facts.count = 1;
    facts.items[0] = .{ .position = 9, .ordinal = 2, .kind = .call, .count = 1 };
    facts.items[0].hits[0] = .{ .offset = 1, .length = 3 };
    try facts.items[0].hits[0].snippet.set("\"雪\n");
    facts.next = .{ .position = 8, .ordinal = 0 };
    var buffer: [max_search_bytes]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    try writeSearch(&out, &facts);
    try std.testing.expectEqualStrings("{\"version\":\"" ++ wire_version ++ "\",\"type\":\"activity_search\",\"items\":[{\"position\":\"9\",\"ordinal\":\"2\",\"kind\":\"call\",\"hits\":[{\"snippet\":\"\\\"雪\\n\",\"offset\":\"1\",\"length\":\"3\"}]}],\"next\":{\"position\":\"8\",\"ordinal\":\"0\"}}", out.buffered());
    facts.count = 0;
    facts.next = null;
    out = std.Io.Writer.fixed(&buffer);
    try writeSearch(&out, &facts);
    try std.testing.expectEqualStrings("{\"version\":\"" ++ wire_version ++ "\",\"type\":\"activity_search\",\"items\":[],\"next\":null}", out.buffered());
}
