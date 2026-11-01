//! The codecs this Host serves, by the codec name a Session pins, and the
//! job that runs a codec's request encoder in storage its caller owns.
const std = @import("std");
const codec_abi = @import("codec_abi.zig");
const protocol = @import("protocol.zig");
const responses = @import("codecs/responses.zig");

pub fn manifest(codec: protocol.Codec) *const codec_abi.Manifest {
    return switch (codec) {
        .@"openai-responses/1" => &responses.manifest,
    };
}

comptime {
    for (@typeInfo(protocol.Codec).@"enum".field_names) |name| {
        if (!manifest(@field(protocol.Codec, name)).valid()) @compileError("codec " ++ name ++ " observes a header that is not a lowercase token");
    }
}

/// The request encoder of a pinned codec.
pub fn encoder(codec: protocol.Codec) *const Encoder {
    return switch (codec) {
        .@"openai-responses/1" => &responses_encoder,
    };
}

const responses_encoder = native(responses.Encoder);

pub const max_state_bytes = 16;

/// A codec's encoder state, opaque to the Host.
pub const State = struct {
    bytes: [max_state_bytes]u8 align(8),
};

/// A request encoder linked into the Host. Each function works on a
/// `State` in a `Job`, never on a stack.
pub const Encoder = struct {
    /// Replace the whole state with the one `carry` holds; false when the
    /// codec cannot read it.
    load: *const fn (state: *State, carry: *const codec_abi.Carry) bool,
    /// Write the item's ops into `ops`, which starts empty.
    step: *const fn (state: *State, header: *const codec_abi.ItemHeader, ops: *codec_abi.Ops) codec_abi.Status,
};

/// The `Encoder` of a codec type with `load(*const Carry) !T` and
/// `encodeItem(*T, *const ItemHeader, *Ops) !Status`.
pub fn native(comptime Codec: type) Encoder {
    comptime std.debug.assert(@sizeOf(Codec) <= max_state_bytes and @alignOf(Codec) <= @alignOf(State));
    const adapter = struct {
        // A codec's error is its own fault, which the shell answers with
        // one code, provider_codec_failed; the contract carries no name.
        fn load(state: *State, carry: *const codec_abi.Carry) bool {
            of(state).* = Codec.load(carry) catch return false;
            return true;
        }

        // As in `load`: every error is the codec's, so it is `.failed`.
        fn step(state: *State, header: *const codec_abi.ItemHeader, ops: *codec_abi.Ops) codec_abi.Status {
            return of(state).encodeItem(header, ops) catch .failed;
        }

        fn of(state: *State) *Codec {
            return @ptrCast(&state.bytes);
        }
    };
    return .{ .load = adapter.load, .step = adapter.step };
}

/// One request's encoding, in its caller's storage for the request's life.
/// The caller writes `header` for each item, steps, and runs each op `next`
/// gives before it asks for another; once `next` gives null it writes the
/// next item.
pub const Job = struct {
    encoder: *const Encoder,
    state: State,
    /// The codec's state at the last history-element boundary: empty at
    /// the start, then each element's own carry, or a history memo's.
    carry: codec_abi.Carry,
    header: codec_abi.ItemHeader,
    ops: codec_abi.Ops,
    /// Where the item's next op begins.
    offset: u16,
    /// Whether the item's carry was read: nothing may follow it.
    carried: bool,

    pub const Error = error{ CodecFailed, CodecBadOp };

    pub fn begin(self: *Job, codec: *const Encoder) Error!void {
        self.encoder = codec;
        self.carry = .{ .len = 0 };
        if (!codec.load(&self.state, &self.carry)) return error.CodecFailed;
    }

    /// Continue after a history memo whose span ended in `carry`.
    pub fn resumeFrom(self: *Job, carry: *const codec_abi.Carry) void {
        self.carry = carry.*;
    }

    /// Encode the item in `header`. Before a history element and
    /// history_end the state is reloaded from the carry, so nothing else
    /// crosses a boundary and a memo copy continues exactly as a rebuild
    /// does.
    pub fn step(self: *Job) Error!void {
        const kind: codec_abi.ItemKind = self.header.item;
        if (kind.resumes() and !self.encoder.load(&self.state, &self.carry)) return error.CodecFailed;
        self.ops.length = 0;
        try self.open(self.encoder.step(&self.state, &self.header, &self.ops));
    }

    /// Done exactly at request_end; a failure is the codec's own.
    fn open(self: *Job, status: codec_abi.Status) Error!void {
        const kind: codec_abi.ItemKind = self.header.item;
        switch (status) {
            .failed => return error.CodecFailed,
            .next, .done => if ((status == .done) != (kind == .request_end)) return error.CodecBadOp,
        }
        self.offset = 0;
        self.carried = false;
    }

    /// The item's next op, judged as it is read: well formed; content only
    /// of the item's handles; a carry exactly once, as the last op, of each
    /// item that ends a history element and of no other. The job keeps the
    /// carry and never returns it. Null once the item's ops end. Nothing
    /// is sent before request_end, so the ops that ran before a bad one
    /// wrote only request scratch, which the failure discards.
    pub fn next(self: *Job) Error!?codec_abi.Op {
        const kind: codec_abi.ItemKind = self.header.item;
        var reader = self.ops.reader(self.offset);
        while (try reader.next()) |op| {
            if (self.carried) return error.CodecBadOp;
            self.offset = reader.offset;
            switch (op) {
                .literal => return op,
                .content => |content| return if (self.header.has(content.handle)) op else error.CodecBadOp,
                .carry => |state| {
                    if (!kind.endsElement()) return error.CodecBadOp;
                    self.carried = true;
                    self.carry = state;
                },
            }
        }
        if (kind.endsElement() and !self.carried) return error.CodecBadOp;
        return null;
    }
};

const TestItem = struct {
    item: codec_abi.Item,
    handles: []const ?[]const u8 = &.{},
};

/// Encode `items` into `out`, running each op as the Host does, with
/// std.json's string escaping standing in for the Host's cursors.
fn encodeForTesting(job: *Job, items: []const TestItem, out: *std.Io.Writer) !void {
    for (items) |item| {
        job.header.item = item.item;
        job.header.handles = 0;
        for (item.handles, 0..) |handle, index| {
            if (handle != null) job.header.handles |= @as(u8, 1) << @intCast(index);
        }
        try job.step();
        while (try job.next()) |op| switch (op) {
            .literal => |bytes| try out.writeAll(bytes),
            .content => |content| switch (content.escape) {
                .verbatim => try out.writeAll(item.handles[content.handle].?),
                .json_string_v1 => try std.json.Stringify.encodeJsonStringChars(item.handles[content.handle].?, .{}, out),
            },
            .carry => unreachable,
        };
    }
}

test "a tool entry escapes its name and description as JSON strings" {
    var job: Job = undefined;
    try job.begin(encoder(.@"openai-responses/1"));
    var buffer: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try encodeForTesting(&job, &.{.{ .item = .tool, .handles = &.{ "t", "say \"hi\"\\\n\x01é", "{}" } }}, &out);
    const json = out.buffered();
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("say \"hi\"\\\n\x01é", parsed.value.object.get("description").?.string);
    try std.testing.expectEqualStrings("{\"type\":\"function\",\"name\":\"t\",\"description\":\"say \\\"hi\\\"\\\\\\n\\u0001é\",\"strict\":true,\"parameters\":{}}", json);
}

test "a job resumed from a history element's carry continues as the uninterrupted job" {
    const history = [_]TestItem{
        .{ .item = .{ .message = .user }, .handles = &.{"one"} },
        .{ .item = .{ .output_open = .{ .kind = .reasoning, .phase = .unphased, .omit_reasoning_text = true } } },
        .{ .item = .{ .output_part = .{ .array = .summary, .kind = .summary_text } }, .handles = &.{ "plan", null } },
        .{ .item = .{ .output_part = .{ .array = .content, .kind = .reasoning_text } }, .handles = &.{"private"} },
        .{ .item = .output_close, .handles = &.{"\"encrypted_content\":\"x\""} },
        .{ .item = .{ .output_open = .{ .kind = .function_call, .phase = .unphased, .omit_reasoning_text = false } }, .handles = &.{ "bash", "c1", "{}" } },
        .{ .item = .output_close },
        .{ .item = .tool_result, .handles = &.{ "c1", "done" } },
        .{ .item = .{ .message = .instruction }, .handles = &.{ "two", "from peer" } },
    };
    const tail = [_]TestItem{ .{ .item = .history_end }, .{ .item = .compaction_trigger }, .{ .item = .tools_start }, .{ .item = .text_format }, .{ .item = .request_end } };
    var whole_buffer: [2048]u8 = undefined;
    var whole: std.Io.Writer = .fixed(&whole_buffer);
    var job: Job = undefined;
    try job.begin(encoder(.@"openai-responses/1"));
    try encodeForTesting(&job, &history, &whole);
    try encodeForTesting(&job, &tail, &whole);
    // Cut before the first element and after every one: a fresh job given
    // only the carry writes the same remaining bytes.
    for (0..history.len + 1) |cut| {
        if (cut != 0) {
            const kind: codec_abi.ItemKind = history[cut - 1].item;
            if (!kind.endsElement()) continue;
        }
        var resumed_buffer: [2048]u8 = undefined;
        var resumed: std.Io.Writer = .fixed(&resumed_buffer);
        var first: Job = undefined;
        try first.begin(encoder(.@"openai-responses/1"));
        try encodeForTesting(&first, history[0..cut], &resumed);
        var second: Job = undefined;
        try second.begin(encoder(.@"openai-responses/1"));
        second.resumeFrom(&first.carry);
        try encodeForTesting(&second, history[cut..], &resumed);
        try encodeForTesting(&second, &tail, &resumed);
        try std.testing.expectEqualStrings(whole.buffered(), resumed.buffered());
    }
    try std.testing.expectStringStartsWith(whole.buffered(), "{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"one\"}]},{\"type\":\"reasoning\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"plan\"}],\"encrypted_content\":\"x\"}");
    try std.testing.expectStringEndsWith(whole.buffered(), "{\"type\":\"compaction_trigger\"}],\"tools\":[],\"text\":{\"verbosity\":\"low\"}}");
}

test "codec ops are checked as they run and a bad op fails the job" {
    const Case = struct { item: codec_abi.Item, handles: u8 = 0, status: codec_abi.Status = .next, ops: []const u8, expected: Job.Error!?u8 };
    const carry_one = [_]u8{ 3, 1, 1 };
    const close = [_]u8{ 1, 1, 0, '}' };
    const oversized = [_]u8{ 3, codec_abi.max_carry_bytes + 1 } ++ @as([codec_abi.max_carry_bytes + 1]u8, @splat(0));
    for ([_]Case{
        .{ .item = .tools_start, .ops = &.{ 1, 1, 0, '[' }, .expected = null },
        .{ .item = .tool_result, .handles = 0b11, .ops = &([_]u8{ 2, 0, 1, 2, 1, 0 } ++ carry_one), .expected = 1 },
        // A carry outside an element, after history_end, twice, before
        // another op, or missing from an element.
        .{ .item = .instructions, .ops = &carry_one, .expected = error.CodecBadOp },
        .{ .item = .history_end, .ops = &carry_one, .expected = error.CodecBadOp },
        .{ .item = .tools_start, .ops = &carry_one, .expected = error.CodecBadOp },
        .{ .item = .output_close, .ops = &(carry_one ++ carry_one), .expected = error.CodecBadOp },
        .{ .item = .output_close, .ops = &(carry_one ++ close), .expected = error.CodecBadOp },
        .{ .item = .output_close, .ops = &close, .expected = error.CodecBadOp },
        .{ .item = .{ .message = .user }, .handles = 1, .ops = &.{ 2, 0, 1 }, .expected = error.CodecBadOp },
        // A handle the item lacks, or past the last handle.
        .{ .item = .text_format, .ops = &.{ 2, 0, 0 }, .expected = error.CodecBadOp },
        .{ .item = .{ .message = .user }, .handles = 0b01, .ops = &([_]u8{ 2, 1, 1 } ++ carry_one), .expected = error.CodecBadOp },
        .{ .item = .tool, .handles = 0xff, .ops = &.{ 2, codec_abi.max_handles, 1 }, .expected = error.CodecBadOp },
        // Malformed ops: an unknown tag or escape, an empty or cut literal,
        // a cut content or carry, a carry past its bound.
        .{ .item = .tools_start, .ops = &.{0}, .expected = error.CodecBadOp },
        .{ .item = .tools_start, .ops = &.{4}, .expected = error.CodecBadOp },
        .{ .item = .tool, .handles = 1, .ops = &.{ 2, 0, 2 }, .expected = error.CodecBadOp },
        .{ .item = .tools_start, .ops = &.{ 1, 0, 0 }, .expected = error.CodecBadOp },
        .{ .item = .tools_start, .ops = &.{ 1, 2, 0, '[' }, .expected = error.CodecBadOp },
        .{ .item = .tools_start, .ops = &.{ 1, 1 }, .expected = error.CodecBadOp },
        .{ .item = .tool, .handles = 1, .ops = &.{ 2, 0 }, .expected = error.CodecBadOp },
        .{ .item = .tool_result, .handles = 0b11, .ops = &.{ 3, 2, 1 }, .expected = error.CodecBadOp },
        .{ .item = .tool_result, .handles = 0b11, .ops = &oversized, .expected = error.CodecBadOp },
        // Done exactly at request_end; a failure is the codec's own.
        .{ .item = .text_format, .status = .done, .ops = &.{}, .expected = error.CodecBadOp },
        .{ .item = .request_end, .ops = &close, .expected = error.CodecBadOp },
        .{ .item = .request_end, .status = .done, .ops = &close, .expected = null },
        .{ .item = .{ .settings = .{ .effort = null, .model_length = 0 } }, .status = .failed, .ops = &.{}, .expected = error.CodecFailed },
    }) |case| {
        var job: Job = undefined;
        job.header = .{ .item = case.item, .handles = case.handles };
        job.carry = .{ .len = 0 };
        job.ops.length = @intCast(case.ops.len);
        @memcpy(job.ops.bytes[0..case.ops.len], case.ops);
        const result = drainForTesting(&job, case.status);
        if (case.expected) |expected| {
            const carry = try result;
            try std.testing.expectEqual(expected, if (carry) |value| value.slice()[0] else null);
        } else |err| try std.testing.expectError(err, result);
    }
}

/// Read every op of the item in `job` as the Host does, and return the
/// item's carry.
fn drainForTesting(job: *Job, status: codec_abi.Status) Job.Error!?codec_abi.Carry {
    try job.open(status);
    while (try job.next()) |op| std.debug.assert(op != .carry);
    return if (job.carried) job.carry else null;
}
