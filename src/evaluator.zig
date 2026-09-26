const std = @import("std");
const ScratchBudget = @import("ScratchBudget.zig");
const named_scratch = @import("named_scratch.zig");

const c = @cImport({
    @cInclude("evaluator_parent.h");
    @cInclude("unistd.h");
});

pub const Cancellation = struct {
    context: ?*anyopaque,
    cancelled: ?*const fn (?*anyopaque) callconv(.c) c_int,

    pub fn never() Cancellation {
        return .{ .context = null, .cancelled = null };
    }

    fn isCancelled(self: Cancellation) bool {
        return if (self.cancelled) |cancelled| cancelled(self.context) != 0 else false;
    }
};

pub const Diagnostic = struct {
    bytes: [4096]u8 = undefined,
    length: usize = 0,

    pub fn text(self: *const Diagnostic) []const u8 {
        return self.bytes[0..self.length];
    }
};

/// Owns the single evaluator lifecycle. Source and prepared input are borrowed
/// immutable files; callers retain them until the method returns. The output
/// file and its JSON reader are borrowed by the consumer only for its call.
pub const Owner = struct {
    io: std.Io,
    scratch_path: []const u8,
    budget: ScratchBudget,
    child_name: []const u8 = "rui-evaluator",
    mutex: std.Io.Mutex = .init,
    pending: ?Pending = null,
    output_removal: named_scratch.Removal = .native,
    index_removal: named_scratch.Removal = .native,

    const Pending = struct {
        output: ?Scratch,
        index: ?Scratch = null,
    };

    const Scratch = struct {
        io: std.Io,
        file: std.Io.File,
        name: [64]u8,
        name_len: u8,
        budget: ScratchBudget,
        length: u64 = 0,
        charged: u64 = 0,

        fn append(self: *Scratch, bytes: []const u8) !void {
            const end = try std.math.add(u64, self.length, bytes.len);
            if (!self.budget.reserve(bytes.len)) return error.EvaluatorOutputBudgetExceeded;
            // A failed positional write may have changed an unknown prefix.
            // Keep the full reservation until a confirmed shrink or removal.
            self.charged += bytes.len;
            try self.file.writePositionalAll(self.io, bytes, self.length);
            self.length = end;
        }

        fn overwrite(self: *Scratch, position: u64, bytes: []const u8) !void {
            std.debug.assert(position <= self.length and bytes.len <= self.length - position);
            try self.file.writePositionalAll(self.io, bytes, position);
        }

        fn shrink(self: *Scratch, length: u64) !void {
            std.debug.assert(length <= self.length);
            if (c.ftruncate(self.file.handle, @intCast(length)) != 0) return error.EvaluatorIndexTruncateFailed;
            self.budget.release(self.charged - length);
            self.length = length;
            self.charged = length;
        }

        fn reclaim(self: *Scratch, path: []const u8, removal: named_scratch.Removal) !void {
            _ = try named_scratch.removeNameWith(self.io, path, self.name[0..self.name_len], removal);
            self.file.close(self.io);
            self.budget.release(self.charged);
        }

        fn appendOutput(context: ?*anyopaque, bytes: [*c]const u8, length: usize) callconv(.c) c_int {
            const self: *Scratch = @ptrCast(@alignCast(context orelse unreachable));
            self.append(bytes[0..length]) catch return -1;
            return 0;
        }
    };

    pub fn init(io: std.Io, scratch_path: []const u8, budget: ScratchBudget) Owner {
        return .{ .io = io, .scratch_path = scratch_path, .budget = budget };
    }

    pub fn validate(self: *Owner, source: std.Io.File, cancellation: Cancellation, diagnostic: *Diagnostic) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        diagnostic.length = 0;
        try self.run(source, null, true, cancellation, diagnostic, void, {}, consumeNothing);
    }

    pub fn evaluate(
        self: *Owner,
        source: std.Io.File,
        prepared_input: std.Io.File,
        cancellation: Cancellation,
        context: anytype,
        comptime consume: fn (@TypeOf(context), *std.Io.File) anyerror!void,
    ) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.run(source, prepared_input, false, cancellation, null, @TypeOf(context), context, consume);
    }

    /// Retry retained scratch cleanup without starting another evaluator.
    /// Shutdown holds the scratch lease until this succeeds.
    pub fn finish(self: *Owner) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.reclaimPending();
    }

    fn run(
        self: *Owner,
        source: std.Io.File,
        prepared_input: ?std.Io.File,
        compile_only: bool,
        cancellation: Cancellation,
        diagnostic: ?*Diagnostic,
        comptime Context: type,
        context: Context,
        comptime consume: fn (Context, *std.Io.File) anyerror!void,
    ) !void {
        // A prior failed removal keeps this owner fenced until the same
        // actionable names can be reclaimed.
        try self.reclaimPending();
        self.runOwned(source, prepared_input, compile_only, cancellation, diagnostic, Context, context, consume) catch |err| {
            // The caller must see the computation or publication failure;
            // failed cleanup retains custody and fences the next lifecycle.
            self.reclaimPending() catch {};
            return err;
        };
        // Validation has not published anything; failed cleanup prevents
        // admission. Evaluation may already have committed its outcome, so
        // retain failed cleanup without changing that published success.
        if (compile_only) return self.reclaimPending();
        self.reclaimPending() catch {};
    }

    fn runOwned(
        self: *Owner,
        source: std.Io.File,
        prepared_input: ?std.Io.File,
        compile_only: bool,
        cancellation: Cancellation,
        diagnostic: ?*Diagnostic,
        comptime Context: type,
        context: Context,
        comptime consume: fn (Context, *std.Io.File) anyerror!void,
    ) !void {
        var executable_buffer: [std.fs.max_path_bytes:0]u8 = undefined;
        const executable_length = try std.process.executablePath(self.io, &executable_buffer);
        const executable_dir = std.fs.path.dirname(executable_buffer[0..executable_length]) orelse return error.InvalidExecutablePath;
        var child_buffer: [std.fs.max_path_bytes:0]u8 = undefined;
        const child = if (std.fs.path.isAbsolute(self.child_name))
            try std.fmt.bufPrintZ(&child_buffer, "{s}", .{self.child_name})
        else
            try std.fmt.bufPrintZ(&child_buffer, "{s}/{s}", .{ executable_dir, self.child_name });

        var scratch: ?std.Io.Dir = null;
        defer if (scratch) |*dir| dir.close(self.io);
        var name_buffer: [64]u8 = undefined;
        if (!compile_only) {
            scratch = try std.Io.Dir.cwd().openDir(self.io, self.scratch_path, .{});
            var random: u64 = undefined;
            self.io.random(@ptrCast(&random));
            const name = try named_scratch.EvaluatorName.format(&name_buffer, random, .output);
            const output = try scratch.?.createFile(self.io, name, .{
                .read = true,
                .exclusive = true,
                .permissions = .fromMode(0o600),
            });
            self.pending = .{
                .output = .{
                    .io = self.io,
                    .file = output,
                    .name = name_buffer,
                    .name_len = @intCast(name.len),
                    .budget = self.budget,
                },
            };
            var index_name_buffer: [64]u8 = undefined;
            const index_name = try named_scratch.EvaluatorName.format(&index_name_buffer, random, .index);
            const index = try scratch.?.createFile(self.io, index_name, .{
                .read = true,
                .exclusive = true,
                .permissions = .fromMode(0o600),
            });
            self.pending.?.index = .{
                .io = self.io,
                .file = index,
                .name = index_name_buffer,
                .name_len = @intCast(index_name.len),
                .budget = self.budget,
            };
        }
        const result = c.rui_evaluate(
            child.ptr,
            source.handle,
            if (prepared_input) |input| input.handle else -1,
            @intFromBool(compile_only),
            cancellation.cancelled,
            cancellation.context,
            Scratch.appendOutput,
            if (compile_only) null else &self.pending.?.output.?,
            if (diagnostic) |result| &result.bytes else null,
            if (diagnostic) |result| result.bytes.len else 0,
            if (diagnostic) |result| &result.length else null,
        );
        if (result == 1) return error.EvaluationCancelled;
        if (result != 0) return error.EvaluationFailed;
        if (cancellation.isCancelled()) return error.EvaluationCancelled;
        if (compile_only) return;

        const pending = &self.pending.?;
        const owned_output = &pending.output.?.file;
        // Child and pipe custody is complete. Hand validation and the consumer
        // only a read-only descriptor; neither can mutate the charged result.
        const sealed_output = try scratch.?.openFile(self.io, name_buffer[0..pending.output.?.name_len], .{
            .mode = .read_only,
            .follow_symlinks = false,
        });
        owned_output.close(self.io);
        pending.output.?.file = sealed_output;
        try validateJson(self.io, owned_output, &pending.index.?, cancellation);
        if (cancellation.isCancelled()) return error.EvaluationCancelled;
        if (c.lseek(owned_output.handle, 0, c.SEEK_SET) < 0) return error.EvaluatorOutputSeekFailed;
        try consume(context, owned_output);
    }

    fn reclaimPending(self: *Owner) !void {
        const pending = &(self.pending orelse return);
        var removal_error: ?anyerror = null;
        if (pending.output) |*output| {
            if (output.reclaim(self.scratch_path, self.output_removal)) |_| {
                pending.output = null;
            } else |err| removal_error = err;
        }
        if (pending.index) |*index| {
            if (index.reclaim(self.scratch_path, self.index_removal)) |_| {
                pending.index = null;
            } else |err| removal_error = err;
        }
        if (removal_error) |err| return err;
        self.pending = null;
    }

    fn consumeNothing(_: void, _: *std.Io.File) !void {}
};

const Container = struct {
    object_id: u64 = 0,
    expecting_key: bool = false,
    index_base: u64 = 0,
    table: u64 = 0,
    capacity: u64 = 0,
    count: u64 = 0,
};

const Utf8State = struct {
    bytes: [4]u8 = undefined,
    used: u3 = 0,
    needed: u3 = 0,

    fn feed(self: *Utf8State, bytes: []const u8) !void {
        for (bytes) |byte| {
            if (self.used == 0) {
                const needed = std.unicode.utf8ByteSequenceLength(byte) catch return error.MalformedEvaluatorOutput;
                self.needed = @intCast(needed);
            }
            self.bytes[self.used] = byte;
            self.used += 1;
            if (self.used == self.needed) {
                const scalar = std.unicode.utf8Decode(self.bytes[0..self.used]) catch return error.MalformedEvaluatorOutput;
                if (scalar >= 0xd800 and scalar <= 0xdfff) return error.MalformedEvaluatorOutput;
                self.used = 0;
            }
        }
    }
};

const NumberState = struct {
    digits: [309]u8 = [_]u8{'0'} ** 309,
    significant: usize = 0,
    total_digits: u64 = 0,
    digits_before_dot: u64 = 0,
    first_nonzero: ?u64 = null,
    after_dot: bool = false,
    in_exponent: bool = false,
    exponent_negative: bool = false,
    exponent: u64 = 0,

    fn feed(self: *NumberState, bytes: []const u8) void {
        for (bytes) |byte| switch (byte) {
            '.' => self.after_dot = true,
            'e', 'E' => self.in_exponent = true,
            '-' => if (self.in_exponent) {
                self.exponent_negative = true;
            },
            '+',
            => {},
            '0'...'9' => {
                if (self.in_exponent) {
                    self.exponent = std.math.mul(u64, self.exponent, 10) catch std.math.maxInt(u64);
                    self.exponent = std.math.add(u64, self.exponent, byte - '0') catch std.math.maxInt(u64);
                } else {
                    if (!self.after_dot) self.digits_before_dot += 1;
                    if (self.first_nonzero != null or byte != '0') {
                        if (self.first_nonzero == null) self.first_nonzero = self.total_digits;
                        if (self.significant < self.digits.len) self.digits[self.significant] = byte;
                        self.significant += 1;
                    }
                    self.total_digits += 1;
                }
            },
            else => {},
        };
    }

    fn finite(self: *const NumberState) bool {
        const first = self.first_nonzero orelse return true;
        const explicit: i128 = if (self.exponent_negative) -@as(i128, self.exponent) else @as(i128, self.exponent);
        const magnitude = @as(i128, self.digits_before_dot) - @as(i128, first) - 1 + explicit;
        if (magnitude < 308) return true;
        if (magnitude > 308) return false;
        // Decimal values below max finite + half an ulp round to a finite
        // binary64. The exact halfway value rounds to infinity (ties to even).
        const overflow = "179769313486231580793728971405303415079934132710037826936173778980444968292764750946649017977587207096330286416692887910946555547851940402630657488671505820681908902000708383676273854845817711531764475730270069855571366959622842914819860834936475292719074168444365510704342711559699508093042880177904174497792";
        for (overflow, 0..) |limit, i| {
            const digit = if (i < @min(self.significant, self.digits.len)) self.digits[i] else '0';
            if (digit < limit) return true;
            if (digit > limit) return false;
        }
        return false;
    }
};

const KeyIndex = struct {
    scratch: *Owner.Scratch,

    fn append(self: *KeyIndex, bytes: []const u8) !void {
        try self.scratch.append(bytes);
    }

    fn allocate(self: *KeyIndex, capacity: u64, cancellation: Cancellation) !u64 {
        const start = self.scratch.length;
        const zeros: [4096]u8 = @splat(0);
        var remaining = try std.math.mul(u64, capacity, 8);
        while (remaining != 0) {
            if (cancellation.isCancelled()) return error.EvaluationCancelled;
            const amount: usize = @intCast(@min(remaining, zeros.len));
            try self.append(zeros[0..amount]);
            remaining -= amount;
        }
        return start;
    }

    fn slot(self: *KeyIndex, table: u64, bucket: u64) !u64 {
        var bytes: [8]u8 = undefined;
        _ = try self.scratch.file.readPositionalAll(self.scratch.io, &bytes, table + bucket * 8);
        return std.mem.readInt(u64, &bytes, .little);
    }

    fn setSlot(self: *KeyIndex, table: u64, bucket: u64, value: u64) !void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .little);
        try self.scratch.overwrite(table + bucket * 8, &bytes);
    }

    fn grow(self: *KeyIndex, object: *Container, cancellation: Cancellation) !void {
        const next_capacity = try std.math.mul(u64, object.capacity, 2);
        const next_table = try self.allocate(next_capacity, cancellation);
        for (0..object.capacity) |old_bucket| {
            if (cancellation.isCancelled()) return error.EvaluationCancelled;
            const entry = try self.slot(object.table, old_bucket);
            if (entry == 0) continue;
            var header: [16]u8 = undefined;
            _ = try self.scratch.file.readPositionalAll(self.scratch.io, &header, entry - 1);
            const hash = std.mem.readInt(u64, header[8..16], .little);
            var bucket = hash % next_capacity;
            while (try self.slot(next_table, bucket) != 0) {
                if (cancellation.isCancelled()) return error.EvaluationCancelled;
                bucket = (bucket + 1) % next_capacity;
            }
            try self.setSlot(next_table, bucket, entry);
        }
        object.table = next_table;
        object.capacity = next_capacity;
    }

    fn pop(self: *KeyIndex, base: u64) !void {
        try self.scratch.shrink(base);
    }
};

fn validateJson(io: std.Io, output: *std.Io.File, index_scratch: *Owner.Scratch, cancellation: Cancellation) !void {
    const index = &index_scratch.file;
    var window: [16 * 1024]u8 = undefined;
    const output_length = try output.length(io);
    var position: u64 = 0;
    var ended = false;
    var nesting_storage: [4096]u8 = undefined;
    var nesting = std.heap.FixedBufferAllocator.init(&nesting_storage);
    var scanner = std.json.Scanner.initStreaming(nesting.allocator());
    defer scanner.deinit();
    var stack: [129]Container = undefined;
    var depth: usize = 0;
    var next_object_id: u64 = 1;
    var key_start: ?u64 = null;
    var key_length: u64 = 0;
    var keys = KeyIndex{ .scratch = index_scratch };
    // A live object's table grows with its keys in charged scratch. Closing
    // the object shrinks this stack arena, so sibling objects retain no index.
    var seed: u64 = undefined;
    io.random(@ptrCast(&seed));
    var key_hash: std.hash.Wyhash = undefined;
    var utf8 = Utf8State{};
    var number = NumberState{};
    var in_number = false;
    while (true) {
        if (cancellation.isCancelled()) return error.EvaluationCancelled;
        const token = scanner.next() catch |err| switch (err) {
            error.BufferUnderrun => {
                if (ended) return error.MalformedEvaluatorOutput;
                if (position == output_length) {
                    scanner.endInput();
                    ended = true;
                } else {
                    const amount: usize = @intCast(@min(output_length - position, window.len));
                    const count = try output.readPositionalAll(io, window[0..amount], position);
                    if (count != amount) return error.MalformedEvaluatorOutput;
                    position += count;
                    scanner.feedInput(window[0..count]);
                }
                continue;
            },
            else => return error.MalformedEvaluatorOutput,
        };
        switch (token) {
            .end_of_document => {
                if (depth != 0 or utf8.used != 0 or (in_number and !number.finite())) return error.MalformedEvaluatorOutput;
                return;
            },
            .object_begin => {
                if (depth == stack.len) return error.MalformedEvaluatorOutput;
                const base = keys.scratch.length;
                const table = try keys.allocate(16, cancellation);
                stack[depth] = .{
                    .object_id = next_object_id,
                    .expecting_key = true,
                    .index_base = base,
                    .table = table,
                    .capacity = 16,
                };
                next_object_id += 1;
                depth += 1;
            },
            .array_begin => {
                if (depth == stack.len) return error.MalformedEvaluatorOutput;
                stack[depth] = .{};
                depth += 1;
            },
            .object_end, .array_end => {
                if (depth == 0) return error.MalformedEvaluatorOutput;
                depth -= 1;
                if (token == .object_end) try keys.pop(stack[depth].index_base);
                if (depth != 0 and stack[depth - 1].object_id != 0) stack[depth - 1].expecting_key = true;
            },
            .partial_string, .partial_string_escaped_1, .partial_string_escaped_2, .partial_string_escaped_3, .partial_string_escaped_4, .string => {
                const bytes: []const u8 = switch (token) {
                    .partial_string => |part| part,
                    .partial_string_escaped_1 => |part| &part,
                    .partial_string_escaped_2 => |part| &part,
                    .partial_string_escaped_3 => |part| &part,
                    .partial_string_escaped_4 => |part| &part,
                    .string => |part| part,
                    else => unreachable,
                };
                try utf8.feed(bytes);
                const is_key = depth != 0 and stack[depth - 1].object_id != 0 and stack[depth - 1].expecting_key;
                if (is_key) {
                    // Escaped and literal JSON spellings can denote the same
                    // key. Keep decoded keys in charged scratch until this
                    // object closes, rather than adding a second raw-range
                    // decoder. For n keys and D decoded bytes the index uses
                    // D + 16n record bytes plus less than 16C table bytes
                    // (C is its current capacity); this can exceed output
                    // size, but resident memory stays bounded.
                    if (key_start == null) {
                        const object = &stack[depth - 1];
                        if (object.count >= object.capacity / 2) try keys.grow(object, cancellation);
                        key_start = keys.scratch.length;
                        key_hash = std.hash.Wyhash.init(seed ^ stack[depth - 1].object_id);
                        const header: [16]u8 = @splat(0);
                        try keys.append(&header);
                    }
                    key_hash.update(bytes);
                    try keys.append(bytes);
                    key_length += bytes.len;
                }
                if (token == .string) {
                    if (utf8.used != 0) return error.MalformedEvaluatorOutput;
                    if (is_key) {
                        const current = key_start.?;
                        const hash = key_hash.final();
                        const object = &stack[depth - 1];
                        var metadata: [16]u8 = undefined;
                        std.mem.writeInt(u64, metadata[0..8], key_length, .little);
                        std.mem.writeInt(u64, metadata[8..16], hash, .little);
                        try index_scratch.overwrite(current, &metadata);
                        var bucket = hash % object.capacity;
                        var left: [4096]u8 = undefined;
                        var right: [4096]u8 = undefined;
                        while (true) {
                            if (cancellation.isCancelled()) return error.EvaluationCancelled;
                            const prior = try keys.slot(object.table, bucket);
                            if (prior == 0) {
                                try keys.setSlot(object.table, bucket, current + 1);
                                object.count += 1;
                                break;
                            }
                            const previous = prior - 1;
                            var header: [16]u8 = undefined;
                            _ = try index.readPositionalAll(io, &header, previous);
                            const length = std.mem.readInt(u64, header[0..8], .little);
                            const old_hash = std.mem.readInt(u64, header[8..16], .little);
                            if (old_hash == hash and length == key_length) {
                                var compared: u64 = 0;
                                while (compared < length) {
                                    if (cancellation.isCancelled()) return error.EvaluationCancelled;
                                    const amount: usize = @intCast(@min(length - compared, left.len));
                                    _ = try index.readPositionalAll(io, left[0..amount], previous + 16 + compared);
                                    _ = try index.readPositionalAll(io, right[0..amount], current + 16 + compared);
                                    if (!std.mem.eql(u8, left[0..amount], right[0..amount])) break;
                                    compared += amount;
                                }
                                if (compared == length) return error.MalformedEvaluatorOutput;
                            }
                            bucket = (bucket + 1) % object.capacity;
                        }
                        stack[depth - 1].expecting_key = false;
                        key_start = null;
                        key_length = 0;
                    } else if (depth != 0 and stack[depth - 1].object_id != 0) stack[depth - 1].expecting_key = true;
                }
            },
            .partial_number, .number => |part| {
                if (!in_number) {
                    number = .{};
                    in_number = true;
                }
                number.feed(part);
                if (token == .number) {
                    if (!number.finite()) return error.MalformedEvaluatorOutput;
                    in_number = false;
                    if (depth != 0 and stack[depth - 1].object_id != 0) stack[depth - 1].expecting_key = true;
                }
            },
            .true, .false, .null => if (depth != 0 and stack[depth - 1].object_id != 0) {
                stack[depth - 1].expecting_key = true;
            },
            else => return error.MalformedEvaluatorOutput,
        }
    }
}
