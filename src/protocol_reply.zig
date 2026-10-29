//! The Host's reply grammar: the typed facts each reply carries and the
//! decoders that accept or reject its bytes. Requests are in protocol.zig;
//! client.zig owns transport and request capture.
const std = @import("std");
const protocol = @import("protocol.zig");

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
        kind: enum { user, assistant, tool_result },
        content: CommandObservation.ContentReference,
        presentation: ?protocol.ToolPresentation = null,
        admitted_at: ?u64 = null, // Host wall-clock second; User items only.
        sender: ?protocol.Peer = null, // A User item's peer sender.
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
            content: struct { bytes: JsonString(20), sha256: JsonString(64), display: JsonString(16) },
            presentation: ?JsonToolPresentation = null,
            admitted_at: ?JsonString(20) = null,
            sender: ?JsonPeer = null, // User items only.
        };
        const Rows = struct {
            values: [protocol.public_conversation_page_items]Row = undefined,
            count: usize = 0,
            pub fn jsonParse(a: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
                if (try source.next() != .array_begin) return error.UnexpectedToken;
                var rows: @This() = .{};
                while (try source.peekNextTokenType() != .array_end) {
                    if (rows.count == rows.values.len) return error.LengthMismatch;
                    rows.values[rows.count] = try std.json.innerParse(Row, a, source, options);
                    rows.count += 1;
                }
                _ = try source.next();
                return rows;
            }
        };
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
        if (!wire.version.eql("1") or !wire.type.eql("conversation_page") or !wire.direction.eql("newest_first")) return error.InvalidConversationPage;
        var page: ConversationPage = .{ .end = try mutationId(wire.end, true), .count = wire.items.count, .more = wire.more };
        if (page.end > std.math.maxInt(i64) or (cursor.end != 0 and page.end != cursor.end) or (page.more and page.count != page.items.len)) return error.InvalidConversationPage;
        var position = cursor.before_position;
        var ordinal = cursor.before_ordinal;
        for (wire.items.values[0..page.count], page.items[0..page.count]) |row, *item| {
            item.* = .{ .position = try mutationId(row.position, false), .ordinal = try mutationId(row.ordinal, true), .kind = row.kind.value, .content = .{ .bytes = try mutationId(row.content.bytes, true), .digest = undefined } };
            item.presentation = if (row.presentation) |p| p.value else null;
            item.admitted_at = if (row.admitted_at) |second| try mutationId(second, false) else null;
            item.sender = if (row.sender) |sender| sender.peer() catch return error.InvalidConversationPage else null;
            if ((item.kind == .tool_result) != (item.presentation != null) or (item.kind == .user) != (item.admitted_at != null) or
                (item.kind != .user and item.sender != null) or
                (item.admitted_at orelse 0) > std.math.maxInt(i64)) return error.InvalidConversationPage;
            if (item.presentation) |p| if (p.publication_position != item.position) return error.InvalidConversationPage;
            if (item.position > page.end or item.ordinal > std.math.maxInt(i64) or item.content.bytes > protocol.max_sqlite_content_bytes or
                ((item.kind == .tool_result) != (item.ordinal != 0)) or !row.content.display.eql("omitted") or row.content.sha256.slice().len != 64 or
                (position != 0 and (item.position > position or (item.position == position and item.ordinal >= ordinal)))) return error.InvalidConversationPage;
            _ = std.fmt.hexToBytes(&item.content.digest, row.content.sha256.slice()) catch return error.InvalidConversationPage;
            position = item.position;
            ordinal = item.ordinal;
        }
        if (page.more) {
            if (wire.before_position == null or wire.before_ordinal == null or
                try mutationId(wire.before_position.?, false) != position or try mutationId(wire.before_ordinal.?, true) != ordinal) return error.InvalidConversationPage;
        } else if (wire.before_position != null or wire.before_ordinal != null) return error.InvalidConversationPage;
        return page;
    }
};

pub const ProposalCursor = struct { end: ?u64 = null, after: u64 = 0 };
pub const ProposalPageReply = union(enum) { page: ProposalPage, failure: ReadFailure };
pub const ProposalPage = struct {
    end: u64,
    items: [protocol.proposal_page_items]protocol.ProposalMetadata = undefined,
    count: usize = 0,
    more: bool,

    pub fn continuation(self: *const ProposalPage) ?ProposalCursor {
        return if (self.more) .{ .end = self.end, .after = self.items[self.count - 1].position } else null;
    }

    pub fn parse(bytes: []const u8, cursor: ProposalCursor) !ProposalPage {
        if (bytes.len > protocol.max_proposal_page_response_bytes) return error.InvalidProposalPage;
        try (protocol.ProposalPage{ .end = cursor.end, .after = cursor.after }).validate();
        const Ref = struct { bytes: JsonString(20), sha256: JsonString(64) };
        const Item = struct {
            position: JsonString(20),
            operation: JsonString(20),
            turn: JsonString(20),
            call_ordinal: JsonString(20),
            action: ?JsonString(20),
            rejection: ?JsonEnum(protocol.ProposalRejection),
            fields: struct { item_id: Ref, name: Ref, call_id: Ref, arguments: Ref },
        };
        const Items = struct {
            values: [protocol.proposal_page_items]Item = undefined,
            count: usize = 0,
            pub fn jsonParse(a: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
                if (try source.next() != .array_begin) return error.UnexpectedToken;
                var result: @This() = .{};
                while (try source.peekNextTokenType() != .array_end) {
                    if (result.count == result.values.len) return error.LengthMismatch;
                    result.values[result.count] = try std.json.innerParse(Item, a, source, options);
                    result.count += 1;
                }
                _ = try source.next();
                return result;
            }
        };
        const Wire = struct { version: JsonString(8), type: JsonString(32), end: JsonString(20), items: Items, more: bool };
        // Fixed scanner storage; no payload tokens or history-sized allocation.
        var storage: [2 * protocol.max_proposal_page_response_bytes]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&storage);
        const wire = std.json.parseFromSliceLeaky(Wire, fixed.allocator(), bytes, .{}) catch return error.InvalidProposalPage;
        if (!wire.version.eql("1") or !wire.type.eql("proposal_page")) return error.InvalidProposalPage;
        var page: ProposalPage = .{ .end = try mutationId(wire.end, true), .count = wire.items.count, .more = wire.more };
        if (page.end > std.math.maxInt(i64) or (cursor.end != null and cursor.end.? != page.end) or
            page.end < cursor.after or (page.more and page.count != page.items.len)) return error.InvalidProposalPage;
        var previous = cursor.after;
        for (wire.items.values[0..wire.items.count], page.items[0..page.count]) |item, *result| {
            result.* = .{
                .position = try mutationId(item.position, false),
                .operation = try mutationId(item.operation, false),
                .turn = try mutationId(item.turn, false),
                .call_ordinal = try mutationId(item.call_ordinal, true),
                .action = if (item.action) |action| try mutationId(action, false) else null,
                .rejection = if (item.rejection) |code| code.value else null,
                .fields = undefined,
            };
            if (result.position <= previous or result.position > page.end or result.operation > std.math.maxInt(i64) or
                result.turn > std.math.maxInt(i64) or result.call_ordinal > std.math.maxInt(i64) or
                (result.action != null) == (result.rejection != null) or
                (result.action != null and result.action.? > std.math.maxInt(i64))) return error.InvalidProposalPage;
            inline for (comptime std.meta.tags(protocol.ProposalField), 0..) |field, index| {
                const reference = @field(item.fields, @tagName(field));
                if (reference.sha256.slice().len != 64) return error.InvalidProposalPage;
                result.fields[index].length = try mutationId(reference.bytes, true);
                if (result.fields[index].length > std.math.maxInt(i64)) return error.InvalidProposalPage;
                _ = std.fmt.hexToBytes(&result.fields[index].digest, reference.sha256.slice()) catch return error.InvalidProposalPage;
            }
            previous = result.position;
        }
        if (page.more and previous >= page.end) return error.InvalidProposalPage;
        return page;
    }
};

pub const ActivityCursor = struct {
    end: ?u64 = null,
    position: u64 = 0,
    ordinal: ?u64 = null,
    direction: @FieldType(protocol.ActivityPage, "direction") = .forward,
    pub fn validate(self: ActivityCursor) !void {
        try (protocol.ActivityPage{ .end = self.end, .position = self.position, .ordinal = self.ordinal, .direction = self.direction }).validate();
    }
};
pub const ActivityPageReply = union(enum) { page: ActivityPage, failure: ReadFailure };
pub const ActivityPage = struct {
    facts: protocol.ActivityFacts,

    pub fn continuation(self: *const ActivityPage) ?ActivityCursor {
        const facts = &self.facts;
        if (!facts.more) return null;
        const last = facts.items[facts.count - 1];
        return .{ .end = facts.end, .position = last.position, .ordinal = last.ordinal, .direction = facts.direction };
    }

    pub fn parse(bytes: []const u8, cursor: ActivityCursor) !ActivityPage {
        try cursor.validate();
        if (bytes.len > protocol.max_activity_page_response_bytes) return error.InvalidActivityPage;
        const Ref = struct { bytes: JsonString(20), sha256: JsonString(64) };
        const Fact = protocol.ActivityItem;
        const Message = struct { admission: JsonString(20), key: JsonString(protocol.max_key_bytes), turn: ?JsonString(20), state: JsonEnum(@FieldType(Fact.Message, "state")), admitted_at: JsonString(20), sender: ?JsonPeer, content: Ref };
        const Sent = struct { admission: JsonString(20), admitted_at: JsonString(20), target: JsonPeer, content: Ref };
        const SendFailed = struct { key: JsonString(protocol.max_key_bytes), target: JsonPeer, code: JsonString(protocol.max_code_bytes) };
        const Call = struct { operation: JsonString(20), turn: JsonString(20), call_ordinal: JsonString(20), action: ?JsonString(20), rejection: ?JsonEnum(protocol.ProposalRejection), fields: [4]Ref };
        const Outcome = struct { turn: JsonString(20), operation: JsonString(20), code: JsonString(protocol.max_code_bytes), content: ?Ref };
        const Stop = struct { key: JsonString(protocol.max_key_bytes), turn: ?JsonString(20), cutoff: JsonString(20), completion: JsonEnum(@FieldType(Fact.Stop, "completion")) };
        const Item = struct { position: JsonString(20), ordinal: JsonString(20), value: union(enum) { admission: Message, user: Message, assistant: Ref, call: Call, tool_result: struct { content: Ref, presentation: JsonToolPresentation }, outcome: Outcome, stop: Stop, sent: Sent, send_failed: SendFailed } };
        const Items = struct {
            values: [16]Item = undefined,
            count: usize = 0,
            pub fn jsonParse(a: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
                if (try source.next() != .array_begin) return error.UnexpectedToken;
                var result: @This() = .{};
                while (try source.peekNextTokenType() != .array_end) {
                    if (result.count == result.values.len) return error.LengthMismatch;
                    result.values[result.count] = try std.json.innerParse(Item, a, source, options);
                    result.count += 1;
                }
                _ = try source.next();
                return result;
            }
        };
        const CallEntry = struct { operation: JsonString(20), ordinal: JsonString(20), presentation: JsonToolPresentation };
        const Calls = struct {
            values: [3]CallEntry = undefined,
            count: usize = 0,
            pub fn jsonParse(a: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
                if (try source.next() != .array_begin) return error.UnexpectedToken;
                var result: @This() = .{};
                while (try source.peekNextTokenType() != .array_end) {
                    if (result.count == result.values.len) return error.LengthMismatch;
                    result.values[result.count] = try std.json.innerParse(CallEntry, a, source, options);
                    result.count += 1;
                }
                _ = try source.next();
                return result;
            }
        };
        const Work = struct { status: JsonEnum(protocol.PageWork.Status), turn: ?JsonString(20), operation: ?JsonString(20), first_action: ?JsonString(20), revision: JsonString(20), workspace: JsonString(protocol.max_workspace_bytes) };
        const Wire = struct { version: JsonString(8), type: JsonString(32), end: JsonString(20), direction: JsonEnum(@FieldType(ActivityCursor, "direction")), items: Items, more: bool, call_activity: struct { total: JsonString(20), entries: Calls }, work: Work };
        var storage: [2 * protocol.max_activity_page_response_bytes]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&storage);
        const wire = std.json.parseFromSliceLeaky(Wire, fixed.allocator(), bytes, .{}) catch return error.InvalidActivityPage;
        var page: ActivityPage = .{ .facts = .{ .end = try id(wire.end, true), .direction = wire.direction.value, .more = wire.more, .count = wire.items.count } };
        if (!wire.version.eql("1") or !wire.type.eql("activity_page") or page.facts.direction != cursor.direction or
            (cursor.end != null and cursor.end.? != page.facts.end) or cursor.position > page.facts.end or
            (wire.more and wire.items.count != 16)) return error.InvalidActivityPage;
        var position = cursor.position;
        var ordinal = cursor.ordinal;
        for (wire.items.values[0..wire.items.count], page.facts.items[0..wire.items.count]) |item, *fact| {
            fact.* = .{ .position = try id(item.position, false), .ordinal = try id(item.ordinal, true), .value = undefined };
            const after = fact.position > position or (ordinal != null and fact.position == position and fact.ordinal > ordinal.?);
            const before = fact.position < position or (ordinal != null and fact.position == position and fact.ordinal < ordinal.?);
            if (fact.position > page.facts.end or (position != 0 and !(if (cursor.direction == .forward) after else before)) or
                ((item.value == .tool_result) != (fact.ordinal != 0))) return error.InvalidActivityPage;
            switch (item.value) {
                .admission, .user => |message| {
                    const value: Fact.Message = .{ .admission = try id(message.admission, false), .key = message.key.value, .turn = if (message.turn) |turn| try id(turn, false) else null, .state = message.state.value, .content = try content(message.content), .admitted_at = try id(message.admitted_at, false), .sender = if (message.sender) |sender| try sender.peer() else null };
                    if ((value.state == .applied) != (value.turn != null) or (item.value == .user and value.state != .applied)) return error.InvalidActivityPage;
                    fact.value = if (item.value == .user) .{ .user = value } else .{ .admission = value };
                },
                .sent => |sent| fact.value = .{ .sent = .{ .admission = try id(sent.admission, false), .admitted_at = try id(sent.admitted_at, false), .target = try sent.target.peer(), .content = try content(sent.content) } },
                .send_failed => |failed| {
                    if (failed.code.slice().len == 0) return error.InvalidActivityPage;
                    fact.value = .{ .send_failed = .{ .key = failed.key.value, .target = try failed.target.peer(), .code = failed.code.value } };
                },
                .assistant => |reference| fact.value = .{ .assistant = try content(reference) },
                .tool_result => |result| {
                    if (result.presentation.value.publication_position != fact.position) return error.InvalidActivityPage;
                    fact.value = .{ .tool_result = .{ .content = try content(result.content), .presentation = result.presentation.value } };
                },
                .call => |call| {
                    var value: Fact.Call = .{ .position = fact.position, .operation = try id(call.operation, false), .turn = try id(call.turn, false), .call_ordinal = try id(call.call_ordinal, true), .action = if (call.action) |action| try id(action, false) else null, .rejection = if (call.rejection) |code| code.value else null, .fields = undefined };
                    if ((value.action != null) == (value.rejection != null)) return error.InvalidActivityPage;
                    for (call.fields, &value.fields) |reference, *field| {
                        const decoded = try content(reference);
                        field.* = .{ .length = decoded.length, .digest = decoded.digest };
                    }
                    fact.value = .{ .call = value };
                },
                .outcome => |outcome| {
                    if (outcome.code.slice().len == 0 or (outcome.code.eql("completed") != (outcome.content != null))) return error.InvalidActivityPage;
                    fact.value = .{ .outcome = .{ .turn = try id(outcome.turn, false), .operation = try id(outcome.operation, false), .code = outcome.code.value, .content = if (outcome.content) |reference| try content(reference) else null } };
                },
                .stop => |stop| {
                    if (stop.turn == null and stop.completion.value == .pending) return error.InvalidActivityPage;
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
        const work = &page.facts.work;
        work.status = wire.work.status.value;
        inline for (.{ &work.turn, &work.operation, &work.first_action }, .{ wire.work.turn, wire.work.operation, wire.work.first_action }) |fact, value| {
            fact.* = if (value) |text| try id(text, false) else null;
        }
        // An operation belongs to its Turn; an Action to the active one.
        if ((work.turn == null) != (work.operation == null) or (work.first_action != null and work.turn == null)) return error.InvalidActivityPage;
        work.revision = try id(wire.work.revision, false);
        // The permission prompt shows this Workspace, so it keeps Current's rule.
        if (!std.fs.path.isAbsolute(wire.work.workspace.slice())) return error.InvalidActivityPage;
        work.workspace.set(wire.work.workspace.slice()) catch return error.InvalidActivityPage;
        return page;
    }

    fn id(value: anytype, zero: bool) !u64 {
        const result = try mutationId(value, zero);
        if (result > std.math.maxInt(i64)) return error.InvalidActivityPage;
        return result;
    }
    fn content(value: anytype) !protocol.ActivityItem.Content {
        const reference = try CommandObservation.decodeReference(value);
        if (reference.bytes > protocol.max_sqlite_content_bytes) return error.InvalidActivityPage;
        return .{ .length = reference.bytes, .digest = reference.digest };
    }
};

pub const HostStatus = union(enum) {
    ready: struct {
        store: protocol.Bounded(protocol.max_store_bytes),
        instance: protocol.InstanceId,
        active_capacity: usize,
        intake_capacity: usize = 100,
        descriptor_limit: ?usize = null,
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

pub fn parseHostInfo(body: []const u8, store: []const u8) !HostStatus {
    if (body.len > protocol.max_host_info_response_bytes) return error.InvalidHostInfo;
    var parse_storage: [protocol.max_host_info_response_bytes * 2]u8 = undefined;
    var arena = std.heap.FixedBufferAllocator.init(&parse_storage);
    const info = try std.json.parseFromSliceLeaky(protocol.HostInfo, arena.allocator(), body, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_if_needed,
    });
    if (!std.mem.eql(u8, info.version, protocol.wire_version) or
        !std.mem.eql(u8, info.type, "host_info") or
        !std.mem.eql(u8, info.store, store))
        return error.InvalidHostInfo;
    const finite_limit: ?[]const u8 = if (std.mem.eql(u8, info.descriptor_limit, "unlimited")) null else info.descriptor_limit;
    for ([_]?[]const u8{ info.active_capacity, info.intake_capacity, finite_limit }) |field| {
        const text = field orelse continue;
        if (text.len == 0 or text.len > 20 or (text.len > 1 and text[0] == '0')) return error.InvalidHostInfo;
        for (text) |digit| if (!std.ascii.isDigit(digit)) return error.InvalidHostInfo;
    }
    const instance = protocol.parseInstanceId(info.instance) catch return error.InvalidHostInfo;
    const capacity = std.fmt.parseInt(usize, info.active_capacity, 10) catch return error.InvalidHostInfo;
    const intake_capacity = std.fmt.parseInt(usize, info.intake_capacity, 10) catch return error.InvalidHostInfo;
    if (intake_capacity < 10 or intake_capacity > 100) return error.InvalidHostInfo;
    const descriptor_limit = if (finite_limit) |text| std.fmt.parseInt(usize, text, 10) catch return error.InvalidHostInfo else null;
    var identity: protocol.Bounded(protocol.max_store_bytes) = .{};
    try identity.set(info.store);
    return .{ .ready = .{
        .store = identity,
        .instance = instance,
        .active_capacity = capacity,
        .intake_capacity = intake_capacity,
        .descriptor_limit = descriptor_limit,
        .capabilities = info.capabilities,
    } };
}

test "Host information is bounded and rejects ambiguous identities and capacity" {
    const golden = "{\"version\":\"1\",\"type\":\"host_info\",\"store\":\"/one\",\"instance\":\"000102030405060708090a0b0c0d0e0f\",\"active_capacity\":\"17\",\"capabilities\":{\"bash\":true,\"model\":false,\"managed_authentication\":false}}";
    const result = try parseHostInfo(golden, "/one");
    try std.testing.expect(result.ready.store.eql("/one"));
    try std.testing.expectEqual(@as(usize, 17), result.ready.active_capacity);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 }, &result.ready.instance);
    try std.testing.expect(result.ready.capabilities.bash);
    try std.testing.expect(!result.ready.capabilities.model);
    try std.testing.expectError(error.InvalidHostInfo, parseHostInfo(golden, "/other"));
    try std.testing.expectError(error.InvalidHostInfo, parseHostInfo(
        "{\"version\":\"1\",\"type\":\"host_info\",\"store\":\"/one\",\"instance\":\"000102030405060708090a0b0c0d0e0F\",\"active_capacity\":\"17\",\"capabilities\":{\"bash\":true,\"model\":false,\"managed_authentication\":false}}",
        "/one",
    ));
    try std.testing.expectError(error.InvalidHostInfo, parseHostInfo(
        "{\"version\":\"1\",\"type\":\"host_info\",\"store\":\"/one\",\"instance\":\"000102030405060708090a0b0c0d0e0f\",\"active_capacity\":\"\",\"capabilities\":{\"bash\":true,\"model\":false,\"managed_authentication\":false}}",
        "/one",
    ));
    try std.testing.expectError(error.InvalidHostInfo, parseHostInfo(
        "{\"version\":\"1\",\"type\":\"host_info\",\"store\":\"/one\",\"instance\":\"000102030405060708090a0b0c0d0e0f\",\"active_capacity\":\"01\",\"capabilities\":{\"bash\":true,\"model\":false,\"managed_authentication\":false}}",
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

test "Host unavailable replies require a known complete error" {
    for ([_][]const u8{
        "{\"version\":\"1\",\"type\":\"busy\",\"code\":\"connection_capacity_exhausted\"}",
        "{\"version\":\"1\",\"type\":\"busy\",\"code\":\"classification_capacity_exhausted\"}",
        "{\"version\":\"1\",\"type\":\"busy\",\"code\":\"ordinary_capacity_exhausted\"}",
        "{\"version\":\"1\",\"type\":\"busy\",\"code\":\"discovery_capacity_exhausted\"}",
        "{\"version\":\"1\",\"type\":\"host_unavailable\",\"code\":\"dispatch_fenced\"}",
    }) |body| try std.testing.expect(validHostUnavailable(body));
    for ([_][]const u8{
        "{}",
        "{\"version\":\"2\",\"type\":\"busy\",\"code\":\"ordinary_capacity_exhausted\"}",
        "{\"version\":\"1\",\"type\":\"busy\",\"code\":\"dispatch_fenced\"}",
        "{\"version\":\"1\",\"type\":\"host_unavailable\",\"code\":\"unknown\"}",
        "{\"version\":\"1\",\"type\":\"busy\",\"code\":\"ordinary_capacity_exhausted\",\"code\":\"ordinary_capacity_exhausted\"}",
        "{\"version\":\"2\",\"type\":\"busy\",\"code\":\"discovery_capacity_exhausted\"}",
        "{\"version\":\"1\",\"type\":\"host_unavailable\",\"code\":\"discovery_capacity_exhausted\"}",
        "{\"version\":\"1\",\"type\":\"busy\",\"code\":\"discovery_capacity_exhausted_other\"}",
        "{\"version\":\"1\",\"type\":\"busy\",\"nested\":{\"code\":\"discovery_capacity_exhausted\"}}",
        "{\"version\":\"1\",\"type\":\"busy\",\"code\":\"discovery_capacity_exhausted\",\"code\":\"discovery_capacity_exhausted\"}",
        "{\"version\":\"1\",\"type\":\"busy\",\"code\":\"discovery_capacity_exhausted\"",
    }) |body| try std.testing.expect(!validHostUnavailable(body));
}

pub const CommandReply = struct {
    status: u16,
    // Borrowed from the caller's ReplyBuffer until that buffer is reused.
    body: []const u8,
};

pub const ResultReply = union(enum) {
    answer: struct { bytes: u64 },
    command: CommandReply,
};

pub const ObservationReply = union(enum) {
    observation: CommandObservation,
    failure: ReadFailure,
};

pub const ResultReadReply = union(enum) {
    answer: struct { bytes: u64 },
    failure: ReadFailure,
};

/// Owned diagnostic; an unsuccessful read says nothing about prior admission.
pub const ReadFailure = struct {
    status: u16,
    diagnostic: InvocationDiagnostic,

    pub fn writeDiagnostic(self: ReadFailure, out: *std.Io.Writer) !void {
        const Text = @import("TerminalText.zig");
        try out.print("HTTP {d}; type: ", .{self.status});
        var text: Text = .{ .mode = .line };
        try text.feed(out, self.diagnostic.type.slice());
        try text.finish(out);
        try out.writeAll("; code: ");
        try text.feed(out, self.diagnostic.code.slice());
        try text.finish(out);
    }

    pub fn err(self: ReadFailure) error{ CanonicalStoreFailure, HostInvocationFailed } {
        return if (self.diagnostic.code.eql("canonical_store_failure")) error.CanonicalStoreFailure else error.HostInvocationFailed;
    }
};

pub const ReportReply = union(enum) {
    report: struct { bytes: u64 },
    command: CommandReply,
};

pub const CurrentReply = union(enum) {
    unconfigured,
    current: Current,
    failure: ReadFailure,

    /// The caller retains immutable, offset-zero scratch through any traversal.
    pub fn decode(io: std.Io, file: std.Io.File, session: []const u8, reply: ReportReply) !CurrentReply {
        return switch (reply) {
            .command => |command| .{ .failure = try decodeReadFailure(command, false) },
            .report => |report| Current.read(io, file, report.bytes, session, NoAttention{}) catch return error.InvalidObservation,
        };
    }

    pub fn writeJson(self: *const CurrentReply, io: std.Io, file: std.Io.File, writer: *std.Io.Writer) !void {
        return switch (self.*) {
            .unconfigured => writer.writeAll("{\"version\":\"1\",\"type\":\"session_report\",\"profile\":\"current\",\"session\":null,\"pending_messages\":\"0\",\"execution\":{\"status\":\"unavailable\",\"reason\":\"session_not_found\"}}"),
            .current => |*current| current.writeJson(io, file, writer),
            .failure => |failure| failure.err(),
        };
    }
};

/// Fixed owned facts; the variable attention population stays in borrowed scratch.
pub const Current = struct {
    pub const Id = ReportNumber(false);
    pub const Count = ReportNumber(true);
    pub const Reference = struct {
        bytes: Count,
        sha256: JsonString(64),
        type: OmittableJson(JsonEnum(enum { text })) = .{},

        pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Reference {
            const Wire = struct { bytes: Count, sha256: JsonString(64), type: @FieldType(Reference, "type") = .{} };
            const wire = try std.json.innerParse(Wire, allocator, source, options);
            var digest: [32]u8 = undefined;
            if (wire.sha256.slice().len != 64) return error.InvalidObservation;
            _ = std.fmt.hexToBytes(&digest, wire.sha256.slice()) catch return error.InvalidObservation;
            return .{ .bytes = wire.bytes, .sha256 = wire.sha256, .type = wire.type };
        }

        pub fn jsonStringify(self: Reference, jw: anytype) !void {
            try writeObject(self, jw);
        }
    };
    pub const Settings = struct {
        reference: JsonString(protocol.max_session_bytes),
        workspace: JsonString(protocol.max_workspace_bytes),
        provider: JsonEnum(protocol.Provider),
        model: JsonString(protocol.max_model_bytes),
        revision: Id,
        tools: ReportTools,
        permission_mode: JsonEnum(enum { ask, bypass }),
        instructions: Reference,
        output_schema: ?Reference,
        compaction_trigger: ?PolicyNumber(false),
        output_reservation: PolicyNumber(true),
        compaction_trigger_override: ?PolicyNumber(false),
        output_reservation_override: ?PolicyNumber(true),
        reasoning_effort: ?JsonEnum(protocol.ReasoningEffort),
        reasoning_effort_override: ?JsonEnum(protocol.ReasoningEffort),

        pub fn jsonStringify(self: Settings, jw: anytype) !void {
            try writeObject(self, jw);
        }
    };
    pub const Work = struct {
        status: JsonEnum(enum { idle, runnable, in_flight, waiting_for_permission, completed, cancelled, failed }),
        turn: OmittableJson(Id) = .{},
        operation: OmittableJson(Id) = .{},
        latest_outcome: ?struct { code: JsonString(protocol.max_code_bytes), content: ?Reference },

        pub fn jsonStringify(self: Work, jw: anytype) !void {
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
            tool: JsonEnum(enum { bash }),
            permission_revision: Id,
            authorization: JsonEnum(enum { pending, bypass, allow_once }),
            call_id: Reference,
            arguments: Reference,
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
            item_id: Reference,
            name: Reference,
            call_id: Reference,
            arguments: Reference,
        },
        actionable: struct { action: Id, permission_revision: Id },
    };

    settings: Settings,
    pending_messages: u64,
    work: Work,
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

    /// Effectful traversal requires the same immutable offset-zero capture
    /// successfully decoded into these facts. Row slices expire at visit return.
    /// The caller owns the file through all synchronous callbacks and return.
    pub fn traverse(self: *const Current, io: std.Io, file: std.Io.File, sink: anytype) !void {
        _ = try read(io, file, self.bytes, self.settings.reference.slice(), sink);
    }

    pub fn writeJson(self: *const Current, io: std.Io, file: std.Io.File, writer: *std.Io.Writer) !void {
        try writer.writeAll("{\"version\":\"1\",\"type\":\"session_report\",\"profile\":\"current\",\"session\":");
        try std.json.Stringify.value(self.settings, .{}, writer);
        try writer.print(",\"pending_messages\":\"{d}\",\"work\":", .{self.pending_messages});
        try std.json.Stringify.value(self.work, .{}, writer);
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
            session: ?Settings,
            pending_messages: Count,
            work: OmittableJson(Work) = .{},
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
        // Nesting storage survives rows; leaf tokens are separately freed after
        // copying into owned fields, never underneath a live scanner stack.
        var scanner_storage: [protocol.content_window_bytes]u8 = undefined;
        var scanner_allocator = std.heap.FixedBufferAllocator.init(&scanner_storage);
        var token_storage: [2 * protocol.max_workspace_bytes]u8 = undefined;
        var token_allocator = std.heap.FixedBufferAllocator.init(&token_storage);
        var reader = std.json.Reader.init(scanner_allocator.allocator(), &body.interface);
        defer reader.deinit();
        var source: CurrentSource(@TypeOf(sink)) = .{ .reader = &reader, .sink = sink };
        const wire = try std.json.parseFromTokenSourceLeaky(Wire, token_allocator.allocator(), &source, .{ .ignore_unknown_fields = true });
        if (body.remaining != .nothing or !wire.version.eql("1")) return error.InvalidObservation;
        const execution = wire.execution;
        const settings = wire.session orelse {
            if (wire.pending_messages.value != 0 or execution.status.value != .unavailable or execution.reason.value == null or
                execution.dispatch_fenced.value != null or execution.custody_occupied.value != null or execution.scratch_used_bytes.value != null or execution.unavailable.value != null or
                wire.work.value != null or wire.selected_message.value != null or wire.recent_messages.value != null or wire.actions.value != null or
                wire.rejected_calls.value != null or wire.actionable_permissions.value != null) return error.InvalidObservation;
            return .unconfigured;
        };
        if (!protocol.validSessionId(settings.reference.slice()) or !settings.reference.eql(session) or !std.fs.path.isAbsolute(settings.workspace.slice()) or settings.model.slice().len == 0 or
            settings.instructions.type.value != null or (if (settings.output_schema) |schema| schema.type.value != null else false) or
            execution.status.value != .partial or execution.reason.value != null or execution.dispatch_fenced.value == null or
            execution.custody_occupied.value == null or execution.scratch_used_bytes.value == null or execution.unavailable.value == null) return error.InvalidObservation;
        const work = wire.work.value orelse return error.InvalidObservation;
        if ((work.turn.value == null) != (work.operation.value == null) or (work.latest_outcome != null and work.turn.value == null)) return error.InvalidObservation;
        if (work.latest_outcome) |outcome| {
            if (outcome.code.slice().len == 0 or (if (outcome.content) |content| content.type.value != null else false)) return error.InvalidObservation;
        }
        const recent = wire.recent_messages.value orelse return error.InvalidObservation;
        const actions = wire.actions.value orelse return error.InvalidObservation;
        const rejected = wire.rejected_calls.value orelse return error.InvalidObservation;
        const actionable = wire.actionable_permissions.value orelse return error.InvalidObservation;
        if (rejected.count.value != rejected.items.count or actions.count.value < actions.unresolved.count + actions.resolved.count or actionable.count > actions.unresolved.count) return error.InvalidObservation;
        return .{ .current = .{
            .settings = settings,
            .pending_messages = wire.pending_messages.value,
            .work = work,
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

fn PolicyNumber(comptime allow_zero: bool) type {
    return struct {
        text: JsonString(20),
        pub fn slice(self: *const @This()) []const u8 {
            return self.text.slice();
        }
        pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
            const text = try JsonString(20).jsonParse(allocator, source, options);
            const value = try mutationId(text, allow_zero);
            if (value > std.math.maxInt(i64)) return error.InvalidObservation;
            return .{ .text = text };
        }
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.write(self.text);
        }
    };
}

fn ReportNumber(comptime allow_zero: bool) type {
    return struct {
        value: u64,
        pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
            const text = try JsonString(20).jsonParse(allocator, source, options);
            const value = try mutationId(text, allow_zero);
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
    bash: bool = false,
    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !ReportTools {
        if (try source.next() != .array_begin) return error.UnexpectedToken;
        var result: ReportTools = .{};
        while (try source.peekNextTokenType() != .array_end) {
            const tool = try std.json.innerParse(JsonEnum(enum { bash }), allocator, source, options);
            switch (tool.value) {
                .bash => {
                    if (result.bash) return error.DuplicateField;
                    result.bash = true;
                },
            }
        }
        _ = try source.next();
        return result;
    }

    pub fn jsonStringify(self: ReportTools, jw: anytype) !void {
        try jw.beginArray();
        if (self.bash) try jw.write("bash");
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
                    if (@FieldType(@TypeOf(row), name) == Current.Reference and @field(row, name).type.value == null) return error.InvalidObservation;
                }
                if ((tag == .resolved or tag == .rejected) and row.code.slice().len == 0) return error.InvalidObservation;
                if (tag == .unresolved) {
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

    pub fn validate(self: SessionListCursor) !void {
        if (self.after > std.math.maxInt(i64) or self.ceiling > std.math.maxInt(i64) or
            (self.after == 0 and self.ceiling != 0) or (self.after != 0 and self.after > self.ceiling)) return error.InvalidCursor;
    }
};

pub const SessionListReply = union(enum) {
    page: SessionListPage,
    failure: ReadFailure,

    /// Borrowed scratch/reply bytes are consumed here; returned facts own their
    /// strings. The report body must start at file offset zero; bytes beyond its
    /// advertised length are not part of this exchange. The file is not changed.
    pub fn decode(io: std.Io, file: std.Io.File, workspace: ?[]const u8, cursor: SessionListCursor, reply: ReportReply) !SessionListReply {
        return switch (reply) {
            .report => |report| .{ .page = try SessionListPage.read(io, file, report.bytes, workspace, cursor) },
            .command => |command| .{ .failure = try decodeReadFailure(command, false) },
        };
    }
};

/// Owned configured-Session summaries; string slices borrow this value, not
/// report scratch. Store remains the authority for ordering and configuration.
pub const SessionListPage = struct {
    pub const Row = struct {
        reference: protocol.Bounded(protocol.max_session_bytes),
        workspace: protocol.Bounded(protocol.max_workspace_bytes),
        provider: protocol.Provider,
        model: protocol.Bounded(protocol.max_model_bytes),
        tools: ReportTools,
        permission_mode: enum { ask, bypass },

        pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Row {
            const Wire = struct {
                reference: JsonString(protocol.max_session_bytes),
                workspace: JsonString(protocol.max_workspace_bytes),
                provider: JsonEnum(protocol.Provider),
                model: JsonString(protocol.max_model_bytes),
                tools: ReportTools,
                permission_mode: JsonEnum(@FieldType(Row, "permission_mode")),
            };
            const wire = try std.json.innerParse(Wire, allocator, source, options);
            if (!protocol.validSessionId(wire.reference.slice()) or wire.workspace.value.len == 0 or wire.model.value.len == 0) return error.InvalidCharacter;
            return .{
                .reference = wire.reference.value,
                .workspace = wire.workspace.value,
                .provider = wire.provider.value,
                .model = wire.model.value,
                .tools = wire.tools,
                .permission_mode = wire.permission_mode.value,
            };
        }
    };

    rows: [protocol.session_list_page_size]Row = undefined,
    count: usize = 0,
    next: ?SessionListCursor = null,

    /// Reads exactly [0, bytes) from caller-owned scratch, not its physical EOF.
    /// No file/resource escapes; malformed input never yields a partial page.
    pub fn read(io: std.Io, file: std.Io.File, bytes: u64, workspace: ?[]const u8, cursor: SessionListCursor) !SessionListPage {
        if (bytes == 0) return error.InvalidSessionPage;
        cursor.validate() catch return error.InvalidSessionPage;
        const Rows = struct {
            rows: [protocol.session_list_page_size]Row = undefined,
            count: usize = 0,

            pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
                if (try source.next() != .array_begin) return error.UnexpectedToken;
                var result: @This() = .{};
                while (try source.peekNextTokenType() != .array_end) {
                    if (result.count == result.rows.len) return error.LengthMismatch;
                    result.rows[result.count] = try std.json.innerParse(Row, allocator, source, options);
                    result.count += 1;
                }
                _ = try source.next();
                return result;
            }
        };
        const Wire = struct {
            version: JsonString(8),
            type: JsonString(32),
            sessions: Rows,
            next: ?struct { after: JsonString(20), ceiling: JsonString(20) },
        };
        var input_buffer: [protocol.content_window_bytes]u8 = undefined;
        var file_reader = file.reader(io, &.{});
        var body = file_reader.interface.limited(.limited64(bytes), &input_buffer);
        // One decoded maximum Workspace token, field names and scanner stack;
        // rows are fixed values, not allocator-backed collections or a DOM.
        var storage: [2 * protocol.max_workspace_bytes + protocol.content_window_bytes]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&storage);
        var reader = std.json.Reader.init(fixed.allocator(), &body.interface);
        defer reader.deinit();
        const wire = std.json.parseFromTokenSourceLeaky(Wire, fixed.allocator(), &reader, .{ .ignore_unknown_fields = true }) catch return error.InvalidSessionPage;
        // Underlying physical EOF can precede the limit even after valid JSON.
        if (body.remaining != .nothing) return error.InvalidSessionPage;
        if (!wire.version.eql("1") or !wire.type.eql("session_list")) return error.InvalidSessionPage;
        var result: SessionListPage = .{ .rows = wire.sessions.rows, .count = wire.sessions.count };
        if (cursor.after != 0 and cursor.after == cursor.ceiling and result.count != 0) return error.InvalidSessionPage;
        for (result.rows[0..result.count], 0..) |*row, index| {
            if (workspace) |scope| if (!row.workspace.eql(scope)) return error.InvalidSessionPage;
            for (result.rows[0..index]) |*previous| if (previous.reference.eql(row.reference.slice())) return error.InvalidSessionPage;
        }
        if (wire.next) |next| {
            const after = mutationId(next.after, false) catch return error.InvalidSessionPage;
            const ceiling = mutationId(next.ceiling, false) catch return error.InvalidSessionPage;
            if (result.count != protocol.session_list_page_size or after <= cursor.after or after >= ceiling or
                ceiling > std.math.maxInt(i64) or (cursor.after != 0 and ceiling != cursor.ceiling)) return error.InvalidSessionPage;
            result.next = .{ .after = after, .ceiling = ceiling };
        }
        return result;
    }

    pub fn writeJson(self: *const SessionListPage, writer: *std.Io.Writer) !void {
        try writer.writeAll("{\"version\":\"1\",\"type\":\"session_list\",\"sessions\":[");
        try self.writeRowsJson(writer);
        if (self.next) |next| try writer.print("],\"next\":{{\"after\":\"{d}\",\"ceiling\":\"{d}\"}}}}", .{ next.after, next.ceiling }) else try writer.writeAll("],\"next\":null}");
    }

    /// Rows borrow this validated page. A caller may stream many bounded pages
    /// into one list without retaining the Session population or raw wire text.
    pub fn writeRowsJson(self: *const SessionListPage, writer: *std.Io.Writer) !void {
        for (self.rows[0..self.count], 0..) |*row, index| {
            if (index != 0) try writer.writeAll(",");
            try writer.writeAll("{\"reference\":");
            try std.json.Stringify.value(row.reference.slice(), .{}, writer);
            try writer.writeAll(",\"workspace\":");
            try std.json.Stringify.value(row.workspace.slice(), .{}, writer);
            try writer.print(",\"provider\":\"{s}\",\"model\":", .{@tagName(row.provider)});
            try std.json.Stringify.value(row.model.slice(), .{}, writer);
            try writer.writeAll(",\"tools\":[");
            if (row.tools.bash) try writer.writeAll("\"bash\"");
            try writer.print("],\"permission_mode\":\"{s}\"}}", .{@tagName(row.permission_mode)});
        }
    }
};

/// A request key and canonical Session reference, before any path or socket access.
pub fn validateIdentityInputs(key: []const u8, session: []const u8) !void {
    if (key.len > protocol.max_key_bytes or !std.unicode.utf8ValidateSlice(key)) return error.InvalidKey;
    if (!protocol.validSessionId(session)) return error.InvalidSession;
}

/// An owned selected address, independent of any local request capture.
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

/// Owned scalar facts survive reply-buffer reuse. No DOM, payload or allocator
/// lifetime is retained. Admission status is distinct from the Message result.
pub const CommandObservation = struct {
    key: protocol.Bounded(protocol.max_key_bytes),
    status: enum { absent, accepted, rejected },
    kind: ?MutationKind = null,
    target: ?protocol.Bounded(protocol.max_session_bytes) = null,
    code: ?protocol.Bounded(protocol.max_code_bytes) = null,
    revision: ?u64 = null,
    created: ?bool = null,
    input: ?ContentReference = null,
    queue: ?struct { status: enum { queued, processing, excluded, completed, failed, cancelled }, admission: u64 } = null,
    processing: ?struct { turn: u64, operation: u64, attempt: u64 } = null,
    result: ?struct { status: enum { completed, failed, cancelled }, code: ?protocol.Bounded(protocol.max_code_bytes), text: ?ContentReference } = null,
    progress: ?Progress = null,
    selection: ?struct { turn: ?u64, admission_cutoff: u64 } = null,
    completion: ?enum { pending, completed } = null,
    interruption_target: ?struct { session: protocol.Bounded(protocol.max_session_bytes), turn: u64, operation: u64 } = null,
    permission_target: ?struct { action: u64, decision: protocol.PermissionDecision } = null,

    pub const ContentReference = struct { bytes: u64, digest: [32]u8 };

    pub const State = enum {
        queued,
        processing,
        rejected,
        completed,
        failed,
        cancelled,

        pub fn terminal(self: State) bool {
            return switch (self) {
                .rejected, .completed, .failed, .cancelled => true,
                else => false,
            };
        }
    };

    pub const Progress = struct {
        status: enum { runnable, in_flight, waiting_for_permission },
        action: ?u64,
    };

    pub fn state(self: *const CommandObservation) State {
        std.debug.assert(self.kind == .message and self.status != .absent);
        if (self.status == .rejected) return .rejected;
        // A terminal result wins over coarser queue/progress hints. Admission
        // remains accepted; a later failure is not a submission rejection.
        if (self.result) |result| return switch (result.status) {
            .completed => .completed,
            .failed => .failed,
            .cancelled => .cancelled,
        };
        return if (self.queue.?.status == .queued) .queued else .processing;
    }

    /// Borrowed from this owned value, not from the receive buffer.
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

    /// Semantic output of supported facts only, with decimal identity strings.
    pub fn writeJson(self: *const CommandObservation, writer: *std.Io.Writer) !void {
        try writer.print("{{\"status\":\"{s}\"", .{@tagName(self.status)});
        if (self.kind) |kind| try writer.print(",\"kind\":\"{s}\",\"target\":", .{@tagName(kind)});
        if (self.target) |*target| try std.json.Stringify.value(target.slice(), .{}, writer);
        if (self.code) |*code| {
            try writer.writeAll(",\"code\":");
            try std.json.Stringify.value(code.slice(), .{}, writer);
        }
        if (self.revision) |revision| try writer.print(",\"revision\":\"{d}\",\"created\":{}", .{ revision, self.created.? });
        if (self.input) |input| {
            try writer.writeAll(",\"input\":");
            try writeContentReference(writer, input);
        }
        if (self.queue) |queue| try writer.print(",\"queue\":{{\"status\":\"{s}\",\"admission\":\"{d}\"}}", .{ @tagName(queue.status), queue.admission });
        if (self.processing) |binding| try writer.print(",\"processing\":{{\"turn\":\"{d}\",\"operation\":\"{d}\",\"attempt\":\"{d}\"}}", .{ binding.turn, binding.operation, binding.attempt });
        if (self.result) |result| {
            try writer.print(",\"result\":{{\"status\":\"{s}\"", .{@tagName(result.status)});
            if (result.code) |*code| {
                try writer.writeAll(",\"code\":");
                try std.json.Stringify.value(code.slice(), .{}, writer);
            }
            if (result.text) |text| {
                try writer.writeAll(",\"text\":");
                try writeContentReference(writer, text);
            }
            try writer.writeByte('}');
        }
        if (self.progress) |progress| {
            try writer.print(",\"progress\":{{\"status\":\"{s}\",\"action\":", .{@tagName(progress.status)});
            if (progress.action) |action| try writer.print("\"{d}\"", .{action}) else try writer.writeAll("null");
            try writer.writeByte('}');
        }
        if (self.selection) |selection| {
            try writer.writeAll(",\"selection\":{\"turn\":");
            if (selection.turn) |turn| try writer.print("\"{d}\"", .{turn}) else try writer.writeAll("null");
            try writer.print(",\"admission_cutoff\":\"{d}\"}},\"completion\":{{\"status\":\"{s}\"}}", .{ selection.admission_cutoff, @tagName(self.completion.?) });
        }
        if (self.interruption_target) |*target| {
            try writer.writeAll(",\"interruption_target\":{\"session\":");
            try std.json.Stringify.value(target.session.slice(), .{}, writer);
            try writer.print(",\"turn\":\"{d}\",\"operation\":\"{d}\"}}", .{ target.turn, target.operation });
        }
        if (self.permission_target) |target| try writer.print(",\"permission_target\":{{\"action\":\"{d}\",\"decision\":\"{s}\"}}", .{ target.action, @tagName(target.decision) });
        try writer.writeByte('}');
    }

    fn writeContentReference(writer: *std.Io.Writer, reference: ContentReference) !void {
        try writer.print("{{\"type\":\"text\",\"bytes\":\"{d}\",\"sha256\":\"{s}\"}}", .{ reference.bytes, std.fmt.bytesToHex(reference.digest, .lower) });
    }

    pub fn parse(reply: CommandReply, key: []const u8) !CommandObservation {
        try checkCanonicalFailure(reply);
        if (reply.status != 200) return error.ObservationFailed;
        if (reply.body.len > protocol.max_response_bytes) return error.ResponseTooLarge;
        const Ref = struct { type: JsonEnum(enum { text }), bytes: JsonString(20), sha256: JsonString(64) };
        const Facts = struct {
            status: JsonEnum(@FieldType(CommandObservation, "status")),
            kind: OmittableJson(JsonEnum(MutationKind)) = .{},
            target: OmittableJson(JsonString(protocol.max_session_bytes)) = .{},
            code: OmittableJson(JsonString(protocol.max_code_bytes)) = .{},
            revision: OmittableJson(JsonString(20)) = .{},
            created: OmittableJson(bool) = .{},
            input: OmittableJson(Ref) = .{},
            queue: OmittableJson(struct { status: JsonEnum(@FieldType(@typeInfo(@FieldType(CommandObservation, "queue")).optional.child, "status")), admission: JsonString(20) }) = .{},
            processing: OmittableJson(struct { turn: JsonString(20), operation: JsonString(20), attempt: JsonString(20) }) = .{},
            result: OmittableJson(struct { status: JsonEnum(@FieldType(@typeInfo(@FieldType(CommandObservation, "result")).optional.child, "status")), code: OmittableJson(JsonString(protocol.max_code_bytes)) = .{}, text: OmittableJson(Ref) = .{} }) = .{},
            progress: OmittableJson(struct { status: JsonEnum(@FieldType(Progress, "status")), action: ?JsonString(20) }) = .{},
            selection: OmittableJson(struct { turn: ?JsonString(20), admission_cutoff: JsonString(20) }) = .{},
            completion: OmittableJson(struct { status: JsonEnum(@typeInfo(@FieldType(CommandObservation, "completion")).optional.child) }) = .{},
            interruption_target: OmittableJson(struct { session: JsonString(protocol.max_session_bytes), turn: JsonString(20), operation: JsonString(20) }) = .{},
            permission_target: OmittableJson(struct { action: JsonString(20), decision: JsonEnum(protocol.PermissionDecision) }) = .{},
        };
        const Wire = struct { version: JsonString(8), type: JsonString(32), key: JsonString(protocol.max_key_bytes), observation: Facts, code: OmittableJson(JsonString(protocol.max_code_bytes)) = .{}, answer: OmittableJson(struct {}) = .{} };
        const capacity = comptime std.ArrayList(u8).growCapacity((protocol.max_response_bytes + 7) / 8) + std.ArrayList(u8).growCapacity(protocol.max_response_bytes);
        var storage: [capacity]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&storage);
        var scanner = std.json.Scanner.initCompleteInput(fixed.allocator(), reply.body);
        defer scanner.deinit();
        scanner.ensureTotalStackCapacity(protocol.max_response_bytes) catch unreachable;
        const wire = std.json.parseFromTokenSourceLeaky(Wire, fixed.allocator(), &scanner, .{ .ignore_unknown_fields = true }) catch return error.InvalidObservation;
        if (!wire.version.eql(protocol.wire_version) or !wire.type.eql("command_observation") or wire.code.value != null or wire.answer.value != null) return error.InvalidObservation;
        if (!wire.key.eql(key)) return error.RequestBindingMismatch;
        const facts = wire.observation;
        var observed: CommandObservation = .{ .key = wire.key.value, .status = facts.status.value, .kind = if (facts.kind.value) |kind| kind.value else null, .created = facts.created.value };
        inline for (.{ "target", "code" }) |name| if (@field(facts, name).value) |value| {
            @field(observed, name) = value.value;
        };
        if (facts.revision.value) |value| observed.revision = try mutationId(value, false);
        if (facts.input.value) |value| observed.input = try decodeReference(value);
        if (facts.queue.value) |value| observed.queue = .{ .status = value.status.value, .admission = try mutationId(value.admission, false) };
        if (facts.processing.value) |value| observed.processing = .{ .turn = try mutationId(value.turn, false), .operation = try mutationId(value.operation, false), .attempt = try mutationId(value.attempt, true) };
        if (facts.result.value) |value| observed.result = .{ .status = value.status.value, .code = if (value.code.value) |code| code.value else null, .text = if (value.text.value) |text| try decodeReference(text) else null };
        if (facts.progress.value) |value| observed.progress = .{ .status = value.status.value, .action = if (value.action) |action| try mutationId(action, false) else null };
        if (facts.selection.value) |value| observed.selection = .{ .turn = if (value.turn) |turn| try mutationId(turn, false) else null, .admission_cutoff = try mutationId(value.admission_cutoff, true) };
        if (facts.completion.value) |value| observed.completion = value.status.value;
        if (facts.interruption_target.value) |value| observed.interruption_target = .{ .session = value.session.value, .turn = try mutationId(value.turn, true), .operation = try mutationId(value.operation, true) };
        if (facts.permission_target.value) |value| observed.permission_target = .{ .action = try mutationId(value.action, true), .decision = value.decision.value };
        try observed.validate();
        return observed;
    }

    fn decodeReference(value: anytype) !ContentReference {
        var result: ContentReference = .{ .bytes = try mutationId(value.bytes, true), .digest = undefined };
        if (value.sha256.slice().len != 64) return error.InvalidObservation;
        _ = std.fmt.hexToBytes(&result.digest, value.sha256.slice()) catch return error.InvalidObservation;
        return result;
    }

    fn validate(self: *const CommandObservation) !void {
        if (self.status == .absent) {
            inline for (.{ "kind", "target", "code", "revision", "created", "input", "queue", "processing", "result", "progress", "selection", "completion", "interruption_target", "permission_target" }) |name| if (@field(self, name) != null) return error.InvalidObservation;
            return;
        }
        const kind = self.kind orelse return error.InvalidObservation;
        if (self.target == null or (self.target.?.len == 0 and
            (self.status != .rejected or (kind != .configure and kind != .message)))) return error.InvalidObservation;
        if ((self.status == .rejected) != (self.code != null)) return error.InvalidObservation;
        if (self.code) |code| if (code.len == 0) return error.InvalidObservation;
        const accepted = self.status == .accepted;
        if (accepted and !protocol.validSessionId(self.target.?.slice())) return error.InvalidObservation;
        if ((self.revision != null) != (accepted and kind == .configure) or (self.created != null) != (accepted and kind == .configure)) return error.InvalidObservation;
        if ((self.selection != null) != (accepted and kind == .session_stop) or (self.completion != null) != (accepted and kind == .session_stop)) return error.InvalidObservation;
        if ((self.interruption_target != null) != (kind == .model_interruption) or (self.permission_target != null) != (kind == .permission_decision)) return error.InvalidObservation;
        if (self.interruption_target) |target| if (!target.session.eql(self.target.?.slice())) return error.RequestBindingMismatch;
        if (kind != .message or !accepted) {
            if (self.queue != null or self.processing != null or self.result != null or self.progress != null or (kind != .message and self.input != null)) return error.InvalidObservation;
            return;
        }
        if (self.input == null or self.queue == null) return error.InvalidObservation;
        const queue = self.queue.?;
        if (queue.status != .queued and queue.status != .excluded and self.processing == null) return error.InvalidObservation;
        if ((queue.status == .excluded or queue.status == .completed or queue.status == .failed or queue.status == .cancelled) and self.result == null) return error.InvalidObservation;
        if (queue.status == .excluded and self.processing != null) return error.InvalidObservation;
        if (self.result) |result| {
            if (queue.status == .excluded) {
                if (result.status != .cancelled) return error.InvalidObservation;
            } else if (self.processing == null) return error.InvalidObservation;
            if ((queue.status == .completed and result.status != .completed) or
                (queue.status == .failed and result.status != .failed) or
                (queue.status == .cancelled and result.status != .cancelled)) return error.InvalidObservation;
            if (result.status == .completed) {
                if (result.text == null or result.code != null or self.processing == null) return error.InvalidObservation;
            } else if (result.text != null or result.code == null or result.code.?.len == 0) return error.InvalidObservation;
        }
        if (self.progress) |progress| if (progress.status == .waiting_for_permission and progress.action == null) return error.InvalidObservation;
    }
};

/// The five durable mutations. Tag names are the captured-record and
/// observation spelling; `rui request recover --kind` uses the hyphenated spelling.
pub const MutationKind = enum {
    configure,
    message,
    session_stop,
    model_interruption,
    permission_decision,

    pub fn route(self: MutationKind) []const u8 {
        return switch (self) {
            .configure => "/v1/configure",
            .message => "/v1/message",
            .session_stop => "/v1/control/session-stop",
            .model_interruption => "/v1/control/model-interruption",
            .permission_decision => "/v1/control/permission-decision",
        };
    }

    pub fn parseRetryName(name: []const u8) ?MutationKind {
        inline for (comptime std.enums.values(MutationKind)) |kind| {
            if (std.mem.eql(u8, name, comptime retryName(kind))) return kind;
        }
        return null;
    }

    pub fn retryName(comptime kind: MutationKind) []const u8 {
        comptime {
            var name = @tagName(kind)[0..@tagName(kind).len].*;
            std.mem.replaceScalar(u8, &name, '_', '-');
            const final = name;
            return &final;
        }
    }
};

pub const MutationTarget = union(MutationKind) {
    configure,
    message: struct { bytes: u64, digest: [32]u8, creates_session: bool = false },
    session_stop,
    model_interruption: struct { turn: u64, operation: u64 },
    permission_decision: struct { action: u64, decision: protocol.PermissionDecision },

    pub fn route(self: MutationTarget) []const u8 {
        return std.meta.activeTag(self).route();
    }
};

pub const MutationAnswer = struct {
    result: union(enum) {
        accepted: union(enum) {
            configure: struct { revision: u64, created: bool },
            message: struct { admission: u64 },
            session_stop: struct { turn: ?u64, admission_cutoff: u64, completion: enum { pending, completed } },
            model_interruption,
            permission_decision,
        },
        rejected: protocol.Bounded(protocol.max_code_bytes),
        conflict,
    },
    replayed: bool,
};

pub const InvocationDiagnostic = struct {
    type: protocol.Bounded(32),
    code: protocol.Bounded(protocol.max_code_bytes),
};

/// Owned facts and original request context survive buffer reuse and capture
/// closure. An answer error is unconfirmed, never rejection or noncommit.
pub const MutationReply = struct {
    status: u16,
    diagnostic: ?InvocationDiagnostic = null,
    context: MutationIdentity = .{},
    target: MutationTarget,
    answer: error{ CanonicalStoreFailure, HostInvocationFailed, InvalidResponse, RequestBindingMismatch }!MutationAnswer,

    pub fn isAccepted(self: MutationReply) bool {
        const answer = self.answer catch return false;
        return answer.result == .accepted;
    }
};

pub fn JsonString(comptime limit: usize) type {
    return struct {
        value: protocol.Bounded(limit) = .{},

        pub fn slice(self: *const @This()) []const u8 {
            return self.value.slice();
        }

        pub fn eql(self: *const @This(), value: []const u8) bool {
            return self.value.eql(value);
        }

        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.write(self.value.slice());
        }

        pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, _: std.json.ParseOptions) !@This() {
            if (try source.peekNextTokenType() != .string) return error.UnexpectedToken;
            const token = try source.nextAllocMax(allocator, .alloc_if_needed, limit);
            defer if (token == .allocated_string) allocator.free(token.allocated_string);
            var result: @This() = .{};
            result.value.set(switch (token) {
                .string, .allocated_string => |value| value,
                else => unreachable,
            }) catch return error.InvalidCharacter;
            return result;
        }
    };
}

pub const JsonAddress = struct {
    store: JsonString(protocol.max_store_bytes),
    session: JsonString(protocol.max_session_bytes),

    pub fn address(self: JsonAddress) !protocol.Address {
        const result: protocol.Address = .{ .store = self.store.value, .session = self.session.value };
        try result.validate();
        return result;
    }
};

/// Pages expose only canonical Session IDs as peer labels.
pub const JsonPeer = struct {
    session: JsonString(protocol.max_session_bytes),

    fn peer(self: *const JsonPeer) !protocol.Peer {
        if (!protocol.validSessionId(self.session.slice())) return error.InvalidResponse;
        return .{ .session = self.session.value };
    }
};

// The stdlib also accepts numeric enum tags. Host facts require named strings;
// their closed vocabulary derives the token bound, with JsonString's lifetime.
pub const JsonToolPresentation = struct {
    value: protocol.ToolPresentation,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const Wire = struct { description: ?JsonString(protocol.max_tool_description_bytes), code: JsonEnum(protocol.ToolPresentation.Code), publication_position: ?JsonString(20) };
        const wire = try std.json.innerParse(Wire, allocator, source, options);
        const position = if (wire.publication_position) |p| mutationId(p, false) catch return error.InvalidCharacter else null;
        if (position) |p| if (p > std.math.maxInt(i64)) return error.InvalidCharacter;
        if (wire.description) |d| if (!@import("tools.zig").validDescription(d.slice())) return error.InvalidCharacter;
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
        "{\"code\":\"succeeded\",\"publication_position\":null}",
        "{\"description\":null,\"code\":\"succeeded\",\"code\":\"failed\",\"publication_position\":null}",
        "{\"description\":\"" ++ @as([101]u8, @splat('x')) ++ "\",\"code\":\"succeeded\",\"publication_position\":null}",
    }) |invalid| {
        if (std.json.parseFromSlice(JsonToolPresentation, std.testing.allocator, invalid, .{})) |unexpected| {
            unexpected.deinit();
            return error.AcceptedInvalidPresentation;
        } else |_| {}
    }
    // Worst JSON escaping is six bytes per decoded byte, not the token bound.
    const escaped = "{\"description\":\"" ++ @as([100 * 6]u8, @bitCast(@as([100][6]u8, @splat("\\u0001".*)))) ++ "\",\"code\":\"succeeded\",\"publication_position\":\"9223372036854775807\"}";
    const maximum = try std.json.parseFromSlice(JsonToolPresentation, std.testing.allocator, escaped, .{});
    defer maximum.deinit();
    try std.testing.expectEqual(@as(usize, 100), maximum.value.value.description.?.slice().len);
    var buffer: [protocol.ToolPresentation.max_json_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try maximum.value.value.writeJson(&writer);
    const roundtrip = try std.json.parseFromSlice(JsonToolPresentation, std.testing.allocator, writer.buffered(), .{});
    defer roundtrip.deinit();
    try std.testing.expectEqualDeep(maximum.value.value, roundtrip.value.value);
    var facts: protocol.ActivityFacts = .{ .end = 16, .count = 16 };
    for (&facts.items, 0..) |*item, index| item.* = .{
        .position = index + 1,
        .ordinal = 1,
        .value = .{ .tool_result = .{ .content = .{ .length = 0, .digest = protocol.contentDigest("") }, .presentation = .{ .description = maximum.value.value.description, .code = .succeeded, .publication_position = index + 1 } } },
    };
    facts.call_activity = .{ .total = std.math.maxInt(i64), .count = 3 };
    for (&facts.call_activity.entries, 0..) |*entry, index| entry.* = .{
        .operation = std.math.maxInt(i64) - 2 + index,
        .ordinal = std.math.maxInt(i64) - 1,
        .presentation = .{ .description = maximum.value.value.description, .code = .infrastructure_shutdown, .publication_position = std.math.maxInt(i64) },
    };
    facts.work = .{ .status = .waiting_for_permission, .turn = std.math.maxInt(i64), .operation = std.math.maxInt(i64) - 1, .first_action = std.math.maxInt(i64) - 2, .revision = std.math.maxInt(i64) };
    // An absolute Workspace whose other bytes escape to their widest JSON form.
    @memset(facts.work.workspace.bytes[0..protocol.max_workspace_bytes], 0x01);
    facts.work.workspace.bytes[0] = '/';
    facts.work.workspace.len = protocol.max_workspace_bytes;
    var page_buffer: [protocol.max_activity_page_response_bytes]u8 = undefined;
    var page_writer = std.Io.Writer.fixed(&page_buffer);
    try facts.writeJson(&page_writer);
    const page = try ActivityPage.parse(page_writer.buffered(), .{});
    try std.testing.expectEqual(@as(usize, 16), page.facts.count);
    try std.testing.expectEqualDeep(facts.call_activity, page.facts.call_activity);
    try std.testing.expectEqualDeep(facts.work, page.facts.work);
    for (page.facts.items) |item| {
        try std.testing.expectEqual(@as(usize, 100), item.value.tool_result.presentation.description.?.slice().len);
        try std.testing.expectEqual(item.position, item.value.tool_result.presentation.publication_position.?);
    }
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
                // No outer arena may hide leaked temporary decoded tokens.
                break :decode std.json.parseFromTokenSourceLeaky(JsonToolPresentation, allocator, &scanner, .{});
            };
            const value = (result catch |err| {
                if (err == error.OutOfMemory) return err;
                try std.testing.expect(invalid);
                try std.testing.expectEqual(error.InvalidCharacter, err);
                return;
            }).value;
            // Returned bounded facts must outlive the parser's allocations.
            try std.testing.expect(!invalid);
            try std.testing.expectEqualStrings("Read € files", value.description.?.slice());
            try std.testing.expectEqual(protocol.ToolPresentation.Code.succeeded, value.code);
            try std.testing.expectEqual(@as(?u64, 9223372036854775807), value.publication_position);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{false});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{true});
}

pub fn JsonEnum(comptime T: type) type {
    const limit = comptime blk: {
        var longest: usize = 0;
        for (@typeInfo(T).@"enum".field_names) |name| longest = @max(longest, name.len);
        break :blk longest;
    };
    return struct {
        value: T,

        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.write(@tagName(self.value));
        }

        pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
            const string = try JsonString(limit).jsonParse(allocator, source, options);
            return .{ .value = std.meta.stringToEnum(T, string.slice()) orelse return error.InvalidEnumTag };
        }
    };
}

// The containing field's default represents omission. A present field must
// parse as T, not ?T: JSON null cannot stand in for an absent outcome/diagnostic.
pub fn OmittableJson(comptime T: type) type {
    return struct {
        value: ?T = null,

        pub fn isPresent(self: @This()) bool {
            return self.value != null;
        }
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.write(self.value);
        }

        pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
            return .{ .value = try std.json.innerParse(T, allocator, source, options) };
        }
    };
}

pub fn mutationId(value: JsonString(20), allow_zero: bool) !u64 {
    const bytes = value.slice();
    if (bytes.len == 0 or (bytes.len > 1 and bytes[0] == '0')) return error.InvalidResponse;
    for (bytes) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidResponse;
    const id = std.fmt.parseInt(u64, bytes, 10) catch return error.InvalidResponse;
    if (!allow_zero and id == 0) return error.InvalidResponse;
    return id;
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

/// One operation boundary for synchronous callers and a later worker. No
/// workflow, terminal, retry or certainty transition is made by this decoder.
pub fn decodeMutationReply(reply: CommandReply, session: []const u8, target: MutationTarget) MutationReply {
    var result: MutationReply = .{ .status = reply.status, .target = target, .answer = error.InvalidResponse };
    result.context.session.set(session) catch return result;
    var resolved = result.context.session;
    result.answer = decodeMutationAnswer(reply, session, target, &result.diagnostic, &resolved);
    if (result.answer) |_| result.context.session = resolved else |_| {}
    return result;
}

fn decodeMutationAnswer(reply: CommandReply, session: []const u8, target: MutationTarget, diagnostic: *?InvocationDiagnostic, resolved_session: *protocol.Bounded(protocol.max_session_bytes)) @FieldType(MutationReply, "answer") {
    if (reply.body.len > protocol.max_response_bytes) return error.InvalidResponse;
    const Wire = struct {
        version: JsonString(8),
        type: JsonString(32),
        code: OmittableJson(JsonString(protocol.max_code_bytes)) = .{},
        answer: OmittableJson(struct {
            status: JsonString(16),
            replayed: bool,
            session: OmittableJson(JsonString(protocol.max_session_bytes)) = .{},
            code: OmittableJson(JsonString(protocol.max_code_bytes)) = .{},
            revision: OmittableJson(JsonString(20)) = .{},
            created: OmittableJson(bool) = .{},
            admission: OmittableJson(JsonString(20)) = .{},
            action: OmittableJson(JsonString(20)) = .{},
            decision: OmittableJson(JsonString(16)) = .{},
            selection: OmittableJson(struct { turn: ?JsonString(20), admission_cutoff: JsonString(20) }) = .{},
            target: OmittableJson(struct { session: JsonString(protocol.max_session_bytes), turn: JsonString(20), operation: JsonString(20) }) = .{},
        }) = .{},
        input: OmittableJson(struct { type: JsonString(8), bytes: JsonString(20), sha256: JsonString(64) }) = .{},
        queue: OmittableJson(struct { status: JsonString(16), admission: JsonString(20) }) = .{},
        execution: OmittableJson(struct { status: JsonString(16), reason: OmittableJson(JsonString(64)) = .{} }) = .{},
        completion: OmittableJson(struct { status: JsonString(16) }) = .{},
    };
    // Strings are copied into bounded values and immediately freed. Reserve
    // scanner nesting first, as in the canonical classifier; no payload arena.
    const capacity = comptime std.ArrayList(u8).growCapacity((protocol.max_response_bytes + 7) / 8) + std.ArrayList(u8).growCapacity(protocol.max_response_bytes);
    var storage: [capacity]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var scanner = std.json.Scanner.initCompleteInput(fixed.allocator(), reply.body);
    defer scanner.deinit();
    scanner.ensureTotalStackCapacity(protocol.max_response_bytes) catch unreachable;
    const wire = std.json.parseFromTokenSourceLeaky(Wire, fixed.allocator(), &scanner, .{ .ignore_unknown_fields = true }) catch return error.InvalidResponse;
    if (wire.code.value) |code| {
        if (wire.answer.value != null or wire.input.value != null or wire.queue.value != null or wire.execution.value != null or wire.completion.value != null) return error.InvalidResponse;
        const parsed = InvocationDiagnostic{ .type = wire.type.value, .code = code.value };
        try validateInvocationDiagnostic(reply.status, wire.version.slice(), parsed);
        diagnostic.* = parsed;
        if (parsed.code.eql("canonical_store_failure")) return error.CanonicalStoreFailure;
        return error.HostInvocationFailed;
    }
    if (reply.status != 200 and reply.status != 409) return error.InvalidResponse;
    const expected_type = switch (target) {
        .configure => "configuration_reply",
        .message => "message_reply",
        .session_stop => "session_stop_reply",
        .model_interruption => "model_interruption_reply",
        .permission_decision => "permission_decision_reply",
    };
    if (!wire.version.eql("1") or !wire.type.eql(expected_type) or wire.code.value != null) return error.InvalidResponse;
    const answer = wire.answer.value orelse return error.InvalidResponse;
    if (target == .model_interruption) {
        const echoed = answer.target.value orelse return error.InvalidResponse;
        if (answer.session.value != null or !echoed.session.eql(session) or try mutationId(echoed.turn, true) != target.model_interruption.turn or
            try mutationId(echoed.operation, true) != target.model_interruption.operation) return error.RequestBindingMismatch;
    } else {
        const echoed = answer.session.value orelse return error.InvalidResponse;
        if (answer.target.value != null) return error.RequestBindingMismatch;
        if (target == .configure and session.len == 0 and answer.status.eql("accepted")) {
            if (!protocol.validSessionId(echoed.slice()) or answer.created.value != true) return error.RequestBindingMismatch;
            resolved_session.* = echoed.value;
        } else if (target == .message and target.message.creates_session and session.len == 0 and answer.status.eql("accepted")) {
            if (!protocol.validSessionId(echoed.slice())) return error.RequestBindingMismatch;
            resolved_session.* = echoed.value;
        } else if (!echoed.eql(session)) return error.RequestBindingMismatch;
    }
    if (target == .permission_decision) {
        if (try mutationId(answer.action.value orelse return error.InvalidResponse, true) != target.permission_decision.action or
            !(answer.decision.value orelse return error.InvalidResponse).eql(@tagName(target.permission_decision.decision))) return error.RequestBindingMismatch;
    } else if (answer.action.value != null or answer.decision.value != null) return error.InvalidResponse;
    const accepted = answer.status.eql("accepted");
    const conflict = answer.status.eql("conflict");
    if ((!accepted and !conflict and !answer.status.eql("rejected")) or (reply.status == 409) != conflict) return error.InvalidResponse;
    if (accepted) {
        if (!protocol.validSessionId(resolved_session.slice())) return error.InvalidResponse;
        if (answer.code.value != null) return error.InvalidResponse;
    } else {
        const code = answer.code.value orelse return error.InvalidResponse;
        if (code.slice().len == 0 or answer.revision.value != null or answer.created.value != null or answer.admission.value != null or answer.selection.value != null) return error.InvalidResponse;
        if (conflict and (!code.eql("idempotency_key_conflict") or answer.replayed)) return error.InvalidResponse;
    }
    var value: @FieldType(@FieldType(MutationAnswer, "result"), "accepted") = undefined;
    switch (target) {
        .configure => {
            const execution = wire.execution.value orelse return error.InvalidResponse;
            if (!execution.status.eql("unavailable") or !(execution.reason.value orelse return error.InvalidResponse).eql("direct_reply_does_not_wait_for_model_processing")) return error.InvalidResponse;
            if (accepted) value = .{ .configure = .{ .revision = try mutationId(answer.revision.value orelse return error.InvalidResponse, false), .created = answer.created.value orelse return error.InvalidResponse } };
        },
        .message => |expected| {
            if (!(wire.execution.value orelse return error.InvalidResponse).status.eql("queued")) return error.InvalidResponse;
            if (conflict) {
                if (wire.input.value != null or wire.queue.value != null) return error.InvalidResponse;
            } else {
                const input = wire.input.value orelse return error.InvalidResponse;
                var digest: [32]u8 = undefined;
                if (!input.type.eql("text") or input.sha256.slice().len != 64) return error.InvalidResponse;
                _ = std.fmt.hexToBytes(&digest, input.sha256.slice()) catch return error.InvalidResponse;
                if (try mutationId(input.bytes, true) != expected.bytes or !std.mem.eql(u8, &digest, &expected.digest)) return error.RequestBindingMismatch;
                if (accepted) {
                    const admission = try mutationId(answer.admission.value orelse return error.InvalidResponse, false);
                    const queue = wire.queue.value orelse return error.InvalidResponse;
                    if (!queue.status.eql("queued") or try mutationId(queue.admission, false) != admission) return error.InvalidResponse;
                    value = .{ .message = .{ .admission = admission } };
                } else if (wire.queue.value != null) return error.InvalidResponse;
            }
        },
        .session_stop => {
            const completion = wire.completion.value orelse return error.InvalidResponse;
            if (accepted) {
                const selection = answer.selection.value orelse return error.InvalidResponse;
                value = .{ .session_stop = .{
                    .turn = if (selection.turn) |turn| try mutationId(turn, false) else null,
                    .admission_cutoff = try mutationId(selection.admission_cutoff, true),
                    .completion = std.meta.stringToEnum(@FieldType(@FieldType(@TypeOf(value), "session_stop"), "completion"), completion.status.slice()) orelse return error.InvalidResponse,
                } };
            } else if (!completion.status.eql("unavailable")) return error.InvalidResponse;
        },
        .model_interruption => if (accepted) {
            value = .model_interruption;
        },
        .permission_decision => if (accepted) {
            value = .permission_decision;
        },
    }
    if ((target != .configure and (answer.revision.value != null or answer.created.value != null)) or
        (target != .message and (answer.admission.value != null or wire.input.value != null or wire.queue.value != null)) or
        (target != .session_stop and (answer.selection.value != null or wire.completion.value != null))) return error.InvalidResponse;
    return .{
        .replayed = answer.replayed,
        .result = if (accepted) .{ .accepted = value } else if (conflict) .conflict else .{ .rejected = answer.code.value.?.value },
    };
}

test "mutation decoder checks binding queue ambiguity and fixed reply bounds" {
    const digest = protocol.contentDigest("a\nµ");
    const target: MutationTarget = .{ .message = .{ .bytes = 4, .digest = digest } };
    const prefix = "{\"version\":\"1\",\"type\":\"message_reply\",\"answer\":{\"status\":\"accepted\",\"replayed\":false,\"session\":\"k7m2q\\u0078\",\"admission\":\"7\"}";
    var suffix_storage: [256]u8 = undefined;
    const suffix = try std.fmt.bufPrint(&suffix_storage, ",\"input\":{{\"type\":\"text\",\"bytes\":\"4\",\"sha256\":\"{s}\"}},\"queue\":{{\"status\":\"queued\",\"admission\":\"7\"}},\"execution\":{{\"status\":\"queued\"}}}}", .{std.fmt.bytesToHex(digest, .lower)});
    var body: [protocol.max_response_bytes + 1]u8 = undefined;
    const valid = try std.fmt.bufPrint(&body, "{s}{s}", .{ prefix, suffix });
    const reply: CommandReply = .{ .status = 200, .body = valid };
    try std.testing.expectEqual(@as(u64, 7), (try decodeMutationReply(reply, "k7m2qx", target).answer).result.accepted.message.admission);
    try std.testing.expectError(error.RequestBindingMismatch, decodeMutationReply(reply, "09azvw", target).answer);
    var changed = target;
    changed.message.bytes = 5;
    try std.testing.expectError(error.RequestBindingMismatch, decodeMutationReply(reply, "k7m2qx", changed).answer);
    changed = target;
    changed.message.digest[3] ^= 1;
    try std.testing.expectError(error.RequestBindingMismatch, decodeMutationReply(reply, "k7m2qx", changed).answer);
    try std.testing.expectError(error.InvalidResponse, decodeMutationReply(.{ .status = 409, .body = valid }, "k7m2qx", target).answer);
    @memset(body[valid.len..protocol.max_response_bytes], ' ');
    _ = try decodeMutationReply(.{ .status = 200, .body = body[0..protocol.max_response_bytes] }, "k7m2qx", target).answer;
    body[protocol.max_response_bytes] = ' ';
    try std.testing.expectError(error.InvalidResponse, decodeMutationReply(.{ .status = 200, .body = &body }, "k7m2qx", target).answer);
    for ([_][]const u8{
        "{\"version\":1,\"type\":\"message_reply\",\"answer\":{\"status\":\"accepted\",\"replayed\":false,\"session\":\"k7m2qx\",\"admission\":\"7\"}",
        "{\"version\":\"1\",\"type\":\"message_reply\",\"answer\":{\"status\":\"accepted\",\"sta\\u0074us\":\"rejected\",\"replayed\":false,\"session\":\"k7m2qx\",\"admission\":\"7\"}",
        "{\"version\":\"1\",\"type\":\"message_reply\",\"answer\":{\"status\":\"accepted\",\"replayed\":false,\"session\":\"k7m2qx\",\"admission\":\"07\"}",
        "{\"version\":\"1\",\"type\":\"message_reply\",\"answer\":{\"status\":\"rejected\",\"replayed\":false,\"session\":\"k7m2qx\",\"code\":\"unknown_session\"}",
    }) |invalid_prefix| {
        const invalid = try std.fmt.bufPrint(&body, "{s}{s}", .{ invalid_prefix, suffix });
        try std.testing.expectError(error.InvalidResponse, decodeMutationReply(.{ .status = 200, .body = invalid }, "k7m2qx", target).answer);
    }
    const conflicting_queue = try std.fmt.bufPrint(&body, "{s},\"input\":{{\"type\":\"text\",\"bytes\":\"4\",\"sha256\":\"{s}\"}},\"queue\":{{\"status\":\"queued\",\"admission\":\"8\"}},\"execution\":{{\"status\":\"queued\"}}}}", .{ prefix, std.fmt.bytesToHex(digest, .lower) });
    try std.testing.expectError(error.InvalidResponse, decodeMutationReply(.{ .status = 200, .body = conflicting_queue }, "k7m2qx", target).answer);
    const malformed = try std.fmt.bufPrint(&body, "{s}{s} trailing", .{ prefix, suffix });
    try std.testing.expectError(error.InvalidResponse, decodeMutationReply(.{ .status = 200, .body = malformed }, "k7m2qx", target).answer);
}

test "mutation decoder preserves invalid-target domain rejection not false fatal certainty" {
    const body = "{\"version\":\"1\",\"type\":\"model_interruption_reply\",\"answer\":{\"status\":\"rejected\",\"replayed\":true,\"target\":{\"session\":\"s\",\"turn\":\"0\",\"operation\":\"18446744073709551615\"},\"code\":\"invalid_target\"}}";
    const target: MutationTarget = .{ .model_interruption = .{ .turn = 0, .operation = std.math.maxInt(u64) } };
    const answer = try decodeMutationReply(.{ .status = 200, .body = body }, "s", target).answer;
    try std.testing.expectEqualStrings("invalid_target", answer.result.rejected.slice());
    try std.testing.expect(answer.replayed);
    for ([_][]const u8{
        "{\"version\":\"1\",\"type\":\"invocation_error\",\"code\":\"unavailable\"}",
        "{\"version\":\"1\",\"type\":\"message_reply\",\"answer\":{\"status\":\"infrastructure_failure\",\"code\":\"canonical_store_failure\"}}",
    }) |unknown| {
        const reply = decodeMutationReply(.{ .status = 500, .body = unknown }, "s", target);
        try std.testing.expectError(if (std.mem.indexOf(u8, unknown, "unavailable") != null) error.HostInvocationFailed else error.InvalidResponse, reply.answer);
        try std.testing.expect(!reply.isAccepted());
        if (std.mem.indexOf(u8, unknown, "unavailable") != null)
            try std.testing.expectEqualStrings("unavailable", reply.diagnostic.?.code.slice());
    }
}

test "mutation diagnostics own complete validated metadata without raw reply lifetime" {
    const body = "{\"version\":\"1\",\"type\":\"invocation_error\",\"co\\u0064e\":\"busy\\u002fµ\",\"extra\":[null,{}]}";
    var bytes: [body.len]u8 = body.*;
    const reply = decodeMutationReply(.{ .status = 409, .body = &bytes }, "original/session", .configure);
    @memset(&bytes, 'x');
    try std.testing.expectError(error.HostInvocationFailed, reply.answer);
    try std.testing.expect(reply.diagnostic != null);
    try std.testing.expectEqualStrings("busy/µ", reply.diagnostic.?.code.slice());
    try std.testing.expectEqualStrings("invocation_error", reply.diagnostic.?.type.slice());
    try std.testing.expectEqualStrings("original/session", reply.context.session.slice());
    for ([_][]const u8{
        "{\"version\":\"1\",\"type\":\"invocation_error\",\"code\":\"canonical_store_failure\"}",
        "{\"version\":\"1\",\"type\":\"busy\",\"code\":\"capacity_exhausted\"}",
    }, [_]u16{ 500, 503 }) |valid, status| {
        const value = decodeMutationReply(.{ .status = status, .body = valid }, "s", .configure);
        try std.testing.expectError(if (status == 500) error.CanonicalStoreFailure else error.HostInvocationFailed, value.answer);
        try std.testing.expect(value.diagnostic != null);
    }
    const prefix = "{\"version\":\"1\",\"type\":\"invocation_error\",\"code\":\"busy\"";
    for ([_][]const u8{
        prefix ++ ",\"co\\u0064e\":\"other\"}",
        prefix ++ ",\"extra\":[}",
        prefix ++ "} trailing",
        prefix ++ ",\"answer\":{\"status\":\"accepted\",\"replayed\":false}}",
        "{\"version\":\"1\",\"type\":\"busy\",\"code\":\"canonical_store_failure\"}",
        "{\"version\":\"1\",\"type\":\"invocation_error\",\"code\":[98]}",
    }) |invalid| {
        const value = decodeMutationReply(.{ .status = 500, .body = invalid }, "s", .configure);
        try std.testing.expectError(error.InvalidResponse, value.answer);
        try std.testing.expect(value.diagnostic == null);
    }
}

pub const MutationIdentity = struct {
    store: protocol.Bounded(protocol.max_store_bytes) = .{},
    key: protocol.Bounded(protocol.max_key_bytes) = .{},
    session: protocol.Bounded(protocol.max_session_bytes) = .{},
    kind: protocol.Bounded(32) = .{},

    pub fn isKind(self: *const MutationIdentity, kind: MutationKind) bool {
        return self.kind.eql(@tagName(kind));
    }
};

// Shared authority rule for operation replies and static read/error envelopes.
pub fn validateInvocationDiagnostic(status: u16, version: []const u8, diagnostic: InvocationDiagnostic) error{InvalidResponse}!void {
    if (status == 200 or !std.mem.eql(u8, version, "1") or diagnostic.type.len == 0 or diagnostic.code.len == 0) return error.InvalidResponse;
    if (diagnostic.code.eql("canonical_store_failure") and (status != 500 or !diagnostic.type.eql("invocation_error"))) return error.InvalidResponse;
}

// Remaining snapshot/report/Action callers check canonical failure here;
// mutation and keyed-read callers own diagnostics from their envelope parse.
pub fn checkCanonicalFailure(reply: CommandReply) !void {
    if (reply.status == 200) return;
    if (reply.body.len > protocol.max_response_bytes) return error.InvalidResponse;
    const Envelope = struct {
        const Field = enum {
            other,
            version_1,
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
                if (std.mem.eql(u8, value, "1")) return .version_1;
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
        error.OutOfMemory => unreachable, // The bounded-storage proof above covers every input.
        else => return error.InvalidResponse,
    };
    // Unknown values receive full syntax validation but no duplicate-key policy;
    // version, type and code alone establish invocation-error authority.
    if (envelope.code == .canonical) {
        var diagnostic: InvocationDiagnostic = .{ .type = .{}, .code = .{} };
        diagnostic.code.set("canonical_store_failure") catch unreachable;
        if (envelope.type == .invocation_error) diagnostic.type.set("invocation_error") catch unreachable;
        try validateInvocationDiagnostic(reply.status, if (envelope.version == .version_1) "1" else "", diagnostic);
        return error.CanonicalStoreFailure;
    }
}

test "canonical failure classifier validates complete string-only error envelope" {
    const canonical = [_][]const u8{
        "{\"version\":\"1\",\"type\":\"invocation_error\",\"code\":\"canonical_store_failure\"}",
        "{\"vers\\u0069on\":\"1\",\"ty\\u0070e\":\"invocation_\\u0065rror\",\"co\\u0064e\":\"canonical_store_\\u0066ailure\",\"extra\":[1,{}]}",
        "{\"version\":\"1\",\"type\":\"invocation_error\",\"code\":\"canonical_store_failure\",\"extra\":{\"x\":1,\"x\":2},\"extra\":null}",
    };
    for (canonical) |body| try std.testing.expectError(error.CanonicalStoreFailure, checkCanonicalFailure(.{ .status = 500, .body = body }));
    const prefix = "{\"version\":\"1\",\"type\":\"invocation_error\",";
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
        "{\"version\":\"2\",\"type\":\"invocation_error\",\"code\":\"canonical_store_failure\"}",
        "{\"version\":\"1\",\"type\":\"message_reply\",\"code\":\"canonical_store_failure\"}",
        "{\"version\":\"1\",\"vers\\u0069on\":\"1\",\"type\":\"invocation_error\",\"code\":\"canonical_store_failure\"}",
        "{\"version\":\"1\",\"type\":\"invocation_error\",\"ty\\u0070e\":\"message_reply\",\"code\":\"canonical_store_failure\"}",
        "{\"version\":null,\"type\":\"invocation_error\",\"code\":\"canonical_store_failure\"}",
        "{\"version\":\"1\",\"type\":[105],\"code\":\"canonical_store_failure\"}",
        "{\"answer\":{\"code\":\"canonical_store_failure\",\"extra\":[}}",
    }) |body| try std.testing.expectError(error.InvalidResponse, checkCanonicalFailure(.{ .status = 500, .body = body }));
    for ([_][]const u8{
        "{}",
        "{\"version\":\"1\",\"type\":\"message_reply\",\"answer\":{\"status\":\"infrastructure_failure\",\"code\":\"canonical_store_failure\"}}",
        "{\"version\":\"1\",\"type\":\"invocation_error\",\"code\":\"unavailable\",\"answer\":{\"code\":\"canonical_store_failure\"}}",
        "{\"answer\":{\"code\":\"unavailable\"}}",
        "{\"answer\":{\"extra\":{\"code\":\"canonical_store_failure\"}}}",
        "{\"extra\":{\"answer\":{\"code\":\"canonical_store_failure\"}}}",
    }) |body| try checkCanonicalFailure(.{ .status = 500, .body = body });
    const body = "{\"version\":\"1\",\"type\":\"invocation_error\",\"code\":\"canonical_store_failure\"}";
    try std.testing.expectError(error.InvalidResponse, checkCanonicalFailure(.{ .status = 409, .body = body }));
}

test "canonical failure classifier bounds deep wide and escaped maximum replies" {
    const prefix = "{\"version\":\"1\",\"type\":\"invocation_error\",\"code\":\"canonical_store_failure\",\"extra\":";
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

    // A nearly maximum escaped field name must be released before code decode.
    const field_prefix = "{\"";
    const field_suffix = "\":0,\"version\":\"1\",\"type\":\"invocation_error\",\"co\\u0064e\":\"canonical_store_\\u0066ailure\"}";
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
    // Discarded wide objects validate syntax, not irrelevant key uniqueness.
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
    // Consecutive escaped names must not accumulate decoded allocations.
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

test "Session list facts own complete rows and render semantic output after scratch reuse" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "page", .{ .read = true });
    defer file.close(io);
    const wire = "{\"version\":\"1\",\"type\":\"session_list\",\"sessions\":[{\"reference\":\"k7m2q\\u0078\",\"workspace\":\"/w\\nµ\",\"provider\":\"codex\",\"model\":\"m\\\"\",\"tools\":[\"bash\"],\"permission_mode\":\"ask\",\"extra\":[null,{\"discard\":true}]}],\"next\":null,\"extra\":1}";
    try file.writePositionalAll(io, wire, 0);
    const decoded = try SessionListReply.decode(io, file, "/w\nµ", .{}, .{ .report = .{ .bytes = wire.len } });
    const page = &decoded.page;
    try file.writePositionalAll(io, &@as([wire.len]u8, @splat('x')), 0);
    try std.testing.expectEqual(@as(usize, 1), page.count);
    try std.testing.expectEqualStrings("k7m2qx", page.rows[0].reference.slice());
    try std.testing.expectEqualStrings("/w\nµ", page.rows[0].workspace.slice());
    var output: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    try page.writeJson(&writer);
    try std.testing.expectEqualStrings("{\"version\":\"1\",\"type\":\"session_list\",\"sessions\":[{\"reference\":\"k7m2qx\",\"workspace\":\"/w\\nµ\",\"provider\":\"codex\",\"model\":\"m\\\"\",\"tools\":[\"bash\"],\"permission_mode\":\"ask\"}],\"next\":null}", writer.buffered());
    var exhausted = std.Io.Writer.fixed(&.{});
    try std.testing.expectError(error.WriteFailed, page.writeJson(&exhausted));
}

test "Session list reply owns read failure facts without asserting absence or admission" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "empty-report", .{ .read = true });
    defer file.close(io);
    var wire = "{\"version\":\"1\",\"type\":\"busy\",\"code\":\"ordinary_capacity_exhausted\",\"extension\":null}".*;
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
    const wire = "{\"version\":\"1\",\"type\":\"session_list\",\"sessions\":[],\"next\":null}";
    try file.writePositionalAll(io, wire, 0);
    try std.testing.expectError(error.InvalidSessionPage, SessionListReply.decode(io, file, null, .{}, .{ .report = .{ .bytes = 0 } }));
}

test "Session list byte range reads a shorter overwritten prefix without changing borrowed storage" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "page", .{ .read = true });
    defer file.close(io);
    const old = "{\"version\":\"1\",\"type\":\"session_list\",\"sessions\":[{\"reference\":\"old\",\"workspace\":\"/w\",\"provider\":\"codex\",\"model\":\"m\",\"tools\":[],\"permission_mode\":\"ask\"}],\"next\":null}";
    const current = "{\"version\":\"1\",\"type\":\"session_list\",\"sessions\":[],\"next\":null}";
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
    const wire = "{\"version\":\"1\",\"type\":\"session_list\",\"sessions\":[],\"next\":null}";
    try file.writePositionalAll(io, wire, 0);
    try std.testing.expectError(error.InvalidSessionPage, SessionListReply.decode(io, file, null, .{}, .{ .report = .{ .bytes = wire.len + 1 } }));
}

test "Session list byte range rejects a promise excluding the final delimiter" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "page", .{ .read = true });
    defer file.close(io);
    const wire = "{\"version\":\"1\",\"type\":\"session_list\",\"sessions\":[],\"next\":null}";
    try file.writePositionalAll(io, wire, 0);
    try std.testing.expectError(error.InvalidSessionPage, SessionListReply.decode(io, file, null, .{}, .{ .report = .{ .bytes = wire.len - 1 } }));
}

test "Session list byte range validates junk inside and ignores junk outside the promise" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "page", .{ .read = true });
    defer file.close(io);
    const wire = "{\"version\":\"1\",\"type\":\"session_list\",\"sessions\":[],\"next\":null}";
    try file.writePositionalAll(io, wire ++ "false", 0);
    try std.testing.expectError(error.InvalidSessionPage, SessionListReply.decode(io, file, null, .{}, .{ .report = .{ .bytes = wire.len + 5 } }));
    const reply = try SessionListReply.decode(io, file, null, .{}, .{ .report = .{ .bytes = wire.len } });
    try std.testing.expectEqual(@as(usize, 0), reply.page.count);
    try file.writePositionalAll(io, wire ++ " \n\r", 0);
    const spaced = try SessionListReply.decode(io, file, null, .{}, .{ .report = .{ .bytes = wire.len + 3 } });
    try std.testing.expectEqual(@as(usize, 0), spaced.page.count);
}

test "Session list facts reject malformed metadata and consequential ambiguity" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const row = "{\"reference\":\"k7m2qx\",\"workspace\":\"/other\",\"provider\":\"codex\",\"model\":\"m\",\"tools\":[],\"permission_mode\":\"ask\"}";
    inline for (.{
        "{\"version\":\"2\",\"type\":\"session_list\",\"sessions\":[],\"next\":null}",
        "{\"version\":\"1\",\"type\":\"session_list\",\"type\":\"session_list\",\"sessions\":[],\"next\":null}",
        "{\"version\":\"1\",\"type\":\"session_list\",\"sessions\":[]}",
        "{\"version\":\"1\",\"type\":\"session_list\",\"sessions\":[],\"next\":null}false",
        "{\"version\":\"1\",\"type\":\"session_list\",\"sessions\":[],\"next\":{\"after\":\"7\",\"ceiling\":\"11\"}}",
        "{\"version\":\"1\",\"type\":\"session_list\",\"sessions\":[" ++ row ++ "," ++ row ++ "],\"next\":null}",
    }, 0..) |wire, index| {
        const file = try tmp.dir.createFile(io, std.fmt.comptimePrint("page-{d}", .{index}), .{ .read = true });
        defer file.close(io);
        try file.writePositionalAll(io, wire, 0);
        try std.testing.expectError(error.InvalidSessionPage, SessionListPage.read(io, file, wire.len, null, .{}));
    }
    const prefix = "{\"version\":\"1\",\"type\":\"session_list\",\"sessions\":[{\"reference\":\"k7m2qx\",\"workspace\":\"/other\",\"provider\":\"codex\",\"model\":\"m\",";
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
        const wire = prefix ++ suffix ++ "}],\"next\":null}";
        try file.writePositionalAll(io, wire, 0);
        try std.testing.expectError(error.InvalidSessionPage, SessionListPage.read(io, file, wire.len, null, .{}));
    }
}

test "Session list terminal cursor accepts only empty rows without rejecting initial or continuing pages" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "terminal", .{ .read = true });
    defer file.close(io);
    const wire = "{\"version\":\"1\",\"type\":\"session_list\",\"sessions\":[{\"reference\":\"k7m2qx\",\"workspace\":\"/w\",\"provider\":\"codex\",\"model\":\"m\",\"tools\":[],\"permission_mode\":\"ask\"}],\"next\":null}";
    try file.writePositionalAll(io, wire, 0);
    inline for (.{ SessionListCursor{}, SessionListCursor{ .after = 7, .ceiling = 8 } }) |cursor| {
        const reply = try SessionListReply.decode(io, file, null, cursor, .{ .report = .{ .bytes = wire.len } });
        try std.testing.expectEqual(@as(usize, 1), reply.page.count);
        try std.testing.expectEqual(@as(?SessionListCursor, null), reply.page.next);
    }
    try std.testing.expectError(error.InvalidSessionPage, SessionListReply.decode(io, file, null, .{ .after = 7, .ceiling = 7 }, .{ .report = .{ .bytes = wire.len } }));
    const empty = "{\"version\":\"1\",\"type\":\"session_list\",\"sessions\":[],\"next\":null}";
    try file.writePositionalAll(io, empty, 0);
    const reply = try SessionListReply.decode(io, file, null, .{ .after = 7, .ceiling = 7 }, .{ .report = .{ .bytes = empty.len } });
    try std.testing.expectEqual(@as(usize, 0), reply.page.count);
    try std.testing.expectEqual(@as(?SessionListCursor, null), reply.page.next);
}

test "Session list facts attain eight maximum escaped rows and bind the continuation cohort" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "maximum", .{ .read = true });
    defer file.close(io);
    var workspace = @as([protocol.max_workspace_bytes]u8, @splat(1));
    workspace[0] = '/';
    const model = @as([protocol.max_model_bytes]u8, @splat(1));
    var bytes: [protocol.content_window_bytes]u8 = undefined;
    var output = file.writerStreaming(io, &bytes);
    const writer = &output.interface;
    try writer.writeAll("{\"version\":\"1\",\"type\":\"session_list\",\"sessions\":[");
    for (0..8) |index| {
        if (index != 0) try writer.writeAll(",");
        var reference = "000000".*;
        reference[0] = @intCast('0' + index);
        try writer.writeAll("{\"reference\":");
        try std.json.Stringify.value(&reference, .{}, writer);
        try writer.writeAll(",\"workspace\":");
        try std.json.Stringify.value(&workspace, .{}, writer);
        try writer.writeAll(",\"provider\":\"codex\",\"model\":");
        try std.json.Stringify.value(&model, .{}, writer);
        try writer.writeAll(",\"tools\":[\"bash\"],\"permission_mode\":\"bypass\"}");
    }
    try writer.writeAll("],\"next\":{\"after\":\"19\",\"ceiling\":\"23\"}}");
    try writer.flush();
    const length = try file.length(io);
    try std.testing.expect(length > protocol.content_window_bytes);
    const page = try SessionListPage.read(io, file, length, &workspace, .{ .after = 11, .ceiling = 23 });
    try std.testing.expectEqual(@as(usize, 8), page.count);
    try std.testing.expectEqual(@as(u64, 19), page.next.?.after);
    try std.testing.expectEqual(@as(u64, 23), page.next.?.ceiling);
    for (page.rows[0..8], 0..) |*row, index| {
        try std.testing.expectEqual(@as(u8, @intCast('0' + index)), row.reference.bytes[0]);
        try std.testing.expectEqual(protocol.session_id_bytes, row.reference.len);
        try std.testing.expectEqualStrings(&workspace, row.workspace.slice());
        try std.testing.expectEqualStrings(&model, row.model.slice());
        try std.testing.expect(row.tools.bash and row.permission_mode == .bypass);
    }
    try std.testing.expectError(error.InvalidSessionPage, SessionListPage.read(io, file, length, "/wrong", .{}));
    try std.testing.expectError(error.InvalidSessionPage, SessionListPage.read(io, file, length, null, .{ .after = 19, .ceiling = 23 }));
    try std.testing.expectError(error.InvalidSessionPage, SessionListPage.read(io, file, length, null, .{ .after = 11, .ceiling = 29 }));
    // A next cursor needs a ninth row strictly beyond the eighth row's after.
    const tail = "],\"next\":{\"after\":\"19\",\"ceiling\":\"23\"}}";
    const prefix_length = length - tail.len;
    try file.writePositionalAll(io, "],\"next\":{\"after\":\"23\",\"ceiling\":\"23\"}}", prefix_length);
    try std.testing.expectError(error.InvalidSessionPage, SessionListReply.decode(io, file, &workspace, .{}, .{ .report = .{ .bytes = length } }));
    // Eight rows with no ninth row are valid, as is a terminal request probe.
    const terminal = "],\"next\":null}";
    try file.writePositionalAll(io, terminal, prefix_length);
    const last = try SessionListReply.decode(io, file, &workspace, .{}, .{ .report = .{ .bytes = prefix_length + terminal.len } });
    try std.testing.expectEqual(@as(usize, 8), last.page.count);
    try std.testing.expectEqual(@as(?SessionListCursor, null), last.page.next);
    try (SessionListCursor{ .after = 23, .ceiling = 23 }).validate();
}

test "keyed observation retains request acceptance independently of later work" {
    const address = try MessageAddress.init("/store", "k7m2qx", "k");
    const prefix = "{\"version\":\"1\",\"type\":\"command_observation\",\"key\":\"k\",\"observation\":{\"kind\":\"message\",\"target\":\"k7m2qx\",\"status\":\"accepted\",\"input\":{\"type\":\"text\",\"bytes\":\"11\",\"sha256\":\"" ++ @as([64]u8, @bitCast(@as([32][2]u8, @splat("ab".*)))) ++ "\"},\"queue\":{\"status\":\"processing\",\"admission\":\"23\"},\"processing\":{\"turn\":\"37\",\"operation\":\"41\",\"attempt\":\"0\"}";
    inline for (.{
        .{ "}}", CommandObservation.State.processing },
        .{ ",\"result\":{\"status\":\"completed\",\"text\":{\"type\":\"text\",\"bytes\":\"19\",\"sha256\":\"" ++ @as([64]u8, @bitCast(@as([32][2]u8, @splat("cd".*)))) ++ "\"}},\"progress\":{\"status\":\"waiting_for_permission\",\"action\":\"91\"}}}", CommandObservation.State.completed },
        .{ ",\"result\":{\"status\":\"failed\",\"code\":\"provider_http_422\"}}}", CommandObservation.State.failed },
        .{ ",\"result\":{\"status\":\"cancelled\",\"code\":\"cancelled\"}}}", CommandObservation.State.cancelled },
    }) |case| {
        const observed = try (try CommandObservation.parse(.{ .status = 200, .body = prefix ++ case[0] }, "k")).forMessage(&address);
        try std.testing.expectEqual(.accepted, observed.status);
        try std.testing.expectEqual(case[1], observed.state());
        try std.testing.expectEqual(@as(u64, 37), observed.processing.?.turn);
        try std.testing.expectEqual(@as(u64, 41), observed.processing.?.operation);
        try std.testing.expectEqual(@as(u64, 0), observed.processing.?.attempt);
        try std.testing.expectEqual(@as(u64, 23), observed.queue.?.admission);
        if (observed.state() == .completed) try std.testing.expectEqual(@as(u64, 19), observed.result.?.text.?.bytes);
        var output: [protocol.max_response_bytes]u8 = undefined;
        var writer = std.Io.Writer.fixed(&output);
        try observed.writeJson(&writer);
        const json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, writer.buffered(), .{});
        defer json.deinit();
        try std.testing.expectEqualStrings("accepted", json.value.object.get("status").?.string);
    }
}

test "keyed observation distinguishes named statuses and omitted fields from numeric tags and null" {
    const prefix = "{\"version\":\"1\",\"type\":\"command_observation\",\"key\":\"k\",\"observation\":{\"target\":\"k7m2qx\",\"code\":\"unknown_session\",";
    inline for (.{ "\"status\":2,\"kind\":\"message\"}}", "\"status\":\"2\",\"kind\":\"message\"}}", "\"status\":\"rejected\",\"kind\":1}}" }) |fields|
        try std.testing.expectError(error.InvalidObservation, CommandObservation.parse(.{ .status = 200, .body = prefix ++ fields }, "k"));
    const absent = "{\"version\":\"1\",\"type\":\"command_observation\",\"key\":\"k\",\"observation\":{\"status\":\"absent\"";
    inline for (.{ "kind", "target", "code", "revision", "created", "input", "queue", "processing", "result", "progress", "selection", "completion", "interruption_target", "permission_target" }) |field|
        try std.testing.expectError(error.InvalidObservation, CommandObservation.parse(.{ .status = 200, .body = absent ++ ",\"" ++ field ++ "\":null}}" }, "k"));
}

test "keyed observation validates all five operation shapes and binding" {
    const prefix = "{\"version\":\"1\",\"type\":\"command_observation\",\"key\":\"k\",\"observation\":{\"target\":\"k7m2qx\",";
    inline for (.{
        .{ "configure", ",\"revision\":\"31\",\"created\":true", "" },
        .{ "message", ",\"input\":{\"type\":\"text\",\"bytes\":\"0\",\"sha256\":\"" ++ @as([64]u8, @splat('0')) ++ "\"},\"queue\":{\"status\":\"queued\",\"admission\":\"13\"}", "" },
        .{ "session_stop", ",\"selection\":{\"turn\":null,\"admission_cutoff\":\"0\"},\"completion\":{\"status\":\"completed\"}", "" },
        .{ "model_interruption", ",\"interruption_target\":{\"session\":\"k7m2qx\",\"turn\":\"3\",\"operation\":\"7\"}", ",\"interruption_target\":{\"session\":\"k7m2qx\",\"turn\":\"0\",\"operation\":\"0\"}" },
        .{ "permission_decision", ",\"permission_target\":{\"action\":\"29\",\"decision\":\"allow_once\"}", ",\"permission_target\":{\"action\":\"0\",\"decision\":\"deny\"}" },
    }) |case| {
        const accepted = prefix ++ "\"kind\":\"" ++ case[0] ++ "\",\"status\":\"accepted\"" ++ case[1] ++ "}}";
        const observed = try CommandObservation.parse(.{ .status = 200, .body = accepted }, "k");
        try std.testing.expectEqualStrings(case[0], @tagName(observed.kind.?));
        try std.testing.expectEqual(.accepted, observed.status);
        var output: [protocol.max_response_bytes]u8 = undefined;
        var writer = std.Io.Writer.fixed(&output);
        try observed.writeJson(&writer);
        try std.testing.expectEqualStrings("{\"status\":\"accepted\",\"kind\":\"" ++ case[0] ++ "\",\"target\":\"k7m2qx\"" ++ case[1] ++ "}", writer.buffered());
        try std.testing.expectError(error.RequestBindingMismatch, CommandObservation.parse(.{ .status = 200, .body = accepted }, "other"));
        const rejected = try CommandObservation.parse(.{ .status = 200, .body = prefix ++ "\"kind\":\"" ++ case[0] ++ "\",\"status\":\"rejected\",\"code\":\"unknown_session\"" ++ case[2] ++ "}}" }, "k");
        try std.testing.expectEqual(.rejected, rejected.status);
        try std.testing.expectEqualStrings("unknown_session", rejected.failureCode().?);
        writer = std.Io.Writer.fixed(&output);
        try rejected.writeJson(&writer);
        try std.testing.expectEqualStrings("{\"status\":\"rejected\",\"kind\":\"" ++ case[0] ++ "\",\"target\":\"k7m2qx\",\"code\":\"unknown_session\"" ++ case[2] ++ "}", writer.buffered());
        // Missing operation-specific metadata must not turn into confirmation.
        try std.testing.expectError(error.InvalidObservation, CommandObservation.parse(.{ .status = 200, .body = prefix ++ "\"kind\":\"" ++ case[0] ++ "\",\"status\":\"accepted\"}}" }, "k"));
        const empty = "{\"version\":\"1\",\"type\":\"command_observation\",\"key\":\"k\",\"observation\":{\"kind\":\"" ++ case[0] ++ "\",\"target\":\"\",\"status\":\"";
        try std.testing.expectError(error.InvalidObservation, CommandObservation.parse(.{ .status = 200, .body = empty ++ "accepted\"" ++ case[1] ++ "}}" }, "k"));
        if (!std.mem.eql(u8, case[0], "configure") and !std.mem.eql(u8, case[0], "message"))
            try std.testing.expectError(error.InvalidObservation, CommandObservation.parse(.{ .status = 200, .body = empty ++ "rejected\",\"code\":\"invalid_session_reference\"" ++ case[2] ++ "}}" }, "k"));
    }
    inline for (.{ "configure", "message" }) |kind| {
        const creation = "{\"version\":\"1\",\"type\":\"command_observation\",\"key\":\"k\",\"observation\":{\"kind\":\"" ++ kind ++ "\",\"status\":\"rejected\",\"code\":\"";
        inline for (.{ "invalid_workspace", "model_capability_unavailable" }) |code| {
            const body = creation ++ code ++ "\",\"target\":\"\"}}";
            const rejected = try CommandObservation.parse(.{ .status = 200, .body = body }, "k");
            try std.testing.expectEqual(.rejected, rejected.status);
            try std.testing.expectEqualStrings("", rejected.target.?.slice());
            try std.testing.expectEqualStrings(code, rejected.failureCode().?);
            inline for (.{ "", ",\"target\":null", ",\"target\":17" }) |target|
                try std.testing.expectError(error.InvalidObservation, CommandObservation.parse(.{ .status = 200, .body = creation ++ code ++ "\"" ++ target ++ "}}" }, "k"));
        }
    }
    const absent = try CommandObservation.parse(.{ .status = 200, .body = "{\"version\":\"1\",\"type\":\"command_observation\",\"key\":\"k\",\"observation\":{\"status\":\"absent\"}}" }, "k");
    const address = try MessageAddress.init("/store", "k7m2qx", "k");
    try std.testing.expectError(error.RequestNotAdmitted, absent.forMessage(&address));
    const rejection = try CommandObservation.parse(.{ .status = 200, .body = prefix ++ "\"kind\":\"message\",\"status\":\"rejected\",\"code\":\"unknown_session\"}}" }, "k");
    const other = try MessageAddress.init("/store", "09azvw", "k");
    try std.testing.expectError(error.RequestBindingMismatch, rejection.forMessage(&other));
}

test "keyed observation rejects malformed consequential fields before outcome interpretation" {
    const prefix = "{\"version\":\"1\",\"type\":\"command_observation\",\"key\":\"k\",\"observation\":{\"kind\":\"message\",\"target\":\"k7m2qx\",\"status\":\"accepted\",\"input\":{\"type\":\"text\",\"bytes\":\"1\",\"sha256\":\"" ++ @as([64]u8, @bitCast(@as([32][2]u8, @splat("ab".*)))) ++ "\"},\"queue\":{\"status\":\"queued\",\"admission\":\"7\"}";
    inline for (.{
        ",\"processing\":null}}",                              ",\"processing\":{}}}",                                      ",\"processing\":{\"turn\":7}}}",
        ",\"result\":{\"status\":\"processing\"}}}",           ",\"result\":{\"status\":\"completed\"}}}",                  ",\"result\":{\"status\":\"failed\",\"code\":17}}}",
        ",\"result\":{\"status\":\"failed\",\"code\":null}}}", ",\"progress\":{\"status\":\"invented\",\"action\":null}}}", ",\"progress\":{\"status\":\"waiting_for_permission\",\"action\":null}}}",
        ",\"progress\":{\"status\":\"in_flight\"}}}",          ",\"progress\":{\"status\":\"in_flight\",\"action\":17}}}",  ",\"result\":{\"status\":\"failed\",\"code\":\"saved_failure\"},\"progress\":false}}",
        ",\"revision\":\"1\"}}",                               ",\"code\":null}}",                                          ",\"target\":null}}",
    }) |suffix| try std.testing.expectError(error.InvalidObservation, CommandObservation.parse(.{ .status = 200, .body = prefix ++ suffix }, "k"));
    inline for (.{ "0", "+7", "07", "18446744073709551616" }) |id|
        try std.testing.expectError(error.InvalidResponse, CommandObservation.parse(.{ .status = 200, .body = prefix ++ ",\"progress\":{\"status\":\"in_flight\",\"action\":\"" ++ id ++ "\"}}}" }, "k"));
    inline for (.{ "{}", "[]", "{\"version\":\"2\"}", "{\"version\":\"1\",\"type\":\"wrong\"}" }) |body|
        try std.testing.expectError(error.InvalidObservation, CommandObservation.parse(.{ .status = 200, .body = body }, "k"));
    try std.testing.expectError(error.InvalidObservation, CommandObservation.parse(.{ .status = 200, .body = prefix ++ ",\"queue\":{\"status\":\"queued\",\"admission\":\"9\"}}}" }, "k"));
    var oversized: [protocol.max_response_bytes + 1]u8 = undefined;
    try std.testing.expectError(error.ResponseTooLarge, CommandObservation.parse(.{ .status = 200, .body = &oversized }, "k"));
}

test "keyed observation owns supported strings without retaining unknown DOM across polls" {
    const observation = "{\"status\":\"rejected\",\"kind\":\"message\",\"target\":\"s/µ\",\"code\":\"line\\ncode\"}";
    const body = "{\"version\":\"1\",\"type\":\"command_observation\",\"key\":\"k\",\"observation\":{\"status\":\"rejected\",\"kind\":\"message\",\"target\":\"s\\u002fµ\",\"code\":\"line\\ncode\",\"unknown\":{\"precise\":123456789012345678901234567890,\"items\":[true,null,\"discard\"]}}}";
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
    const wire = "{\"version\":\"1\",\"type\":\"busy\",\"code\":\"ordinary_capacity_exhausted\",\"unknown\":[1,2,3]}";
    var storage = wire.*;
    const busy = try decodeReadFailure(.{ .status = 503, .body = &storage }, false);
    @memset(&storage, 'x');
    try std.testing.expectEqual(@as(u16, 503), busy.status);
    try std.testing.expectEqualStrings("ordinary_capacity_exhausted", busy.diagnostic.code.slice());
    try std.testing.expectEqual(error.HostInvocationFailed, busy.err());
    const fatal = try decodeReadFailure(.{ .status = 500, .body = "{\"version\":\"1\",\"type\":\"invocation_error\",\"code\":\"canonical_store_failure\"}" }, false);
    try std.testing.expectEqual(error.CanonicalStoreFailure, fatal.err());
    inline for (.{ "result_not_found", "result_not_ready", "result_failed" }) |code| {
        const reply: CommandReply = .{ .status = 409, .body = "{\"version\":\"1\",\"type\":\"result_unavailable\",\"code\":\"" ++ code ++ "\"}" };
        try std.testing.expectEqualStrings(code, (try decodeReadFailure(reply, true)).diagnostic.code.slice());
        try std.testing.expectError(error.InvalidResponse, decodeReadFailure(reply, false));
    }
    inline for (.{ "null", "{}" }) |value|
        try std.testing.expectError(error.InvalidResponse, decodeReadFailure(.{ .status = 500, .body = "{\"version\":\"1\",\"type\":\"invocation_error\",\"code\":\"canonical_store_failure\",\"observation\":" ++ value ++ "}" }, false));
    std.debug.print("keyed facts bytes={d}; reply bytes={d}; fixed parser scratch={d}; no retained allocator/DOM\n", .{
        @sizeOf(CommandObservation), @sizeOf(protocol.ResponseBuffer), std.ArrayList(u8).growCapacity((protocol.max_response_bytes + 7) / 8) + std.ArrayList(u8).growCapacity(protocol.max_response_bytes),
    });
}

test "Current facts preserve explicit unconfigured and promised range" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "current", .{ .read = true });
    defer file.close(io);
    const wire = "{\"version\":\"1\",\"type\":\"session_report\",\"profile\":\"current\",\"session\":null,\"pending_messages\":\"0\",\"execution\":{\"status\":\"unavailable\",\"reason\":\"session_not_found\"}}";
    try file.writePositionalAll(io, wire ++ "false", 0);
    try std.testing.expect((try CurrentReply.decode(io, file, "unknown", .{ .report = .{ .bytes = wire.len } })) == .unconfigured);
    inline for (.{ 0, wire.len - 1, wire.len + 1, wire.len + 6 }) |length|
        try std.testing.expectError(error.InvalidObservation, CurrentReply.decode(io, file, "unknown", .{ .report = .{ .bytes = length } }));
}

test "Current settings preserve decimal token heuristics in projections" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "current", .{ .read = true });
    defer file.close(io);
    const wire = "{\"reference\":\"k7m2qx\",\"workspace\":\"/w\",\"provider\":\"codex\",\"model\":\"m\",\"revision\":\"1\",\"tools\":[],\"permission_mode\":\"ask\",\"instructions\":{\"bytes\":\"0\",\"sha256\":\"" ++ @as([64]u8, @splat('0')) ++ "\"},\"output_schema\":null,\"reasoning_effort\":\"high\",\"reasoning_effort_override\":\"high\",\"compaction_trigger\":\"100000\",\"output_reservation\":\"16384\",\"compaction_trigger_override\":null,\"output_reservation_override\":null}";
    const report = "{\"version\":\"1\",\"type\":\"session_report\",\"profile\":\"current\",\"session\":" ++ wire ++ ",\"pending_messages\":\"0\",\"work\":{\"status\":\"idle\",\"latest_outcome\":null},\"selected_message\":null,\"recent_messages\":[],\"actions\":{\"count\":\"0\",\"unresolved\":[],\"resolved\":[]},\"rejected_calls\":{\"count\":\"0\",\"items\":[]},\"actionable_permissions\":[],\"execution\":{\"status\":\"partial\",\"dispatch_fenced\":false,\"custody_occupied\":\"0\",\"scratch_used_bytes\":\"0\",\"unavailable\":[\"structured_output\"]}}";
    try file.writePositionalAll(io, report, 0);
    const reply = try CurrentReply.decode(io, file, "k7m2qx", .{ .report = .{ .bytes = report.len } });
    try std.testing.expectEqualStrings("100000", reply.current.settings.compaction_trigger.?.slice());
    try std.testing.expectEqualStrings("16384", reply.current.settings.output_reservation.slice());
    try std.testing.expectEqual(protocol.ReasoningEffort.high, reply.current.settings.reasoning_effort.?.value);
    try std.testing.expectEqual(protocol.ReasoningEffort.high, reply.current.settings.reasoning_effort_override.?.value);
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try reply.current.writeJson(io, file, &writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\"compaction_trigger\":\"100000\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\"output_reservation\":\"16384\"") != null);
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
        .{ .suffix = ",\"compaction_trigger\":null,\"output_reservation\":\"0\",\"output_reservation_override\":null}", .valid = false },
        .{ .suffix = ",\"compaction_trigger\":null,\"compaction_trigger_override\":null,\"output_reservation_override\":null}", .valid = false },
        .{ .suffix = ",\"output_reservation\":\"0\",\"compaction_trigger_override\":null,\"output_reservation_override\":null}", .valid = false },
        .{ .suffix = ",\"compaction_trigger\":null,\"output_reservation\":\"0\",\"compaction_trigger_override\":null,\"output_reservation_override\":null}", .valid = true },
        .{ .suffix = ",\"compaction_trigger\":\"42\",\"output_reservation\":\"0\",\"compaction_trigger_override\":\"42\",\"output_reservation_override\":\"0\"}", .valid = true },
        .{ .suffix = ",\"compaction_trigger\":\"0\",\"output_reservation\":\"0\",\"compaction_trigger_override\":null,\"output_reservation_override\":null}", .valid = false },
        .{ .suffix = ",\"compaction_trigger\":null,\"output_reservation\":null,\"compaction_trigger_override\":null,\"output_reservation_override\":null}", .valid = false },
        .{ .suffix = ",\"compaction_trigger\":null,\"output_reservation\":\"0\",\"compaction_trigger_override\":\"0\",\"output_reservation_override\":null}", .valid = false },
        .{ .suffix = ",\"compaction_trigger\":null,\"output_reservation\":\"0\",\"compaction_trigger_override\":null,\"output_reservation_override\":\"-1\"}", .valid = false },
        .{ .suffix = ",\"compaction_trigger\":null,\"output_reservation\":\"01\",\"compaction_trigger_override\":null,\"output_reservation_override\":null}", .valid = false },
        .{ .suffix = ",\"compaction_trigger\":null,\"output_reservation\":1,\"compaction_trigger_override\":null,\"output_reservation_override\":null}", .valid = false },
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
    const reference = "{\"bytes\":\"7\",\"sha256\":\"" ++ @as([64]u8, @bitCast(@as([4][16]u8, @splat("0123456789abcdef".*)))) ++ "\"}";
    try writer.writeAll("{\"version\":\"1\",\"type\":\"session_report\",\"profile\":\"current\",\"session\":{\"reference\":\"k7m2qx\",\"workspace\":\"/w\",\"provider\":\"codex\",\"model\":\"exact\\u0001model\",\"revision\":\"17\",\"tools\":[],\"permission_mode\":\"ask\",\"instructions\":" ++ reference ++ ",\"output_schema\":null,\"reasoning_effort\":null,\"reasoning_effort_override\":null,\"compaction_trigger\":null,\"output_reservation\":\"0\",\"compaction_trigger_override\":null,\"output_reservation_override\":null},\"pending_messages\":\"2\",\"work\":{\"status\":\"runnable\",\"turn\":\"37\",\"operation\":\"91\",\"latest_outcome\":{\"code\":\"failed_saved\",\"content\":null}},\"selected_message\":\"\",\"recent_messages\":[");
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
    try std.testing.expectEqual(@as(u64, 17), facts.settings.revision.value);
    try std.testing.expect(!facts.settings.tools.bash);
    try std.testing.expectEqual(@as(u64, 7), facts.settings.instructions.bytes.value);
    try std.testing.expect(facts.settings.reasoning_effort == null and facts.settings.reasoning_effort_override == null and facts.selected_message != null);
    try std.testing.expectEqualStrings("", facts.selected_message.?.slice());
    try std.testing.expectEqual(@as(u64, 91), facts.work.operation.value.?.value);
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
    try file.writePositionalAll(io, "x", 0);
    try std.testing.expectEqualStrings("exact\x01model", facts.settings.model.slice());
}

test "Current facts traverse every attention row and preserve metadata with fixed scratch" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "current", .{ .read = true });
    defer file.close(io);
    const rendered = try tmp.dir.createFile(io, "rendered", .{ .read = true });
    defer rendered.close(io);
    const reference = "{\"type\":\"text\",\"bytes\":\"13\",\"sha256\":\"" ++ @as([64]u8, @bitCast(@as([32][2]u8, @splat("ab".*)))) ++ "\"}";
    var buffer: [protocol.content_window_bytes]u8 = undefined;
    var output = file.writerStreaming(io, &buffer);
    const writer = &output.interface;
    try writer.writeAll("{\"version\":\"1\",\"type\":\"session_report\",\"profile\":\"current\",\"session\":{\"reference\":\"k7m2qx\",\"workspace\":\"/w\",\"provider\":\"codex\",\"model\":\"m\",\"revision\":\"17\",\"tools\":[\"bash\"],\"permission_mode\":\"ask\",\"instructions\":{\"bytes\":\"0\",\"sha256\":\"" ++ @as([64]u8, @splat('0')) ++ "\"},\"output_schema\":null,\"reasoning_effort\":null,\"reasoning_effort_override\":null,\"compaction_trigger\":null,\"output_reservation\":\"0\",\"compaction_trigger_override\":null,\"output_reservation_override\":null},\"pending_messages\":\"0\",\"work\":{\"status\":\"waiting_for_permission\",\"turn\":\"7\",\"operation\":\"19\",\"latest_outcome\":null},\"selected_message\":\"k\\n\",\"recent_messages\":[],\"actions\":{\"count\":\"515\",\"unresolved\":[");
    for (0..257) |i| {
        if (i != 0) try writer.writeAll(",");
        try writer.print("{{\"action\":\"{d}\",\"parent_operation\":\"19\",\"call_ordinal\":\"{d}\",\"tool\":\"bash\",\"permission_revision\":\"23\",\"authorization\":\"pending\",\"call_id\":", .{ i + 31, i });
        try writer.writeAll(reference ++ ",\"arguments\":" ++ reference ++ ",\"presentation\":{\"description\":\"Run parser tests\",\"code\":\"pending_permission\",\"publication_position\":null}}");
    }
    try writer.writeAll("],\"resolved\":[");
    for (0..257) |i| {
        if (i != 0) try writer.writeAll(",");
        try writer.print("{{\"action\":\"{d}\",\"parent_operation\":\"11\",\"call_ordinal\":\"{d}\",\"code\":\"indeterminate\",\"acceptance_position\":\"{d}\",\"result\":", .{ i + 1001, i, i + 71 });
        try writer.writeAll(reference ++ ",\"presentation\":{\"description\":\"Run parser tests\",\"code\":\"indeterminate\",\"publication_position\":null}}");
    }
    try writer.writeAll("]},\"rejected_calls\":{\"count\":\"257\",\"items\":[");
    for (0..257) |i| {
        if (i != 0) try writer.writeAll(",");
        try writer.print("{{\"parent_operation\":\"11\",\"call_ordinal\":\"{d}\",\"code\":\"unknown_tool\",\"acceptance_position\":\"{d}\",\"result\":", .{ i + 1000, i + 5001 });
        try writer.writeAll(reference ++ ",\"item_id\":" ++ reference ++ ",\"name\":" ++ reference ++ ",\"call_id\":" ++ reference ++ ",\"arguments\":" ++ reference ++ ",\"presentation\":{\"description\":null,\"code\":\"unknown_tool\",\"publication_position\":null}}");
    }
    try writer.writeAll("]},\"actionable_permissions\":[");
    for (0..257) |i| {
        if (i != 0) try writer.writeAll(",");
        try writer.print("{{\"action\":\"{d}\",\"permission_revision\":\"23\"}}", .{i + 31});
    }
    try writer.writeAll("],\"execution\":{\"status\":\"partial\",\"dispatch_fenced\":false,\"custody_occupied\":\"3\",\"scratch_used_bytes\":\"987\",\"unavailable\":[\"structured_output\"]},\"extension\":\"");
    try writer.splatByteAll('x', 20000);
    try writer.writeAll("\"}");
    try output.flush();
    const bytes = try file.length(io);
    const reply = try CurrentReply.decode(io, file, "k7m2qx", .{ .report = .{ .bytes = bytes } });
    const facts = &reply.current;
    try std.testing.expectEqual(@as(u64, 257), facts.actionable_count);
    try std.testing.expectEqual(@as(u64, 257), facts.indeterminate_count);
    try std.testing.expectEqual(@as(u64, 1001), facts.first_indeterminate.?);
    try std.testing.expect(facts.settings.reasoning_effort == null and facts.settings.reasoning_effort_override == null);
    const Sink = struct {
        counts: [4]usize = @splat(0),
        pub fn visit(self: *@This(), attention: Current.Attention) !void {
            const kind = @backingInt(attention);
            const i = self.counts[kind];
            switch (attention) {
                .unresolved => |row| {
                    try std.testing.expectEqual(@as(u64, 31 + i), row.action.value);
                    try std.testing.expectEqual(@as(u64, 19), row.parent_operation.value);
                    try std.testing.expectEqual(@as(u64, i), row.call_ordinal.value);
                    try std.testing.expectEqual(@as(u64, 13), row.arguments.bytes.value);
                    try std.testing.expectEqualStrings(&@as([64]u8, @bitCast(@as([32][2]u8, @splat("ab".*)))), row.call_id.sha256.slice());
                    try std.testing.expectEqualStrings("Run parser tests", row.presentation.value.description.?.slice());
                    try std.testing.expectEqual(protocol.ToolPresentation.Code.pending_permission, row.presentation.value.code);
                },
                .resolved => |row| {
                    try std.testing.expectEqual(@as(u64, 1001 + i), row.action.value);
                    try std.testing.expectEqual(@as(u64, 71 + i), row.acceptance_position.value);
                    try std.testing.expectEqualStrings("indeterminate", row.code.slice());
                    try std.testing.expect(row.presentation.value.publication_position == null);
                },
                .rejected => |row| {
                    try std.testing.expectEqual(@as(u64, 1000 + i), row.call_ordinal.value);
                    try std.testing.expectEqual(@as(u64, 5001 + i), row.acceptance_position.value);
                    try std.testing.expectEqualStrings("unknown_tool", row.code.slice());
                    try std.testing.expectEqual(@as(u64, 13), row.name.bytes.value);
                    try std.testing.expect(row.presentation.value.description == null);
                },
                .actionable => |row| {
                    try std.testing.expectEqual(@as(u64, 31 + i), row.action.value);
                    try std.testing.expectEqual(@as(u64, 23), row.permission_revision.value);
                },
            }
            self.counts[kind] += 1;
        }
    };
    var sink: Sink = .{};
    try facts.traverse(io, file, &sink);
    try std.testing.expectEqual([4]usize{ 257, 257, 257, 257 }, sink.counts);
    var json = rendered.writerStreaming(io, &buffer);
    try reply.writeJson(io, file, &json.interface);
    try json.flush();
    const roundtrip = try CurrentReply.decode(io, rendered, "k7m2qx", .{ .report = .{ .bytes = try rendered.length(io) } });
    var again: Sink = .{};
    try roundtrip.current.traverse(io, rendered, &again);
    try std.testing.expectEqual(sink.counts, again.counts);
    const Failing = struct {
        pub fn visit(_: @This(), _: Current.Attention) !void {
            return error.SinkFailed;
        }
    };
    try std.testing.expectError(error.SinkFailed, facts.traverse(io, file, Failing{}));
    try std.testing.expectError(error.InvalidObservation, CurrentReply.decode(io, file, "k7m2qx", .{ .report = .{ .bytes = bytes + 1 } }));
    var prefix: [2048]u8 = undefined;
    try std.testing.expectEqual(prefix.len, try file.readPositionalAll(io, &prefix, 0));
    inline for (.{
        .{ "\"version\":\"1\"", "\"version\":\"2\"" },
        .{ "\"tools\":[\"bash\"]", "\"tools\":[\"edit\"]" },
        .{ "\"turn\":\"7\"", "\"turn\":\"0\"" },
        .{ "\"operation\":\"19\"", "\"operation\":\"00\"" },
        .{ "\"selected_message\"", "\"ignored__message\"" },
        .{ "\"type\":\"text\"", "\"meta\":\"text\"" },
        .{ &@as([64]u8, @bitCast(@as([32][2]u8, @splat("ab".*)))), &@as([64]u8, @bitCast(@as([32][2]u8, @splat("xz".*)))) },
    }) |case| {
        const offset = std.mem.indexOf(u8, &prefix, case[0]).?;
        try file.writePositionalAll(io, case[1], offset);
        try std.testing.expectError(error.InvalidObservation, CurrentReply.decode(io, file, "k7m2qx", .{ .report = .{ .bytes = bytes } }));
        try file.writePositionalAll(io, case[0], offset);
    }
    try std.testing.expectEqual(bytes, try file.length(io));
    std.debug.print("Current facts={d}B, fixed scanner/token/input=16384B, capture={d}B; 4x257 rows, no population allocation\n", .{ @sizeOf(Current), bytes });
}
