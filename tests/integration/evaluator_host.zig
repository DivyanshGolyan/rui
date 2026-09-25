const std = @import("std");
const evaluator = @import("evaluator");
const c = @cImport({
    @cInclude("unistd.h");
});

fn replaceSource(dir: std.Io.Dir, io: std.Io, bytes: []const u8) !std.Io.File {
    var writer = try dir.createFile(io, "source", .{ .truncate = true });
    try writer.writeStreamingAll(io, bytes);
    writer.close(io);
    return dir.openFile(io, "source", .{});
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 2 and std.mem.eql(u8, args[1], "run-prepared")) {
        var marker: [1]u8 = undefined;
        if (c.pread(3, &marker, 1, 0) != 1) return error.InvalidFixtureSource;
        const stdout = std.Io.File.stdout();
        if (marker[0] == 'W' or marker[0] == 'Q') {
            var block: [16 * 1024]u8 = undefined;
            var used: usize = 0;
            block[used] = '{';
            used += 1;
            const count: usize = if (marker[0] == 'W') 50000 else 21;
            for (0..count) |i| {
                var item_buffer: [32]u8 = undefined;
                const item = try std.fmt.bufPrint(&item_buffer, "\"k{d}\":{d}{s}", .{
                    if (marker[0] == 'Q' and i == 20) @as(usize, 0) else i,
                    if (marker[0] == 'Q' and i == 20) @as(u8, 1) else @as(u8, 0),
                    if (i + 1 == count) "}" else ",",
                });
                if (used + item.len > block.len) {
                    var header: [4]u8 = undefined;
                    std.mem.writeInt(u32, &header, @intCast(used), .little);
                    try stdout.writeStreamingAll(io, &header);
                    try stdout.writeStreamingAll(io, block[0..used]);
                    used = 0;
                }
                @memcpy(block[used..][0..item.len], item);
                used += item.len;
            }
            var header: [4]u8 = undefined;
            std.mem.writeInt(u32, &header, @intCast(used), .little);
            try stdout.writeStreamingAll(io, &header);
            try stdout.writeStreamingAll(io, block[0..used]);
            try stdout.writeStreamingAll(io, &.{ 0, 0, 0, 0 });
            return;
        }
        if (marker[0] == 'B') {
            try stdout.writeStreamingAll(io, &.{ 1, 0, 0, 0, '[' });
            var block: [8000]u8 = undefined;
            for (0..1000) |i| @memcpy(block[i * 8 ..][0..8], "{\"k\":0},");
            for (0..100) |i| {
                if (i == 99) block[block.len - 1] = ']';
                try stdout.writeStreamingAll(io, &.{ 0x40, 0x1f, 0, 0 });
                try stdout.writeStreamingAll(io, &block);
            }
            try stdout.writeStreamingAll(io, &.{ 0, 0, 0, 0 });
            return;
        }
        if (marker[0] == 'X' or marker[0] == 'Y') {
            var digits: [10400]u8 = undefined;
            var length: usize = 0;
            if (marker[0] == 'X') {
                @memcpy(digits[0..2], "0.");
                @memset(digits[2..10002], '0');
                @memcpy(digits[10002..10009], "1e10310");
                length = 10009; // 1e309, despite exponent/mantissa cancellation.
            } else {
                digits[0] = '1';
                @memset(digits[1..10310], '0');
                @memcpy(digits[10310..10317], "e-10001");
                length = 10317; // 1e308, despite a long negative exponent.
            }
            var header: [4]u8 = undefined;
            std.mem.writeInt(u32, &header, @intCast(length), .little);
            try stdout.writeStreamingAll(io, &header);
            try stdout.writeStreamingAll(io, digits[0..length]);
            try stdout.writeStreamingAll(io, &.{ 0, 0, 0, 0 });
            return;
        }
        if (marker[0] == 'T') {
            _ = c.sleep(20); // Parent's five-second watchdog must terminate us.
            return error.EvaluatorDeadlineNotEnforced;
        }
        const json = switch (marker[0]) {
            'D' => "{\"answer\":1,\"answer\":2}",
            'E' => "{\"a\":1,\"\\u0061\":2}",
            'N' => "1e999",
            'F' => "1.7976931348623158e308",
            'S' => "\"\\ud800\"",
            '!' => "5",
            else => "{",
        };
        if (marker[0] == 'L') {
            var block: [16 * 1024]u8 = undefined;
            @memset(&block, 'x');
            block[0] = '"';
            var remaining: usize = 600 * 1024 + 1;
            while (remaining != 0) {
                const count = @min(remaining, block.len);
                var header: [4]u8 = undefined;
                std.mem.writeInt(u32, &header, @intCast(count), .little);
                try stdout.writeStreamingAll(io, &header);
                try stdout.writeStreamingAll(io, block[0..count]);
                block[0] = 'x';
                remaining -= count;
            }
            try stdout.writeStreamingAll(io, &.{ 1, 0, 0, 0, '"', 0, 0, 0, 0 });
            return;
        }
        var header: [4]u8 = undefined;
        std.mem.writeInt(u32, &header, @intCast(json.len), .little);
        try stdout.writeStreamingAll(io, &header);
        try stdout.writeStreamingAll(io, json);
        try stdout.writeStreamingAll(io, &.{ 0, 0, 0, 0 });
        if (marker[0] == '!') return error.FixtureNonzeroExit;
        return;
    }
    if (args.len != 2) return error.ExpectedEvaluatorPath;

    var random: u64 = undefined;
    io.random(@ptrCast(&random));
    var temporary_name_buffer: [64]u8 = undefined;
    const temporary_name = try std.fmt.bufPrint(&temporary_name_buffer, ".zig-cache/evaluator-host-{x}", .{random});
    try std.Io.Dir.cwd().createDirPath(io, temporary_name);
    defer std.Io.Dir.cwd().deleteTree(io, temporary_name) catch {};
    var tmp = try std.Io.Dir.cwd().openDir(io, temporary_name, .{ .iterate = true });
    defer tmp.close(io);
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_length = try tmp.realPath(io, &root_buffer);
    const root = root_buffer[0..root_length];
    var scratch_used: std.atomic.Value(u64) = .init(0);
    var owner = evaluator.Owner.init(io, root, .{ .used = &scratch_used, .limit = 32 * 1024 * 1024 });
    const evaluator_dirname = std.fs.path.dirname(args[1]) orelse ".";
    var evaluator_dir = try std.Io.Dir.cwd().openDir(io, evaluator_dirname, .{});
    defer evaluator_dir.close(io);
    var evaluator_dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const evaluator_dir_length = try evaluator_dir.realPath(io, &evaluator_dir_buffer);
    owner.child_name = try std.fs.path.join(init.arena.allocator(), &.{
        evaluator_dir_buffer[0..evaluator_dir_length],
        std.fs.path.basename(args[1]),
    });
    const real_child = owner.child_name;

    var source = try replaceSource(tmp, io,
        "throw Error('compile-only must not execute'); export default async function workflow() {}");
    defer source.close(io);
    var diagnostic = evaluator.Diagnostic{};
    owner.validate(source, evaluator.Cancellation.never(), &diagnostic) catch return error.CompileOnlyFailed;
    if (diagnostic.text().len != 0) return error.SuccessHasCompilerDiagnostic;
    var missing_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const missing = try std.fmt.bufPrint(&missing_buffer, "{s}/unavailable", .{owner.scratch_path});
    const scratch_path = owner.scratch_path;
    owner.scratch_path = missing;
    owner.output_removal = .injected_failure;
    try owner.validate(source, evaluator.Cancellation.never(), &diagnostic);
    try owner.finish();
    if (scratch_used.load(.acquire) != 0) return error.CompileOnlyScratchCharged;
    var validation_iterator = tmp.iterate();
    while (try validation_iterator.next(io)) |entry| {
        if (std.mem.startsWith(u8, entry.name, "evaluator-")) return error.UnexpectedValidationScratch;
    }
    owner.scratch_path = scratch_path;
    owner.output_removal = .native;

    source.close(io);
    source = try replaceSource(tmp, io, "export default async function workflow(_, input) { return input; }");
    var input_writer = try tmp.createFile(io, "input", .{});
    try input_writer.writeStreamingAll(io, &.{ 5, 1, 0, 0, 0, 2 });
    input_writer.close(io);
    var prepared = try tmp.openFile(io, "input", .{});
    defer prepared.close(io);
    var consumption = struct { io: std.Io, observed: bool = false }{ .io = io };
    owner.evaluate(source, prepared, evaluator.Cancellation.never(), &consumption, struct {
        fn consume(result: *@TypeOf(consumption), output: *std.Io.File) !void {
            if (c.write(output.handle, "!", 1) != -1) return error.WritableEvaluatorResult;
            var bytes: [4]u8 = undefined;
            const count = try output.readPositionalAll(result.io, &bytes, 0);
            if (!std.mem.eql(u8, "true", bytes[0..count])) return error.UnexpectedEvaluatorOutput;
            result.observed = true;
        }
    }.consume) catch return error.FixedInputFailed;
    if (!consumption.observed) return error.ConsumerNotCalled;

    var bad_writer = try tmp.createFile(io, "bad-input", .{});
    try bad_writer.writeStreamingAll(io, &.{ 4, 5, 0, 0, 0, 0, 0, 0, 0, 'x' });
    bad_writer.close(io);
    {
        const bad_input = try tmp.openFile(io, "bad-input", .{});
        defer bad_input.close(io);
        var bad_delivered = false;
        try std.testing.expectError(error.EvaluationFailed, owner.evaluate(
            source,
            bad_input,
            evaluator.Cancellation.never(),
            &bad_delivered,
            struct {
                fn consume(observed: *bool, _: *std.Io.File) !void {
                    observed.* = true;
                }
            }.consume,
        ));
        if (bad_delivered or scratch_used.load(.acquire) != 0) return error.MalformedPreparedInputDelivered;
    }
    try tmp.deleteFile(io, "bad-input");
    consumption.observed = false;
    try owner.evaluate(source, prepared, evaluator.Cancellation.never(), &consumption, struct {
        fn consume(result: *@TypeOf(consumption), _: *std.Io.File) !void {
            result.observed = true;
        }
    }.consume);
    if (!consumption.observed) return error.EvaluatorNotReusable;

    owner.output_removal = .injected_failure;
    try owner.evaluate(
        source,
        prepared,
        evaluator.Cancellation.never(),
        &consumption,
        struct {
            fn consume(_: *@TypeOf(consumption), _: *std.Io.File) !void {}
        }.consume,
    );
    if (scratch_used.load(.acquire) != 4) return error.EvaluatorScratchChargeDropped;
    var retained_iterator = tmp.iterate();
    var retained_names: usize = 0;
    while (try retained_iterator.next(io)) |entry| {
        if (std.mem.startsWith(u8, entry.name, "evaluator-")) retained_names += 1;
    }
    if (retained_names != 1) return error.EvaluatorScratchCustodyDropped;
    try std.testing.expectError(error.InjectedScratchRemovalFailure, owner.finish());
    owner.output_removal = .native;
    try owner.finish(); // Idle/shutdown reclamation needs no next evaluation.
    if (scratch_used.load(.acquire) != 0) return error.EvaluatorScratchChargeLeaked;
    try owner.evaluate(source, prepared, evaluator.Cancellation.never(), &consumption, struct {
        fn consume(_: *@TypeOf(consumption), _: *std.Io.File) !void {}
    }.consume);
    if (scratch_used.load(.acquire) != 0) return error.EvaluatorScratchChargeLeaked;

    source.close(io);
    source = try replaceSource(tmp, io, "function (");
    try std.testing.expectError(error.EvaluationFailed, owner.validate(source, evaluator.Cancellation.never(), &diagnostic));
    if (std.mem.indexOf(u8, diagnostic.text(), "SyntaxError") == null or
        std.mem.indexOf(u8, diagnostic.text(), "workflow.js") == null)
    {
        std.debug.print("compiler diagnostic: {s}\n", .{diagnostic.text()});
        return error.MissingCompilerDiagnostic;
    }
    source.close(io);
    source = try replaceSource(tmp, io, "export default async function workflow(_, input) { return input; }");
    try owner.validate(source, evaluator.Cancellation.never(), &diagnostic);
    if (diagnostic.text().len != 0) return error.StaleCompilerDiagnostic;
    owner.budget.limit = 3; // JSON true needs four bytes, with no partial delivery.
    var delivered = false;
    try std.testing.expectError(error.EvaluationFailed, owner.evaluate(
        source,
        prepared,
        evaluator.Cancellation.never(),
        &delivered,
        struct {
            fn consume(observed: *bool, _: *std.Io.File) !void {
                observed.* = true;
            }
        }.consume,
    ));
    if (delivered or scratch_used.load(.acquire) != 0) return error.PartialEvaluatorDelivery;
    owner.budget.limit = 32 * 1024 * 1024;
    try owner.evaluate(source, prepared, evaluator.Cancellation.never(), &consumption, struct {
        fn consume(result: *@TypeOf(consumption), output: *std.Io.File) !void {
            var bytes: [4]u8 = undefined;
            const count = try output.readPositionalAll(result.io, &bytes, 0);
            if (!std.mem.eql(u8, "true", bytes[0..count])) return error.UnexpectedEvaluatorOutput;
        }
    }.consume);

    source.close(io);
    source = try replaceSource(tmp, io, "export default async function workflow() { return '中😀'; }");
    try owner.evaluate(source, prepared, evaluator.Cancellation.never(), &consumption, struct {
        fn consume(result: *@TypeOf(consumption), output: *std.Io.File) !void {
            var bytes: [16]u8 = undefined;
            const count = try output.readPositionalAll(result.io, &bytes, 0);
            if (!std.mem.eql(u8, "\"中😀\"", bytes[0..count])) return error.UnexpectedEvaluatorOutput;
        }
    }.consume);

    source.close(io);
    source = try replaceSource(tmp, io,
        "export default async function workflow() { return 'a'.repeat(600) + 'b'.repeat(600); }");
    try owner.evaluate(source, prepared, evaluator.Cancellation.never(), &consumption, struct {
        fn consume(result: *@TypeOf(consumption), output: *std.Io.File) !void {
            var bytes: [1202]u8 = undefined;
            if (try output.readPositionalAll(result.io, &bytes, 0) != bytes.len or
                bytes[0] != '"' or bytes[1201] != '"') return error.UnexpectedEvaluatorOutput;
            for (bytes[1..601]) |byte| if (byte != 'a') return error.UnexpectedEvaluatorOutput;
            for (bytes[601..1201]) |byte| if (byte != 'b') return error.UnexpectedEvaluatorOutput;
        }
    }.consume);
    if (scratch_used.load(.acquire) != 0) return error.EvaluatorScratchChargeLeaked;

    var self_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const self_length = try std.process.executablePath(io, &self_buffer);
    owner.child_name = self_buffer[0..self_length];
    for ([_][]const u8{ "D", "E", "N", "S", "X", "Q", "{" }) |fake_output| {
        source.close(io);
        source = try replaceSource(tmp, io, fake_output);
        var called = false;
        try std.testing.expectError(error.MalformedEvaluatorOutput, owner.evaluate(
            source,
            prepared,
            evaluator.Cancellation.never(),
            &called,
            struct {
                fn consume(observed: *bool, _: *std.Io.File) !void {
                    observed.* = true;
                }
            }.consume,
        ));
        if (called) return error.InvalidEvaluatorOutputDelivered;
        if (scratch_used.load(.acquire) != 0) return error.EvaluatorScratchChargeLeaked;
    }
    owner.index_removal = .injected_failure;
    try std.testing.expectError(error.MalformedEvaluatorOutput, owner.evaluate(
        source,
        prepared,
        evaluator.Cancellation.never(),
        {},
        struct {
            fn consume(_: void, _: *std.Io.File) !void {
                return error.InvalidEvaluatorOutputDelivered;
            }
        }.consume,
    ));
    if (scratch_used.load(.acquire) == 0) return error.EvaluatorIndexChargeDropped;
    var index_iterator = tmp.iterate();
    var index_names: usize = 0;
    while (try index_iterator.next(io)) |entry| {
        if (std.mem.startsWith(u8, entry.name, "evaluator-")) {
            if (!std.mem.endsWith(u8, entry.name, ".index")) return error.EvaluatorOutputNotReclaimed;
            index_names += 1;
        }
    }
    if (index_names != 1) return error.EvaluatorIndexCustodyDropped;
    try std.testing.expectError(error.InjectedScratchRemovalFailure, owner.finish());
    owner.index_removal = .native;
    try owner.finish();
    if (scratch_used.load(.acquire) != 0) return error.EvaluatorIndexChargeLeaked;
    source.close(io);
    for ([_][]const u8{ "F", "Y" }) |fake_output| {
        source = try replaceSource(tmp, io, fake_output);
        var finite = false;
        try owner.evaluate(source, prepared, evaluator.Cancellation.never(), &finite, struct {
            fn consume(observed: *bool, _: *std.Io.File) !void {
                observed.* = true;
            }
        }.consume);
        if (!finite or scratch_used.load(.acquire) != 0) return error.FiniteBoundaryRejected;
        source.close(io);
    }
    source = try replaceSource(tmp, io, "T");
    const deadline_start = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    var timed_delivered = false;
    try std.testing.expectError(error.EvaluationFailed, owner.evaluate(
        source,
        prepared,
        evaluator.Cancellation.never(),
        &timed_delivered,
        struct {
            fn consume(observed: *bool, _: *std.Io.File) !void {
                observed.* = true;
            }
        }.consume,
    ));
    if (timed_delivered or scratch_used.load(.acquire) != 0 or
        std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds - deadline_start > 8 * 1_000_000_000)
        return error.EvaluatorDeadlineNotEnforced;
    source.close(io);
    source = try replaceSource(tmp, io, "L");
    var large = struct { io: std.Io, called: bool = false }{ .io = io };
    try owner.evaluate(source, prepared, evaluator.Cancellation.never(), &large, struct {
        fn consume(observed: *@TypeOf(large), output: *std.Io.File) !void {
            if (try output.length(observed.io) != 600 * 1024 + 2)
                return error.UnexpectedEvaluatorOutput;
            observed.called = true;
        }
    }.consume);
    if (!large.called or scratch_used.load(.acquire) != 0) return error.LargeEvaluatorOutputNotDelivered;
    source.close(io);
    source = try replaceSource(tmp, io, "B");
    var siblings = struct { io: std.Io, called: bool = false }{ .io = io };
    try owner.evaluate(source, prepared, evaluator.Cancellation.never(), &siblings, struct {
        fn consume(observed: *@TypeOf(siblings), output: *std.Io.File) !void {
            if (try output.length(observed.io) != 800001) return error.UnexpectedEvaluatorOutput;
            observed.called = true;
        }
    }.consume);
    if (!siblings.called or scratch_used.load(.acquire) != 0) return error.SiblingObjectOutputNotDelivered;
    source.close(io);
    source = try replaceSource(tmp, io, "W");
    var wide = struct { io: std.Io, called: bool = false }{ .io = io };
    try owner.evaluate(source, prepared, evaluator.Cancellation.never(), &wide, struct {
        fn consume(observed: *@TypeOf(wide), output: *std.Io.File) !void {
            // 50,000 entries each contribute six fixed bytes plus their
            // decimal index width; opening brace replaces the final comma.
            if (try output.length(observed.io) != 538891) return error.UnexpectedEvaluatorOutput;
            observed.called = true;
        }
    }.consume);
    if (!wide.called or scratch_used.load(.acquire) != 0) return error.WideObjectOutputNotDelivered;
    var cancel_during_validation = struct {
        checks: usize = 0,
        fn check(context: ?*anyopaque) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.checks += 1;
            return @intFromBool(self.checks >= 1000);
        }
    }{};
    var cancelled_delivered = false;
    try std.testing.expectError(error.EvaluationCancelled, owner.evaluate(
        source,
        prepared,
        .{ .context = &cancel_during_validation, .cancelled = @TypeOf(cancel_during_validation).check },
        &cancelled_delivered,
        struct {
            fn consume(observed: *bool, _: *std.Io.File) !void {
                observed.* = true;
            }
        }.consume,
    ));
    if (cancelled_delivered or scratch_used.load(.acquire) != 0) return error.CancelledEvaluatorDelivered;
    owner.child_name = real_child;
    source.close(io);
    source = try replaceSource(tmp, io, "export default async function workflow() { while (true) {} }");
    var cancel_live = struct {
        checks: usize = 0,
        fn check(context: ?*anyopaque) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.checks += 1;
            return @intFromBool(self.checks >= 5);
        }
    }{};
    cancelled_delivered = false;
    owner.output_removal = .injected_failure;
    try std.testing.expectError(error.EvaluationCancelled, owner.evaluate(
        source,
        prepared,
        .{ .context = &cancel_live, .cancelled = @TypeOf(cancel_live).check },
        &cancelled_delivered,
        struct {
            fn consume(observed: *bool, _: *std.Io.File) !void {
                observed.* = true;
            }
        }.consume,
    ));
    if (cancel_live.checks < 5 or cancelled_delivered or scratch_used.load(.acquire) != 0)
        return error.LiveCancellationNotReclaimed;
    try std.testing.expectError(error.InjectedScratchRemovalFailure, owner.finish());
    owner.output_removal = .native;
    try owner.finish();
    const cpu_start = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    var cpu_delivered = false;
    try std.testing.expectError(error.EvaluationFailed, owner.evaluate(
        source,
        prepared,
        evaluator.Cancellation.never(),
        &cpu_delivered,
        struct {
            fn consume(observed: *bool, _: *std.Io.File) !void {
                observed.* = true;
            }
        }.consume,
    ));
    if (cpu_delivered or scratch_used.load(.acquire) != 0 or
        std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds - cpu_start > 4 * 1_000_000_000)
        return error.EvaluatorCpuLimitNotEnforced;
    source.close(io);
    source = try replaceSource(tmp, io,
        "export default async function workflow() { function recurse() { return recurse(); } return recurse(); }");
    var stack_delivered = false;
    try std.testing.expectError(error.EvaluationFailed, owner.evaluate(
        source,
        prepared,
        evaluator.Cancellation.never(),
        &stack_delivered,
        struct {
            fn consume(observed: *bool, _: *std.Io.File) !void {
                observed.* = true;
            }
        }.consume,
    ));
    if (stack_delivered or scratch_used.load(.acquire) != 0) return error.EvaluatorStackLimitNotEnforced;
    source.close(io);
    source = try replaceSource(tmp, io, "export default async function workflow() { return 42; }");
    try owner.evaluate(source, prepared, evaluator.Cancellation.never(), &consumption, struct {
        fn consume(result: *@TypeOf(consumption), output: *std.Io.File) !void {
            var bytes: [2]u8 = undefined;
            if (try output.readPositionalAll(result.io, &bytes, 0) != 2 or
                !std.mem.eql(u8, &bytes, "42")) return error.UnexpectedEvaluatorOutput;
        }
    }.consume);
    if (scratch_used.load(.acquire) != 0) return error.EvaluatorScratchChargeLeaked;
    owner.child_name = self_buffer[0..self_length];
    source.close(io);
    source = try replaceSource(tmp, io, "!exit");
    try std.testing.expectError(error.EvaluationFailed, owner.evaluate(
        source,
        prepared,
        evaluator.Cancellation.never(),
        {},
        struct {
            fn consume(_: void, _: *std.Io.File) !void {}
        }.consume,
    ));
    owner.output_removal = .injected_failure;
    try std.testing.expectError(error.EvaluationFailed, owner.evaluate(
        source,
        prepared,
        evaluator.Cancellation.never(),
        {},
        struct {
            fn consume(_: void, _: *std.Io.File) !void {}
        }.consume,
    ));
    try std.testing.expectError(error.InjectedScratchRemovalFailure, owner.finish());
    owner.output_removal = .native;
    try owner.finish();

    source.close(io);
    source = try replaceSource(tmp, io, "X");
    owner.index_removal = .injected_failure;
    try std.testing.expectError(error.MalformedEvaluatorOutput, owner.evaluate(
        source,
        prepared,
        evaluator.Cancellation.never(),
        {},
        struct {
            fn consume(_: void, _: *std.Io.File) !void {
                return error.InvalidEvaluatorOutputDelivered;
            }
        }.consume,
    ));
    try std.testing.expectError(error.InjectedScratchRemovalFailure, owner.finish());
    owner.index_removal = .native;
    try owner.finish();

    source.close(io);
    source = try replaceSource(tmp, io, "F");
    owner.output_removal = .injected_failure;
    try std.testing.expectError(error.CanonicalPublicationFailed, owner.evaluate(
        source,
        prepared,
        evaluator.Cancellation.never(),
        {},
        struct {
            fn consume(_: void, _: *std.Io.File) !void {
                return error.CanonicalPublicationFailed;
            }
        }.consume,
    ));
    if (scratch_used.load(.acquire) == 0) return error.EvaluatorScratchChargeDropped;
    try std.testing.expectError(error.InjectedScratchRemovalFailure, owner.evaluate(
        source,
        prepared,
        evaluator.Cancellation.never(),
        {},
        struct {
            fn consume(_: void, _: *std.Io.File) !void {
                return error.InvalidEvaluatorOutputDelivered;
            }
        }.consume,
    ));
    try std.testing.expectError(error.InjectedScratchRemovalFailure, owner.finish());
    owner.output_removal = .native;
    try owner.finish();
    if (scratch_used.load(.acquire) != 0) return error.EvaluatorScratchChargeLeaked;
    var iterator = tmp.iterate();
    var count: usize = 0;
    while (try iterator.next(io)) |_| count += 1;
    if (count != 2) return error.EvaluatorScratchLeaked;
    if (scratch_used.load(.acquire) != 0) return error.EvaluatorScratchChargeLeaked;
}
