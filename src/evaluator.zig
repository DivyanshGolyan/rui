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
/// file is borrowed by the consumer only for its call.
pub const Owner = struct {
    io: std.Io,
    scratch_path: []const u8,
    budget: ScratchBudget,
    child_name: []const u8 = "rui-evaluator",
    mutex: std.Io.Mutex = .init,
    pending: ?Pending = null,
    output_removal: named_scratch.Removal = .native,

    const Pending = struct {
        output: ?Scratch,
    };

    const Scratch = struct {
        file: std.Io.File,
        name: [64]u8,
        name_len: u8,
        charge: OutputCharge,
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
            const name = try std.fmt.bufPrint(&name_buffer, "evaluator-{x}.tmp", .{random});
            const output = try scratch.?.createFile(self.io, name, .{
                .read = true,
                .exclusive = true,
                .permissions = .fromMode(0o600),
            });
            self.pending = .{
                .output = .{
                    .file = output,
                    .name = name_buffer,
                    .name_len = @intCast(name.len),
                    .charge = .{ .budget = self.budget },
                },
            };
        }
        const result = c.rui_evaluate(
            child.ptr,
            source.handle,
            if (prepared_input) |input| input.handle else -1,
            if (compile_only) -1 else self.pending.?.output.?.file.handle,
            self.budget.limit,
            @intFromBool(compile_only),
            cancellation.cancelled,
            cancellation.context,
            OutputCharge.reserve,
            if (compile_only) null else &self.pending.?.output.?.charge,
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
        // Child and pipe custody is complete. The consumer receives only a
        // read-only descriptor and cannot mutate the charged result.
        const sealed_output = try scratch.?.openFile(self.io, name_buffer[0..pending.output.?.name_len], .{
            .mode = .read_only,
            .follow_symlinks = false,
        });
        owned_output.close(self.io);
        pending.output.?.file = sealed_output;
        if (cancellation.isCancelled()) return error.EvaluationCancelled;
        if (c.lseek(owned_output.handle, 0, c.SEEK_SET) < 0) return error.EvaluatorOutputSeekFailed;
        try consume(context, owned_output);
    }

    fn reclaimPending(self: *Owner) !void {
        const pending = &(self.pending orelse return);
        var removal_error: ?anyerror = null;
        if (pending.output) |*output| {
            if (named_scratch.removeNameWith(
                self.io,
                self.scratch_path,
                output.name[0..output.name_len],
                self.output_removal,
            )) |_| {
                output.file.close(self.io);
                output.charge.budget.release(output.charge.bytes);
                pending.output = null;
            } else |err| removal_error = err;
        }
        if (removal_error) |err| return err;
        self.pending = null;
    }

    fn consumeNothing(_: void, _: *std.Io.File) !void {}
};

const OutputCharge = struct {
    budget: ScratchBudget,
    bytes: u64 = 0,

    fn reserve(context: ?*anyopaque, amount: u64) callconv(.c) c_int {
        const self: *OutputCharge = @ptrCast(@alignCast(context orelse unreachable));
        if (!self.budget.reserve(amount)) return -1;
        self.bytes += amount;
        return 0;
    }
};
