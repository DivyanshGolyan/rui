//! The codecs this Host serves, by the codec name a Session pins. A codec's
//! encoder is plain functions over values its caller stores, dispatched at
//! comptime; its error classifier still runs as a job in storage its caller
//! owns.
const std = @import("std");
const codec_abi = @import("codec_abi.zig");
const protocol = @import("protocol.zig");
const responses = @import("codecs/responses.zig");

/// The module of each codec this Host serves, the one place a codec is
/// added: everything below is derived from it.
fn module(comptime codec: protocol.Codec) type {
    return switch (codec) {
        .@"openai-responses/1" => responses,
    };
}

pub fn manifest(codec: protocol.Codec) *const codec_abi.Manifest {
    return switch (codec) {
        inline else => |tag| &module(tag).manifest,
    };
}

comptime {
    for (@typeInfo(protocol.Codec).@"enum".field_names) |name| {
        const codec = module(@field(protocol.Codec, name));
        if (!codec.manifest.valid()) @compileError("codec " ++ name ++ " observes a header that is not a lowercase token");
        const headers = @typeInfo(codec.RequestHeader).@"enum".field_names;
        if (headers.len > codec_abi.max_request_headers) @compileError("codec " ++ name ++ " names more request headers than a request holds");
        for (headers) |header| if (!codec_abi.lowercaseToken(header)) @compileError("codec " ++ name ++ " names a request header that is not a lowercase token");
    }
    // The Responses classifier accepts exactly the bodies the Host's own
    // JSON reading did.
    std.debug.assert(@import("codecs/json.zig").max_depth == protocol.max_json_depth);
}

/// A pinned codec's request encoder state, which its caller stores. Each
/// codec's `Encoder` holds its `Carry` as `carry`, and its other fields'
/// defaults are its state at a history-element boundary.
pub const Encoder = PerCodec("Encoder");

/// A pinned codec's encoder state at a history-element boundary.
pub const Carry = PerCodec("Carry");

/// The union over every codec of the type each declares as `name`.
fn PerCodec(comptime name: []const u8) type {
    const codecs = @typeInfo(protocol.Codec).@"enum".field_names;
    var names: [codecs.len][]const u8 = undefined;
    var types: [codecs.len]type = undefined;
    for (codecs, &names, &types) |codec, *field, *T| {
        field.* = codec;
        T.* = @field(module(@field(protocol.Codec, codec)), name);
    }
    return @Union(.auto, protocol.Codec, &names, &types, &@splat(.{}));
}

/// The carry before a request's first history element.
pub fn initialCarry(codec: protocol.Codec) Carry {
    return switch (codec) {
        inline else => |tag| @unionInit(Carry, @tagName(tag), module(tag).initial),
    };
}

pub fn resumeFrom(carry: Carry) Encoder {
    return switch (carry) {
        inline else => |value, tag| @unionInit(Encoder, @tagName(tag), .{ .carry = value }),
    };
}

pub fn carryOf(encoder: *const Encoder) Carry {
    return switch (encoder.*) {
        inline else => |*state, tag| @unionInit(Carry, @tagName(tag), state.carry),
    };
}

/// Write the item's pieces into `out`. `error.Declined` is the codec
/// declining a request it cannot encode.
pub fn encodeItem(encoder: *Encoder, header: *const codec_abi.ItemHeader, out: *codec_abi.Pieces) error{Declined}!void {
    return switch (encoder.*) {
        inline else => |*state| state.encodeItem(header, out),
    };
}

/// The pinned codec's request headers for `settings`, written over `out`.
pub fn requestHeaders(codec: protocol.Codec, settings: *const codec_abi.Settings, out: *codec_abi.Headers) void {
    switch (codec) {
        inline else => |tag| module(tag).requestHeaders(settings, out),
    }
}

/// The name `codec` gives the request header `Headers.names` holds as
/// `name`.
pub fn headerName(codec: protocol.Codec, name: u8) []const u8 {
    return switch (codec) {
        inline else => |tag| @tagName(@as(module(tag).RequestHeader, @fromBackingInt(@intCast(name)))),
    };
}

/// The HTTP error classifier of a pinned codec.
pub fn classifier(codec: protocol.Codec) *const Classifier {
    return switch (codec) {
        inline else => |tag| &struct {
            const value = nativeClassifier(module(tag).Classifier);
        }.value,
    };
}

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
        // Malformed: an unknown tag, field or escape, an empty or overlong
        // code, a cut finding, a reset flag past 1 or a reset time without
        // its flag.
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

/// Encode `items` into `out` as the Host does, resuming `encoder` from
/// `carry` before each item that resumes when `carry` is given, with
/// std.json's string escaping standing in for the Host's cursors.
fn encodeForTesting(encoder: *Encoder, carry: ?*Carry, items: []const TestItem, out: *std.Io.Writer) !void {
    var pieces: codec_abi.Pieces = .{ .len = 0 };
    for (items) |item| {
        var header: codec_abi.ItemHeader = .{ .item = item.item, .handles = 0 };
        for (item.handles, 0..) |handle, index| {
            if (handle != null) header.handles |= @as(u8, 1) << @intCast(index);
        }
        const kind: codec_abi.ItemKind = header.item;
        if (carry) |kept| if (kind.resumes()) {
            encoder.* = resumeFrom(kept.*);
        };
        try encodeItem(encoder, &header, &pieces);
        if (carry) |kept| if (kind.endsElement()) {
            kept.* = carryOf(encoder);
        };
        for (pieces.slice()) |piece| switch (piece) {
            .literal => |bytes| try out.writeAll(bytes),
            .content => |content| switch (content.escape) {
                .verbatim => try out.writeAll(item.handles[content.handle].?),
                .json_string_v1 => try std.json.Stringify.encodeJsonStringChars(item.handles[content.handle].?, .{}, out),
            },
        };
    }
}

const responses_initial = initialCarry(.@"openai-responses/1");

test "a tool entry escapes its name and description as JSON strings" {
    var encoder = resumeFrom(responses_initial);
    var buffer: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try encodeForTesting(&encoder, null, &.{.{ .item = .tool, .handles = &.{ "t", "say \"hi\"\\\n\x01é", "{}" } }}, &out);
    const json = out.buffered();
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("say \"hi\"\\\n\x01é", parsed.value.object.get("description").?.string);
    try std.testing.expectEqualStrings("{\"type\":\"function\",\"name\":\"t\",\"description\":\"say \\\"hi\\\"\\\\\\n\\u0001é\",\"strict\":true,\"parameters\":{}}", json);
}

test "a resumed encoder writes what an uninterrupted one writes" {
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
    // One encoder over the whole request, never resumed: the bytes a
    // carry that held less than the codec needs would change.
    var whole_buffer: [2048]u8 = undefined;
    var whole: std.Io.Writer = .fixed(&whole_buffer);
    var uninterrupted = resumeFrom(responses_initial);
    try encodeForTesting(&uninterrupted, null, &history, &whole);
    try encodeForTesting(&uninterrupted, null, &tail, &whole);
    // Cut before the first element and after every one: a fresh encoder
    // given only the carry writes the same remaining bytes.
    for (0..history.len + 1) |cut| {
        if (cut != 0) {
            const kind: codec_abi.ItemKind = history[cut - 1].item;
            if (!kind.endsElement()) continue;
        }
        var resumed_buffer: [2048]u8 = undefined;
        var resumed: std.Io.Writer = .fixed(&resumed_buffer);
        var carry = responses_initial;
        var first = resumeFrom(carry);
        try encodeForTesting(&first, &carry, history[0..cut], &resumed);
        var second = resumeFrom(responses_initial);
        try encodeForTesting(&second, &carry, history[cut..], &resumed);
        try encodeForTesting(&second, &carry, &tail, &resumed);
        try std.testing.expectEqualStrings(whole.buffered(), resumed.buffered());
    }
    try std.testing.expectStringStartsWith(whole.buffered(), "{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"one\"}]},{\"type\":\"reasoning\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"plan\"}],\"encrypted_content\":\"x\"}");
    try std.testing.expectStringEndsWith(whole.buffered(), "{\"type\":\"compaction_trigger\"}],\"tools\":[],\"text\":{\"verbosity\":\"low\"}}");
}
