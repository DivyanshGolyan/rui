const std = @import("std");
const model_catalog = @import("model_catalog.zig");
const protocol = @import("protocol.zig");
const command_spec = @import("command_spec.zig");
const session_list = @import("session_list.zig");
const activity_reply = @import("activity_reply.zig");
pub const SessionToken = @import("change_ring.zig").SessionToken;
const model_list = @import("model_list.zig");
const model_picker = @import("model_picker.zig");
const transport_policy = @import("transport_policy.zig");
const wire_field = @import("wire_field.zig");
const mutation_answer = @import("mutation_answer.zig");
const content_value = @import("content_value.zig");
const input_parts = @import("input_parts.zig");
comptime {
    std.debug.assert(mutation_answer.max_code_bytes == protocol.max_code_bytes);
    std.debug.assert(mutation_answer.max_session_bytes == protocol.max_session_bytes);
}
pub const JsonString = wire_field.JsonString;
pub const JsonEnum = wire_field.JsonEnum;
const JsonArray = wire_field.JsonArray;
pub const OmittableJson = wire_field.OmittableJson;
pub const decimalId = wire_field.decimalId;

pub const ConversationCursor = struct {
    end: u64,
    before_position: u64 = 0,
    before_ordinal: u64 = 0,
    pub fn validate(self: ConversationCursor) !void {
        if (self.end > std.math.maxInt(i64) or self.before_position > self.end or self.before_ordinal > std.math.maxInt(i64) or
            (self.before_position == 0 and self.before_ordinal != 0)) return error.InvalidCursor;
    }
};
pub const ConversationPageReply = union(enum) { page: ConversationPage, failure: ReadFailure };
pub const ConversationPage = struct {
    pub const Item = struct {
        position: u64,
        ordinal: u64,
        kind: protocol.ConversationItemKind,
        /// Always text on an `assistant` item.
        content: content_value.Value,
        presentation: ?protocol.ToolPresentation = null,
        admitted_at: ?u64 = null,
        sender: ?protocol.NamedPeer = null,
        source_action: ?u64 = null,
    };
    end: u64,
    items: [protocol.public_conversation_page_items]Item = undefined,
    count: usize = 0,
    more: bool,
    pub fn continuation(self: *const ConversationPage) ?ConversationCursor {
        if (!self.more) return null;
        const last = self.items[self.count - 1];
        return .{ .end = self.end, .before_position = last.position, .before_ordinal = last.ordinal };
    }
    pub fn parse(bytes: []const u8, cursor: ConversationCursor) !ConversationPage {
        try cursor.validate();
        const Row = struct {
            position: JsonString(20),
            ordinal: JsonString(20),
            kind: JsonEnum(@FieldType(Item, "kind")),
            content: ?JsonContentValue = null,
            presentation: ?JsonToolPresentation = null,
            admitted_at: ?JsonString(20) = null,
            sender: ?JsonNamedPeer = null,
            source_action: ?JsonString(20) = null,
        };
        const Rows = JsonArray(Row, protocol.public_conversation_page_items);
        const Wire = struct {
            version: JsonString(8),
            type: JsonString(32),
            direction: JsonString(16),
            end: JsonString(20),
            items: Rows,
            more: bool,
            before_position: ?JsonString(20) = null,
            before_ordinal: ?JsonString(20) = null,
        };
        var storage: [2 * protocol.max_conversation_page_response_bytes]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&storage);
        const wire = std.json.parseFromSliceLeaky(Wire, fixed.allocator(), bytes, .{ .ignore_unknown_fields = true }) catch return error.InvalidConversationPage;
        if (!wire.version.eql(protocol.wire_version) or !wire.type.eql("conversation_page") or !wire.direction.eql("newest_first")) return error.InvalidConversationPage;
        var page: ConversationPage = .{ .end = try decimalId(wire.end, true), .count = wire.items.count, .more = wire.more };
        if (page.end > std.math.maxInt(i64) or (cursor.end != 0 and page.end != cursor.end) or (page.more and page.count != page.items.len)) return error.InvalidConversationPage;
        var position = cursor.before_position;
        var ordinal = cursor.before_ordinal;
        for (wire.items.values[0..page.count], page.items[0..page.count]) |row, *item| {
            const hosted = row.kind.value == .hosted_call;
            if (hosted == (row.content != null)) return error.InvalidConversationPage;
            item.* = .{ .position = try decimalId(row.position, false), .ordinal = try decimalId(row.ordinal, true), .kind = row.kind.value, .content = .{ .text = .{ .length = 0, .digest = protocol.contentDigest("") } } };
            item.presentation = if (row.presentation) |p| p.value else null;
            item.admitted_at = if (row.admitted_at) |second| try decimalId(second, false) else null;
            item.sender = if (row.sender) |sender| sender.peer() catch return error.InvalidConversationPage else null;
            item.source_action = if (row.source_action) |action| try decimalId(action, false) else null;
            if ((item.kind == .tool_result or hosted) != (item.presentation != null) or (item.kind == .user) != (item.admitted_at != null) or
                (item.kind != .user and (item.sender != null or item.source_action != null)) or
                (item.sender != null and item.source_action != null) or
                (item.admitted_at orelse 0) > std.math.maxInt(i64)) return error.InvalidConversationPage;
            if (item.presentation) |p| if (p.publication_position != item.position or (hosted and p.description == null)) return error.InvalidConversationPage;
            if (row.content) |value| item.content = if (item.kind == .assistant) .{ .text = value.text() catch return error.InvalidConversationPage } else value.value;
            if (item.position > page.end or item.ordinal > std.math.maxInt(i64) or
                ((item.kind == .tool_result) != (item.ordinal != 0)) or
                (position != 0 and (item.position > position or (item.position == position and item.ordinal >= ordinal)))) return error.InvalidConversationPage;
            position = item.position;
            ordinal = item.ordinal;
        }
        if (page.more) {
            if (wire.before_position == null or wire.before_ordinal == null or
                try decimalId(wire.before_position.?, false) != position or try decimalId(wire.before_ordinal.?, true) != ordinal) return error.InvalidConversationPage;
        } else if (wire.before_position != null or wire.before_ordinal != null) return error.InvalidConversationPage;
        return page;
    }
};

pub const ActivityCursor = struct {
    end: ?u64 = null,
    position: u64 = 0,
    ordinal: ?u64 = null,
    direction: @FieldType(protocol.ActivityPage, "direction") = .forward,
    kinds: protocol.ActivityPage.Kinds = .full,
    limit: u8 = protocol.ActivityPage.items,
    pub fn validate(self: ActivityCursor) !void {
        try (protocol.ActivityPage{ .end = self.end, .position = self.position, .ordinal = self.ordinal, .direction = self.direction, .kinds = self.kinds, .limit = self.limit }).validate();
    }
};
pub const ActivityPageReply = union(enum) { page: ActivityPage, failure: ReadFailure };
pub const ActivityPrefixReply = union(enum) { line: []const u8, failure: ReadFailure };
pub const ActivityPage = struct {
    facts: protocol.ActivityFacts,
    kinds: protocol.ActivityPage.Kinds = .full,
    limit: u8 = protocol.ActivityPage.items,

    pub fn continuation(self: *const ActivityPage) ?ActivityCursor {
        const facts = &self.facts;
        if (!facts.more) return null;
        const last = facts.items[facts.count - 1];
        return .{ .end = facts.end, .position = last.position, .ordinal = last.ordinal, .direction = facts.direction, .kinds = self.kinds, .limit = self.limit };
    }

    pub fn parse(bytes: []const u8, cursor: ActivityCursor) !ActivityPage {
        try cursor.validate();
        if (bytes.len > activity_reply.max_page_bytes) return error.InvalidActivityPage;
        const Ref = JsonContentValue;
        const Fact = protocol.ActivityItem;
        const Message = struct { admission: JsonString(20), key: JsonString(protocol.max_key_bytes), turn: ?JsonString(20), state: JsonEnum(@FieldType(Fact.Message, "state")), admitted_at: JsonString(20), sender: ?JsonNamedPeer, source_action: ?JsonString(20) = null, content: Ref };
        const Sent = struct { admission: JsonString(20), admitted_at: JsonString(20), target: JsonNamedPeer, content: Ref };
        const SendFailed = struct { key: JsonString(protocol.max_key_bytes), target: ?JsonNamedPeer, code: JsonString(protocol.max_code_bytes) };
        const Call = struct { operation: JsonString(20), turn: JsonString(20), call_ordinal: JsonString(20), action: ?JsonString(20), rejection: ?JsonEnum(protocol.ProposalRejection), fields: [3]Ref, description: ?JsonString(protocol.max_tool_description_bytes), tool: ?JsonString(protocol.max_tool_name_bytes), server: ?JsonString(protocol.max_tool_name_bytes) };
        const TurnEnded = struct { session: JsonString(protocol.session_id_bytes), turn: JsonString(20), operation: JsonString(20), ending: JsonEnum(protocol.TurnEnding), code: JsonString(protocol.max_code_bytes), content: ?Ref };
        const ApprovalRequested = struct { session: JsonString(protocol.session_id_bytes), action: JsonString(20), operation: JsonString(20), call_ordinal: JsonString(20), description: ?JsonString(protocol.max_tool_description_bytes), tool: ?JsonString(protocol.max_tool_name_bytes), server: ?JsonString(protocol.max_tool_name_bytes) };
        const SessionChanged = struct { revision: JsonString(20), field: protocol.SessionField, provider_text: ?JsonString(protocol.max_report_bytes) = null };
        const Compacted = struct { operation: JsonString(20), dropped: JsonString(20) };
        const ModelCall = struct { model: JsonString(protocol.max_model_bytes), served_model: ?JsonString(protocol.max_model_bytes), input_tokens: ?JsonString(20), output_tokens: ?JsonString(20), cached_tokens: ?JsonString(20), latency_ms: ?JsonString(20), first_event_ms: ?JsonString(20), status: JsonString(protocol.max_code_bytes), attempts: JsonString(20) };
        const Stop = struct { key: JsonString(protocol.max_key_bytes), turn: ?JsonString(20), cutoff: JsonString(20), completion: JsonEnum(@FieldType(Fact.Stop, "completion")) };
        const Item = struct { position: JsonString(20), ordinal: JsonString(20), at: JsonString(20), value: union(enum) { admission: Message, user: Message, assistant: struct { content: Ref, final: bool }, call: Call, tool_result: struct { content: Ref, presentation: JsonToolPresentation }, hosted_call: struct { presentation: JsonToolPresentation }, turn_ended: TurnEnded, stop: Stop, sent: Sent, send_failed: SendFailed, received: Message, approval_requested: ApprovalRequested, session_changed: SessionChanged, compacted: Compacted, model_call: ModelCall } };
        const Items = JsonArray(Item, 16);
        const CallEntry = struct { operation: JsonString(20), ordinal: JsonString(20), presentation: JsonToolPresentation };
        const Calls = JsonArray(CallEntry, 3);
        const Work = struct { creator: ?JsonString(protocol.session_id_bytes), read_version: JsonString(protocol.SinceToken.max_bytes), state: JsonWorkState, turn: ?JsonString(20), operation: ?JsonString(20), first_action: ?JsonString(20), attention: ?JsonWorkAttention, group: JsonEnum(@import("session_work.zig").Group), actions: JsonWorkActions, last_line: ?struct { position: JsonString(20), text: ?JsonString(session_list.max_last_line_bytes) } = null, revision: JsonString(20), workspace: JsonString(protocol.max_workspace_bytes) };
        const Queued = struct { count: JsonString(20), oldest_position: JsonString(20), newest_admission: JsonString(20), newest_position: JsonString(20), newest_content: ?Ref };
        const Wire = struct { version: JsonString(8), type: JsonString(32), delta: JsonEnum(enum { full }), since: ?JsonString(SessionToken.max_bytes), end: JsonString(20), direction: JsonEnum(@FieldType(ActivityCursor, "direction")), items: Items, more: bool, call_activity: struct { total: JsonString(20), entries: Calls }, queued: Queued, work: Work };
        var storage: [2 * activity_reply.max_page_bytes]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&storage);
        const Header = struct { delta: JsonEnum(enum { full, not_modified }) };
        const header = std.json.parseFromSliceLeaky(Header, fixed.allocator(), bytes, .{ .ignore_unknown_fields = true }) catch return error.InvalidActivityPage;
        fixed.reset();
        if (header.delta.value == .not_modified) {
            const Unchanged = struct { version: JsonString(8), type: JsonString(32), delta: JsonEnum(enum { not_modified }), since: JsonString(SessionToken.max_bytes) };
            const wire = std.json.parseFromSliceLeaky(Unchanged, fixed.allocator(), bytes, .{}) catch return error.InvalidActivityPage;
            if (!wire.version.eql(protocol.wire_version) or !wire.type.eql("activity_page")) return error.InvalidActivityPage;
            return .{ .facts = .{
                .end = cursor.end orelse cursor.position,
                .direction = cursor.direction,
                .token = SessionToken.parse(wire.since.slice()) catch return error.InvalidActivityPage,
                .not_modified = true,
            }, .kinds = cursor.kinds, .limit = cursor.limit };
        }
        const wire = std.json.parseFromSliceLeaky(Wire, fixed.allocator(), bytes, .{}) catch return error.InvalidActivityPage;
        var page: ActivityPage = .{ .facts = .{ .token = if (wire.since) |token| SessionToken.parse(token.slice()) catch return error.InvalidActivityPage else null, .end = try id(wire.end, true), .direction = wire.direction.value, .more = wire.more, .count = wire.items.count }, .kinds = cursor.kinds, .limit = cursor.limit };
        if (!wire.version.eql(protocol.wire_version) or !wire.type.eql("activity_page") or page.facts.direction != cursor.direction or
            (cursor.end != null and cursor.end.? != page.facts.end) or cursor.position > page.facts.end or
            wire.items.count > cursor.limit or (wire.more and wire.items.count != cursor.limit)) return error.InvalidActivityPage;
        var position = cursor.position;
        var ordinal = cursor.ordinal;
        for (wire.items.values[0..wire.items.count], page.facts.items[0..wire.items.count]) |item, *fact| {
            fact.* = .{ .position = try id(item.position, false), .ordinal = try id(item.ordinal, true), .at = try id(item.at, false), .value = undefined };
            const after = fact.position > position or (ordinal != null and fact.position == position and fact.ordinal > ordinal.?);
            const before = fact.position < position or (ordinal != null and fact.position == position and fact.ordinal < ordinal.?);
            if (fact.position > page.facts.end or (position != 0 and !(if (cursor.direction == .forward) after else before)) or
                (switch (item.value) {
                    .approval_requested => fact.ordinal > 1,
                    .session_changed => false,
                    else => (item.value == .tool_result) != (fact.ordinal != 0),
                }) or !cursor.kinds.contains(std.meta.stringToEnum(protocol.ActivityItem.Kind, @tagName(item.value)).?)) return error.InvalidActivityPage;
            switch (item.value) {
                inline .admission, .user, .received => |message, kind| {
                    const value: Fact.Message = .{ .admission = try id(message.admission, false), .key = message.key.value, .turn = if (message.turn) |turn| try id(turn, false) else null, .state = message.state.value, .content = message.content.value, .admitted_at = try id(message.admitted_at, false), .sender = if (message.sender) |sender| try sender.peer() else null, .source_action = if (message.source_action) |action| try id(action, false) else null };
                    if ((value.state == .applied) != (value.turn != null) or (kind == .user and value.state != .applied)) return error.InvalidActivityPage;
                    if ((value.sender != null and value.source_action != null) or (kind != .user and (fact.at != value.admitted_at or (kind == .received) != (value.sender != null or value.source_action != null)))) return error.InvalidActivityPage;
                    fact.value = @unionInit(Fact.Value, @tagName(kind), value);
                },
                .sent => |sent| {
                    fact.value = .{ .sent = .{ .admission = try id(sent.admission, false), .admitted_at = try id(sent.admitted_at, false), .target = try sent.target.peer(), .content = sent.content.value } };
                    if (fact.at != fact.value.sent.admitted_at) return error.InvalidActivityPage;
                },
                .approval_requested => |request| {
                    if (!protocol.validSessionId(request.session.slice())) return error.InvalidActivityPage;
                    fact.value = .{ .approval_requested = .{ .action = try id(request.action, false), .operation = try id(request.operation, false), .session = request.session.value, .call_ordinal = try id(request.call_ordinal, true), .description = if (request.description) |text| text.value else null, .tool = if (request.tool) |text| text.value else null, .server = if (request.server) |text| text.value else null } };
                },
                .session_changed => |change| {
                    const revision = try id(change.revision, false);
                    if (revision <= 1 or (change.field == .reasoning_effort_refused) != (change.provider_text != null)) return error.InvalidActivityPage;
                    fact.value = .{ .session_changed = .{ .revision = revision, .field = change.field, .provider_text = if (change.provider_text) |text| text.value else null } };
                },
                .compacted => |compacted| fact.value = .{ .compacted = .{ .operation = try id(compacted.operation, false), .dropped = try id(compacted.dropped, true) } },
                .model_call => |call| {
                    if (call.model.slice().len == 0 or call.status.slice().len == 0 or (call.served_model != null and call.served_model.?.slice().len == 0)) return error.InvalidActivityPage;
                    fact.value = .{ .model_call = .{
                        .model = call.model.value,
                        .served_model = if (call.served_model) |model| model.value else null,
                        .input_tokens = if (call.input_tokens) |count| try decimalId(count, true) else null,
                        .output_tokens = if (call.output_tokens) |count| try decimalId(count, true) else null,
                        .cached_tokens = if (call.cached_tokens) |count| try decimalId(count, true) else null,
                        .latency_ms = if (call.latency_ms) |count| try id(count, true) else null,
                        .first_event_ms = if (call.first_event_ms) |count| try id(count, true) else null,
                        .status = call.status.value,
                        .attempts = try id(call.attempts, false),
                    } };
                },
                .send_failed => |failed| {
                    if (failed.code.slice().len == 0) return error.InvalidActivityPage;
                    fact.value = .{ .send_failed = .{ .key = failed.key.value, .target = if (failed.target) |peer| try peer.peer() else null, .code = failed.code.value } };
                },
                .assistant => |assistant| fact.value = .{ .assistant = .{ .content = try textOf(assistant.content), .final = assistant.final } },
                .tool_result => |result| {
                    if (result.presentation.value.publication_position != fact.position) return error.InvalidActivityPage;
                    fact.value = .{ .tool_result = .{ .content = result.content.value, .presentation = result.presentation.value } };
                },
                .hosted_call => |call| {
                    if (call.presentation.value.publication_position != fact.position or call.presentation.value.description == null) return error.InvalidActivityPage;
                    fact.value = .{ .hosted_call = call.presentation.value };
                },
                .call => |call| {
                    var value: Fact.Call = .{ .position = fact.position, .operation = try id(call.operation, false), .turn = try id(call.turn, false), .call_ordinal = try id(call.call_ordinal, true), .action = if (call.action) |action| try id(action, false) else null, .rejection = if (call.rejection) |code| code.value else null, .fields = undefined, .description = if (call.description) |text| text.value else null, .tool = if (call.tool) |text| text.value else null, .server = if (call.server) |text| text.value else null };
                    if ((value.action != null) == (value.rejection != null)) return error.InvalidActivityPage;
                    for (call.fields, &value.fields) |reference, *field| {
                        const decoded = try textOf(reference);
                        field.* = .{ .length = decoded.length, .digest = decoded.digest };
                    }
                    fact.value = .{ .call = value };
                },
                .turn_ended => |ended| {
                    if (!protocol.validSessionId(ended.session.slice())) return error.InvalidActivityPage;
                    const ending = ended.ending.value;
                    const done = ending == .done;
                    const cancelled = ending == .stopped or ending == .interrupted;
                    if (ended.code.slice().len == 0 or done != ended.code.eql("completed") or cancelled != ended.code.eql("cancelled") or
                        (done and ended.content == null) or (cancelled and ended.content != null)) return error.InvalidActivityPage;
                    fact.value = .{ .turn_ended = .{ .session = ended.session.value, .turn = try id(ended.turn, false), .operation = try id(ended.operation, false), .ending = ending, .code = ended.code.value, .content = if (ended.content) |reference| try textOf(reference) else null } };
                },
                .stop => |stop| {
                    fact.value = .{ .stop = .{ .key = stop.key.value, .turn = if (stop.turn) |turn| try id(turn, false) else null, .cutoff = try id(stop.cutoff, true), .completion = stop.completion.value } };
                },
            }
            position = fact.position;
            ordinal = fact.ordinal;
        }
        page.facts.call_activity.total = try id(wire.call_activity.total, true);
        page.facts.call_activity.count = wire.call_activity.entries.count;
        if (page.facts.call_activity.count != @min(3, page.facts.call_activity.total)) return error.InvalidActivityPage;
        const last = if (page.facts.direction == .forward and page.facts.more) page.facts.items[page.facts.count - 1] else null;
        const boundary_position = if (last) |item| item.position else page.facts.end;
        const boundary_ordinal: ?u64 = if (last) |item| item.ordinal else null;
        var previous: ?protocol.CallActivity.Entry = null;
        for (wire.call_activity.entries.values[0..page.facts.call_activity.count], page.facts.call_activity.entries[0..page.facts.call_activity.count]) |entry, *fact| {
            fact.* = .{ .operation = try id(entry.operation, false), .ordinal = try id(entry.ordinal, true), .presentation = entry.presentation.value };
            if (fact.ordinal == std.math.maxInt(i64)) return error.InvalidActivityPage;
            if (previous) |prior| if (fact.operation < prior.operation or
                fact.operation == prior.operation and fact.ordinal <= prior.ordinal) return error.InvalidActivityPage;
            if (fact.presentation.publication_position) |p| if (p < boundary_position or
                p == boundary_position and (boundary_ordinal == null or fact.ordinal + 1 <= boundary_ordinal.?)) return error.InvalidActivityPage;
            previous = fact.*;
        }
        const queued: protocol.Queued = .{ .count = try id(wire.queued.count, true), .oldest_position = try id(wire.queued.oldest_position, true), .newest_admission = try id(wire.queued.newest_admission, true), .newest_position = try id(wire.queued.newest_position, true), .newest_content = if (wire.queued.newest_content) |value| value.value else null };
        if (if (queued.count == 0)
            !std.meta.eql(queued, protocol.Queued{})
        else
            queued.newest_admission == 0 or queued.oldest_position == 0 or queued.oldest_position > queued.newest_position or
                queued.newest_position > boundary_position or queued.count > queued.newest_position - queued.oldest_position + 1 or
                !mutation_answer.matchesMessageAdmission(queued.newest_content orelse return error.InvalidActivityPage, queued.newest_admission)) return error.InvalidActivityPage;
        page.facts.queued = queued;
        const facts = &page.facts.work;
        const work = &facts.work;
        work.state = wire.work.state.value;
        work.served_attention = try readWorkAttention(wire.work.attention);
        work.served_group = wire.work.group.value;
        work.actions = try readWorkActions(wire.work.actions);
        inline for (.{ &work.turn, &work.operation, &work.first_action }, .{ wire.work.turn, wire.work.operation, wire.work.first_action }) |fact, value| {
            fact.* = if (value) |text| try id(text, false) else null;
        }
        if ((work.turn == null) != (work.operation == null)) return error.InvalidActivityPage;
        if (wire.work.last_line) |line| facts.last_line = .{ .position = try id(line.position, false), .text = if (line.text) |text| text.value else null };
        if (wire.work.creator) |creator| {
            if (!protocol.validSessionId(creator.slice())) return error.InvalidActivityPage;
            facts.creator = creator.value;
        }
        facts.read_version = protocol.SinceToken.parse(wire.work.read_version.slice()) catch return error.InvalidActivityPage;
        facts.revision = try id(wire.work.revision, false);
        if (!std.fs.path.isAbsolute(wire.work.workspace.slice())) return error.InvalidActivityPage;
        facts.workspace.set(wire.work.workspace.slice()) catch return error.InvalidActivityPage;
        return page;
    }

    fn id(value: anytype, zero: bool) !u64 {
        const result = try decimalId(value, zero);
        if (result > std.math.maxInt(i64)) return error.InvalidActivityPage;
        return result;
    }
    fn textOf(value: JsonContentValue) !content_value.Reference {
        return value.text() catch error.InvalidActivityPage;
    }
};

pub const HostStatus = union(enum) {
    ready: struct {
        store: protocol.Bounded(protocol.max_store_bytes),
        instance: protocol.InstanceId,
        active_capacity: usize,
        intake_capacity: usize = 100,
        descriptor_limit: ?usize = null,
        started_at: u64,
        custody_occupied: usize,
        paused: bool,
        innodb_doublewrite: ?protocol.Bounded(32) = null,
        /// SHA-256 of the settings frame a detached Host was started with; absent for older Hosts and foreground starts.
        settings_digest: ?@import("host_settings_handoff.zig").Digest = null,
        capabilities: @FieldType(protocol.HostInfo, "capabilities"),
    },
    unavailable,
    owned_unavailable,
    incompatible,
    access_failure,
};

pub fn validHostUnavailable(body: []const u8) bool {
    if (body.len > protocol.max_control_error_response_bytes) return false;
    var parse_storage: [protocol.max_control_error_response_bytes * 2]u8 = undefined;
    var arena = std.heap.FixedBufferAllocator.init(&parse_storage);
    const reply = std.json.parseFromSliceLeaky(struct {
        version: []const u8,
        type: []const u8,
        code: []const u8,
    }, arena.allocator(), body, .{ .ignore_unknown_fields = false, .allocate = .alloc_if_needed }) catch return false;
    if (!std.mem.eql(u8, reply.version, protocol.wire_version)) return false;
    if (std.mem.eql(u8, reply.type, "host_unavailable")) return std.mem.eql(u8, reply.code, "dispatch_fenced");
    if (!std.mem.eql(u8, reply.type, "busy")) return false;
    return std.mem.eql(u8, reply.code, "connection_capacity_exhausted") or
        std.mem.eql(u8, reply.code, "classification_capacity_exhausted") or
        std.mem.eql(u8, reply.code, "ordinary_capacity_exhausted") or
        std.mem.eql(u8, reply.code, "discovery_capacity_exhausted");
}

pub fn modelListProviders(body: []const u8) error{InvalidModelList}![]const u8 {
    const reply = protocol.model_list_reply;
    if (!std.mem.startsWith(u8, body, reply.head) or !std.mem.endsWith(u8, body, reply.tail) or body.len < reply.head.len + reply.tail.len)
        return error.InvalidModelList;
    return body[reply.head.len .. body.len - reply.tail.len];
}

test "a model list reply reads as what the Host writes" {
    var bytes: [protocol.model_list_reply.max_bytes]u8 = undefined;
    var out = std.Io.Writer.fixed(&bytes);
    try out.writeAll(protocol.model_list_reply.head);
    try model_list.writeProviders(&out, model_catalog.shipped, &.{
        .{ .provider = .codex, .list = .catalog },
        .{ .provider = .openai, .list = .{ .live = .{ .bytes = "gpt-6-luna\nunlisted-model\n" } } },
    });
    try out.writeAll(protocol.model_list_reply.tail);
    var menu = try model_picker.read(std.testing.allocator, try modelListProviders(out.buffered()));
    defer menu.deinit(std.testing.allocator);
    try std.testing.expectEqual(@import("model_catalog.zig").openai_ids.len + 1, menu.entries.len);
    try std.testing.expectEqual(@as(?model_list.Source, .catalog), menu.sources.get(.codex));
    try std.testing.expectEqual(@as(?model_list.Source, .live), menu.sources.get(.openai));
    try std.testing.expectEqualStrings("unlisted-model", menu.entries[menu.others].id);
    for ([_][]const u8{ "", protocol.model_list_reply.head, "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"host_info\",\"providers\":[]}" }) |body|
        try std.testing.expectError(error.InvalidModelList, modelListProviders(body));
}

pub const HostInfoProfile = enum {
    current,
    released_22,
    released_23,

    pub fn historical(self: HostInfoProfile) bool {
        return self != .current;
    }

    pub fn wire(self: HostInfoProfile) []const u8 {
        return switch (self) {
            .current => protocol.wire_version,
            .released_22 => "22",
            .released_23 => "23",
        };
    }

    pub fn fromWire(text: []const u8) ?HostInfoProfile {
        for (std.enums.values(HostInfoProfile)) |profile| if (std.mem.eql(u8, profile.wire(), text)) return profile;
        return null;
    }

    fn Providers(comptime self: HostInfoProfile) type {
        return switch (self) {
            .current, .released_22, .released_23 => protocol.Routes,
        };
    }
};

pub const HostInfoFacts = @FieldType(HostStatus, "ready");

pub fn parseHostInfo(body: []const u8, store: []const u8) !HostStatus {
    return .{ .ready = try parseHostInfoForProfile(body, store, .current) };
}

pub fn parseHostInfoForProfile(body: []const u8, store: []const u8, profile: HostInfoProfile) !HostInfoFacts {
    return switch (profile) {
        inline else => |known| parseHostInfoShape(protocol.HostInfoWith(known.Providers()), body, store, known),
    };
}

fn parseHostInfoShape(comptime Info: type, body: []const u8, store: []const u8, profile: HostInfoProfile) !HostInfoFacts {
    if (body.len > protocol.max_host_info_response_bytes) return error.InvalidHostInfo;
    var parse_storage: [protocol.max_host_info_response_bytes * 2]u8 = undefined;
    var arena = std.heap.FixedBufferAllocator.init(&parse_storage);
    const info = try std.json.parseFromSliceLeaky(Info, arena.allocator(), body, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_if_needed,
    });
    if (!std.mem.eql(u8, info.version, profile.wire()) or
        !std.mem.eql(u8, info.type, "host_info") or
        !std.mem.eql(u8, info.store, store))
        return error.InvalidHostInfo;
    const finite_limit: ?[]const u8 = if (std.mem.eql(u8, info.descriptor_limit, "unlimited")) null else info.descriptor_limit;
    for ([_]?[]const u8{ info.active_capacity, info.intake_capacity, finite_limit, info.started_at, info.custody_occupied }) |field| {
        const text = field orelse continue;
        if (text.len == 0 or text.len > 20 or (text.len > 1 and text[0] == '0')) return error.InvalidHostInfo;
        for (text) |digit| if (!std.ascii.isDigit(digit)) return error.InvalidHostInfo;
    }
    const instance = protocol.parseInstanceId(info.instance) catch return error.InvalidHostInfo;
    const capacity = std.fmt.parseInt(usize, info.active_capacity, 10) catch return error.InvalidHostInfo;
    const intake_capacity = std.fmt.parseInt(usize, info.intake_capacity, 10) catch return error.InvalidHostInfo;
    if (intake_capacity < 10 or intake_capacity > 100) return error.InvalidHostInfo;
    const descriptor_limit = if (finite_limit) |text| std.fmt.parseInt(usize, text, 10) catch return error.InvalidHostInfo else null;
    const started_at = std.fmt.parseInt(u64, info.started_at, 10) catch return error.InvalidHostInfo;
    if (started_at == 0 or started_at > std.math.maxInt(i64)) return error.InvalidHostInfo;
    const custody_occupied = std.fmt.parseInt(usize, info.custody_occupied, 10) catch return error.InvalidHostInfo;
    if (custody_occupied > capacity) return error.InvalidHostInfo;
    var identity: protocol.Bounded(protocol.max_store_bytes) = .{};
    try identity.set(info.store);
    var doublewrite: ?protocol.Bounded(32) = null;
    if (info.innodb_doublewrite) |value| {
        doublewrite = .{};
        try doublewrite.?.set(value);
    }
    var settings_digest: ?@import("host_settings_handoff.zig").Digest = null;
    if (info.settings_digest) |value| {
        if (value.len != 64) return error.InvalidHostInfo;
        for (value) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return error.InvalidHostInfo;
        var bytes: @import("host_settings_handoff.zig").Digest = undefined;
        _ = std.fmt.hexToBytes(&bytes, value) catch return error.InvalidHostInfo;
        settings_digest = bytes;
    }
    return .{
        .store = identity,
        .instance = instance,
        .active_capacity = capacity,
        .intake_capacity = intake_capacity,
        .descriptor_limit = descriptor_limit,
        .started_at = started_at,
        .custody_occupied = custody_occupied,
        .paused = info.paused,
        .innodb_doublewrite = doublewrite,
        .settings_digest = settings_digest,
        .capabilities = .{
            .bash = info.capabilities.bash,
            .providers = routes: {
                var routes = protocol.routesAll(.unserved);
                inline for (@typeInfo(@TypeOf(info.capabilities.providers)).@"struct".field_names) |name|
                    @field(routes, name) = @field(info.capabilities.providers, name);
                break :routes routes;
            },
        },
    };
}

test "Host information parses omitted and bounded string diagnostics with one selector bound" {
    const host_reply = @import("host_reply.zig");
    for ([_][]const u8{ "/sqlite", "0123456789abcdef0123456789abcdef", &@as([protocol.max_store_bytes]u8, @splat('s')) }) |selector| {
        var info: host_reply.HostInfo = .{
            .store = selector,
            .instance = @splat(1),
            .active_capacity = 2,
            .intake_capacity = 100,
            .descriptor_soft_limit = 1024,
            .started_at = 1792918800,
            .custody_occupied = 0,
            .paused = false,
            .routes = protocol.routesAll(.unserved),
            .doublewrite = null,
            .settings_digest = null,
        };
        var response: protocol.ResponseBuffer = .{};
        try response.render(host_reply.renderHostInfo, .{info});
        const omitted = try parseHostInfo(response.slice(), selector);
        try std.testing.expect(omitted.ready.innodb_doublewrite == null and omitted.ready.settings_digest == null);
        try std.testing.expect(std.mem.indexOf(u8, response.slice(), "innodb_doublewrite") == null);
        const escaped = @as([32]u8, @splat(1));
        for (0..escaped.len + 1) |len| {
            response.len = 0;
            info.doublewrite = escaped[0..len];
            try response.render(host_reply.renderHostInfo, .{info});
            const present = try parseHostInfo(response.slice(), selector);
            try std.testing.expectEqualStrings(escaped[0..len], present.ready.innodb_doublewrite.?.slice());
        }
        response.len = 0;
        info.doublewrite = "";
        try response.render(host_reply.renderHostInfo, .{info});
        const oversized = try std.mem.replaceOwned(u8, std.testing.allocator, response.slice(), "\"innodb_doublewrite\":\"\"", "\"innodb_doublewrite\":\"" ++ (&@as([33]u8, @splat('x'))) ++ "\"");
        defer std.testing.allocator.free(oversized);
        try std.testing.expectError(error.ValueTooLong, parseHostInfo(oversized, selector));
    }
}

test "Host information parses the settings digest only as 64 lowercase hex characters" {
    const host_reply = @import("host_reply.zig");
    const digest: @import("host_settings_handoff.zig").Digest = @splat(0xaa);
    var info: host_reply.HostInfo = .{
        .store = "/sqlite",
        .instance = @splat(1),
        .active_capacity = 2,
        .intake_capacity = 100,
        .descriptor_soft_limit = 1024,
        .started_at = 1792918800,
        .custody_occupied = 0,
        .paused = false,
        .routes = protocol.routesAll(.unserved),
        .doublewrite = null,
        .settings_digest = digest,
    };
    var response: protocol.ResponseBuffer = .{};
    try response.render(host_reply.renderHostInfo, .{info});
    const present = try parseHostInfo(response.slice(), "/sqlite");
    try std.testing.expectEqualSlices(u8, &digest, &present.ready.settings_digest.?);
    const hex = std.fmt.bytesToHex(digest, .lower);
    for ([_][]const u8{ "ABCDEF" ++ (&@as([58]u8, @splat('0'))), &@as([63]u8, @splat('a')), &@as([64]u8, @splat('g')) }) |bad| {
        const body = try std.mem.replaceOwned(u8, std.testing.allocator, response.slice(), &hex, bad);
        defer std.testing.allocator.free(body);
        try std.testing.expectError(error.InvalidHostInfo, parseHostInfo(body, "/sqlite"));
    }
    info.settings_digest = null;
    response.len = 0;
    try response.render(host_reply.renderHostInfo, .{info});
    try std.testing.expect((try parseHostInfo(response.slice(), "/sqlite")).ready.settings_digest == null);
}

test "Host information is bounded and rejects ambiguous identities and capacity" {
    const golden = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"host_info\",\"store\":\"/one\",\"instance\":\"000102030405060708090a0b0c0d0e0f\",\"active_capacity\":\"17\",\"started_at\":\"1792918800\",\"custody_occupied\":\"17\",\"paused\":true,\"capabilities\":{\"bash\":true,\"providers\":{\"codex\":\"unserved\",\"openai\":\"unserved\",\"chatgpt\":\"unserved\"}}}";
    const result = try parseHostInfo(golden, "/one");
    try std.testing.expect(result.ready.store.eql("/one"));
    try std.testing.expectEqual(@as(usize, 17), result.ready.active_capacity);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 }, &result.ready.instance);
    try std.testing.expect(result.ready.capabilities.bash);
    try std.testing.expectEqual(protocol.Route.unserved, result.ready.capabilities.providers.codex);
    try std.testing.expectEqual(@as(u64, 1792918800), result.ready.started_at);
    try std.testing.expectEqual(@as(usize, 17), result.ready.custody_occupied);
    try std.testing.expect(result.ready.paused);
    for ([_][2][]const u8{
        .{ "\"started_at\":\"1792918800\"", "\"started_at\":\"0\"" },
        .{ "\"started_at\":\"1792918800\"", "\"started_at\":\"01792918800\"" },
        .{ "\"started_at\":\"1792918800\"", "\"started_at\":\"9223372036854775808\"" },
        .{ "\"started_at\":\"1792918800\"", "\"started_at\":\"+1792918800\"" },
        .{ "\"custody_occupied\":\"17\"", "\"custody_occupied\":\"18\"" },
        .{ "\"custody_occupied\":\"17\"", "\"custody_occupied\":\"\"" },
        .{ "\"custody_occupied\":\"17\"", "\"custody_occupied\":\"1_7\"" },
    }) |case| {
        const malformed = try std.mem.replaceOwned(u8, std.testing.allocator, golden, case[0], case[1]);
        defer std.testing.allocator.free(malformed);
        try std.testing.expectError(error.InvalidHostInfo, parseHostInfo(malformed, "/one"));
    }
    inline for (.{ "\"started_at\":\"1792918800\",", "\"custody_occupied\":\"17\",", "\"paused\":true," }) |field| {
        const missing = try std.mem.replaceOwned(u8, std.testing.allocator, golden, field, "");
        defer std.testing.allocator.free(missing);
        try std.testing.expectError(error.MissingField, parseHostInfo(missing, "/one"));
    }
    try std.testing.expectError(error.InvalidHostInfo, parseHostInfo(golden, "/other"));
    try std.testing.expectError(error.InvalidHostInfo, parseHostInfo(
        "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"host_info\",\"store\":\"/one\",\"instance\":\"000102030405060708090a0b0c0d0e0F\",\"active_capacity\":\"17\",\"started_at\":\"1792918800\",\"custody_occupied\":\"0\",\"paused\":false,\"capabilities\":{\"bash\":true,\"providers\":{\"codex\":\"unserved\",\"openai\":\"unserved\",\"chatgpt\":\"unserved\"}}}",
        "/one",
    ));
    try std.testing.expectError(error.InvalidHostInfo, parseHostInfo(
        "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"host_info\",\"store\":\"/one\",\"instance\":\"000102030405060708090a0b0c0d0e0f\",\"active_capacity\":\"\",\"started_at\":\"1792918800\",\"custody_occupied\":\"0\",\"paused\":false,\"capabilities\":{\"bash\":true,\"providers\":{\"codex\":\"unserved\",\"openai\":\"unserved\",\"chatgpt\":\"unserved\"}}}",
        "/one",
    ));
    try std.testing.expectError(error.InvalidHostInfo, parseHostInfo(
        "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"host_info\",\"store\":\"/one\",\"instance\":\"000102030405060708090a0b0c0d0e0f\",\"active_capacity\":\"01\",\"started_at\":\"1792918800\",\"custody_occupied\":\"0\",\"paused\":false,\"capabilities\":{\"bash\":true,\"providers\":{\"codex\":\"unserved\",\"openai\":\"unserved\",\"chatgpt\":\"unserved\"}}}",
        "/one",
    ));
    for ([_][]const u8{ "intake_capacity", "descriptor_limit" }) |field| {
        for ([_][]const u8{ "010", "+10", "1_0", "", "18446744073709551616" }) |value| {
            const extra = try std.fmt.allocPrint(std.testing.allocator, "\"{s}\":\"{s}\",\"capabilities\":", .{ field, value });
            defer std.testing.allocator.free(extra);
            const malformed = try std.mem.replaceOwned(u8, std.testing.allocator, golden, "\"capabilities\":", extra);
            defer std.testing.allocator.free(malformed);
            try std.testing.expectError(error.InvalidHostInfo, parseHostInfo(malformed, "/one"));
        }
    }
    const reduced = try std.mem.replaceOwned(u8, std.testing.allocator, golden, "\"capabilities\":", "\"intake_capacity\":\"10\",\"descriptor_limit\":\"0\",\"capabilities\":");
    defer std.testing.allocator.free(reduced);
    const reduced_info = try parseHostInfo(reduced, "/one");
    try std.testing.expectEqual(@as(usize, 10), reduced_info.ready.intake_capacity);
    try std.testing.expectEqual(@as(?usize, 0), reduced_info.ready.descriptor_limit);
    try std.testing.expectEqual(@as(usize, 100), result.ready.intake_capacity);
    try std.testing.expectEqual(@as(?usize, null), result.ready.descriptor_limit);
    for ([_]struct { needle: []const u8, replacement: []const u8 }{
        .{ .needle = "\"store\":\"/one\"", .replacement = "\"store\":\"/other\",\"store\":\"/one\"" },
        .{ .needle = "\"bash\":true", .replacement = "\"bash\":false,\"bash\":true" },
    }) |case| {
        const duplicated = try std.mem.replaceOwned(u8, std.testing.allocator, golden, case.needle, case.replacement);
        defer std.testing.allocator.free(duplicated);
        try std.testing.expectError(error.DuplicateField, parseHostInfo(duplicated, "/one"));
    }
}

const host_info_fields_after_version = ",\"type\":\"host_info\",\"store\":\"/one\",\"instance\":\"000102030405060708090a0b0c0d0e0f\",\"active_capacity\":\"17\",\"intake_capacity\":\"10\",\"descriptor_limit\":\"256\",\"started_at\":\"1792918800\",\"custody_occupied\":\"3\",\"paused\":true,\"capabilities\":{\"bash\":true,\"providers\":{\"codex\":\"endpoint\",\"openai\":\"unserved\",\"chatgpt\":\"unserved\"}}}";
const released_22_host_info = "{\"version\":\"" ++ HostInfoProfile.released_22.wire() ++ "\"" ++ host_info_fields_after_version;
const current_host_info = "{\"version\":\"" ++ protocol.wire_version ++ "\"" ++ host_info_fields_after_version;

test "Host information accepts the released wire-22 shape and requires complete facts" {
    const facts = try parseHostInfoForProfile(released_22_host_info, "/one", .released_22);
    try std.testing.expectEqual(protocol.Route.endpoint, facts.capabilities.providers.codex);
    try std.testing.expectEqual(protocol.Route.unserved, facts.capabilities.providers.openai);
    try std.testing.expectEqual(protocol.Route.unserved, facts.capabilities.providers.chatgpt);
    try std.testing.expectEqualDeep(facts, (try parseHostInfo(current_host_info, "/one")).ready);
    try std.testing.expectError(error.InvalidHostInfo, parseHostInfo(released_22_host_info, "/one"));
    const missing = try std.mem.replaceOwned(u8, std.testing.allocator, released_22_host_info, ",\"chatgpt\":\"unserved\"", "");
    defer std.testing.allocator.free(missing);
    try std.testing.expectError(error.MissingField, parseHostInfoForProfile(missing, "/one", .released_22));

    inline for (@typeInfo(protocol.Routes).@"struct".field_names) |provider| {
        for (std.meta.tags(protocol.Route)) |route| {
            const before = try std.fmt.allocPrint(std.testing.allocator, "\"{s}\":\"{s}\"", .{ provider, @tagName(@field(facts.capabilities.providers, provider)) });
            defer std.testing.allocator.free(before);
            const after = try std.fmt.allocPrint(std.testing.allocator, "\"{s}\":\"{s}\"", .{ provider, @tagName(route) });
            defer std.testing.allocator.free(after);
            const body = try std.mem.replaceOwned(u8, std.testing.allocator, released_22_host_info, before, after);
            defer std.testing.allocator.free(body);
            var expected = facts;
            @field(expected.capabilities.providers, provider) = route;
            try std.testing.expectEqualDeep(expected, try parseHostInfoForProfile(body, "/one", .released_22));
        }
    }
    const samples = [_]struct { body: []const u8, profile: HostInfoProfile }{
        .{ .body = released_22_host_info, .profile = .released_22 },
        .{ .body = current_host_info, .profile = .current },
    };
    for (samples) |sample| {
        const body = sample.body;
        for ([_]struct { from: []const u8, to: []const u8, failure: anyerror }{
            .{ .from = "\"codex\":\"endpoint\",", .to = "", .failure = error.MissingField },
            .{ .from = ",\"openai\":\"unserved\"", .to = "", .failure = error.MissingField },
            .{ .from = "\"codex\":\"endpoint\"", .to = "\"codex\":null", .failure = error.UnexpectedToken },
            .{ .from = "\"openai\":\"unserved\"", .to = "\"openai\":\"unknown\"", .failure = error.InvalidEnumTag },
            .{ .from = "\"codex\":\"endpoint\"", .to = "\"codex\":\"endpoint\",\"codex\":\"unserved\"", .failure = error.DuplicateField },
            .{ .from = "\"openai\":\"unserved\"", .to = "\"openai\":\"unserved\",\"openai\":\"unserved\"", .failure = error.DuplicateField },
            .{ .from = "\"openai\":\"unserved\"", .to = "\"openai\":\"unserved\",\"unknown\":\"unserved\"", .failure = error.UnknownField },
        }) |case| {
            const bad = try std.mem.replaceOwned(u8, std.testing.allocator, body, case.from, case.to);
            defer std.testing.allocator.free(bad);
            try std.testing.expectError(case.failure, parseHostInfoForProfile(bad, "/one", sample.profile));
        }
    }
    for ([_]struct { value: []const u8, failure: anyerror }{
        .{ .value = "\"unknown\"", .failure = error.InvalidEnumTag },
        .{ .value = "null", .failure = error.UnexpectedToken },
        .{ .value = "false", .failure = error.UnexpectedToken },
        .{ .value = "{}", .failure = error.UnexpectedToken },
        .{ .value = "[]", .failure = error.UnexpectedToken },
        .{ .value = "\"unserved\",\"chatgpt\":\"unserved\"", .failure = error.DuplicateField },
    }) |case| {
        const field = try std.fmt.allocPrint(std.testing.allocator, "\"chatgpt\":{s}", .{case.value});
        defer std.testing.allocator.free(field);
        for (samples) |sample| {
            const bad = try std.mem.replaceOwned(u8, std.testing.allocator, sample.body, "\"chatgpt\":\"unserved\"", field);
            defer std.testing.allocator.free(bad);
            try std.testing.expectError(case.failure, parseHostInfoForProfile(bad, "/one", sample.profile));
        }
    }
}

test "upgrade Host information profiles map every wire back to their profile" {
    for (std.enums.values(HostInfoProfile)) |profile| try std.testing.expectEqual(profile, HostInfoProfile.fromWire(profile.wire()).?);
    try std.testing.expectEqual(@as(?HostInfoProfile, null), HostInfoProfile.fromWire("8"));
    try std.testing.expectEqual(@as(?HostInfoProfile, null), HostInfoProfile.fromWire(""));
}

test "WIR-5 released_host_info_profiles" {
    try std.testing.expectEqualStrings(protocol.wire_version, HostInfoProfile.current.wire());
    try std.testing.expectEqualStrings("22", HostInfoProfile.released_22.wire());
    try std.testing.expectEqualStrings("23", HostInfoProfile.released_23.wire());
    try std.testing.expect(HostInfoProfile.released_22.historical());
    try std.testing.expect(!HostInfoProfile.current.historical());
    const facts = try parseHostInfoForProfile(released_22_host_info, "/one", .released_22);
    try std.testing.expect(facts.store.eql("/one"));
    try std.testing.expectEqual(@as(usize, 17), facts.active_capacity);
    try std.testing.expectEqual(@as(usize, 10), facts.intake_capacity);
    try std.testing.expectEqual(@as(?usize, 256), facts.descriptor_limit);
    try std.testing.expectEqual(@as(usize, 3), facts.custody_occupied);
    try std.testing.expectEqual(@as(u64, 1792918800), facts.started_at);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 }, &facts.instance);
    try std.testing.expect(facts.paused and facts.capabilities.bash);
    try std.testing.expectError(error.InvalidHostInfo, parseHostInfoForProfile(released_22_host_info, "/other", .released_22));
    try std.testing.expectError(error.InvalidHostInfo, parseHostInfoForProfile(current_host_info, "/one", .released_22));
    for ([_]struct { from: []const u8, to: []const u8, failure: anyerror }{
        .{ .from = "\"type\":\"host_info\"", .to = "\"type\":\"host_status\"", .failure = error.InvalidHostInfo },
        .{ .from = "\"store\":\"/one\"", .to = "\"store\":\"/one\",\"store\":\"/one\"", .failure = error.DuplicateField },
        .{ .from = "\"paused\":true", .to = "\"paused\":true,\"paused\":false", .failure = error.DuplicateField },
        .{ .from = "\"paused\":true,", .to = "", .failure = error.MissingField },
        .{ .from = "\"paused\":true", .to = "\"paused\":true,\"unknown\":false", .failure = error.UnknownField },
        .{ .from = "000102030405060708090a0b0c0d0e0f", .to = "000102030405060708090a0b0c0d0e0F", .failure = error.InvalidHostInfo },
        .{ .from = "\"active_capacity\":\"17\"", .to = "\"active_capacity\":\"017\"", .failure = error.InvalidHostInfo },
        .{ .from = "\"intake_capacity\":\"10\"", .to = "\"intake_capacity\":\"9\"", .failure = error.InvalidHostInfo },
        .{ .from = "\"descriptor_limit\":\"256\"", .to = "\"descriptor_limit\":\"+256\"", .failure = error.InvalidHostInfo },
        .{ .from = "\"started_at\":\"1792918800\"", .to = "\"started_at\":\"0\"", .failure = error.InvalidHostInfo },
        .{ .from = "\"custody_occupied\":\"3\"", .to = "\"custody_occupied\":\"18\"", .failure = error.InvalidHostInfo },
        .{ .from = "\"codex\":\"endpoint\"", .to = "\"codex\":\"unknown\"", .failure = error.InvalidEnumTag },
    }) |case| {
        const bad = try std.mem.replaceOwned(u8, std.testing.allocator, released_22_host_info, case.from, case.to);
        defer std.testing.allocator.free(bad);
        try std.testing.expectError(case.failure, parseHostInfoForProfile(bad, "/one", .released_22));
    }
    for ([_][]const u8{ "8", protocol.next_wire_version, "09", "unknown", "" }) |wire| {
        const version = try std.fmt.allocPrint(std.testing.allocator, "\"version\":\"{s}\"", .{wire});
        defer std.testing.allocator.free(version);
        const bad = try std.mem.replaceOwned(u8, std.testing.allocator, released_22_host_info, "\"version\":\"" ++ comptime HostInfoProfile.released_22.wire() ++ "\"", version);
        defer std.testing.allocator.free(bad);
        try std.testing.expectError(error.InvalidHostInfo, parseHostInfoForProfile(bad, "/one", .released_22));
    }
}

test "Host unavailable replies require a known complete error" {
    for ([_][]const u8{
        "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"busy\",\"code\":\"connection_capacity_exhausted\"}",
        "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"busy\",\"code\":\"classification_capacity_exhausted\"}",
        "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"busy\",\"code\":\"ordinary_capacity_exhausted\"}",
        "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"busy\",\"code\":\"discovery_capacity_exhausted\"}",
        "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"host_unavailable\",\"code\":\"dispatch_fenced\"}",
    }) |body| try std.testing.expect(validHostUnavailable(body));
    for ([_][]const u8{
        "{}",
        "{\"version\":\"" ++ protocol.next_wire_version ++ "\",\"type\":\"busy\",\"code\":\"ordinary_capacity_exhausted\"}",
        "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"busy\",\"code\":\"dispatch_fenced\"}",
        "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"host_unavailable\",\"code\":\"unknown\"}",
        "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"busy\",\"code\":\"ordinary_capacity_exhausted\",\"code\":\"ordinary_capacity_exhausted\"}",
        "{\"version\":\"" ++ protocol.next_wire_version ++ "\",\"type\":\"busy\",\"code\":\"discovery_capacity_exhausted\"}",
        "{\"version\":\"" ++ protocol.previous_wire_version ++ "\",\"type\":\"busy\",\"code\":\"discovery_capacity_exhausted\"}",
        "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"host_unavailable\",\"code\":\"discovery_capacity_exhausted\"}",
        "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"busy\",\"code\":\"discovery_capacity_exhausted_other\"}",
        "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"busy\",\"nested\":{\"code\":\"discovery_capacity_exhausted\"}}",
        "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"busy\",\"code\":\"discovery_capacity_exhausted\",\"code\":\"discovery_capacity_exhausted\"}",
        "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"busy\",\"code\":\"discovery_capacity_exhausted\"",
    }) |body| try std.testing.expect(!validHostUnavailable(body));
}

pub const CommandReply = struct {
    status: u16,
    body: []const u8,
};

pub const ResultReply = union(enum) {
    answer: struct { bytes: u64 },
    command: CommandReply,
};

pub const ObservationReply = union(enum) {
    observation: struct { facts: CommandObservation, since: ?SessionToken },
    not_modified: SessionToken,
    failure: ReadFailure,

    pub fn parse(reply: CommandReply, key: []const u8, since: ?SessionToken) !ObservationReply {
        if (reply.status != 200) return .{ .failure = try decodeReadFailure(reply, false) };
        const result = try CommandObservation.parseReply(reply, key);
        if (result == .not_modified) {
            const previous = since orelse return error.InvalidObservation;
            const next = result.not_modified;
            if (!std.mem.eql(u8, &previous.instance, &next.instance) or
                !std.mem.eql(u8, &previous.session, &next.session) or next.generation < previous.generation)
                return error.RequestBindingMismatch;
        }
        return result;
    }
};

pub const ResultReadReply = union(enum) {
    answer: struct { bytes: u64 },
    failure: ReadFailure,
};

pub const ReadFailure = struct {
    status: u16,
    diagnostic: InvocationDiagnostic,

    pub fn err(self: ReadFailure) error{ CanonicalStoreFailure, HostInvocationFailed } {
        return if (self.diagnostic.code.eql("canonical_store_failure")) error.CanonicalStoreFailure else error.HostInvocationFailed;
    }
};

pub const ReportReply = union(enum) {
    report: struct { bytes: u64 },
    command: CommandReply,
};

/// A `public_parts` reply captured in a report file. `decode` checks the whole
/// list once; `PartList.iterator` then re-reads it one bounded entry at a time.
pub const PublicPartsReply = union(enum) {
    list: PartList,
    failure: ReadFailure,

    /// What the caller asked for: the owner always, the manifest identity when it holds one.
    pub const Expected = struct { session: []const u8, owner: content_value.Owner, identity: ?content_value.Reference = null };

    /// Validates that the head names the requested Session and owner (and identity, when
    /// given), that ordinals run contiguously from 0, and that kinds and media are known.
    pub fn decode(io: std.Io, file: std.Io.File, reply: ReportReply, expected: Expected) !PublicPartsReply {
        const bytes = switch (reply) {
            .command => |command| return .{ .failure = try decodeReadFailure(command, false) },
            .report => |report| report.bytes,
        };
        if (bytes > protocol.public_parts_reply.max_bytes) return error.InvalidPartList;
        var walk: PartWalk = undefined;
        try walk.open(io, file, bytes);
        const value = try walk.head(expected.session);
        if (!std.meta.eql(value.owner, expected.owner)) return error.InvalidPartList;
        if (expected.identity) |identity| if (!std.meta.eql(identity, value.identity)) return error.InvalidPartList;
        var count: u32 = 0;
        while (try walk.next(count)) |_| count += 1;
        if (count == 0) return error.InvalidPartList;
        try walk.finish();
        return .{ .list = .{ .io = io, .file = file, .bytes = bytes, .count = count, .value = value, .session = expected.session } };
    }
};

pub const PartList = struct {
    io: std.Io,
    file: std.Io.File,
    bytes: u64,
    count: u32,
    value: content_value.Value.Parts,
    session: []const u8,

    /// Restartable: each iterator reads the file from its start.
    pub fn iterator(self: *const PartList, out: *PartIterator) !void {
        out.list = self;
        out.read = 0;
        try out.walk.open(self.io, self.file, self.bytes);
        _ = try out.walk.head(self.session);
    }
};

pub const PartIterator = struct {
    list: *const PartList,
    read: u32,
    walk: PartWalk,

    pub fn next(self: *PartIterator) !?content_value.Part {
        const part = try self.walk.next(self.read) orelse {
            if (self.read != self.list.count) return error.InvalidPartList;
            return null;
        };
        self.read += 1;
        return part;
    }
};

/// One forward pass over a captured `public_parts` reply. Holds pointers into
/// itself, so it is opened in place and never moved.
const PartWalk = struct {
    file_reader: std.Io.File.Reader,
    input: [protocol.content_window_bytes]u8,
    body: std.Io.Reader.Limited,
    reader_storage: [256]u8,
    reader_fixed: std.heap.FixedBufferAllocator,
    value_storage: [2048]u8,
    value_fixed: std.heap.FixedBufferAllocator,
    json: std.json.Reader,

    const WireOwner = struct { message: ?JsonString(20) = null, action: ?JsonString(20) = null };
    const WireValue = struct { type: JsonString(8), bytes: JsonString(20), sha256: JsonString(64), owner: WireOwner };
    const WirePart = struct {
        ordinal: JsonString(20),
        type: JsonString(8),
        bytes: JsonString(20),
        sha256: JsonString(64),
        mime: ?JsonString(16) = null,
        width: ?JsonString(20) = null,
        height: ?JsonString(20) = null,
        name: ?JsonString(input_parts.max_name_bytes) = null,
    };

    fn open(self: *PartWalk, io: std.Io, file: std.Io.File, bytes: u64) !void {
        self.file_reader = file.reader(io, &.{});
        self.body = self.file_reader.interface.limited(.limited64(bytes), &self.input);
        self.reader_fixed = .init(&self.reader_storage);
        self.value_fixed = .init(&self.value_storage);
        self.json = std.json.Reader.init(self.reader_fixed.allocator(), &self.body.interface);
    }

    fn parse(self: *PartWalk, comptime T: type) !T {
        self.value_fixed.reset();
        // innerParse, unlike parseFrom*, does not default the member-name bound.
        return std.json.innerParse(T, self.value_fixed.allocator(), &self.json, .{ .ignore_unknown_fields = false, .max_value_len = input_parts.max_name_bytes }) catch error.InvalidPartList;
    }

    fn key(self: *PartWalk) ![]const u8 {
        self.value_fixed.reset();
        return switch (self.json.nextAlloc(self.value_fixed.allocator(), .alloc_if_needed) catch return error.InvalidPartList) {
            .string, .allocated_string => |name| name,
            else => error.InvalidPartList,
        };
    }

    /// Reads every head member up to and including `"parts":[`, which comes last.
    fn head(self: *PartWalk, session: []const u8) !content_value.Value.Parts {
        if ((self.json.next() catch return error.InvalidPartList) != .object_begin) return error.InvalidPartList;
        const Field = enum { version, type, session, value, parts };
        var seen: std.enums.EnumSet(Field) = .empty;
        var value: ?content_value.Value.Parts = null;
        while (true) {
            const field = std.meta.stringToEnum(Field, try self.key()) orelse return error.InvalidPartList;
            if (seen.contains(field)) return error.InvalidPartList;
            seen.insert(field);
            switch (field) {
                .version => if (!(try self.parse(JsonString(8))).eql(protocol.wire_version)) return error.InvalidPartList,
                .type => if (!(try self.parse(JsonString(16))).eql("public_parts")) return error.InvalidPartList,
                .session => if (!(try self.parse(JsonString(protocol.max_session_bytes))).eql(session)) return error.InvalidPartList,
                .value => value = try decodeValue(try self.parse(WireValue)),
                .parts => {
                    if (seen.count() != std.enums.values(Field).len) return error.InvalidPartList;
                    if ((self.json.next() catch return error.InvalidPartList) != .array_begin) return error.InvalidPartList;
                    return value.?;
                },
            }
        }
    }

    /// The next part, which must carry `ordinal`, or null at the end of the list.
    fn next(self: *PartWalk, ordinal: u32) !?content_value.Part {
        if ((self.json.peekNextTokenType() catch return error.InvalidPartList) == .array_end) return null;
        if (ordinal == input_parts.max_parts) return error.InvalidPartList;
        const wire = try self.parse(WirePart);
        if (try decimal(wire.ordinal, true) != ordinal) return error.InvalidPartList;
        const reference: content_value.Reference = .{ .length = try decimal(wire.bytes, true), .digest = try digest(wire.sha256) };
        if (wire.type.eql("text")) {
            if (wire.mime != null or wire.width != null or wire.height != null or wire.name != null) return error.InvalidPartList;
            return .{ .ordinal = ordinal, .kind = .text, .reference = reference };
        }
        if (!wire.type.eql("image")) return error.InvalidPartList;
        const mime = wire.mime orelse return error.InvalidPartList;
        const format: @import("input_media.zig").Format = if (mime.eql("image/png")) .png else if (mime.eql("image/jpeg")) .jpeg else return error.InvalidPartList;
        const width = try decimal(wire.width orelse return error.InvalidPartList, false);
        const height = try decimal(wire.height orelse return error.InvalidPartList, false);
        if (width > std.math.maxInt(u32) or height > std.math.maxInt(u32)) return error.InvalidPartList;
        const name: ?input_parts.Name = if (wire.name) |text| input_parts.displayName(text.slice()) catch return error.InvalidPartList else null;
        return .{ .ordinal = ordinal, .kind = .{ .image = .{ .media = .{ .format = format, .width = @intCast(width), .height = @intCast(height) }, .name = name } }, .reference = reference };
    }

    fn finish(self: *PartWalk) !void {
        if ((self.json.next() catch return error.InvalidPartList) != .array_end or
            (self.json.next() catch return error.InvalidPartList) != .object_end or
            (self.json.next() catch return error.InvalidPartList) != .end_of_document or
            self.body.remaining != .nothing) return error.InvalidPartList;
    }

    fn decodeValue(wire: WireValue) !content_value.Value.Parts {
        if (!wire.type.eql("parts")) return error.InvalidPartList;
        const owner: content_value.Owner = if (wire.owner.message) |id|
            (if (wire.owner.action != null) return error.InvalidPartList else .{ .message = try decimal(id, false) })
        else
            .{ .action = try decimal(wire.owner.action orelse return error.InvalidPartList, false) };
        return .{ .identity = .{ .length = try decimal(wire.bytes, true), .digest = try digest(wire.sha256) }, .owner = owner };
    }

    fn decimal(text: JsonString(20), allow_zero: bool) !u64 {
        return decimalId(text, allow_zero) catch error.InvalidPartList;
    }

    fn digest(text: JsonString(64)) ![32]u8 {
        var out: [32]u8 = undefined;
        const hex = text.slice();
        if (hex.len != 64) return error.InvalidPartList;
        for (hex) |byte| if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) return error.InvalidPartList;
        _ = std.fmt.hexToBytes(&out, hex) catch return error.InvalidPartList;
        return out;
    }
};

pub const CurrentReply = union(enum) {
    unconfigured,
    current: Current,
    failure: ReadFailure,

    pub fn decode(io: std.Io, file: std.Io.File, session: []const u8, reply: ReportReply) !CurrentReply {
        return switch (reply) {
            .command => |command| .{ .failure = try decodeReadFailure(command, false) },
            .report => |report| Current.read(io, file, report.bytes, session, NoAttention{}) catch return error.InvalidObservation,
        };
    }

    pub fn writeJson(self: *const CurrentReply, io: std.Io, file: std.Io.File, writer: *std.Io.Writer) !void {
        return switch (self.*) {
            .unconfigured => writer.writeAll("{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"session_report\",\"delta\":\"full\",\"since\":null,\"profile\":\"current\",\"session\":null,\"pending_messages\":\"0\",\"execution\":{\"status\":\"unavailable\",\"reason\":\"session_not_found\"}}"),
            .current => |*current| current.writeJson(io, file, writer),
            .failure => |failure| failure.err(),
        };
    }
};

pub const Current = struct {
    pub const Id = ReportNumber(false);
    pub const Count = ReportNumber(true);
    pub const Reference = JsonContentValue;
    pub const Settings = struct {
        reference: JsonString(protocol.max_session_bytes),
        parent: ?JsonString(protocol.session_id_bytes),
        workspace: JsonString(protocol.max_workspace_bytes),
        provider: JsonEnum(protocol.Provider),
        model: JsonString(protocol.max_model_bytes),
        revision: Id,
        tools: ReportTools,
        loaded_tools: ReportTools,
        permission_mode: JsonEnum(enum { ask, bypass }),
        instructions: Reference,
        output_schema: ?Reference,
        compaction_trigger: ?Id,
        context_estimate: OmittableJson(?Count) = .{},
        output_reservation: Count,
        compaction_trigger_override: ?Id,
        output_reservation_override: ?Count,
        reasoning_effort: ?JsonEnum(protocol.ReasoningEffort),
        reasoning_effort_override: ?JsonEnum(protocol.ReasoningEffort),
        label: ?JsonString(protocol.max_label_bytes),
        created_at: Id,

        pub fn jsonStringify(self: Settings, jw: anytype) !void {
            try writeObject(self, jw);
        }
    };
    pub const Work = struct {
        state: JsonWorkState,
        turn: ?Id,
        operation: ?Id,
        first_action: ?Id,
        attention: ?JsonWorkAttention,
        group: JsonEnum(@import("session_work.zig").Group),
        actions: JsonWorkActions,
        latest_outcome: ?struct { code: JsonString(protocol.max_code_bytes), content: ?Reference },

        pub fn jsonStringify(self: Work, jw: anytype) !void {
            try writeObject(self, jw);
        }
    };
    pub const Peers = struct {
        from_person_at: ?Id,

        pub fn jsonStringify(self: Peers, jw: anytype) !void {
            try writeObject(self, jw);
        }
    };
    pub const Recent = struct { turn: Id, message: JsonString(protocol.max_key_bytes), outcome: JsonString(protocol.max_code_bytes) };
    pub const Execution = struct {
        status: JsonEnum(enum { partial, unavailable }),
        reason: OmittableJson(JsonEnum(enum { session_not_found })) = .{},
        dispatch_fenced: OmittableJson(bool) = .{},
        custody_occupied: OmittableJson(Count) = .{},
        scratch_used_bytes: OmittableJson(Count) = .{},
        unavailable: OmittableJson(struct {
            pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
                if (try source.next() != .array_begin) return error.InvalidObservation;
                _ = try std.json.innerParse(JsonEnum(enum { structured_output }), allocator, source, options);
                if (try source.next() != .array_end) return error.InvalidObservation;
                return .{};
            }

            pub fn jsonStringify(_: @This(), jw: anytype) !void {
                try jw.write([_][]const u8{"structured_output"});
            }
        }) = .{},

        pub fn jsonStringify(self: Execution, jw: anytype) !void {
            try writeObject(self, jw);
        }
    };
    pub const Attention = union(enum) {
        unresolved: struct {
            presentation: JsonToolPresentation,
            action: Id,
            parent_operation: Id,
            call_ordinal: Count,
            tool: JsonString(protocol.max_tool_name_bytes),
            server: OmittableJson(JsonString(64)) = .{},
            permission_revision: Id,
            authorization: JsonEnum(enum { pending, bypass, allow_once, core }),
            call_id: Reference,
            arguments: Reference,

            pub fn jsonStringify(self: @This(), jw: anytype) !void {
                try Current.writeObject(self, jw);
            }
        },
        resolved: struct {
            presentation: JsonToolPresentation,
            action: Id,
            parent_operation: Id,
            call_ordinal: Count,
            code: JsonString(32),
            acceptance_position: Id,
            result: Reference,
        },
        rejected: struct {
            presentation: JsonToolPresentation,
            parent_operation: Id,
            call_ordinal: Count,
            code: JsonString(32),
            acceptance_position: Id,
            result: Reference,
            name: Reference,
            call_id: Reference,
            arguments: Reference,
        },
        actionable: struct { action: Id, permission_revision: Id },
    };

    settings: Settings,
    archive_state: protocol.SessionArchiveState = .active,
    pending_messages: u64,
    work: Work,
    peers: Peers,
    first_message: OmittableJson(?JsonFirstMessage) = .{},
    selected_message: ?JsonString(protocol.max_key_bytes),
    recent: [10]Recent,
    recent_count: usize,
    action_total: u64,
    rejected_total: u64,
    actionable_count: u64,
    first_action: ?u64,
    indeterminate_count: u64,
    first_indeterminate: ?u64,
    execution: Execution,
    bytes: u64,

    fn writeObject(value: anytype, jw: anytype) !void {
        try jw.beginObject();
        inline for (comptime std.meta.fieldNames(@TypeOf(value))) |name| {
            const item = @field(value, name);
            const present = if (comptime std.meta.hasFn(@TypeOf(item), "isPresent")) item.isPresent() else true;
            if (present) {
                try jw.objectField(name);
                try jw.write(item);
            }
        }
        try jw.endObject();
    }

    pub fn traverse(self: *const Current, io: std.Io, file: std.Io.File, sink: anytype) !void {
        _ = try read(io, file, self.bytes, self.settings.reference.slice(), sink);
    }

    pub fn writeJson(self: *const Current, io: std.Io, file: std.Io.File, writer: *std.Io.Writer) !void {
        try writer.writeAll("{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"session_report\",\"delta\":\"full\",\"since\":null,\"profile\":\"current\",\"session\":");
        try std.json.Stringify.value(self.settings, .{}, writer);
        try writer.print(",\"archive_state\":\"{s}\",\"pending_messages\":\"{d}\",\"work\":", .{ @tagName(self.archive_state), self.pending_messages });
        try std.json.Stringify.value(self.work, .{}, writer);
        try writer.writeAll(",\"peers\":");
        try std.json.Stringify.value(self.peers, .{}, writer);
        if (self.first_message.value) |first| {
            try writer.writeAll(",\"first_message\":");
            try std.json.Stringify.value(first, .{}, writer);
        }
        try writer.writeAll(",\"selected_message\":");
        try std.json.Stringify.value(self.selected_message, .{}, writer);
        try writer.writeAll(",\"recent_messages\":");
        try std.json.Stringify.value(self.recent[0..self.recent_count], .{}, writer);
        try writer.print(",\"actions\":{{\"count\":\"{d}\",\"unresolved\":", .{self.action_total});
        try self.writeArray(io, file, .unresolved, writer);
        try writer.writeAll(",\"resolved\":");
        try self.writeArray(io, file, .resolved, writer);
        try writer.print("}},\"rejected_calls\":{{\"count\":\"{d}\",\"items\":", .{self.rejected_total});
        try self.writeArray(io, file, .rejected, writer);
        try writer.writeAll("},\"actionable_permissions\":");
        try self.writeArray(io, file, .actionable, writer);
        try writer.writeAll(",\"execution\":");
        try std.json.Stringify.value(self.execution, .{}, writer);
        try writer.writeAll("}");
    }

    fn writeArray(self: *const Current, io: std.Io, file: std.Io.File, tag: std.meta.Tag(Attention), writer: *std.Io.Writer) !void {
        const Sink = struct {
            writer: *std.Io.Writer,
            tag: std.meta.Tag(Attention),
            first: bool = true,
            fn visit(sink: *@This(), item: Attention) !void {
                switch (item) {
                    inline else => |row, kind| if (kind == sink.tag) {
                        if (!sink.first) try sink.writer.writeAll(",");
                        try std.json.Stringify.value(row, .{}, sink.writer);
                        sink.first = false;
                    },
                }
            }
        };
        var sink: Sink = .{ .writer = writer, .tag = tag };
        try writer.writeAll("[");
        try self.traverse(io, file, &sink);
        try writer.writeAll("]");
    }

    fn read(io: std.Io, file: std.Io.File, bytes: u64, session: []const u8, sink: anytype) !CurrentReply {
        const RecentRows = struct {
            rows: [10]Recent = undefined,
            count: usize = 0,
            pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
                if (try source.next() != .array_begin) return error.InvalidObservation;
                var result: @This() = .{};
                while (try source.peekNextTokenType() != .array_end) {
                    if (result.count == result.rows.len) return error.InvalidObservation;
                    const row = try std.json.innerParse(Recent, allocator, source, options);
                    if (row.outcome.slice().len == 0) return error.InvalidObservation;
                    for (result.rows[0..result.count]) |prior| if (prior.message.eql(row.message.slice())) return error.InvalidObservation;
                    result.rows[result.count] = row;
                    result.count += 1;
                }
                _ = try source.next();
                return result;
            }
        };
        const Wire = struct {
            version: JsonString(8),
            type: JsonEnum(enum { session_report }),
            profile: JsonEnum(enum { current }),
            delta: JsonEnum(enum { full }),
            since: ?JsonString(SessionToken.max_bytes),
            session: ?Settings,
            archive_state: OmittableJson(JsonEnum(protocol.SessionArchiveState)) = .{},
            pending_messages: Count,
            work: OmittableJson(Work) = .{},
            peers: OmittableJson(Peers) = .{},
            first_message: OmittableJson(?JsonFirstMessage) = .{},
            selected_message: OmittableJson(?JsonString(protocol.max_key_bytes)) = .{},
            recent_messages: OmittableJson(RecentRows) = .{},
            actions: OmittableJson(struct { count: Count, unresolved: AttentionRows(.unresolved), resolved: AttentionRows(.resolved) }) = .{},
            rejected_calls: OmittableJson(struct { count: Count, items: AttentionRows(.rejected) }) = .{},
            actionable_permissions: OmittableJson(AttentionRows(.actionable)) = .{},
            execution: Execution,
        };
        if (bytes == 0) return error.InvalidObservation;
        var input: [protocol.content_window_bytes]u8 = undefined;
        var file_reader = file.reader(io, &.{});
        var body = file_reader.interface.limited(.limited64(bytes), &input);
        var scanner_storage: [protocol.content_window_bytes]u8 = undefined;
        var scanner_allocator = std.heap.FixedBufferAllocator.init(&scanner_storage);
        var token_storage: [2 * protocol.max_workspace_bytes]u8 = undefined;
        var token_allocator = std.heap.FixedBufferAllocator.init(&token_storage);
        var reader = std.json.Reader.init(scanner_allocator.allocator(), &body.interface);
        defer reader.deinit();
        var source: CurrentSource(@TypeOf(sink)) = .{ .reader = &reader, .sink = sink };
        const wire = try std.json.parseFromTokenSourceLeaky(Wire, token_allocator.allocator(), &source, .{ .ignore_unknown_fields = true });
        if (body.remaining != .nothing or !wire.version.eql(protocol.wire_version) or wire.since != null) return error.InvalidObservation;
        const execution = wire.execution;
        const settings = wire.session orelse {
            if (wire.pending_messages.value != 0 or execution.status.value != .unavailable or execution.reason.value == null or
                execution.dispatch_fenced.value != null or execution.custody_occupied.value != null or execution.scratch_used_bytes.value != null or execution.unavailable.value != null or
                wire.archive_state.isPresent() or wire.work.value != null or wire.peers.value != null or wire.first_message.value != null or wire.selected_message.value != null or wire.recent_messages.value != null or wire.actions.value != null or
                wire.rejected_calls.value != null or wire.actionable_permissions.value != null) return error.InvalidObservation;
            return .unconfigured;
        };
        if (!protocol.validSessionId(settings.reference.slice()) or !settings.reference.eql(session) or !std.fs.path.isAbsolute(settings.workspace.slice()) or settings.model.slice().len == 0 or
            (if (settings.parent) |parent| !protocol.validSessionId(parent.slice()) or parent.eql(session) else false) or
            (if (settings.label) |label| !protocol.validLabel(label.slice()) else false) or
            (if (settings.context_estimate.value) |estimate| estimate != null and settings.compaction_trigger == null else false) or
            settings.instructions.value != .text or (if (settings.output_schema) |schema| schema.value != .text else false) or
            execution.status.value != .partial or execution.reason.value != null or execution.dispatch_fenced.value == null or
            execution.custody_occupied.value == null or execution.scratch_used_bytes.value == null or execution.unavailable.value == null) return error.InvalidObservation;
        const work = wire.work.value orelse return error.InvalidObservation;
        const peers = wire.peers.value orelse return error.InvalidObservation;
        if ((work.turn == null) != (work.operation == null) or (work.latest_outcome != null and work.turn == null)) return error.InvalidObservation;
        if (work.latest_outcome) |outcome| {
            if (outcome.code.slice().len == 0 or (if (outcome.content) |content| content.value != .text else false)) return error.InvalidObservation;
        }
        const recent = wire.recent_messages.value orelse return error.InvalidObservation;
        const actions = wire.actions.value orelse return error.InvalidObservation;
        const rejected = wire.rejected_calls.value orelse return error.InvalidObservation;
        const actionable = wire.actionable_permissions.value orelse return error.InvalidObservation;
        if (rejected.count.value != rejected.items.count or actions.count.value < actions.unresolved.count + actions.resolved.count or actionable.count > actions.unresolved.count) return error.InvalidObservation;
        return .{ .current = .{
            .settings = settings,
            .archive_state = (wire.archive_state.value orelse return error.InvalidObservation).value,
            .pending_messages = wire.pending_messages.value,
            .work = work,
            .peers = peers,
            .first_message = wire.first_message,
            .selected_message = wire.selected_message.value orelse return error.InvalidObservation,
            .recent = recent.rows,
            .recent_count = recent.count,
            .action_total = actions.count.value,
            .rejected_total = rejected.count.value,
            .actionable_count = actionable.count,
            .first_action = actionable.first,
            .indeterminate_count = actions.resolved.indeterminate,
            .first_indeterminate = actions.resolved.first_indeterminate,
            .execution = execution,
            .bytes = bytes,
        } };
    }
};

const NoAttention = struct {
    fn visit(_: @This(), _: Current.Attention) !void {}
};

fn ReportNumber(comptime allow_zero: bool) type {
    return struct {
        value: u64,
        pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
            const text = try JsonString(20).jsonParse(allocator, source, options);
            const value = try decimalId(text, allow_zero);
            if (value > std.math.maxInt(i64)) return error.InvalidObservation;
            return .{ .value = value };
        }

        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            var bytes: [20]u8 = undefined;
            try jw.write(std.fmt.bufPrint(&bytes, "{d}", .{self.value}) catch unreachable);
        }
    };
}

const ReportTools = struct {
    names: protocol.ToolsField = .{ .state = .value },
    set: protocol.ToolSelection = .empty,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !ReportTools {
        if (try source.next() != .array_begin) return error.UnexpectedToken;
        var result: ReportTools = .{};
        while (try source.peekNextTokenType() != .array_end) {
            const name = try std.json.innerParse(JsonString(protocol.max_tool_name_bytes), allocator, source, options);
            result.names.append(name.slice()) catch |err| return switch (err) {
                error.InvalidToolName => error.InvalidCharacter,
                error.InvalidJsonShape => error.UnexpectedToken,
            };
            if (protocol.builtInTool(name.slice())) |tool| result.set.insert(tool);
        }
        _ = try source.next();
        return result;
    }

    pub fn jsonStringify(self: ReportTools, jw: anytype) !void {
        try jw.beginArray();
        var names = self.names.iterator();
        while (names.next()) |name| try jw.write(name);
        try jw.endArray();
    }
};

fn CurrentSource(comptime Sink: type) type {
    return struct {
        reader: *std.json.Reader,
        sink: Sink,
        pub const NextError = anyerror;
        pub const PeekError = anyerror;
        pub const AllocError = anyerror;
        pub fn next(self: *@This()) !std.json.Token {
            return self.reader.next();
        }
        pub fn peekNextTokenType(self: *@This()) !std.json.TokenType {
            return self.reader.peekNextTokenType();
        }
        pub fn nextAllocMax(self: *@This(), allocator: std.mem.Allocator, when: std.json.AllocWhen, limit: usize) !std.json.Token {
            return self.reader.nextAllocMax(allocator, when, limit);
        }
        pub fn skipValue(self: *@This()) !void {
            return self.reader.skipValue();
        }
    };
}

fn AttentionRows(comptime tag: std.meta.Tag(Current.Attention)) type {
    return struct {
        count: u64 = 0,
        first: ?u64 = null,
        indeterminate: u64 = 0,
        first_indeterminate: ?u64 = null,
        pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
            if (try source.next() != .array_begin) return error.InvalidObservation;
            var result: @This() = .{};
            while (try source.peekNextTokenType() != .array_end) {
                const row = try std.json.innerParse(@FieldType(Current.Attention, @tagName(tag)), allocator, source, options);
                inline for (comptime std.meta.fieldNames(@TypeOf(row))) |name| {
                    // Only a resolved Action's result can be a parts value; call fields and rejections are model text.
                    const parts_allowed = tag == .resolved and comptime std.mem.eql(u8, name, "result");
                    if (@FieldType(@TypeOf(row), name) == Current.Reference and !parts_allowed and @field(row, name).value != .text) return error.InvalidObservation;
                }
                if ((tag == .resolved or tag == .rejected) and row.code.slice().len == 0) return error.InvalidObservation;
                if (tag == .unresolved) {
                    if (!protocol.validToolName(row.tool.slice())) return error.InvalidObservation;
                    if (row.server.value) |server| {
                        if (!protocol.validToolName(server.slice()) or std.meta.stringToEnum(protocol.BuiltInTool, row.tool.slice()) != null) return error.InvalidObservation;
                    }
                    const p = row.presentation.value;
                    if (p.publication_position != null or p.code != (if (row.authorization.value == .pending) protocol.ToolPresentation.Code.pending_permission else .unresolved)) return error.InvalidObservation;
                }
                if (tag == .resolved or tag == .rejected) {
                    const p = row.presentation.value;
                    if (!std.mem.eql(u8, @tagName(p.code), row.code.slice())) return error.InvalidObservation;
                    if (p.publication_position) |position| if (position < row.acceptance_position.value) return error.InvalidObservation;
                }
                if (tag != .rejected) {
                    if (result.first == null) result.first = row.action.value;
                }
                if (tag == .resolved and row.code.eql("indeterminate")) {
                    result.indeterminate += 1;
                    if (result.first_indeterminate == null) result.first_indeterminate = row.action.value;
                }
                try source.sink.visit(@unionInit(Current.Attention, @tagName(tag), row));
                result.count += 1;
            }
            _ = try source.next();
            return result;
        }
    };
}

pub const SessionListCursor = struct {
    after: u64 = 0,
    ceiling: u64 = 0,
    since: ?protocol.SinceToken = null,
    changed: ?protocol.ListSessions.ChangedCursor = null,

    pub fn validate(self: SessionListCursor) !void {
        const request: protocol.ListSessions = .{ .after = self.after, .ceiling = self.ceiling, .since = self.since, .changed = self.changed };
        try request.validate();
    }
};

pub const SessionTraversal = struct {
    cursor: SessionListCursor,
    delta: protocol.ListDelta = .full,
    since: ?protocol.SinceToken = null,
    /// The archive filter of the whole walk, set once when the walk starts and kept across its pages.
    archive: protocol.SessionArchiveFilter = .active,

    pub fn init(since: ?protocol.SinceToken) SessionTraversal {
        return .{ .cursor = .{ .since = since } };
    }

    pub fn restarts(self: *const SessionTraversal, page: *const SessionListPage) bool {
        return self.since != null and self.delta != .full and page.delta == .full;
    }

    pub fn advance(self: *SessionTraversal, page: *const SessionListPage) bool {
        if (self.since == null or self.restarts(page)) {
            self.delta = page.delta;
            self.since = page.since;
        }
        self.cursor = page.next orelse return false;
        return true;
    }
};

pub const SessionListReply = union(enum) {
    page: SessionListPage,
    failure: ReadFailure,

    pub fn decode(io: std.Io, file: std.Io.File, workspace: ?[]const u8, cursor: SessionListCursor, reply: ReportReply) !SessionListReply {
        return switch (reply) {
            .report => |report| .{ .page = try SessionListPage.read(io, file, report.bytes, workspace, cursor) },
            .command => |command| .{ .failure = try decodeReadFailure(command, false) },
        };
    }
};

pub const SessionListPage = struct {
    pub const Row = protocol.SessionRow;

    const JsonRow = struct {
        value: Row,

        pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !JsonRow {
            const Wire = struct {
                read_version: JsonString(protocol.SinceToken.max_bytes),
                archive_state: JsonEnum(protocol.SessionArchiveState),
                pin_order: ?JsonString(20),
                reference: JsonString(protocol.max_session_bytes),
                // The Archived key. Live rows carry null; the overview does not read it until the Archived window client.
                archive_seq: ?JsonString(20),
                parent: ?JsonString(protocol.session_id_bytes),
                creator: ?JsonString(protocol.session_id_bytes),
                workspace: JsonString(protocol.max_workspace_bytes),
                provider: JsonEnum(protocol.Provider),
                model: JsonString(protocol.max_model_bytes),
                tools: ReportTools,
                permission_mode: JsonEnum(protocol.PermissionMode),
                label: ?JsonString(protocol.max_label_bytes),
                created_at: JsonString(20),
                state_change_at: JsonString(20),
                subtree_state_change_at: JsonString(20),
                descendant_count: JsonString(20),
                descendant_needs_you_count: JsonString(20),
                revision: JsonString(20),
                end: JsonString(20),
                first_message: ?JsonFirstMessage,
                last_line: ?struct { position: JsonString(20), text: ?JsonString(session_list.max_last_line_bytes) },
                work: struct { state: JsonWorkState, turn: ?JsonString(20), operation: ?JsonString(20), first_action: ?JsonString(20), attention: ?JsonWorkAttention, group: JsonEnum(@import("session_work.zig").Group), actions: JsonWorkActions },
                peers: struct { from_person_at: ?JsonString(20) },
            };
            const wire = try std.json.innerParse(Wire, allocator, source, options);
            return .{ .value = decode(wire) catch return error.InvalidCharacter };
        }

        fn decode(wire: anytype) !Row {
            if (!protocol.validSessionId(wire.reference.slice()) or wire.workspace.value.len == 0 or wire.model.value.len == 0) return error.InvalidCharacter;
            if (wire.parent) |parent| if (!protocol.validSessionId(parent.slice()) or parent.eql(wire.reference.slice())) return error.InvalidCharacter;
            if (wire.creator) |creator| if (!protocol.validSessionId(creator.slice()) or creator.eql(wire.reference.slice())) return error.InvalidCharacter;
            if (wire.label) |label| if (!protocol.validLabel(label.slice())) return error.InvalidCharacter;
            var row: Row = .{
                .read_version = try protocol.SinceToken.parse(wire.read_version.slice()),
                .archive_state = wire.archive_state.value,
                .pin_order = if (wire.pin_order) |rank| try ActivityPage.id(rank, false) else null,
                .reference = wire.reference.value,
                .archive_seq = if (wire.archive_seq) |key| try ActivityPage.id(key, false) else null,
                .parent = if (wire.parent) |parent| parent.value else null,
                .creator = if (wire.creator) |creator| creator.value else null,
                .workspace = wire.workspace.value,
                .provider = wire.provider.value,
                .model = wire.model.value,
                .tools = wire.tools.names,
                .permission_mode = wire.permission_mode.value,
                .label = if (wire.label) |label| label.value else null,
                .created_at = try ActivityPage.id(wire.created_at, false),
                .state_change_at = try ActivityPage.id(wire.state_change_at, false),
                .subtree_state_change_at = try ActivityPage.id(wire.subtree_state_change_at, false),
                .descendant_count = try ActivityPage.id(wire.descendant_count, true),
                .descendant_needs_you_count = try ActivityPage.id(wire.descendant_needs_you_count, true),
                .revision = try ActivityPage.id(wire.revision, false),
                .end = try ActivityPage.id(wire.end, true),
                .work = .{
                    .state = wire.work.state.value,
                    .turn = if (wire.work.turn) |turn| try ActivityPage.id(turn, false) else null,
                    .operation = if (wire.work.operation) |operation| try ActivityPage.id(operation, false) else null,
                    .first_action = if (wire.work.first_action) |action| try ActivityPage.id(action, false) else null,
                    .attention = try readWorkAttention(wire.work.attention),
                    .group = wire.work.group.value,
                    .actions = try readWorkActions(wire.work.actions),
                },
                .peers = .{ .from_person_at = if (wire.peers.from_person_at) |at| try ActivityPage.id(at, false) else null },
            };
            if (row.state_change_at < row.created_at or row.subtree_state_change_at < row.state_change_at or row.descendant_needs_you_count > row.descendant_count) return error.InvalidCharacter;
            if ((row.archive_state == .active) != (row.archive_seq == null)) return error.InvalidCharacter;
            if (wire.first_message) |first| row.first_message = first.value;
            if (wire.last_line) |last| {
                row.last_line = .{ .position = try ActivityPage.id(last.position, false), .text = if (last.text) |text| text.value else null };
                if (row.last_line.?.position > row.end) return error.InvalidCharacter;
            }
            const work = row.work;
            if ((work.turn == null) != (work.operation == null)) return error.InvalidCharacter;
            if (row.first_message) |first| {
                if (first.position > row.end) return error.InvalidCharacter;
                if (first.sender == null and row.peers.from_person_at == null) return error.InvalidCharacter;
            } else if (row.peers.from_person_at != null or work.turn != null) return error.InvalidCharacter;
            return row;
        }
    };

    rows: [protocol.session_list_page_size]Row = undefined,
    count: usize = 0,
    delta: protocol.ListDelta = .full,
    since: protocol.SinceToken = .{ .instance = @splat(0), .generation = 0 },
    next: ?SessionListCursor = null,

    pub fn read(io: std.Io, file: std.Io.File, bytes: u64, workspace: ?[]const u8, cursor: SessionListCursor) !SessionListPage {
        if (bytes == 0 or bytes > protocol.session_list_reply.max_bytes) return error.InvalidSessionPage;
        cursor.validate() catch return error.InvalidSessionPage;
        const Rows = JsonArray(JsonRow, protocol.session_list_page_size);
        const Wire = struct {
            version: JsonString(8),
            type: JsonString(32),
            sessions: Rows,
            delta: JsonEnum(protocol.ListDelta),
            since: JsonString(protocol.SinceToken.max_bytes),
            next: ?struct {
                after: ?JsonString(20) = null,
                ceiling: ?JsonString(20) = null,
                through: ?JsonString(20) = null,
                after_reference: ?JsonString(protocol.max_session_bytes) = null,
            },
        };
        var input_buffer: [protocol.content_window_bytes]u8 = undefined;
        var file_reader = file.reader(io, &.{});
        var body = file_reader.interface.limited(.limited64(bytes), &input_buffer);
        var storage: [2 * protocol.max_workspace_bytes + protocol.content_window_bytes]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&storage);
        var reader = std.json.Reader.init(fixed.allocator(), &body.interface);
        defer reader.deinit();
        const wire = std.json.parseFromTokenSourceLeaky(Wire, fixed.allocator(), &reader, .{ .ignore_unknown_fields = true }) catch return error.InvalidSessionPage;
        if (body.remaining != .nothing) return error.InvalidSessionPage;
        if (!wire.version.eql(protocol.wire_version) or !wire.type.eql("session_list")) return error.InvalidSessionPage;
        var result: SessionListPage = .{
            .count = wire.sessions.count,
            .delta = wire.delta.value,
            .since = protocol.SinceToken.parse(wire.since.slice()) catch return error.InvalidSessionPage,
        };
        for (result.rows[0..result.count], wire.sessions.slice()) |*row, json| row.* = json.value;
        for (result.rows[0..result.count], 0..) |*row, index| {
            if (workspace) |scope| if (!row.workspace.eql(scope)) return error.InvalidSessionPage;
            for (result.rows[0..index]) |*previous| if (previous.reference.eql(row.reference.slice())) return error.InvalidSessionPage;
        }
        switch (result.delta) {
            // A roster request never asks for a window, so a window reply is not this request's answer.
            .window => return error.InvalidSessionPage,
            .not_modified => {
                const since = cursor.since orelse return error.InvalidSessionPage;
                if (cursor.changed != null or result.count != 0 or wire.next != null or
                    !std.meta.eql(since, result.since)) return error.InvalidSessionPage;
            },
            .changed => {
                const since = cursor.since orelse return error.InvalidSessionPage;
                if (!std.mem.eql(u8, &since.instance, &result.since.instance) or result.since.generation < since.generation) return error.InvalidSessionPage;
                if (cursor.changed) |changed| if (result.since.generation != changed.through) return error.InvalidSessionPage;
                for (result.rows[0..result.count], 0..) |*row, index| {
                    const previous: ?[]const u8 = if (index != 0) result.rows[index - 1].reference.slice() else if (cursor.changed) |*changed| &changed.after_reference else null;
                    if (previous) |reference| if (std.mem.order(u8, reference, row.reference.slice()) != .lt) return error.InvalidSessionPage;
                }
                if (wire.next) |next| {
                    if (next.after != null or next.ceiling != null or result.count != protocol.session_list_page_size) return error.InvalidSessionPage;
                    const through = decimalId(next.through orelse return error.InvalidSessionPage, true) catch return error.InvalidSessionPage;
                    const reference = next.after_reference orelse return error.InvalidSessionPage;
                    if (through != result.since.generation or !reference.eql(result.rows[result.count - 1].reference.slice())) return error.InvalidSessionPage;
                    result.next = .{ .since = since, .changed = .{ .through = through, .after_reference = reference.value.bytes[0..protocol.session_id_bytes].* } };
                }
            },
            .full => {
                const keyset: SessionListCursor = if (cursor.since == null) cursor else .{};
                if (keyset.after != 0 and keyset.after == keyset.ceiling and result.count != 0) return error.InvalidSessionPage;
                if (wire.next) |next| {
                    if (next.through != null or next.after_reference != null) return error.InvalidSessionPage;
                    const after = decimalId(next.after orelse return error.InvalidSessionPage, false) catch return error.InvalidSessionPage;
                    const ceiling = decimalId(next.ceiling orelse return error.InvalidSessionPage, false) catch return error.InvalidSessionPage;
                    if (result.count != protocol.session_list_page_size or after <= keyset.after or after >= ceiling or
                        ceiling > std.math.maxInt(i64) or (keyset.after != 0 and ceiling != keyset.ceiling)) return error.InvalidSessionPage;
                    result.next = .{ .after = after, .ceiling = ceiling };
                }
            },
        }
        return result;
    }

    pub fn writeJson(self: *const SessionListPage, writer: *std.Io.Writer) !void {
        try writer.writeAll("{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"session_list\",\"sessions\":[");
        try self.writeRowsJson(writer);
        var token: [protocol.SinceToken.max_bytes]u8 = undefined;
        try writer.print("],\"delta\":\"{t}\",\"since\":\"{s}\",\"next\":", .{ self.delta, self.since.format(&token) });
        if (self.next) |next| {
            if (next.changed) |changed|
                try writer.print("{{\"through\":\"{d}\",\"after_reference\":\"{s}\"}}}}", .{ changed.through, &changed.after_reference })
            else
                try writer.print("{{\"after\":\"{d}\",\"ceiling\":\"{d}\"}}}}", .{ next.after, next.ceiling });
        } else try writer.writeAll("null}");
    }

    pub fn writeRowsJson(self: *const SessionListPage, writer: *std.Io.Writer) !void {
        for (self.rows[0..self.count], 0..) |*row, index| {
            if (index != 0) try writer.writeAll(",");
            try row.writeJson(writer);
        }
    }
};

/// One Archived window page (`delta` "window"): slim rows, newest archive first, with the page's edge keys.
pub const ArchivedWindowPage = struct {
    /// One slim row: the same decoder the wire shape is tested through (`ArchivedRowRead`).
    pub const Row = ArchivedRowRead;

    const Rows = JsonArray(ArchivedRowRead, session_list.archived_window_size);

    rows: [session_list.archived_window_size]Row = undefined,
    count: usize = 0,
    since: protocol.SinceToken = .{ .instance = @splat(0), .generation = 0 },
    first: ?u64 = null,
    last: ?u64 = null,
    more_above: bool = false,
    more_below: bool = false,

    /// Reads the reply to `window` and refuses anything the Host could not have answered for that cursor.
    pub fn read(io: std.Io, file: std.Io.File, bytes: u64, cursor: session_list.ArchivedCursor) !ArchivedWindowPage {
        if (bytes == 0 or bytes > protocol.session_list_reply.max_bytes) return error.InvalidSessionPage;
        const Wire = struct {
            version: JsonString(8),
            type: JsonString(32),
            sessions: Rows,
            delta: JsonEnum(protocol.ListDelta),
            since: JsonString(protocol.SinceToken.max_bytes),
            next: ?struct {
                first: ?JsonString(20) = null,
                last: ?JsonString(20) = null,
                more_above: bool,
                more_below: bool,
            },
        };
        var input_buffer: [protocol.content_window_bytes]u8 = undefined;
        var file_reader = file.reader(io, &.{});
        var body = file_reader.interface.limited(.limited64(bytes), &input_buffer);
        var storage: [2 * protocol.max_workspace_bytes + protocol.content_window_bytes]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&storage);
        var reader = std.json.Reader.init(fixed.allocator(), &body.interface);
        defer reader.deinit();
        const wire = std.json.parseFromTokenSourceLeaky(Wire, fixed.allocator(), &reader, .{ .ignore_unknown_fields = true }) catch return error.InvalidSessionPage;
        if (body.remaining != .nothing) return error.InvalidSessionPage;
        if (!wire.version.eql(protocol.wire_version) or !wire.type.eql("session_list")) return error.InvalidSessionPage;
        if (wire.delta.value != .window) return error.InvalidSessionPage;
        const next = wire.next orelse return error.InvalidSessionPage;
        var result: ArchivedWindowPage = .{
            .count = wire.sessions.count,
            .since = protocol.SinceToken.parse(wire.since.slice()) catch return error.InvalidSessionPage,
            .more_above = next.more_above,
            .more_below = next.more_below,
        };
        for (result.rows[0..result.count], wire.sessions.slice()) |*row, json| row.* = json;
        for (result.rows[0..result.count], 0..) |*row, index| {
            if (index != 0 and row.archive_seq >= result.rows[index - 1].archive_seq) return error.InvalidSessionPage;
            if (row.archive_seq == 0 or row.archive_seq > std.math.maxInt(i64)) return error.InvalidSessionPage;
            for (result.rows[0..index]) |*previous| if (previous.reference.eql(row.reference.slice())) return error.InvalidSessionPage;
        }
        if (result.count != 0) {
            result.first = result.rows[0].archive_seq;
            result.last = result.rows[result.count - 1].archive_seq;
        }
        if ((next.first != null) != (result.count != 0) or (next.last != null) != (result.count != 0)) return error.InvalidSessionPage;
        if (next.first) |first| if (try ActivityPage.id(first, false) != result.first.?) return error.InvalidSessionPage;
        if (next.last) |last| if (try ActivityPage.id(last, false) != result.last.?) return error.InvalidSessionPage;
        // The page's side is fixed by the cursor: head has nothing above it, tail nothing below, and a keyed
        // read keeps every row on its own side of the key.
        switch (cursor) {
            .head => if (result.more_above) return error.InvalidSessionPage,
            .tail => if (result.more_below) return error.InvalidSessionPage,
            .below => |key| {
                if (!result.more_above) return error.InvalidSessionPage;
                for (result.rows[0..result.count]) |row| if (row.archive_seq >= key) return error.InvalidSessionPage;
            },
            .above => |key| {
                if (!result.more_below) return error.InvalidSessionPage;
                for (result.rows[0..result.count]) |row| if (row.archive_seq <= key) return error.InvalidSessionPage;
            },
        }
        return result;
    }
};

pub const ArchivedWindowReply = union(enum) {
    page: ArchivedWindowPage,
    failure: ReadFailure,

    pub fn decode(io: std.Io, file: std.Io.File, cursor: session_list.ArchivedCursor, reply: ReportReply) !ArchivedWindowReply {
        return switch (reply) {
            .report => |report| .{ .page = try ArchivedWindowPage.read(io, file, report.bytes, cursor) },
            .command => |command| .{ .failure = try decodeReadFailure(command, false) },
        };
    }
};

pub fn validateIdentityInputs(key: []const u8, session: []const u8) !void {
    if (key.len > protocol.max_key_bytes or !std.unicode.utf8ValidateSlice(key)) return error.InvalidKey;
    if (!protocol.validSessionId(session)) return error.InvalidSession;
}

pub const MessageAddress = struct {
    store: protocol.Bounded(protocol.max_store_bytes) = .{},
    session: protocol.Bounded(protocol.max_session_bytes) = .{},
    key: protocol.Bounded(protocol.max_key_bytes) = .{},

    pub fn init(store: []const u8, session: []const u8, key: []const u8) !MessageAddress {
        try validateIdentityInputs(key, session);
        var address: MessageAddress = .{};
        try address.store.set(store);
        try address.session.set(session);
        try address.key.set(key);
        return address;
    }
};

const JsonWorkAttention = struct {
    kind: JsonEnum(@FieldType(@import("session_work.zig").Attention, "kind")),
    turn: JsonString(20),
    step: JsonString(20),
};
const JsonWorkActions = struct {
    stop: bool,
    interrupt: ?struct { turn: JsonString(20), operation: JsonString(20) },
    decide: ?JsonString(20),
};
fn readWorkAttention(value: ?JsonWorkAttention) !?@import("session_work.zig").Attention {
    const v = value orelse return null;
    return .{ .kind = v.kind.value, .turn = try ActivityPage.id(v.turn, true), .step = try decimalId(v.step, true) };
}
fn readWorkActions(v: JsonWorkActions) !@import("session_work.zig").Actions {
    return .{ .stop = v.stop, .interrupt = if (v.interrupt) |target| .{ .turn = try ActivityPage.id(target.turn, false), .operation = try ActivityPage.id(target.operation, false) } else null, .decide = if (v.decide) |action| try ActivityPage.id(action, false) else null };
}

pub const CommandObservation = struct {
    key: protocol.Bounded(protocol.max_key_bytes),
    status: enum { absent, accepted, rejected },
    kind: ?protocol.CommandKind = null,
    target: ?protocol.Bounded(protocol.max_session_bytes) = null,
    code: ?protocol.Bounded(protocol.max_code_bytes) = null,
    revision: ?u64 = null,
    created: ?bool = null,
    input: ?content_value.Value = null,
    state: ?protocol.MessageRequestState = null,
    queue: ?struct { admission: u64, admitted_at: u64 } = null,
    binding: ?struct { turn: u64, operation: u64, attempt: u64 } = null,
    result: ?struct { status: enum { completed, failed, cancelled }, code: ?protocol.Bounded(protocol.max_code_bytes), text: ?ContentReference } = null,
    work: ?struct { state: protocol.WorkState, first_action: ?u64, attention: ?@import("session_work.zig").Attention, group: @import("session_work.zig").Group, actions: @import("session_work.zig").Actions } = null,
    recovery: ?Recovery = null,
    selection: ?struct { turn: ?u64, admission_cutoff: u64 } = null,
    archived: ?bool = null,
    pinned: ?bool = null,
    completion: ?protocol.SessionStopCompletion = null,
    interruption_target: ?struct { session: protocol.Bounded(protocol.max_session_bytes), turn: u64, operation: u64 } = null,
    permission_target: ?struct { action: u64, decision: protocol.PermissionDecision } = null,
    action_target: ?u64 = null,
    action_selection: ?@import("action_control.zig").Selection = null,
    resolution_position: ?u64 = null,

    pub const ContentReference = mutation_answer.ContentReference;

    pub const Recovery = struct {
        unknown_outcomes: [protocol.message_recovery_limit]protocol.MessageUnknownOutcome = undefined,
        count: usize = 0,
        more: bool,
    };

    pub fn failureCode(self: *const CommandObservation) ?[]const u8 {
        if (self.code) |*code| return code.slice();
        if (self.result) |*result| if (result.code) |*code| return code.slice();
        return null;
    }

    pub fn forMessage(self: CommandObservation, address: *const MessageAddress) !CommandObservation {
        if (!self.key.eql(address.key.slice())) return error.RequestBindingMismatch;
        if (self.status == .absent) return error.RequestNotAdmitted;
        if (self.kind != .message or !self.target.?.eql(address.session.slice())) return error.RequestBindingMismatch;
        return self;
    }

    pub fn writeJson(self: *const CommandObservation, writer: *std.Io.Writer) !void {
        try writer.print("{{\"status\":\"{s}\"", .{@tagName(self.status)});
        if (self.kind) |kind| try writer.print(",\"kind\":\"{s}\",\"target\":", .{@tagName(kind)});
        if (self.target) |*target| try std.json.Stringify.value(target.slice(), .{}, writer);
        if (self.code) |*code| {
            try writer.writeAll(",\"code\":");
            try std.json.Stringify.value(code.slice(), .{}, writer);
        }
        if (self.state) |state| try writer.print(",\"state\":\"{s}\"", .{@tagName(state)});
        if (self.revision) |revision| try writer.print(",\"revision\":\"{d}\",\"created\":{}", .{ revision, self.created.? });
        if (self.input) |input| {
            try writer.writeAll(",\"input\":");
            try (protocol.MessageInputJson{ .value = input }).writeJson(writer);
        }
        if (self.queue) |queue| try writer.print(",\"queue\":{{\"admission\":\"{d}\",\"admitted_at\":\"{d}\"}}", .{ queue.admission, queue.admitted_at });
        if (self.binding) |binding| try writer.print(",\"binding\":{{\"turn\":\"{d}\",\"operation\":\"{d}\",\"attempt\":\"{d}\"}}", .{ binding.turn, binding.operation, binding.attempt });
        if (self.result) |result| {
            try writer.print(",\"result\":{{\"status\":\"{s}\"", .{@tagName(result.status)});
            if (result.code) |*code| {
                try writer.writeAll(",\"code\":");
                try std.json.Stringify.value(code.slice(), .{}, writer);
            }
            if (result.text) |text| {
                try writer.writeAll(",\"text\":");
                try protocol.ContentValueJson.text(.{ .length = text.bytes, .digest = text.digest }).writeJson(writer);
            }
            try writer.writeByte('}');
        }
        if (self.work) |work| {
            try writer.writeAll(",\"work\":{\"state\":");
            try (protocol.WorkStateJson{ .state = work.state }).writeJson(writer);
            try writer.writeAll(",\"first_action\":");
            if (work.first_action) |action| try writer.print("\"{d}\"", .{action}) else try writer.writeAll("null");
            try writer.writeAll(",\"attention\":");
            if (work.attention) |value| try (protocol.WorkAttentionJson{ .value = value }).writeJson(writer) else try writer.writeAll("null");
            try writer.print(",\"group\":\"{s}\",\"actions\":", .{@tagName(work.group)});
            try (protocol.WorkActionsJson{ .value = work.actions }).writeJson(writer);
            try writer.writeByte('}');
        }
        if (self.recovery) |*recovery| {
            try writer.writeAll(",\"recovery\":");
            try (protocol.MessageRecoveryJson{ .calls = recovery.unknown_outcomes[0..recovery.count], .more = recovery.more }).writeJson(writer);
        }
        if (self.selection) |selection| {
            try writer.writeAll(",\"selection\":{\"turn\":");
            if (selection.turn) |turn| try writer.print("\"{d}\"", .{turn}) else try writer.writeAll("null");
            try writer.print(",\"admission_cutoff\":\"{d}\"}},\"completion\":{{\"status\":\"{s}\"}}", .{ selection.admission_cutoff, @tagName(self.completion.?) });
        }
        if (self.archived) |archived| {
            try writer.print(",\"archived\":{s},\"completion\":{{\"status\":\"{s}\"}}", .{ if (archived) "true" else "false", @tagName(self.completion.?) });
        }
        if (self.pinned) |pinned| try writer.print(",\"pinned\":{}", .{pinned});
        if (self.interruption_target) |*target| {
            try writer.writeAll(",\"interruption_target\":{\"session\":");
            try std.json.Stringify.value(target.session.slice(), .{}, writer);
            try writer.print(",\"turn\":\"{d}\",\"operation\":\"{d}\"}}", .{ target.turn, target.operation });
        }
        if (self.permission_target) |target| try writer.print(",\"permission_target\":{{\"action\":\"{d}\",\"decision\":\"{s}\"}}", .{ target.action, @tagName(target.decision) });
        if (self.action_target) |action| try writer.print(",\"action_target\":{{\"action\":\"{d}\"}}", .{action});
        if (self.kind == .action_stop and self.status == .accepted) {
            try writer.writeAll(",\"resolution_position\":");
            if (self.resolution_position) |p| try writer.print("\"{d}\"", .{p}) else try writer.writeAll("null");
        }
        if (self.action_selection) |selection| try writer.print(",\"action_selection\":{{\"kind\":\"{s}\",\"position\":\"{d}\"}}", .{ @tagName(selection.kind), selection.position });
        try writer.writeByte('}');
    }

    pub fn parse(reply: CommandReply, key: []const u8) !CommandObservation {
        return switch (try parseReply(reply, key)) {
            .observation => |full| full.facts,
            else => error.InvalidObservation,
        };
    }

    fn parseReply(reply: CommandReply, key: []const u8) !ObservationReply {
        @setEvalBranchQuota(2_000_000);
        try checkCanonicalFailure(reply);
        if (reply.status != 200) return error.ObservationFailed;
        if (reply.body.len > protocol.command_observation_reply.max_bytes) return error.ResponseTooLarge;
        const shapes = comptime command_spec.observationDecoderShapes(protocol).values;
        // Session pin supplies the existing answer envelope without owning the
        // unrelated input, queue or execution extensions of other mutations.
        const universe = comptime shapes ++ .{ protocol.error_reply, protocol.session_pin_reply.accepted };
        const JsonTypes = struct {
            pub fn Type(comptime T: type) type {
                if (T == protocol.MessageInputJson) return mutation_answer.InputWire;
                if (T == protocol.WorkStateJson) return JsonWorkState;
                if (T == protocol.WorkAttentionJson) return JsonWorkAttention;
                if (T == protocol.WorkActionsJson) return JsonWorkActions;
                if (T == protocol.MessageRecoveryJson) return JsonMessageRecovery;
                return T;
            }
        };
        const capacity = comptime std.ArrayList(u8).growCapacity((protocol.command_observation_reply.max_bytes + 7) / 8) + std.ArrayList(u8).growCapacity(protocol.command_observation_reply.max_bytes);
        var storage: [capacity]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&storage);
        inline for (shapes) |shape| {
            candidate: {
                fixed.reset();
                const Decoder = @import("command_reply.zig").DecoderWithJson(shape, universe, JsonTypes);
                const wire = Decoder.parse(fixed.allocator(), reply.body) catch break :candidate;
                return decodeObservation(wire, key);
            }
        }
        return error.InvalidObservation;
    }

    const JsonMessageRecovery = struct {
        const Outcome = struct { action: JsonString(20), operation: JsonString(20), call: JsonString(20), description: ?JsonString(protocol.max_tool_description_bytes), at: JsonString(20) };
        unknown_outcomes: JsonArray(Outcome, protocol.message_recovery_limit),
        more: bool,
    };

    fn decodeObservation(wire: anytype, key: []const u8) !ObservationReply {
        if (!wire.key.eql(key)) return error.RequestBindingMismatch;
        const since: ?SessionToken = blk: {
            if (comptime @TypeOf(wire.since) == ?void) break :blk null;
            if (comptime @typeInfo(@TypeOf(wire.since)) == .optional) {
                break :blk if (wire.since) |text| SessionToken.parse(text.slice()) catch return error.InvalidObservation else null;
            }
            break :blk SessionToken.parse(wire.since.slice()) catch return error.InvalidObservation;
        };
        if (comptime !@hasField(@TypeOf(wire), "observation")) return .{ .not_modified = since orelse return error.InvalidObservation };
        const facts = wire.observation;
        const Facts = @TypeOf(facts);
        var observed: CommandObservation = .{ .key = wire.key.value, .status = std.meta.stringToEnum(@FieldType(CommandObservation, "status"), facts.status.slice()) orelse return error.InvalidObservation };
        if (comptime @hasField(Facts, "kind")) observed.kind = std.meta.stringToEnum(protocol.CommandKind, facts.kind.slice()) orelse return error.InvalidObservation;
        inline for (.{ "target", "code" }) |name| if (comptime @hasField(Facts, name)) {
            @field(observed, name) = @field(facts, name).value;
        };
        inline for (.{ "created", "archived", "pinned" }) |name| if (comptime @hasField(Facts, name)) {
            @field(observed, name) = @field(facts, name);
        };
        if (comptime @hasField(Facts, "revision")) observed.revision = try decimalId(facts.revision, false);
        if (comptime @hasField(Facts, "input")) observed.input = facts.input.contentValue(protocol.max_sqlite_content_bytes) catch return error.InvalidObservation;
        if (comptime @hasField(Facts, "state")) observed.state = std.meta.stringToEnum(protocol.MessageRequestState, facts.state.slice()) orelse return error.InvalidObservation;
        if (comptime @hasField(Facts, "queue")) observed.queue = .{ .admission = try decimalId(facts.queue.admission, false), .admitted_at = try decimalId(facts.queue.admitted_at, false) };
        if (comptime @hasField(Facts, "binding")) observed.binding = .{ .turn = try decimalId(facts.binding.turn, false), .operation = try decimalId(facts.binding.operation, false), .attempt = try decimalId(facts.binding.attempt, true) };
        if (comptime @hasField(Facts, "result")) observed.result = .{
            .status = std.meta.stringToEnum(@FieldType(@typeInfo(@FieldType(CommandObservation, "result")).optional.child, "status"), facts.result.status.slice()) orelse return error.InvalidObservation,
            .code = if (@hasField(@TypeOf(facts.result), "code")) facts.result.code.value else null,
            .text = if (@hasField(@TypeOf(facts.result), "text")) try decodeReference(facts.result.text) else null,
        };
        if (comptime @hasField(Facts, "work")) observed.work = .{ .state = facts.work.state.value, .first_action = if (facts.work.first_action) |action| try decimalId(action, false) else null, .attention = try readWorkAttention(facts.work.attention), .group = std.meta.stringToEnum(@import("session_work.zig").Group, facts.work.group.slice()) orelse return error.InvalidObservation, .actions = try readWorkActions(facts.work.actions) };
        if (comptime @hasField(Facts, "recovery")) {
            var recovery: Recovery = .{ .more = facts.recovery.more };
            for (facts.recovery.unknown_outcomes.slice()) |row| {
                if (row.description) |description| if (!protocol.ToolPresentation.validDescription(description.slice())) return error.InvalidObservation;
                recovery.unknown_outcomes[recovery.count] = .{
                    .action_id = try decimalId(row.action, false),
                    .operation_id = try decimalId(row.operation, false),
                    .call = try decimalId(row.call, true),
                    .description = if (row.description) |description| description.value else null,
                    .at = try decimalId(row.at, false),
                };
                recovery.count += 1;
            }
            observed.recovery = recovery;
        }
        if (comptime @hasField(Facts, "selection")) observed.selection = .{ .turn = if (facts.selection.turn) |turn| try decimalId(turn, false) else null, .admission_cutoff = try decimalId(facts.selection.admission_cutoff, true) };
        if (comptime @hasField(Facts, "completion")) observed.completion = std.meta.stringToEnum(protocol.SessionStopCompletion, facts.completion.status.slice()) orelse return error.InvalidObservation;
        if (comptime @hasField(Facts, "interruption_target")) observed.interruption_target = .{ .session = facts.interruption_target.session.value, .turn = try decimalId(facts.interruption_target.turn, true), .operation = try decimalId(facts.interruption_target.operation, true) };
        if (comptime @hasField(Facts, "permission_target")) observed.permission_target = .{ .action = try decimalId(facts.permission_target.action, true), .decision = std.meta.stringToEnum(protocol.PermissionDecision, facts.permission_target.decision.slice()) orelse return error.InvalidObservation };
        if (comptime @hasField(Facts, "resolution_position")) observed.resolution_position = if (facts.resolution_position) |p| try decimalId(p, false) else null;
        if (comptime @hasField(Facts, "action_target")) observed.action_target = try decimalId(facts.action_target.action, true);
        if (comptime @hasField(Facts, "action_selection")) observed.action_selection = .{ .kind = std.meta.stringToEnum(@FieldType(@import("action_control.zig").Selection, "kind"), facts.action_selection.kind.slice()) orelse return error.InvalidObservation, .position = try decimalId(facts.action_selection.position, false) };
        try observed.validate();
        if (since) |token| {
            const target = observed.target orelse return error.InvalidObservation;
            if (!target.eql(&token.session)) return error.RequestBindingMismatch;
        }
        return .{ .observation = .{ .facts = observed, .since = since } };
    }

    fn decodeReference(value: anytype) !ContentReference {
        var result: ContentReference = .{ .bytes = try decimalId(value.bytes, true), .digest = undefined };
        if (value.sha256.slice().len != 64) return error.InvalidObservation;
        _ = std.fmt.hexToBytes(&result.digest, value.sha256.slice()) catch return error.InvalidObservation;
        return result;
    }

    fn validate(self: *const CommandObservation) !void {
        @setEvalBranchQuota(10_000);
        if (self.status == .absent) return;
        const kind = self.kind orelse return error.InvalidObservation;
        if (self.target == null or (self.target.?.len == 0 and
            (self.status != .rejected or (kind != .configure and kind != .message)))) return error.InvalidObservation;
        if ((self.status == .rejected) != (self.code != null)) return error.InvalidObservation;
        if (self.code) |code| if (code.len == 0) return error.InvalidObservation;
        const accepted = self.status == .accepted;
        if (accepted and !protocol.validSessionId(self.target.?.slice())) return error.InvalidObservation;
        if (self.interruption_target) |target| if (!target.session.eql(self.target.?.slice())) return error.RequestBindingMismatch;
        if (kind != .message) return;
        const state = self.state orelse return error.InvalidObservation;
        if (!accepted) {
            if (state != .rejected or self.input != null or self.queue != null or self.binding != null or self.result != null or self.work != null or self.recovery != null) return error.InvalidObservation;
            return;
        }
        const input = self.input orelse return error.InvalidObservation;
        const queue = self.queue orelse return error.InvalidObservation;
        if (state == .rejected or !mutation_answer.matchesMessageAdmission(input, queue.admission)) return error.InvalidObservation;
        if (self.result) |result| {
            if (self.work != null or !std.mem.eql(u8, @tagName(state), @tagName(result.status))) return error.InvalidObservation;
            if (result.status != .cancelled and self.binding == null) return error.InvalidObservation;
            if (result.status == .completed) {
                if (result.text == null or result.code != null) return error.InvalidObservation;
            } else if (result.text != null or result.code == null or result.code.?.len == 0) return error.InvalidObservation;
        } else {
            if (self.work == null) return error.InvalidObservation;
            if ((state == .waiting_for_permission) != (self.work.?.state == .approval)) return error.InvalidObservation;
            switch (state) {
                .queued => if (self.binding != null) return error.InvalidObservation,
                .processing => if (self.binding == null) return error.InvalidObservation,
                // A newer Message hides the decision while automatic denial is pending.
                .waiting_for_permission => {},
                .completed, .failed, .cancelled, .rejected => return error.InvalidObservation,
            }
        }
        if (self.recovery) |recovery| {
            if (self.binding == null or recovery.count == 0 or (recovery.more and recovery.count != recovery.unknown_outcomes.len)) return error.InvalidObservation;
            for (recovery.unknown_outcomes[0..recovery.count], 0..) |outcome, index| {
                for (recovery.unknown_outcomes[0..index]) |prior| if (prior.action_id == outcome.action_id) return error.InvalidObservation;
            }
        }
    }
};

pub const MutationTarget = mutation_answer.Target;
pub const MutationAnswer = mutation_answer.Answer;
pub const InvocationDiagnostic = mutation_answer.InvocationDiagnostic;

pub fn validateInvocationDiagnostic(status: u16, version: []const u8, diagnostic: InvocationDiagnostic) error{InvalidResponse}!void {
    return mutation_answer.validateInvocationDiagnostic(protocol.wire_version, status, version, diagnostic);
}

pub const MutationReply = struct {
    status: u16,
    diagnostic: ?InvocationDiagnostic = null,
    context: MutationIdentity,
    target: MutationTarget,
    answer: mutation_answer.Error!MutationAnswer,

    pub fn failureReason(err: @typeInfo(@FieldType(MutationReply, "answer")).error_union.error_set) []const u8 {
        return switch (err) {
            error.CanonicalStoreFailure => "CanonicalStoreFailure",
            error.HostInvocationFailed => "HostInvocationFailed",
            error.InvalidResponse => "InvalidResponse",
            error.RequestBindingMismatch => "RequestBindingMismatch",
        };
    }

    pub fn isAccepted(self: MutationReply) bool {
        const answer = self.answer catch return false;
        return answer.result == .accepted;
    }
};

pub const JsonAddress = struct {
    store: JsonString(protocol.max_store_bytes),
    session: JsonString(protocol.max_session_bytes),

    pub fn address(self: JsonAddress) !protocol.Address {
        const result: protocol.Address = .{ .store = self.store.value, .session = self.session.value };
        try result.validate();
        return result;
    }
};

pub const JsonFirstMessage = struct {
    value: protocol.FirstMessage,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const Wire = struct { position: JsonString(20), admission: JsonString(20), admitted_at: JsonString(20), sender: ?JsonPeer, content: JsonContentValue };
        const wire = try std.json.innerParse(Wire, allocator, source, options);
        return .{ .value = .{
            .position = ActivityPage.id(wire.position, false) catch return error.InvalidCharacter,
            .admission = ActivityPage.id(wire.admission, false) catch return error.InvalidCharacter,
            .admitted_at = ActivityPage.id(wire.admitted_at, false) catch return error.InvalidCharacter,
            .sender = if (wire.sender) |sender| sender.peer() catch return error.InvalidCharacter else null,
            .content = wire.content.value,
        } };
    }

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        var buffer: [protocol.FirstMessage.max_json_bytes]u8 = undefined;
        var out = std.Io.Writer.fixed(&buffer);
        self.value.writeJson(&out) catch unreachable;
        try jw.print("{s}", .{out.buffered()});
    }
};

/// The one reader of a `ContentValue` member.
pub const JsonContentValue = struct {
    value: content_value.Value,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const wire = try mutation_answer.InputWire.jsonParse(allocator, source, options);
        return .{ .value = try wire.contentValue(protocol.max_sqlite_content_bytes) };
    }

    /// Model text (an answer, an outcome, a call field) is never parts.
    pub fn text(self: JsonContentValue) error{InvalidCharacter}!content_value.Reference {
        return switch (self.value) {
            .text => |reference| reference,
            .parts => error.InvalidCharacter,
        };
    }

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        var buffer: [protocol.ContentValueJson.max_json_bytes]u8 = undefined;
        var out = std.Io.Writer.fixed(&buffer);
        (protocol.ContentValueJson{ .value = self.value }).writeJson(&out) catch unreachable;
        try jw.print("{s}", .{out.buffered()});
    }
};

/// One slim Archived row as the window reply sends it (protocol.ArchivedRow.Fields): the first Message's
/// position, admission and content reference, and its inline line when it has one.
pub const ArchivedRowRead = struct {
    reference: JsonString(protocol.max_session_bytes),
    archive_seq: u64,
    stopped_at: u64,
    label: ?JsonString(protocol.max_label_bytes),
    first: ?ArchivedFirstRead,

    pub const ArchivedFirstRead = struct {
        position: u64,
        admission: u64,
        content: content_value.Value,
        line: ?JsonString(session_list.max_first_line_bytes),
    };

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const Wire = struct {
            reference: JsonString(protocol.max_session_bytes),
            archive_seq: JsonString(20),
            stopped_at: JsonString(20),
            label: ?JsonString(protocol.max_label_bytes),
            first: ?struct { position: JsonString(20), admission: JsonString(20), content: JsonContentValue, line: ?JsonString(session_list.max_first_line_bytes) },
        };
        const wire = try std.json.innerParse(Wire, allocator, source, options);
        if (!protocol.validSessionId(wire.reference.slice())) return error.InvalidCharacter;
        if (wire.label) |label| if (!protocol.validLabel(label.slice())) return error.InvalidCharacter;
        const first: ?ArchivedFirstRead = if (wire.first) |first| .{
            .position = ActivityPage.id(first.position, false) catch return error.InvalidCharacter,
            .admission = ActivityPage.id(first.admission, false) catch return error.InvalidCharacter,
            .content = first.content.value,
            .line = first.line,
        } else null;
        return .{
            .reference = wire.reference,
            .archive_seq = ActivityPage.id(wire.archive_seq, false) catch return error.InvalidCharacter,
            .stopped_at = ActivityPage.id(wire.stopped_at, false) catch return error.InvalidCharacter,
            .label = wire.label,
            .first = first,
        };
    }
};

pub const JsonPeer = struct {
    session: JsonString(protocol.max_session_bytes),

    fn peer(self: *const JsonPeer) !protocol.Peer {
        if (!protocol.validSessionId(self.session.slice())) return error.InvalidResponse;
        return .{ .session = self.session.value };
    }
};

pub const JsonNamedPeer = struct {
    session: JsonString(protocol.max_session_bytes),
    label: ?JsonString(protocol.max_label_bytes) = null,

    fn peer(self: *const JsonNamedPeer) !protocol.NamedPeer {
        if (!protocol.validSessionId(self.session.slice())) return error.InvalidResponse;
        const label = if (self.label) |label| label.value else protocol.Bounded(protocol.max_label_bytes){};
        if (self.label != null and !protocol.validLabel(label.slice())) return error.InvalidResponse;
        return .{ .session = self.session.value, .label = label };
    }
};

pub const JsonWorkState = struct {
    value: protocol.WorkState,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const Kind = protocol.session_work.Kind;
        const Wire = struct {
            kind: JsonEnum(Kind),
            since: JsonString(20),
            compaction: OmittableJson(bool) = .{},
            due_at_ms: OmittableJson(JsonString(20)) = .{},
            cause: OmittableJson(JsonString(protocol.max_code_bytes)) = .{},
            attempt: OmittableJson(JsonString(20)) = .{},
            call: OmittableJson(JsonString(20)) = .{},
            description: OmittableJson(?JsonString(protocol.session_work.max_description_bytes)) = .{},
            running: OmittableJson(JsonString(20)) = .{},
            approvals: OmittableJson(JsonString(20)) = .{},
            code: OmittableJson(JsonString(protocol.max_code_bytes)) = .{},
            resets_at: OmittableJson(?JsonString(20)) = .{},
        };
        const wire = try std.json.innerParse(Wire, allocator, source, options);
        const kind = wire.kind.value;
        const present = [_]bool{ wire.due_at_ms.isPresent(), wire.cause.isPresent(), wire.attempt.isPresent(), wire.description.isPresent(), wire.running.isPresent(), wire.approvals.isPresent(), wire.code.isPresent(), wire.resets_at.isPresent() };
        const owned: [present.len]bool = switch (kind) {
            .retrying => .{ true, true, true, false, false, false, false, false },
            .bash => .{ false, false, false, true, true, true, false, false },
            .failed => .{ false, false, false, false, false, false, true, true },
            .stopped => .{ false, true, false, false, false, false, false, false },
            .idle, .pending, .working, .approval, .stopping, .finished => @splat(false),
        };
        if (!std.mem.eql(bool, &present, &owned)) return error.InvalidCharacter;
        if (wire.compaction.isPresent() and kind != .working) return error.InvalidCharacter;
        if (wire.call.isPresent() and kind != .bash) return error.InvalidCharacter;
        const since = number(wire.since, false) catch return error.InvalidCharacter;
        const value: protocol.WorkState = switch (kind) {
            .working => .{ .working = .{ .since = since, .compaction = wire.compaction.value orelse false } },
            .retrying => .{ .retrying = .{
                .since = since,
                .due_at_ms = number(wire.due_at_ms.value.?, false) catch return error.InvalidCharacter,
                .cause = try code(wire.cause.value.?),
                .attempt = attempt: {
                    const attempt = number(wire.attempt.value.?, false) catch return error.InvalidCharacter;
                    if (attempt > protocol.session_work.max_retried_attempt) return error.InvalidCharacter;
                    break :attempt attempt;
                },
            } },
            .bash => .{ .bash = .{
                .since = since,
                .call = if (wire.call.value) |text| number(text, true) catch return error.InvalidCharacter else null,
                .description = if (wire.description.value.?) |text| description: {
                    if (!protocol.ToolPresentation.validDescription(text.slice())) return error.InvalidCharacter;
                    break :description text.value;
                } else null,
                .running = number(wire.running.value.?, false) catch return error.InvalidCharacter,
                .approvals = number(wire.approvals.value.?, true) catch return error.InvalidCharacter,
            } },
            .failed => failed: {
                const saved = try code(wire.code.value.?);
                const resets_at = if (wire.resets_at.value.?) |text| number(text, false) catch return error.InvalidCharacter else null;
                if (resets_at != null and transport_policy.Quota.ofFailureCode(saved.slice()) == null) return error.InvalidCharacter;
                break :failed .{ .failed = .{ .since = since, .code = saved, .resets_at = resets_at } };
            },
            .stopped => .{ .stopped = .{
                .since = since,
                .cause = std.meta.stringToEnum(protocol.session_work.StopCause, wire.cause.value.?.slice()) orelse return error.InvalidCharacter,
            } },
            inline .idle, .pending, .approval, .stopping, .finished => |tag| @unionInit(protocol.WorkState, @tagName(tag), .{ .since = since }),
        };
        return .{ .value = value };
    }

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginWriteRaw();
        try (protocol.WorkStateJson{ .state = self.value }).writeJson(jw.writer);
        jw.endWriteRaw();
    }

    fn number(text: JsonString(20), zero: bool) !u64 {
        const value = try decimalId(text, zero);
        if (value > std.math.maxInt(i64)) return error.InvalidResponse;
        return value;
    }

    fn code(text: JsonString(protocol.max_code_bytes)) !protocol.Bounded(protocol.max_code_bytes) {
        if (text.slice().len == 0) return error.InvalidCharacter;
        return text.value;
    }
};

// The stdlib also accepts numeric enum tags. Host facts require named strings;
// their closed vocabulary derives the token bound, with JsonString's lifetime.
pub const JsonToolPresentation = struct {
    value: protocol.ToolPresentation,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const Wire = struct { description: ?JsonString(protocol.max_tool_description_bytes), code: JsonEnum(protocol.ToolPresentation.Code), publication_position: ?JsonString(20) };
        const wire = try std.json.innerParse(Wire, allocator, source, options);
        const position = if (wire.publication_position) |p| decimalId(p, false) catch return error.InvalidCharacter else null;
        if (position) |p| if (p > std.math.maxInt(i64)) return error.InvalidCharacter;
        if (wire.description) |d| if (!protocol.ToolPresentation.validDescription(d.slice())) return error.InvalidCharacter;
        if (wire.description == null) switch (wire.code.value) {
            .unknown_tool, .invalid_arguments => {},
            else => return error.InvalidCharacter,
        };
        if (position != null and (wire.code.value == .unresolved or wire.code.value == .pending_permission)) return error.InvalidCharacter;
        return .{ .value = .{ .description = if (wire.description) |d| d.value else null, .code = wire.code.value, .publication_position = position } };
    }

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("description");
        if (self.value.description) |d| try jw.write(d.slice()) else try jw.write(null);
        try jw.objectField("code");
        try jw.write(@tagName(self.value.code));
        try jw.objectField("publication_position");
        if (self.value.publication_position) |p| {
            var buffer: [20]u8 = undefined;
            try jw.write(std.fmt.bufPrint(&buffer, "{d}", .{p}) catch unreachable);
        } else try jw.write(null);
        try jw.endObject();
    }
};

test "canonical presentation typed ingress owns escaped labels and closed facts" {
    const bytes = "{\"description\":\"Read \\u20ac files\",\"code\":\"denied\",\"publication_position\":null}";
    const parsed = try std.json.parseFromSlice(JsonToolPresentation, std.testing.allocator, bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("Read € files", parsed.value.value.description.?.slice());
    try std.testing.expectEqual(protocol.ToolPresentation.Code.denied, parsed.value.value.code);
    try std.testing.expect(parsed.value.value.publication_position == null);
    for ([_][]const u8{
        "{\"description\":null,\"code\":0,\"publication_position\":null}",
        "{\"description\":null,\"code\":\"invented\",\"publication_position\":null}",
        "{\"description\":null,\"code\":\"succeeded\",\"publication_position\":\"1\"}",
        "{\"description\":\"Read\\nfiles\",\"code\":\"succeeded\",\"publication_position\":\"1\"}",
        "{\"description\":\" \",\"code\":\"succeeded\",\"publication_position\":\"1\"}",
        "{\"description\":null,\"code\":\"succeeded\",\"publication_position\":1}",
        "{\"description\":null,\"code\":\"succeeded\",\"publication_position\":\"0\"}",
        "{\"description\":null,\"code\":\"succeeded\",\"publication_position\":\"9223372036854775808\"}",
        "{\"description\":null,\"code\":\"pending_permission\",\"publication_position\":\"1\"}",
        "{\"description\":null,\"code\":\"pending_permission\",\"publication_position\":null}",
        "{\"description\":null,\"code\":\"unresolved\",\"publication_position\":null}",
        "{\"code\":\"succeeded\",\"publication_position\":null}",
        "{\"description\":null,\"code\":\"succeeded\",\"code\":\"failed\",\"publication_position\":null}",
        "{\"description\":\"" ++ @as([201]u8, @splat('x')) ++ "\",\"code\":\"succeeded\",\"publication_position\":null}",
    }) |invalid| {
        if (std.json.parseFromSlice(JsonToolPresentation, std.testing.allocator, invalid, .{})) |unexpected| {
            unexpected.deinit();
            return error.AcceptedInvalidPresentation;
        } else |_| {}
    }
    const escaped = "{\"description\":\"" ++ @as([200 * 6]u8, @bitCast(@as([200][6]u8, @splat("\\u0001".*)))) ++ "\",\"code\":\"succeeded\",\"publication_position\":\"9223372036854775807\"}";
    const maximum = try std.json.parseFromSlice(JsonToolPresentation, std.testing.allocator, escaped, .{});
    defer maximum.deinit();
    try std.testing.expectEqual(@as(usize, 200), maximum.value.value.description.?.slice().len);
    var buffer: [protocol.ToolPresentationJson.max_json_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try (protocol.ToolPresentationJson{ .value = maximum.value.value }).writeJson(&writer);
    const roundtrip = try std.json.parseFromSlice(JsonToolPresentation, std.testing.allocator, writer.buffered(), .{});
    defer roundtrip.deinit();
    try std.testing.expectEqualDeep(maximum.value.value, roundtrip.value.value);
    var facts: protocol.ActivityFacts = .{ .end = std.math.maxInt(i64) - 1, .count = 16 };
    facts.queued = .{ .count = std.math.maxInt(i64) - 1_000_000_000_000_000_000, .oldest_position = 1_000_000_000_000_000_000, .newest_admission = std.math.maxInt(i64), .newest_position = std.math.maxInt(i64) - 1, .newest_content = .{ .text = .{ .length = 1, .digest = @splat(1) } } };
    for (&facts.items, 0..) |*item, index| item.* = .{
        .position = index + 1,
        .ordinal = 1,
        .at = std.math.maxInt(i64) - index,
        .value = .{ .tool_result = .{ .content = .{ .text = .{ .length = 0, .digest = protocol.contentDigest("") } }, .presentation = .{ .description = maximum.value.value.description, .code = .succeeded, .publication_position = index + 1 } } },
    };
    facts.call_activity = .{ .total = std.math.maxInt(i64), .count = 3 };
    for (&facts.call_activity.entries, 0..) |*entry, index| entry.* = .{
        .operation = std.math.maxInt(i64) - 2 + index,
        .ordinal = std.math.maxInt(i64) - 1,
        .presentation = .{ .description = maximum.value.value.description, .code = .infrastructure_shutdown, .publication_position = std.math.maxInt(i64) },
    };
    facts.work = .{ .read_version = .{ .instance = @splat(0xab), .generation = std.math.maxInt(u64) }, .work = .{ .state = .{ .approval = .{ .since = std.math.maxInt(i64) } }, .turn = std.math.maxInt(i64), .operation = std.math.maxInt(i64) - 1, .first_action = std.math.maxInt(i64) - 2 }, .revision = std.math.maxInt(i64) };
    facts.work.work.served_attention = @import("session_work.zig").attention(facts.work.work);
    facts.work.work.served_group = @import("session_work.zig").group(facts.work.work);
    @memset(facts.work.workspace.bytes[0..protocol.max_workspace_bytes], 0x01);
    facts.work.workspace.bytes[0] = '/';
    facts.work.workspace.len = protocol.max_workspace_bytes;
    var page_buffer: [activity_reply.max_page_bytes]u8 = undefined;
    var page_writer = std.Io.Writer.fixed(&page_buffer);
    try activity_reply.writePage(&page_writer, &facts);
    const page = try ActivityPage.parse(page_writer.buffered(), .{});
    try std.testing.expectEqual(@as(usize, 16), page.facts.count);
    try std.testing.expectEqualDeep(facts.call_activity, page.facts.call_activity);
    try std.testing.expectEqualDeep(facts.queued, page.facts.queued);
    try std.testing.expectEqualDeep(facts.work, page.facts.work);
    for (page.facts.items) |item| {
        try std.testing.expectEqual(@as(usize, 200), item.value.tool_result.presentation.description.?.slice().len);
        try std.testing.expectEqual(item.position, item.value.tool_result.presentation.publication_position.?);
        try std.testing.expectEqual(std.math.maxInt(i64) + 1 - item.position, item.at);
    }
}

test "activity page preserves the canonical row preview with its work" {
    var facts: protocol.ActivityFacts = .{ .end = 4, .work = .{
        .revision = 1,
        .work = .{ .state = .{ .finished = .{ .since = 2 } }, .turn = 1, .operation = 1 },
        .last_line = .{ .position = 4, .text = .{} },
    } };
    facts.work.work.served_attention = @import("session_work.zig").attention(facts.work.work);
    facts.work.work.served_group = @import("session_work.zig").group(facts.work.work);
    try facts.work.workspace.set("/work");
    try facts.work.last_line.?.text.?.set("New completed answer");
    var buffer: [activity_reply.max_page_bytes]u8 = undefined;
    for ([_]bool{ true, false }) |has_text| {
        if (!has_text) facts.work.last_line.?.text = null;
        var out = std.Io.Writer.fixed(&buffer);
        try activity_reply.writePage(&out, &facts);
        const parsed = try ActivityPage.parse(out.buffered(), .{});
        try std.testing.expectEqualDeep(facts.work, parsed.facts.work);
        const malformed = try std.mem.replaceOwned(u8, std.testing.allocator, out.buffered(), "\"position\":\"4\"", "\"position\":\"0\"");
        defer std.testing.allocator.free(malformed);
        try std.testing.expectError(error.InvalidResponse, ActivityPage.parse(malformed, .{}));
        facts.end = 1;
    }
}

test "CLI-17 activity_served_work" {
    var facts: protocol.ActivityFacts = .{ .end = 0, .work = .{
        .revision = 1,
        .work = .{ .state = .{ .working = .{ .since = 1 } }, .turn = 1, .operation = 2, .served_attention = .{ .kind = .approval, .turn = 1, .step = 7 }, .served_group = .needs_you, .actions = .{ .stop = true, .interrupt = .{ .turn = 1, .operation = 2 } } },
    } };
    try facts.work.workspace.set("/work");
    var buffer: [activity_reply.max_page_bytes]u8 = undefined;
    for (0..2) |i| {
        if (i == 1) facts.work.work.actions.interrupt = null;
        var out = std.Io.Writer.fixed(&buffer);
        try activity_reply.writePage(&out, &facts);
        const parsed = try ActivityPage.parse(out.buffered(), .{});
        try std.testing.expectEqualDeep(facts.work.work, parsed.facts.work.work);
        for ([_][]const u8{
            "\"attention\":{\"kind\":\"approval\",\"turn\":\"1\",\"step\":\"7\"},",
            "\"group\":\"needs_you\",",
            if (i == 0) ",\"actions\":{\"stop\":true,\"interrupt\":{\"turn\":\"1\",\"operation\":\"2\"},\"decide\":null}" else ",\"actions\":{\"stop\":true,\"interrupt\":null,\"decide\":null}",
        }) |field| {
            try std.testing.expect(std.mem.indexOf(u8, out.buffered(), field) != null);
            const missing = try std.mem.replaceOwned(u8, std.testing.allocator, out.buffered(), field, "");
            defer std.testing.allocator.free(missing);
            try std.testing.expectError(error.InvalidActivityPage, ActivityPage.parse(missing, .{}));
        }
    }
}

test "activity page creator is required nullable canonical provenance" {
    var facts: protocol.ActivityFacts = .{ .end = 0, .work = .{ .revision = 1, .work = .{ .state = .{ .idle = .{ .since = 1 } } } } };
    try facts.work.workspace.set("/work");
    var buffer: [activity_reply.max_page_bytes]u8 = undefined;
    for ([_]?[]const u8{ null, "cr3at0" }) |creator| {
        facts.work.creator = if (creator) |reference| try .from(reference) else null;
        var out = std.Io.Writer.fixed(&buffer);
        try activity_reply.writePage(&out, &facts);
        const parsed = try ActivityPage.parse(out.buffered(), .{});
        if (creator) |reference| {
            try std.testing.expectEqualStrings(reference, parsed.facts.work.creator.?.slice());
        } else try std.testing.expect(parsed.facts.work.creator == null);
    }
    facts.work.creator = null;
    var out = std.Io.Writer.fixed(&buffer);
    try activity_reply.writePage(&out, &facts);
    for ([_][]const u8{ "", "\"creator\":0,", "\"creator\":{},", "\"creator\":\"\",", "\"creator\":\"short\",", "\"creator\":\"abcdefg\",", "\"creator\":\"k7m2qX\",", "\"creator\":\"k7m2qi\",", "\"creator\":null,\"creator\":null," }) |replacement| {
        const malformed = try std.mem.replaceOwned(u8, std.testing.allocator, out.buffered(), "\"creator\":null,", replacement);
        defer std.testing.allocator.free(malformed);
        try std.testing.expectError(error.InvalidActivityPage, ActivityPage.parse(malformed, .{}));
    }
    const escaped = try std.mem.replaceOwned(u8, std.testing.allocator, out.buffered(), "\"creator\":null", "\"creator\":\"cr3at\\u0030\"");
    defer std.testing.allocator.free(escaped);
    const parsed = try ActivityPage.parse(escaped, .{});
    try std.testing.expectEqualStrings("cr3at0", parsed.facts.work.creator.?.slice());
}

test "activity page requires a canonical read version" {
    var facts: protocol.ActivityFacts = .{ .end = 0, .work = .{ .revision = 1 } };
    try facts.work.workspace.set("/work");
    var buffer: [activity_reply.max_page_bytes]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    try activity_reply.writePage(&out, &facts);
    for ([_][2][]const u8{
        .{ "\"read_version\":\"00000000000000000000000000000000.0\",", "" },
        .{ "\"read_version\":\"00000000000000000000000000000000.0\"", "\"read_version\":\"bad\"" },
    }) |case| {
        const malformed = try std.mem.replaceOwned(u8, std.testing.allocator, out.buffered(), case[0], case[1]);
        defer std.testing.allocator.free(malformed);
        try std.testing.expectError(error.InvalidActivityPage, ActivityPage.parse(malformed, .{}));
    }
}

test "activity page delta variants validate tokens and preserve the cursor" {
    const token_text = "abababababababababababababababab.42.k7m2qx";
    const token = try SessionToken.parse(token_text);
    const unchanged = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"activity_page\",\"delta\":\"not_modified\",\"since\":\"" ++ token_text ++ "\"}";
    const page = try ActivityPage.parse(unchanged, .{ .end = 40, .position = 25, .direction = .backward, .limit = 3 });
    try std.testing.expect(page.facts.not_modified);
    try std.testing.expectEqualDeep(token, page.facts.token.?);
    try std.testing.expectEqual(@as(u64, 40), page.facts.end);
    try std.testing.expectEqual(.backward, page.facts.direction);
    try std.testing.expectEqual(@as(usize, 0), page.facts.count);
    try std.testing.expect(page.continuation() == null);
    const follow = try ActivityPage.parse(unchanged, .{ .position = 40 });
    try std.testing.expectEqual(@as(u64, 40), follow.facts.end);

    for ([_][]const u8{
        "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"activity_page\",\"delta\":\"not_modified\",\"since\":null}",
        "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"activity_page\",\"delta\":\"not_modified\",\"since\":\"bad\"}",
        "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"activity_page\",\"delta\":\"not_modified\"}",
        "{\"version\":\"old\",\"type\":\"activity_page\",\"delta\":\"not_modified\",\"since\":\"" ++ token_text ++ "\"}",
        "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"activity_page\",\"delta\":\"unknown\",\"since\":\"" ++ token_text ++ "\"}",
    }) |invalid| try std.testing.expectError(error.InvalidActivityPage, ActivityPage.parse(invalid, .{}));

    var facts: protocol.ActivityFacts = .{ .end = 40, .token = token, .work = .{ .revision = 1, .work = .{ .state = .{ .idle = .{ .since = 1 } } } } };
    try facts.work.workspace.set("/w");
    var buffer: [activity_reply.max_page_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try activity_reply.writePage(&writer, &facts);
    const full = try ActivityPage.parse(writer.buffered(), .{});
    try std.testing.expect(!full.facts.not_modified);
    try std.testing.expectEqualDeep(token, full.facts.token.?);
    for ([_]struct { from: []const u8, to: []const u8 }{
        .{ .from = token_text, .to = "bad" },
        .{ .from = "\"delta\":\"full\",", .to = "" },
        .{ .from = ",\"since\":\"" ++ token_text ++ "\"", .to = "" },
    }) |change| {
        const malformed = try std.mem.replaceOwned(u8, std.testing.allocator, writer.buffered(), change.from, change.to);
        defer std.testing.allocator.free(malformed);
        try std.testing.expectError(error.InvalidActivityPage, ActivityPage.parse(malformed, .{}));
    }
    facts.token = null;
    writer = std.Io.Writer.fixed(&buffer);
    try activity_reply.writePage(&writer, &facts);
    try std.testing.expect((try ActivityPage.parse(writer.buffered(), .{})).facts.token == null);
}

test "INS-7 the integration empty queue matches the Activity writer and decoder" {
    var facts: protocol.ActivityFacts = .{ .end = 40, .work = .{ .work = .{ .state = .{ .idle = .{ .since = 1 } } }, .revision = 1 } };
    try facts.work.workspace.set("/w");
    var buffer: [activity_reply.max_page_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try activity_reply.writePage(&writer, &facts);
    const fixture = @embedFile("codecs/fixtures/activity/empty-queue.json");
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), fixture) != null);
    try std.testing.expectEqualDeep(protocol.Queued{}, (try ActivityPage.parse(writer.buffered(), .{})).facts.queued);
}

test "an activity page's queued Messages are none or a span at its boundary" {
    var facts: protocol.ActivityFacts = .{ .end = 40, .work = .{ .work = .{ .state = .{ .working = .{ .since = 1 } } }, .revision = 1 } };
    try facts.work.workspace.set("/w");
    const Case = struct { queued: protocol.Queued, valid: bool };
    const text: content_value.Value = .{ .text = .{ .length = 1, .digest = @splat(1) } };
    for ([_]Case{
        .{ .queued = .{}, .valid = true },
        .{ .queued = .{ .count = 2, .oldest_position = 31, .newest_admission = 9, .newest_position = 40, .newest_content = text }, .valid = true },
        .{ .queued = .{ .count = 1, .oldest_position = 40, .newest_admission = 9, .newest_position = 40, .newest_content = text }, .valid = true },
        .{ .queued = .{ .count = 1, .oldest_position = 40, .newest_admission = 9, .newest_position = 40, .newest_content = .{ .parts = .{ .identity = text.text, .owner = .{ .message = 9 } } } }, .valid = true },
        // The newest Message's value is its own: another owner, or none while one waits, is refused.
        .{ .queued = .{ .count = 1, .oldest_position = 40, .newest_admission = 9, .newest_position = 40, .newest_content = .{ .parts = .{ .identity = text.text, .owner = .{ .message = 8 } } } }, .valid = false },
        .{ .queued = .{ .count = 1, .oldest_position = 40, .newest_admission = 9, .newest_position = 40, .newest_content = .{ .parts = .{ .identity = text.text, .owner = .{ .action = 9 } } } }, .valid = false },
        .{ .queued = .{ .count = 1, .oldest_position = 40, .newest_admission = 9, .newest_position = 40 }, .valid = false },
        .{ .queued = .{ .newest_content = text }, .valid = false },
        .{ .queued = .{ .newest_admission = 9 }, .valid = false },
        .{ .queued = .{ .count = 1, .oldest_position = 41, .newest_admission = 9, .newest_position = 41, .newest_content = text }, .valid = false },
        .{ .queued = .{ .count = 2, .oldest_position = 32, .newest_admission = 9, .newest_position = 31, .newest_content = text }, .valid = false },
        .{ .queued = .{ .count = 3, .oldest_position = 39, .newest_admission = 9, .newest_position = 40, .newest_content = text }, .valid = false },
        .{ .queued = .{ .count = 1, .oldest_position = 40, .newest_admission = 0, .newest_position = 40, .newest_content = text }, .valid = false },
    }) |case| {
        facts.queued = case.queued;
        var buffer: [activity_reply.max_page_bytes]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try activity_reply.writePage(&writer, &facts);
        if (case.valid) {
            try std.testing.expectEqualDeep(case.queued, (try ActivityPage.parse(writer.buffered(), .{})).facts.queued);
        } else try std.testing.expectError(error.InvalidActivityPage, ActivityPage.parse(writer.buffered(), .{}));
    }
}

test "a turn_ended row's ending agrees with its saved code and content, and a final answer crosses" {
    const content: content_value.Reference = .{ .length = 1, .digest = @splat(1) };
    const Case = struct { ending: protocol.TurnEnding, code: []const u8, content: ?content_value.Reference, valid: bool };
    for ([_]Case{
        .{ .ending = .done, .code = "completed", .content = content, .valid = true },
        .{ .ending = .done, .code = "completed", .content = null, .valid = false },
        .{ .ending = .done, .code = "provider_policy", .content = content, .valid = false },
        .{ .ending = .stopped, .code = "cancelled", .content = null, .valid = true },
        .{ .ending = .interrupted, .code = "cancelled", .content = null, .valid = true },
        .{ .ending = .interrupted, .code = "cancelled", .content = content, .valid = false },
        .{ .ending = .failed, .code = "cancelled", .content = null, .valid = false },
        .{ .ending = .provider_refused, .code = "provider_policy", .content = content, .valid = true },
        .{ .ending = .context_full, .code = "ResourceExceeded", .content = null, .valid = true },
    }) |case| {
        var code: protocol.Bounded(protocol.max_code_bytes) = .{};
        try code.set(case.code);
        var facts: protocol.ActivityFacts = .{ .end = 2, .count = 2, .work = .{ .work = .{ .state = .{ .idle = .{ .since = 1 } } }, .revision = 1 } };
        facts.items[0] = .{ .position = 1, .at = 1, .value = .{ .assistant = .{ .content = content, .final = case.ending == .done } } };
        facts.items[1] = .{ .position = 2, .at = 1, .value = .{ .turn_ended = .{ .session = .{ .bytes = "k7m2qx".*, .len = 6 }, .turn = 1, .operation = 1, .ending = case.ending, .code = code, .content = case.content } } };
        try facts.work.workspace.set("/w");
        var buffer: [activity_reply.max_page_bytes]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try activity_reply.writePage(&writer, &facts);
        if (!case.valid) {
            try std.testing.expectError(error.InvalidActivityPage, ActivityPage.parse(writer.buffered(), .{}));
            continue;
        }
        const page = try ActivityPage.parse(writer.buffered(), .{});
        try std.testing.expectEqual(case.ending == .done, page.facts.items[0].value.assistant.final);
        try std.testing.expectEqual(case.ending, page.facts.items[1].value.turn_ended.ending);
    }
}

test "an activity row carries its time, and a Message's rows carry its admission time" {
    const content: content_value.Value = .{ .text = .{ .length = 0, .digest = protocol.contentDigest("") } };
    const message: protocol.ActivityItem.Message = .{ .admission = 1, .key = .{}, .turn = null, .state = .queued, .content = content, .admitted_at = 1792925000 };
    var peer: protocol.NamedPeer = .{ .session = .{} };
    try peer.session.set("k7m2qx");
    const sent: protocol.ActivityItem.Sent = .{ .admission = 2, .target = peer, .content = content, .admitted_at = 1792925000 };
    for ([_]struct { value: protocol.ActivityItem.Value, at: u64, failure: ?anyerror = null }{
        .{ .value = .{ .admission = message }, .at = 1792925000 },
        .{ .value = .{ .admission = message }, .at = 1792925001, .failure = error.InvalidActivityPage },
        .{ .value = .{ .sent = sent }, .at = 1792925000 },
        .{ .value = .{ .sent = sent }, .at = 1, .failure = error.InvalidActivityPage },
        .{ .value = .{ .assistant = .{ .content = content.text } }, .at = 0, .failure = error.InvalidResponse },
    }) |case| {
        var facts: protocol.ActivityFacts = .{ .end = 1, .count = 1, .work = .{ .work = .{ .state = .{ .idle = .{ .since = 1 } } }, .revision = 1 } };
        facts.items[0] = .{ .position = 1, .at = case.at, .value = case.value };
        try facts.work.workspace.set("/w");
        var buffer: [activity_reply.max_page_bytes]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try activity_reply.writePage(&writer, &facts);
        if (case.failure) |failure| {
            try std.testing.expectError(failure, ActivityPage.parse(writer.buffered(), .{}));
        } else try std.testing.expectEqual(case.at, (try ActivityPage.parse(writer.buffered(), .{})).facts.items[0].at);
    }
    for ([_][]const u8{ "Review the WAL", "" }) |label| {
        var named = sent;
        try named.target.label.set(label);
        var facts: protocol.ActivityFacts = .{ .end = 1, .count = 1, .work = .{ .work = .{ .state = .{ .idle = .{ .since = 1 } } }, .revision = 1 } };
        facts.items[0] = .{ .position = 1, .at = 1792925000, .value = .{ .sent = named } };
        try facts.work.workspace.set("/w");
        var buffer: [activity_reply.max_page_bytes]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try activity_reply.writePage(&writer, &facts);
        const target = (try ActivityPage.parse(writer.buffered(), .{})).facts.items[0].value.sent.target;
        try std.testing.expectEqualStrings(label, target.label.slice());
        try std.testing.expectEqualStrings(if (label.len == 0) "k7m2qx" else label, target.name());
    }
    var facts: protocol.ActivityFacts = .{ .end = 1, .count = 1, .work = .{ .work = .{ .state = .{ .idle = .{ .since = 1 } } }, .revision = 1 } };
    facts.items[0] = .{ .position = 1, .at = 7, .value = .{ .assistant = .{ .content = content.text } } };
    try facts.work.workspace.set("/w");
    var buffer: [activity_reply.max_page_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try activity_reply.writePage(&writer, &facts);
    const field = ",\"at\":\"7\"";
    const at = std.mem.indexOf(u8, writer.buffered(), field).?;
    var missing: [activity_reply.max_page_bytes]u8 = undefined;
    const bytes = try std.fmt.bufPrint(&missing, "{s}{s}", .{ writer.buffered()[0..at], writer.buffered()[at + field.len ..] });
    try std.testing.expectError(error.InvalidActivityPage, ActivityPage.parse(bytes, .{}));
}

test "refused peer activity retains absent and canonical targets" {
    for ([_]bool{ false, true }) |has_target| {
        var target: protocol.NamedPeer = .{ .session = .{} };
        try target.session.set("absent");
        var failure: protocol.ActivityItem.SendFailed = .{ .key = .{}, .target = if (has_target) target else null, .code = .{} };
        try failure.key.set("refused");
        try failure.code.set(if (has_target) "unknown_session" else "invalid_session_reference");
        var facts: protocol.ActivityFacts = .{ .end = 1, .count = 1, .work = .{ .work = .{ .state = .{ .idle = .{ .since = 1 } } }, .revision = 1 } };
        facts.items[0] = .{ .position = 1, .at = 7, .value = .{ .send_failed = failure } };
        try facts.work.workspace.set("/w");
        var buffer: [activity_reply.max_page_bytes]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try activity_reply.writePage(&writer, &facts);
        const decoded = (try ActivityPage.parse(writer.buffered(), .{})).facts.items[0].value.send_failed;
        try std.testing.expectEqualStrings(failure.key.slice(), decoded.key.slice());
        try std.testing.expectEqualStrings(failure.code.slice(), decoded.code.slice());
        if (has_target) {
            try std.testing.expectEqualStrings("absent", decoded.target.?.session.slice());
        } else try std.testing.expect(decoded.target == null);
    }
}

test "SUI-47 work state wire preserves owned facts" {
    var cause: protocol.Bounded(protocol.max_code_bytes) = .{};
    try cause.set("provider_temporary_http_429");
    var quota: protocol.Bounded(protocol.max_code_bytes) = .{};
    try quota.set("provider_quota");
    var description: protocol.Bounded(protocol.session_work.max_description_bytes) = .{};
    try description.set(&@as([protocol.session_work.max_description_bytes]u8, @splat(1)));
    const states = [_]protocol.WorkState{
        .{ .idle = .{ .since = 1 } },
        .{ .pending = .{ .since = 2 } },
        .{ .working = .{ .since = 3 } },
        .{ .working = .{ .since = 3, .compaction = true } },
        .{ .retrying = .{ .since = 4, .due_at_ms = 4_500, .cause = cause, .attempt = 2 } },
        .{ .bash = .{ .since = 5, .call = 0, .description = description, .running = 1, .approvals = 0 } },
        .{ .bash = .{ .since = 5, .call = 3, .description = null, .running = 2, .approvals = 3 } },
        .{ .bash = .{ .since = 5, .call = null, .description = description, .running = 1, .approvals = 0 } },
        .{ .approval = .{ .since = 6 } },
        .{ .stopping = .{ .since = 7 } },
        .{ .finished = .{ .since = 8 } },
        .{ .failed = .{ .since = 9, .code = quota, .resets_at = 1792940000 } },
        .{ .failed = .{ .since = 9, .code = cause, .resets_at = null } },
        .{ .stopped = .{ .since = 10, .cause = .interruption } },
        .{ .stopped = .{ .since = 10, .cause = .stop } },
    };
    for (states) |state| {
        var buffer: [protocol.WorkStateJson.max_json_bytes]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try (protocol.WorkStateJson{ .state = state }).writeJson(&writer);
        const parsed = try std.json.parseFromSlice(JsonWorkState, std.testing.allocator, writer.buffered(), .{});
        defer parsed.deinit();
        try std.testing.expectEqual(std.meta.activeTag(state), std.meta.activeTag(parsed.value.value));
        if (state == .working) {
            try std.testing.expectEqual(state.working.since, parsed.value.value.working.since);
            try std.testing.expectEqual(state.working.compaction, parsed.value.value.working.compaction);
        }
        var again: [protocol.WorkStateJson.max_json_bytes]u8 = undefined;
        var again_writer = std.Io.Writer.fixed(&again);
        try std.json.Stringify.value(parsed.value, .{}, &again_writer);
        try std.testing.expectEqualStrings(writer.buffered(), again_writer.buffered());
        if (state != .working) {
            var forged: [protocol.WorkStateJson.max_json_bytes + 24]u8 = undefined;
            const bytes = try std.fmt.bufPrint(&forged, "{s},\"compaction\":true}}", .{writer.buffered()[0 .. writer.buffered().len - 1]});
            try std.testing.expectError(error.InvalidCharacter, std.json.parseFromSlice(JsonWorkState, std.testing.allocator, bytes, .{}));
        }
    }
    for ([_][]const u8{
        "{\"kind\":\"bash\",\"since\":\"5\",\"description\":null,\"running\":\"1\",\"approvals\":\"0\"}",
        "{\"kind\":\"bash\",\"since\":\"5\",\"call\":\"3\",\"description\":null,\"running\":\"1\",\"approvals\":\"0\"}",
    }, [_]?u64{ null, 3 }) |bytes, call| {
        const parsed = try std.json.parseFromSlice(JsonWorkState, std.testing.allocator, bytes, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(call, parsed.value.value.bash.call);
    }
    for ([_]bool{ false, true }) |compaction| {
        var bytes: [80]u8 = undefined;
        const text = try std.fmt.bufPrint(&bytes, "{{\"kind\":\"working\",\"since\":\"3\",\"compaction\":{}}}", .{compaction});
        const parsed = try std.json.parseFromSlice(JsonWorkState, std.testing.allocator, text, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(compaction, parsed.value.value.working.compaction);
    }
    for ([_][]const u8{
        "{\"kind\":\"idle\",\"since\":\"1\",\"cause\":\"stop\"}",
        "{\"kind\":\"retrying\",\"since\":\"4\",\"due_at_ms\":\"4500\",\"cause\":\"c\"}",
        "{\"kind\":\"bash\",\"since\":\"5\",\"running\":\"1\",\"approvals\":\"0\"}",
        "{\"kind\":\"working\",\"since\":\"3\",\"call\":\"0\"}",
        "{\"kind\":\"pending\",\"since\":\"3\",\"compaction\":true}",
        "{\"kind\":\"working\",\"since\":\"3\",\"compaction\":null}",
        "{\"kind\":\"working\",\"since\":\"3\",\"compaction\":\"true\"}",
        "{\"kind\":\"failed\",\"since\":\"9\",\"code\":\"c\"}",
        "{\"kind\":\"pending\",\"since\":\"0\"}",
        "{\"kind\":\"pending\",\"since\":2}",
        "{\"kind\":\"later\",\"since\":\"2\"}",
        "{\"kind\":\"bash\",\"since\":\"5\",\"call\":\"0\",\"description\":\"\",\"running\":\"1\",\"approvals\":\"0\"}",
        "{\"kind\":\"bash\",\"since\":\"5\",\"call\":\"0\",\"description\":null,\"running\":\"0\",\"approvals\":\"0\"}",
        "{\"kind\":\"bash\",\"since\":\"5\",\"call\":0,\"description\":null,\"running\":\"1\",\"approvals\":\"0\"}",
        "{\"kind\":\"failed\",\"since\":\"9\",\"code\":\"\",\"resets_at\":null}",
        "{\"kind\":\"failed\",\"since\":\"9\",\"code\":\"provider_http_401\",\"resets_at\":\"5\"}",
        "{\"kind\":\"stopped\",\"since\":\"10\",\"cause\":\"timeout\"}",
        "{\"kind\":\"retrying\",\"since\":\"4\",\"due_at_ms\":\"4500\",\"cause\":\"c\",\"attempt\":\"4\"}",
    }) |bytes| {
        try std.testing.expect(std.meta.isError(std.json.parseFromSlice(JsonWorkState, std.testing.allocator, bytes, .{})));
    }
}

test "shape decoder delegates JSON holes and releases parser allocations" {
    const Payload = struct {
        pub const max_json_bytes = 64;
    };
    const Bindings = struct {
        pub fn Type(comptime T: type) type {
            if (T == Payload) return struct { count: wire_field.JsonString(20) };
            @compileError("unexpected JSON hole");
        }
    };
    const shape = .{ "{\"payload\":", protocol.Hole{ .json = Payload }, ",\"next\":", protocol.Hole.optional_id, ",\"absent\":null}" };
    const D = @import("command_reply.zig").DecoderWithJson(shape, .{shape}, Bindings);
    const Check = struct {
        fn run(allocator: std.mem.Allocator, invalid: bool) !void {
            const valid = "{\"paylo\\u0061d\":{\"count\":\"\\u0037\",\"extra\":[{}]},\"next\":null,\"absent\":null}";
            const result = D.parse(allocator, if (invalid) valid ++ " {}" else valid);
            const value = result catch |err| {
                if (err == error.OutOfMemory) return err;
                try std.testing.expect(invalid);
                return;
            };
            try std.testing.expect(!invalid);
            try std.testing.expect(value.payload.count.eql("7"));
            try std.testing.expect(value.next == null and value.absent == null);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{false});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{true});
}

test "canonical presentation releases allocations on acceptance and late rejection" {
    const Check = struct {
        fn run(allocator: std.mem.Allocator, invalid: bool) !void {
            const bytes = "{\"description\":\"Read \\u20ac files\",\"code\":\"su\\u0063ceeded\",\"publication_position\":";
            const result: anyerror!JsonToolPresentation = decode: {
                var scanner = std.json.Scanner.initCompleteInput(allocator, if (invalid)
                    bytes ++ "\"9223372036854775808\"}"
                else
                    bytes ++ "\"9223372036854775807\"}");
                defer scanner.deinit();
                break :decode std.json.parseFromTokenSourceLeaky(JsonToolPresentation, allocator, &scanner, .{});
            };
            const value = (result catch |err| {
                if (err == error.OutOfMemory) return err;
                try std.testing.expect(invalid);
                try std.testing.expectEqual(error.InvalidCharacter, err);
                return;
            }).value;
            try std.testing.expect(!invalid);
            try std.testing.expectEqualStrings("Read € files", value.description.?.slice());
            try std.testing.expectEqual(protocol.ToolPresentation.Code.succeeded, value.code);
            try std.testing.expectEqual(@as(?u64, 9223372036854775807), value.publication_position);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{false});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{true});
}

pub fn decodeReadFailure(reply: CommandReply, result_read: bool) !ReadFailure {
    if (reply.body.len > protocol.max_response_bytes) return error.InvalidResponse;
    const Wire = struct {
        version: JsonString(8),
        type: JsonString(32),
        code: JsonString(protocol.max_code_bytes),
        observation: OmittableJson(struct {}) = .{},
        answer: OmittableJson(struct {}) = .{},
    };
    const capacity = comptime std.ArrayList(u8).growCapacity((protocol.max_response_bytes + 7) / 8) + std.ArrayList(u8).growCapacity(protocol.max_response_bytes);
    var storage: [capacity]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var scanner = std.json.Scanner.initCompleteInput(fixed.allocator(), reply.body);
    defer scanner.deinit();
    scanner.ensureTotalStackCapacity(protocol.max_response_bytes) catch unreachable;
    const wire = std.json.parseFromTokenSourceLeaky(Wire, fixed.allocator(), &scanner, .{ .ignore_unknown_fields = true }) catch return error.InvalidResponse;
    if (wire.observation.value != null or wire.answer.value != null) return error.InvalidResponse;
    const failure: ReadFailure = .{ .status = reply.status, .diagnostic = .{ .type = wire.type.value, .code = wire.code.value } };
    try validateInvocationDiagnostic(reply.status, wire.version.slice(), failure.diagnostic);
    if (wire.type.eql("result_unavailable") and (!result_read or reply.status != 409 or
        (!wire.code.eql("result_not_found") and !wire.code.eql("result_not_ready") and !wire.code.eql("result_failed")))) return error.InvalidResponse;
    return failure;
}

pub fn decodeMutationReply(reply: CommandReply, session: []const u8, target: MutationTarget) MutationReply {
    var result: MutationReply = .{ .status = reply.status, .context = .{ .kind = target }, .target = target, .answer = error.InvalidResponse };
    result.context.session.set(session) catch return result;
    var resolved = result.context.session;
    result.answer = decodeMutationAnswer(reply, session, target, &result.diagnostic, &resolved);
    if (result.answer) |_| result.context.session = resolved else |_| {}
    return result;
}

fn decodeMutationAnswer(reply: CommandReply, session: []const u8, target: MutationTarget, diagnostic: *?InvocationDiagnostic, resolved_session: *protocol.Bounded(protocol.max_session_bytes)) @FieldType(MutationReply, "answer") {
    if (reply.body.len > protocol.max_response_bytes) return error.InvalidResponse;
    const capacity = comptime std.ArrayList(u8).growCapacity((protocol.max_response_bytes + 7) / 8) + std.ArrayList(u8).growCapacity(protocol.max_response_bytes);
    var storage: [capacity]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    return mutation_answer.decode(protocol, @import("command_reply.zig"), fixed.allocator(), reply.body, reply.status, session, target, diagnostic, resolved_session);
}

test "mutation decoder bounds reply bytes and rejects trailing input" {
    const digest = protocol.contentDigest("a\nµ");
    const target: MutationTarget = .{ .message = .{ .bytes = 4, .digest = digest } };
    const prefix = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"message_reply\",\"answer\":{\"status\":\"accepted\",\"replayed\":false,\"session\":\"k7m2q\\u0078\",\"admission\":\"7\"}";
    var suffix_storage: [256]u8 = undefined;
    const suffix = try std.fmt.bufPrint(&suffix_storage, ",\"input\":{{\"type\":\"text\",\"bytes\":\"4\",\"sha256\":\"{s}\"}},\"queue\":{{\"status\":\"queued\",\"admission\":\"7\"}},\"execution\":{{\"status\":\"queued\"}}}}", .{std.fmt.bytesToHex(digest, .lower)});
    var body: [protocol.max_response_bytes + 1]u8 = undefined;
    const valid = try std.fmt.bufPrint(&body, "{s}{s}", .{ prefix, suffix });
    _ = try decodeMutationReply(.{ .status = 200, .body = valid }, "k7m2qx", target).answer;
    @memset(body[valid.len..protocol.max_response_bytes], ' ');
    _ = try decodeMutationReply(.{ .status = 200, .body = body[0..protocol.max_response_bytes] }, "k7m2qx", target).answer;
    body[protocol.max_response_bytes] = ' ';
    try std.testing.expectError(error.InvalidResponse, decodeMutationReply(.{ .status = 200, .body = &body }, "k7m2qx", target).answer);
    const malformed = try std.fmt.bufPrint(&body, "{s}{s} trailing", .{ prefix, suffix });
    try std.testing.expectError(error.InvalidResponse, decodeMutationReply(.{ .status = 200, .body = malformed }, "k7m2qx", target).answer);
}

test "mutation diagnostics own complete validated metadata without raw reply lifetime" {
    const body = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"invocation_error\",\"co\\u0064e\":\"busy\\u002fµ\",\"extra\":[null,{}]}";
    var bytes: [body.len]u8 = body.*;
    const reply = decodeMutationReply(.{ .status = 409, .body = &bytes }, "original/session", .configure);
    @memset(&bytes, 'x');
    try std.testing.expectError(error.HostInvocationFailed, reply.answer);
    try std.testing.expect(reply.diagnostic != null);
    try std.testing.expectEqualStrings("busy/µ", reply.diagnostic.?.code.slice());
    try std.testing.expectEqualStrings("invocation_error", reply.diagnostic.?.type.slice());
    try std.testing.expectEqualStrings("original/session", reply.context.session.slice());
}

pub const MutationIdentity = struct {
    store: protocol.Bounded(protocol.max_store_bytes) = .{},
    key: protocol.Bounded(protocol.max_key_bytes) = .{},
    session: protocol.Bounded(protocol.max_session_bytes) = .{},
    kind: protocol.CommandKind,
};

pub fn checkCanonicalFailure(reply: CommandReply) !void {
    if (reply.status == 200) return;
    if (reply.body.len > protocol.max_response_bytes) return error.InvalidResponse;
    const Envelope = struct {
        const Field = enum {
            other,
            current_version,
            invocation_error,
            canonical,

            pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
                // A plain []const u8 field also accepts JSON byte arrays.
                if (try source.peekNextTokenType() != .string) return error.UnexpectedToken;
                const token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
                defer if (token == .allocated_string) allocator.free(token.allocated_string);
                const value = switch (token) {
                    .string, .allocated_string => |string| string,
                    else => unreachable,
                };
                if (std.mem.eql(u8, value, protocol.wire_version)) return .current_version;
                if (std.mem.eql(u8, value, "invocation_error")) return .invocation_error;
                return if (std.mem.eql(u8, value, "canonical_store_failure")) .canonical else .other;
            }
        };

        version: Field = .other,
        type: Field = .other,
        code: Field = .other,
    };
    // Reserve nesting first, including malformed N-opening-delimiter prefixes.
    // Names/fields decode one byte string at a time and free it before advancing.
    // With stack growth excluded, FBA grows/shrinks that last allocation in
    // place. Both byte arrays are bounded by stdlib's capacity growth formula.
    const capacity = comptime std.ArrayList(u8).growCapacity((protocol.max_response_bytes + 7) / 8) +
        std.ArrayList(u8).growCapacity(protocol.max_response_bytes);
    var storage: [capacity]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    const allocator = fixed.allocator();
    var scanner = std.json.Scanner.initCompleteInput(allocator, reply.body);
    defer scanner.deinit();
    scanner.ensureTotalStackCapacity(protocol.max_response_bytes) catch unreachable;
    const envelope = std.json.parseFromTokenSourceLeaky(Envelope, allocator, &scanner, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => unreachable,
        else => return error.InvalidResponse,
    };
    if (envelope.code == .canonical) {
        var diagnostic: InvocationDiagnostic = .{ .type = .{}, .code = .{} };
        diagnostic.code.set("canonical_store_failure") catch unreachable;
        if (envelope.type == .invocation_error) diagnostic.type.set("invocation_error") catch unreachable;
        try validateInvocationDiagnostic(reply.status, if (envelope.version == .current_version) protocol.wire_version else "", diagnostic);
        return error.CanonicalStoreFailure;
    }
}

test "canonical failure classifier validates complete string-only error envelope" {
    const canonical = [_][]const u8{
        "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"invocation_error\",\"code\":\"canonical_store_failure\"}",
        "{\"vers\\u0069on\":\"" ++ protocol.wire_version ++ "\",\"ty\\u0070e\":\"invocation_\\u0065rror\",\"co\\u0064e\":\"canonical_store_\\u0066ailure\",\"extra\":[1,{}]}",
        "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"invocation_error\",\"code\":\"canonical_store_failure\",\"extra\":{\"x\":1,\"x\":2},\"extra\":null}",
    };
    for (canonical) |body| try std.testing.expectError(error.CanonicalStoreFailure, checkCanonicalFailure(.{ .status = 500, .body = body }));
    const prefix = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"invocation_error\",";
    for ([_][]const u8{
        prefix ++ "\"code\":\"canonical_store_failure\",\"co\\u0064e\":\"other\"}",
        prefix ++ "\"code\":\"canonical_store_failure\",\"extra\":[}",
        prefix ++ "\"code\":\"canonical_store_failure\"} trailing",
        prefix ++ "\"code\":null}",
        prefix ++ "\"code\":[99,97,110,111,110,105,99,97,108,95,115,116,111,114,101,95,102,97,105,108,117,114,101]}",
        "[]",
    }) |body| try std.testing.expectError(error.InvalidResponse, checkCanonicalFailure(.{ .status = 500, .body = body }));
    try checkCanonicalFailure(.{ .status = 503, .body = "{\"code\":\"unavailable\"}" });
    try checkCanonicalFailure(.{ .status = 500, .body = "{\"extra\":\"canonical_store_failure\"}" });
    try checkCanonicalFailure(.{ .status = 200, .body = "not an error envelope" });
}

test "canonical failure classifier uses only authoritative invocation envelope" {
    for ([_][]const u8{
        "{\"code\":\"canonical_store_failure\"}",
        "{\"version\":\"" ++ protocol.next_wire_version ++ "\",\"type\":\"invocation_error\",\"code\":\"canonical_store_failure\"}",
        "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"message_reply\",\"code\":\"canonical_store_failure\"}",
        "{\"version\":\"" ++ protocol.wire_version ++ "\",\"vers\\u0069on\":\"" ++ protocol.wire_version ++ "\",\"type\":\"invocation_error\",\"code\":\"canonical_store_failure\"}",
        "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"invocation_error\",\"ty\\u0070e\":\"message_reply\",\"code\":\"canonical_store_failure\"}",
        "{\"version\":null,\"type\":\"invocation_error\",\"code\":\"canonical_store_failure\"}",
        "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":[105],\"code\":\"canonical_store_failure\"}",
        "{\"answer\":{\"code\":\"canonical_store_failure\",\"extra\":[}}",
    }) |body| try std.testing.expectError(error.InvalidResponse, checkCanonicalFailure(.{ .status = 500, .body = body }));
    for ([_][]const u8{
        "{}",
        "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"message_reply\",\"answer\":{\"status\":\"infrastructure_failure\",\"code\":\"canonical_store_failure\"}}",
        "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"invocation_error\",\"code\":\"unavailable\",\"answer\":{\"code\":\"canonical_store_failure\"}}",
        "{\"answer\":{\"code\":\"unavailable\"}}",
        "{\"answer\":{\"extra\":{\"code\":\"canonical_store_failure\"}}}",
        "{\"extra\":{\"answer\":{\"code\":\"canonical_store_failure\"}}}",
    }) |body| try checkCanonicalFailure(.{ .status = 500, .body = body });
    const body = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"invocation_error\",\"code\":\"canonical_store_failure\"}";
    try std.testing.expectError(error.InvalidResponse, checkCanonicalFailure(.{ .status = 409, .body = body }));
}

test "canonical failure classifier bounds deep wide and escaped maximum replies" {
    const prefix = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"invocation_error\",\"code\":\"canonical_store_failure\",\"extra\":";
    var body: [protocol.max_response_bytes + 1]u8 = undefined;
    @memcpy(body[0..prefix.len], prefix);
    const depth = (protocol.max_response_bytes - prefix.len - 2) / 2;
    @memset(body[prefix.len..][0..depth], '[');
    var length = prefix.len + depth;
    body[length] = '0';
    length += 1;
    @memset(body[length..][0..depth], ']');
    length += depth;
    body[length] = '}';
    length += 1;
    @memset(body[length..protocol.max_response_bytes], ' ');
    try std.testing.expectError(error.CanonicalStoreFailure, checkCanonicalFailure(.{ .status = 500, .body = body[0..protocol.max_response_bytes] }));
    @memset(body[prefix.len..protocol.max_response_bytes], '[');
    try std.testing.expectError(error.InvalidResponse, checkCanonicalFailure(.{ .status = 500, .body = body[0..protocol.max_response_bytes] }));

    const field_prefix = "{\"";
    const field_suffix = "\":0,\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"invocation_error\",\"co\\u0064e\":\"canonical_store_\\u0066ailure\"}";
    @memcpy(body[0..field_prefix.len], field_prefix);
    length = field_prefix.len;
    const escaped_end = protocol.max_response_bytes - field_suffix.len - 6;
    @memset(body[length..escaped_end], 'x');
    length = escaped_end;
    @memcpy(body[length..][0..6], "\\u0078");
    length += 6;
    @memcpy(body[length..][0..field_suffix.len], field_suffix);
    length += field_suffix.len;
    @memset(body[length..protocol.max_response_bytes], ' ');
    try std.testing.expectError(error.CanonicalStoreFailure, checkCanonicalFailure(.{ .status = 500, .body = body[0..protocol.max_response_bytes] }));

    @memcpy(body[0..prefix.len], prefix);
    length = prefix.len;
    const wide = "{\"x\":0,\"x\":0}";
    body[length] = '[';
    length += 1;
    while (length + wide.len + 3 <= protocol.max_response_bytes) {
        @memcpy(body[length..][0..wide.len], wide);
        length += wide.len;
        body[length] = ',';
        length += 1;
    }
    length -= 1;
    @memcpy(body[length..][0..2], "]}");
    length += 2;
    @memset(body[length..protocol.max_response_bytes], ' ');
    try std.testing.expectError(error.CanonicalStoreFailure, checkCanonicalFailure(.{ .status = 500, .body = body[0..protocol.max_response_bytes] }));
    body[protocol.max_response_bytes] = ' ';
    try std.testing.expectError(error.InvalidResponse, checkCanonicalFailure(.{ .status = 500, .body = &body }));

    @memcpy(body[0..prefix.len], prefix);
    length = prefix.len;
    const names = "\"ignored\",\"\\u0061\":0,";
    @memcpy(body[length..][0..names.len], names);
    length += names.len;
    const name = "\"\\u0061\":0,";
    while (length + name.len + 1 <= protocol.max_response_bytes) {
        @memcpy(body[length..][0..name.len], name);
        length += name.len;
    }
    length -= 1;
    body[length] = '}';
    length += 1;
    @memset(body[length..protocol.max_response_bytes], ' ');
    try std.testing.expectError(error.CanonicalStoreFailure, checkCanonicalFailure(.{ .status = 500, .body = body[0..protocol.max_response_bytes] }));
}

const testing_list_facts = "],\"delta\":\"full\",\"since\":\"abababababababababababababababab.42\",\"next\":";
const testing_row_facts = ",\"read_version\":\"00000000000000000000000000000000.0\",\"archive_state\":\"active\",\"pin_order\":null" ++ testing_row_details;
const testing_row_details = ",\"parent\":null,\"creator\":null,\"label\":null,\"created_at\":\"1\",\"state_change_at\":\"1\",\"subtree_state_change_at\":\"1\",\"descendant_count\":\"0\",\"descendant_needs_you_count\":\"0\",\"revision\":\"1\",\"end\":\"0\",\"first_message\":null,\"last_line\":null," ++
    "\"work\":{\"state\":{\"kind\":\"idle\",\"since\":\"1\"},\"turn\":null,\"operation\":null,\"first_action\":null,\"attention\":null,\"group\":\"done\",\"actions\":{\"stop\":false,\"interrupt\":null,\"decide\":null}},\"peers\":{\"from_person_at\":null}";
const testing_started_row_facts = ",\"read_version\":\"00000000000000000000000000000000.0\",\"archive_state\":\"active\",\"pin_order\":null,\"parent\":null,\"creator\":null,\"label\":\"Review PR 412\",\"created_at\":\"1792925000\",\"state_change_at\":\"1792925300\",\"subtree_state_change_at\":\"1792925400\",\"descendant_count\":\"2\",\"descendant_needs_you_count\":\"1\",\"revision\":\"1\",\"end\":\"9\"," ++
    "\"first_message\":{\"position\":\"1\",\"admission\":\"4\",\"admitted_at\":\"1792925001\",\"sender\":null,\"content\":{\"type\":\"text\",\"bytes\":\"5\",\"sha256\":\"" ++ @as([64]u8, @splat('a')) ++ "\"}}," ++
    "\"last_line\":null,\"work\":{\"state\":{\"kind\":\"working\",\"since\":\"1792925300\"},\"turn\":\"2\",\"operation\":\"6\",\"first_action\":null,\"attention\":null,\"group\":\"done\",\"actions\":{\"stop\":false,\"interrupt\":null,\"decide\":null}},\"peers\":{\"from_person_at\":\"1792925001\"}";

fn listValidationCase0() !void {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "page", .{ .read = true });
    defer file.close(io);
    const digest = @as([64]u8, @splat('a'));
    const facts = "\"read_version\":\"00000000000000000000000000000000.0\",\"archive_state\":\"active\",\"pin_order\":null,\"parent\":\"p33rs1\",\"creator\":\"cr3at0\",\"label\":\"Review \\u0050R\",\"created_at\":\"1792925000\",\"state_change_at\":\"1792925300\",\"subtree_state_change_at\":\"1792925400\",\"descendant_count\":\"2\",\"descendant_needs_you_count\":\"1\",\"revision\":\"3\",\"end\":\"9\"," ++
        "\"first_message\":{\"position\":\"1\",\"admission\":\"4\",\"admitted_at\":\"1792925001\",\"sender\":{\"session\":\"p33rs1\"},\"content\":{\"type\":\"text\",\"bytes\":\"5\",\"sha256\":\"" ++ digest ++ "\"}}," ++
        "\"last_line\":{\"position\":\"8\",\"text\":\"Saved preview\"},\"work\":{\"state\":{\"kind\":\"bash\",\"since\":\"1792925300\",\"call\":\"0\",\"description\":\"Run the tests\",\"running\":\"1\",\"approvals\":\"0\"},\"turn\":\"2\",\"operation\":\"6\",\"first_action\":null,\"attention\":{\"kind\":\"approval\",\"turn\":\"2\",\"step\":\"8\"},\"group\":\"needs_you\",\"actions\":{\"stop\":true,\"interrupt\":{\"turn\":\"2\",\"operation\":\"6\"},\"decide\":null}}," ++
        "\"peers\":{\"from_person_at\":\"1792925200\"}";
    const wire = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"session_list\",\"sessions\":[{\"reference\":\"k7m2q\\u0078\",\"archive_seq\":null,\"workspace\":\"/w\\nµ\",\"provider\":\"codex\",\"model\":\"m\\\"\",\"tools\":[\"bash\"],\"permission_mode\":\"ask\"," ++
        facts ++ ",\"extra\":[null,{\"discard\":true}]}" ++ testing_list_facts ++ "null,\"extra\":1}";
    try file.writePositionalAll(io, wire, 0);
    const decoded = try SessionListReply.decode(io, file, "/w\nµ", .{}, .{ .report = .{ .bytes = wire.len } });
    const page = &decoded.page;
    try file.writePositionalAll(io, &@as([wire.len]u8, @splat('x')), 0);
    try std.testing.expectEqual(@as(usize, 1), page.count);
    const row = &page.rows[0];
    try std.testing.expectEqualStrings("k7m2qx", row.reference.slice());
    try std.testing.expectEqualStrings("p33rs1", row.parent.?.slice());
    try std.testing.expectEqualStrings("cr3at0", row.creator.?.slice());
    try std.testing.expectEqualStrings("/w\nµ", row.workspace.slice());
    try std.testing.expectEqualStrings("Review PR", row.label.?.slice());
    try std.testing.expectEqual(@as(u64, 1792925000), row.created_at);
    try std.testing.expectEqual(@as(u64, 1792925300), row.state_change_at);
    try std.testing.expectEqual(@as(u64, 1792925400), row.subtree_state_change_at);
    try std.testing.expectEqual(@as(u64, 2), row.descendant_count);
    try std.testing.expectEqual(@as(u64, 1), row.descendant_needs_you_count);
    try std.testing.expectEqual(@as(u64, 9), row.end);
    try std.testing.expectEqual(@as(u64, 8), row.last_line.?.position);
    try std.testing.expectEqualStrings("Saved preview", row.last_line.?.text.?.slice());
    try std.testing.expectEqualStrings("p33rs1", row.first_message.?.sender.?.session.slice());
    try std.testing.expectEqual(@as(u64, 1792925300), row.work.state.since());
    try std.testing.expectEqualStrings("Run the tests", row.work.state.bash.description.?.slice());
    try std.testing.expectEqual(@import("session_work.zig").Group.needs_you, row.work.group);
    try std.testing.expectEqualDeep(@as(?@import("session_work.zig").Attention, .{ .kind = .approval, .turn = 2, .step = 8 }), row.work.attention);
    try std.testing.expectEqualDeep(@import("session_work.zig").Actions{ .stop = true, .interrupt = .{ .turn = 2, .operation = 6 } }, row.work.actions);
    try std.testing.expectEqual(@as(?u64, 1792925200), row.peers.from_person_at);
    var output: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    try page.writeJson(&writer);
    try std.testing.expectEqualStrings("{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"session_list\",\"sessions\":[{\"read_version\":\"00000000000000000000000000000000.0\",\"archive_state\":\"active\",\"pin_order\":null,\"reference\":\"k7m2qx\",\"archive_seq\":null,\"workspace\":\"/w\\nµ\",\"provider\":\"codex\",\"model\":\"m\\\"\",\"tools\":[\"bash\"],\"permission_mode\":\"ask\"," ++
        "\"parent\":\"p33rs1\",\"creator\":\"cr3at0\",\"label\":\"Review PR\"" ++ facts["\"read_version\":\"00000000000000000000000000000000.0\",\"archive_state\":\"active\",\"pin_order\":null,\"parent\":\"p33rs1\",\"creator\":\"cr3at0\",\"label\":\"Review \\u0050R\"".len..] ++ "}" ++ testing_list_facts ++ "null}", writer.buffered());
    var exhausted = std.Io.Writer.fixed(&.{});
    try std.testing.expectError(error.WriteFailed, page.writeJson(&exhausted));
    for ([_][]const u8{
        "\"attention\":{\"kind\":\"approval\",\"turn\":\"2\",\"step\":\"8\"},",
        "\"group\":\"needs_you\",",
        ",\"actions\":{\"stop\":true,\"interrupt\":{\"turn\":\"2\",\"operation\":\"6\"},\"decide\":null}",
    }) |field| {
        try std.testing.expect(std.mem.indexOf(u8, wire, field) != null);
        const missing = try std.mem.replaceOwned(u8, std.testing.allocator, wire, field, "");
        defer std.testing.allocator.free(missing);
        try file.writePositionalAll(io, missing, 0);
        try std.testing.expectError(error.InvalidSessionPage, SessionListPage.read(io, file, missing.len, "/w\nµ", .{}));
    }
    const collision = try std.mem.replaceOwned(u8, std.testing.allocator, wire, "\"interrupt\":{\"turn\":\"2\",\"operation\":\"6\"}", "\"interrupt\":null");
    defer std.testing.allocator.free(collision);
    try file.writePositionalAll(io, collision, 0);
    const decoded_collision = try SessionListReply.decode(io, file, "/w\nµ", .{}, .{ .report = .{ .bytes = collision.len } });
    const other = decoded_collision.page.rows[0].work;
    try std.testing.expectEqualDeep(row.work.state, other.state);
    try std.testing.expectEqual(row.work.turn, other.turn);
    try std.testing.expectEqual(row.work.operation, other.operation);
    try std.testing.expectEqualDeep(row.work.attention, other.attention);
    try std.testing.expectEqual(row.work.group, other.group);
    try std.testing.expect(other.actions.interrupt == null);
    try std.testing.expectEqual(row.work.actions.stop, other.actions.stop);
    try std.testing.expectEqual(row.work.actions.decide, other.actions.decide);
}

test "Session list reply owns read failure facts without asserting absence or admission" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "empty-report", .{ .read = true });
    defer file.close(io);
    var wire = ("{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"busy\",\"code\":\"ordinary_capacity_exhausted\",\"extension\":null}").*;
    const reply = try SessionListReply.decode(io, file, null, .{}, .{ .command = .{ .status = 503, .body = &wire } });
    @memset(&wire, 'x');
    try std.testing.expectEqual(@as(u16, 503), reply.failure.status);
    try std.testing.expectEqualStrings("busy", reply.failure.diagnostic.type.slice());
    try std.testing.expectEqualStrings("ordinary_capacity_exhausted", reply.failure.diagnostic.code.slice());
    try std.testing.expectEqual(error.HostInvocationFailed, reply.failure.err());
}

test "Session list byte range rejects zero instead of decoding an older page" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "page", .{ .read = true });
    defer file.close(io);
    const wire = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"session_list\",\"sessions\":[" ++ testing_list_facts ++ "null}";
    try file.writePositionalAll(io, wire, 0);
    try std.testing.expectError(error.InvalidSessionPage, SessionListReply.decode(io, file, null, .{}, .{ .report = .{ .bytes = 0 } }));
}

test "Session list byte range reads a shorter overwritten prefix without changing borrowed storage" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "page", .{ .read = true });
    defer file.close(io);
    const old = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"session_list\",\"sessions\":[{\"reference\":\"old\",\"archive_seq\":null,\"workspace\":\"/w\",\"provider\":\"codex\",\"model\":\"m\",\"tools\":[],\"permission_mode\":\"ask\"}" ++ testing_list_facts ++ "null}";
    const current = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"session_list\",\"sessions\":[" ++ testing_list_facts ++ "null}";
    try file.writePositionalAll(io, old, 0);
    try file.writePositionalAll(io, current, 0);
    const reply = try SessionListReply.decode(io, file, "/w", .{}, .{ .report = .{ .bytes = current.len } });
    try std.testing.expectEqual(@as(usize, 0), reply.page.count);
    try std.testing.expectEqual(@as(?SessionListCursor, null), reply.page.next);
    var bytes: [old.len]u8 = undefined;
    try std.testing.expectEqual(old.len, try file.length(io));
    try std.testing.expectEqual(old.len, try file.readPositionalAll(io, &bytes, 0));
    try std.testing.expectEqualStrings(current, bytes[0..current.len]);
    try std.testing.expectEqualStrings(old[current.len..], bytes[current.len..]);
    var writer = std.Io.Writer.fixed(&bytes);
    try reply.page.writeJson(&writer);
    try std.testing.expectEqualStrings(current, writer.buffered());
}

test "Session list byte range rejects physical EOF before promised completion" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "page", .{ .read = true });
    defer file.close(io);
    const wire = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"session_list\",\"sessions\":[" ++ testing_list_facts ++ "null}";
    try file.writePositionalAll(io, wire, 0);
    try std.testing.expectError(error.InvalidSessionPage, SessionListReply.decode(io, file, null, .{}, .{ .report = .{ .bytes = wire.len + 1 } }));
}

test "Session list byte range rejects a promise excluding the final delimiter" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "page", .{ .read = true });
    defer file.close(io);
    const wire = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"session_list\",\"sessions\":[" ++ testing_list_facts ++ "null}";
    try file.writePositionalAll(io, wire, 0);
    try std.testing.expectError(error.InvalidSessionPage, SessionListReply.decode(io, file, null, .{}, .{ .report = .{ .bytes = wire.len - 1 } }));
}

test "Session list byte range validates junk inside and ignores junk outside the promise" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "page", .{ .read = true });
    defer file.close(io);
    const wire = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"session_list\",\"sessions\":[" ++ testing_list_facts ++ "null}";
    try file.writePositionalAll(io, wire ++ "false", 0);
    try std.testing.expectError(error.InvalidSessionPage, SessionListReply.decode(io, file, null, .{}, .{ .report = .{ .bytes = wire.len + 5 } }));
    const reply = try SessionListReply.decode(io, file, null, .{}, .{ .report = .{ .bytes = wire.len } });
    try std.testing.expectEqual(@as(usize, 0), reply.page.count);
    try file.writePositionalAll(io, wire ++ " \n\r", 0);
    const spaced = try SessionListReply.decode(io, file, null, .{}, .{ .report = .{ .bytes = wire.len + 3 } });
    try std.testing.expectEqual(@as(usize, 0), spaced.page.count);
}

fn listValidationCase1() !void {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const row = "{\"reference\":\"k7m2qx\",\"archive_seq\":null,\"workspace\":\"/other\",\"provider\":\"codex\",\"model\":\"m\",\"tools\":[],\"permission_mode\":\"ask\"" ++ testing_row_facts ++ "}";
    inline for (.{
        "{\"version\":\"" ++ protocol.next_wire_version ++ "\",\"type\":\"session_list\",\"sessions\":[" ++ testing_list_facts ++ "null}",
        "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"session_list\",\"type\":\"session_list\",\"sessions\":[" ++ testing_list_facts ++ "null}",
        "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"session_list\",\"sessions\":[]}",
        "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"session_list\",\"sessions\":[" ++ testing_list_facts ++ "null}false",
        "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"session_list\",\"sessions\":[" ++ testing_list_facts ++ "{\"after\":\"7\",\"ceiling\":\"11\"}}",
        "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"session_list\",\"sessions\":[" ++ row ++ "," ++ row ++ testing_list_facts ++ "null}",
    }, 0..) |wire, index| {
        const file = try tmp.dir.createFile(io, std.fmt.comptimePrint("page-{d}", .{index}), .{ .read = true });
        defer file.close(io);
        try file.writePositionalAll(io, wire, 0);
        try std.testing.expectError(error.InvalidSessionPage, SessionListPage.read(io, file, wire.len, null, .{}));
    }
    const prefix = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"session_list\",\"sessions\":[{\"reference\":\"k7m2qx\",\"archive_seq\":null,\"workspace\":\"/other\",\"provider\":\"codex\",\"model\":\"m\",";
    inline for (.{
        "\"tools\":[\"bash\",\"bash\"],\"permission_mode\":\"ask\"",
        "\"tools\":null,\"permission_mode\":\"ask\"",
        "\"tools\":[0],\"permission_mode\":\"ask\"",
        "\"tools\":[],\"permission_mode\":0",
        "\"tools\":[],\"permission_mode\":\"invented\"",
        "\"tools\":[]",
        "\"tools\":[],\"permission_mode\":\"ask\",\"reference\":\"k7m2qx\"",
    }, 0..) |suffix, index| {
        const file = try tmp.dir.createFile(io, std.fmt.comptimePrint("row-{d}", .{index}), .{ .read = true });
        defer file.close(io);
        const wire = prefix ++ suffix ++ testing_row_facts ++ "}" ++ testing_list_facts ++ "null}";
        try file.writePositionalAll(io, wire, 0);
        try std.testing.expectError(error.InvalidSessionPage, SessionListPage.read(io, file, wire.len, null, .{}));
    }
    const settings = prefix ++ "\"tools\":[],\"permission_mode\":\"ask\"";
    {
        const file = try tmp.dir.createFile(io, "facts-valid", .{ .read = true });
        defer file.close(io);
        const wire = settings ++ testing_started_row_facts ++ "}" ++ testing_list_facts ++ "null}";
        try file.writePositionalAll(io, wire, 0);
        const page = try SessionListPage.read(io, file, wire.len, null, .{});
        try std.testing.expectEqual(@as(?protocol.Peer, null), page.rows[0].first_message.?.sender);
    }
    for ([_][2][]const u8{
        .{ "\"read_version\":\"00000000000000000000000000000000.0\",", "" },
        .{ "\"read_version\":\"00000000000000000000000000000000.0\"", "\"read_version\":\"bad\"" },
        .{ ",\"archive_state\":\"active\",\"pin_order\":null", "" },
        .{ "\"archive_state\":\"active\",\"pin_order\":null", "\"archive_state\":null" },
        .{ "\"archive_state\":\"active\",\"pin_order\":null", "\"archive_state\":\"unknown\"" },
        .{ ",\"pin_order\":null", "" },
        .{ "\"pin_order\":null", "\"pin_order\":\"0\"" },
        .{ "\"pin_order\":null", "\"pin_order\":1" },
        .{ "\"pin_order\":null", "\"pin_order\":\"9223372036854775808\"" },
        .{ ",\"creator\":null", "" },
        .{ "\"creator\":null", "\"creator\":0" },
        .{ "\"creator\":null", "\"creator\":{}" },
        .{ "\"creator\":null", "\"creator\":\"\"" },
        .{ "\"creator\":null", "\"creator\":\"k7m2qX\"" },
        .{ "\"creator\":null", "\"creator\":\"k7m2qx\"" },
        .{ "\"creator\":null", "\"creator\":\"short\"" },
        .{ "\"creator\":null", "\"creator\":\"abcdefg\"" },
        .{ "\"creator\":null", "\"creator\":\"k7m2qi\"" },
        .{ "\"creator\":null", "\"creator\":null,\"creator\":null" },
        .{ "\"parent\":null", "\"parent\":\"k7m2qX\"" },
        .{ "\"parent\":null", "\"parent\":\"k7m2qx\"" },
        .{ "\"parent\":null", "\"parent\":\"abcdefg\"" },
        .{ ",\"parent\":null", "" },
        .{ "\"label\":\"Review PR 412\"", "\"label\":\"two\\nlines\"" },
        .{ "\"label\":\"Review PR 412\"", "\"label\":\" \"" },
        .{ "\"created_at\":\"1792925000\"", "\"created_at\":\"0\"" },
        .{ ",\"state_change_at\":\"1792925300\"", "" },
        .{ ",\"subtree_state_change_at\":\"1792925400\"", "" },
        .{ ",\"descendant_count\":\"2\"", "" },
        .{ ",\"descendant_needs_you_count\":\"1\"", "" },
        .{ "\"descendant_count\":\"2\"", "\"descendant_count\":\"-1\"" },
        .{ "\"state_change_at\":\"1792925300\"", "\"state_change_at\":\"1792924999\"" },
        .{ "\"subtree_state_change_at\":\"1792925400\"", "\"subtree_state_change_at\":\"1792925299\"" },
        .{ "\"descendant_needs_you_count\":\"1\"", "\"descendant_needs_you_count\":\"3\"" },
        .{ "\"revision\":\"1\"", "\"revision\":\"0\"" },
        .{ "\"end\":\"9\"", "\"end\":\"9\",\"end\":\"9\"" },
        .{ ",\"last_line\":null", "" },
        .{ "\"last_line\":null", "\"last_line\":{\"position\":\"0\",\"text\":null}" },
        .{ "\"last_line\":null", "\"last_line\":{\"position\":\"10\",\"text\":null}" },
        .{ "\"last_line\":null", "\"last_line\":{\"position\":\"8\"}" },
        .{ "\"last_line\":null", "\"last_line\":{\"position\":\"8\",\"text\":false}" },
        .{ "\"last_line\":null", "\"last_line\":{\"position\":\"8\",\"text\":\"" ++ @as([session_list.max_last_line_bytes + 1]u8, @splat('x')) ++ "\"}" },
        .{ "\"end\":\"9\"", "\"end\":\"0\"" },
        .{ "\"sender\":null", "\"sender\":{\"session\":\"k7m2qX\"}" },
        .{ "\"from_person_at\":\"1792925001\"", "\"from_person_at\":null" },
        .{ "\"operation\":\"6\"", "\"operation\":null" },
        .{ "\"state\":{\"kind\":\"working\",\"since\":\"1792925300\"}", "\"state\":{\"kind\":\"failed\",\"since\":\"1\",\"code\":\"provider_http_500\",\"resets_at\":\"5\"}" },
        .{ ",\"peers\":{\"from_person_at\":\"1792925001\"}", "" },
        .{ "\"first_message\":{\"position\":\"1\",\"admission\":\"4\",\"admitted_at\":\"1792925001\",\"sender\":null,", "\"first_message\":null,\"ignored\":{\"sender\":null," },
    }, 0..) |case, index| {
        var name_buffer: [32]u8 = undefined;
        const file = try tmp.dir.createFile(io, try std.fmt.bufPrint(&name_buffer, "facts-{d}", .{index}), .{ .read = true });
        defer file.close(io);
        const facts = testing_started_row_facts;
        const at = std.mem.indexOf(u8, facts, case[0]).?;
        var buffer: [2048]u8 = undefined;
        const wire = try std.fmt.bufPrint(&buffer, "{s}{s}{s}{s}}}" ++ testing_list_facts ++ "null}}", .{ settings, facts[0..at], case[1], facts[at + case[0].len ..] });
        try file.writePositionalAll(io, wire, 0);
        try std.testing.expectError(error.InvalidSessionPage, SessionListPage.read(io, file, wire.len, null, .{}));
    }
}

fn testingListPage(buffer: []u8, references: []const []const u8, facts: []const u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    try writer.writeAll("{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"session_list\",\"sessions\":[");
    for (references, 0..) |reference, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.print("{{\"read_version\":\"00000000000000000000000000000000.0\",\"archive_state\":\"active\",\"pin_order\":null,\"reference\":\"{s}\",\"archive_seq\":null,\"workspace\":\"/w\",\"provider\":\"codex\",\"model\":\"m\",\"tools\":[],\"permission_mode\":\"ask\"", .{reference});
        try writer.writeAll(testing_row_details ++ "}");
    }
    try writer.writeAll(facts);
    return writer.buffered();
}

test "a since reply answers its request's token: unchanged, changed rows in ID order, or a full restart" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "page", .{ .read = true });
    defer file.close(io);
    const since = try protocol.SinceToken.parse("abababababababababababababababab.42");
    const asked: SessionListCursor = .{ .since = since };
    const continued: SessionListCursor = .{ .since = since, .changed = .{ .through = 48, .after_reference = "c00000".* } };
    const eight = [_][]const u8{ "d00000", "d00001", "d00002", "d00003", "d00004", "d00005", "d00006", "d00007" };
    const Case = struct { cursor: SessionListCursor, references: []const []const u8, facts: []const u8, valid: bool };
    const cases = [_]Case{
        .{ .cursor = asked, .references = &.{}, .facts = "],\"delta\":\"not_modified\",\"since\":\"abababababababababababababababab.42\",\"next\":null}", .valid = true },
        .{ .cursor = .{}, .references = &.{}, .facts = "],\"delta\":\"not_modified\",\"since\":\"abababababababababababababababab.42\",\"next\":null}", .valid = false },
        .{ .cursor = continued, .references = &.{}, .facts = "],\"delta\":\"not_modified\",\"since\":\"abababababababababababababababab.42\",\"next\":null}", .valid = false },
        .{ .cursor = asked, .references = &.{}, .facts = "],\"delta\":\"not_modified\",\"since\":\"abababababababababababababababab.43\",\"next\":null}", .valid = false },
        .{ .cursor = asked, .references = &.{"k7m2qx"}, .facts = "],\"delta\":\"not_modified\",\"since\":\"abababababababababababababababab.42\",\"next\":null}", .valid = false },
        .{ .cursor = asked, .references = &.{ "a00000", "k7m2qx" }, .facts = "],\"delta\":\"changed\",\"since\":\"abababababababababababababababab.48\",\"next\":null}", .valid = true },
        .{ .cursor = asked, .references = &.{}, .facts = "],\"delta\":\"changed\",\"since\":\"abababababababababababababababab.42\",\"next\":null}", .valid = true },
        .{ .cursor = .{}, .references = &.{}, .facts = "],\"delta\":\"changed\",\"since\":\"abababababababababababababababab.48\",\"next\":null}", .valid = false },
        .{ .cursor = asked, .references = &.{ "k7m2qx", "a00000" }, .facts = "],\"delta\":\"changed\",\"since\":\"abababababababababababababababab.48\",\"next\":null}", .valid = false },
        .{ .cursor = asked, .references = &.{}, .facts = "],\"delta\":\"changed\",\"since\":\"cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd.48\",\"next\":null}", .valid = false },
        .{ .cursor = asked, .references = &.{}, .facts = "],\"delta\":\"changed\",\"since\":\"abababababababababababababababab.41\",\"next\":null}", .valid = false },
        .{ .cursor = continued, .references = &.{"d00000"}, .facts = "],\"delta\":\"changed\",\"since\":\"abababababababababababababababab.48\",\"next\":null}", .valid = true },
        .{ .cursor = continued, .references = &.{"c00000"}, .facts = "],\"delta\":\"changed\",\"since\":\"abababababababababababababababab.48\",\"next\":null}", .valid = false },
        .{ .cursor = continued, .references = &.{"d00000"}, .facts = "],\"delta\":\"changed\",\"since\":\"abababababababababababababababab.49\",\"next\":null}", .valid = false },
        .{ .cursor = asked, .references = &eight, .facts = "],\"delta\":\"changed\",\"since\":\"abababababababababababababababab.48\",\"next\":{\"through\":\"48\",\"after_reference\":\"d00007\"}}", .valid = true },
        .{ .cursor = asked, .references = eight[0..7], .facts = "],\"delta\":\"changed\",\"since\":\"abababababababababababababababab.48\",\"next\":{\"through\":\"48\",\"after_reference\":\"d00006\"}}", .valid = false },
        .{ .cursor = asked, .references = &eight, .facts = "],\"delta\":\"changed\",\"since\":\"abababababababababababababababab.48\",\"next\":{\"through\":\"47\",\"after_reference\":\"d00007\"}}", .valid = false },
        .{ .cursor = asked, .references = &eight, .facts = "],\"delta\":\"changed\",\"since\":\"abababababababababababababababab.48\",\"next\":{\"through\":\"48\",\"after_reference\":\"d00006\"}}", .valid = false },
        .{ .cursor = asked, .references = &eight, .facts = "],\"delta\":\"changed\",\"since\":\"abababababababababababababababab.48\",\"next\":{\"after\":\"8\",\"ceiling\":\"20\"}}", .valid = false },
        .{ .cursor = continued, .references = &eight, .facts = "],\"delta\":\"full\",\"since\":\"cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd.3\",\"next\":{\"after\":\"8\",\"ceiling\":\"20\"}}", .valid = true },
        .{ .cursor = asked, .references = &eight, .facts = "],\"delta\":\"full\",\"since\":\"cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd.3\",\"next\":{\"through\":\"3\",\"after_reference\":\"d00007\"}}", .valid = false },
        .{ .cursor = .{}, .references = &.{}, .facts = "],\"since\":\"abababababababababababababababab.42\",\"next\":null}", .valid = false },
        .{ .cursor = .{}, .references = &.{}, .facts = "],\"delta\":\"full\",\"next\":null}", .valid = false },
        .{ .cursor = .{}, .references = &.{}, .facts = "],\"delta\":\"partial\",\"since\":\"abababababababababababababababab.42\",\"next\":null}", .valid = false },
        .{ .cursor = .{}, .references = &.{}, .facts = "],\"delta\":\"full\",\"since\":\"abababababababababababababababab\",\"next\":null}", .valid = false },
    };
    var buffer: [8192]u8 = undefined;
    for (cases) |case| {
        const wire = try testingListPage(&buffer, case.references, case.facts);
        try file.writePositionalAll(io, wire, 0);
        if (!case.valid) {
            try std.testing.expectError(error.InvalidSessionPage, SessionListPage.read(io, file, wire.len, null, case.cursor));
            continue;
        }
        const page = try SessionListPage.read(io, file, wire.len, null, case.cursor);
        try std.testing.expectEqual(case.references.len, page.count);
        var output: [8192]u8 = undefined;
        var writer = std.Io.Writer.fixed(&output);
        try page.writeJson(&writer);
        try std.testing.expectEqualStrings(wire, writer.buffered());
    }
    const wire = try testingListPage(&buffer, &eight, "],\"delta\":\"changed\",\"since\":\"abababababababababababababababab.48\",\"next\":{\"through\":\"48\",\"after_reference\":\"d00007\"}}");
    try file.writePositionalAll(io, wire, 0);
    const changed = try SessionListPage.read(io, file, wire.len, null, asked);
    try std.testing.expectEqualDeep(SessionListCursor{ .since = since, .changed = .{ .through = 48, .after_reference = "d00007".* } }, changed.next.?);
    try changed.next.?.validate();
}

test "a traversal keeps its first page's token, and a changed one that turns full restarts" {
    const first = try protocol.SinceToken.parse("abababababababababababababababab.42");
    const later = try protocol.SinceToken.parse("abababababababababababababababab.50");
    const other = try protocol.SinceToken.parse("cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd.3");
    const changed_next: SessionListCursor = .{ .since = first, .changed = .{ .through = 48, .after_reference = "d00007".* } };
    var full = SessionTraversal.init(null);
    try std.testing.expect(full.advance(&.{ .delta = .full, .since = first, .next = .{ .after = 8, .ceiling = 20 } }));
    try std.testing.expectEqualDeep(SessionListCursor{ .after = 8, .ceiling = 20 }, full.cursor);
    try std.testing.expect(!full.restarts(&.{ .delta = .full, .since = later }));
    try std.testing.expect(!full.advance(&.{ .delta = .full, .since = later }));
    try std.testing.expectEqual(protocol.ListDelta.full, full.delta);
    try std.testing.expectEqualDeep(first, full.since.?);
    var traversal = SessionTraversal.init(first);
    try std.testing.expectEqualDeep(SessionListCursor{ .since = first }, traversal.cursor);
    const through = try protocol.SinceToken.parse("abababababababababababababababab.48");
    try std.testing.expect(!traversal.restarts(&.{ .delta = .changed, .since = through, .next = changed_next }));
    try std.testing.expect(traversal.advance(&.{ .delta = .changed, .since = through, .next = changed_next }));
    try std.testing.expectEqual(protocol.ListDelta.changed, traversal.delta);
    try std.testing.expectEqualDeep(changed_next, traversal.cursor);
    try std.testing.expect(traversal.restarts(&.{ .delta = .full, .since = other }));
    try std.testing.expect(traversal.advance(&.{ .delta = .full, .since = other, .next = .{ .after = 8, .ceiling = 20 } }));
    try std.testing.expectEqual(protocol.ListDelta.full, traversal.delta);
    try std.testing.expectEqualDeep(other, traversal.since.?);
    try std.testing.expect(!traversal.advance(&.{ .delta = .full, .since = later }));
    try std.testing.expectEqualDeep(other, traversal.since.?);
    var unchanged = SessionTraversal.init(first);
    try std.testing.expect(!unchanged.advance(&.{ .delta = .not_modified, .since = first }));
    try std.testing.expectEqual(protocol.ListDelta.not_modified, unchanged.delta);
    try std.testing.expectEqualDeep(first, unchanged.since.?);
}

test "Session list terminal cursor accepts only empty rows without rejecting initial or continuing pages" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "terminal", .{ .read = true });
    defer file.close(io);
    const wire = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"session_list\",\"sessions\":[{\"reference\":\"k7m2qx\",\"archive_seq\":null,\"workspace\":\"/w\",\"provider\":\"codex\",\"model\":\"m\",\"tools\":[],\"permission_mode\":\"ask\"" ++ testing_row_facts ++ "}" ++ testing_list_facts ++ "null}";
    try file.writePositionalAll(io, wire, 0);
    inline for (.{ SessionListCursor{}, SessionListCursor{ .after = 7, .ceiling = 8 } }) |cursor| {
        const reply = try SessionListReply.decode(io, file, null, cursor, .{ .report = .{ .bytes = wire.len } });
        try std.testing.expectEqual(@as(usize, 1), reply.page.count);
        try std.testing.expectEqual(@as(?SessionListCursor, null), reply.page.next);
    }
    try std.testing.expectError(error.InvalidSessionPage, SessionListReply.decode(io, file, null, .{ .after = 7, .ceiling = 7 }, .{ .report = .{ .bytes = wire.len } }));
    const empty = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"session_list\",\"sessions\":[" ++ testing_list_facts ++ "null}";
    try file.writePositionalAll(io, empty, 0);
    const reply = try SessionListReply.decode(io, file, null, .{ .after = 7, .ceiling = 7 }, .{ .report = .{ .bytes = empty.len } });
    try std.testing.expectEqual(@as(usize, 0), reply.page.count);
    try std.testing.expectEqual(@as(?SessionListCursor, null), reply.page.next);
}

test "Session list rows retain host tool names" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "tools", .{ .read = true });
    defer file.close(io);
    const wire = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"session_list\",\"sessions\":[{\"reference\":\"k7m2qx\",\"archive_seq\":null,\"workspace\":\"/w\",\"provider\":\"codex\",\"model\":\"m\",\"tools\":[\"bash\",\"fetch_page\"],\"permission_mode\":\"ask\"" ++ testing_row_facts ++ "}" ++ testing_list_facts ++ "null}";
    try file.writePositionalAll(io, wire, 0);
    const page = try SessionListPage.read(io, file, wire.len, null, .{});
    try std.testing.expectEqualStrings("bash fetch_page", page.rows[0].tools.names.slice());
    var buffer: [protocol.session_list_reply.max_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try page.writeRowsJson(&writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\"tools\":[\"bash\",\"fetch_page\"]") != null);
}

fn listValidationCase2() !void {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "maximum", .{ .read = true });
    defer file.close(io);
    var workspace = @as([protocol.max_workspace_bytes]u8, @splat(1));
    workspace[0] = '/';
    const model = @as([protocol.max_model_bytes]u8, @splat(1));
    const text = @as([protocol.max_label_bytes]u8, @splat(1));
    var bytes: [protocol.content_window_bytes]u8 = undefined;
    var output = file.writerStreaming(io, &bytes);
    const writer = &output.interface;
    try writer.writeAll("{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"session_list\",\"sessions\":[");
    const largest = std.math.maxInt(i64);
    var maximal: protocol.SessionRow = .{ .read_version = .{ .instance = @splat(0xab), .generation = std.math.maxInt(u64) }, .archive_state = .archiving, .provider = .codex, .tools = try .of(&.{"bash"}), .permission_mode = .bypass, .label = .{}, .created_at = largest, .state_change_at = largest, .subtree_state_change_at = largest, .descendant_count = largest, .descendant_needs_you_count = largest, .revision = largest, .end = largest };
    // An archiving row carries its archive key; the largest one is the longest row.
    maximal.archive_seq = largest;
    maximal.creator = .{};
    try maximal.creator.?.set("zzzzzz");
    maximal.parent = .{};
    try maximal.parent.?.set("zzzzzz");
    try maximal.workspace.set(&workspace);
    try maximal.model.set(&model);
    try maximal.label.?.set(&text);
    maximal.first_message = .{ .position = largest, .admission = largest, .admitted_at = largest, .sender = .{ .session = .{} }, .content = .{ .parts = .{ .identity = .{ .length = protocol.max_sqlite_content_bytes, .digest = @splat(0xff) }, .owner = .{ .message = largest } } } };
    try maximal.first_message.?.sender.?.session.set("zzzzzz");
    const call_text = @as([protocol.max_tool_description_bytes]u8, @splat(1));
    var description: protocol.Bounded(protocol.session_work.max_description_bytes) = .{};
    try description.set(&call_text);
    maximal.work = .{ .state = .{ .bash = .{ .since = largest, .call = largest, .description = description, .running = largest, .approvals = largest } }, .turn = largest, .operation = largest, .first_action = largest };
    maximal.last_line = .{ .position = largest, .text = description };
    maximal.peers = .{ .from_person_at = largest };
    for (0..8) |index| {
        if (index != 0) try writer.writeAll(",");
        var reference = "000000".*;
        reference[0] = @intCast('0' + index);
        try maximal.reference.set(&reference);
        try maximal.writeJson(writer);
    }
    try writer.writeAll(testing_list_facts ++ "{\"after\":\"19\",\"ceiling\":\"23\"}}");
    try writer.flush();
    const length = try file.length(io);
    try std.testing.expect(length > protocol.content_window_bytes);
    try std.testing.expect(length <= protocol.session_list_reply.max_bytes);
    try std.testing.expectError(error.InvalidSessionPage, SessionListPage.read(io, file, protocol.session_list_reply.max_bytes + 1, &workspace, .{ .after = 11, .ceiling = 23 }));
    const page = try SessionListPage.read(io, file, length, &workspace, .{ .after = 11, .ceiling = 23 });
    try std.testing.expectEqual(@as(usize, 8), page.count);
    try std.testing.expectEqual(@as(u64, 19), page.next.?.after);
    try std.testing.expectEqual(@as(u64, 23), page.next.?.ceiling);
    for (page.rows[0..8], 0..) |*row, index| {
        try std.testing.expectEqualDeep(maximal.read_version, row.read_version);
        try std.testing.expectEqual(@as(u8, @intCast('0' + index)), row.reference.bytes[0]);
        try std.testing.expectEqual(protocol.session_id_bytes, row.reference.len);
        try std.testing.expectEqualStrings(&workspace, row.workspace.slice());
        try std.testing.expectEqualStrings(&model, row.model.slice());
        try std.testing.expect(std.mem.eql(u8, row.tools.names.slice(), "bash") and row.permission_mode == .bypass);
        try std.testing.expectEqualStrings(&text, row.label.?.slice());
        try std.testing.expectEqualStrings(&call_text, row.work.state.bash.description.?.slice());
    }
    try std.testing.expectError(error.InvalidSessionPage, SessionListPage.read(io, file, length, "/wrong", .{}));
    try std.testing.expectError(error.InvalidSessionPage, SessionListPage.read(io, file, length, null, .{ .after = 19, .ceiling = 23 }));
    try std.testing.expectError(error.InvalidSessionPage, SessionListPage.read(io, file, length, null, .{ .after = 11, .ceiling = 29 }));
    const tail = testing_list_facts ++ "{\"after\":\"19\",\"ceiling\":\"23\"}}";
    const prefix_length = length - tail.len;
    try file.writePositionalAll(io, testing_list_facts ++ "{\"after\":\"23\",\"ceiling\":\"23\"}}", prefix_length);
    try std.testing.expectError(error.InvalidSessionPage, SessionListReply.decode(io, file, &workspace, .{}, .{ .report = .{ .bytes = length } }));
    const terminal = testing_list_facts ++ "null}";
    try file.writePositionalAll(io, terminal, prefix_length);
    const last = try SessionListReply.decode(io, file, &workspace, .{}, .{ .report = .{ .bytes = prefix_length + terminal.len } });
    try std.testing.expectEqual(@as(usize, 8), last.page.count);
    try std.testing.expectEqual(@as(?SessionListCursor, null), last.page.next);
    try (SessionListCursor{ .after = 23, .ceiling = 23 }).validate();
}

const testing_observation_input = ",\"input\":{\"type\":\"text\",\"bytes\":\"11\",\"sha256\":\"" ++ @as([64]u8, @splat('a')) ++ "\"}";
const testing_observation_parts_head = ",\"input\":{\"type\":\"parts\",\"bytes\":\"11\",\"sha256\":\"" ++ @as([64]u8, @splat('a')) ++ "\"";
const testing_observation_queue = ",\"queue\":{\"admission\":\"23\",\"admitted_at\":\"1762329000\"}";
const testing_observation_work = ",\"work\":{\"state\":{\"kind\":\"working\",\"since\":\"1762329010\"},\"first_action\":null,\"attention\":null,\"group\":\"done\",\"actions\":{\"stop\":false,\"interrupt\":null,\"decide\":null}}";
const testing_observation_binding = ",\"binding\":{\"turn\":\"37\",\"operation\":\"41\",\"attempt\":\"0\"}";
const testing_observation_prefix = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"command_observation\",\"key\":\"k\",\"delta\":\"full\",\"since\":null,\"observation\":";
const testing_observation_message = "{\"status\":\"accepted\",\"kind\":\"message\",\"target\":\"k7m2qx\"";

test "ADM-27 keyed observation preserves input identity across states" {
    const address = try MessageAddress.init("/store", "k7m2qx", "k");
    inline for (.{
        .{ "queued", "", ",\"work\":{\"state\":{\"kind\":\"pending\",\"since\":\"1762329000\"},\"first_action\":null,\"attention\":null,\"group\":\"done\",\"actions\":{\"stop\":false,\"interrupt\":null,\"decide\":null}}" },
        .{ "processing", testing_observation_binding, ",\"work\":{\"state\":{\"kind\":\"bash\",\"since\":\"1762329010\",\"call\":\"0\",\"description\":\"Run tests\",\"running\":\"1\",\"approvals\":\"0\"},\"first_action\":null,\"attention\":null,\"group\":\"done\",\"actions\":{\"stop\":false,\"interrupt\":null,\"decide\":null}}" },
        .{ "waiting_for_permission", testing_observation_binding, ",\"work\":{\"state\":{\"kind\":\"approval\",\"since\":\"1762329010\"},\"first_action\":\"57\",\"attention\":null,\"group\":\"done\",\"actions\":{\"stop\":false,\"interrupt\":null,\"decide\":null}}" },
        .{ "waiting_for_permission", "", ",\"work\":{\"state\":{\"kind\":\"approval\",\"since\":\"1762329010\"},\"first_action\":\"57\",\"attention\":null,\"group\":\"done\",\"actions\":{\"stop\":false,\"interrupt\":null,\"decide\":null}}" },
        .{ "waiting_for_permission", testing_observation_binding, ",\"work\":{\"state\":{\"kind\":\"approval\",\"since\":\"1762329010\"},\"first_action\":null,\"attention\":{\"kind\":\"approval\",\"turn\":\"37\",\"step\":\"0\"},\"group\":\"needs_you\",\"actions\":{\"stop\":true,\"interrupt\":null,\"decide\":null}}" },
        .{ "completed", testing_observation_binding, ",\"result\":{\"status\":\"completed\",\"text\":{\"type\":\"text\",\"bytes\":\"11\",\"sha256\":\"" ++ @as([64]u8, @splat('a')) ++ "\"}}" },
        .{ "failed", testing_observation_binding, ",\"result\":{\"status\":\"failed\",\"code\":\"provider_http_422\"}" },
        .{ "cancelled", testing_observation_binding, ",\"result\":{\"status\":\"cancelled\",\"code\":\"cancelled\"}" },
        .{ "cancelled", "", ",\"result\":{\"status\":\"cancelled\",\"code\":\"cancelled\"}" },
    }) |case| {
        inline for (.{ "text", "parts" }) |form| {
            const parts = comptime std.mem.eql(u8, form, "parts");
            const input = if (parts) testing_observation_parts_head ++ ",\"owner\":{\"message\":\"23\"}}" else testing_observation_input;
            const facts = testing_observation_message ++ ",\"state\":\"" ++ case[0] ++ "\"" ++ input ++ testing_observation_queue ++ case[1] ++ case[2] ++ "}";
            const observed = try (try CommandObservation.parse(.{ .status = 200, .body = testing_observation_prefix ++ facts ++ "}" }, "k")).forMessage(&address);
            try std.testing.expectEqual(.accepted, observed.status);
            const value = observed.input.?;
            try std.testing.expectEqualStrings(form, @tagName(value));
            try std.testing.expectEqualDeep(content_value.Reference{ .length = 11, .digest = @splat(0xaa) }, value.identity());
            if (parts) try std.testing.expectEqualDeep(content_value.Owner{ .message = 23 }, value.parts.owner);
            try std.testing.expectEqualStrings(case[0], @tagName(observed.state.?));
            try std.testing.expectEqual(@as(u64, 23), observed.queue.?.admission);
            try std.testing.expectEqual(@as(u64, 1762329000), observed.queue.?.admitted_at);
            if (observed.binding) |binding| {
                try std.testing.expectEqual(@as(u64, 37), binding.turn);
                try std.testing.expectEqual(@as(u64, 41), binding.operation);
                try std.testing.expectEqual(@as(u64, 0), binding.attempt);
            }
            var output: [protocol.command_observation_reply.max_bytes]u8 = undefined;
            var writer = std.Io.Writer.fixed(&output);
            try observed.writeJson(&writer);
            try std.testing.expectEqualStrings(facts, writer.buffered());
        }
    }
    const rejection = "{\"status\":\"rejected\",\"kind\":\"message\",\"target\":\"k7m2qx\",\"code\":\"invalid_input\",\"state\":\"rejected\"";
    const observed = try CommandObservation.parse(.{ .status = 200, .body = testing_observation_prefix ++ rejection ++ "}}" }, "k");
    try std.testing.expectEqual(.rejected, observed.status);
    try std.testing.expect(observed.input == null);
    var output: [protocol.command_observation_reply.max_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    try observed.writeJson(&writer);
    try std.testing.expectEqualStrings(rejection ++ "}", writer.buffered());
    inline for (.{ testing_observation_input, testing_observation_parts_head ++ ",\"owner\":{\"message\":\"23\"}}", ",\"input\":null" }) |input| {
        const body = testing_observation_prefix ++ rejection ++ input ++ "}}";
        try std.testing.expectError(error.InvalidObservation, CommandObservation.parse(.{ .status = 200, .body = body }, "k"));
    }
}

test "ADM-27 keyed observation rejects invalid Message input owners" {
    const prefix = testing_observation_prefix ++ testing_observation_message ++ ",\"state\":\"queued\"";
    const suffix = "}" ++ testing_observation_queue ++ testing_observation_work ++ "}}";
    const owner = ",\"owner\":{\"message\":\"23\"}";
    inline for (.{
        "",
        ",\"owner\":null",
        ",\"owner\":{}",
        ",\"owner\":{\"message\":null}",
        ",\"owner\":{\"message\":\"23\",\"action\":null}",
        ",\"owner\":{\"message\":\"23\",\"extra\":true}",
        ",\"owner\":{\"message\":\"23\",\"messa\\u0067e\":\"23\"}",
        owner ++ owner,
        ",\"owner\":{\"action\":\"23\"}",
        ",\"owner\":{\"message\":\"22\"}",
    }) |invalid_owner| {
        const body = prefix ++ testing_observation_parts_head ++ invalid_owner ++ suffix;
        try std.testing.expectError(error.InvalidObservation, CommandObservation.parse(.{ .status = 200, .body = body }, "k"));
    }
    inline for (.{ owner, ",\"owner\":null" }) |invalid_owner| {
        const body = prefix ++ testing_observation_input[0 .. testing_observation_input.len - 1] ++ invalid_owner ++ suffix;
        try std.testing.expectError(error.InvalidObservation, CommandObservation.parse(.{ .status = 200, .body = body }, "k"));
    }
}

fn observationFieldSample() !CommandObservation {
    const body = testing_observation_prefix ++ testing_observation_message ++ ",\"state\":\"queued\"" ++ testing_observation_input ++ testing_observation_queue ++ testing_observation_work ++ "}}";
    var sample = try CommandObservation.parse(.{ .status = 200, .body = body }, "k");
    sample.revision = 31;
    sample.created = true;
    sample.binding = .{ .turn = 37, .operation = 41, .attempt = 0 };
    sample.result = .{ .status = .cancelled, .code = try protocol.Bounded(protocol.max_code_bytes).from("cancelled"), .text = null };
    sample.recovery = .{ .more = false };
    sample.selection = .{ .turn = null, .admission_cutoff = 0 };
    sample.archived = false;
    sample.pinned = false;
    sample.completion = .completed;
    sample.interruption_target = .{ .session = try protocol.Bounded(protocol.max_session_bytes).from("k7m2qx"), .turn = 3, .operation = 7 };
    sample.permission_target = .{ .action = 29, .decision = .allow_once };
    sample.action_target = 29;
    sample.action_selection = .{ .kind = .background, .position = 31 };
    sample.kind = .action_stop;
    sample.resolution_position = 31;
    return sample;
}

// These independently specified minimal fixtures exercise structural ownership
// through the public parser, including required fields and foreign payloads.
fn expectObservationFieldPresence(original: *const CommandObservation) !void {
    var original_bytes: [protocol.command_observation_reply.max_bytes]u8 = undefined;
    var original_writer = std.Io.Writer.fixed(&original_bytes);
    try original.writeJson(&original_writer);
    const sample = try observationFieldSample();
    var sample_bytes: [protocol.command_observation_reply.max_bytes]u8 = undefined;
    var sample_writer = std.Io.Writer.fixed(&sample_bytes);
    try sample.writeJson(&sample_writer);
    // The sample carries both stop and archive payloads, whose renderer each
    // emits completion. Only its independent field values are used below.
    const sample_facts = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, sample_writer.buffered(), .{ .duplicate_field_behavior = .use_last });
    defer sample_facts.deinit();
    inline for (comptime std.meta.fieldNames(CommandObservation)) |name| {
        if (comptime !std.mem.eql(u8, name, "key") and !std.mem.eql(u8, name, "status") and
            !std.mem.eql(u8, name, "kind") and !std.mem.eql(u8, name, "target") and !std.mem.eql(u8, name, "code"))
        {
            var facts = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, original_writer.buffered(), .{});
            defer facts.deinit();
            if (!facts.value.object.swapRemove(name)) try facts.value.object.put(facts.arena.allocator(), name, sample_facts.value.object.get(name).?);
            var bytes: [protocol.command_observation_reply.max_bytes]u8 = undefined;
            var writer = std.Io.Writer.fixed(&bytes);
            try writer.writeAll(testing_observation_prefix);
            try std.json.Stringify.value(facts.value, .{}, &writer);
            try writer.writeByte('}');
            const parsed = CommandObservation.parse(.{ .status = 200, .body = writer.buffered() }, "k");
            try std.testing.expectError(error.InvalidObservation, parsed);
        }
    }
}

test "keyed observation validates interruption binding for both saved outcomes" {
    inline for (.{ .accepted, .rejected }) |status| {
        const code = comptime if (status == .rejected) ",\"code\":\"unknown_operation\"" else "";
        const body = testing_observation_prefix ++ "{\"status\":\"" ++ @tagName(status) ++ "\",\"kind\":\"model_interruption\",\"target\":\"k7m2qx\",\"interruption_target\":{\"session\":\"09azvw\",\"turn\":\"3\",\"operation\":\"7\"}" ++ code ++ "}}";
        try std.testing.expectError(error.RequestBindingMismatch, CommandObservation.parse(.{ .status = 200, .body = body }, "k"));
    }
}

test "keyed observation validates every operation shape and binding" {
    const prefix = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"command_observation\",\"key\":\"k\",\"delta\":\"full\",\"since\":null,\"observation\":{\"target\":\"k7m2qx\",";
    inline for (.{
        .{ "configure", ",\"revision\":\"31\",\"created\":true", "" },
        .{ "message", ",\"state\":\"queued\"" ++ testing_observation_input ++ testing_observation_queue ++ testing_observation_work, ",\"state\":\"rejected\"" },
        .{ "session_stop", ",\"selection\":{\"turn\":null,\"admission_cutoff\":\"0\"},\"completion\":{\"status\":\"completed\"}", "" },
        .{ "session_archive", ",\"archived\":false,\"completion\":{\"status\":\"completed\"}", "" },
        .{ "session_pin", ",\"pinned\":false", "" },
        .{ "model_interruption", ",\"interruption_target\":{\"session\":\"k7m2qx\",\"turn\":\"3\",\"operation\":\"7\"}", ",\"interruption_target\":{\"session\":\"k7m2qx\",\"turn\":\"0\",\"operation\":\"0\"}" },
        .{ "permission_decision", ",\"permission_target\":{\"action\":\"29\",\"decision\":\"allow_once\"}", ",\"permission_target\":{\"action\":\"0\",\"decision\":\"deny\"}" },
        .{ "action_background", ",\"action_target\":{\"action\":\"29\"},\"action_selection\":{\"kind\":\"background\",\"position\":\"31\"}", ",\"action_target\":{\"action\":\"29\"}" },
        .{ "action_stop", ",\"action_target\":{\"action\":\"29\"},\"resolution_position\":null", ",\"action_target\":{\"action\":\"29\"}" },
        .{ "action_stop", ",\"action_target\":{\"action\":\"29\"},\"resolution_position\":\"31\"", ",\"action_target\":{\"action\":\"29\"}" },
    }) |case| {
        const accepted = prefix ++ "\"kind\":\"" ++ case[0] ++ "\",\"status\":\"accepted\"" ++ case[1] ++ "}}";
        const observed = try CommandObservation.parse(.{ .status = 200, .body = accepted }, "k");
        try std.testing.expectEqualStrings(case[0], @tagName(observed.kind.?));
        try std.testing.expectEqual(.accepted, observed.status);
        try expectObservationFieldPresence(&observed);
        var output: [protocol.command_observation_reply.max_bytes]u8 = undefined;
        var writer = std.Io.Writer.fixed(&output);
        try observed.writeJson(&writer);
        try std.testing.expectEqualStrings("{\"status\":\"accepted\",\"kind\":\"" ++ case[0] ++ "\",\"target\":\"k7m2qx\"" ++ case[1] ++ "}", writer.buffered());
        try std.testing.expectError(error.RequestBindingMismatch, CommandObservation.parse(.{ .status = 200, .body = accepted }, "other"));
        const rejected = try CommandObservation.parse(.{ .status = 200, .body = prefix ++ "\"kind\":\"" ++ case[0] ++ "\",\"status\":\"rejected\",\"code\":\"unknown_session\"" ++ case[2] ++ "}}" }, "k");
        try std.testing.expectEqual(.rejected, rejected.status);
        try std.testing.expectEqualStrings("unknown_session", rejected.failureCode().?);
        try expectObservationFieldPresence(&rejected);
        writer = std.Io.Writer.fixed(&output);
        try rejected.writeJson(&writer);
        try std.testing.expectEqualStrings("{\"status\":\"rejected\",\"kind\":\"" ++ case[0] ++ "\",\"target\":\"k7m2qx\",\"code\":\"unknown_session\"" ++ case[2] ++ "}", writer.buffered());
        try std.testing.expectError(error.InvalidObservation, CommandObservation.parse(.{ .status = 200, .body = prefix ++ "\"kind\":\"" ++ case[0] ++ "\",\"status\":\"accepted\"}}" }, "k"));
        if (!std.mem.eql(u8, case[0], "message")) {
            try std.testing.expectError(error.InvalidObservation, CommandObservation.parse(.{ .status = 200, .body = accepted[0 .. accepted.len - 2] ++ ",\"state\":\"queued\"}}" }, "k"));
        }
    }
    inline for (.{ "configure", "message" }) |kind| {
        const state = comptime if (std.mem.eql(u8, kind, "message")) ",\"state\":\"rejected\"" else "";
        const creation = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"command_observation\",\"key\":\"k\",\"delta\":\"full\",\"since\":null,\"observation\":{\"kind\":\"" ++ kind ++ "\",\"status\":\"rejected\"" ++ state ++ ",\"code\":\"invalid_workspace\"";
        const rejected = try CommandObservation.parse(.{ .status = 200, .body = creation ++ ",\"target\":\"\"}}" }, "k");
        try std.testing.expectEqualStrings("", rejected.target.?.slice());
        inline for (.{ "", ",\"target\":null", ",\"target\":17" }) |target|
            try std.testing.expectError(error.InvalidObservation, CommandObservation.parse(.{ .status = 200, .body = creation ++ target ++ "}}" }, "k"));
    }
    const absent = try CommandObservation.parse(.{ .status = 200, .body = testing_observation_prefix ++ "{\"status\":\"absent\"}}" }, "k");
    try expectObservationFieldPresence(&absent);
    const address = try MessageAddress.init("/store", "k7m2qx", "k");
    try std.testing.expectError(error.RequestNotAdmitted, absent.forMessage(&address));
    const rejection = try CommandObservation.parse(.{ .status = 200, .body = prefix ++ "\"kind\":\"message\",\"status\":\"rejected\",\"state\":\"rejected\",\"code\":\"unknown_session\"}}" }, "k");
    const other = try MessageAddress.init("/store", "09azvw", "k");
    try std.testing.expectError(error.RequestBindingMismatch, rejection.forMessage(&other));
}

test "keyed Action observation preserves requested zero and maximum targets but rejects zero selection positions" {
    inline for (.{ "0", "18446744073709551615" }) |target| {
        const facts = "{\"status\":\"rejected\",\"kind\":\"action_background\",\"target\":\"k7m2qx\",\"code\":\"invalid_target\",\"action_target\":{\"action\":\"" ++ target ++ "\"}}";
        const observed = try CommandObservation.parse(.{ .status = 200, .body = testing_observation_prefix ++ facts ++ "}" }, "k");
        try std.testing.expectEqual(try std.fmt.parseInt(u64, target, 10), observed.action_target.?);
        try std.testing.expectEqualStrings("invalid_target", observed.failureCode().?);
        var output: [protocol.command_observation_reply.max_bytes]u8 = undefined;
        var writer = std.Io.Writer.fixed(&output);
        try observed.writeJson(&writer);
        try std.testing.expectEqualStrings(facts, writer.buffered());
    }
    const selected = testing_observation_prefix ++ "{\"status\":\"accepted\",\"kind\":\"action_background\",\"target\":\"k7m2qx\",\"action_target\":{\"action\":\"29\"},\"action_selection\":{\"kind\":\"background\",\"position\":\"0\"}}}";
    try std.testing.expectError(error.InvalidResponse, CommandObservation.parse(.{ .status = 200, .body = selected }, "k"));
}

test "keyed observation distinguishes named statuses and omitted fields from numeric tags and null" {
    const prefix = testing_observation_prefix ++ "{\"target\":\"k7m2qx\",\"code\":\"unknown_session\",";
    inline for (.{ "\"status\":2,\"kind\":\"message\"}}", "\"status\":\"2\",\"kind\":\"message\"}}", "\"status\":\"rejected\",\"kind\":1}}" }) |fields|
        try std.testing.expectError(error.InvalidObservation, CommandObservation.parse(.{ .status = 200, .body = prefix ++ fields }, "k"));
    const absent = testing_observation_prefix ++ "{\"status\":\"absent\"";
    inline for (.{ "kind", "target", "code", "revision", "created", "input", "state", "queue", "binding", "result", "work", "recovery", "selection", "completion", "interruption_target", "permission_target" }) |field|
        try std.testing.expectError(error.InvalidObservation, CommandObservation.parse(.{ .status = 200, .body = absent ++ ",\"" ++ field ++ "\":null}}" }, "k"));
}

test "keyed observation ignores unrelated root extensions and rejects diagnostic envelopes" {
    inline for (.{
        testing_observation_prefix ++ "{\"status\":\"absent\"}",
        testing_observation_prefix ++ "{\"status\":\"accepted\",\"kind\":\"configure\",\"target\":\"k7m2qx\",\"revision\":\"31\",\"created\":true}",
        "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"command_observation\",\"key\":\"k\",\"delta\":\"not_modified\",\"since\":\"abababababababababababababababab.42.k7m2qx\"",
    }) |prefix| {
        inline for (.{ "input", "queue", "execution", "completion", "extension" }) |field| {
            inline for (.{ "null", "{\"nested\":[true,{},null]}" }) |value| {
                _ = try CommandObservation.parseReply(.{ .status = 200, .body = prefix ++ ",\"" ++ field ++ "\":" ++ value ++ "}" }, "k");
            }
        }
        inline for (.{ "code", "answer" }) |field| {
            inline for (.{ "null", "{}" }) |value| {
                try std.testing.expectError(error.InvalidObservation, CommandObservation.parseReply(.{ .status = 200, .body = prefix ++ ",\"" ++ field ++ "\":" ++ value ++ "}" }, "k"));
            }
        }
    }
}

test "keyed observation rejects malformed consequential fields before outcome interpretation" {
    const prefix = testing_observation_prefix ++ testing_observation_message ++ ",\"state\":\"queued\"" ++ testing_observation_input ++ testing_observation_queue;
    inline for (.{
        ",\"binding\":null}}",                                                                         ",\"binding\":{}}}",                                                                                                                                                           ",\"binding\":{\"turn\":7}}}",
        ",\"result\":{\"status\":\"processing\"}}}",                                                   ",\"result\":{\"status\":\"completed\"}}}",                                                                                                                                    ",\"result\":{\"status\":\"failed\",\"code\":17}}}",
        ",\"result\":{\"status\":\"failed\",\"code\":null}}}",                                         ",\"work\":{\"state\":{\"kind\":\"invented\"},\"first_action\":null,\"attention\":null,\"group\":\"done\",\"actions\":{\"stop\":false,\"interrupt\":null,\"decide\":null}}}}", ",\"work\":{\"state\":{\"kind\":\"working\",\"since\":\"1762329000\"}}}}",
        ",\"work\":{\"state\":{\"kind\":\"working\",\"since\":\"1762329000\"},\"first_action\":17}}}", ",\"revision\":\"1\"}}",                                                                                                                                                       ",\"code\":null}}",
        ",\"target\":null}}",                                                                          ",\"state\":\"queued\"}}",                                                                                                                                                     ",\"state\":null}}",
        ",\"queue\":{\"admission\":\"9\",\"admitted_at\":\"1762329000\"}}}",                           ",\"recovery\":{\"unknown_outcomes\":[],\"more\":false}}}",
    }) |suffix| {
        const work = comptime if (std.mem.startsWith(u8, suffix, ",\"work\":")) "" else testing_observation_work;
        try std.testing.expectError(error.InvalidObservation, CommandObservation.parse(.{ .status = 200, .body = prefix ++ work ++ suffix }, "k"));
    }
    inline for (.{ "0", "+7", "07", "18446744073709551616" }) |id|
        try std.testing.expectError(error.InvalidResponse, CommandObservation.parse(.{ .status = 200, .body = prefix ++ ",\"work\":{\"state\":{\"kind\":\"working\",\"since\":\"1762329000\"},\"first_action\":\"" ++ id ++ "\",\"attention\":null,\"group\":\"done\",\"actions\":{\"stop\":false,\"interrupt\":null,\"decide\":null}}}}" }, "k"));
    inline for (.{ "", ",\"state\":\"queued\"", ",\"state\":\"waiting_for_permission\"", ",\"state\":null", ",\"state\":1", ",\"state\":\"invented\"", ",\"state\":\"processing\"", ",\"state\":\"completed\"", ",\"state\":\"rejected\"" }) |state|
        try std.testing.expectError(error.InvalidObservation, CommandObservation.parse(.{ .status = 200, .body = testing_observation_prefix ++ testing_observation_message ++ state ++ testing_observation_input ++ testing_observation_queue ++ "}}" }, "k"));
    inline for (.{ "{}", "[]", "{\"version\":\"" ++ protocol.next_wire_version ++ "\"}", "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"wrong\"}" }) |body|
        try std.testing.expectError(error.InvalidObservation, CommandObservation.parse(.{ .status = 200, .body = body }, "k"));
    var oversized: [protocol.command_observation_reply.max_bytes + 1]u8 = undefined;
    try std.testing.expectError(error.ResponseTooLarge, CommandObservation.parse(.{ .status = 200, .body = &oversized }, "k"));
}

test "keyed observation retains superseded approval work without a decision" {
    inline for (.{ "", testing_observation_binding }) |binding| {
        const facts = testing_observation_message ++ ",\"state\":\"waiting_for_permission\"" ++ testing_observation_input ++ testing_observation_queue ++ binding ++
            ",\"work\":{\"state\":{\"kind\":\"approval\",\"since\":\"1762329010\"},\"first_action\":null,\"attention\":{\"kind\":\"approval\",\"turn\":\"37\",\"step\":\"0\"},\"group\":\"needs_you\",\"actions\":{\"stop\":true,\"interrupt\":null,\"decide\":null}}}";
        const observed = try CommandObservation.parse(.{ .status = 200, .body = testing_observation_prefix ++ facts ++ "}" }, "k");
        try std.testing.expectEqual(.waiting_for_permission, observed.state.?);
        try std.testing.expect(observed.work.?.first_action == null and observed.work.?.actions.decide == null);
        try std.testing.expectEqual(.needs_you, observed.work.?.group);
        var output: [protocol.command_observation_reply.max_bytes]u8 = undefined;
        var writer = std.Io.Writer.fixed(&output);
        try observed.writeJson(&writer);
        try std.testing.expectEqualStrings(facts, writer.buffered());
    }
}

test "keyed observation rejects contradictory permission work variants" {
    inline for (.{
        .{ "waiting_for_permission", "", ",\"work\":{\"state\":{\"kind\":\"working\",\"since\":\"1762329010\"},\"first_action\":\"57\",\"attention\":null,\"group\":\"done\",\"actions\":{\"stop\":false,\"interrupt\":null,\"decide\":null}}" },
        .{ "queued", "", ",\"work\":{\"state\":{\"kind\":\"approval\",\"since\":\"1762329010\"},\"first_action\":\"57\",\"attention\":null,\"group\":\"done\",\"actions\":{\"stop\":false,\"interrupt\":null,\"decide\":null}}" },
        .{ "processing", testing_observation_binding, ",\"work\":{\"state\":{\"kind\":\"approval\",\"since\":\"1762329010\"},\"first_action\":\"57\",\"attention\":null,\"group\":\"done\",\"actions\":{\"stop\":false,\"interrupt\":null,\"decide\":null}}" },
    }) |case| {
        const body = testing_observation_prefix ++ testing_observation_message ++ ",\"state\":\"" ++ case[0] ++ "\"" ++ testing_observation_input ++ testing_observation_queue ++ case[1] ++ case[2] ++ "}}";
        try std.testing.expectError(error.InvalidObservation, CommandObservation.parse(.{ .status = 200, .body = body }, "k"));
    }
    const body = testing_observation_prefix ++ testing_observation_message ++ ",\"state\":\"processing\"" ++ testing_observation_input ++ testing_observation_queue ++ testing_observation_binding ++
        ",\"work\":{\"state\":{\"kind\":\"bash\",\"since\":\"1762329010\",\"call\":\"0\",\"description\":\"Run tests\",\"running\":\"1\",\"approvals\":\"1\"},\"first_action\":\"57\",\"attention\":null,\"group\":\"done\",\"actions\":{\"stop\":false,\"interrupt\":null,\"decide\":null}}}}";
    const observed = try CommandObservation.parse(.{ .status = 200, .body = body }, "k");
    try std.testing.expectEqual(.processing, observed.state.?);
    try std.testing.expectEqual(@as(?u64, 57), observed.work.?.first_action);
}

test "keyed observation owns bounded recovery while running and after completion" {
    const recovery = ",\"recovery\":{\"unknown_outcomes\":[{\"action\":\"57\",\"operation\":\"39\",\"call\":\"0\",\"description\":\"Run \\\"tests\\\"\",\"at\":\"1762329020\"},{\"action\":\"55\",\"operation\":\"39\",\"call\":\"1\",\"description\":null,\"at\":\"1762329020\"}],\"more\":false}";
    inline for (.{
        .{ "processing", testing_observation_work },
        .{ "completed", ",\"result\":{\"status\":\"completed\",\"text\":{\"type\":\"text\",\"bytes\":\"11\",\"sha256\":\"" ++ @as([64]u8, @splat('a')) ++ "\"}}" },
    }) |case| {
        const facts = testing_observation_message ++ ",\"state\":\"" ++ case[0] ++ "\"" ++ testing_observation_input ++ testing_observation_queue ++ testing_observation_binding ++ case[1] ++ recovery ++ "}";
        var storage = (testing_observation_prefix ++ facts ++ "}").*;
        const observed = try CommandObservation.parse(.{ .status = 200, .body = &storage }, "k");
        @memset(&storage, 'x');
        try std.testing.expectEqual(@as(usize, 2), observed.recovery.?.count);
        try std.testing.expectEqual(@as(u64, 57), observed.recovery.?.unknown_outcomes[0].action_id);
        try std.testing.expectEqualStrings("Run \"tests\"", observed.recovery.?.unknown_outcomes[0].description.?.slice());
        try std.testing.expectEqual(@as(u64, 1762329020), observed.recovery.?.unknown_outcomes[0].at);
        var output: [protocol.command_observation_reply.max_bytes]u8 = undefined;
        var writer = std.Io.Writer.fixed(&output);
        try observed.writeJson(&writer);
        try std.testing.expectEqualStrings(facts, writer.buffered());
    }
    const bounded_prefix = testing_observation_prefix ++ testing_observation_message ++ ",\"state\":\"processing\"" ++ testing_observation_input ++ testing_observation_queue ++ testing_observation_binding ++ testing_observation_work ++ ",\"recovery\":{\"unknown_outcomes\":[";
    const four = "{\"action\":\"57\",\"operation\":\"39\",\"call\":\"3\",\"description\":null,\"at\":\"1762329020\"}," ++
        "{\"action\":\"56\",\"operation\":\"39\",\"call\":\"2\",\"description\":null,\"at\":\"1762329020\"}," ++
        "{\"action\":\"55\",\"operation\":\"39\",\"call\":\"1\",\"description\":null,\"at\":\"1762329020\"}," ++
        "{\"action\":\"54\",\"operation\":\"39\",\"call\":\"0\",\"description\":null,\"at\":\"1762329020\"}";
    inline for (.{ "false", "true" }) |more| {
        const observed = try CommandObservation.parse(.{ .status = 200, .body = bounded_prefix ++ four ++ "],\"more\":" ++ more ++ "}}}" }, "k");
        try std.testing.expectEqual(@as(usize, protocol.message_recovery_limit), observed.recovery.?.count);
        try std.testing.expectEqual(std.mem.eql(u8, more, "true"), observed.recovery.?.more);
    }
    const row = "{\"action\":\"57\",\"operation\":\"39\",\"call\":\"0\",\"description\":null,\"at\":\"1762329020\"}";
    const prefix = testing_observation_prefix ++ testing_observation_message ++ ",\"state\":\"processing\"" ++ testing_observation_input ++ testing_observation_queue ++ testing_observation_binding ++ testing_observation_work ++ ",\"recovery\":{\"unknown_outcomes\":[";
    inline for (.{
        "] ,\"more\":false}}}",                                                              row ++ "],\"more\":true}}}",                                                                                                       row ++ "," ++ row ++ "],\"more\":false}}}",
        row ++ "," ++ row ++ "," ++ row ++ "," ++ row ++ "," ++ row ++ "],\"more\":true}}}", "{\"action\":\"57\",\"operation\":\"39\",\"call\":\"0\",\"description\":\"bad\\nline\",\"at\":\"1762329020\"}],\"more\":false}}}",
    }) |suffix| try std.testing.expectError(error.InvalidObservation, CommandObservation.parse(.{ .status = 200, .body = prefix ++ suffix }, "k"));
}

test "keyed observation owns supported strings without retaining unknown DOM across polls" {
    const observation = "{\"status\":\"rejected\",\"kind\":\"message\",\"target\":\"s/µ\",\"code\":\"line\\ncode\",\"state\":\"rejected\"}";
    const body = testing_observation_prefix ++ "{\"status\":\"rejected\",\"kind\":\"message\",\"target\":\"s\\u002fµ\",\"code\":\"line\\ncode\",\"state\":\"rejected\",\"unknown\":{\"precise\":123456789012345678901234567890,\"items\":[true,null,\"discard\"]}}}";
    for (0..100) |_| {
        var storage = body.*;
        const observed = try CommandObservation.parse(.{ .status = 200, .body = &storage }, "k");
        @memset(&storage, 'x');
        try std.testing.expectEqualStrings("line\ncode", observed.failureCode().?);
        var output: [body.len]u8 = undefined;
        var writer = std.Io.Writer.fixed(&output);
        try observed.writeJson(&writer);
        try std.testing.expectEqualStrings(observation, writer.buffered());
        var too_small = std.Io.Writer.fixed(&.{});
        try std.testing.expectError(error.WriteFailed, observed.writeJson(&too_small));
    }
}

test "keyed observation read diagnostics are owned without claiming admission" {
    const wire = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"busy\",\"code\":\"ordinary_capacity_exhausted\",\"unknown\":[1,2,3]}";
    var storage = wire.*;
    const busy = try decodeReadFailure(.{ .status = 503, .body = &storage }, false);
    @memset(&storage, 'x');
    try std.testing.expectEqual(@as(u16, 503), busy.status);
    try std.testing.expectEqualStrings("ordinary_capacity_exhausted", busy.diagnostic.code.slice());
    try std.testing.expectEqual(error.HostInvocationFailed, busy.err());
    const fatal = try decodeReadFailure(.{ .status = 500, .body = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"invocation_error\",\"code\":\"canonical_store_failure\"}" }, false);
    try std.testing.expectEqual(error.CanonicalStoreFailure, fatal.err());
    inline for (.{ "result_not_found", "result_not_ready", "result_failed" }) |code| {
        const reply: CommandReply = .{ .status = 409, .body = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"result_unavailable\",\"code\":\"" ++ code ++ "\"}" };
        try std.testing.expectEqualStrings(code, (try decodeReadFailure(reply, true)).diagnostic.code.slice());
        try std.testing.expectError(error.InvalidResponse, decodeReadFailure(reply, false));
    }
    inline for (.{ "null", "{}" }) |value|
        try std.testing.expectError(error.InvalidResponse, decodeReadFailure(.{ .status = 500, .body = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"invocation_error\",\"code\":\"canonical_store_failure\",\"observation\":" ++ value ++ "}" }, false));
    std.debug.print("keyed facts bytes={d}; reply bytes={d}; fixed parser scratch={d}; no retained allocator/DOM\n", .{
        @sizeOf(CommandObservation), @sizeOf(protocol.CommandObservationBuffer), std.ArrayList(u8).growCapacity((protocol.command_observation_reply.max_bytes + 7) / 8) + std.ArrayList(u8).growCapacity(protocol.command_observation_reply.max_bytes),
    });
}

test "Current facts preserve explicit unconfigured and promised range" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "current", .{ .read = true });
    defer file.close(io);
    const wire = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"session_report\",\"delta\":\"full\",\"since\":null,\"profile\":\"current\",\"session\":null,\"pending_messages\":\"0\",\"execution\":{\"status\":\"unavailable\",\"reason\":\"session_not_found\"}}";
    try file.writePositionalAll(io, wire ++ "false", 0);
    try std.testing.expect((try CurrentReply.decode(io, file, "unknown", .{ .report = .{ .bytes = wire.len } })) == .unconfigured);
    inline for (.{ 0, wire.len - 1, wire.len + 1, wire.len + 6 }) |length|
        try std.testing.expectError(error.InvalidObservation, CurrentReply.decode(io, file, "unknown", .{ .report = .{ .bytes = length } }));
}

test "Current excludes conditional replies and requires explicit full null token" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "current-contract", .{ .read = true });
    defer file.close(io);
    inline for (.{
        "",
        "\"delta\":\"full\",",
        "\"since\":null,",
        "\"delta\":\"not_modified\",\"since\":null,",
        "\"delta\":\"full\",\"since\":\"host.1.k7m2qx\",",
    }) |fields| {
        const wire = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"session_report\"," ++ fields ++ "\"profile\":\"current\",\"session\":null,\"pending_messages\":\"0\",\"execution\":{\"status\":\"unavailable\",\"reason\":\"session_not_found\"}}";
        try file.setLength(io, 0);
        try file.writePositionalAll(io, wire, 0);
        try std.testing.expectError(error.InvalidObservation, CurrentReply.decode(io, file, "k7m2qx", .{ .report = .{ .bytes = wire.len } }));
    }
}

test "Current settings preserve decimal token heuristics in projections" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "current", .{ .read = true });
    defer file.close(io);
    const wire = "{\"reference\":\"k7m2qx\",\"parent\":null,\"workspace\":\"/w\",\"provider\":\"codex\",\"model\":\"m\",\"revision\":\"1\",\"tools\":[],\"loaded_tools\":[],\"permission_mode\":\"ask\",\"instructions\":{\"type\":\"text\",\"bytes\":\"0\",\"sha256\":\"" ++ @as([64]u8, @splat('0')) ++ "\"},\"output_schema\":null,\"reasoning_effort\":\"high\",\"reasoning_effort_override\":\"high\",\"compaction_trigger\":\"100000\",\"output_reservation\":\"16384\",\"compaction_trigger_override\":null,\"output_reservation_override\":null,\"label\":null,\"created_at\":\"1\"}";
    const report = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"session_report\",\"delta\":\"full\",\"since\":null,\"profile\":\"current\",\"archive_state\":\"active\",\"session\":" ++ wire ++ ",\"pending_messages\":\"0\",\"work\":{\"state\":{\"kind\":\"idle\",\"since\":\"1\"},\"turn\":null,\"operation\":null,\"first_action\":null,\"attention\":null,\"group\":\"done\",\"actions\":{\"stop\":false,\"interrupt\":null,\"decide\":null},\"latest_outcome\":null},\"peers\":{\"from_person_at\":null},\"selected_message\":null,\"recent_messages\":[],\"actions\":{\"count\":\"0\",\"unresolved\":[],\"resolved\":[]},\"rejected_calls\":{\"count\":\"0\",\"items\":[]},\"actionable_permissions\":[],\"execution\":{\"status\":\"partial\",\"dispatch_fenced\":false,\"custody_occupied\":\"0\",\"scratch_used_bytes\":\"0\",\"unavailable\":[\"structured_output\"]}}";
    try file.writePositionalAll(io, report, 0);
    const reply = try CurrentReply.decode(io, file, "k7m2qx", .{ .report = .{ .bytes = report.len } });
    try std.testing.expectEqual(@as(u64, 100000), reply.current.settings.compaction_trigger.?.value);
    try std.testing.expectEqual(@as(u64, 16384), reply.current.settings.output_reservation.value);
    try std.testing.expectEqual(protocol.ReasoningEffort.high, reply.current.settings.reasoning_effort.?.value);
    try std.testing.expectEqual(protocol.ReasoningEffort.high, reply.current.settings.reasoning_effort_override.?.value);
    for ([_]struct { fields: []const u8, names: []const u8, loaded: u8 }{
        .{ .fields = "\"tools\":[\"bash\"],\"loaded_tools\":[]", .names = "bash", .loaded = 0 },
        .{ .fields = "\"tools\":[\"bash\",\"fetch_page\"],\"loaded_tools\":[\"bash\",\"fetch_page\"]", .names = "bash fetch_page", .loaded = 2 },
    }) |case| {
        const changed = try std.mem.replaceOwned(u8, std.testing.allocator, report, "\"tools\":[],\"loaded_tools\":[]", case.fields);
        defer std.testing.allocator.free(changed);
        try file.writePositionalAll(io, changed, 0);
        const settings = (try CurrentReply.decode(io, file, "k7m2qx", .{ .report = .{ .bytes = changed.len } })).current.settings;
        try std.testing.expectEqualStrings(case.names, settings.tools.names.names.slice());
        try std.testing.expect(settings.tools.set.contains(.bash) and !settings.tools.set.contains(.web_search));
        try std.testing.expectEqual(case.loaded, settings.loaded_tools.names.count);
    }
    try file.writePositionalAll(io, report, 0);
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try reply.current.writeJson(io, file, &writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\"compaction_trigger\":\"100000\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\"output_reservation\":\"16384\"") != null);
    for ([_][]const u8{ ",\"archive_state\":\"active\"", ",\"parent\":null", ",\"created_at\":\"1\"", ",\"peers\":{\"from_person_at\":null}" }) |required| {
        const at = std.mem.indexOf(u8, report, required).?;
        var missing_buffer: [4096]u8 = undefined;
        const missing = try std.fmt.bufPrint(&missing_buffer, "{s}{s}", .{ report[0..at], report[at + required.len ..] });
        try file.writePositionalAll(io, missing, 0);
        try std.testing.expectError(error.InvalidObservation, CurrentReply.decode(io, file, "k7m2qx", .{ .report = .{ .bytes = missing.len } }));
    }
    for ([_]struct { text: []const u8, expected: ?protocol.SessionArchiveState }{
        .{ .text = "\"active\"", .expected = .active },
        .{ .text = "\"archiving\"", .expected = .archiving },
        .{ .text = "\"archived\"", .expected = .archived },
        .{ .text = "null", .expected = null },
        .{ .text = "\"unknown\"", .expected = null },
    }) |case| {
        const field = try std.fmt.allocPrint(std.testing.allocator, "\"archive_state\":{s}", .{case.text});
        defer std.testing.allocator.free(field);
        const changed = try std.mem.replaceOwned(u8, std.testing.allocator, report, "\"archive_state\":\"active\"", field);
        defer std.testing.allocator.free(changed);
        try file.writePositionalAll(io, changed, 0);
        const decoded = CurrentReply.decode(io, file, "k7m2qx", .{ .report = .{ .bytes = changed.len } });
        if (case.expected) |expected| {
            const current = (try decoded).current;
            try std.testing.expectEqual(expected, current.archive_state);
            var projected: [4096]u8 = undefined;
            var projection = std.Io.Writer.fixed(&projected);
            try current.writeJson(io, file, &projection);
            try std.testing.expect(std.mem.indexOf(u8, projection.buffered(), case.text) != null);
        } else try std.testing.expectError(error.InvalidObservation, decoded);
    }
    const parent_start = std.mem.indexOf(u8, report, ",\"parent\":null").?;
    for ([_][]const u8{ "\"k7m2qX\"", "\"k7m2qx\"", "\"abcdefg\"", "0" }) |invalid| {
        var changed_buffer: [4096]u8 = undefined;
        const changed = try std.fmt.bufPrint(&changed_buffer, "{s},\"parent\":{s}{s}", .{ report[0..parent_start], invalid, report[parent_start + ",\"parent\":null".len ..] });
        try file.writePositionalAll(io, changed, 0);
        try std.testing.expectError(error.InvalidObservation, CurrentReply.decode(io, file, "k7m2qx", .{ .report = .{ .bytes = changed.len } }));
    }
    const effort_start = std.mem.indexOf(u8, report, ",\"reasoning_effort\"").?;
    const effort_end = std.mem.indexOf(u8, report, ",\"compaction_trigger\"").?;
    for ([_]struct { fields: []const u8, valid: bool }{
        .{ .fields = ",\"reasoning_effort\":\"low\",\"reasoning_effort_override\":null", .valid = true },
        .{ .fields = ",\"reasoning_effort\":null,\"reasoning_effort_override\":null", .valid = true },
        .{ .fields = "", .valid = false },
        .{ .fields = ",\"reasoning_effort\":null", .valid = false },
        .{ .fields = ",\"reasoning_effort_override\":null", .valid = false },
        .{ .fields = ",\"reasoning_effort\":\"ultra\",\"reasoning_effort_override\":null", .valid = false },
        .{ .fields = ",\"reasoning_effort\":\"medium\",\"reasoning_effort_override\":\"default\"", .valid = false },
    }) |case| {
        var changed_buffer: [4096]u8 = undefined;
        const changed = try std.fmt.bufPrint(&changed_buffer, "{s}{s}{s}", .{ report[0..effort_start], case.fields, report[effort_end..] });
        try file.writePositionalAll(io, changed, 0);
        const decoded = CurrentReply.decode(io, file, "k7m2qx", .{ .report = .{ .bytes = changed.len } });
        if (case.valid) {
            try std.testing.expect((try decoded).current.settings.reasoning_effort_override == null);
        } else try std.testing.expectError(error.InvalidObservation, decoded);
    }
    const prefix = wire[0..std.mem.indexOf(u8, wire, ",\"compaction_trigger\"").?];
    const cases = [_]struct { suffix: []const u8, valid: bool }{
        .{ .suffix = "}", .valid = false },
        .{ .suffix = ",\"compaction_trigger\":null,\"output_reservation\":\"0\",\"compaction_trigger_override\":null}", .valid = false },
        .{ .suffix = ",\"compaction_trigger\":null,\"output_reservation\":\"0\",\"output_reservation_override\":null,\"label\":null,\"created_at\":\"1\"}", .valid = false },
        .{ .suffix = ",\"compaction_trigger\":null,\"compaction_trigger_override\":null,\"output_reservation_override\":null,\"label\":null,\"created_at\":\"1\"}", .valid = false },
        .{ .suffix = ",\"output_reservation\":\"0\",\"compaction_trigger_override\":null,\"output_reservation_override\":null,\"label\":null,\"created_at\":\"1\"}", .valid = false },
        .{ .suffix = ",\"compaction_trigger\":null,\"output_reservation\":\"0\",\"compaction_trigger_override\":null,\"output_reservation_override\":null,\"label\":null,\"created_at\":\"1\"}", .valid = true },
        .{ .suffix = ",\"compaction_trigger\":\"42\",\"output_reservation\":\"0\",\"compaction_trigger_override\":\"42\",\"output_reservation_override\":\"0\",\"label\":null,\"created_at\":\"1\"}", .valid = true },
        .{ .suffix = ",\"compaction_trigger\":\"0\",\"output_reservation\":\"0\",\"compaction_trigger_override\":null,\"output_reservation_override\":null,\"label\":null,\"created_at\":\"1\"}", .valid = false },
        .{ .suffix = ",\"compaction_trigger\":null,\"output_reservation\":null,\"compaction_trigger_override\":null,\"output_reservation_override\":null,\"label\":null,\"created_at\":\"1\"}", .valid = false },
        .{ .suffix = ",\"compaction_trigger\":null,\"output_reservation\":\"0\",\"compaction_trigger_override\":\"0\",\"output_reservation_override\":null,\"label\":null,\"created_at\":\"1\"}", .valid = false },
        .{ .suffix = ",\"compaction_trigger\":null,\"output_reservation\":\"0\",\"compaction_trigger_override\":null,\"output_reservation_override\":\"-1\",\"label\":null,\"created_at\":\"1\"}", .valid = false },
        .{ .suffix = ",\"compaction_trigger\":null,\"output_reservation\":\"01\",\"compaction_trigger_override\":null,\"output_reservation_override\":null,\"label\":null,\"created_at\":\"1\"}", .valid = false },
        .{ .suffix = ",\"compaction_trigger\":null,\"output_reservation\":1,\"compaction_trigger_override\":null,\"output_reservation_override\":null,\"label\":null,\"created_at\":\"1\"}", .valid = false },
        .{ .suffix = ",\"compaction_trigger\":\"42\",\"context_estimate\":\"50\",\"output_reservation\":\"0\",\"compaction_trigger_override\":\"42\",\"output_reservation_override\":\"0\",\"label\":null,\"created_at\":\"1\"}", .valid = true },
        .{ .suffix = ",\"compaction_trigger\":\"42\",\"context_estimate\":\"0\",\"output_reservation\":\"0\",\"compaction_trigger_override\":\"42\",\"output_reservation_override\":\"0\",\"label\":null,\"created_at\":\"1\"}", .valid = true },
        .{ .suffix = ",\"compaction_trigger\":null,\"context_estimate\":null,\"output_reservation\":\"0\",\"compaction_trigger_override\":null,\"output_reservation_override\":null,\"label\":null,\"created_at\":\"1\"}", .valid = true },
        .{ .suffix = ",\"compaction_trigger\":\"42\",\"context_estimate\":null,\"output_reservation\":\"0\",\"compaction_trigger_override\":\"42\",\"output_reservation_override\":\"0\",\"label\":null,\"created_at\":\"1\"}", .valid = true },
        .{ .suffix = ",\"compaction_trigger\":null,\"context_estimate\":\"5\",\"output_reservation\":\"0\",\"compaction_trigger_override\":null,\"output_reservation_override\":null,\"label\":null,\"created_at\":\"1\"}", .valid = false },
        .{ .suffix = ",\"compaction_trigger\":\"42\",\"context_estimate\":\"-1\",\"output_reservation\":\"0\",\"compaction_trigger_override\":\"42\",\"output_reservation_override\":\"0\",\"label\":null,\"created_at\":\"1\"}", .valid = false },
    };
    for (cases) |case| {
        var settings_buffer: [4096]u8 = undefined;
        const session_start = std.mem.indexOf(u8, report, wire).?;
        const settings_json = try std.fmt.bufPrint(&settings_buffer, "{s}{s}{s}{s}", .{ report[0..session_start], prefix, case.suffix, report[session_start + wire.len ..] });
        try file.writePositionalAll(io, settings_json, 0);
        if (case.valid) {
            const parsed = try CurrentReply.decode(io, file, "k7m2qx", .{ .report = .{ .bytes = settings_json.len } });
            var projection_buffer: [4096]u8 = undefined;
            var projection = std.Io.Writer.fixed(&projection_buffer);
            try parsed.current.writeJson(io, file, &projection);
            if (parsed.current.settings.compaction_trigger == null)
                try std.testing.expect(std.mem.indexOf(u8, projection.buffered(), "\"compaction_trigger\":null") != null);
            if (std.mem.indexOf(u8, case.suffix, "\"context_estimate\":")) |at| {
                const end = std.mem.indexOfScalarPos(u8, case.suffix, at, ',').?;
                try std.testing.expect(std.mem.indexOf(u8, projection.buffered(), case.suffix[at..end]) != null);
            } else try std.testing.expect(std.mem.indexOf(u8, projection.buffered(), "context_estimate") == null);
        } else {
            try std.testing.expectError(error.InvalidObservation, CurrentReply.decode(io, file, "k7m2qx", .{ .report = .{ .bytes = settings_json.len } }));
        }
    }
}

test "Current facts retain settings selected empty key and ten recent bindings" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "current", .{ .read = true });
    defer file.close(io);
    var buffer: [protocol.content_window_bytes]u8 = undefined;
    var output = file.writerStreaming(io, &buffer);
    const writer = &output.interface;
    const reference = "{\"type\":\"text\",\"bytes\":\"7\",\"sha256\":\"" ++ @as([64]u8, @bitCast(@as([4][16]u8, @splat("0123456789abcdef".*)))) ++ "\"}";
    try writer.writeAll("{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"session_report\",\"delta\":\"full\",\"since\":null,\"profile\":\"current\",\"archive_state\":\"active\",\"session\":{\"reference\":\"k7m2qx\",\"parent\":\"p33rs1\",\"workspace\":\"/w\",\"provider\":\"codex\",\"model\":\"exact\\u0001model\",\"revision\":\"17\",\"tools\":[],\"loaded_tools\":[],\"permission_mode\":\"ask\",\"instructions\":" ++ reference ++ ",\"output_schema\":null,\"reasoning_effort\":null,\"reasoning_effort_override\":null,\"compaction_trigger\":null,\"output_reservation\":\"0\",\"compaction_trigger_override\":null,\"output_reservation_override\":null,\"label\":\"Review PR 412\",\"created_at\":\"1792925000\"},\"pending_messages\":\"2\",\"work\":{\"state\":{\"kind\":\"pending\",\"since\":\"1792925300\"},\"turn\":\"37\",\"operation\":\"91\",\"first_action\":null,\"attention\":null,\"group\":\"done\",\"actions\":{\"stop\":false,\"interrupt\":null,\"decide\":null},\"latest_outcome\":{\"code\":\"failed_saved\",\"content\":null}},\"peers\":{\"from_person_at\":\"1792925300\"},\"first_message\":{\"position\":\"1\",\"admission\":\"4\",\"admitted_at\":\"1792925001\",\"sender\":null,\"content\":" ++ reference ++ "},\"selected_message\":\"\",\"recent_messages\":[");
    for (0..10) |i| {
        if (i != 0) try writer.writeAll(",");
        try writer.print("{{\"turn\":\"{d}\",\"message\":\"key/{d}\",\"outcome\":\"completed\"}}", .{ 30 - i, i });
    }
    try writer.writeAll("],\"actions\":{\"count\":\"0\",\"unresolved\":[],\"resolved\":[]},\"rejected_calls\":{\"count\":\"0\",\"items\":[]},\"actionable_permissions\":[],\"execution\":{\"status\":\"partial\",\"dispatch_fenced\":false,\"custody_occupied\":\"3\",\"scratch_used_bytes\":\"123\",\"unavailable\":[\"structured_output\"]}}");
    try output.flush();
    const bytes = try file.length(io);
    const reply = try CurrentReply.decode(io, file, "k7m2qx", .{ .report = .{ .bytes = bytes } });
    const facts = &reply.current;
    try std.testing.expectEqualStrings("exact\x01model", facts.settings.model.slice());
    try std.testing.expectEqualStrings("p33rs1", facts.settings.parent.?.slice());
    try std.testing.expectEqual(@as(u64, 17), facts.settings.revision.value);
    try std.testing.expectEqual(@as(u64, 7), facts.settings.instructions.value.text.length);
    try std.testing.expect(facts.settings.reasoning_effort == null and facts.settings.reasoning_effort_override == null and facts.selected_message != null);
    try std.testing.expectEqualStrings("", facts.selected_message.?.slice());
    try std.testing.expectEqual(@as(u64, 91), facts.work.operation.?.value);
    try std.testing.expectEqualStrings("Review PR 412", facts.settings.label.?.slice());
    try std.testing.expectEqual(@as(u64, 1792925000), facts.settings.created_at.value);
    try std.testing.expectEqual(@as(u64, 1792925300), facts.peers.from_person_at.?.value);
    try std.testing.expectEqual(@as(u64, 1), facts.first_message.value.?.?.value.position);
    try std.testing.expectEqual(@as(u64, 4), facts.first_message.value.?.?.value.admission);
    try std.testing.expectEqual(@as(usize, 10), facts.recent_count);
    for (facts.recent[0..10], 0..) |row, i| try std.testing.expectEqual(@as(u64, 30 - i), row.turn.value);
    try std.testing.expectError(error.InvalidObservation, CurrentReply.decode(io, file, "09azvw", .{ .report = .{ .bytes = bytes } }));
    var rendered: [4096]u8 = undefined;
    var json = std.Io.Writer.fixed(&rendered);
    try facts.writeJson(io, file, &json);
    try std.testing.expect(std.mem.indexOf(u8, json.buffered(), "\"revision\":\"17\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.buffered(), "\"reasoning_effort\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.buffered(), "\"reasoning_effort_override\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.buffered(), "\"selected_message\":\"\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.buffered(), "\"label\":\"Review PR 412\",\"created_at\":\"1792925000\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.buffered(), "\"peers\":{\"from_person_at\":\"1792925300\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.buffered(), "\"parent\":\"p33rs1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.buffered(), "\"first_message\":{\"position\":\"1\",\"admission\":\"4\",\"admitted_at\":\"1792925001\",\"sender\":null,\"content\":" ++ reference ++ "}") != null);
    try file.writePositionalAll(io, "x", 0);
    try std.testing.expectEqualStrings("exact\x01model", facts.settings.model.slice());
    try std.testing.expectEqualStrings("p33rs1", facts.settings.parent.?.slice());
}

test "a hosted call travels as its presentation alone, in the conversation and the activity" {
    var description: protocol.Bounded(protocol.max_tool_description_bytes) = .{};
    try description.set("Search \"zig\"");
    const presentation: protocol.ToolPresentation = .{ .description = description, .code = .failed, .publication_position = 7 };
    const conversation = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"conversation_page\",\"direction\":\"newest_first\",\"end\":\"9\",\"items\":[" ++
        "{\"position\":\"7\",\"ordinal\":\"0\",\"kind\":\"hosted_call\",\"presentation\":{\"description\":\"Search \\\"zig\\\"\",\"code\":\"failed\",\"publication_position\":\"7\"}}],\"more\":false}";
    const page = try ConversationPage.parse(conversation, .{ .end = 0 });
    try std.testing.expectEqual(@as(usize, 1), page.count);
    try std.testing.expectEqual(protocol.ConversationItemKind.hosted_call, page.items[0].kind);
    try std.testing.expectEqual(@as(u64, 0), page.items[0].content.text.length);
    try std.testing.expectEqualDeep(presentation, page.items[0].presentation.?);
    for ([_][]const u8{
        "{\"position\":\"7\",\"ordinal\":\"0\",\"kind\":\"hosted_call\",\"content\":{\"type\":\"text\",\"bytes\":\"0\",\"sha256\":\"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\"},\"presentation\":{\"description\":\"a\",\"code\":\"failed\",\"publication_position\":\"7\"}}",
        "{\"position\":\"7\",\"ordinal\":\"0\",\"kind\":\"hosted_call\",\"presentation\":{\"description\":null,\"code\":\"failed\",\"publication_position\":\"7\"}}",
        "{\"position\":\"7\",\"ordinal\":\"0\",\"kind\":\"hosted_call\"}",
        "{\"position\":\"7\",\"ordinal\":\"1\",\"kind\":\"hosted_call\",\"presentation\":{\"description\":\"a\",\"code\":\"failed\",\"publication_position\":\"7\"}}",
        "{\"position\":\"7\",\"ordinal\":\"0\",\"kind\":\"assistant\"}",
    }) |item| {
        var buffer: [1024]u8 = undefined;
        const bytes = try std.fmt.bufPrint(&buffer, "{{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"conversation_page\",\"direction\":\"newest_first\",\"end\":\"9\",\"items\":[{s}],\"more\":false}}", .{item});
        try std.testing.expectError(error.InvalidConversationPage, ConversationPage.parse(bytes, .{ .end = 0 }));
    }

    var facts: protocol.ActivityFacts = .{ .end = 9, .count = 1, .work = .{ .work = .{ .state = .{ .idle = .{ .since = 1 } } }, .revision = 1 } };
    try facts.work.workspace.set("/w");
    facts.items[0] = .{ .position = 7, .at = 5, .value = .{ .hosted_call = presentation } };
    var activity_buffer: [activity_reply.max_page_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&activity_buffer);
    try activity_reply.writePage(&writer, &facts);
    const activity = try ActivityPage.parse(writer.buffered(), .{});
    try std.testing.expectEqualDeep(presentation, activity.facts.items[0].value.hosted_call);
}

test "session change activity carries refusal text only for a refused later revision" {
    for (std.enums.values(protocol.SessionField)) |field| {
        for ([_]u64{ 1, 2 }) |revision| {
            for ([_]bool{ false, true }) |has_text| {
                var facts: protocol.ActivityFacts = .{ .end = 1, .count = 1, .work = .{ .work = .{ .state = .{ .idle = .{ .since = 1 } } }, .revision = 2 } };
                try facts.work.workspace.set("/w");
                facts.items[0] = .{ .position = 1, .at = 1, .value = .{ .session_changed = .{ .revision = revision, .field = field } } };
                if (has_text) {
                    facts.items[0].value.session_changed.provider_text = .{};
                    try facts.items[0].value.session_changed.provider_text.?.set("unsupported_value: high \"effort\" is not supported");
                }
                var buffer: [activity_reply.max_page_bytes]u8 = undefined;
                var writer = std.Io.Writer.fixed(&buffer);
                try activity_reply.writePage(&writer, &facts);
                if (revision > 1 and (field == .reasoning_effort_refused) == has_text) {
                    const page = try ActivityPage.parse(writer.buffered(), .{});
                    try std.testing.expectEqualDeep(facts.items[0].value.session_changed, page.facts.items[0].value.session_changed);
                } else {
                    try std.testing.expectError(error.InvalidActivityPage, ActivityPage.parse(writer.buffered(), .{}));
                }
            }
        }
    }
}

test "approval activity accepts own and forwarded ordinals and validates child session" {
    for ([_]u64{ 0, 1, 2 }) |ordinal| {
        for ([_][]const u8{ "k7m2qx", "BAD" }) |session| {
            var facts: protocol.ActivityFacts = .{ .end = 1, .count = 1, .work = .{ .work = .{ .state = .{ .idle = .{ .since = 1 } } }, .revision = 1 } };
            facts.items[0] = .{ .position = 1, .ordinal = ordinal, .at = 1, .value = .{ .approval_requested = .{ .session = .{}, .action = 1, .operation = 1, .call_ordinal = 0 } } };
            try facts.items[0].value.approval_requested.session.set(session);
            try facts.work.workspace.set("/w");
            var buffer: [activity_reply.max_page_bytes]u8 = undefined;
            var writer = std.Io.Writer.fixed(&buffer);
            try activity_reply.writePage(&writer, &facts);
            if (ordinal < 2 and protocol.validSessionId(session)) {
                const page = try ActivityPage.parse(writer.buffered(), .{});
                try std.testing.expectEqualStrings(session, page.facts.items[0].value.approval_requested.session.slice());
            } else {
                try std.testing.expectError(error.InvalidActivityPage, ActivityPage.parse(writer.buffered(), .{}));
            }
        }
    }
}

test "call and approval activity round trip saved inline description tool and server" {
    var description: protocol.Bounded(protocol.max_tool_description_bytes) = .{};
    try description.set("Fetch \"saved\" café");
    var tool: protocol.Bounded(protocol.max_tool_name_bytes) = .{};
    try tool.set("fetch_page");
    var server: protocol.Bounded(protocol.max_tool_name_bytes) = .{};
    try server.set("docs");
    const field: protocol.ProposalFieldReference = .{ .length = 0, .digest = @splat(0) };
    for ([_]protocol.ActivityItem.Value{
        .{ .call = .{ .position = 1, .operation = 2, .turn = 1, .call_ordinal = 0, .action = 3, .rejection = null, .fields = @splat(field), .description = description, .tool = tool, .server = server } },
        .{ .approval_requested = .{ .session = .{ .bytes = "ch11d1".*, .len = 6 }, .action = 3, .operation = 2, .call_ordinal = 0, .description = description, .tool = tool, .server = server } },
    }) |value| {
        var facts: protocol.ActivityFacts = .{ .end = 1, .count = 1, .work = .{ .work = .{ .state = .{ .idle = .{ .since = 1 } } }, .revision = 1 } };
        facts.items[0] = .{ .position = 1, .at = 1, .value = value };
        try facts.work.workspace.set("/w");
        var buffer: [activity_reply.max_page_bytes]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try activity_reply.writePage(&writer, &facts);
        const parsed = try ActivityPage.parse(writer.buffered(), .{});
        try std.testing.expectEqualDeep(value, parsed.facts.items[0].value);
        const missing = try std.mem.replaceOwned(u8, std.testing.allocator, writer.buffered(), ",\"server\":\"docs\"", "");
        defer std.testing.allocator.free(missing);
        try std.testing.expectError(error.InvalidActivityPage, ActivityPage.parse(missing, .{}));
    }
}

test "approval and ending activity require a valid explicit child session" {
    for ([_]protocol.ActivityItem.Value{
        .{ .approval_requested = .{ .session = .{ .bytes = "k7m2qx".*, .len = 6 }, .action = 1, .operation = 1, .call_ordinal = 0 } },
        .{ .turn_ended = .{ .session = .{ .bytes = "k7m2qx".*, .len = 6 }, .turn = 1, .operation = 1, .ending = .stopped, .code = .{ .bytes = "cancelled".* ++ @as([protocol.max_code_bytes - 9]u8, undefined), .len = 9 }, .content = null } },
    }) |value| {
        var facts: protocol.ActivityFacts = .{ .end = 1, .count = 1, .work = .{ .work = .{ .state = .{ .idle = .{ .since = 1 } } }, .revision = 1 } };
        facts.items[0] = .{ .position = 1, .at = 1, .value = value };
        try facts.work.workspace.set("/w");
        var buffer: [activity_reply.max_page_bytes]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try activity_reply.writePage(&writer, &facts);
        _ = try ActivityPage.parse(writer.buffered(), .{});
        for ([_][]const u8{ "", "\"session\":\"BAD\",", "\"session\":null," }) |replacement| {
            const malformed = try std.mem.replaceOwned(u8, std.testing.allocator, writer.buffered(), "\"session\":\"k7m2qx\",", replacement);
            defer std.testing.allocator.free(malformed);
            try std.testing.expectError(error.InvalidActivityPage, ActivityPage.parse(malformed, .{}));
        }
    }
}

test "keyed observation decodes full and unchanged metadata with request binding" {
    const token_text = "abababababababababababababababab.42.k7m2qx";
    const token = try SessionToken.parse(token_text);
    const prefix = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"command_observation\",\"key\":\"k\",\"delta\":";
    const full = prefix ++ "\"full\",\"since\":\"" ++ token_text ++ "\",\"observation\":{\"status\":\"rejected\",\"kind\":\"message\",\"target\":\"k7m2qx\",\"code\":\"unknown_session\",\"state\":\"rejected\"}}";
    const observed = try ObservationReply.parse(.{ .status = 200, .body = full }, "k", null);
    try std.testing.expectEqualDeep(token, observed.observation.since.?);
    try std.testing.expectEqual(.rejected, observed.observation.facts.status);
    const absent = try ObservationReply.parse(.{ .status = 200, .body = testing_observation_prefix ++ "{\"status\":\"absent\"}}" }, "k", token);
    try std.testing.expectEqual(@as(?SessionToken, null), absent.observation.since);
    const unchanged = prefix ++ "\"not_modified\",\"since\":\"" ++ token_text ++ "\"}";
    const repeated = try ObservationReply.parse(.{ .status = 200, .body = unchanged }, "k", token.at(41));
    try std.testing.expectEqualDeep(token, repeated.not_modified);
    try std.testing.expectError(error.RequestBindingMismatch, ObservationReply.parse(.{ .status = 200, .body = unchanged }, "other", token));
    try std.testing.expectError(error.InvalidObservation, ObservationReply.parse(.{ .status = 200, .body = unchanged }, "k", null));
    try std.testing.expectError(error.RequestBindingMismatch, ObservationReply.parse(.{ .status = 200, .body = unchanged }, "k", token.at(43)));
    var foreign = token;
    foreign.instance[0] = 0;
    try std.testing.expectError(error.RequestBindingMismatch, ObservationReply.parse(.{ .status = 200, .body = unchanged }, "k", foreign));
    foreign = token;
    foreign.session = "abc123".*;
    try std.testing.expectError(error.RequestBindingMismatch, ObservationReply.parse(.{ .status = 200, .body = unchanged }, "k", foreign));
    const mismatched = prefix ++ "\"full\",\"since\":\"abababababababababababababababab.42.abc123\",\"observation\":{\"status\":\"rejected\",\"kind\":\"message\",\"target\":\"k7m2qx\",\"code\":\"unknown_session\",\"state\":\"rejected\"}}";
    try std.testing.expectError(error.RequestBindingMismatch, ObservationReply.parse(.{ .status = 200, .body = mismatched }, "k", null));
}

test "keyed observation requires valid delta since and shape-specific facts" {
    const prefix = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"command_observation\",\"key\":\"k\",";
    const token = try SessionToken.parse("abababababababababababababababab.42.k7m2qx");
    inline for (.{
        "\"observation\":{\"status\":\"absent\"}",
        "\"delta\":\"full\",\"observation\":{\"status\":\"absent\"}",
        "\"since\":null,\"observation\":{\"status\":\"absent\"}",
        "\"delta\":\"changed\",\"since\":null,\"observation\":{\"status\":\"absent\"}",
        "\"delta\":null,\"since\":null,\"observation\":{\"status\":\"absent\"}",
        "\"delta\":\"full\",\"since\":false,\"observation\":{\"status\":\"absent\"}",
        "\"delta\":\"full\",\"since\":\"invalid\",\"observation\":{\"status\":\"absent\"}",
        "\"delta\":\"full\",\"since\":null",
        "\"delta\":\"full\",\"since\":null,\"observation\":null",
        "\"delta\":\"not_modified\",\"since\":null",
        "\"delta\":\"not_modified\"",
        "\"delta\":\"not_modified\",\"since\":\"invalid\"",
        "\"delta\":\"not_modified\",\"since\":\"abababababababababababababababab.42.k7m2qx\",\"observation\":{\"status\":\"absent\"}",
        "\"delta\":\"not_modified\",\"since\":\"abababababababababababababababab.42.k7m2qx\",\"observation\":null",
        "\"delta\":\"full\",\"since\":\"abababababababababababababababab.42.k7m2qx\",\"observation\":{\"status\":\"absent\"}",
    }) |fields| {
        try std.testing.expectError(error.InvalidObservation, ObservationReply.parse(.{ .status = 200, .body = prefix ++ fields ++ "}" }, "k", token));
    }
}

pub fn decodeSkillSuggestions(gpa: std.mem.Allocator, bytes: []const u8) !@import("skill_suggestions.zig").Page {
    const suggestion = @import("skill_suggestions.zig");
    const Text = @import("json_scalar.zig").Text;
    const Entry = struct { name: Text, description: Text };
    const Entries = struct {
        values: []const Entry,
        pub fn jsonParse(a: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
            if (try source.next() != .array_begin) return error.UnexpectedToken;
            var values: std.ArrayList(Entry) = .empty;
            while (try source.peekNextTokenType() != .array_end) {
                if (values.items.len == suggestion.capacity) return error.LengthMismatch;
                const entry = try std.json.innerParse(Entry, a, source, options);
                if (entry.name.slice.len == 0 or entry.name.slice.len > 64 or entry.description.slice.len == 0 or entry.description.slice.len > 4096) return error.LengthMismatch;
                if (!std.unicode.utf8ValidateSlice(entry.name.slice) or !std.unicode.utf8ValidateSlice(entry.description.slice)) return error.InvalidCharacter;
                if (values.items.len != 0 and std.mem.order(u8, values.items[values.items.len - 1].name.slice, entry.name.slice) != .lt) return error.InvalidCharacter;
                try values.append(a, entry);
            }
            _ = try source.next();
            return .{ .values = values.items };
        }
    };
    const Wire = struct { version: JsonString(8), type: JsonString(32), revision: JsonString(20), total: JsonString(20), entries: Entries };
    if (bytes.len > protocol.skill_suggestions_reply.max_bytes) return error.InvalidResponse;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const wire = std.json.parseFromSliceLeaky(Wire, arena.allocator(), bytes, .{ .max_value_len = 4096 }) catch return error.InvalidResponse;
    if (!wire.version.eql(protocol.wire_version) or !wire.type.eql("skill_suggestions")) return error.InvalidResponse;
    const revision = std.fmt.parseInt(u64, wire.revision.slice(), 10) catch return error.InvalidResponse;
    const total = std.fmt.parseInt(usize, wire.total.slice(), 10) catch return error.InvalidResponse;
    if (total > 4096 or wire.entries.values.len != @min(total, suggestion.capacity)) return error.InvalidResponse;
    const entries = try gpa.alloc(suggestion.Entry, wire.entries.values.len);
    var initialized: usize = 0;
    errdefer {
        for (entries[0..initialized]) |entry| {
            gpa.free(entry.name);
            gpa.free(entry.description);
        }
        gpa.free(entries);
    }
    for (wire.entries.values, 0..) |entry, index| {
        const name = try gpa.dupe(u8, entry.name.slice);
        errdefer gpa.free(name);
        const description = try gpa.dupe(u8, entry.description.slice);
        entries[index] = .{ .name = name, .description = description };
        initialized += 1;
    }
    return .{ .entries = entries, .revision = revision, .total = total };
}

test "inline skills suggestion decoder owns bounded metadata and rejects path or count forgery" {
    const prefix = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"skill_suggestions\",\"revision\":\"7\",\"total\":\"1\",\"entries\":[";
    var page = try decodeSkillSuggestions(std.testing.allocator, prefix ++ "{\"name\":\"demo\",\"description\":\"A skill\"}]}");
    defer page.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("demo", page.entries[0].name);
    try std.testing.expectEqual(@as(u64, 7), page.revision);
    for ([_][]const u8{
        prefix ++ "{\"name\":\"demo\",\"description\":\"A skill\",\"path\":\"/not-public\"}]}",
        prefix ++ "]}",
        prefix ++ "{\"name\":3,\"description\":\"A skill\"}]}",
    }) |wire| try std.testing.expectError(error.InvalidResponse, decodeSkillSuggestions(std.testing.allocator, wire));
}

test "activity golden model call null evidence and zero usage roundtrip" {
    const facts = try std.testing.allocator.create(protocol.ActivityFacts);
    defer std.testing.allocator.destroy(facts);
    facts.* = .{ .end = 4, .count = 1, .work = .{ .revision = 1, .workspace = .{ .len = 0 }, .work = .{ .state = .{ .idle = .{ .since = 1 } } } } };
    try facts.work.workspace.set("/w");
    facts.items[0] = .{ .position = 4, .at = 7, .value = .{ .model_call = .{
        .model = .{ .len = 0 },
        .served_model = null,
        .input_tokens = null,
        .output_tokens = null,
        .cached_tokens = null,
        .latency_ms = 0,
        .first_event_ms = null,
        .status = .{ .len = 0 },
        .attempts = 2,
    } } };
    try facts.items[0].value.model_call.model.set("requested");
    try facts.items[0].value.model_call.status.set("provider_connection_closed");
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try @import("host_reply.zig").renderActivityPage(.{ .writer = &out.writer }, facts);
    const expected = "{\"model\":\"requested\",\"served_model\":null,\"input_tokens\":null,\"output_tokens\":null,\"cached_tokens\":null,\"latency_ms\":\"0\",\"first_event_ms\":null,\"status\":\"provider_connection_closed\",\"attempts\":\"2\"}";
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.written(), .{});
    defer parsed.deinit();
    const value = parsed.value.object.get("items").?.array.items[0].object.get("value").?.object.get("model_call").?;
    var row: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer row.deinit();
    try std.json.Stringify.value(value, .{}, &row.writer);
    try std.testing.expectEqualStrings(expected, row.written());
    const native = try std.testing.allocator.create(ActivityPage);
    defer std.testing.allocator.destroy(native);
    native.* = try ActivityPage.parse(out.written(), .{});
    try std.testing.expectEqualStrings(facts.items[0].value.model_call.model.slice(), native.facts.items[0].value.model_call.model.slice());
    try std.testing.expectEqualStrings(facts.items[0].value.model_call.status.slice(), native.facts.items[0].value.model_call.status.slice());
    inline for (.{ "served_model", "input_tokens", "output_tokens", "cached_tokens", "latency_ms", "first_event_ms", "attempts" }) |field_name| {
        try std.testing.expectEqual(@field(facts.items[0].value.model_call, field_name), @field(native.facts.items[0].value.model_call, field_name));
    }
    facts.items[0].value.model_call.input_tokens = 0;
    facts.items[0].value.model_call.output_tokens = 0;
    facts.items[0].value.model_call.cached_tokens = 0;
    out.clearRetainingCapacity();
    try @import("host_reply.zig").renderActivityPage(.{ .writer = &out.writer }, facts);
    native.* = try ActivityPage.parse(out.written(), .{});
    try std.testing.expectEqualStrings(facts.items[0].value.model_call.model.slice(), native.facts.items[0].value.model_call.model.slice());
    try std.testing.expectEqualStrings(facts.items[0].value.model_call.status.slice(), native.facts.items[0].value.model_call.status.slice());
    inline for (.{ "served_model", "input_tokens", "output_tokens", "cached_tokens", "latency_ms", "first_event_ms", "attempts" }) |field_name| {
        try std.testing.expectEqual(@field(facts.items[0].value.model_call, field_name), @field(native.facts.items[0].value.model_call, field_name));
    }
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"input_tokens\":\"0\",\"output_tokens\":\"0\",\"cached_tokens\":\"0\"") != null);
}

test "Session pin list ranks round trip as positive decimal strings" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "pin-rank", .{ .read = true });
    defer file.close(io);
    var input: [2048]u8 = undefined;
    const unpinned = try testingListPage(&input, &.{"k7m2qx"}, testing_list_facts ++ "null}");
    const pinned = try std.mem.replaceOwned(u8, std.testing.allocator, unpinned, "\"pin_order\":null", "\"pin_order\":\"9223372036854775807\"");
    defer std.testing.allocator.free(pinned);
    try file.writePositionalAll(io, pinned, 0);
    const decoded = try SessionListReply.decode(io, file, "/w", .{}, .{ .report = .{ .bytes = pinned.len } });
    try std.testing.expectEqual(@as(?u64, std.math.maxInt(i64)), decoded.page.rows[0].pin_order);
    var output: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    try decoded.page.writeJson(&writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\"pin_order\":\"9223372036854775807\"") != null);
}

test "derived observation payloads cover caller fields" {
    @setEvalBranchQuota(2_000_000);
    const JsonTypes = struct {
        pub fn Type(comptime T: type) type {
            if (T == protocol.WorkStateJson) return JsonWorkState;
            if (T == protocol.WorkAttentionJson) return JsonWorkAttention;
            if (T == protocol.WorkActionsJson) return JsonWorkActions;
            if (T == protocol.MessageRecoveryJson) return CommandObservation.JsonMessageRecovery;
            return T;
        }
    };
    const shapes = comptime command_spec.observationDecoderShapes(protocol).values;
    inline for (comptime std.meta.fieldNames(CommandObservation)) |name| {
        if (comptime !std.mem.eql(u8, name, "key")) {
            const owned = comptime blk: {
                for (shapes) |shape| {
                    const Value = @import("command_reply.zig").DecoderWithJson(shape, shapes, JsonTypes).Value;
                    if (@hasField(Value, "observation") and @hasField(@FieldType(Value, "observation"), name)) break :blk true;
                }
                break :blk false;
            };
            try std.testing.expect(owned);
        }
    }
}

test "CLI-12 list_page_validation" {
    try listValidationCase0();
    try listValidationCase1();
    try listValidationCase2();
}

test "WIR-4 a content value reads back only as text or as parts with one owner" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const identity: content_value.Reference = .{ .length = 7, .digest = @bitCast(@as([2][16]u8, @splat(.{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef }))) };
    const largest = std.math.maxInt(i64);
    for ([_]content_value.Value{
        .{ .text = identity },
        .{ .text = .{ .length = 0, .digest = identity.digest } },
        .{ .text = .{ .length = protocol.max_sqlite_content_bytes, .digest = identity.digest } },
        .{ .parts = .{ .identity = identity, .owner = .{ .message = 1 } } },
        .{ .parts = .{ .identity = identity, .owner = .{ .action = largest } } },
    }) |value| {
        var buffer: [protocol.ContentValueJson.max_json_bytes]u8 = undefined;
        var out = std.Io.Writer.fixed(&buffer);
        try (protocol.ContentValueJson{ .value = value }).writeJson(&out);
        const decoded = try std.json.parseFromSliceLeaky(JsonContentValue, arena.allocator(), out.buffered(), .{});
        try std.testing.expectEqualDeep(value, decoded.value);
        try std.testing.expectEqual(value == .text, if (decoded.text()) |_| true else |_| false);
    }
    const head = "{\"bytes\":\"7\",\"sha256\":\"" ++ digest ++ "\"";
    for ([_][]const u8{
        head ++ "}",
        "{\"type\":\"text\"," ++ head[1..] ++ ",\"display\":\"omitted\"}",
        "{\"type\":\"text\"," ++ head[1..] ++ ",\"owner\":{\"message\":\"1\"}}",
        "{\"type\":\"parts\"," ++ head[1..] ++ "}",
        "{\"type\":\"parts\"," ++ head[1..] ++ ",\"owner\":null}",
        "{\"type\":\"parts\"," ++ head[1..] ++ ",\"owner\":{}}",
        "{\"type\":\"parts\"," ++ head[1..] ++ ",\"owner\":{\"message\":\"1\",\"action\":\"2\"}}",
        "{\"type\":\"parts\"," ++ head[1..] ++ ",\"owner\":{\"message\":\"0\"}}",
        "{\"type\":\"parts\"," ++ head[1..] ++ ",\"owner\":{\"action\":\"9223372036854775808\"}}",
        "{\"type\":\"parts\"," ++ head[1..] ++ ",\"owner\":{\"turn\":\"1\"}}",
        "{\"type\":\"image\"," ++ head[1..] ++ "}",
        "{\"type\":\"text\",\"bytes\":\"07\",\"sha256\":\"" ++ digest ++ "\"}",
        "{\"type\":\"text\",\"bytes\":\"7\",\"sha256\":\"" ++ digest[0..63] ++ "F\"}",
        "{\"type\":\"text\",\"bytes\":\"7\",\"sha256\":\"" ++ digest[0..62] ++ "\"}",
        std.fmt.comptimePrint("{{\"type\":\"text\",\"bytes\":\"{d}\",\"sha256\":\"" ++ digest ++ "\"}}", .{protocol.max_sqlite_content_bytes + 1}),
    }) |wire| {
        if (std.json.parseFromSliceLeaky(JsonContentValue, arena.allocator(), wire, .{})) |_| {
            std.debug.print("accepted {s}\n", .{wire});
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

test "WIR-4 a public parts reply reads back as the Host writes it and refuses any other list" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "parts", .{ .read = true });
    defer file.close(io);
    const a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const b = "0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b";
    const c = "c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0";
    const wire = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"public_parts\",\"session\":\"k7m2qx\"," ++
        "\"value\":{\"type\":\"parts\",\"bytes\":\"120\",\"sha256\":\"" ++ a ++ "\",\"owner\":{\"action\":\"9\"}},\"parts\":[" ++
        "{\"ordinal\":\"0\",\"type\":\"text\",\"bytes\":\"0\",\"sha256\":\"" ++ b ++ "\"}," ++
        "{\"ordinal\":\"1\",\"type\":\"image\",\"mime\":\"image/png\",\"width\":\"1\",\"height\":\"4294967295\",\"name\":\"cat \\\"\\u96ea\\\".png\",\"bytes\":\"67\",\"sha256\":\"" ++ c ++ "\"}," ++
        "{\"ordinal\":\"2\",\"type\":\"image\",\"mime\":\"image/jpeg\",\"width\":\"3\",\"height\":\"2\",\"name\":null,\"bytes\":\"5\",\"sha256\":\"" ++ b ++ "\"}]}";
    var identity: content_value.Reference = .{ .length = 120, .digest = @splat(0xaa) };
    const expected: PublicPartsReply.Expected = .{ .session = "k7m2qx", .owner = .{ .action = 9 }, .identity = identity };
    try file.writePositionalAll(io, wire, 0);
    const reply = try PublicPartsReply.decode(io, file, .{ .report = .{ .bytes = wire.len } }, expected);
    try std.testing.expectEqual(@as(u32, 3), reply.list.count);
    try std.testing.expect(std.meta.eql(content_value.Owner{ .action = 9 }, reply.list.value.owner));
    const iterator = try std.testing.allocator.create(PartIterator);
    defer std.testing.allocator.destroy(iterator);
    // The iterator restarts from the file each time.
    for (0..2) |_| {
        try reply.list.iterator(iterator);
        const text = (try iterator.next()).?;
        try std.testing.expect(text.kind == .text and text.ordinal == 0 and text.reference.length == 0);
        try std.testing.expectEqualSlices(u8, &@as([32]u8, @splat(0x0b)), &text.reference.digest);
        const png = (try iterator.next()).?;
        try std.testing.expectEqual(@as(u64, 67), png.reference.length);
        try std.testing.expectEqual(@import("input_media.zig").Format.png, png.kind.image.media.format);
        try std.testing.expectEqual(@as(u32, 1), png.kind.image.media.width);
        try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), png.kind.image.media.height);
        try std.testing.expectEqualStrings("cat \"雪\".png", png.kind.image.name.?.slice());
        const jpeg = (try iterator.next()).?;
        try std.testing.expect(jpeg.ordinal == 2 and jpeg.kind.image.media.format == .jpeg and jpeg.kind.image.name == null);
        try std.testing.expectEqual(@as(?content_value.Part, null), try iterator.next());
    }
    // A Host refusal decodes as a read failure, not a list.
    const refusal = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"parts_unavailable\",\"code\":\"ContentIsText\"}";
    const failure = (try PublicPartsReply.decode(io, file, .{ .command = .{ .status = 409, .body = refusal } }, expected)).failure;
    try std.testing.expectEqualStrings("ContentIsText", failure.diagnostic.code.slice());

    const Mutation = struct { from: []const u8, to: []const u8 };
    const mutations = [_]Mutation{
        .{ .from = "\"session\":\"k7m2qx\"", .to = "\"session\":\"k7m2qy\"" },
        .{ .from = "{\"action\":\"9\"}", .to = "{\"message\":\"9\"}" },
        .{ .from = "{\"action\":\"9\"}", .to = "{\"action\":\"9\",\"message\":\"9\"}" },
        .{ .from = "\"bytes\":\"120\"", .to = "\"bytes\":\"121\"" },
        .{ .from = "\"type\":\"parts\"", .to = "\"type\":\"text\"" },
        .{ .from = "\"type\":\"public_parts\"", .to = "\"type\":\"public_part\"" },
        .{ .from = "\"version\":\"" ++ protocol.wire_version ++ "\"", .to = "\"version\":\"" ++ protocol.wire_version ++ "0\"" },
        .{ .from = "\"ordinal\":\"1\"", .to = "\"ordinal\":\"3\"" },
        .{ .from = "\"ordinal\":\"0\"", .to = "\"ordinal\":\"00\"" },
        .{ .from = "\"type\":\"text\",\"bytes\":\"0\"", .to = "\"type\":\"text\",\"mime\":\"image/png\",\"bytes\":\"0\"" },
        .{ .from = "\"type\":\"text\",\"bytes\":\"0\"", .to = "\"type\":\"audio\",\"bytes\":\"0\"" },
        .{ .from = "image/png", .to = "image/gif" },
        .{ .from = "\"width\":\"1\"", .to = "\"width\":\"0\"" },
        .{ .from = "\"height\":\"4294967295\"", .to = "\"height\":\"4294967296\"" },
        .{ .from = ",\"width\":\"3\"", .to = "" },
        .{ .from = "\"name\":null", .to = "\"name\":\"\"" },
        .{ .from = "\"name\":null,", .to = "\"name\":null,\"extra\":true," },
        .{ .from = "\"sha256\":\"" ++ b ++ "\"}]", .to = "\"sha256\":\"" ++ b[0..62] ++ "\"}]" },
        .{ .from = "\"sha256\":\"" ++ b ++ "\"}]", .to = "\"sha256\":\"" ++ b[0..62] ++ "AB\"}]" },
        .{ .from = ",\"parts\":[", .to = ",\"parts\":[],\"later\":[" },
        .{ .from = "\"parts\":[{\"ordinal\":\"0\"", .to = "\"parts\":[],\"x\":[{\"ordinal\":\"0\"" },
        .{ .from = "}]}", .to = "}]}}" },
    };
    for (mutations) |mutation| {
        const changed = try std.mem.replaceOwned(u8, std.testing.allocator, wire, mutation.from, mutation.to);
        defer std.testing.allocator.free(changed);
        try std.testing.expect(!std.mem.eql(u8, changed, wire));
        try file.writePositionalAll(io, changed, 0);
        if (PublicPartsReply.decode(io, file, .{ .report = .{ .bytes = changed.len } }, expected)) |_| {
            std.debug.print("accepted {s}\n", .{changed});
            return error.TestUnexpectedResult;
        } else |err| try std.testing.expectEqual(error.InvalidPartList, err);
    }
    // An empty list, a short byte count and trailing bytes past the count.
    const empty = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"public_parts\",\"session\":\"k7m2qx\",\"value\":{\"type\":\"parts\",\"bytes\":\"120\",\"sha256\":\"" ++ a ++ "\",\"owner\":{\"action\":\"9\"}},\"parts\":[]}";
    try file.writePositionalAll(io, empty, 0);
    try std.testing.expectError(error.InvalidPartList, PublicPartsReply.decode(io, file, .{ .report = .{ .bytes = empty.len } }, expected));
    try file.writePositionalAll(io, wire ++ "x", 0);
    try std.testing.expectError(error.InvalidPartList, PublicPartsReply.decode(io, file, .{ .report = .{ .bytes = wire.len - 1 } }, expected));
    try std.testing.expectError(error.InvalidPartList, PublicPartsReply.decode(io, file, .{ .report = .{ .bytes = wire.len + 1 } }, expected));
    // The requested identity binds the manifest.
    identity.length = 119;
    try file.writePositionalAll(io, wire, 0);
    try std.testing.expectError(error.InvalidPartList, PublicPartsReply.decode(io, file, .{ .report = .{ .bytes = wire.len } }, .{ .session = "k7m2qx", .owner = .{ .action = 9 }, .identity = identity }));
}

test "Archived window wire: a slim row reads back with its position, admission, content and line" {
    const digest: [32]u8 = @splat(0x5a);
    const identity: content_value.Reference = .{ .length = 7, .digest = digest };
    const cases = [_]struct { label: ?[]const u8, first: ?protocol.ArchivedFirstFields }{
        .{ .label = "Review", .first = .{ .position = 1, .admission = 2, .content = .{ .text = identity }, .line = "hello" } },
        .{ .label = null, .first = .{ .position = 9, .admission = 8, .content = .{ .parts = .{ .identity = identity, .owner = .{ .message = 8 } } }, .line = null } },
        .{ .label = null, .first = null },
    };
    for (cases) |case| {
        const row: protocol.ArchivedRow.Fields = .{ .reference = "k7m2qx", .archive_seq = 42, .stopped_at = 1700, .label = case.label, .first = case.first };
        var buffer: [protocol.ArchivedRow.Fields.max_json_bytes]u8 = undefined;
        var out = std.Io.Writer.fixed(&buffer);
        try row.writeJson(&out);
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const decoded = try std.json.parseFromSliceLeaky(ArchivedRowRead, arena.allocator(), out.buffered(), .{});
        try std.testing.expectEqualStrings("k7m2qx", decoded.reference.slice());
        try std.testing.expectEqual(@as(u64, 42), decoded.archive_seq);
        try std.testing.expectEqual(@as(u64, 1700), decoded.stopped_at);
        if (case.label) |label| try std.testing.expectEqualStrings(label, decoded.label.?.slice()) else try std.testing.expect(decoded.label == null);
        if (case.first) |first| {
            const read = decoded.first orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(first.position, read.position);
            try std.testing.expectEqual(first.admission, read.admission);
            try std.testing.expectEqualDeep(first.content, read.content);
            if (first.line) |line| try std.testing.expectEqualStrings(line, read.line.?.slice()) else try std.testing.expect(read.line == null);
        } else try std.testing.expect(decoded.first == null);
    }
}
