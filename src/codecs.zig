//! The codecs this Host serves, by the codec name a Session pins, and the
//! jobs that run a codec's request encoder, error classifier and response
//! interpreter in storage their caller owns.
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
    // The Responses classifier accepts exactly the bodies the Host's own
    // JSON reading did.
    std.debug.assert(@import("codecs/json.zig").max_depth == protocol.max_json_depth);
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
/// `State` in an `EncodeJob`, never on a stack.
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
pub const EncodeJob = struct {
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

    pub fn begin(self: *EncodeJob, codec: *const Encoder) Error!void {
        self.encoder = codec;
        self.carry = .{ .len = 0 };
        if (!codec.load(&self.state, &self.carry)) return error.CodecFailed;
    }

    /// Continue after a history memo whose span ended in `carry`.
    pub fn resumeFrom(self: *EncodeJob, carry: *const codec_abi.Carry) void {
        self.carry = carry.*;
    }

    /// Encode the item in `header`. Before a history element and
    /// history_end the state is reloaded from the carry, so nothing else
    /// crosses a boundary and a memo copy continues exactly as a rebuild
    /// does.
    pub fn step(self: *EncodeJob) Error!void {
        const kind: codec_abi.ItemKind = self.header.item;
        if (kind.resumes() and !self.encoder.load(&self.state, &self.carry)) return error.CodecFailed;
        self.ops.length = 0;
        try self.open(self.encoder.step(&self.state, &self.header, &self.ops));
    }

    /// Done exactly at request_end; a failure is the codec's own.
    fn open(self: *EncodeJob, status: codec_abi.Status) Error!void {
        const kind: codec_abi.ItemKind = self.header.item;
        switch (status) {
            .failed => return error.CodecFailed,
            .next, .done => if ((status == .done) != (kind == .request_end)) return error.CodecBadOp,
        }
        self.offset = 0;
        self.carried = false;
    }

    /// The item's next op, judged as it is read: well formed; content only
    /// of the item's handles; a header only of the settings item (its name
    /// and value are judged where they are kept); a carry exactly once, as
    /// the last op, of each item that ends a history element and of no
    /// other. The job keeps the
    /// carry and never returns it. Null once the item's ops end. Nothing
    /// is sent before request_end, so the ops that ran before a bad one
    /// wrote only request scratch, which the failure discards.
    pub fn next(self: *EncodeJob) Error!?codec_abi.Op {
        const kind: codec_abi.ItemKind = self.header.item;
        var reader = self.ops.reader(self.offset);
        while (try reader.next()) |op| {
            if (self.carried) return error.CodecBadOp;
            self.offset = reader.offset;
            switch (op) {
                .literal => return op,
                .content => |content| return if (self.header.has(content.handle)) op else error.CodecBadOp,
                .header => return if (kind == .settings) op else error.CodecBadOp,
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

/// The HTTP error classifier of a pinned codec.
pub fn classifier(codec: protocol.Codec) *const Classifier {
    return switch (codec) {
        .@"openai-responses/1" => &responses_classifier,
    };
}

const responses_classifier = nativeClassifier(responses.Classifier);

pub const max_classifier_state_bytes = 512;

/// A codec's classifier state, opaque to the Host.
pub const ClassifierState = struct {
    bytes: [max_classifier_state_bytes]u8 align(16),
};

/// An HTTP error classifier linked into the Host. Each function works on a
/// `ClassifierState` in a `ClassifyJob`, never on a stack.
pub const Classifier = struct {
    /// The state before the body's first byte.
    init: *const fn (state: *ClassifierState) void,
    /// Read one window and write its findings into `ops`, which starts empty.
    step: *const fn (state: *ClassifierState, fed: *const codec_abi.Fed, ops: *codec_abi.Ops) codec_abi.Status,
};

/// The `Classifier` of a codec type with `init(*T)` and
/// `classify(*T, *const Fed, *Ops) !Status`.
pub fn nativeClassifier(comptime Codec: type) Classifier {
    comptime std.debug.assert(@sizeOf(Codec) <= max_classifier_state_bytes and @alignOf(Codec) <= @alignOf(ClassifierState));
    const adapter = struct {
        fn init(state: *ClassifierState) void {
            of(state).init();
        }

        // Every error is the codec's own, so it is `.failed`, which narrows
        // nothing.
        fn step(state: *ClassifierState, fed: *const codec_abi.Fed, ops: *codec_abi.Ops) codec_abi.Status {
            return of(state).classify(fed, ops) catch .failed;
        }

        fn of(state: *ClassifierState) *Codec {
            return @ptrCast(&state.bytes);
        }
    };
    return .{ .init = adapter.init, .step = adapter.step };
}

/// One error body's classification, in its caller's storage. The caller
/// steps each window of the body in order and takes every finding `next`
/// gives before it steps the next window.
pub const ClassifyJob = struct {
    classifier: *const Classifier,
    state: ClassifierState,
    ops: codec_abi.Ops,
    findings: codec_abi.FindingReader,
    /// The body's length, within which every report range lies.
    length: u64,
    given: std.EnumSet(Given),

    pub const Error = error{ CodecFailed, CodecBadOp };

    /// Each finding is given at most once, a report once per field.
    const Given = enum { context_overflow, quota, refusal, report_code, report_message };

    pub fn begin(self: *ClassifyJob, codec: *const Classifier, length: u64) void {
        self.classifier = codec;
        self.length = length;
        self.given = .empty;
        self.findings = .{ .bytes = &.{} };
        codec.init(&self.state);
    }

    /// Classify the next window; true once the codec is done, which it
    /// must be after the last.
    pub fn step(self: *ClassifyJob, fed: *const codec_abi.Fed) Error!bool {
        self.ops.length = 0;
        const status = self.classifier.step(&self.state, fed, &self.ops);
        self.findings = self.ops.findings();
        return switch (status) {
            .failed => error.CodecFailed,
            .done => true,
            .next => if (fed.end) error.CodecBadOp else false,
        };
    }

    /// The window's next finding, judged as it is read: well formed, not
    /// given before, and a report range within the body. Null once the
    /// window's findings end.
    pub fn next(self: *ClassifyJob) Error!?codec_abi.Finding {
        const finding = try self.findings.next() orelse return null;
        const given: Given = switch (finding) {
            .context_overflow => .context_overflow,
            .quota => .quota,
            .refusal => .refusal,
            .report => |range| report: {
                if (range.start > self.length or range.length > self.length - range.start) return error.CodecBadOp;
                break :report if (range.field == .code) .report_code else .report_message;
            },
        };
        if (self.given.contains(given)) return error.CodecBadOp;
        self.given.insert(given);
        return finding;
    }
};

/// The response interpreter of a pinned codec.
pub fn interpreter(codec: protocol.Codec) *const Interpreter {
    return switch (codec) {
        .@"openai-responses/1" => &responses_interpreter,
    };
}

const responses_interpreter = nativeInterpreter(responses.Interpreter);

pub const max_interpreter_state_bytes = 8 * 1024;

/// A codec's interpreter state, opaque to the Host.
pub const InterpreterState = struct {
    bytes: [max_interpreter_state_bytes]u8 align(16),
};

/// A response interpreter linked into the Host. Each function works on an
/// `InterpreterState` in an `InterpretJob`, never on a stack.
pub const Interpreter = struct {
    /// The state before the stream's first event.
    init: *const fn (state: *InterpreterState, operation: codec_abi.Operation) void,
    /// Read one window and write its records into `ops`, which starts empty.
    step: *const fn (state: *InterpreterState, fed: *const codec_abi.EventFed, ops: *codec_abi.Ops) codec_abi.Status,
};

/// The `Interpreter` of a codec type with `init(*T, Operation)` and
/// `interpret(*T, *const EventFed, *Ops) !Status`.
pub fn nativeInterpreter(comptime Codec: type) Interpreter {
    comptime std.debug.assert(@sizeOf(Codec) <= max_interpreter_state_bytes and @alignOf(Codec) <= @alignOf(InterpreterState));
    const adapter = struct {
        fn init(state: *InterpreterState, operation: codec_abi.Operation) void {
            of(state).init(operation);
        }

        // Every error is the codec's own, so it is `.failed`.
        fn step(state: *InterpreterState, fed: *const codec_abi.EventFed, ops: *codec_abi.Ops) codec_abi.Status {
            return of(state).interpret(fed, ops) catch .failed;
        }

        fn of(state: *InterpreterState) *Codec {
            return @ptrCast(&state.bytes);
        }
    };
    return .{ .init = adapter.init, .step = adapter.step };
}

/// One response's interpretation, in its caller's storage. The caller
/// steps each window it feeds and takes every record `next` gives before it
/// feeds again.
pub const InterpretJob = struct {
    interpreter: *const Interpreter,
    state: InterpreterState,
    ops: codec_abi.Ops,
    records: codec_abi.RecordReader,
    /// Whether the window's answer ended with `need`, which nothing follows.
    needed: bool,

    pub const Error = error{ CodecFailed, CodecBadOp };

    pub fn begin(self: *InterpretJob, codec: *const Interpreter, operation: codec_abi.Operation) void {
        self.interpreter = codec;
        self.records = .{ .bytes = &.{} };
        codec.init(&self.state, operation);
    }

    /// Interpret the next window; true once the codec is done, which it may
    /// be only at the stream's end and must be there unless it failed.
    pub fn step(self: *InterpretJob, fed: *const codec_abi.EventFed) Error!bool {
        self.ops.length = 0;
        self.needed = false;
        const status = self.interpreter.step(&self.state, fed, &self.ops);
        self.records = self.ops.records();
        return switch (status) {
            .failed => error.CodecFailed,
            .done => if (fed.end) true else error.CodecBadOp,
            .next => false,
        };
    }

    /// The window's next record, well formed, with nothing after a `need`.
    /// Null once the window's records end.
    pub fn next(self: *InterpretJob) Error!?codec_abi.Record {
        const record = try self.records.next() orelse return null;
        if (self.needed) return error.CodecBadOp;
        if (record == .need) self.needed = true;
        return record;
    }
};

test "classifier findings are checked as they are read and a bad one fails the job" {
    const Case = struct { status: codec_abi.Status = .done, end: bool = true, ops: []const u8, expected: ClassifyJob.Error!usize };
    const report = [_]u8{ 8, 0, 1 } ++ std.mem.toBytes(@as(u64, 2)) ++ std.mem.toBytes(@as(u64, 8));
    const message = [_]u8{ 8, 1, 1 } ++ std.mem.toBytes(@as(u64, 0)) ++ std.mem.toBytes(@as(u64, 10));
    const quota = [_]u8{ 6, 1, 1 } ++ std.mem.toBytes(@as(u64, 0)) ++ [_]u8{'q'};
    const long_code = [_]u8{ 7, codec_abi.max_code_bytes } ++ @as([codec_abi.max_code_bytes]u8, @splat('c'));
    for ([_]Case{
        .{ .ops = &.{}, .expected = 0 },
        .{ .status = .next, .end = false, .ops = &.{}, .expected = 0 },
        .{ .ops = &([_]u8{5} ++ quota ++ [_]u8{ 7, 1, 'r' } ++ report ++ message), .expected = 5 },
        .{ .ops = &long_code, .expected = 1 },
        .{ .ops = &([_]u8{ 6, 1, 0 } ++ std.mem.toBytes(@as(u64, 0)) ++ [_]u8{'q'}), .expected = 1 },
        // Each finding once, a report once per field.
        .{ .ops = &.{ 5, 5 }, .expected = error.CodecBadOp },
        .{ .ops = &(quota ++ quota), .expected = error.CodecBadOp },
        .{ .ops = &.{ 7, 1, 'r', 7, 1, 's' }, .expected = error.CodecBadOp },
        .{ .ops = &(report ++ report), .expected = error.CodecBadOp },
        // A report range past the body's 10 bytes.
        .{ .ops = &([_]u8{ 8, 1, 1 } ++ std.mem.toBytes(@as(u64, 0)) ++ std.mem.toBytes(@as(u64, 11))), .expected = error.CodecBadOp },
        .{ .ops = &([_]u8{ 8, 1, 1 } ++ std.mem.toBytes(@as(u64, 11)) ++ std.mem.toBytes(@as(u64, 0))), .expected = error.CodecBadOp },
        .{ .ops = &([_]u8{ 8, 1, 1 } ++ std.mem.toBytes(@as(u64, 4)) ++ std.mem.toBytes(@as(u64, std.math.maxInt(u64)))), .expected = error.CodecBadOp },
        // Malformed: an encode op, an unknown tag, field or escape, an empty
        // or overlong code, a cut finding, a reset flag past 1 or a reset
        // time without its flag.
        .{ .ops = &.{ 1, 1, 0, '{' }, .expected = error.CodecBadOp },
        .{ .ops = &.{9}, .expected = error.CodecBadOp },
        .{ .ops = &([_]u8{ 8, 2, 1 } ++ std.mem.toBytes(@as(u64, 0)) ++ std.mem.toBytes(@as(u64, 0))), .expected = error.CodecBadOp },
        .{ .ops = &([_]u8{ 8, 0, 2 } ++ std.mem.toBytes(@as(u64, 0)) ++ std.mem.toBytes(@as(u64, 0))), .expected = error.CodecBadOp },
        .{ .ops = &.{ 7, 0 }, .expected = error.CodecBadOp },
        .{ .ops = &([_]u8{ 7, codec_abi.max_code_bytes + 1 } ++ @as([codec_abi.max_code_bytes + 1]u8, @splat('c'))), .expected = error.CodecBadOp },
        .{ .ops = &.{ 7, 2, 'r' }, .expected = error.CodecBadOp },
        .{ .ops = report[0..18], .expected = error.CodecBadOp },
        .{ .ops = quota[0..10], .expected = error.CodecBadOp },
        .{ .ops = &([_]u8{ 6, 1, 2 } ++ std.mem.toBytes(@as(u64, 0)) ++ [_]u8{'q'}), .expected = error.CodecBadOp },
        .{ .ops = &([_]u8{ 6, 1, 0 } ++ std.mem.toBytes(@as(u64, 1)) ++ [_]u8{'q'}), .expected = error.CodecBadOp },
        // Done after the last window, and a failure the codec's own.
        .{ .status = .next, .ops = &.{}, .expected = error.CodecBadOp },
        .{ .status = .failed, .ops = &.{5}, .expected = error.CodecFailed },
    }) |case| {
        const Fixed = struct {
            var status: codec_abi.Status = undefined;
            var ops: []const u8 = undefined;
            const codec: Classifier = .{ .init = init, .step = step };
            fn init(_: *ClassifierState) void {}
            fn step(_: *ClassifierState, _: *const codec_abi.Fed, out: *codec_abi.Ops) codec_abi.Status {
                @memcpy(out.bytes[0..ops.len], ops);
                out.length = @intCast(ops.len);
                return status;
            }
        };
        Fixed.status = case.status;
        Fixed.ops = case.ops;
        var job: ClassifyJob = undefined;
        job.begin(&Fixed.codec, 10);
        const result = count: {
            _ = job.step(&.{ .bytes = "0123456789", .end = case.end }) catch |err| break :count err;
            var count: usize = 0;
            while (job.next() catch |err| break :count err) |_| count += 1;
            break :count count;
        };
        if (case.expected) |expected| {
            try std.testing.expectEqual(expected, try result);
        } else |err| try std.testing.expectError(err, result);
    }
    // The Responses classifier's largest answer fits the ops bound: an
    // overflow is never also a quota and a refusal.
    var ops: codec_abi.Ops = .{};
    const longest: codec_abi.Quota = .{ .code = &@as([codec_abi.max_code_bytes]u8, @splat('c')), .resets_at = std.math.maxInt(u64) };
    try ops.finding(.{ .quota = longest });
    try ops.finding(.{ .refusal = longest.code });
    for (std.enums.values(codec_abi.ReportField)) |field| try ops.finding(.{ .report = .{ .field = field, .escape = .json_string_v1, .start = 0, .length = 0 } });
}

const TestItem = struct {
    item: codec_abi.Item,
    handles: []const ?[]const u8 = &.{},
};

/// Encode `items` into `out`, running each op as the Host does, with
/// std.json's string escaping standing in for the Host's cursors.
fn encodeForTesting(job: *EncodeJob, items: []const TestItem, out: *std.Io.Writer) !void {
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
            .carry, .header => unreachable,
        };
    }
}

test "a tool entry escapes its name and description as JSON strings" {
    var job: EncodeJob = undefined;
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
    var job: EncodeJob = undefined;
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
        var first: EncodeJob = undefined;
        try first.begin(encoder(.@"openai-responses/1"));
        try encodeForTesting(&first, history[0..cut], &resumed);
        var second: EncodeJob = undefined;
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
    const Case = struct { item: codec_abi.Item, handles: u8 = 0, status: codec_abi.Status = .next, ops: []const u8, expected: EncodeJob.Error!?u8 };
    const carry_one = [_]u8{ 3, 1, 1 };
    const close = [_]u8{ 1, 1, 0, '}' };
    const oversized = [_]u8{ 3, codec_abi.max_carry_bytes + 1 } ++ @as([codec_abi.max_carry_bytes + 1]u8, @splat(0));
    const header = [_]u8{ 4, 1, 2, 0, 'a', 'v', 'w' };
    const settings: codec_abi.Item = .{ .settings = .{ .effort = null, .session_affinity = @splat(0), .model_length = 0 } };
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
        // A header of the settings item only.
        .{ .item = settings, .ops = &header, .expected = null },
        .{ .item = .instructions, .handles = 1, .ops = &header, .expected = error.CodecBadOp },
        .{ .item = .history_end, .ops = &header, .expected = error.CodecBadOp },
        .{ .item = .tool_result, .handles = 0b11, .ops = &(header ++ carry_one), .expected = error.CodecBadOp },
        // Malformed ops: an unknown tag or escape, an empty or cut literal,
        // a cut content, carry or header, a carry past its bound, a header
        // without a name, a header whose lengths sum past u16 or past the
        // ops.
        .{ .item = .tools_start, .ops = &.{0}, .expected = error.CodecBadOp },
        .{ .item = .tools_start, .ops = &.{5}, .expected = error.CodecBadOp },
        .{ .item = settings, .ops = header[0 .. header.len - 1], .expected = error.CodecBadOp },
        .{ .item = settings, .ops = header[0..3], .expected = error.CodecBadOp },
        .{ .item = settings, .ops = &.{ 4, 0, 1, 0, 'v' }, .expected = error.CodecBadOp },
        .{ .item = settings, .ops = &.{ 4, 0x10, 0xff, 0xff }, .expected = error.CodecBadOp },
        .{ .item = settings, .ops = &.{ 4, 0xff, 0xff, 0xff }, .expected = error.CodecBadOp },
        .{ .item = settings, .ops = &.{ 4, 0xff, 0, 0 }, .expected = error.CodecBadOp },
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
        .{ .item = settings, .status = .failed, .ops = &.{}, .expected = error.CodecFailed },
    }) |case| {
        var job: EncodeJob = undefined;
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
fn drainForTesting(job: *EncodeJob, status: codec_abi.Status) EncodeJob.Error!?codec_abi.Carry {
    try job.open(status);
    while (try job.next()) |op| std.debug.assert(op != .carry);
    return if (job.carried) job.carry else null;
}
