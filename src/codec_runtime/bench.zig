//! Measures the codec sandbox on this machine: the same scanner natively and
//! in WAMR over a Codex-like event stream, the instructions it meters per
//! byte, and the process's private memory at each phase of a job.
//! Usage: rui-codec-runtime-bench [MiB] [rounds]
const std = @import("std");
const codec_runtime = @import("codec_runtime");
const scan = @import("scan");

const scan_wasm = @embedFile("scan_wasm");
const max_rounds = 64;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const mib = if (args.len > 1) try std.fmt.parseInt(usize, args[1], 10) else 32;
    const rounds = if (args.len > 2) try std.fmt.parseInt(usize, args[2], 10) else 5;
    if (mib == 0 or rounds == 0 or rounds > max_rounds) return error.InvalidArguments;
    const corpus = try codexStream(arena, mib << 20);
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;
    try out.print("corpus {d} bytes, {d} rounds, module {d} bytes\n", .{ corpus.len, rounds, scan_wasm.len });

    var native_ns: [max_rounds]u64 = undefined;
    var native: scan.Scan = .{};
    for (native_ns[0..rounds]) |*elapsed| {
        const start = now(init.io);
        native = .{};
        var offset: usize = 0;
        while (offset < corpus.len) : (offset += scan.window_bytes) {
            native.feed(corpus[offset..@min(offset + scan.window_bytes, corpus.len)]);
        }
        elapsed.* = now(init.io) - start;
    }
    try report(out, "native", corpus.len, native_ns[0..rounds]);

    const before = try privateMemory(init.io);
    const module_bytes = try arena.dupe(u8, scan_wasm);
    var load_ns = now(init.io);
    var module = try codec_runtime.Module.load(module_bytes);
    load_ns = now(init.io) - load_ns;
    const loaded = try privateMemory(init.io);
    const limits: codec_runtime.Limits = .{ .memory_pages = module.memory_pages };

    var begin_ns: [max_rounds]u64 = undefined;
    var end_ns: [max_rounds]u64 = undefined;
    var wasm_ns: [max_rounds]u64 = undefined;
    var running: Memory = undefined;
    for (wasm_ns[0..rounds], begin_ns[0..rounds], end_ns[0..rounds], 0..) |*elapsed, *begin_elapsed, *end_elapsed, round| {
        const begin_start = now(init.io);
        var job = try codec_runtime.Job.begin(&module, limits);
        begin_elapsed.* = now(init.io) - begin_start;
        const window = try job.call(job.function("windowAddress", 0).?, &.{}, 1000);
        const feed = job.function("feed", 1).?;
        const start = now(init.io);
        var offset: usize = 0;
        while (offset < corpus.len) : (offset += scan.window_bytes) {
            const piece = corpus[offset..@min(offset + scan.window_bytes, corpus.len)];
            @memcpy(job.memory()[window..][0..piece.len], piece);
            _ = try job.call(feed, &.{@intCast(piece.len)}, std.math.maxInt(codec_runtime.Budget));
        }
        elapsed.* = now(init.io) - start;
        const digest = try job.call(job.function("digestLow", 0).?, &.{}, 1000);
        if (digest != @as(u32, @truncate(native.digest))) return error.DigestMismatch;
        if (round == 0) running = try privateMemory(init.io);
        const end_start = now(init.io);
        job.end();
        end_elapsed.* = now(init.io) - end_start;
    }
    try report(out, "wasm", corpus.len, wasm_ns[0..rounds]);
    try out.print("ratio wasm/native median time {d:.2}\n", .{
        @as(f64, @floatFromInt(median(wasm_ns[0..rounds]))) / @as(f64, @floatFromInt(median(native_ns[0..rounds]))),
    });
    try out.print("load {d} us, begin median {d} us, end median {d} us\n", .{
        load_ns / 1000, median(begin_ns[0..rounds]) / 1000, median(end_ns[0..rounds]) / 1000,
    });
    try out.print("metered instructions per byte {d:.1} (one {d}-byte window)\n", .{
        try instructionsPerByte(&module, limits, corpus[0..scan.window_bytes]), scan.window_bytes,
    });
    const ended = try privateMemory(init.io);
    module.unload();
    const unloaded = try privateMemory(init.io);
    try out.print("private memory KiB, Anonymous and Rss: before load {d}, {d}\n", .{ before.anonymous, before.rss });
    for ([_][]const u8{ "module loaded", "first job running", "every job ended", "module unloaded" }, [_]Memory{ loaded, running, ended, unloaded }) |phase, memory| {
        try out.print("  {s}: {d}, {d}\n", .{
            phase,
            @as(i64, @intCast(memory.anonymous)) - @as(i64, @intCast(before.anonymous)),
            @as(i64, @intCast(memory.rss)) - @as(i64, @intCast(before.rss)),
        });
    }
    try out.flush();
}

fn instructionsPerByte(module: *codec_runtime.Module, limits: codec_runtime.Limits, window: []const u8) !f64 {
    var low: codec_runtime.Budget = 0;
    var high: codec_runtime.Budget = std.math.maxInt(codec_runtime.Budget);
    while (low < high) {
        const middle = low + (high - low) / 2;
        var job = try codec_runtime.Job.begin(module, limits);
        defer job.end();
        const address = try job.call(job.function("windowAddress", 0).?, &.{}, 1000);
        @memcpy(job.memory()[address..][0..window.len], window);
        if (job.call(job.function("feed", 1).?, &.{@intCast(window.len)}, middle)) |_| {
            high = middle;
        } else |err| switch (err) {
            error.BudgetExhausted => low = middle + 1,
            else => return err,
        }
    }
    return @as(f64, @floatFromInt(low)) / @as(f64, @floatFromInt(window.len));
}

fn report(out: *std.Io.Writer, name: []const u8, bytes: usize, samples: []u64) !void {
    const middle = median(samples);
    const mb = @as(f64, @floatFromInt(bytes)) / 1e6;
    try out.print("{s}: median {d:.1} MB/s (range {d:.1} to {d:.1})\n", .{
        name,
        mb / seconds(middle),
        mb / seconds(samples[samples.len - 1]),
        mb / seconds(samples[0]),
    });
}

fn median(samples: []u64) u64 {
    std.mem.sortUnstable(u64, samples, {}, std.sort.asc(u64));
    return samples[samples.len / 2];
}

fn seconds(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e9;
}

fn now(io: std.Io) u64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

/// Anonymous memory, not Private_Dirty: a freshly built binary's own code
/// pages count as private dirty until the kernel writes the file back.
const Memory = struct { anonymous: u64, rss: u64 };

fn privateMemory(io: std.Io) !Memory {
    var buffer: [4096]u8 = undefined;
    const text = try std.Io.Dir.cwd().readFile(io, "/proc/self/smaps_rollup", &buffer);
    return .{ .anonymous = field(text, "Anonymous:"), .rss = field(text, "Rss:") };
}

fn field(text: []const u8, name: []const u8) u64 {
    const start = (std.mem.indexOf(u8, text, name) orelse return 0) + name.len;
    const line = std.mem.sliceTo(text[start..], '\n');
    var words = std.mem.tokenizeScalar(u8, line, ' ');
    return std.fmt.parseInt(u64, words.next() orelse return 0, 10) catch 0;
}

/// Response events shaped like Codex's: text deltas with escapes and
/// non-ASCII text, and function-call argument deltas carrying escaped JSON.
fn codexStream(gpa: std.mem.Allocator, target: usize) ![]u8 {
    var stream: std.Io.Writer.Allocating = .init(gpa);
    var random = std.Random.DefaultPrng.init(0x5eed);
    const words = [_][]const u8{ "the", "harness", "waits", "on", "everything", "model", "tool", "caf\\u00e9", "\\\"quoted\\\"", "line\\n", "naïve", "résumé", "build", "zig" };
    var sequence: usize = 0;
    while (stream.written().len < target) : (sequence += 1) {
        const call = random.random().uintLessThan(u8, 8) == 0;
        try stream.writer.print("event: response.{s}.delta\ndata: {{\"type\":\"response.{s}.delta\",\"sequence_number\":{d},\"item_id\":\"msg_{x:0>16}\",\"output_index\":0,\"content_index\":0,\"delta\":\"", .{
            if (call) "function_call_arguments" else "output_text",
            if (call) "function_call_arguments" else "output_text",
            sequence,
            random.random().int(u64),
        });
        if (call) {
            try stream.writer.writeAll("{\\\"command\\\":\\\"zig build test\\\",\\\"timeout_ms\\\":120000}");
        } else for (0..random.random().intRangeAtMost(usize, 1, 12)) |_| {
            try stream.writer.print("{s} ", .{words[random.random().uintLessThan(usize, words.len)]});
        }
        try stream.writer.writeAll(if (call) "\"}\n\n" else "\",\"logprobs\":[]}\n\n");
    }
    return stream.written();
}
